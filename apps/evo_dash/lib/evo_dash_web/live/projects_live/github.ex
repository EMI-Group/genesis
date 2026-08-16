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
  it) and reports back via a message that is stale-guarded on project path +
  node before being applied.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, connected?: 1]

  alias EvoGit.TaskRegistry

  alias EvoDash.NodeContext
  alias EvoDashWeb.GitHubComponents
  alias EvoDashWeb.LiveHooks.NodeAware

  @doc """
  The default `:github_issues` assign — modal closed, filter "open".
  """
  def idle_issues, do: %{status: :idle, error: nil, state_filter: "open", issues: []}

  @doc """
  Kicks off the async GitHub-upstream detection when a project is active and
  its task mode implies an existing git repo (`genesis_new` has no repo to
  check). No-ops when a status is already present, so a check is spawned only
  once per project activation; the result arrives later as a
  `{:github_status_result, path, node, result}` message.
  """
  def maybe_check(socket) do
    %{
      active_project_path: path,
      task_mode: mode,
      github_status: status,
      current_node: current_node
    } = socket.assigns

    if connected?(socket) and is_binary(path) and mode != "genesis_new" and is_nil(status) do
      parent = self()

      # Test seam: the runner is resolved from application env at spawn time
      # so tests can stub out the real (gh-touching) upstream check. The
      # default is the real `EvoDash.NodeContext.github_upstream/2`.
      runner = Application.get_env(:evo_dash, :github_runner) || (&NodeContext.github_upstream/2)

      socket = assign(socket, :github_status, %{state: :checking, owner: nil, repo: nil})

      Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
        result =
          try do
            runner.(current_node, path)
          rescue
            # The repo can vanish mid-check (e.g. temp-repo teardown in
            # tests) — report a failed check instead of crashing silently and
            # leaving the status stuck at :checking.
            _ -> {:error, :check_failed}
          end

        send(parent, {:github_status_result, path, current_node, result})
      end)

      socket
    else
      socket
    end
  end

  @doc """
  Applies an async upstream-detection result to `:github_status`, ignoring
  stale results (different project path or node). A successful check with
  `gh_available: true` marks the status `:ok` (which renders the top-bar
  GitHub button); anything else marks it `:error` (button hidden — there is
  deliberately no error UI in the top bar).
  """
  def handle_status_result(socket, path, result_node, result) do
    %{active_project_path: active_path, current_node: current_node} = socket.assigns

    if path != active_path or result_node != current_node do
      socket
    else
      status =
        case result do
          {:ok, %{gh_available: true, owner: owner, repo: repo}}
          when is_binary(owner) and is_binary(repo) ->
            %{state: :ok, owner: owner, repo: repo}

          _ ->
            %{state: :error, owner: nil, repo: nil}
        end

      assign(socket, :github_status, status)
    end
  end

  @doc """
  Opens the issues modal and fetches the issue list with the default
  "open" filter. The list result arrives as a
  `{:github_issues_result, path, node, state, result}` message.
  """
  def open_modal(socket) do
    %{active_project_path: path, current_node: current_node} = socket.assigns

    if is_binary(path) do
      socket
      |> assign(:github_modal_open, true)
      |> assign(:github_fixing, nil)
      |> fetch_issues(path, current_node, "open")
    else
      socket
    end
  end

  @doc """
  Closes the issues modal and resets the issue list to idle.
  """
  def close_modal(socket) do
    socket
    |> assign(:github_modal_open, false)
    |> assign(:github_issues, idle_issues())
    |> assign(:github_fixing, nil)
  end

  @doc """
  Re-fetches the issue list with a new state filter
  (`"open"`/`"closed"`/`"all"`), via the same async fetch as `open_modal/1`.
  """
  def filter_state(socket, state) when state in ["open", "closed", "all"] do
    %{active_project_path: path, current_node: current_node, github_modal_open: open?} =
      socket.assigns

    if open? and is_binary(path) do
      fetch_issues(socket, path, current_node, state)
    else
      socket
    end
  end

  def filter_state(socket, _state), do: socket

  @doc """
  Fetches a single issue's Markdown in the background (the per-row "Fix"
  button flow). `number` arrives as a string from `phx-value-number`. The
  result arrives as a `{:github_fix_result, path, node, number, result}`
  message.
  """
  def fix_issue(socket, number) do
    %{active_project_path: path, current_node: current_node, github_modal_open: open?} =
      socket.assigns

    with {issue_number, ""} <- Integer.parse(number),
         true <- open?,
         true <- is_binary(path) do
      parent = self()

      # Test seam: resolved from application env at spawn time (same pattern
      # as `:github_runner`). The default is the real
      # `EvoDash.NodeContext.github_issue_markdown/3`.
      runner =
        Application.get_env(:evo_dash, :github_issue_markdown_runner) ||
          (&NodeContext.github_issue_markdown/3)

      Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
        result =
          try do
            runner.(current_node, path, issue_number)
          rescue
            _ -> {:error, :fetch_failed}
          end

        send(parent, {:github_fix_result, path, current_node, issue_number, result})
      end)

      assign(socket, :github_fixing, issue_number)
    else
      _ -> socket
    end
  end

  @doc """
  Applies an async issue-list result, ignoring stale results (different
  project path, node, or filter state — out-of-order responses for older
  filters are dropped). `{:ok, issues}` marks the list `:ok`; `{:error,
  reason}` marks it `:error` with the reason surfaced in the modal.
  """
  def handle_issues_result(socket, path, result_node, state, result) do
    %{
      active_project_path: active_path,
      current_node: current_node,
      github_issues: issues
    } = socket.assigns

    if path != active_path or result_node != current_node or state != issues.state_filter do
      socket
    else
      case result do
        {:ok, list} when is_list(list) ->
          assign(socket, :github_issues, %{issues | status: :ok, error: nil, issues: list})

        {:error, reason} ->
          assign(socket, :github_issues, %{issues | status: :error, error: reason, issues: []})

        _ ->
          socket
      end
    end
  end

  @doc """
  Applies an async issue-markdown fetch result: on `{:ok, markdown}` starts
  an `:evolve` fix task (mirroring `task_submit`'s start flow) and closes the
  modal; on `{:error, reason}` flashes the surfaced error. `:github_fixing`
  is cleared on every non-stale path. Stale results (different project path
  or node) are dropped untouched.
  """
  def handle_fix_result(socket, path, result_node, number, result) do
    %{active_project_path: active_path, current_node: current_node} = socket.assigns

    if path != active_path or result_node != current_node do
      socket
    else
      socket = assign(socket, :github_fixing, nil)

      case result do
        {:ok, markdown} when is_binary(markdown) ->
          start_fix_task(socket, number, markdown)

        {:error, reason} ->
          put_flash(socket, :error, GitHubComponents.error_message(reason))
      end
    end
  end

  # Spawns the issue-list fetch for `state` in a supervised Task (same async
  # pattern as `EvoDashWeb.ReviewLive.MergeCheck`). The requested filter is
  # echoed back with the result so stale-filter responses are dropped by
  # `handle_issues_result/5`.
  defp fetch_issues(socket, path, current_node, state) do
    parent = self()

    runner =
      Application.get_env(:evo_dash, :github_issues_runner) ||
        (&NodeContext.list_github_issues/3)

    socket =
      assign(socket, :github_issues, %{
        status: :loading,
        error: nil,
        state_filter: state,
        issues: []
      })

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result =
        try do
          runner.(current_node, path, state: state)
        rescue
          _ -> {:error, :fetch_failed}
        end

      send(parent, {:github_issues_result, path, current_node, state, result})
    end)

    socket
  end

  # Starts the `:evolve` fix task exactly following the existing `task_submit`
  # start flow: path/mode/objective opts, foreign repos and the selected model
  # id threaded when present, local vs remote start split. The objective is an
  # agent prompt — plain string interpolation, NOT gettext. The markdown
  # already embeds the issue's title, URL, state, labels, and body so the
  # agent has full context.
  defp start_fix_task(socket, number, markdown) do
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

    selected_model_id = socket.assigns[:selected_model_id]

    opts =
      if is_binary(selected_model_id) and selected_model_id != "",
        do: Keyword.put(opts, :model_id, selected_model_id),
        else: opts

    start_result =
      if socket.assigns.remote? do
        NodeContext.start_task(socket.assigns.current_node, :evolve, opts)
      else
        TaskRegistry.start_task(:evolve, opts)
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
