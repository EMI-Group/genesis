defmodule EvoDashWeb.DashboardLive do
  use EvoDashWeb, :live_view
  alias EvoDash.TaskRegistry
  alias EvoGit.Core.ForeignRepo

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:dashboard} config_status={@config_status}>
      <div id="browser-notifications" phx-hook="BrowserNotifications">
        <!-- Project Selector (always visible) -->
        <EvoDashWeb.DashboardComponents.project_selector
          active_project={@active_project}
          recent_projects={@recent_projects}
          is_desktop={@is_desktop}
          show_open_form={@show_open_project_form}
          path_suggestions={@path_suggestions}
        />

        <!-- Task Form (always visible, disabled when no project) -->
        <div class="mt-4 mb-4 animate-fade-in-up animation-delay-100">
          <EvoDashWeb.DashboardComponents.task_form
            prompt={@task_prompt}
            mode={@task_mode}
            mode_info={@task_mode_info}
            node_path={@task_node_path}
            seeds={@task_seeds}
            starting_commit={@task_starting_commit}
            disabled={is_nil(@active_project)}
          />
        </div>

        <!-- Project Settings (always in DOM, collapsible) -->
        <div class="mb-4 animate-fade-in-up animation-delay-200">
          <EvoDashWeb.DashboardComponents.project_settings_panel
            active_project={@active_project_path}
            show={@show_project_settings}
            project_config={@project_config}
            worktree_script={@worktree_script}
            commands={@commands}
            foreign_repos={@foreign_repos}
            show_add_foreign_repo={@show_add_foreign_repo_form}
            new_repo_id={@new_repo_id}
            new_repo_path={@new_repo_path}
            new_repo_name={@new_repo_name}
            is_desktop={@is_desktop}
          />
        </div>

        <!-- Running Tasks Section -->
        <%= if @running_tasks != [] do %>
          <div class="mt-6 animate-fade-in-up">
            <div class="flex items-center gap-2 mb-4">
              <div class="bg-success/15 text-success p-2 rounded-lg">
                <.icon name="hero-play-circle" class="size-5" />
              </div>
              <h2 class="text-lg font-semibold text-base-content/80">{gettext("Active Tasks")}</h2>
              <span class="badge badge-success">{length(@running_tasks)}</span>
            </div>
            <div class="space-y-3">
              <%= for task <- Enum.sort_by(@running_tasks, & &1.started_at, {:asc, DateTime}) do %>
                <div class={["rounded-2xl", if(task.status == :finalizing, do: "animate-pulse-glow-warning", else: "animate-pulse-glow")]}>
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
          <div class="mt-6 animate-fade-in-up animation-delay-100">
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

        <!-- Empty State -->
        <%= if @running_tasks == [] and @recent_tasks == [] do %>
          <div class="mt-6 text-center py-10 text-base-content/50 animate-fade-in-up">
            <div class="animate-float">
              <.icon name="hero-inbox" class="size-14 mx-auto mb-3 opacity-50" />
            </div>
            <p class="text-base font-medium">{gettext("No tasks yet")}</p>
            <p class="text-sm mt-1">
              <%= if @active_project do %>
                {gettext("Configure and execute a task above to get started.")}
              <% else %>
                {gettext("Open a project to get started.")}
              <% end %>
            </p>
          </div>
        <% end %>

        <!-- View All Tasks Link -->
        <%= if @running_tasks != [] or @recent_tasks != [] do %>
          <div class="mt-4 text-center animate-fade-in-up animation-delay-200">
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
      </div>
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

    recent_projects = TaskRegistry.list_recent_projects()

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
      |> assign(:is_desktop, is_desktop)
      |> assign(:active_project, nil)
      |> assign(:active_project_path, nil)
      |> assign(:show_open_project_form, false)
      |> assign(:recent_projects, recent_projects)
      |> assign(:path_suggestions, [])
      |> assign(:expanded_task_ids, MapSet.new())
      |> assign(:selected_result, nil)
      |> assign(:selected_options, nil)
      |> assign(:show_project_settings, false)
      |> assign(:project_config, nil)
      |> assign(:worktree_script, nil)
    |> assign(:commands, %{})
      |> assign(:foreign_repos, [])
      |> assign(:show_add_foreign_repo_form, false)
      |> assign(:new_repo_id, "")
      |> assign(:new_repo_path, "")
      |> assign(:new_repo_name, "")
      |> assign(:tasks, [])
      |> assign(:notified_task_ids,
          TaskRegistry.list_tasks()
          |> Enum.filter(&(&1.status in [:completed, :failed, :cancelled]))
          |> Enum.map(& &1.id)
          |> MapSet.new())
      |> assign_form_defaults()
      |> assign_running_and_recent_tasks()
      |> assign(:config_status, config_status)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    project_path = params["project"]

    socket =
      if project_path && project_path != "" do
        expanded = Path.expand(project_path)

        if File.dir?(expanded) do
          activate_project(socket, expanded)
        else
          # Project path in URL is invalid, clear it
          tasks = TaskRegistry.list_tasks()

          socket
          |> assign(:active_project, nil)
          |> assign(:active_project_path, nil)
          |> assign(:tasks, tasks)
          |> assign(:notified_task_ids, build_notified_task_ids(tasks, socket.assigns.notified_task_ids))
          |> assign_running_and_recent_tasks()
        end
      else
        # No project in URL — load all tasks
        tasks =
          if socket.assigns.active_project do
            # We had a project but navigated away and back without it
            socket.assigns.tasks
          else
            TaskRegistry.list_tasks()
          end

        socket
        |> assign(:tasks, tasks)
        |> assign(:notified_task_ids, build_notified_task_ids(tasks, socket.assigns.notified_task_ids))
        |> assign_running_and_recent_tasks()
      end

    {:noreply, socket}
  end

  # --- Project Management Events ---

  @impl true
  def handle_event("toggle_open_project_form", _params, socket) do
    {:noreply, assign(socket, :show_open_project_form, !socket.assigns.show_open_project_form)}
  end

  @impl true
  def handle_event("open_project", %{"path" => path}, socket) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      TaskRegistry.add_recent_project(expanded, Path.basename(expanded))
      recent_projects = TaskRegistry.list_recent_projects()

      socket =
        socket
        |> assign(:recent_projects, recent_projects)
        |> assign(:show_open_project_form, false)

      # Push URL params to persist project across navigation
      {:noreply, push_patch(socket, to: ~p"/?project=#{URI.encode(expanded)}")}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("Directory does not exist: %{path}", path: path))}
    end
  end

  @impl true
  def handle_event("select_project", %{"path" => path}, socket) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      {:noreply, push_patch(socket, to: ~p"/?project=#{URI.encode(expanded)}")}
    else
      {:noreply,
       put_flash(socket, :error, gettext("Directory does not exist: %{path}", path: path))}
    end
  end

  # --- Task Form Events ---

  @impl true
  def handle_event("task_change", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :task_mode, mode)}
  end

  @impl true
  def handle_event("task_submit", %{"prompt" => prompt, "mode" => combined_mode} = params, socket) do
    path = socket.assigns[:active_project_path]

    if is_nil(path) do
      {:noreply,
       put_flash(socket, :error, gettext("No project selected. Please open a project first."))}
    else
      {task_type, mode} =
        case combined_mode do
          "genesis_new" -> {:genesis, "new"}
          "genesis_existing" -> {:genesis, "existing"}
          "evolve_simple" -> {:evolve, "simple"}
          "evolve_complex" -> {:evolve, "complex"}
        end

      node_path = params["node_path"]

      opts = [path: path, mode: mode]

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
        if task_type == :evolve and is_binary(starting_commit) and
             String.trim(starting_commit) != "" do
          Keyword.put(opts, :starting_commit, String.trim(starting_commit))
        else
          opts
        end

      seeds_content = params["seeds"]

      opts =
        if task_type == :evolve and mode == "complex" and is_binary(seeds_content) and
             String.trim(seeds_content) != "" do
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
             gettext("%{type} task started with ID: %{id}",
               type: String.capitalize(to_string(task_type)),
               id: task.id
             )
           )
           |> assign(:tasks, TaskRegistry.list_tasks_by_path(path))
           |> assign_running_and_recent_tasks()
           |> assign_form_defaults()}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to start task: %{reason}", reason: inspect(reason))
           )}
      end
    end
  end

  # --- Task Management Events ---

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
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to cancel task: %{reason}", reason: inspect(reason))
         )}
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

    {:noreply,
     socket
     |> assign(:tasks, current_tasks(socket))
     |> assign(:expanded_task_ids, MapSet.new())
     |> assign_running_and_recent_tasks()}
  end

  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    TaskRegistry.delete_task(task_id)
    expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

    {:noreply,
     socket
     |> assign(:tasks, current_tasks(socket))
     |> assign(:expanded_task_ids, expanded)
     |> assign_running_and_recent_tasks()}
  end

  # --- Project Settings Events ---

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
        {:noreply,
         put_flash(socket, :error, gettext("Path must be absolute (start with /)."))}

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
               |> put_flash(
                 :info,
                 gettext("Foreign repo '%{repo_id}' registered successfully.",
                   repo_id: repo_id_str
                 )
               )}

            {:error, {:already_exists, id}} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 gettext("Repo '%{id}' is already registered.", id: id)
               )}
          end
        rescue
          e ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Failed to register repo: %{reason}",
                 reason: Exception.message(e)
               )
             )}
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
           |> put_flash(
             :info,
             gettext("Foreign repo '%{repo_id}' removed successfully.", repo_id: repo_id_str)
           )}

        {:error, :cannot_unregister_primary} ->
          {:noreply,
           put_flash(socket, :error, gettext("Cannot remove the primary repository."))}

        {:error, {:not_found, id}} ->
          {:noreply,
           put_flash(socket, :error, gettext("Repo '%{id}' not found.", id: id))}
      end
    rescue
      e ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to remove repo: %{reason}", reason: Exception.message(e))
         )}
    catch
      _, _ ->
        {:noreply,
         put_flash(socket, :error, gettext("Failed to remove repo: scheduler not available."))}
    end
  end

  # --- Path / Directory Picker Events ---

  @impl true
  def handle_event("path_input", %{"path" => value}, socket) do
    suggestions = path_suggestions(value)
    {:noreply, assign(socket, :path_suggestions, suggestions)}
  end

  @impl true
  def handle_event("pick_directory", %{"picker_id" => picker_id}, socket) do
    case EvoDashWeb.NativePicker.pick_directory() do
      {:ok, path} ->
        {:noreply, push_event(socket, "picker_result:#{picker_id}", %{path: path})}

      {:error, :cancelled} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not open directory picker: %{reason}", reason: reason)
         )}
    end
  end

  @impl true
  def handle_event("directory_picked", %{"path" => path, "picker_id" => picker_id}, socket) do
    {:noreply, push_event(socket, "picker_result:#{picker_id}", %{path: path})}
  end

  @impl true
  def handle_event("run_command", %{"command" => command}, socket) do
    commands = socket.assigns.commands
    project_root = socket.assigns.active_project_path

    case Map.get(commands, command) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Command not found: %{command}", command: command))}

      cmd_string ->
        try do
          {output, exit_code} =
            case :os.type() do
              {:win32, _} ->
                System.cmd("powershell", ["-Command", cmd_string],
                  cd: project_root,
                  stderr_to_stdout: true,
                  timeout: 30_000
                )

              _ ->
                System.cmd("bash", ["-c", cmd_string],
                  cd: project_root,
                  stderr_to_stdout: true,
                  timeout: 30_000
                )
            end

          if exit_code == 0 do
            flash_type = :info
            msg = gettext("Command '%{command}' completed:\n%{output}", command: command, output: truncate_output(output))
            {:noreply, put_flash(socket, flash_type, msg)}
          else
            msg = gettext("Command '%{command}' failed (exit %{code}):\n%{output}", command: command, code: exit_code, output: truncate_output(output))
            {:noreply, put_flash(socket, :error, msg)}
          end
        rescue
          e ->
            msg = gettext("Error running '%{command}': %{error}", command: command, error: Exception.message(e))
            {:noreply, put_flash(socket, :error, msg)}
        end
    end
  end

  defp truncate_output(output) when byte_size(output) > 2000 do
    String.slice(output, 0, 2000) <> "..."
  end

  defp truncate_output(output), do: String.trim(output)

  # --- PubSub Handlers ---

  @impl true
  def handle_info({:tasks_updated}, socket) do
    new_tasks = current_tasks(socket)

    # Refresh project settings if shown
    socket =
      if socket.assigns.show_project_settings and socket.assigns.active_project_path do
        {project_config, worktree_script, commands} =
          load_project_config(socket.assigns.active_project_path)

        foreign_repos = load_foreign_repos()

        socket
        |> assign(:project_config, project_config)
        |> assign(:worktree_script, worktree_script)
        |> assign(:commands, commands)
        |> assign(:foreign_repos, foreign_repos)
      else
        socket
      end

    # Detect newly finished tasks for browser notifications
    previously_notified = socket.assigns.notified_task_ids

    {newly_finished, updated_notified} =
      Enum.reduce(new_tasks, {[], previously_notified}, fn task, {acc, notified} ->
        if task.status in [:completed, :failed, :cancelled] and
             not MapSet.member?(notified, task.id) do
          {[task | acc], MapSet.put(notified, task.id)}
        else
          {acc, notified}
        end
      end)

    socket =
      Enum.reduce(newly_finished, socket, fn task, sock ->
        {title, body} = task_notification_content(task)
        push_event(sock, "task_notification", %{title: title, body: body})
      end)

    {:noreply,
     socket
     |> assign(:notified_task_ids, updated_notified)
     |> assign(:tasks, new_tasks)
     |> assign_running_and_recent_tasks()}
  end

  @impl true
  def handle_info({:task_status, _task_id, _status}, socket) do
    {:noreply,
     socket
     |> assign(:tasks, current_tasks(socket))
     |> assign_running_and_recent_tasks()}
  end

  @impl true
  def handle_info({:recent_projects_updated}, socket) do
    {:noreply, assign(socket, :recent_projects, TaskRegistry.list_recent_projects())}
  end

  # --- Private Helpers ---

  defp activate_project(socket, path) do
    name = Path.basename(path)
    mode = detect_mode(path)
    mode_info = mode_info_message(mode)
    tasks = TaskRegistry.list_tasks_by_path(path)

    # Load project settings eagerly
    {project_config, worktree_script, commands} = load_project_config(path)
    foreign_repos = load_foreign_repos()

    socket
    |> assign(:active_project, %{path: path, name: name})
    |> assign(:active_project_path, path)
    |> assign(:tasks, tasks)
    |> assign(:notified_task_ids, build_notified_task_ids(tasks, socket.assigns.notified_task_ids))
    |> assign(:task_mode, mode)
    |> assign(:task_mode_info, mode_info)
    |> assign(:show_open_project_form, false)
    |> assign(:show_project_settings, true)
    |> assign(:project_config, project_config)
    |> assign(:worktree_script, worktree_script)
    |> assign(:commands, commands)
    |> assign(:foreign_repos, foreign_repos)
    |> assign(:show_add_foreign_repo_form, false)
    |> assign_running_and_recent_tasks()
    |> maybe_put_flash_mode_info(mode_info)
  end

  # Only put flash when the project actually changes (not on every handle_params)
  defp maybe_put_flash_mode_info(socket, ""), do: socket

  defp maybe_put_flash_mode_info(socket, mode_info) do
    if socket.assigns.active_project_path && socket.assigns.active_project do
      # Already had a project — skip flash on re-activation
      socket
    else
      put_flash(socket, :info, mode_info)
    end
  end

  defp build_notified_task_ids(tasks, existing_notified) do
    tasks
    |> Enum.filter(&(&1.status in [:completed, :failed, :cancelled]))
    |> Enum.map(& &1.id)
    |> MapSet.new()
    |> MapSet.union(existing_notified)
  end

  defp assign_running_and_recent_tasks(socket) do
    all_tasks = socket.assigns.tasks

    running_tasks =
      Enum.filter(all_tasks, &(&1.status in [:running, :pending, :finalizing]))

    recent_tasks =
      all_tasks
      |> Enum.filter(&(&1.status in [:completed, :failed, :cancelled]))
      |> Enum.sort_by(&(&1.finished_at || &1.started_at), {:desc, DateTime})
      |> Enum.take(5)

    socket
    |> assign(:running_tasks, running_tasks)
    |> assign(:recent_tasks, recent_tasks)
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
    if socket.assigns.active_project_path do
      TaskRegistry.list_tasks_by_path(socket.assigns.active_project_path)
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

  defp path_suggestions(value) when value == "" or is_nil(value), do: []

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
          {File.cwd!(), expanded}
      end

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          String.starts_with?(String.downcase(entry), String.downcase(prefix))
        end)
        |> Enum.sort_by(fn entry ->
          {not File.dir?(Path.join(dir, entry)), String.downcase(entry)}
        end)
        |> Enum.take(15)
        |> Enum.map(fn entry -> Path.join(dir, entry) end)

      {:error, _} ->
        []
    end
  end

  defp load_project_config(nil), do: {nil, nil, %{}}

  defp load_project_config(project_root) do
    try do
      config = EvoGit.ProjectConfig.read(project_root)

      worktree_script =
        case config do
          %{"worktree" => %{"script" => script}} when is_binary(script) -> script
          _ -> nil
        end

      commands = EvoGit.ProjectConfig.commands(project_root)

      {config, worktree_script, commands}
    rescue
      _ -> {nil, nil, %{}}
    catch
      _, _ -> {nil, nil, %{}}
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
end
