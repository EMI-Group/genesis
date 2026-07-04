defmodule EvoDashWeb.DashboardLive do
  @moduledoc """
  Project-based task dashboard for launching and monitoring EvoGit tasks.

  Users open a repository, and the dashboard auto-detects the task mode
  (genesis or evolve). Displays active tasks with live logs and inline
  project settings including foreign repositories.
  """
  use EvoDashWeb, :live_view
  alias EvoDash.TaskRegistry
  alias EvoGit.Core.ForeignRepo

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @live_action == :system_dashboard do %>
      <EvoDashWeb.Layouts.app flash={@flash} current_page={:phx_dashboard} config_status={@config_status}>
        <div class="flex items-center gap-3 mb-2 animate-fade-in-up">
          <div class="bg-info/15 text-info p-3 rounded-xl">
            <.icon name="hero-chart-bar" class="size-6" />
          </div>
          <div>
            <h1 class="text-xl font-bold">{gettext("System Dashboard")}</h1>
            <p class="text-sm text-base-content/60">{gettext("Phoenix LiveDashboard — system metrics, processes, and application telemetry")}</p>
          </div>
        </div>
        <iframe
          src={~p"/phoenix/dashboard/home"}
          class="w-full rounded-xl"
          style={"min-height: calc(100vh - 200px); border: none;"}
          title="Phoenix LiveDashboard"
        >
        </iframe>
      </EvoDashWeb.Layouts.app>
    <% else %>
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:dashboard} config_status={@config_status}>
      <div id="dashboard-root" phx-hook="StatePersistence" data-project={@active_project_path} data-task-mode={@task_mode}>
        <div id="welcome-check" phx-hook="WelcomeCheck" class="hidden"></div>
        <div id="browser-notifications" phx-hook="BrowserNotifications">
        <!-- Project Selector (always visible) -->
        <EvoDashWeb.DashboardComponents.project_selector
          active_project={@active_project}
          recent_projects={@recent_projects}
          show_open_form={@show_open_project_form}
          path_suggestions={@path_suggestions}
        />

        <!-- Task Form (always visible, disabled when no project) -->
        <div class="mt-6 mb-6 animate-fade-in-up animation-delay-100">
          <EvoDashWeb.DashboardComponents.task_form
            prompt={@task_prompt}
            mode={@task_mode}
            mode_info={@task_mode_info}
            node_path={@task_node_path}
            seeds={@task_seeds}
            starting_commit={@task_starting_commit}
            resume_from={@task_resume_from}
            show_advanced={@show_advanced}
            disabled={is_nil(@active_project)}
            archive={@task_archive}
          />
        </div>

        <!-- Project Settings (always in DOM, collapsible) -->
        <div class="mb-6 animate-fade-in-up animation-delay-200">
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
            new_repo_description={@new_repo_description}
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

        <!-- Pending Review Tasks Section -->
        <%= if @pending_tasks != [] do %>
          <div class="mt-6 animate-fade-in-up animation-delay-100">
            <div class="flex items-center gap-2 mb-4">
              <div class="bg-warning/15 text-warning p-2 rounded-lg">
                <.icon name="hero-exclamation-circle" class="size-5" />
              </div>
              <h2 class="text-lg font-semibold text-base-content/80">{gettext("Pending Review")}</h2>
              <span class="badge badge-ghost">{length(@pending_tasks)}</span>
            </div>
            <div class="space-y-3">
              <%= for task <- @pending_tasks do %>
                <EvoDashWeb.DashboardComponents.task_card
                  task={task}
                  show_details={MapSet.member?(@expanded_task_ids, task.id)}
                />
              <% end %>
            </div>
          </div>
        <% end %>

        <!-- Empty State -->
        <%= if @running_tasks == [] and @pending_tasks == [] do %>
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
        <%= if @running_tasks != [] or @pending_tasks != [] do %>
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
      </div>
      <%= if @show_welcome do %>
        <div class="modal modal-open bg-black/50" id="welcome-modal">
          <div class="modal-box max-w-lg">
            <div class="flex items-center gap-3 mb-4">
              <div class="bg-primary/15 text-primary p-3 rounded-xl">
                <.icon name="hero-sparkles" class="size-6" />
              </div>
              <h3 class="font-bold text-lg">{gettext("Welcome to EvoGit!")}</h3>
            </div>
            <p class="text-sm text-base-content/70 leading-relaxed mb-6">
              {gettext("EvoGit uses AI agents to build and evolve codebases. To get started, you'll need to configure an LLM model and API key. Would you like to set that up now?")}
            </p>
            <div class="mb-4">
              <div class="text-xs font-medium text-base-content/50 mb-1.5">{gettext("Language")}</div>
              <details class="dropdown">
                <summary class="btn btn-sm btn-outline gap-2 w-full justify-between">
                  <span class="flex items-center gap-2">
                    <.icon name="hero-language" class="size-4" />
                    {Enum.find_value(EvoDashWeb.Layouts.supported_languages(), "English", fn {code, name} ->
                      if code == @welcome_locale, do: name
                    end)}
                  </span>
                  <.icon name="hero-chevron-down" class="size-4 opacity-60" />
                </summary>
                <div class="dropdown-content mt-1 z-50 w-full rounded-xl border border-base-200 bg-base-100/95 backdrop-blur-md shadow-xl p-2">
                  <div class="max-h-48 overflow-y-auto flex flex-col gap-0.5">
                    <button
                      :for={{code, name} <- EvoDashWeb.Layouts.supported_languages()}
                      class={[
                        "flex items-center gap-3 w-full px-3 py-2.5 rounded-lg text-sm font-medium transition-colors cursor-pointer",
                        @welcome_locale == code && "bg-indigo-50 dark:bg-indigo-500/15 text-indigo-700 dark:text-indigo-300",
                        @welcome_locale != code && "hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-700 dark:text-slate-300"
                      ]}
                      phx-click="set_welcome_language"
                      phx-value-locale={code}
                    >
                      <span class="flex-1 text-left">{name}</span>
                      <.icon :if={@welcome_locale == code} name="hero-check-solid" class="size-4 text-indigo-500 shrink-0" />
                    </button>
                  </div>
                </div>
              </details>
            </div>
            <div class="modal-action">
              <button class="btn btn-ghost" phx-click="dismiss_welcome">
                {gettext("Skip")}
              </button>
              <button class="btn btn-primary gap-2" phx-click="welcome_configure_llm">
                <.icon name="hero-sparkles" class="size-4" />
                {gettext("Configure LLM")}
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="dismiss_welcome">
            <button class="cursor-default">{gettext("close")}</button>
          </div>
        </div>
      <% end %>
    </EvoDashWeb.Layouts.app>
    <% end %>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "recent_projects")
    end

    recent_projects = TaskRegistry.list_recent_projects()

    config_status = config_status()

    socket =
      socket
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
      |> assign(:new_repo_description, "")
      |> assign(:tasks, [])
      |> assign(
        :notified_task_ids,
        TaskRegistry.list_tasks()
        |> Enum.filter(&(&1.status in [:completed, :failed, :cancelled]))
        |> Enum.map(& &1.id)
        |> MapSet.new()
      )
      |> assign_form_defaults()
      |> assign(:show_advanced, false)
      |> assign(:task_resume_from, "")
      |> assign_running_and_pending_tasks()
      |> assign(:config_status, config_status)
      |> assign(:show_welcome, false)
      |> assign(:welcome_locale, Gettext.get_locale(EvoDashWeb.Gettext))

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
          |> assign(
            :notified_task_ids,
            build_notified_task_ids(tasks, socket.assigns.notified_task_ids)
          )
          |> assign_running_and_pending_tasks()
        end
      else
        # No project in URL — try auto-loading most recent project, or load all tasks
        socket =
          if is_nil(socket.assigns.active_project) do
            case List.first(socket.assigns.recent_projects) do
              %{path: recent_path} when is_binary(recent_path) ->
                if File.dir?(recent_path) do
                  activate_project(socket, recent_path)
                else
                  all_tasks = TaskRegistry.list_tasks()

                  socket
                  |> assign(:tasks, all_tasks)
                  |> assign(
                    :notified_task_ids,
                    build_notified_task_ids(all_tasks, socket.assigns.notified_task_ids)
                  )
                  |> assign_running_and_pending_tasks()
                end

              _ ->
                all_tasks = TaskRegistry.list_tasks()

                socket
                |> assign(:tasks, all_tasks)
                |> assign(
                  :notified_task_ids,
                  build_notified_task_ids(all_tasks, socket.assigns.notified_task_ids)
                )
                |> assign_running_and_pending_tasks()
            end
          else
            # We had a project but navigated away and back without it
            socket
          end

        socket
      end

    # Preserve starting_commit from URL query param (e.g. ?starting_commit=abc123)
    socket =
      case params["starting_commit"] do
        sha when is_binary(sha) and sha != "" ->
          assign(socket, :task_starting_commit, sha)

        _ ->
          socket
      end

    # Preserve resume_from from URL query param (e.g. ?resume_from=task_id)
    # and auto-expand the Advanced Options so the user sees it's filled in.
    socket =
      case params["resume_from"] do
        task_id when is_binary(task_id) and task_id != "" ->
          socket
          |> assign(:task_resume_from, task_id)
          |> assign(:show_advanced, true)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  # --- Welcome Modal Events ---

  @impl true
  def handle_event("show_welcome", _params, socket) do
    {:noreply, assign(socket, :show_welcome, true)}
  end

  @impl true
  def handle_event("dismiss_welcome", _params, socket) do
    {:noreply, socket |> assign(:show_welcome, false) |> push_event("welcome_dismissed", %{})}
  end

  @impl true
  def handle_event("welcome_configure_llm", _params, socket) do
    socket = socket |> push_event("welcome_dismissed", %{})
    {:noreply, push_navigate(socket, to: "/settings?category=llm")}
  end

  @impl true
  def handle_event("set_welcome_language", %{"locale" => code}, socket) do
    Gettext.put_locale(EvoDashWeb.Gettext, code)

    {:noreply,
     socket
     |> assign(:welcome_locale, code)
     |> push_event("persist_locale", %{locale: code})}
  end

  # --- Project Management Events ---

  @impl true
  def handle_event("toggle_open_project_form", _params, socket) do
    {:noreply, assign(socket, :show_open_project_form, !socket.assigns.show_open_project_form)}
  end

  @impl true
  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :show_advanced, !socket.assigns.show_advanced)}
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
      TaskRegistry.add_recent_project(expanded, Path.basename(expanded))
      recent_projects = TaskRegistry.list_recent_projects()

      socket =
        socket
        |> assign(:recent_projects, recent_projects)

      {:noreply, push_patch(socket, to: ~p"/?project=#{URI.encode(expanded)}")}
    else
      {:noreply,
       put_flash(socket, :error, gettext("Directory does not exist: %{path}", path: path))}
    end
  end

  # --- Task Form Events ---

  @impl true
  def handle_event("task_change", %{"mode" => mode}, socket) do
    {:noreply,
     socket
     |> assign(:task_mode, mode)
     |> maybe_persist_state()}
  end

  @impl true
  def handle_event("restore_state", params, socket) do
    # Don't let restore_state overwrite a starting_commit that came from the URL
    # (set in handle_params from ?starting_commit=... query param)
    socket =
      if socket.assigns.task_starting_commit != "" do
        socket
      else
        maybe_restore_assign(socket, :task_starting_commit, params["task_starting_commit"])
      end

    # Don't let restore_state overwrite a resume_from that came from the URL
    # (set in handle_params from ?resume_from=... query param)
    socket =
      if socket.assigns.task_resume_from != "" do
        socket
      else
        maybe_restore_assign(socket, :task_resume_from, params["task_resume_from"])
      end

    socket =
      socket
      |> maybe_restore_assign(:task_prompt, params["task_prompt"])
      |> maybe_restore_assign(:task_seeds, params["task_seeds"])
      |> maybe_restore_show_project_settings(params["show_project_settings"])
      |> maybe_restore_task_archive(params["task_archive"])
      |> maybe_restore_show_advanced(params["show_advanced"])

    # Restore project if we don't already have one active.
    # Only restore project-specific assigns (mode, node_path) when no project is
    # active — otherwise the auto-detected values from detect_mode/1 should win.
    socket =
      if is_nil(socket.assigns.active_project) do
        socket =
          socket
          |> maybe_restore_assign(:task_mode, params["task_mode"])
          |> maybe_restore_assign(:task_node_path, params["task_node_path"])

        project_path = params["project"]

        if is_binary(project_path) and project_path != "" and File.dir?(project_path) do
          activate_project(socket, project_path)
        else
          socket
        end
      else
        socket
      end

    # Restore foreign repos from session AFTER activate_project, which loads
    # repos from genesis.toml. The session-restored repos are the authoritative
    # snapshot from before navigation/reload.
    socket = maybe_restore_foreign_repos(socket, params["foreign_repos"])

    {:noreply, socket}
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
          _ -> {:evolve, "simple"}
        end

      node_path = params["node_path"]
      archive = params["archive"] == "true"

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

      # Include foreign repos from project settings for this task
      foreign_repos = socket.assigns[:foreign_repos] || []

      opts =
        if foreign_repos != [], do: Keyword.put(opts, :foreign_repos, foreign_repos), else: opts

      opts = if archive, do: Keyword.put(opts, :archive, true), else: opts

      resume_from = params["resume_from"]

      opts =
        if task_type == :evolve and is_binary(resume_from) and String.trim(resume_from) != "" do
          Keyword.put(opts, :resume_from, String.trim(resume_from))
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
           |> assign_running_and_pending_tasks()
           |> assign_form_defaults()
           |> maybe_persist_state()}

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
         |> assign_running_and_pending_tasks()}

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
     |> assign_running_and_pending_tasks()}
  end

  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    TaskRegistry.delete_task(task_id)
    expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

    {:noreply,
     socket
     |> assign(:tasks, current_tasks(socket))
     |> assign(:expanded_task_ids, expanded)
     |> assign_running_and_pending_tasks()}
  end

  # --- Project Settings Events ---

  @impl true
  def handle_event("toggle_add_foreign_repo_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_foreign_repo_form, !socket.assigns.show_add_foreign_repo_form)
     |> assign(:new_repo_id, "")
     |> assign(:new_repo_path, "")
     |> assign(:new_repo_description, "")}
  end

  @impl true
  def handle_event("add_foreign_repo", params, socket) do
    repo_id_str = String.trim(params["repo_id"] || "")
    path = String.trim(params["path"] || "")
    description = String.trim(params["description"] || "")

    cond do
      repo_id_str == "" ->
        {:noreply, put_flash(socket, :error, gettext("Repo ID cannot be empty."))}

      path == "" ->
        {:noreply, put_flash(socket, :error, gettext("Path cannot be empty."))}

      not String.starts_with?(path, "/") ->
        {:noreply, put_flash(socket, :error, gettext("Path must be absolute (start with /)."))}

      true ->
        repo_id = repo_id_str

        # Check if already exists in the current list
        current_repos = socket.assigns.foreign_repos

        if Enum.any?(current_repos, &(&1.id == repo_id)) do
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Repo '%{id}' is already registered.", id: repo_id)
           )}
        else
          repo =
            if description != "" do
              ForeignRepo.new(repo_id, path, description: description)
            else
              ForeignRepo.new(repo_id, path)
            end

          updated_repos =
            Enum.sort_by([repo | current_repos], fn r ->
              {if(ForeignRepo.primary?(r.id), do: 0, else: 1), r.id}
            end)

          {:noreply,
           socket
           |> assign(:foreign_repos, updated_repos)
           |> assign(:show_add_foreign_repo_form, false)
           |> assign(:new_repo_id, "")
           |> assign(:new_repo_path, "")
           |> assign(:new_repo_description, "")
           |> maybe_persist_state()
           |> put_flash(
             :info,
             gettext("Foreign repo '%{repo_id}' registered successfully.",
               repo_id: repo_id_str
             )
           )}
        end
    end
  end

  @impl true
  def handle_event("remove_foreign_repo", %{"repo_id" => repo_id_str}, socket) do
    repo_id = repo_id_str

    if repo_id == "primary" do
      {:noreply, put_flash(socket, :error, gettext("Cannot remove the primary repository."))}
    else
      current_repos = socket.assigns.foreign_repos
      updated_repos = Enum.reject(current_repos, &(&1.id == repo_id))

      if length(updated_repos) == length(current_repos) do
        {:noreply, put_flash(socket, :error, gettext("Repo '%{id}' not found.", id: repo_id))}
      else
        {:noreply,
         socket
         |> assign(:foreign_repos, updated_repos)
         |> maybe_persist_state()
         |> put_flash(
           :info,
           gettext("Foreign repo '%{repo_id}' removed successfully.", repo_id: repo_id_str)
         )}
      end
    end
  end

  # --- Path / Directory Picker Events ---

  @impl true
  def handle_event("path_input", %{"path" => value}, socket) do
    suggestions = path_suggestions(value)
    {:noreply, assign(socket, :path_suggestions, suggestions)}
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
        {:noreply,
         put_flash(socket, :error, gettext("Command not found: %{command}", command: command))}

      cmd_string ->
        # Justified try/rescue: System.cmd runs arbitrary project-config-defined shell commands.
        # A failing command should show a user-friendly error, not crash the LiveView.
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

            msg =
              gettext("Command '%{command}' completed:\n%{output}",
                command: command,
                output: truncate_output(output)
              )

            {:noreply, put_flash(socket, flash_type, msg)}
          else
            msg =
              gettext("Command '%{command}' failed (exit %{code}):\n%{output}",
                command: command,
                code: exit_code,
                output: truncate_output(output)
              )

            {:noreply, put_flash(socket, :error, msg)}
          end
        rescue
          e ->
            msg =
              gettext("Error running '%{command}': %{error}",
                command: command,
                error: Exception.message(e)
              )

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

    # Refresh project settings if shown (foreign repos are in-memory, not re-read)
    socket =
      if socket.assigns.show_project_settings and socket.assigns.active_project_path do
        {project_config, worktree_script, commands} =
          load_project_config(socket.assigns.active_project_path)

        socket
        |> assign(:project_config, project_config)
        |> assign(:worktree_script, worktree_script)
        |> assign(:commands, commands)
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
     |> assign_running_and_pending_tasks()}
  end

  @impl true
  def handle_info({:task_status, _task_id, _status}, socket) do
    {:noreply,
     socket
     |> assign(:tasks, current_tasks(socket))
     |> assign_running_and_pending_tasks()}
  end

  @impl true
  def handle_info({:recent_projects_updated}, socket) do
    {:noreply, assign(socket, :recent_projects, TaskRegistry.list_recent_projects())}
  end

  # --- Private Helpers ---

  defp activate_project(socket, path) do
    name = Path.basename(path)
    is_project_change = socket.assigns[:active_project_path] != path

    # Only auto-detect mode when switching to a different project.
    # Preserve the user's manual mode selection on re-navigation/reconnect.
    {mode, mode_info} =
      if is_project_change do
        detected = detect_mode(path)
        {detected, mode_info_message(detected)}
      else
        current_mode = socket.assigns[:task_mode]
        {current_mode, socket.assigns[:task_mode_info]}
      end

    tasks = TaskRegistry.list_tasks_by_path(path)

    # Load project settings eagerly
    {project_config, worktree_script, commands} = load_project_config(path)
    foreign_repos = load_foreign_repos(path)

    socket
    |> assign(:active_project, %{path: path, name: name})
    |> assign(:active_project_path, path)
    |> assign(:tasks, tasks)
    |> assign(
      :notified_task_ids,
      build_notified_task_ids(tasks, socket.assigns.notified_task_ids)
    )
    |> assign(:task_mode, mode)
    |> assign(:task_mode_info, mode_info)
    |> assign(:show_open_project_form, false)
    |> assign(:show_project_settings, true)
    |> assign(:project_config, project_config)
    |> assign(:worktree_script, worktree_script)
    |> assign(:commands, commands)
    |> assign(:foreign_repos, foreign_repos)
    |> assign(:show_add_foreign_repo_form, false)
    |> assign_running_and_pending_tasks()
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

  defp assign_running_and_pending_tasks(socket) do
    all_tasks = socket.assigns.tasks

    running_tasks =
      Enum.filter(all_tasks, &(&1.status in [:running, :pending, :finalizing]))

    pending_tasks =
      all_tasks
      |> Enum.filter(fn task ->
        task.status == :completed and is_nil(Map.get(task, :review_status)) and
          show_review_button?(task)
      end)
      |> Enum.sort_by(&(&1.finished_at || &1.started_at), {:desc, DateTime})

    socket
    |> assign(:running_tasks, running_tasks)
    |> assign(:pending_tasks, pending_tasks)
  end

  defp show_review_button?(%{status: :completed, result: {:ok, %{branch_name: branch}}})
       when is_binary(branch) and branch != "", do: true

  defp show_review_button?(_), do: false

  defp assign_form_defaults(socket) do
    mode =
      if socket.assigns[:active_project_path] do
        detect_mode(socket.assigns.active_project_path)
      else
        "genesis_new"
      end

    socket
    |> assign(:task_prompt, "")
    |> assign(:task_mode, mode)
    |> assign(:task_mode_info, "")
    |> assign(:task_node_path, "")
    |> assign(:task_seeds, "")
    |> assign(:task_starting_commit, "")
    |> assign(:task_resume_from, "")
    |> assign(:task_archive, false)
    |> assign(:show_advanced, false)
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
        {:ok, items} -> items -- [".git", "README.md", ".genesis", ".gitignore"]
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

  defp load_project_config(project_root) do
    config = EvoGit.ProjectConfig.read(project_root)

    worktree_script =
      case config do
        %{"worktree" => %{"script" => script}} when is_binary(script) -> script
        _ -> nil
      end

    commands = EvoGit.ProjectConfig.commands(project_root)

    {config, worktree_script, commands}
  end

  defp load_foreign_repos(repo_path) do
    repos = EvoGit.ProjectConfig.foreign_repos(repo_path)

    Enum.sort_by(repos, fn repo ->
      {if(ForeignRepo.primary?(repo.id), do: 0, else: 1), repo.id}
    end)
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

  # --- Session Persistence Helpers ---

  defp maybe_persist_state(socket) do
    state = %{
      project: socket.assigns.active_project_path,
      task_mode: socket.assigns.task_mode,
      task_prompt: socket.assigns.task_prompt,
      task_node_path: socket.assigns.task_node_path,
      task_seeds: socket.assigns.task_seeds,
      task_starting_commit: socket.assigns.task_starting_commit,
      task_resume_from: socket.assigns.task_resume_from,
      show_advanced: socket.assigns.show_advanced,
      task_archive: socket.assigns.task_archive,
      foreign_repos: serialize_foreign_repos(socket.assigns[:foreign_repos])
    }

    push_event(socket, "persist_state", state)
  end

  defp serialize_foreign_repos(nil), do: []

  defp serialize_foreign_repos(repos) do
    Enum.map(repos, fn repo ->
      %{"id" => repo.id, "path" => repo.root, "description" => repo.description}
    end)
  end

  defp maybe_restore_assign(socket, _key, nil), do: socket
  defp maybe_restore_assign(socket, _key, ""), do: socket

  defp maybe_restore_assign(socket, key, value) when is_binary(value) do
    assign(socket, key, value)
  end

  defp maybe_restore_show_project_settings(socket, "true"),
    do: assign(socket, :show_project_settings, true)

  defp maybe_restore_show_project_settings(socket, "false"),
    do: assign(socket, :show_project_settings, false)

  defp maybe_restore_show_project_settings(socket, _), do: socket

  defp maybe_restore_task_archive(socket, "true"), do: assign(socket, :task_archive, true)
  defp maybe_restore_task_archive(socket, true), do: assign(socket, :task_archive, true)
  defp maybe_restore_task_archive(socket, _), do: assign(socket, :task_archive, false)

  defp maybe_restore_show_advanced(socket, "true"), do: assign(socket, :show_advanced, true)
  defp maybe_restore_show_advanced(socket, true), do: assign(socket, :show_advanced, true)
  defp maybe_restore_show_advanced(socket, _), do: socket

  defp maybe_restore_foreign_repos(socket, nil), do: socket
  defp maybe_restore_foreign_repos(socket, repos) when is_list(repos) and repos == [], do: socket

  defp maybe_restore_foreign_repos(socket, repos) when is_list(repos) do
    restored =
      repos
      |> Enum.filter(fn r -> is_map(r) and is_binary(r["path"]) and r["path"] != "" end)
      |> Enum.map(fn r ->
        id = if is_binary(r["id"]) and r["id"] != "", do: r["id"], else: "primary"

        opts =
          if is_binary(r["description"]) and r["description"] != "",
            do: [description: r["description"]],
            else: []

        ForeignRepo.new(id, r["path"], opts)
      end)

    if restored != [] do
      sorted =
        Enum.sort_by(restored, fn repo ->
          {if(ForeignRepo.primary?(repo.id), do: 0, else: 1), repo.id}
        end)

      assign(socket, :foreign_repos, sorted)
    else
      socket
    end
  end
end
