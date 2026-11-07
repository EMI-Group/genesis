defmodule EvoDashWeb.ProjectsLive.GitHub do
  @moduledoc """
  Async GitHub issue integration for `EvoDashWeb.ProjectsLive`.

  Support module (same pattern as `EvoDashWeb.ReviewLive.MergeCheck`) so the
  single-page LiveView stays lean. Every function takes and returns a
  LiveView socket; ProjectsLive's handle_event/handle_info clauses are thin
  wrappers.

  All GitHub data access goes through the node-aware `EvoDash.NodeContext`
  (the `gh` CLI runs on the node where the repo lives — local OR SSH remote;
  the dashboard never touches gh/git directly). Nothing here blocks the page
  load: every call runs in a supervised `EvoDash.TaskSupervisor` task (the
  runner is resolved from application env AT SPAWN TIME so tests can stub
  it) and reports back via a message stale-guarded on project path, target,
  node and request identity before being applied.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, connected?: 1]

  alias EvoGit.TaskRegistry

  alias EvoDash.NodeContext
  alias EvoDash.SafeCall
  alias EvoDashWeb.GitHubComponents
  alias EvoDashWeb.LiveHooks.NodeAware
  alias EvoDashWeb.ProjectsLive.LaunchOptions
  alias EvoDashWeb.RemoteGateComponents

  @doc """
  The default `:github_issues` assign — modal closed, filter "open".
  """
  def idle_issues, do: %{status: :idle, error: nil, state_filter: "open", issues: []}

  @doc """
  Kicks off async upstream detection for an active existing repo on a usable
  node. The result arrives as `{:github_status_result, path, node, result}`.
  """
  def maybe_check(socket) do
    %{
      active_project_path: path,
      task_mode: mode,
      github_status: status,
      current_node: current_node
    } = socket.assigns

    if connected?(socket) and usable_node?(socket) and is_binary(path) and
         mode != "genesis_new" and is_nil(status) do
      runner = Application.get_env(:evo_dash, :github_runner) || (&NodeContext.github_upstream/2)

      socket
      |> assign(:github_status, %{state: :checking, owner: nil, repo: nil})
      |> dispatch(:github_status_request, {:github_status_result, path, current_node}, fn ->
        runner.(current_node, path)
      end)
    else
      socket
    end
  end

  @doc """
  Applies the current upstream-detection result; stale or unscoped results
  are ignored. Failed checks hide the top-bar button.
  """
  def handle_status_result(socket, path, result_node, {:github_request, scope, result}) do
    if current_request?(socket, :github_status_request, scope, path, result_node) and
         match?(%{state: :checking}, socket.assigns[:github_status]) do
      status =
        case result do
          {:ok, %{gh_available: true, owner: owner, repo: repo}}
          when is_binary(owner) and is_binary(repo) ->
            %{state: :ok, owner: owner, repo: repo}

          _ ->
            %{state: :error, owner: nil, repo: nil}
        end

      socket
      |> assign(:github_status_request, nil)
      |> assign(:github_status, status)
    else
      socket
    end
  end

  def handle_status_result(socket, _path, _result_node, _result), do: socket

  @doc """
  Opens the issues modal and fetches the default "open" list on a usable node.
  Results keep the `{:github_issues_result, path, node, state, result}` shape.
  """
  def open_modal(socket) do
    %{active_project_path: path, current_node: current_node} = socket.assigns

    if usable_node?(socket) and is_binary(path) do
      socket
      |> assign(:github_modal_open, true)
      |> assign(:github_fixing, nil)
      |> assign(:github_fix_request, nil)
      |> fetch_issues(path, current_node, "open")
    else
      socket
    end
  end

  @doc """
  Closes the modal and invalidates its pending list and fix requests.
  """
  def close_modal(socket) do
    socket
    |> assign(:github_modal_open, false)
    |> assign(:github_issues, idle_issues())
    |> assign(:github_fixing, nil)
    |> assign(:github_issues_request, nil)
    |> assign(:github_fix_request, nil)
  end

  @doc """
  Re-fetches the issue list with a new "open"/"closed"/"all" state filter.
  """
  def filter_state(socket, state) when state in ["open", "closed", "all"] do
    %{active_project_path: path, current_node: current_node, github_modal_open: open?} =
      socket.assigns

    if open? and usable_node?(socket) and is_binary(path) do
      fetch_issues(socket, path, current_node, state)
    else
      socket
    end
  end

  def filter_state(socket, _state), do: socket

  @doc """
  Fetches a positive issue number's Markdown in the background. Results keep
  the `{:github_fix_result, path, node, number, result}` message shape.
  """
  def fix_issue(socket, number) when is_binary(number) do
    %{active_project_path: path, current_node: current_node, github_modal_open: open?} =
      socket.assigns

    with {issue_number, ""} when issue_number > 0 <- Integer.parse(number),
         true <- open? and usable_node?(socket) and is_binary(path),
         false <- socket.assigns[:github_fixing] == issue_number do
      runner =
        Application.get_env(:evo_dash, :github_issue_markdown_runner) ||
          (&NodeContext.github_issue_markdown/3)

      socket
      |> assign(:github_fixing, issue_number)
      |> dispatch(
        :github_fix_request,
        {:github_fix_result, path, current_node, issue_number},
        fn -> runner.(current_node, path, issue_number) end
      )
    else
      _ -> socket
    end
  end

  def fix_issue(socket, _number), do: socket

  @doc """
  Applies only the current open modal's issue-list request, matching its node,
  target, project and filter. Older requests for the same filter are dropped.
  """
  def handle_issues_result(socket, path, result_node, state, {:github_request, scope, result}) do
    issues = socket.assigns.github_issues

    if current_request?(socket, :github_issues_request, scope, path, result_node) and
         socket.assigns.github_modal_open and issues.status == :loading and
         state == issues.state_filter do
      issues =
        case result do
          {:ok, list} when is_list(list) ->
            %{issues | status: :ok, error: nil, issues: list}

          {:error, reason} ->
            %{issues | status: :error, error: reason, issues: []}

          _ ->
            %{issues | status: :error, error: :fetch_failed, issues: []}
        end

      socket
      |> assign(:github_issues_request, nil)
      |> assign(:github_issues, issues)
    else
      socket
    end
  end

  def handle_issues_result(socket, _path, _result_node, _state, _result), do: socket

  @doc """
  Starts a fix task only for the current open modal's in-flight issue fetch.
  Closing/reopening the modal or superseding the fix invalidates older results.
  """
  def handle_fix_result(socket, path, result_node, number, {:github_request, scope, result}) do
    if current_request?(socket, :github_fix_request, scope, path, result_node) and
         socket.assigns.github_modal_open and is_integer(number) and number > 0 and
         socket.assigns[:github_fixing] == number do
      socket =
        socket
        |> assign(:github_fixing, nil)
        |> assign(:github_fix_request, nil)

      case result do
        {:ok, markdown} when is_binary(markdown) ->
          start_fix_task(socket, number, markdown)

        {:error, reason} ->
          put_flash(socket, :error, GitHubComponents.error_message(reason))

        _ ->
          put_flash(socket, :error, GitHubComponents.error_message(:fetch_failed))
      end
    else
      socket
    end
  end

  def handle_fix_result(socket, _path, _result_node, _number, _result), do: socket

  defp fetch_issues(socket, path, current_node, state) do
    runner =
      Application.get_env(:evo_dash, :github_issues_runner) ||
        (&NodeContext.list_github_issues/3)

    socket
    |> assign(:github_issues, %{
      status: :loading,
      error: nil,
      state_filter: state,
      issues: []
    })
    |> dispatch(:github_issues_request, {:github_issues_result, path, current_node, state}, fn ->
      runner.(current_node, path, state: state)
    end)
  end

  # Keep parent message tuples unchanged; only their opaque result carries
  # request identity. Target ids matter even when two targets share a BEAM node.
  defp dispatch(socket, key, tag, fun) do
    scope = {make_ref(), socket.assigns[:current_node_id]}
    parent = self()

    deliver = fn result ->
      send(parent, Tuple.insert_at(tag, tuple_size(tag), {:github_request, scope, result}))
    end

    case SafeCall.run(fn ->
           Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
             deliver.(guarded_result(fun))
           end)
         end) do
      {:ok, {:ok, _pid}} -> :ok
      {:ok, {:error, reason}} -> deliver.({:error, reason})
      {:error, reason} -> deliver.({:error, reason})
    end

    assign(socket, key, scope)
  end

  defp guarded_result(fun) do
    case SafeCall.run(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_request?(socket, key, {ref, target_id} = scope, path, result_node)
       when is_reference(ref) do
    usable_node?(socket) and socket.assigns[key] == scope and
      target_id == socket.assigns[:current_node_id] and
      path == socket.assigns.active_project_path and result_node == socket.assigns.current_node
  end

  defp current_request?(_socket, _key, _scope, _path, _result_node), do: false

  # A selected but disconnected target resolves to the LOCAL node. Never use
  # remote? alone to choose a registry: it is false in that pending context.
  defp usable_node?(socket) do
    if is_nil(socket.assigns[:current_node_id]) do
      socket.assigns[:current_node] == node()
    else
      socket.assigns[:current_node] not in [nil, node()] and
        not RemoteGateComponents.gate_active?(socket.assigns)
    end
  end

  # Same LaunchOptions policy as task_submit: canonical model-spec locking,
  # custom agent and quality, with foreign repos preserved. The objective is
  # an agent prompt, NOT gettext; Markdown includes title/URL/state/body.
  defp start_fix_task(socket, number, markdown) do
    if usable_node?(socket) do
      do_start_fix_task(socket, number, markdown)
    else
      put_flash(socket, :error, gettext("Connect to the remote node before starting a task."))
    end
  end

  defp do_start_fix_task(socket, number, markdown) do
    %{github_issues: %{issues: issues}, active_project_path: path} = socket.assigns

    title =
      case Enum.find(issues, &(&1[:number] == number)) do
        nil -> "GitHub issue ##{number}"
        issue -> issue_title(issue, number)
      end

    opts = [path: path, mode: "simple", objective: "Fix #{title}\n\n#{markdown}"]

    foreign_repos = socket.assigns[:foreign_repos] || []

    opts =
      if foreign_repos != [],
        do: Keyword.put(opts, :foreign_repos, foreign_repos),
        else: opts

    start_result =
      with {:ok, opts} <- LaunchOptions.apply(opts, socket.assigns) do
        guarded_result(fn ->
          if is_nil(socket.assigns[:current_node_id]) do
            TaskRegistry.start_task(:evolve, opts)
          else
            NodeContext.start_task(socket.assigns.current_node, :evolve, opts)
          end
        end)
      end

    case start_result do
      {:ok, task} ->
        socket
        |> put_flash(
          :info,
          gettext("%{type} task started with ID: %{id}", type: "Evolve", id: task.id)
        )
        |> NodeAware.assign_active_tasks()
        |> close_modal()

      {:error, reason} ->
        put_flash(
          socket,
          :error,
          gettext("Failed to start task: %{reason}", reason: inspect(reason))
        )
    end
  end

  defp issue_title(issue, number) do
    title = Map.get(issue, :title)

    if is_binary(title) and String.trim(title) != "" do
      title
    else
      "GitHub issue ##{number}"
    end
  end
end
