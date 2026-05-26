defmodule EvoDashWeb.DashboardLive do
  use EvoDashWeb, :live_view
  alias EvoDash.TaskRegistry

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.flash_group flash={@flash} />

    <div class="container mx-auto px-4 py-8 max-w-6xl">
      <.header>
        EvoGit Dashboard
        <:subtitle>
          Manage your evolutionary software development tasks
        </:subtitle>
        <:actions>
          <a href="/agents" class="btn btn-sm btn-ghost">
            <.icon name="hero-server" class="size-4" /> Agents
          </a>
        </:actions>
      </.header>

      <%= if @projects != [] do %>
        <div class="mt-4">
          <EvoDashWeb.DashboardComponents.project_tabs
            projects={@projects}
            active_project_id={@active_project_id}
          />
        </div>
      <% end %>

      <%= if @active_project_id == nil do %>
        <div class="mt-6">
          <EvoDashWeb.DashboardComponents.landing_page />
        </div>
      <% else %>
        <% project = Enum.find(@projects, &(&1.id == @active_project_id)) %>

        <div class="mt-6 mb-8">
          <EvoDashWeb.DashboardComponents.task_form
            path={project.path}
            prompt={@task_prompt}
            mode={@task_mode}
            concurrency={@task_concurrency}
            retries={@task_retries}
            agent_max_retries={@task_agent_max_retries}
            detected_mode={@detected_mode}
            mode_overridden={@mode_overridden}
            project_active={true}
            foreign_repos={@foreign_repos}
          />
        </div>

        <div class="divider">Running & Recent Tasks</div>

        <div class="space-y-4">
          <%= if @tasks == [] do %>
            <div class="text-center py-12 text-base-content/50">
              <.icon name="hero-inbox" class="size-16 mx-auto mb-4" />
              <p>No tasks yet for this project. Start by creating a new task.</p>
            </div>
          <% else %>
            <%= for task <- Enum.sort_by(@tasks, & &1.started_at, :desc) do %>
              <EvoDashWeb.DashboardComponents.task_card
                task={task}
                show_details={MapSet.member?(@expanded_task_ids, task.id)}
              />
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>

    <!-- Full Result Modal -->
    <%= if @selected_result do %>
      <div class="modal modal-open bg-black/50">
        <div class="modal-box w-11/12 max-w-5xl">
          <%= case @selected_result do %>
            <% {:ok, %{result: result, no_changes: true}} when is_binary(result) -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-information-circle" class="size-5 text-warning" />
                No Changes
              </h3>
              <div class="bg-warning/10 border border-warning/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <p class="text-sm text-warning">The agent completed without making any changes to the codebase.</p>
              </div>
              <div class="mt-4 bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <h4 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide">Agent Message</h4>
                <pre class="text-sm whitespace-pre-wrap break-words"><%= result %></pre>
              </div>

            <% {:ok, %{result: result, branch_name: branch_name} = data} when is_binary(result) -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-5 text-success" />
                Agent Message
              </h3>
              <div class="flex flex-wrap gap-2 mb-4">
                <%= if branch_name do %>
                  <span class="badge badge-primary font-mono text-sm">
                    <.icon name="hero-code-bracket-square" class="size-4 mr-1" />
                    <%= branch_name %>
                  </span>
                <% end %>
                <%= if Map.get(data, :pr_url) do %>
                  <a href={Map.get(data, :pr_url)} target="_blank" class="badge badge-success font-mono text-sm hover:opacity-80 transition-opacity">
                    <.icon name="hero-arrow-top-right-on-square" class="size-4 mr-1" />
                    View PR
                  </a>
                <% end %>
              </div>
              <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm whitespace-pre-wrap break-words"><%= result %></pre>
              </div>

            <% {%{result: result}} when is_binary(result) -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-5 text-success" />
                Agent Message
              </h3>
              <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm whitespace-pre-wrap break-words"><%= result %></pre>
              </div>

            <% {:error, reason} -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-x-circle" class="size-5 text-error" />
                Task Failed
              </h3>
              <div class="bg-error/10 border border-error/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm text-error whitespace-pre-wrap break-words"><%= inspect(reason, limit: :infinity) %></pre>
              </div>

            <% {:exit, reason} -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-x-circle" class="size-5 text-error" />
                Task Crashed
              </h3>
              <div class="bg-error/10 border border-error/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm text-error whitespace-pre-wrap break-words"><%= inspect(reason, limit: :infinity) %></pre>
              </div>

            <% {:ok, %{result: result}} -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-5 text-success" />
                Agent Message
              </h3>
              <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm whitespace-pre-wrap break-words"><%= inspect(result, limit: :infinity) %></pre>
              </div>

            <% %{result: result} -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-5 text-success" />
                Agent Message
              </h3>
              <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm whitespace-pre-wrap break-words"><%= inspect(result, limit: :infinity) %></pre>
              </div>

            <% _ -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-information-circle" class="size-5 text-base-content/70" />
                Result
              </h3>
              <div class="bg-base-200 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm overflow-x-auto"><%= inspect(@selected_result, pretty: true, limit: :infinity) %></pre>
              </div>
          <% end %>

          <div class="modal-action">
            <button class="btn" phx-click="close_result_modal">Close</button>
          </div>
        </div>

        <div class="modal-backdrop" phx-click="close_result_modal">
          <button class="cursor-default">close</button>
        </div>
      </div>
    <% end %>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :refresh_tasks)
    end

    tasks = TaskRegistry.list_tasks()

    socket =
      socket
      |> assign(:tasks, tasks)
      |> assign(:expanded_task_ids, MapSet.new())
      |> assign(:selected_result, nil)
      |> assign(:projects, [])
      |> assign(:active_project_id, nil)
      |> assign(:detected_mode, nil)
      |> assign(:mode_overridden, false)
      |> assign_form_defaults()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_tasks, socket) do
    tasks =
      case socket.assigns.active_project_id do
        nil ->
          TaskRegistry.list_tasks()

        _ ->
          project =
            Enum.find(socket.assigns.projects, &(&1.id == socket.assigns.active_project_id))

          if project,
            do: TaskRegistry.list_tasks_by_repo(project.path),
            else: TaskRegistry.list_tasks()
      end

    {:noreply, assign(socket, :tasks, tasks)}
  end

  @impl true
  def handle_event("open_project", %{"path" => path}, socket) do
    path = String.trim(path)

    if path == "" do
      {:noreply, put_flash(socket, :error, "Please enter a repository path")}
    else
      expanded = Path.expand(path)

      existing = Enum.find(socket.assigns.projects, &(Path.expand(&1.path) == expanded))

      if existing do
        detected = detect_task_mode(existing.path)

        socket =
          socket
          |> assign(:active_project_id, existing.id)
          |> assign_tasks_for_project(existing.path)
          |> assign(:detected_mode, detected)
          |> assign(:mode_overridden, false)
          |> assign_task_mode_from_detection()
          |> assign(:foreign_repos, [])

        {:noreply, socket}
      else
        project = %{
          id: generate_project_id(),
          path: path,
          name: project_name_from_path(path)
        }

        detected = detect_task_mode(path)

        socket =
          socket
          |> assign(:projects, socket.assigns.projects ++ [project])
          |> assign(:active_project_id, project.id)
          |> assign_tasks_for_project(project.path)
          |> assign(:detected_mode, detected)
          |> assign(:mode_overridden, false)
          |> assign_task_mode_from_detection()
          |> assign(:foreign_repos, [])

        {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("switch_project", %{"project_id" => project_id}, socket) do
    project = Enum.find(socket.assigns.projects, &(&1.id == project_id))

    if project do
      detected = detect_task_mode(project.path)

      socket =
        socket
        |> assign(:active_project_id, project_id)
        |> assign_tasks_for_project(project.path)
        |> assign(:detected_mode, detected)
        |> assign(:mode_overridden, false)
        |> assign_task_mode_from_detection()
        |> assign(:foreign_repos, [])

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_project", %{"project_id" => project_id}, socket) do
    projects = Enum.reject(socket.assigns.projects, &(&1.id == project_id))

    new_active =
      if socket.assigns.active_project_id == project_id do
        case List.last(projects) do
          nil -> nil
          p -> p.id
        end
      else
        socket.assigns.active_project_id
      end

    socket =
      socket
      |> assign(:projects, projects)
      |> assign(:active_project_id, new_active)

    socket =
      case new_active do
        nil ->
          assign(socket, :tasks, TaskRegistry.list_tasks())

        _ ->
          project = Enum.find(projects, &(&1.id == new_active))
          assign_tasks_for_project(socket, project.path)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("task_change", params, socket) do
    new_mode = params["mode"] || socket.assigns.task_mode

    new_overridden =
      if params["mode"] && params["mode"] != "" do
        true
      else
        socket.assigns.mode_overridden
      end

    {:noreply,
     socket
     |> assign(:task_mode, new_mode)
     |> assign(:task_prompt, params["prompt"] || socket.assigns.task_prompt)
     |> assign(:task_concurrency, params["concurrency"] || socket.assigns.task_concurrency)
     |> assign(:task_retries, params["retries"] || socket.assigns.task_retries)
     |> assign(:task_agent_max_retries, params["agent_max_retries"] || socket.assigns.task_agent_max_retries)
     |> assign(:mode_overridden, new_overridden)}
  end

  @impl true
  def handle_event(
        "task_submit",
        %{
          "prompt" => prompt,
          "mode" => combined_mode,
          "concurrency" => concurrency,
          "retries" => retries,
          "agent_max_retries" => agent_max_retries
        } = params,
        socket
      ) do
    project = Enum.find(socket.assigns.projects, &(&1.id == socket.assigns.active_project_id))

    path =
      if project,
        do: project.path,
        else: params["path"] || File.cwd!()

    prompt = prompt || socket.assigns.task_prompt
    combined_mode = combined_mode || socket.assigns.task_mode
    concurrency = concurrency || socket.assigns.task_concurrency
    retries = retries || socket.assigns.task_retries
    agent_max_retries = agent_max_retries || socket.assigns.task_agent_max_retries

    {task_type, mode} =
      case combined_mode do
        "genesis_new" -> {:genesis, "new"}
        "genesis_existing" -> {:genesis, "existing"}
        "evolve_simple" -> {:evolve, "simple"}
        "evolve_complex" -> {:evolve, "complex"}
      end

    opts = [
      path: path,
      mode: mode,
      concurrency: String.to_integer(concurrency),
      retries: String.to_integer(retries),
      agent_max_retries: String.to_integer(agent_max_retries)
    ]

    opts =
      if task_type == :genesis do
        Keyword.put(opts, :prompt, prompt)
      else
        Keyword.put(opts, :objective, prompt)
      end

    foreign_repos = Map.get(params, "foreign_repos", [])
    opts = Keyword.put(opts, :foreign_repos, foreign_repos)

    case TaskRegistry.start_task(task_type, opts) do
      {:ok, task} ->
        new_tasks =
          if project,
            do: TaskRegistry.list_tasks_by_repo(project.path),
            else: TaskRegistry.list_tasks()

        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{String.capitalize(to_string(task_type))} task started with ID: #{task.id}"
         )
         |> assign(:tasks, new_tasks)
         |> assign(:task_prompt, prompt)
         |> assign(:task_mode, combined_mode)
         |> assign(:task_concurrency, concurrency)
         |> assign(:task_retries, retries)
         |> assign(:task_agent_max_retries, agent_max_retries)
         |> assign(:foreign_repos, [])}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start task: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_task", %{"task_id" => task_id}, socket) do
    case TaskRegistry.cancel_task(task_id) do
      :ok ->
        expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

        {:noreply,
         socket
         |> assign(:tasks, refresh_tasks_for_socket(socket))
         |> assign(:expanded_task_ids, expanded)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel task: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_task_details", %{"task_id" => task_id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_task_ids, task_id) do
        MapSet.delete(socket.assigns.expanded_task_ids, task_id)
      else
        MapSet.put(socket.assigns.expanded_task_ids, task_id)
      end

    {:noreply, assign(socket, :expanded_task_ids, expanded)}
  end

  @impl true
  def handle_event("view_full_result", %{"task_id" => task_id}, socket) do
    task = Enum.find(socket.assigns.tasks, &(&1.id == task_id))
    result = Map.get(task || %{}, :result)
    {:noreply, assign(socket, :selected_result, result)}
  end

  @impl true
  def handle_event("close_result_modal", _params, socket) do
    {:noreply, assign(socket, :selected_result, nil)}
  end

  @impl true
  def handle_event("add_foreign_repo", %{"new_foreign_repo" => path}, socket) do
    path = String.trim(path)

    if path != "" do
      expanded = Path.expand(path)
      foreign_repos = socket.assigns.foreign_repos ++ [expanded]
      {:noreply, assign(socket, :foreign_repos, foreign_repos)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_foreign_repo", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    foreign_repos = List.delete_at(socket.assigns.foreign_repos, idx)
    {:noreply, assign(socket, :foreign_repos, foreign_repos)}
  end

  # Private Helpers

  defp assign_form_defaults(socket) do
    socket
    |> assign(:task_prompt, "")
    |> assign(:task_mode, "genesis_new")
    |> assign(:task_concurrency, to_string(EvoGit.Defaults.max_concurrency()))
    |> assign(:task_retries, to_string(EvoGit.Defaults.max_retries()))
    |> assign(:task_agent_max_retries, to_string(EvoGit.Defaults.agent_max_retries()))
    |> assign(:foreign_repos, [])
  end

  defp assign_tasks_for_project(socket, path) do
    assign(socket, :tasks, TaskRegistry.list_tasks_by_repo(path))
  end

  defp assign_task_mode_from_detection(socket) do
    case socket.assigns.detected_mode do
      {mode, _desc} -> assign(socket, :task_mode, to_string(mode))
      nil -> socket
    end
  end

  defp refresh_tasks_for_socket(socket) do
    project = Enum.find(socket.assigns.projects, &(&1.id == socket.assigns.active_project_id))

    if project,
      do: TaskRegistry.list_tasks_by_repo(project.path),
      else: TaskRegistry.list_tasks()
  end

  defp detect_task_mode(path) do
    expanded = Path.expand(path)

    cond do
      !File.dir?(expanded) || dir_empty?(expanded) ->
        {:genesis_new, "Directory is empty or doesn't exist — will create a new codebase"}

      !File.exists?(Path.join(expanded, "CONTEXT.md")) ->
        {:genesis_existing, "No CONTEXT.md found — will analyze existing codebase"}

      true ->
        {:evolve_simple, "CONTEXT.md found — will evolve existing codebase"}
    end
  end

  defp dir_empty?(path) do
    case File.ls(path) do
      {:ok, []} -> true
      _ -> false
    end
  end

  defp generate_project_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp project_name_from_path(path) do
    path |> Path.expand() |> Path.basename()
  end
end
