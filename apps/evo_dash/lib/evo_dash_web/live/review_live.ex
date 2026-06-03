defmodule EvoDashWeb.ReviewLive do
  use EvoDashWeb, :live_view
  alias EvoDash.TaskRegistry
  import EvoDashWeb.ReviewComponents

  @impl true
  def mount(%{"task_id" => task_id}, _session, socket) do
    Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

    config_status =
      try do
        EvoGit.Config.config_status()
      rescue
        _ -> %{missing: [], warnings: [], ok?: true}
      catch
        _, _ -> %{missing: [], warnings: [], ok?: true}
      end

    socket =
      socket
      |> assign(:task_id, task_id)
      |> assign(:config_status, config_status)
      |> assign(:creating_pr, false)
      |> assign(:action_error, nil)
      |> assign(:selected_file, nil)
      |> load_task_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:review} config_status={@config_status}>
      <div class="animate-fade-in-up">
        <%= if @task do %>
          <.review_header task={@task} review_status={@review_status} />

          <div class="mt-6 space-y-6">
            <%= if @action_error do %>
              <div class="alert alert-error animate-scale-in">
                <.icon name="hero-exclamation-circle" class="size-5" />
                <span>{@action_error}</span>
              </div>
            <% end %>

            <.action_buttons
              review_status={@review_status}
              task_id={@task_id}
              branch_exists={@branch_exists}
              pr_url={@pr_url}
              creating_pr={@creating_pr}
            />

            <%= if @agent_summary do %>
              <.summary_section result={@agent_summary} />
            <% end %>

            <%= if @files != [] do %>
              <.file_list
                files={@files}
                total_additions={@total_additions}
                total_deletions={@total_deletions}
              />
            <% end %>

            <%= if @diff do %>
              <.diff_viewer diff={@diff} />
            <% end %>
          </div>
        <% else %>
          <!-- Task not found -->
          <div class="flex flex-col items-center justify-center min-h-[50vh] text-center">
            <div class="bg-error/10 text-error p-6 rounded-2xl mb-6">
              <.icon name="hero-exclamation-circle" class="size-12" />
            </div>
            <h2 class="text-xl font-bold mb-2">{gettext("Task Not Found")}</h2>
            <p class="text-base-content/60 mb-6">
              {gettext("The task you're looking for doesn't exist or has been deleted.")}
            </p>
            <.link navigate={~p"/"} class="btn btn-primary">
              <.icon name="hero-home" class="size-5" /> {gettext("Back to Dashboard")}
            </.link>
          </div>
        <% end %>
      </div>
    </EvoDashWeb.Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Event Handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("merge", _params, socket) do
    %{task_id: task_id, repo_path: repo_path} = socket.assigns

    try do
      result_data = result_from_task(socket.assigns.task)
      branch_name = Map.get(result_data, :branch_name)
      commit_sha = Map.get(result_data, :commit_sha)

      if branch_name && socket.assigns.branch_exists && commit_sha do
        case EvoGit.Adapters.Git.merge(repo_path, commit_sha) do
          {:ok, _output} ->
            EvoGit.Adapters.Git.delete_branch(repo_path, branch_name)

          {:conflict, output} ->
            # Abort the merge on conflict
            System.cmd("git", ["merge", "--abort"], cd: repo_path, stderr_to_stdout: true)

            throw(
              {:action_error,
               gettext("Merge conflict detected. Please resolve conflicts manually.") <>
                 "\n\n#{output}"}
            )

          {:error, _code, output} ->
            throw({:action_error, gettext("Merge failed") <> ": #{output}"})
        end
      end

      TaskRegistry.update_review_status(task_id, :merged)

      socket =
        socket
        |> put_flash(:success, gettext("Changes merged successfully"))
        |> assign(:action_error, nil)
        |> load_task_data()

      {:noreply, socket}
    rescue
      e ->
        {:noreply, assign(socket, :action_error, Exception.message(e))}
    catch
      {:action_error, msg} ->
        {:noreply, assign(socket, :action_error, msg)}
    end
  end

  @impl true
  def handle_event("reject", _params, socket) do
    %{task_id: task_id, repo_path: repo_path} = socket.assigns

    try do
      result_data = result_from_task(socket.assigns.task)
      branch_name = Map.get(result_data, :branch_name)

      if branch_name && socket.assigns.branch_exists do
        EvoGit.Adapters.Git.delete_branch(repo_path, branch_name)
      end

      TaskRegistry.update_review_status(task_id, :rejected)

      socket =
        socket
        |> put_flash(:success, gettext("Changes rejected"))
        |> assign(:action_error, nil)
        |> load_task_data()

      {:noreply, socket}
    rescue
      e ->
        {:noreply, assign(socket, :action_error, Exception.message(e))}
    end
  end

  @impl true
  def handle_event("continue", _params, socket) do
    %{task_id: task_id, repo_path: repo_path} = socket.assigns

    try do
      result_data = result_from_task(socket.assigns.task)
      commit_sha = Map.get(result_data, :commit_sha)

      TaskRegistry.update_review_status(task_id, :continued)

      socket =
        socket
        |> put_flash(:info, gettext("Continuing from commit"))
        |> push_navigate(
          to:
            ~p"/?starting_commit=#{commit_sha}&path=#{URI.encode_www_form(repo_path || "")}"
        )

      {:noreply, socket}
    rescue
      e ->
        {:noreply, assign(socket, :action_error, Exception.message(e))}
    end
  end

  @impl true
  def handle_event("create_pr", _params, socket) do
    %{task: task, repo_path: repo_path} = socket.assigns

    try do
      result_data = result_from_task(task)
      branch_name = Map.get(result_data, :branch_name)
      objective = task_objective(task)
      agent_result = Map.get(result_data, :result, "")

      socket = assign(socket, :creating_pr, true)

      if branch_name && repo_path do
        case EvoGit.Runtime.PullRequest.try_create(repo_path, branch_name, objective, agent_result) do
          {pr_url, _title} when is_binary(pr_url) ->
            socket =
              socket
              |> assign(:creating_pr, false)
              |> assign(:pr_url, pr_url)
              |> assign(:action_error, nil)
              |> put_flash(:success, gettext("Pull request created successfully"))

            {:noreply, socket}

          {nil, _} ->
            socket =
              socket
              |> assign(:creating_pr, false)
              |> assign(:action_error, gettext("Failed to create pull request. Check that 'gh' CLI is installed and authenticated."))

            {:noreply, socket}
        end
      else
        socket =
          socket
          |> assign(:creating_pr, false)
          |> assign(:action_error, gettext("No branch found to create PR from."))

        {:noreply, socket}
      end
    rescue
      e ->
        socket =
          socket
          |> assign(:creating_pr, false)
          |> assign(:action_error, Exception.message(e))

        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub Handler
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:tasks_updated}, socket) do
    {:noreply, load_task_data(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp load_task_data(socket) do
    task_id = socket.assigns.task_id
    task = TaskRegistry.get_task(task_id)

    if task do
      result_data = result_from_task(task)

      review_status = Map.get(task, :review_status)
      repo_path = task.opts[:path]

      {diff, files, total_additions, total_deletions, branch_exists} =
        compute_diff_data(result_data, repo_path)

      pr_url = if result_data, do: Map.get(result_data, :pr_url), else: nil
      agent_summary = if result_data, do: Map.get(result_data, :result), else: nil

      socket
      |> assign(:task, task)
      |> assign(:review_status, review_status)
      |> assign(:repo_path, repo_path)
      |> assign(:diff, diff)
      |> assign(:files, files)
      |> assign(:total_additions, total_additions)
      |> assign(:total_deletions, total_deletions)
      |> assign(:branch_exists, branch_exists)
      |> assign(:pr_url, pr_url)
      |> assign(:agent_summary, agent_summary)
    else
      socket
      |> assign(:task, nil)
      |> assign(:review_status, nil)
      |> assign(:diff, nil)
      |> assign(:files, [])
      |> assign(:total_additions, 0)
      |> assign(:total_deletions, 0)
      |> assign(:branch_exists, false)
      |> assign(:pr_url, nil)
      |> assign(:agent_summary, nil)
      |> assign(:repo_path, nil)
    end
  end

  defp compute_diff_data(result_data, repo_path) do
    try do
      cond do
        is_nil(result_data) or is_nil(repo_path) ->
          {nil, [], 0, 0, false}

        Map.get(result_data, :no_changes) ->
          {nil, [], 0, 0, false}

        true ->
          commit_sha = Map.get(result_data, :commit_sha)
          base_sha = Map.get(result_data, :base_sha)
          branch_name = Map.get(result_data, :branch_name)

          branch_exists =
            branch_name && EvoGit.Adapters.Git.branch_exists?(repo_path, branch_name)

          # Resolve base_sha — if not in result, use merge_base
          base_sha =
            cond do
              base_sha ->
                base_sha

              commit_sha ->
                case EvoGit.Adapters.Git.merge_base(repo_path, commit_sha, "HEAD") do
                  {:ok, sha} -> sha
                  _ -> nil
                end

              true ->
                nil
            end

          if commit_sha && base_sha && commit_sha != base_sha do
            # Get full diff
            diff =
              case EvoGit.Adapters.Git.diff(repo_path, base_sha, commit_sha) do
                {:ok, output} -> output
                _ -> nil
              end

            # Get diff stat
            files =
              case EvoGit.Adapters.Git.diff_stat(repo_path, base_sha, commit_sha) do
                {:ok, stat_output} -> parse_diff_stat(stat_output)
                _ -> []
              end

            total_additions = Enum.reduce(files, 0, fn f, acc -> acc + f.additions end)
            total_deletions = Enum.reduce(files, 0, fn f, acc -> acc + f.deletions end)

            {diff, files, total_additions, total_deletions, branch_exists}
          else
            {nil, [], 0, 0, branch_exists || false}
          end
      end
    rescue
      _ -> {nil, [], 0, 0, false}
    catch
      _, _ -> {nil, [], 0, 0, false}
    end
  end

  defp parse_diff_stat(stat_output) do
    stat_output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "|"))
    |> Enum.map(fn line ->
      [path | rest] = String.split(line, "|", parts: 2)
      path = String.trim(path)
      change_part = List.first(rest) |> to_string() |> String.trim()

      additions = String.graphemes(change_part) |> Enum.count(&(&1 == "+"))
      deletions = String.graphemes(change_part) |> Enum.count(&(&1 == "-"))

      %{path: path, additions: additions, deletions: deletions}
    end)
  end

  defp result_from_task(%{result: {:ok, data}}) when is_map(data), do: data
  defp result_from_task(_), do: nil

  defp task_objective(%{type: :genesis, opts: opts}) when is_list(opts), do: opts[:prompt] || ""
  defp task_objective(%{type: :evolve, opts: opts}) when is_list(opts), do: opts[:objective] || ""
  defp task_objective(_), do: ""
end
