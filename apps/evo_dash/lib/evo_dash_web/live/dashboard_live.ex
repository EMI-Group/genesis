defmodule EvoDashWeb.DashboardLive do
  use EvoDashWeb, :live_view
  alias EvoDash.TaskRegistry
  alias EvoGit.Core.ForeignRepo

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:dashboard} config_status={@config_status}>
      <div id="browser-notifications" class="animate-fade-in-up" phx-hook="BrowserNotifications">
        <p class="text-base-content/60 text-sm">{gettext("Manage your evolutionary software development tasks")}</p>
      </div>

      <%= if @active_project do %>
        <!-- Active Project State -->
        <div class="mt-4 mb-2 animate-fade-in-up animation-delay-100">
          <EvoDashWeb.DashboardComponents.project_tabs
            projects={@projects}
            active_project={@active_project}
          />
        </div>

        <%= if @show_open_project_form do %>
          <div class="mb-8 bg-base-200/50 rounded-xl p-4 sm:p-6 border border-base-200 animate-scale-in">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-folder-open" class="size-5 text-primary" /> {gettext("Open Another Project")}
              </h3>
              <button class="btn btn-ghost" phx-click="hide_open_project_form">
                <.icon name="hero-x-mark" class="size-4" /> {gettext("Cancel")}
              </button>
            </div>
            <.form for={%{}} phx-submit="open_project" class="flex flex-col sm:flex-row gap-3">
              <div class="relative flex-1">
                <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none text-base-content/40">
                  <.icon name="hero-folder" class="size-5" />
                </div>
                <input
                  type="text"
                  name="path"
                  class="input input-bordered w-full pl-10 pr-10 focus:outline-none focus:ring-2 focus:ring-primary/30 font-mono text-sm"
                  placeholder={gettext("/path/to/another/repo")}
                  autofocus
                  phx-hook="PathAutocomplete"
                  phx-change="path_input"
                  phx-debounce="150"
                  id="open-another-project-path-input"
                  list="path-suggestions-open"
                />
                <button
                  type="button"
                  id="open-another-project-picker-button"
                  class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/40 hover:text-primary transition-colors z-10"
                  phx-click="pick_directory"
                  phx-hook="DirectoryPicker"
                  data-is-desktop={to_string(@is_desktop)}
                  title={gettext("Browse for directory")}
                >
                  <.icon name="hero-folder-open" class="size-5" />
                </button>
                <datalist id="path-suggestions-open">
                  <%= for suggestion <- @path_suggestions do %>
                    <option value={suggestion}></option>
                  <% end %>
                </datalist>
              </div>
              <button type="submit" class="btn btn-primary w-full sm:w-auto">
                <.icon name="hero-folder-open" class="size-5" /> {gettext("Open")}
              </button>
            </.form>
          </div>
        <% end %>

        <div class="mb-8 animate-fade-in-up animation-delay-200">
          <EvoDashWeb.DashboardComponents.task_form
            prompt={@task_prompt}
            mode={@task_mode}
            mode_info={@task_mode_info}
            node_path={@task_node_path}
            seeds={@task_seeds}
            starting_commit={@task_starting_commit}
          />
        </div>

        <!-- Project Settings Toggle Button -->
        <div class="mb-4">
          <button
            class="btn gap-2"
            phx-click="toggle_project_settings"
          >
            <.icon name="hero-cog-6-tooth" class="size-4" />
            <%= if @show_project_settings do %>
              {gettext("Hide Project Settings")}
            <% else %>
              {gettext("Project Settings")}
            <% end %>
          </button>
        </div>

        <%= if @show_project_settings do %>
          <!-- Project Config Section -->
          <div class="mb-6 bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden animate-slide-down">
            <div class="bg-gradient-to-br from-accent/10 via-accent/5 to-transparent p-4 sm:p-6">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-document-text" class="size-5 text-accent" /> {gettext("evogit.toml Configuration")}
              </h2>
            </div>
            <div class="p-4 sm:p-6 pt-2">
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 sm:gap-4">
                <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
                  <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">{gettext("Project Root")}</p>
                  <p class="text-sm font-mono mt-1">{@active_project}</p>
                </div>
                <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
                  <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">{gettext("Config File")}</p>
                  <p class="text-sm mt-1">
                    <%= if @project_config do %>
                      <span class="badge badge-success badge-sm gap-1">
                        <.icon name="hero-check-circle" class="size-3" /> {gettext("Present")}
                      </span>
                    <% else %>
                      <span class="badge badge-ghost badge-sm gap-1">
                        <.icon name="hero-x-circle" class="size-3" /> {gettext("Not found")}
                      </span>
                    <% end %>
                  </p>
                </div>
                <div class="bg-base-200/40 rounded-lg p-3 border border-base-200 sm:col-span-2">
                  <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">{gettext("Worktree Init Script")}</p>
                  <p class="text-sm font-mono mt-1">
                    <%= if @worktree_script do %>
                      <span>{@worktree_script}</span>
                    <% else %>
                      <span class="text-base-content/30">{gettext("Not configured")}</span>
                    <% end %>
                  </p>
                </div>
              </div>
            </div>
          </div>

          <!-- Foreign Repos Section -->
          <div class="mb-6 bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden animate-slide-down animation-delay-100">
            <div class="bg-gradient-to-br from-secondary/10 via-secondary/5 to-transparent p-4 sm:p-6">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-server-stack" class="size-5 text-secondary" /> {gettext("Foreign Repositories")}
              </h2>
            </div>
            <div class="p-4 sm:p-6 pt-2">
              <%= if @foreign_repos == [] do %>
                <div class="text-center py-8 text-base-content/40">
                  <.icon name="hero-folder-minus" class="size-12 mx-auto mb-2 opacity-30" />
                  <p class="text-sm">{gettext("No repositories registered")}</p>
                </div>
              <% else %>
                <div class="space-y-3">
                  <%= for repo <- @foreign_repos do %>
                    <div class="flex items-center gap-3 bg-base-200/40 rounded-lg p-3 border border-base-200">
                      <span class={"badge #{if ForeignRepo.primary?(repo.id), do: "badge-primary", else: "badge-ghost"} badge-sm font-mono"}>
                        {repo.id}
                      </span>
                      <div class="flex-1 min-w-0">
                        <p class="text-sm font-mono truncate">{repo.root}</p>
                        <%= if repo.name && repo.name != Atom.to_string(repo.id) do %>
                          <p class="text-xs text-base-content/50">{repo.name}</p>
                        <% end %>
                      </div>
                      <%= unless ForeignRepo.primary?(repo.id) do %>
                        <button
                          class="btn btn-ghost btn-sm text-error"
                          phx-click="remove_foreign_repo"
                          phx-value-repo_id={repo.id}
                        >
                          <.icon name="hero-trash" class="size-3.5" />
                        </button>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%= if @show_add_foreign_repo_form do %>
                <div class="border-t border-base-200 mt-4 pt-4 animate-scale-in">
                  <h3 class="text-sm font-semibold flex items-center gap-2 mb-3">
                    <.icon name="hero-plus-circle" class="size-4 text-success" /> {gettext("Add Foreign Repository")}
                  </h3>
                  <.form for={%{}} phx-submit="add_foreign_repo" class="space-y-4">
                    <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 sm:gap-4">
                      <div>
                        <label class="label">
                          <span class="label-text text-xs font-medium uppercase tracking-wide">{gettext("Repo ID")}</span>
                        </label>
                        <input
                          type="text"
                          name="repo_id"
                          value={@new_repo_id}
                          placeholder={gettext("e.g., original")}
                          class="input input-bordered input-sm w-full font-mono"
                          required
                        />
                      </div>
                      <div>
                        <label class="label">
                          <span class="label-text text-xs font-medium uppercase tracking-wide">{gettext("Path")}</span>
                        </label>
                        <input
                          type="text"
                          name="path"
                          value={@new_repo_path}
                          placeholder={gettext("/absolute/path/to/repo")}
                          class="input input-bordered input-sm w-full font-mono"
                          required
                        />
                      </div>
                      <div>
                        <label class="label">
                          <span class="label-text text-xs font-medium uppercase tracking-wide">{gettext("Name (optional)")}</span>
                        </label>
                        <input
                          type="text"
                          name="name"
                          value={@new_repo_name}
                          placeholder={gettext("Human-readable name")}
                          class="input input-bordered input-sm w-full"
                        />
                      </div>
                    </div>
                    <div class="flex gap-2">
                      <button type="submit" class="btn btn-primary btn-sm gap-2">
                        <.icon name="hero-plus" class="size-4" /> {gettext("Add Repository")}
                      </button>
                      <button
                        type="button"
                        class="btn btn-ghost btn-sm"
                        phx-click="toggle_add_foreign_repo_form"
                      >
                        {gettext("Cancel")}
                      </button>
                    </div>
                  </.form>
                </div>
              <% else %>
                <button class="btn btn-sm btn-outline btn-secondary gap-2 w-full mt-4" phx-click="toggle_add_foreign_repo_form">
                  <.icon name="hero-plus-circle" class="size-4" /> {gettext("Add Foreign Repo")}
                </button>
              <% end %>
            </div>
          </div>
        <% end %>

      <% else %>
        <!-- No Active Project State -->
        <div class="mt-4 mb-8 animate-scale-in">
          <EvoDashWeb.DashboardComponents.open_project_form path="" recent_projects={@recent_projects} path_suggestions={@path_suggestions} />
        </div>
      <% end %>

      <!-- Running Tasks Section -->
      <%= if @running_tasks != [] do %>
        <div class="mt-8 animate-fade-in-up">
          <div class="flex items-center gap-2 mb-4">
            <div class="bg-success/15 text-success p-2 rounded-lg">
              <.icon name="hero-play-circle" class="size-5" />
            </div>
            <h2 class="text-lg font-semibold text-base-content/80">{gettext("Active Tasks")}</h2>
            <span class="badge badge-success">{length(@running_tasks)}</span>
          </div>
          <div class="space-y-3">
            <%= for task <- Enum.sort_by(@running_tasks, & &1.started_at, {:asc, DateTime}) do %>
              <div class="animate-pulse-glow rounded-2xl">
                <EvoDashWeb.DashboardComponents.task_card
                  task={task}
                  show_details={MapSet.member?(@expanded_task_ids, task.id)}
                />
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Recently Finished Tasks Section -->
      <%= if @recent_tasks != [] do %>
        <div class="mt-8 animate-fade-in-up animation-delay-100">
          <div class="flex items-center gap-2 mb-4">
            <div class="bg-info/15 text-info p-2 rounded-lg">
              <.icon name="hero-clock" class="size-5" />
            </div>
            <h2 class="text-lg font-semibold text-base-content/80">{gettext("Recently Finished")}</h2>
            <span class="badge badge-ghost">{length(@recent_tasks)}</span>
          </div>
          <div class="space-y-3">
            <%= for task <- @recent_tasks do %>
              <EvoDashWeb.DashboardComponents.task_card
                task={task}
                show_details={MapSet.member?(@expanded_task_ids, task.id)}
              />
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Empty State (no tasks at all) -->
      <%= if @running_tasks == [] and @recent_tasks == [] do %>
        <div class="mt-8 text-center py-12 sm:py-16 text-base-content/50 animate-fade-in-up">
          <div class="animate-float">
            <.icon name="hero-inbox" class="size-16 mx-auto mb-4 opacity-50" />
          </div>
          <p class="text-lg font-medium">
            <%= if @active_project do %>
              {gettext("No tasks yet")}
            <% else %>
              {gettext("No tasks yet")}
            <% end %>
          </p>
          <p class="text-sm mt-1">
            <%= if @active_project do %>
              {gettext("Start by creating a new task above.")}
            <% else %>
              {gettext("Open a project to get started.")}
            <% end %>
          </p>
        </div>
      <% end %>

      <!-- View All Tasks Link -->
      <%= if @running_tasks != [] or @recent_tasks != [] do %>
        <div class="mt-6 text-center animate-fade-in-up animation-delay-200">
          <.link navigate={~p"/tasks"} class="btn btn-ghost gap-2 hover-lift">
            <.icon name="hero-clipboard-document-list" class="size-4" /> {gettext("View Full Task History")}
            <.icon name="hero-arrow-right" class="size-4" />
          </.link>
        </div>
      <% end %>

      <!-- Full Result Modal -->
      <%= if @selected_result do %>
        <div class="modal modal-open bg-black/50">
          <div class="modal-box w-11/12 max-w-5xl">
            <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
              <.icon name="hero-information-circle" class="size-5 text-base-content/70" />
              {gettext("Task Result")}
            </h3>
            <div class="bg-base-200 p-4 rounded-lg overflow-x-auto max-h-[70vh] overflow-y-auto">
              {EvoDashWeb.DashboardComponents.render_result_full(@selected_result)}
            </div>
            <div class="modal-action">
              <button class="btn" phx-click="close_result_modal">{gettext("Close")}</button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_result_modal">
            <button class="cursor-default">{gettext("close")}</button>
          </div>
        </div>
      <% end %>

      <!-- Full Options Modal -->
      <%= if @selected_options do %>
        <div class="modal modal-open bg-black/50">
          <div class="modal-box w-11/12 max-w-5xl">
            <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
              <.icon name="hero-chat-bubble-left-ellipsis" class="size-5 text-primary" />
              {gettext("Full Objective")}
            </h3>
            <div class="bg-base-200 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
              <pre class="text-sm whitespace-pre-wrap break-words"><%= @selected_options %></pre>
            </div>
            <div class="modal-action">
              <button class="btn" phx-click="close_options_modal">{gettext("Close")}</button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_options_modal">
            <button class="cursor-default">{gettext("close")}</button>
          </div>
        </div>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    is_desktop = Map.get(session, "is_desktop", false)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "recent_projects")
    end

    tasks = TaskRegistry.list_tasks()
    recent_projects = TaskRegistry.list_recent_projects()

    socket =
      socket
      |> assign(:is_desktop, is_desktop)
      |> assign(:tasks, tasks)
      |> assign(:expanded_task_ids, MapSet.new())
      |> assign(:selected_result, nil)
      |> assign(:selected_options, nil)
      |> assign(:projects, %{})
      |> assign(:active_project, nil)
      |> assign(:show_open_project_form, false)
      |> assign(:recent_projects, recent_projects)
      |> assign(:path_suggestions, [])
      |> assign(:show_project_settings, false)
      |> assign(:project_config, nil)
      |> assign(:worktree_script, nil)
      |> assign(:foreign_repos, [])
      |> assign(:show_add_foreign_repo_form, false)
      |> assign(:new_repo_id, "")
      |> assign(:new_repo_path, "")
      |> assign(:new_repo_name, "")
      |> assign(:notified_task_ids, build_initial_notified_task_ids(tasks))
      |> assign_form_defaults()
      |> assign_running_and_recent_tasks()

    config_status =
      try do
        EvoGit.Config.config_status()
      rescue
        _ -> %{missing: [], warnings: [], ok?: true}
      catch
        _, _ -> %{missing: [], warnings: [], ok?: true}
      end

    socket = assign(socket, :config_status, config_status)

    {:ok, socket}
  end

  @impl true
  def handle_info({:tasks_updated}, socket) do
    new_tasks =
      if socket.assigns.active_project do
        TaskRegistry.list_tasks_by_path(socket.assigns.active_project)
      else
        TaskRegistry.list_tasks()
      end

    socket =
      if socket.assigns.show_project_settings and socket.assigns.active_project do
        {project_config, worktree_script} = load_project_config(socket.assigns.active_project)
        foreign_repos = load_foreign_repos()

        socket
        |> assign(:project_config, project_config)
        |> assign(:worktree_script, worktree_script)
        |> assign(:foreign_repos, foreign_repos)
      else
        socket
      end

    # Detect newly finished tasks and send browser notifications
    previously_notified = socket.assigns.notified_task_ids

    {newly_finished, updated_notified} =
      Enum.reduce(new_tasks, {[], previously_notified}, fn task, {acc, notified} ->
        if task.status in [:completed, :failed, :cancelled] and not MapSet.member?(notified, task.id) do
          {[task | acc], MapSet.put(notified, task.id)}
        else
          {acc, notified}
        end
      end)

    socket =
      socket
      |> assign(:notified_task_ids, updated_notified)

    # Push notification events for each newly finished task
    socket =
      Enum.reduce(newly_finished, socket, fn task, sock ->
        {title, body} = task_notification_content(task)
        push_event(sock, "task_notification", %{title: title, body: body})
      end)

    {:noreply,
     socket
     |> assign(:tasks, new_tasks)
     |> assign_running_and_recent_tasks()}
  end

  @impl true
  def handle_info({:recent_projects_updated}, socket) do
    recent_projects = TaskRegistry.list_recent_projects()
    {:noreply, assign(socket, :recent_projects, recent_projects)}
  end

  @impl true
  def handle_event("open_project", %{"path" => path}, socket) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      TaskRegistry.add_recent_project(expanded, Path.basename(expanded))

      project = %{path: expanded, name: Path.basename(expanded)}
      projects = Map.put(socket.assigns.projects, expanded, project)
      mode = detect_mode(expanded)
      mode_info = mode_info_message(mode)

      tasks = TaskRegistry.list_tasks_by_path(expanded)

      {:noreply,
       socket
       |> assign(:projects, projects)
       |> assign(:active_project, expanded)
       |> assign(:tasks, tasks)
       |> assign(:task_mode, mode)
       |> assign(:task_mode_info, mode_info)
       |> assign(:show_open_project_form, false)
       |> assign(:show_project_settings, false)
       |> assign(:recent_projects, TaskRegistry.list_recent_projects())
       |> assign_running_and_recent_tasks()
       |> put_flash(:info, mode_info)}
    else
      {:noreply,
       socket
       |> assign(:show_open_project_form, false)
       |> put_flash(:error, gettext("Directory does not exist: %{path}", path: path))}
    end
  end

  @impl true
  def handle_event("switch_project", %{"path" => path}, socket) do
    mode = detect_mode(path)
    mode_info = mode_info_message(mode)
    tasks = TaskRegistry.list_tasks_by_path(path)

    {:noreply,
     socket
     |> assign(:active_project, path)
     |> assign(:tasks, tasks)
     |> assign(:task_mode, mode)
     |> assign(:task_mode_info, mode_info)
     |> assign(:show_project_settings, false)
     |> assign_running_and_recent_tasks()}
  end

  @impl true
  def handle_event("close_project", %{"path" => path}, socket) do
    projects = Map.delete(socket.assigns.projects, path)

    {active_project, tasks} =
      if socket.assigns.active_project == path do
        case Map.keys(projects) do
          [next | _] ->
            {next, TaskRegistry.list_tasks_by_path(next)}

          [] ->
            {nil, TaskRegistry.list_tasks()}
        end
      else
        {socket.assigns.active_project, socket.assigns.tasks}
      end

    mode =
      if active_project do
        detect_mode(active_project)
      else
        "genesis_new"
      end

    mode_info =
      if active_project do
        mode_info_message(mode)
      else
        ""
      end

    {:noreply,
     socket
     |> assign(:projects, projects)
     |> assign(:active_project, active_project)
     |> assign(:tasks, tasks)
     |> assign(:task_mode, mode)
     |> assign(:task_mode_info, mode_info)
     |> assign_running_and_recent_tasks()}
  end

  @impl true
  def handle_event("show_open_project", _params, socket) do
    {:noreply, assign(socket, :show_open_project_form, true)}
  end

  @impl true
  def handle_event("hide_open_project_form", _params, socket) do
    {:noreply, assign(socket, :show_open_project_form, false)}
  end

  @impl true
  def handle_event("toggle_project_settings", _params, socket) do
    show = !socket.assigns.show_project_settings

    socket =
      if show do
        {project_config, worktree_script} = load_project_config(socket.assigns.active_project)
        foreign_repos = load_foreign_repos()

        socket
        |> assign(:project_config, project_config)
        |> assign(:worktree_script, worktree_script)
        |> assign(:foreign_repos, foreign_repos)
      else
        socket
      end

    {:noreply, assign(socket, :show_project_settings, show)}
  end

  @impl true
  def handle_event("toggle_add_foreign_repo_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_foreign_repo_form, !socket.assigns.show_add_foreign_repo_form)
     |> assign(:new_repo_id, "")
     |> assign(:new_repo_path, "")
     |> assign(:new_repo_name, "")}
  end

  @impl true
  def handle_event("add_foreign_repo", params, socket) do
    repo_id_str = String.trim(params["repo_id"] || "")
    path = String.trim(params["path"] || "")
    name = String.trim(params["name"] || "")

    cond do
      repo_id_str == "" ->
        {:noreply, put_flash(socket, :error, gettext("Repo ID cannot be empty."))}

      path == "" ->
        {:noreply, put_flash(socket, :error, gettext("Path cannot be empty."))}

      not String.starts_with?(path, "/") ->
        {:noreply, put_flash(socket, :error, gettext("Path must be absolute (start with /)."))}

      true ->
        repo_id = String.to_atom(repo_id_str)

        repo =
          if name != "" do
            ForeignRepo.new(repo_id, path, name: name)
          else
            ForeignRepo.new(repo_id, path)
          end

        try do
          case EvoGit.AgentScheduler.register_foreign_repo(repo) do
            :ok ->
              foreign_repos = load_foreign_repos()

              {:noreply,
               socket
               |> assign(:foreign_repos, foreign_repos)
               |> assign(:show_add_foreign_repo_form, false)
               |> assign(:new_repo_id, "")
               |> assign(:new_repo_path, "")
               |> assign(:new_repo_name, "")
               |> put_flash(:info, gettext("Foreign repo '%{repo_id}' registered successfully.", repo_id: repo_id_str))}

            {:error, {:already_exists, id}} ->
              {:noreply,
               socket
               |> put_flash(:error, gettext("Repo '%{id}' is already registered.", id: id))}
          end
        rescue
          e ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Failed to register repo: %{reason}", reason: Exception.message(e)))}
        catch
          _, _ ->
            {:noreply,
             put_flash(socket, :error, gettext("Failed to register repo: scheduler not available."))}
        end
    end
  end

  @impl true
  def handle_event("remove_foreign_repo", %{"repo_id" => repo_id_str}, socket) do
    repo_id = String.to_atom(repo_id_str)

    try do
      case EvoGit.AgentScheduler.unregister_foreign_repo(repo_id) do
        :ok ->
          foreign_repos = load_foreign_repos()

          {:noreply,
           socket
           |> assign(:foreign_repos, foreign_repos)
           |> put_flash(:info, gettext("Foreign repo '%{repo_id}' removed successfully.", repo_id: repo_id_str))}

        {:error, :cannot_unregister_primary} ->
          {:noreply, put_flash(socket, :error, gettext("Cannot remove the primary repository."))}

        {:error, {:not_found, id}} ->
          {:noreply, put_flash(socket, :error, gettext("Repo '%{id}' not found.", id: id))}
      end
    rescue
      e ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to remove repo: %{reason}", reason: Exception.message(e)))}
    catch
      _, _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove repo: scheduler not available."))}
    end
  end

  @impl true
  def handle_event("path_input", %{"path" => value}, socket) do
    suggestions = path_suggestions(value)
    {:noreply, assign(socket, :path_suggestions, suggestions)}
  end

  @impl true
  def handle_event("pick_directory", _params, socket) do
    case EvoDashWeb.NativePicker.pick_directory() do
      {:ok, path} ->
        {:noreply, push_event(socket, "picker_result", %{path: path})}

      {:error, :cancelled} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not open directory picker: %{reason}", reason: reason))}
    end
  end

  @impl true
  def handle_event("directory_picked", %{"path" => path}, socket) do
    {:noreply, push_event(socket, "picker_result", %{path: path})}
  end

  @impl true
  def handle_event("task_change", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :task_mode, mode)}
  end

  @impl true
  def handle_event(
        "task_submit",
        %{"prompt" => prompt, "mode" => combined_mode} = params,
        socket
      ) do
    path = socket.assigns.active_project

    if is_nil(path) do
      {:noreply, put_flash(socket, :error, gettext("No project selected. Please open a project first."))}
    else
      {task_type, mode} =
        case combined_mode do
          "genesis_new" -> {:genesis, "new"}
          "genesis_existing" -> {:genesis, "existing"}
          "evolve_simple" -> {:evolve, "simple"}
          "evolve_complex" -> {:evolve, "complex"}
        end

      node_path = params["node_path"]

      opts = [
        path: path,
        mode: mode
      ]

      opts =
        if task_type == :genesis do
          Keyword.put(opts, :prompt, prompt)
        else
          Keyword.put(opts, :objective, prompt)
        end

      opts =
        if task_type == :evolve and is_binary(node_path) and String.trim(node_path) != "" do
          Keyword.put(opts, :node_path, String.trim(node_path))
        else
          opts
        end

      starting_commit = params["starting_commit"]

      opts =
        if task_type == :evolve and is_binary(starting_commit) and String.trim(starting_commit) != "" do
          Keyword.put(opts, :starting_commit, String.trim(starting_commit))
        else
          opts
        end

      seeds_content = params["seeds"]

      opts =
        if task_type == :evolve and mode == "complex" and is_binary(seeds_content) and String.trim(seeds_content) != "" do
          Keyword.put(opts, :seed_content, String.trim(seeds_content))
        else
          opts
        end

      case TaskRegistry.start_task(task_type, opts) do
        {:ok, task} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("%{type} task started with ID: %{id}", type: String.capitalize(to_string(task_type)), id: task.id)
           )
           |> assign(:tasks, TaskRegistry.list_tasks_by_path(path))
           |> assign_running_and_recent_tasks()
           |> assign(:task_prompt, "")
           |> assign(:task_node_path, "")
           |> assign(:task_seeds, "")
           |> assign(:task_starting_commit, "")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to start task: %{reason}", reason: inspect(reason)))}
      end
    end
  end

  @impl true
  def handle_event("cancel_task", %{"task_id" => task_id}, socket) do
    case TaskRegistry.cancel_task(task_id) do
      :ok ->
        expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

        {:noreply,
         socket
         |> assign(:tasks, current_tasks(socket))
         |> assign(:expanded_task_ids, expanded)
         |> assign_running_and_recent_tasks()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to cancel task: %{reason}", reason: inspect(reason)))}
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
  def handle_event("view_full_options", %{"task_id" => task_id}, socket) do
    task = Enum.find(socket.assigns.tasks, &(&1.id == task_id))
    opts = Map.get(task || %{}, :opts, [])
    primary_text = opts[:prompt] || opts[:objective] || ""
    {:noreply, assign(socket, :selected_options, primary_text)}
  end

  @impl true
  def handle_event("close_options_modal", _params, socket) do
    {:noreply, assign(socket, :selected_options, nil)}
  end

  @impl true
  def handle_event("clear_task_history", _params, socket) do
    TaskRegistry.clear_finished_tasks()

    tasks =
      if socket.assigns.active_project do
        TaskRegistry.list_tasks_by_path(socket.assigns.active_project)
      else
        TaskRegistry.list_tasks()
      end

    {:noreply,
     socket
     |> assign(:tasks, tasks)
     |> assign(:expanded_task_ids, MapSet.new())
     |> assign_running_and_recent_tasks()}
  end

  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    TaskRegistry.delete_task(task_id)

    expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

    tasks =
      if socket.assigns.active_project do
        TaskRegistry.list_tasks_by_path(socket.assigns.active_project)
      else
        TaskRegistry.list_tasks()
      end

    {:noreply,
     socket
     |> assign(:tasks, tasks)
     |> assign(:expanded_task_ids, expanded)
     |> assign_running_and_recent_tasks()}
  end

  # Helpers

  defp assign_running_and_recent_tasks(socket) do
    all_tasks = socket.assigns.tasks

    running_tasks = Enum.filter(all_tasks, &(&1.status in [:running, :pending, :finalizing]))

    recent_tasks =
      all_tasks
      |> Enum.filter(&(&1.status in [:completed, :failed, :cancelled]))
      |> Enum.sort_by(&(&1.finished_at || &1.started_at), {:desc, DateTime})
      |> Enum.take(5)

    socket
    |> assign(:running_tasks, running_tasks)
    |> assign(:recent_tasks, recent_tasks)
  end

  defp build_initial_notified_task_ids(tasks) do
    tasks
    |> Enum.filter(&(&1.status in [:completed, :failed, :cancelled]))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp task_notification_content(task) do
    objective = task.opts[:prompt] || task.opts[:objective] || ""

    case task.result do
      {:ok, %{pr_title: pr_title}} when is_binary(pr_title) and pr_title != "" ->
        {pr_title, objective}

      {:ok, _} ->
        case task.type do
          :genesis -> {"Genesis task completed", objective}
          :evolve -> {"Evolution task completed", objective}
        end

      {:error, reason} ->
        {"Task failed", inspect(reason)}

      {:exit, reason} ->
        {"Task crashed", inspect(reason)}

      _ ->
        {"Task finished", objective}
    end
  end

  defp assign_form_defaults(socket) do
    socket
    |> assign(:task_prompt, "")
    |> assign(:task_mode, "genesis_new")
    |> assign(:task_mode_info, "")
    |> assign(:task_node_path, "")
    |> assign(:task_seeds, "")
    |> assign(:task_starting_commit, "")
  end

  defp current_tasks(socket) do
    if socket.assigns.active_project do
      TaskRegistry.list_tasks_by_path(socket.assigns.active_project)
    else
      TaskRegistry.list_tasks()
    end
  end

  defp detect_mode(path) do
    path = Path.expand(path)

    cond do
      new_codebase?(path) -> "genesis_new"
      not File.exists?(Path.join(path, "CONTEXT.md")) -> "genesis_existing"
      true -> "evolve_simple"
    end
  end

  defp new_codebase?(path) do
    files =
      case File.ls(path) do
        {:ok, items} -> items -- [".git", "README.md", ".evogit", ".gitignore"]
        _ -> []
      end

    Enum.empty?(files)
  end

  defp path_suggestions(value) when value == "" or is_nil(value) do
    []
  end

  defp path_suggestions(value) do
    expanded = Path.expand(value)

    {dir, prefix} =
      cond do
        String.ends_with?(expanded, "/") ->
          {expanded, ""}

        String.contains?(expanded, "/") ->
          dir = Path.dirname(expanded)
          base = Path.basename(expanded)
          {dir, base}

        true ->
          # No directory separator — use cwd as dir and whole value as prefix
          {File.cwd!(), expanded}
      end

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          String.starts_with?(String.downcase(entry), String.downcase(prefix))
        end)
        |> Enum.sort_by(fn entry ->
          # Directories first, then alphabetical
          {not File.dir?(Path.join(dir, entry)), String.downcase(entry)}
        end)
        |> Enum.take(15)
        |> Enum.map(fn entry ->
          Path.join(dir, entry)
        end)

      {:error, _} ->
        []
    end
  end

  # Project Settings Helpers

  defp load_project_config(nil), do: {nil, nil}

  defp load_project_config(project_root) do
    try do
      config = EvoGit.ProjectConfig.read(project_root)

      worktree_script =
        case config do
          %{"worktree" => %{"script" => script}} when is_binary(script) -> script
          _ -> nil
        end

      {config, worktree_script}
    rescue
      _ -> {nil, nil}
    catch
      _, _ -> {nil, nil}
    end
  end

  defp load_foreign_repos do
    try do
      repos = EvoGit.AgentScheduler.get_foreign_repos()

      Enum.sort_by(repos, fn repo ->
        {if(ForeignRepo.primary?(repo.id), do: 0, else: 1), repo.id}
      end)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end
end
