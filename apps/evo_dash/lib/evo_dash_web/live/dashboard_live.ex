defmodule EvoDashWeb.DashboardLive do
  @moduledoc """
  Project-based task dashboard for launching and monitoring EvoGit tasks.

  Users open a repository, and the dashboard auto-detects the task mode
  (genesis or evolve). Displays active tasks with live logs and inline
  project settings including foreign repositories.
  """
  use EvoDashWeb, :live_view
  alias EvoGit.TaskRegistry
  alias EvoDashWeb.DashboardLive.{StatePersistence, Project, Assigns, ProjectFlow}
  alias EvoDashWeb.ThemeColor
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Platform
  alias EvoGit.ProjectConfig
  use EvoDashWeb.ModalHelpers

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @live_action == :system_dashboard do %>
      <EvoDashWeb.Layouts.app
        flash={@flash}
        current_page={:phx_dashboard}
        config_status={@config_status}
        current_node_id={@current_node_id}
        current_node_name={@current_node_name}
        running_tasks={@running_tasks}
        pending_tasks={@pending_tasks}
      >
        <div class="flex items-center gap-3 mb-2 animate-fade-in-up">
          <div class="bg-info/15 text-info p-3 rounded-xl">
            <.icon name="hero-chart-bar" class="size-6" />
          </div>
          <div>
            <h1 class="text-xl font-bold">{gettext("System Dashboard")}</h1>
            <p class="text-sm text-base-content/60">
              {gettext("Phoenix LiveDashboard — system metrics, processes, and application telemetry")}
            </p>
          </div>
        </div>
        <iframe
          src={~p"/phoenix/dashboard/home"}
          class="w-full rounded-xl"
          style="min-height: calc(100vh - 200px); border: none;"
          title="Phoenix LiveDashboard"
        ></iframe>
      </EvoDashWeb.Layouts.app>
    <% else %>
      <EvoDashWeb.Layouts.app
        flash={@flash}
        current_page={:dashboard}
        config_status={@config_status}
        current_node_id={@current_node_id}
        current_node_name={@current_node_name}
        tasks={@tasks}
        running_tasks={@running_tasks}
        pending_tasks={@pending_tasks}
      >
        <div
          id="dashboard-root"
          phx-hook="StatePersistence"
          data-project={@active_project_path}
          data-task-mode={@task_mode}
          class="flex flex-col min-h-full"
          style={"--project-accent: #{ThemeColor.accent_color(@active_project && @active_project.name)}"}
        >
          <div id="tauri-detect" phx-hook="TauriDetect" class="hidden"></div>
          <div id="platform-detect" phx-hook="PlatformDetect" class="hidden"></div>
          <div
            id="browser-notifications"
            phx-hook="BrowserNotifications"
            class="flex-1 flex flex-col min-h-0"
          >
            <%= if @remote? do %>
              <!-- Remote node view: show the remote node's active agents.
                   The local task list and project management are LOCAL
                   concerns — the remote daemon runs evo_git only, no
                   evo_dash (no TaskRegistry/Store). -->
              <div class="mt-2 mb-6 rounded-lg border border-info/30 bg-info/5 p-4 flex items-start gap-3">
                <.icon name="hero-server-stack" class="size-5 text-info shrink-0 mt-0.5" />
                <div>
                  <h2 class="font-bold text-sm text-info mb-0.5">
                    {gettext("Remote Node — Active Agents")}
                  </h2>
                  <p class="text-sm text-base-content/70">
                    {gettext(
                      "You are viewing agents running on a remote node. Task launching and project management are local dashboard features."
                    )}
                  </p>
                </div>
              </div>

              <%= if @remote_agents == [] do %>
                <div class="mt-6 text-center py-10 text-base-content/50 animate-fade-in-up">
                  <div class="animate-float">
                    <.icon name="hero-inbox" class="size-14 mx-auto mb-3 opacity-50" />
                  </div>
                  <p class="text-base font-medium">{gettext("No active agents")}</p>
                  <p class="text-sm mt-1">
                    {gettext("There are no running agents on this remote node.")}
                  </p>
                </div>
              <% else %>
                <div class="mt-6 animate-fade-in-up">
                  <div class="flex items-center gap-2 mb-4">
                    <div class="bg-success/15 text-success p-2 rounded-lg">
                      <.icon name="hero-play-circle" class="size-5" />
                    </div>
                    <h2 class="text-lg font-semibold text-base-content/80">
                      {gettext("Agents")}
                    </h2>
                    <span class="badge badge-success">{length(@remote_agents)}</span>
                  </div>
                  <div class="space-y-3">
                    <%= for agent <- Enum.sort_by(@remote_agents, &{Map.get(&1, :depth, 0), Map.get(&1, :id, 0)}) do %>
                      <div class="rounded-2xl border border-base-200 bg-base-100 p-4">
                        <div class="flex items-center justify-between gap-3 mb-2">
                          <div class="flex items-center gap-2 min-w-0">
                            <span class="badge badge-ghost badge-sm font-mono shrink-0">
                              #{Map.get(agent, :id, "?")}
                            </span>
                            <code class="text-xs text-base-content/60 truncate">
                              {Map.get(agent, :agent_module, "")}
                            </code>
                          </div>
                          <span class={[
                            "badge badge-sm shrink-0",
                            case Map.get(agent, :status) do
                              :running -> "badge-success"
                              :pending -> "badge-warning"
                              :waiting -> "badge-info"
                              :ready -> "badge-info"
                              :blocked -> "badge-error"
                              _ -> "badge-ghost"
                            end
                          ]}>
                            {case Map.get(agent, :status) do
                              s when is_atom(s) ->
                                Gettext.gettext(
                                  EvoDashWeb.Gettext,
                                  String.capitalize(Atom.to_string(s))
                                )

                              _ ->
                                gettext("Unknown")
                            end}
                          </span>
                        </div>
                        <% objective = Map.get(agent, :objective) %>
                        <%= if objective do %>
                          <p class="text-sm text-base-content/70 line-clamp-2">{objective}</p>
                        <% end %>
                        <div class="flex flex-wrap gap-3 mt-2 text-xs text-base-content/50">
                          <%= if Map.get(agent, :model_id) do %>
                            <span class="badge badge-ghost badge-sm">{Map.get(agent, :model_id)}</span>
                          <% end %>
                          <%= if Map.get(agent, :repo_id) do %>
                            <span>{gettext("Repo")}: {Map.get(agent, :repo_id)}</span>
                          <% end %>
                          <% usage = Map.get(agent, :usage) || %{} %>
                          <% total =
                            Map.get(usage, :total_tokens) || Map.get(agent, :total_tokens) || 0 %>
                          <%= if total > 0 do %>
                            <span>{gettext("Tokens")}: {total}</span>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            <% else %>
              <div class="flex-1 flex flex-col min-h-0 gap-3">
                <.top_bar
                  active_project={@active_project}
                  active_project_path={@active_project_path}
                  recent_projects={@recent_projects}
                  show_open_form={@show_open_project_form}
                  show_new_project_form={@show_new_project_form}
                  path_suggestions={@path_suggestions}
                  tauri_detected={@tauri_detected}
                  platform={@platform}
                  show_project_settings={@show_project_settings}
                  task_mode={@task_mode}
                  task_node_path={@task_node_path}
                  task_starting_commit={@task_starting_commit}
                  task_resume_from={@task_resume_from}
                  task_archive={@task_archive}
                  build_systems={@build_systems}
                  task_build_system={@task_build_system}
                  project_config={@project_config}
                  worktree_script={@worktree_script}
                  commands={@commands}
                  foreign_repos={@foreign_repos}
                  show_add_foreign_repo_form={@show_add_foreign_repo_form}
                  new_repo_id={@new_repo_id}
                  new_repo_path={@new_repo_path}
                  new_repo_description={@new_repo_description}
                  disabled={is_nil(@active_project)}
                  address_bar_editing={@address_bar_editing}
                  show_configure_dropdown={@show_configure_dropdown}
                />

                <!-- Zone 2 (textarea, flex-1) + Zone 3 (floating bottom launcher) -->
                <EvoDashWeb.TaskFormComponents.task_form
                  prompt={@task_prompt}
                  mode={@task_mode}
                  mode_info={@task_mode_info}
                  node_path={@task_node_path}
                  starting_commit={@task_starting_commit}
                  resume_from={@task_resume_from}
                  show_advanced={@show_advanced}
                  disabled={is_nil(@active_project)}
                  archive={@task_archive}
                  model_profiles={@model_profiles}
                  selected_model_id={@selected_model_id}
                  build_systems={@build_systems}
                  selected_build_system={@task_build_system}
                />

                <!-- Full Result Modal -->
                <%= if @selected_result do %>
                  <EvoDashWeb.Helpers.modal on_close="close_result_modal">
                    <:title>
                      <.icon name="hero-information-circle" class="size-5 text-base-content/70" />
                      {gettext("Task Result")}
                    </:title>
                    {EvoDashWeb.TaskCardComponents.render_result_full(@selected_result)}
                  </EvoDashWeb.Helpers.modal>
                <% end %>

                <!-- Full Options Modal -->
                <%= if @selected_options do %>
                  <EvoDashWeb.Helpers.modal on_close="close_options_modal">
                    <:title>
                      <.icon name="hero-chat-bubble-left-ellipsis" class="size-5 text-primary" />
                      {gettext("Full Objective")}
                    </:title>
                    <pre class="text-sm whitespace-pre-wrap break-words"><%= @selected_options %></pre>
                  </EvoDashWeb.Helpers.modal>
                <% end %>
              </div>
            <% end %>
            <%!-- end of @remote? else branch --%>
          </div>
        </div>
      </EvoDashWeb.Layouts.app>
    <% end %>
    """
  end

  attr(:build_systems, :list, default: [])
  attr(:selected, :string, default: nil)

  def build_system_select(assigns) do
    ~H"""
    <select
      name="build_system"
      form="task-form"
      class="select select-ghost select-sm bg-transparent font-medium focus:outline-none focus:ring-2 focus:ring-primary/20 min-w-32"
      title={gettext("Build System")}
    >
      <option value="">{gettext("No build system")}</option>
      <%= for bs <- @build_systems do %>
        <option value={to_string(bs.id)} selected={@selected == to_string(bs.id)}>
          {bs.name}
        </option>
      <% end %>
    </select>
    """
  end

  # ---------------------------------------------------------------------------
  # top_bar/1 — Immersive sticky app header with address-bar project control.
  #
  # LEFT: address-bar-style project control (click to open/reveal path input
  # + recent projects + new-project option).
  # RIGHT: a single "Configure" dropdown showing BOTH sections at once —
  # "Task Options" and "Project Settings" — with no tab bar.
  # ---------------------------------------------------------------------------

  attr(:active_project, :map, default: nil)
  attr(:active_project_path, :string, default: nil)
  attr(:recent_projects, :list, default: [])
  attr(:show_open_form, :boolean, default: false)
  attr(:show_new_project_form, :boolean, default: false)
  attr(:path_suggestions, :list, default: [])
  attr(:tauri_detected, :boolean, default: false)
  attr(:platform, :string, default: "linux")
  attr(:show_project_settings, :boolean, default: false)
  attr(:task_mode, :string, default: "genesis_new")
  attr(:task_node_path, :string, default: "")
  attr(:task_starting_commit, :string, default: "")
  attr(:task_resume_from, :string, default: "")
  attr(:task_archive, :boolean, default: false)
  attr(:build_systems, :list, default: [])
  attr(:task_build_system, :string, default: nil)
  attr(:project_config, :map, default: nil)
  attr(:worktree_script, :string, default: nil)
  attr(:commands, :map, default: %{})
  attr(:foreign_repos, :list, default: [])
  attr(:show_add_foreign_repo_form, :boolean, default: false)
  attr(:new_repo_id, :string, default: "")
  attr(:new_repo_path, :string, default: "")
  attr(:new_repo_description, :string, default: "")
  attr(:disabled, :boolean, default: false)
  attr(:address_bar_editing, :boolean, default: false)
  attr(:show_configure_dropdown, :boolean, default: false)

  def top_bar(assigns) do
    ~H"""
    <div class="dashboard-topbar shrink-0 sticky top-0 z-30 w-full flex items-center justify-between gap-2 px-3 py-2">
      <!-- LEFT: address-bar-style project control -->
      <div class="flex-1 min-w-0">
        <EvoDashWeb.ProjectComponents.project_selector
          active_project={@active_project}
          recent_projects={@recent_projects}
          show_open_form={@show_open_form}
          show_new_project_form={@show_new_project_form}
          path_suggestions={@path_suggestions}
          tauri_detected={@tauri_detected}
          platform={@platform}
          address_bar_editing={@address_bar_editing}
        />
      </div>

      <!-- RIGHT: Configure dropdown — server-managed open state -->
      <div class="relative shrink-0">
        <button
          type="button"
          class="btn btn-sm btn-ghost gap-1"
          title={gettext("Configure")}
          phx-click="toggle_configure_dropdown"
        >
          <.icon name="hero-adjustments-horizontal" class="size-4" />
          <span class="hidden sm:inline">{gettext("Configure")}</span>
        </button>

        <%= if @show_configure_dropdown do %>
          <!-- Full-screen invisible click-catcher overlay -->
          <div class="fixed inset-0 z-40" phx-click="close_configure_dropdown"></div>
        <% end %>

        <!-- Dropdown content — always in DOM, hidden when closed.
             Using class-based toggling (not conditional render) so content
             stays in the DOM and phx events inside still work reliably. -->
        <div class={[
          "absolute right-0 z-50 w-80 sm:w-96 mt-2 rounded-xl border border-base-200 bg-base-100/95 backdrop-blur-md shadow-xl overflow-hidden",
          !@show_configure_dropdown && "hidden"
        ]}>
          <div class="p-3 max-h-[60vh] overflow-y-auto overflow-x-hidden">
            <!-- Section 1: Task Options -->
            <div>
              <p class="text-[11px] font-semibold uppercase tracking-wide text-base-content/40 mb-2">
                {gettext("Task Options")}
              </p>
              <EvoDashWeb.TaskFormComponents.task_options_tab
                mode={@task_mode}
                node_path={@task_node_path}
                starting_commit={@task_starting_commit}
                resume_from={@task_resume_from}
                archive={@task_archive}
                build_systems={@build_systems}
                selected_build_system={@task_build_system}
                disabled={@disabled}
              />
            </div>

            <!-- Section 2: Project Settings (only when a project is active) -->
            <%= if @active_project != nil do %>
              <div class="mt-4 pt-4 border-t border-base-200">
                <p class="text-[11px] font-semibold uppercase tracking-wide text-base-content/40 mb-2">
                  {gettext("Project Settings")}
                </p>
                <EvoDashWeb.ProjectComponents.project_settings_tab
                  active_project={@active_project_path}
                  project_config={@project_config}
                  worktree_script={@worktree_script}
                  commands={@commands}
                  foreign_repos={@foreign_repos}
                  show_add_foreign_repo={@show_add_foreign_repo_form}
                  new_repo_id={@new_repo_id}
                  new_repo_path={@new_repo_path}
                  new_repo_description={@new_repo_description}
                  tauri_detected={@tauri_detected}
                  platform={@platform}
                />
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    # On the dead render (initial HTTP request), use server-based detection to
    # decide whether to redirect first-time users to /welcome. The check is
    # backed by EvoGit.Config.VersionState.onboarding_needed?/0 (which reports
    # whether the version-state file has ever been created). It runs ONLY on
    # the dead render; connected mounts skip it to avoid redirect loops.
    onboarding_needed =
      !connected?(socket) and
        if Code.ensure_loaded?(EvoGit.Config.VersionState) do
          EvoGit.Config.VersionState.onboarding_needed?()
        else
          false
        end

    if onboarding_needed do
      {:ok, push_navigate(socket, to: "/welcome")}
    else
      if connected?(socket) do
        Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
        Phoenix.PubSub.subscribe(EvoGit.PubSub, "recent_projects")
        send(self(), :load_config_status)
      end

      recent_projects = TaskRegistry.list_recent_projects()

      # Pre-resolve config once and memoize via Process dict so that the
      # deferred :load_config_status handler can reuse this result instead
      # of re-reading and re-parsing config.toml.
      Process.put(:memo_config_resolve, EvoGit.Config.resolve())

      # Defer config_status to handle_info — it reads config.toml +
      # credentials.toml and is NOT needed for the first paint. The
      # config warning banner can appear a frame later.
      config_status = nil

      {model_profiles, selected_model_id} = Project.load_model_profiles()

      build_systems = EvoGit.Runtime.WorktreeInitScript.build_systems()

      socket =
        assign(socket,
          active_project: nil,
          active_project_path: nil,
          show_open_project_form: false,
          show_new_project_form: false,
          recent_projects: recent_projects,
          path_suggestions: [],
          expanded_task_ids: MapSet.new(),
          selected_result: nil,
          selected_options: nil,
          show_project_settings: false,
          project_config: nil,
          worktree_script: nil,
          commands: %{},
          foreign_repos: [],
          show_add_foreign_repo_form: false,
          new_repo_id: "",
          new_repo_path: "",
          new_repo_description: "",
          address_bar_editing: false,
          show_configure_dropdown: false,
          tasks: [],
          model_profiles: model_profiles,
          selected_model_id: selected_model_id,
          build_systems: build_systems,
          tauri_detected: false,
          platform: "linux",
          notified_task_ids:
            TaskRegistry.list_tasks()
            |> Enum.filter(&(&1.status in [:completed, :failed, :cancelled]))
            |> Enum.map(& &1.id)
            |> MapSet.new()
        )

      socket = Assigns.assign_form_defaults(socket)

      socket =
        assign(socket,
          show_advanced: false,
          task_resume_from: "",
          task_build_system: nil,
          config_status: config_status,
          config_tab: "task_options",
          remote?: false,
          remote_agents: []
        )

      socket = Assigns.assign_running_and_pending_tasks(socket)

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/")
      |> assign(:remote?, socket.assigns.current_node != node())

    # When viewing a remote node, the dashboard shows the remote node's active
    # agents instead of local tasks/projects. Load them here so the render
    # branch has the data.
    socket =
      if socket.assigns.remote? do
        assign(
          socket,
          :remote_agents,
          EvoDash.NodeContext.list_agents(socket.assigns.current_node)
        )
      else
        socket
      end

    # Reload recent projects from the correct node on every handle_params run.
    # When remote, load via RPC; when local, load from the local TaskRegistry.
    # This ensures the project list refreshes on every node switch
    # (local→remote and remote→local).
    socket =
      if socket.assigns.remote? do
        assign(
          socket,
          :recent_projects,
          EvoDash.NodeContext.list_recent_projects(socket.assigns.current_node)
        )
      else
        assign(socket, :recent_projects, TaskRegistry.list_recent_projects())
      end

    project_path = params["project"]

    socket =
      if socket.assigns.remote? do
        # Remote node — do not activate local projects or check local file
        # paths. The remote render branch shows remote agents instead of the
        # project UI. Clear local project assigns so no stale local state
        # leaks into the remote view.
        socket
        |> assign(:active_project, nil)
        |> assign(:active_project_path, nil)
      else
        if project_path && project_path != "" do
          expanded = Path.expand(project_path)

          if File.dir?(expanded) do
            activate_project(socket, expanded)
          else
            # Project path in URL is invalid, clear it
            all_tasks = TaskRegistry.list_tasks()

            socket
            |> Assigns.assign_running_and_pending_tasks(all_tasks)
            |> assign(:tasks, Enum.map(all_tasks, &lightweight_task/1))
            |> assign(
              :notified_task_ids,
              Assigns.build_notified_task_ids(all_tasks, socket.assigns.notified_task_ids)
            )
            |> assign(
              active_project: nil,
              active_project_path: nil
            )
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
                    |> Assigns.assign_running_and_pending_tasks(all_tasks)
                    |> assign(:tasks, Enum.map(all_tasks, &lightweight_task/1))
                    |> assign(
                      :notified_task_ids,
                      Assigns.build_notified_task_ids(all_tasks, socket.assigns.notified_task_ids)
                    )
                  end

                _ ->
                  all_tasks = TaskRegistry.list_tasks()

                  socket
                  |> Assigns.assign_running_and_pending_tasks(all_tasks)
                  |> assign(:tasks, Enum.map(all_tasks, &lightweight_task/1))
                  |> assign(
                    :notified_task_ids,
                    Assigns.build_notified_task_ids(all_tasks, socket.assigns.notified_task_ids)
                  )
              end
            else
              # We had a project but navigated away and back without it
              socket
            end

          socket
        end
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
    # Also restore foreign_repos from the original task so the "continue from
    # here" workflow preserves multi-repo configuration.
    socket =
      case params["resume_from"] do
        task_id when is_binary(task_id) and task_id != "" ->
          socket
          |> assign(:task_resume_from, task_id)
          |> assign(:show_advanced, true)
          |> maybe_restore_foreign_repos_from_task(task_id)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  # --- Project Management Events ---

  @impl true
  def handle_event("toggle_open_project_form", params, socket) do
    ProjectFlow.toggle_open_project_form(socket, params)
  end

  @impl true
  def handle_event("toggle_address_bar", _params, socket) do
    {:noreply,
     socket
     |> assign(:address_bar_editing, !socket.assigns.address_bar_editing)
     |> assign(:show_open_project_form, false)
     |> assign(:show_new_project_form, false)}
  end

  @impl true
  def handle_event("toggle_configure_dropdown", _params, socket) do
    {:noreply, assign(socket, :show_configure_dropdown, !socket.assigns.show_configure_dropdown)}
  end

  @impl true
  def handle_event("close_configure_dropdown", _params, socket) do
    {:noreply, assign(socket, :show_configure_dropdown, false)}
  end

  @impl true
  def handle_event("toggle_new_project_form", params, socket) do
    socket = assign(socket, :address_bar_editing, false)
    ProjectFlow.toggle_new_project_form(socket, params)
  end

  @impl true
  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :show_advanced, !socket.assigns.show_advanced)}
  end

  @impl true
  def handle_event("select_config_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :config_tab, tab)}
  end

  @impl true
  def handle_event("create_project", params, socket) do
    socket = assign(socket, :address_bar_editing, false)
    ProjectFlow.create_project(socket, params)
  end

  @impl true
  def handle_event("open_project", params, socket) do
    socket = assign(socket, :address_bar_editing, false)
    ProjectFlow.open_project(socket, params)
  end

  @impl true
  def handle_event("select_project", params, socket) do
    socket = assign(socket, :address_bar_editing, false)
    ProjectFlow.select_project(socket, params)
  end

  # --- Task Form Events ---

  @impl true
  def handle_event("task_change", %{"mode" => mode}, socket) do
    {:noreply,
     socket
     |> assign(:task_mode, mode)
     |> StatePersistence.maybe_persist_state()}
  end

  @impl true
  def handle_event("select_model", %{"model_id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_model_id, id)
     |> StatePersistence.maybe_persist_state()}
  end

  @impl true
  def handle_event("tauri_detected", %{"tauri" => tauri}, socket) do
    {:noreply, assign(socket, :tauri_detected, tauri)}
  end

  @impl true
  def handle_event("platform_info", %{"platform" => platform}, socket) do
    {:noreply, assign(socket, :platform, platform)}
  end

  @impl true
  def handle_event("restore_state", params, socket) do
    # Don't let restore_state overwrite a starting_commit that came from the URL
    # (set in handle_params from ?starting_commit=... query param)
    socket =
      if socket.assigns.task_starting_commit != "" do
        socket
      else
        StatePersistence.maybe_restore_assign(
          socket,
          :task_starting_commit,
          params["task_starting_commit"]
        )
      end

    # Don't let restore_state overwrite a resume_from that came from the URL
    # (set in handle_params from ?resume_from=... query param)
    socket =
      if socket.assigns.task_resume_from != "" do
        socket
      else
        StatePersistence.maybe_restore_assign(
          socket,
          :task_resume_from,
          params["task_resume_from"]
        )
      end

    socket =
      socket
      |> StatePersistence.maybe_restore_assign(:task_prompt, params["task_prompt"])
      |> StatePersistence.maybe_restore_show_project_settings(params["show_project_settings"])
      |> StatePersistence.maybe_restore_task_archive(params["task_archive"])
      |> StatePersistence.maybe_restore_show_advanced(params["show_advanced"])
      |> StatePersistence.maybe_restore_assign(:selected_model_id, params["selected_model_id"])

    # Always restore task_mode from sessionStorage — the user's explicit choice
    # takes precedence over auto-detection when returning to a project.
    socket = StatePersistence.maybe_restore_assign(socket, :task_mode, params["task_mode"])

    # Restore project if we don't already have one active.
    # Only restore project-specific assigns (node_path) when no project is
    # active — otherwise the auto-detected values from detect_mode/1 should win.
    socket =
      if is_nil(socket.assigns.active_project) do
        socket =
          socket
          |> StatePersistence.maybe_restore_assign(:task_node_path, params["task_node_path"])

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
    socket = StatePersistence.maybe_restore_foreign_repos(socket, params["foreign_repos"])

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
          Keyword.put(opts, :prompt, String.trim(prompt))
        else
          Keyword.put(opts, :objective, String.trim(prompt))
        end

      build_system_param = params["build_system"]

      opts =
        if task_type == :genesis and is_binary(build_system_param) and
             String.trim(build_system_param) != "" do
          Keyword.put(opts, :build_system, String.to_existing_atom(build_system_param))
        else
          opts
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

      # Include foreign repos from project settings for this task
      foreign_repos = socket.assigns[:foreign_repos] || []

      opts =
        if foreign_repos != [], do: Keyword.put(opts, :foreign_repos, foreign_repos), else: opts

      opts = if archive, do: Keyword.put(opts, :archive, true), else: opts

      # Thread the selected model profile id into opts (if non-nil/non-empty).
      # The runtime uses this to select which [[llm.models]] profile to use.
      selected_model_id = socket.assigns[:selected_model_id]

      opts =
        if is_binary(selected_model_id) and selected_model_id != "",
          do: Keyword.put(opts, :model_id, selected_model_id),
          else: opts

      resume_from = params["resume_from"]

      opts =
        if task_type == :evolve and is_binary(resume_from) and String.trim(resume_from) != "" do
          Keyword.put(opts, :resume_from, String.trim(resume_from))
        else
          opts
        end

      case TaskRegistry.start_task(task_type, opts) do
        {:ok, task} ->
          all_tasks = TaskRegistry.list_tasks_by_path(path)

          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("%{type} task started with ID: %{id}",
               type: String.capitalize(to_string(task_type)),
               id: task.id
             )
           )
           |> Assigns.assign_running_and_pending_tasks(all_tasks)
           |> assign(:tasks, Enum.map(all_tasks, &lightweight_task/1))
           |> Assigns.assign_form_defaults()
           |> StatePersistence.maybe_persist_state()}

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
        all_tasks = Assigns.current_tasks(socket)

        {:noreply,
         socket
         |> Assigns.assign_running_and_pending_tasks(all_tasks)
         |> assign(:tasks, Enum.map(all_tasks, &lightweight_task/1))
         |> assign(:expanded_task_ids, expanded)}

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
    view_full_result(socket, task_id)
  end

  @impl true
  def handle_event("close_result_modal", _params, socket) do
    close_result_modal(socket)
  end

  @impl true
  def handle_event("view_full_options", %{"task_id" => task_id}, socket) do
    view_full_options(socket, task_id)
  end

  @impl true
  def handle_event("close_options_modal", _params, socket) do
    close_options_modal(socket)
  end

  @impl true
  def handle_event("clear_task_history", _params, socket) do
    TaskRegistry.clear_finished_tasks()
    all_tasks = Assigns.current_tasks(socket)

    {:noreply,
     socket
     |> Assigns.assign_running_and_pending_tasks(all_tasks)
     |> assign(:tasks, Enum.map(all_tasks, &lightweight_task/1))
     |> assign(:expanded_task_ids, MapSet.new())}
  end

  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    TaskRegistry.delete_task(task_id)
    expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)
    all_tasks = Assigns.current_tasks(socket)

    {:noreply,
     socket
     |> Assigns.assign_running_and_pending_tasks(all_tasks)
     |> assign(:tasks, Enum.map(all_tasks, &lightweight_task/1))
     |> assign(:expanded_task_ids, expanded)}
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
  def handle_event("toggle_project_settings", _params, socket) do
    new_show = !socket.assigns.show_project_settings

    {:noreply,
     socket
     |> assign(:show_project_settings, new_show)
     # When expanding, switch the config dropdown to the Project Settings tab
     # so its content is visible. (Backwards-compatible entry point for tests
     # and any external callers of the toggle_project_settings event.)
     |> then(fn s ->
       if new_show, do: assign(s, :config_tab, "project_settings"), else: s
     end)
     |> StatePersistence.maybe_persist_state()}
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

      not Platform.absolute_path?(path) ->
        {:noreply, put_flash(socket, :error, gettext("Path must be absolute."))}

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
           |> StatePersistence.maybe_persist_state()
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
         |> StatePersistence.maybe_persist_state()
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
    suggestions = Project.path_suggestions(value)
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
  def handle_info({:node_selected, node_id}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)
  end

  @impl true
  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)
  end

  @impl true
  def handle_info({:tasks_updated}, socket) do
    new_tasks = Assigns.current_tasks(socket)

    # Refresh project settings if shown (foreign repos are in-memory, not re-read)
    socket =
      if socket.assigns.show_project_settings and socket.assigns.active_project_path do
        {project_config, worktree_script, commands} =
          Project.load_project_config(socket.assigns.active_project_path)

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
        {title, body} = Project.task_notification_content(task)
        push_event(sock, "task_notification", %{title: title, body: body})
      end)

    {:noreply,
     socket
     |> assign(:notified_task_ids, updated_notified)
     |> Assigns.assign_running_and_pending_tasks(new_tasks)
     |> assign(:tasks, Enum.map(new_tasks, &lightweight_task/1))}
  end

  @impl true
  def handle_info({:task_status, _task_id, _status}, socket) do
    all_tasks = Assigns.current_tasks(socket)

    {:noreply,
     socket
     |> Assigns.assign_running_and_pending_tasks(all_tasks)
     |> assign(:tasks, Enum.map(all_tasks, &lightweight_task/1))}
  end

  @impl true
  def handle_info({:recent_projects_updated}, socket) do
    {:noreply, assign(socket, :recent_projects, TaskRegistry.list_recent_projects())}
  end

  @impl true
  def handle_info(:load_config_status, socket) do
    # config_status/0 (imported from EvoDashWeb.Helpers) reads config.toml +
    # credentials.toml and computes the config warning banner data.
    # This is deferred from mount/3 to avoid blocking first paint.
    # The Process dict memoization set up in mount/3 primes the OS file
    # cache so this deferred read is fast.
    {:noreply, assign(socket, :config_status, config_status())}
  end

  # Restores foreign_repos from a previous task's opts when resuming ("continue from here").
  #
  # Looks up the task by id, extracts `task.opts[:foreign_repos]`, and converts the
  # values to `%ForeignRepo{}` structs. Handles both:
  #   - Fresh `%ForeignRepo{}` structs (from an in-memory task)
  #   - Maps with `"root"` key (Jason-decoded from the DB, via `@derive {Jason.Encoder}`)
  #   - Maps with `"path"` key (sessionStorage serialization format, as a fallback)
  defp maybe_restore_foreign_repos_from_task(socket, task_id) do
    case TaskRegistry.get_task(task_id) do
      nil ->
        socket

      task ->
        case task.opts[:foreign_repos] do
          nil ->
            socket

          [] ->
            socket

          repos when is_list(repos) ->
            converted =
              Enum.map(repos, fn
                %ForeignRepo{} = repo ->
                  repo

                repo when is_map(repo) ->
                  id = Map.get(repo, "id") || Map.get(repo, :id) || "primary"
                  root = Map.get(repo, "root") || Map.get(repo, "path") || Map.get(repo, :root)
                  desc = Map.get(repo, "description") || Map.get(repo, :description)

                  opts = if is_binary(desc) and desc != "", do: [description: desc], else: []
                  ForeignRepo.new(id, root, opts)

                _ ->
                  nil
              end)
              |> Enum.reject(&is_nil/1)

            if converted != [] do
              sorted =
                Enum.sort_by(converted, fn repo ->
                  {if(ForeignRepo.primary?(repo.id), do: 0, else: 1), repo.id}
                end)

              assign(socket, :foreign_repos, sorted)
            else
              socket
            end
        end
    end
  end

  # Strips heavy fields from a %TaskInfo{} struct to reduce binary retention
  # in LiveView assigns. The stripped fields (logs, result, usage, archive_metadata)
  # are the primary sources of ~30MB memory pressure from holding full task data.
  defp lightweight_task(task) do
    %{task | logs: [], result: nil, usage: nil, archive_metadata: nil}
  end

  defp activate_project(socket, path) do
    name = Path.basename(path)
    is_project_change = socket.assigns[:active_project_path] != path

    # Only auto-detect mode when switching to a different project.
    # Preserve the user's manual mode selection on re-navigation/reconnect.
    {mode, mode_info} =
      if is_project_change do
        detected = Project.detect_mode(path)
        {detected, mode_info_message(detected)}
      else
        current_mode = socket.assigns[:task_mode]
        {current_mode, socket.assigns[:task_mode_info]}
      end

    tasks = TaskRegistry.list_tasks_by_path(path)

    # Load project settings eagerly — read genesis.toml once and thread
    # through all consumers to avoid redundant disk reads.
    config = ProjectConfig.read(path)
    {project_config, worktree_script, commands} = Project.load_project_config(path, config)
    foreign_repos = Project.load_foreign_repos(path, config)

    socket
    |> assign(
      active_project: %{path: path, name: name},
      active_project_path: path,
      tasks: Enum.map(tasks, &lightweight_task/1),
      notified_task_ids: Assigns.build_notified_task_ids(tasks, socket.assigns.notified_task_ids),
      task_mode: mode,
      task_mode_info: mode_info,
      show_open_project_form: false,
      show_new_project_form: false,
      show_project_settings: false,
      project_config: project_config,
      worktree_script: worktree_script,
      commands: commands,
      foreign_repos: foreign_repos,
      show_add_foreign_repo_form: false
    )
    |> Assigns.assign_running_and_pending_tasks(tasks)
    |> Project.maybe_put_flash_mode_info(mode_info)
  end
end
