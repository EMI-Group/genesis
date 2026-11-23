defmodule EvoDashWeb.ProjectsLive do
  @moduledoc """
  Project-based task dashboard for launching and monitoring EvoGit tasks.

  Users open a repository, and the dashboard auto-detects the task mode
  (genesis or evolve). Displays active tasks with live logs and inline
  project settings including foreign repositories.
  """
  use EvoDashWeb, :live_view
  alias EvoGit.TaskRegistry

  alias EvoDash.SafeCall

  alias EvoDashWeb.ProjectsLive.{
    StatePersistence,
    Project,
    Assigns,
    ProjectFlow,
    RemoteView,
    Attachments,
    GitHub,
    AsyncLoad,
    ModelSelectionScope,
    Notifications,
    TaskSubmit,
    Commands,
    Palette,
    Workspace,
    ForeignRepos
  }

  alias EvoDashWeb.ThemeColor
  alias EvoDashWeb.LLMSelection
  alias EvoDash.NodeContext
  alias EvoGit.ProjectConfig

  # Picker id for the objective editor's attach-file button — must match the
  # `data-picker-id` on the FilePicker hook button in
  # EvoDashWeb.TaskFormComponents.task_form/1 and the `@attach_picker_id`
  # literal in the AttachFile support module (kept as a literal in both
  # modules — a compile-time function call in a module attribute is fragile
  # under parallel compilation).
  #
  # Image/audio picker ids follow the same literal-duplication contract — they
  # pair with the @attach_picker_id_image / @attach_picker_id_audio literals in
  # the AttachFile support module (its start_binary_read/4 pushes the result on
  # the kind's picker channel), which is edited in parallel.
  @attach_picker_id "objective_file"
  @attach_picker_id_image "objective_file_image"
  @attach_picker_id_audio "objective_file_audio"

  # Speed ↔ quality segmented control values (STRING, mirrors :mode). The
  # default "balanced" is the untouched/absent case — see do_task_submit/4.
  @quality_levels ~w(fast balanced high_quality)

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @live_action == :system_dashboard do %>
      <EvoDashWeb.Layouts.app
        flash={@flash}
        current_page={:phx_dashboard}
        config_status={@config_status}
        current_node_id={@current_node_id}
        remote_targets={assigns[:remote_targets] || []}
        connection_statuses={assigns[:connection_statuses] || %{}}
        current_node_name={@current_node_name}
        running_tasks={@running_tasks}
        session_list={assigns[:session_list] || []}
        session_list_loading={assigns[:session_list_loading] == true}
        session_list_error={assigns[:session_list_error]}
        current_session_id={assigns[:current_session_id]}
        pending_tasks={@pending_tasks}
        desktop_quit_confirm={@desktop_quit_confirm}
        update_status={@update_status}
        guide={@guide}
        accent_color={assigns[:accent_color] || "blue"}
      >
        <%!--
          Full-bleed Phoenix LiveDashboard: no header chrome — the iframe
          fills the entire main content area. `main#main-content` is the
          `flex-1 min-h-0` page box inside the shell, so its content box
          already excludes the persistent top bar and the main padding;
          `.shell-fill` (height: 100%) spans exactly that area with no
          viewport math, which keeps it correct if the shell chrome changes.
        --%>
        <iframe
          src={~p"/phoenix/dashboard/home"}
          class="w-full shell-fill"
          style="border: none;"
          title="Phoenix LiveDashboard"
        ></iframe>
      </EvoDashWeb.Layouts.app>
    <% else %>
      <% selecting_workbench_project? = get_in(@workbench_reconnect_params, ["wb_home"]) == "1" %>
      <% draft_scope = StatePersistence.draft_scope(assigns) %>
      <% workbench_project =
        if selecting_workbench_project?,
          do:
            (@workbench_project_selection && @workbench_project_selection.path) ||
              @remote_project_loading || @active_project_path,
          else: @active_project_path %>
      <EvoDashWeb.Layouts.app
        flash={@flash}
        current_page={:dashboard}
        config_status={@config_status}
        current_node_id={@current_node_id}
        remote_targets={assigns[:remote_targets] || []}
        connection_statuses={assigns[:connection_statuses] || %{}}
        workbench_project={workbench_project}
        workbench_git_project={if workbench_project == @active_project_path, do: @active_project_path}
        workbench_git_branch={@workbench_reconnect_params["wb_git_branch"]}
        workbench_starting_commit={@workbench_reconnect_params["starting_commit"]}
        github_status={@github_status}
        current_node_name={@current_node_name}
        running_tasks={@running_tasks}
        session_list={assigns[:session_list] || []}
        session_list_loading={assigns[:session_list_loading] == true}
        session_list_error={assigns[:session_list_error]}
        current_session_id={assigns[:current_session_id]}
        pending_tasks={@pending_tasks}
        desktop_quit_confirm={@desktop_quit_confirm}
        update_status={@update_status}
        accent_color={assigns[:accent_color] || "blue"}
      >
        <%!--
          --project-accent carries the TASK-MODE accent: genesis_new → red,
          genesis_existing → blue, evolve_simple → green (lighter green when a
          resume task id is set — evolve only), custom_agent → violet (lighter
          violet on resume — custom runs are evolve-family). It drives the
          objective box (.input-card). --project-ring-accent carries the
          PROJECT-NAME-HASH accent (ThemeColor.accent_color/1) — stable per
          project name — and drives the top-bar project ring
          (.project-palette-trigger:hover). The --project-accent var name is
          historical; renaming it would require touching assets/css/app.css
          (out of scope).
        --%>
        <div
          id="dashboard-root"
          phx-hook={unless @workbench_idle?, do: "StatePersistence"}
          data-workbench-compose={to_string(!@workbench_idle?)}
          data-project={workbench_project}
          data-task-draft-project={@workbench_reconnect_params["project"]}
          data-task-draft-scope={draft_scope}
          data-task-mode={@task_mode}
          data-node-id={@current_node_id || "local"}
          class="flex flex-col min-h-full"
          style={
            "--project-accent: #{ThemeColor.accent_color_for_mode(@task_mode, @task_resume_from)}; --project-ring-accent: #{ThemeColor.accent_color(@active_project && @active_project.name)}"
          }
        >
          <div id="tauri-detect" phx-hook="TauriDetect" class="hidden"></div>
          <div id="platform-detect" phx-hook="PlatformDetect" class="hidden"></div>
          <div
            id="browser-notifications"
            phx-hook="BrowserNotifications"
            class="flex-1 flex flex-col min-h-0 space-y-4"
          >
            <div
              :if={!@workbench_idle? and not is_nil(@model_selection_error)}
              id="model-selection-error"
              role="alert"
              class="flex items-center gap-3 rounded-lg border border-warning/30 bg-warning/10 p-4 text-sm"
            >
              <p class="flex-1">
                {gettext(
                  "Could not load model selection. Your choice has been kept. Reconnect to the node if needed, then retry before launching a task."
                )}
              </p>
              <button
                type="button"
                phx-click="retry_model_selection"
                disabled={
                  ModelSelectionScope.pending_remote?(assigns) or
                    EvoDashWeb.RemoteGateComponents.gate_active?(assigns)
                }
                class="btn btn-sm btn-outline"
              >
                {gettext("Retry")}
              </button>
            </div>
            <%!-- Node-context gate: `phase` drives the render branches below.
                 `@remote_status` is a %{phase: ...} map in ANY remote context
                 (set by NodeAware.assign_node/2); a missing/absent status with
                 `@current_node_id` set is treated as connecting so no local
                 data is ever shown for an unresolved remote context. --%>
            <% phase =
              case @remote_status do
                %{phase: p} -> p
                _ -> :connecting
              end %>
            <EvoDashWeb.ProjectComponents.project_omnibox
              :if={@project_palette_open and !EvoDashWeb.RemoteGateComponents.gate_active?(assigns)}
              show_trigger={false}
              projects={@projects}
              palette_open={@project_palette_open}
              palette_search={@palette_search}
              palette_mode={@palette_mode}
              palette_selected_index={@palette_selected_index}
              workspaces={@workspaces}
              expanded_workspaces={@expanded_workspaces}
              new_workspace_members={@new_workspace_members}
              path_suggestions={@path_suggestions}
              tauri_detected={@tauri_detected}
              platform={@platform}
              remote={@remote?}
            />
            <%= cond do %>
              <% @remote_project_loading != nil and !selecting_workbench_project? and
                   !EvoDashWeb.RemoteGateComponents.gate_active?(assigns) -> %>
                <div id="workbench-project-loading" class="workbench-idle" role="status">
                  {gettext("Loading project…")}
                </div>
              <% !EvoDashWeb.RemoteGateComponents.gate_active?(assigns) and
                   (@workbench_idle? or is_nil(@active_project)) -> %>
                <div id="workbench-idle" class="workbench-idle" role="status">
                  <p data-workbench-idle-projects hidden={!is_nil(workbench_project)}>
                    {gettext("No projects")}
                  </p>
                  <p data-workbench-idle-window hidden={is_nil(workbench_project)}>
                    {gettext("No window selected")}
                  </p>
                </div>
              <% is_nil(@current_node_id) or @remote? -> %>
                <div
                  id="workbench-task-composer"
                  phx-hook="WorkbenchSection"
                  class="flex-1 flex flex-col min-h-0"
                >
                  <EvoDashWeb.TaskFormComponents.task_form
                    prompt={@task_prompt}
                    mode={@task_mode}
                    node_path={@task_node_path}
                    starting_commit={@task_starting_commit}
                    resume_from={@task_resume_from}
                    archive={@task_archive}
                    persist_agent_state?={@persist_agent_state?}
                    provider_profiles={@provider_profiles}
                    model_selections={@model_selections}
                    model_spec={@selected_model_spec}
                    launch_disabled={!@model_selection_ready? || @model_selections == []}
                    custom_agents={@custom_agents}
                    selected_agent_id={@selected_agent_id}
                    quality_level={@quality_level}
                    show_auto_model_option={@model_selection_enabled}
                    build_systems={@build_systems}
                    selected_build_system={@task_build_system}
                    staged_attachments={@staged_attachments}
                  >
                    <:controls>
                      <button
                        :if={@model_selection_ready? && @model_selections == []}
                        id="task-model-setup"
                        type="button"
                        class="btn btn-sm btn-ghost"
                        data-workbench-settings={
                          EvoDashWeb.WorkbenchComponent.navigation_path(
                            ~p"/settings/window",
                            @current_node_id,
                            category: "llm"
                          )
                        }
                      >
                        <.icon name="hero-adjustments-horizontal" class="size-4" />
                        {gettext("Configure a model")}
                      </button>
                      <span
                        :if={!@model_selection_ready? && is_nil(@model_selection_error)}
                        id="model-selection-loading"
                        class="flex items-center gap-2 shrink-0 text-xs text-base-content/70"
                        role="status"
                      >
                        <span>{gettext("Loading models…")}</span>
                        <button
                          id="model-selection-loading-retry"
                          type="button"
                          phx-click="retry_model_selection"
                          disabled={
                            ModelSelectionScope.pending_remote?(assigns) or
                              EvoDashWeb.RemoteGateComponents.gate_active?(assigns)
                          }
                          class="btn btn-sm btn-outline"
                        >
                          {gettext("Retry")}
                        </button>
                      </span>
                      <span
                        :if={
                          git_task_draft?(@workbench_reconnect_params) &&
                            @task_mode == "evolve_simple"
                        }
                        id="workbench-task-git-base"
                        class="workbench-task-git-base"
                        title={@task_starting_commit}
                      >
                        <.icon name="hero-code-bracket" class="size-4 shrink-0" />
                        <span class="truncate">{@workbench_reconnect_params["wb_git_branch"]}</span>
                      </span>
                      <button
                        type="button"
                        class="workbench-icon-button shrink-0"
                        data-workbench-task-settings
                        aria-haspopup="dialog"
                        aria-controls="workbench-task-settings"
                        aria-label={gettext("Configure")}
                        title={gettext("Configure")}
                      >
                        <.icon name="hero-adjustments-horizontal" class="size-4" />
                      </button>
                    </:controls>
                  </EvoDashWeb.TaskFormComponents.task_form>
                  <RemoteView.task_configuration
                    active_project_path={@active_project_path}
                    tauri_detected={@tauri_detected}
                    platform={@platform}
                    task_mode={@task_mode}
                    task_node_path={@task_node_path}
                    task_starting_commit={@task_starting_commit}
                    task_resume_from={@task_resume_from}
                    task_archive={@task_archive}
                    persist_agent_state?={@persist_agent_state?}
                    build_systems={@build_systems}
                    task_build_system={@task_build_system}
                    project_config={@project_config}
                    worktree_script={@worktree_script}
                    commands={@commands}
                    foreign_repos={@foreign_repos}
                    foreign_repo_path_suggestions={@foreign_repo_path_suggestions}
                    show_add_foreign_repo_form={@show_add_foreign_repo_form}
                    new_repo_id={@new_repo_id}
                    new_repo_path={@new_repo_path}
                    new_repo_description={@new_repo_description}
                    remote={@remote?}
                  />
                </div>
              <% phase in [:connecting, :bootstrapping, :disconnecting] -> %>
                <!-- Pending remote context: connecting chrome only — no
                     project data, no task form, no local project list (the
                     node-switch clear already reset project state). -->
                <RemoteView.connecting_state current_node_name={@current_node_name} />
              <% true -> %>
                <!-- Failed/disconnected remote context: prominent error state
                     with Retry / Manage Connections / Switch to Local. -->
                <RemoteView.error_state
                  current_node_name={@current_node_name}
                  last_error={Map.get(@remote_status || %{}, :last_error)}
                />
            <% end %>
            <%!-- end of node-context cond --%>

            <%= if @github_modal_open do %>
              <EvoDashWeb.GitHubComponents.issues_modal
                github_status={@github_status}
                issues={@github_issues}
                fixing={@github_fixing}
              />
            <% end %>
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
      class="select select-ghost select-sm bg-transparent font-medium min-w-32"
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

  @impl true
  def mount(_params, _session, socket) do
    title =
      if socket.assigns.live_action == :system_dashboard,
        do: gettext("System Dashboard"),
        else: gettext("Projects")

    socket = assign(socket, :page_title, title)

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
        Phoenix.PubSub.subscribe(EvoGit.PubSub, "vct")
        # Config changes (a Settings save, a CLI/MCP write, another tab) must
        # refresh the canonical picker bundle — see the `{:config_reloaded, …}`
        # handler.
        Phoenix.PubSub.subscribe(EvoGit.PubSub, "config")
        send(self(), :load_config_status)
      end

      # ZERO project-registry / task-store calls on the mount path: both the
      # VCT project list and the notified-terminal-id seed are loaded by the
      # connected AsyncLoad batch (AsyncLoad.maybe_spawn/2 in handle_params/3)
      # — a registry `GenServer.call` can take seconds (full-row decode) and
      # EXITS the caller on timeout/dead server, which would crash the page.
      # The empty seeds below are replaced a frame later; project
      # auto-activation is likewise deferred to that continuation
      # (maybe_auto_activate_project/1).
      projects = []

      # Pre-resolve config once and memoize via Process dict so that the
      # deferred :load_config_status handler can reuse this result instead
      # of re-reading and re-parsing config.toml.
      Process.put(:memo_config_resolve, EvoGit.Config.resolve())

      # Defer config_status to handle_info — it reads config.toml +
      # credentials.toml and is NOT needed for the first paint. The
      # config warning banner can appear a frame later.
      config_status = nil

      # The canonical picker is loaded by AsyncLoad after node resolution;
      # never seed a remote page with the local node's model selection.

      # Custom agents + model-selection script state for the task form's
      # agent select and the model select's "Auto (by rules)" option.
      # Node-aware (reads the node being viewed), degrading gracefully.
      {custom_agents, model_selection_enabled} =
        AsyncLoad.load_custom_agents(socket.assigns[:current_node])

      build_systems = EvoGit.Runtime.WorktreeInitScript.build_systems()

      socket =
        assign(socket,
          active_project: nil,
          active_project_path: nil,
          # In-flight remote project activation (the path being loaded). nil
          # = no activation in flight; set by
          # ProjectFlow.spawn_remote_project_activation/2 and cleared by the
          # {:async_remote_project, ...} continuation (or the node-switch
          # state clear, which drops in-flight results from an old node).
          remote_project_loading: nil,
          workbench_project_selection: nil,
          project_palette_open: false,
          palette_search: "",
          palette_mode: :menu,
          palette_selected_index: 0,
          projects: projects,
          # VCT WORKSPACE views (`%{workspace: mount, resolved: [mount],
          # missing: [ref], nested: [ref]}`) for the palette's Workspaces
          # section, the points whose member list is expanded, and the ORDERED
          # member refs chosen in the New Workspace form. All three are filled
          # by the async load / palette events — never on the mount path.
          workspaces: [],
          expanded_workspaces: [],
          new_workspace_members: [],
          path_suggestions: [],
          foreign_repo_path_suggestions: [],
          show_project_settings: false,
          project_config: nil,
          # Mtime of the active project's genesis.toml captured WITH
          # `project_config`: the task-broadcast debounce compares it against a
          # cheap File.stat before deciding to re-parse (never re-parses
          # unchanged settings). nil = not read yet / no file.
          project_config_mtime: nil,
          worktree_script: nil,
          commands: %{},
          foreign_repos: [],
          show_add_foreign_repo_form: false,
          new_repo_id: "",
          new_repo_path: "",
          new_repo_description: "",
          new_repo_base_sha: "",
          editing_foreign_repo_id: nil,
          foreign_repo_edit_form: nil,
          model_selection: nil,
          model_selection_scope: nil,
          model_selection_ready?: false,
          model_selection_error: nil,
          provider_profiles: [],
          model_selections: [],
          selected_model_spec: nil,
          pending_model_selection: nil,
          custom_agents: custom_agents,
          selected_agent_id: nil,
          quality_level: "balanced",
          model_selection_enabled: model_selection_enabled,
          build_systems: build_systems,
          tauri_detected: false,
          platform: "linux",
          # Browser-notification diffing state (LOCAL contexts only). The set
          # starts EMPTY and `notified_task_ids_ready?` false: notification
          # detection is skipped entirely until the async seed marks it ready —
          # scanning against an empty set would fire a notification for every
          # historical task.
          notified_task_ids: MapSet.new(),
          notified_task_ids_ready?: false,
          # Monotonic stale-guards for the async store reads.
          task_notifications_seq: 0,
          projects_seq: 0,
          workspaces_seq: 0,
          # Monotonic stale-guard for the ASYNC workspace create/replace. It is
          # deliberately SEPARATE from `workspaces_seq`: `EvoGit.VCT` broadcasts
          # `{:vct_updated, node}` BEFORE it replies, so the broadcast's
          # `reload_vct/1` always bumps `workspaces_seq` first and a guard on
          # that seq would drop every `{:workspace_created, …}` continuation
          # (losing the flash, the return to the palette menu and the expanded
          # row). Only a newer CREATE invalidates an older create's result.
          workspace_create_seq: 0,
          # Monotonic stale-guard for the async clear-history batch.
          clear_history_seq: 0,
          # Monotonic stale-guards + in-flight markers for the two async
          # foreground operations the page no longer blocks on: a
          # project-configured command (`run_command`, up to 30 s) and the
          # task launch itself. Both results land as messages guarded by these
          # seqs.
          command_seq: 0,
          command_running: nil,
          task_launch_seq: 0,
          task_launching: false,
          # True when this handle_params run has no `?project=` and is on the
          # local node — the async load continuation then auto-activates the
          # newest-opened project (replaces the old synchronous mount seed).
          auto_activate_candidate?: false,
          # Resume foreign-repos restore in flight for this task id (guards
          # task_submit until the restore lands).
          foreign_repos_restoring_from: nil,
          # Guards the genesis.toml reload of an AsyncLoad batch against a
          # resume-restored task foreign-repo list (see
          # maybe_flag_resume_foreign_repos/1).
          resume_foreign_repos_guard: false,
          # Prompt snapshot per attach-file picker id, taken when the native
          # file dialog opens (see handle_event("file_pick")) so the picked
          # file's text can be appended even if the user keeps typing while
          # the dialog is open.
          file_pick_bases: %{},
          # Attach-file reads in flight: `picker_id => base prompt` for every
          # pick whose file read is still running off-process (see
          # start_text_attach/3 + start_binary_attach/4). Doubles as the guard
          # the `{{:attachment_loaded, ...}}` handler keys on: a result whose
          # picker id is no longer pending was superseded by a newer pick (or
          # cleared by a node switch) and is dropped, never applied.
          attach_pending: %{},
          # Server-side-only in-memory staging of RAW attachment binaries
          # (image/audio). Never persisted (StatePersistence keeps a fixed key
          # list) and never restored across remounts/refresh/resume (a
          # documented limitation); each entry's "data" is raw binary and must
          # never be rendered, logged, or serialized — base64 encoding happens
          # only when building the task opt at submit.
          staged_attachments: [],
          # GitHub issue integration: async-detected upstream status, issues
          # modal state, and the issue number whose markdown is being fetched
          # (per-row "Fix" spinner). All GitHub data access is async via
          # EvoDashWeb.ProjectsLive.GitHub — never on the page-load path.
          github_status: nil,
          github_modal_open: false,
          github_issues: GitHub.idle_issues(),
          github_fixing: nil
        )

      socket = Assigns.assign_form_defaults(socket)

      socket =
        assign(socket,
          show_advanced: false,
          task_resume_from: "",
          task_build_system: nil,
          config_status: config_status,
          # `{config_dir, generation}` of the last `{:config_reloaded, node,
          # dir, generation}` broadcast that actually re-spawned the picker
          # batch (nil before the first one): a repeat or older generation for
          # the same config dir never spawns again, a different dir is a new
          # identity.
          config_generation: nil,
          config_tab: "task_options",
          remote?: false
        )

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    prev_node_id = socket.assigns[:current_node_id]
    prev_scope = ModelSelectionScope.current(socket.assigns)

    # NOTE: `remote?` must be derived from the socket AFTER `assign_node/2`
    # re-assigns `current_node` — computing it inside the pipe from the outer
    # `socket` variable would read the PRE-assign_node value, so a page load at
    # a connected `?node=` URL would render the error gate on the first pass.
    socket =
      EvoDashWeb.LiveHooks.NodeAware.assign_node(socket, params, preserve_unresolved?: true)

    socket = assign(socket, :current_path, ~p"/projects")

    socket = assign(socket, :remote?, socket.assigns.current_node != node())

    node_context_changed? = prev_scope != ModelSelectionScope.current(socket.assigns)

    # Auto-activation candidate: no `?project=` in the URL and a LOCAL context.
    # The actual activation runs in the AsyncLoad continuation once the projects
    # have been loaded (maybe_auto_activate_project/1) — the mount seeds no
    # projects, so nothing can be activated synchronously here.
    socket =
      assign(
        socket,
        :auto_activate_candidate?,
        is_nil(params["project"]) and is_nil(socket.assigns[:current_node_id])
      )

    # Node-aware refresh (custom agents + model-selection script state,
    # canonical provider/model/reasoning picker, remote
    # project config, and projects) now runs in ONE
    # async task so the LiveView process never blocks on cross-node RPCs —
    # see EvoDashWeb.ProjectsLive.AsyncLoad. The spawn sits after the
    # node-switch clearing and the project-activation block below so it
    # captures the post-clear, post-activation active project path; mount/3
    # already seeded every affected assign with safe defaults, and the async
    # result (a stale-guarded
    # `{:async_project_load, node, prev_node_id, path, results}` message)
    # overrides them a frame later.

    # Each node context (local + each remote target) has its own persisted
    # dashboard state; switching nodes clears the client-side state and
    # re-persists it under the new node key so no state leaks across nodes.
    socket =
      StatePersistence.maybe_clear_state_on_node_switch(
        socket,
        prev_node_id,
        socket.assigns[:current_node_id]
      )

    # Attach-file flow: the prompt snapshot taken when the file dialog opened
    # (file_pick_bases) is per-node client state — clear it alongside the
    # other client state on node switches (mirrors the StatePersistence
    # clearing above; that module owns task_prompt and friends, this assign
    # is LiveView-local). The GitHub issue state is per-node too: a stale
    # :ok status from the previous node must never render the GitHub button
    # for the wrong node (results are stale-guarded on node, but an already
    # resolved status would survive the switch otherwise).
    socket =
      if node_context_changed? do
        socket
        |> assign(:file_pick_bases, %{})
        # An in-flight attach read belongs to the previous node, so its result
        # must not be applied here once it lands.
        |> assign(:attach_pending, %{})
        # Staged raw attachment binaries are per-node client state too — drop
        # them alongside the other state on node switches (raw "data" bytes
        # must never leak across node contexts).
        |> assign(:staged_attachments, [])
        |> assign(:remote_project_loading, nil)
        |> assign(:foreign_repos_restoring_from, nil)
        |> assign(:resume_foreign_repos_guard, false)
        |> assign(:github_status, nil)
        |> assign(:github_modal_open, false)
        |> assign(:github_issues, GitHub.idle_issues())
        |> assign(:github_fixing, nil)
        # VCT workspaces are per-node registry rows: a remote view must never
        # render (or keep expanding) another node's groups, and a half-built
        # member selection from the old node must not be submitted here.
        |> assign(:workspaces, [])
        |> assign(:expanded_workspaces, [])
        |> assign(:new_workspace_members, [])
      else
        socket
      end

    socket =
      assign(socket,
        workbench_reconnect_params:
          Map.take(params, ~w(project wb_open wb_home wb_task wb_git_branch starting_commit)),
        workbench_open_requested: params["wb_open"] == "1",
        workbench_idle?:
          params["wb_home"] == "1" or
            Enum.all?(~w(project starting_commit resume_from), &is_nil(params[&1]))
      )

    project_path = params["project"]

    socket =
      if params["wb_home"] != "1" or node_context_changed? or
           get_in(socket.assigns, [:workbench_project_selection, :requested_path]) != project_path do
        socket
        |> cancel_async(:workbench_project_selection)
        |> assign(:workbench_project_selection, nil)
      else
        socket
      end

    # An in-flight activation cannot select a project after navigation has
    # moved back to another project (including the already active one).
    socket =
      if socket.assigns.remote_project_loading != project_path,
        do: assign(socket, :remote_project_loading, nil),
        else: socket

    socket =
      if socket.assigns[:current_node_id] != nil do
        # Remote context. A `?project=` URL param — a plain remote open
        # (`/projects?project=<remote path>&node=<id>`) or the Review-page
        # "continue task" resume landing (`...&resume_from=<id>&starting_commit=<sha>`,
        # which appends `project` + `node` via a manual `&node=` suffix) — is
        # routed through the SAME async remote-activation machinery the
        # palette remote open/select uses: `ProjectFlow.spawn_remote_project_activation/2`,
        # or the resume-aware `/3` variant when `resume_from` is present (it
        # additionally restores the previous task's foreign repos INSIDE the
        # activation task). Remote paths NEVER touch the local filesystem:
        # normalization is remote-aware (`ProjectFlow.normalize_remote_project_path/2`
        # — no local `Path.expand`) and existence is validated via the
        # `NodeContext.dir?/2` RPC in the activation task.
        #
        # Gating: while the selected target is pending/connecting (gate
        # active) `@current_node` is still the LOCAL BEAM node, so nothing is
        # activated — the connecting gate chrome renders instead. A URL
        # project that already equals the active project (the push_patch after
        # a successful activation re-runs handle_params with the normalized
        # path) is a no-op — no activate→patch→activate loop (the
        # same-path-in-flight guard in `spawn_remote_project_activation` covers
        # double-Enter within one frame). All other remote handle_params runs
        # (no project param) keep skipping local expansion / `File.dir?` /
        # auto-load-newest entirely: a display-only remote project
        # selection made via the palette must survive same-node handle_params
        # runs; the node-switch clear above is what resets it.
        cond do
          not ModelSelectionScope.pending_remote?(socket.assigns) and
            not EvoDashWeb.RemoteGateComponents.gate_active?(socket.assigns) and
            is_binary(project_path) and project_path != "" and
              project_path != socket.assigns.active_project_path ->
            case ProjectFlow.normalize_remote_project_path(
                   socket.assigns[:current_node],
                   project_path
                 ) do
              {:ok, expanded} ->
                case params do
                  %{"resume_from" => task_id} when is_binary(task_id) and task_id != "" ->
                    ProjectFlow.spawn_remote_project_activation(socket, expanded, task_id)

                  %{"wb_home" => "1"} ->
                    select_remote_workbench_project(socket, project_path, expanded)

                  _ ->
                    ProjectFlow.spawn_remote_project_activation(socket, expanded)
                end

              # Blank/relative project params (stale/legacy URLs) are silently
              # ignored — never Path.expand against the VM cwd, same as the
              # local branch.
              _ ->
                socket
            end

          true ->
            socket
        end
      else
        if is_binary(project_path) do
          case ProjectFlow.normalize_project_path(project_path) do
            {:ok, expanded} ->
              if File.dir?(expanded) do
                activate_project(socket, expanded)
              else
                # Project path in URL is invalid, clear it. The notified-id set
                # is owned by the AsyncLoad seed / notification batches — no
                # store read here.
                assign(socket,
                  active_project: nil,
                  active_project_path: nil
                )
              end

            # Relative or blank project params (stale/legacy URLs, or entries
            # from previously-polluted projects) are silently ignored: never
            # `Path.expand` against the VM cwd — the Windows desktop backend
            # inherits the Tauri process cwd, so a relative input would join
            # against the install dir. handle_params runs on every navigation,
            # so no flash here; the param just doesn't activate a project.
            {:error, _reason} ->
              socket
          end
        else
          # No project in URL — the newest-opened project is auto-activated by
          # the async load continuation once the projects land (see
          # maybe_auto_activate_project/1). Nothing to load here.
          socket
        end
      end

    # Spawn the grouped async node-aware load (custom agents, model profiles,
    # remote project config, projects + the notified-terminal-id seed —
    # see the comment above and EvoDashWeb.ProjectsLive.AsyncLoad). The spawn
    # runs AFTER the node-switch state clearing AND the project-activation
    # block above, so it captures the post-clear, post-activation active
    # project path — the identity the AsyncLoad stale-guard compares against,
    # so a result spawned for the very activation that just happened is never
    # dropped as "stale" (and a remote→local switch can never keep a remote
    # node's model profiles/projects after a local project activates).
    socket =
      if socket.assigns.workbench_project_selection,
        do: socket,
        else: AsyncLoad.maybe_spawn(socket, prev_node_id)

    # Preserve starting_commit from URL query param (e.g. ?starting_commit=abc123)
    socket =
      case params["starting_commit"] do
        sha when is_binary(sha) and sha != "" ->
          socket
          |> assign(:task_starting_commit, sha)
          |> use_git_task_mode()

        _ ->
          socket
      end

    # Preserve resume_from from URL query param (e.g. ?resume_from=task_id)
    # and auto-expand the Advanced Options so the user sees it's filled in.
    # Also restore foreign_repos from the original task so the "continue from
    # here" workflow preserves multi-repo configuration — loaded in a
    # supervised task (the previous task's row must never be fetched in the
    # LiveView process), see start_foreign_repos_restore/2.
    socket =
      case params["resume_from"] do
        task_id when is_binary(task_id) and task_id != "" ->
          socket
          |> assign(:task_resume_from, task_id)
          |> assign(:show_advanced, true)
          |> start_foreign_repos_restore(task_id)

        _ ->
          socket
      end

    # Async GitHub-upstream detection (never runs synchronously — spawns a
    # supervised Task). Runs AFTER project restoration above so
    # `active_project_path`/`task_mode` are settled; no-ops when no project
    # is active, the mode is genesis_new, or a status is already present.
    socket = GitHub.maybe_check(socket)

    socket =
      if socket.assigns.workbench_open_requested, do: open_project_palette(socket), else: socket

    {:noreply, socket}
  end

  # --- Project Management Events ---

  @impl true
  def handle_event("open_project_palette", _params, socket) do
    {:noreply, open_project_palette(socket)}
  end

  @impl true
  def handle_event("close_project_palette", _params, socket) do
    {:noreply,
     socket
     |> assign(:project_palette_open, false)
     |> assign(:palette_mode, :menu)
     |> assign(:palette_search, "")
     |> assign(:palette_selected_index, 0)}
  end

  @impl true
  def handle_event("palette_search", %{"palette_search" => value}, socket) do
    {:noreply,
     socket
     |> assign(:palette_search, value)
     |> assign(:palette_selected_index, 0)}
  end

  @impl true
  def handle_event("palette_mode", %{"mode" => mode_str}, socket) do
    mode = Palette.mode_atom(mode_str)

    socket =
      socket
      |> assign(:palette_mode, mode)

    # Entering the workspace form always starts from an EMPTY member selection:
    # a stale selection from a previous visit must never be submitted as a
    # group the user did not build.
    socket =
      if mode == :new_workspace do
        assign(socket, :new_workspace_members, [])
      else
        socket
      end

    # Seed path suggestions when entering open_path mode (node-aware: remote
    # suggestions resolve against the remote daemon's filesystem)
    socket =
      if mode == :open_path do
        assign(
          socket,
          :path_suggestions,
          Project.path_suggestions(
            socket.assigns.current_node,
            "",
            socket.assigns.projects
          )
        )
      else
        socket
      end

    {:noreply, socket}
  end

  # Expands/collapses ONE workspace's member list in the palette. Pure UI state
  # (no store/RPC call): a workspace is a grouping row, never an activatable
  # project, so this event must not open, activate or launch anything.
  @impl true
  def handle_event("toggle_workspace", %{"point" => point}, socket)
      when is_binary(point) and point != "" do
    expanded = socket.assigns.expanded_workspaces |> Workspace.toggle_member(point)
    {:noreply, assign(socket, :expanded_workspaces, expanded)}
  end

  def handle_event("toggle_workspace", _params, socket), do: {:noreply, socket}

  # Adds/removes ONE project mount in the New Workspace member selection. New
  # members APPEND, so `new_workspace_members` IS the click order (which the
  # workspace stores verbatim). A missing/blank point is accepted and ignored.
  @impl true
  def handle_event("toggle_workspace_member", %{"point" => point}, socket)
      when is_binary(point) and point != "" do
    members = socket.assigns.new_workspace_members |> Workspace.toggle_member(point)
    {:noreply, assign(socket, :new_workspace_members, members)}
  end

  def handle_event("toggle_workspace_member", _params, socket), do: {:noreply, socket}

  # Creates or REPLACES a VCT workspace from the New Workspace form. ASYNC: the
  # registry write AND the follow-up authoritative reload run in a supervised
  # task (a registry `GenServer.call` can hang/exit and must never run in the
  # LiveView process); the result arrives as `{:workspace_created, seq, node,
  # result}`.
  @impl true
  def handle_event("create_workspace", %{"name" => name} = params, socket) do
    node = socket.assigns[:current_node] || node()
    seq = socket.assigns.workspace_create_seq + 1
    parent = self()

    members =
      Workspace.member_refs(
        socket.assigns.new_workspace_members,
        socket.assigns.projects
      )

    description = Workspace.description_param(params)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result =
        case SafeCall.run(fn ->
               AsyncLoad.create_workspace(node, name, members, description: description)
             end) do
          {:ok, value} -> value
          {:error, reason} -> {:error, reason}
        end

      send(parent, {:workspace_created, seq, node, result})
    end)

    {:noreply, assign(socket, :workspace_create_seq, seq)}
  end

  def handle_event("create_workspace", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("palette_keydown", %{"key" => key}, socket) do
    socket = Palette.handle_key(socket, key, socket.assigns.palette_mode)
    {:noreply, socket}
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
    ProjectFlow.create_project(socket, params)
  end

  @impl true
  def handle_event("open_project", params, socket) do
    ProjectFlow.open_project(socket, params)
  end

  @impl true
  def handle_event("select_project", params, socket) do
    ProjectFlow.select_project(socket, params)
  end

  # Forgets a project in the VCT project registry WITHOUT opening it. Works in
  # BOTH local and remote contexts (the forget RPC is node-aware). ASYNC: the
  # forget + the authoritative re-read run in one supervised task (never in the
  # LiveView process — the registry call can hang/exit); the row disappears
  # OPTIMISTICALLY on this render and the `{:projects_forgotten, seq, node,
  # result}` continuation assigns the authoritative (absolute-path-filtered)
  # list. A later `{:vct_updated, node}` broadcast corrects a failed forget.
  # The selected index resets to 0 so keyboard navigation stays in sync with
  # the shortened list.
  @impl true
  def handle_event("forget_project", %{"point" => point}, socket) do
    node = socket.assigns[:current_node] || node()
    node_id = socket.assigns[:current_node_id]
    remote? = socket.assigns.remote? == true
    seq = socket.assigns.projects_seq + 1
    parent = self()

    socket =
      socket
      |> assign(:projects_seq, seq)
      |> assign(:palette_selected_index, 0)
      |> assign(
        :projects,
        Enum.reject(socket.assigns.projects, fn entry ->
          (Map.get(entry, :point) || entry.path) == point
        end)
      )

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result =
        case SafeCall.run(fn -> NodeContext.forget_project(node, point) end) do
          {:ok, :ok} -> SafeCall.run(fn -> AsyncLoad.load_projects(remote?, node_id, node) end)
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end

      send(parent, {:projects_forgotten, seq, node, result})
    end)

    {:noreply, socket}
  end

  # --- Remote Node Events ---

  # Re-initiates a connection to the currently selected (failed/disconnected)
  # remote target. The connection is spawned on EvoDash.TaskSupervisor via the
  # shared NodeAware.initiate_remote_connect/2 helper — never blocks the
  # LiveView. Terminal outcomes arrive via "remote_connections" PubSub
  # broadcasts → handle_connection_status → push_patch once connected; only
  # synchronous errors are self-messaged back ({:remote_connect_result, ...}).
  @impl true
  def handle_event("retry_remote_connection", _params, socket) do
    if node_id = socket.assigns[:current_node_id] do
      EvoDashWeb.LiveHooks.NodeAware.initiate_remote_connect(socket, node_id)
    else
      socket
    end
    |> then(&{:noreply, &1})
  end

  # Switches back to the local node from a failed/disconnected remote context.
  # Reuses the existing {:node_selected, _} → NodeAware.handle_node_selected/2
  # path, which push_patches to the current path without the ?node= param.
  @impl true
  def handle_event("switch_to_local", _params, socket) do
    send(self(), {:node_selected, "local"})
    {:noreply, socket}
  end

  # --- Task Form Events ---

  @impl true
  def handle_event("task_change", %{"mode" => mode}, socket) do
    # Custom Agent mode requires a chosen agent (task_submit re-validates
    # it). When the user switches TO custom mode with no agent selected,
    # default to the first custom agent so the visible select always matches
    # what will be submitted (the form hides the "Auto (recommended)"
    # option in this mode).
    selected_agent_id = socket.assigns.selected_agent_id

    agent_id =
      if mode == "custom_agent" and
           not (is_binary(selected_agent_id) and String.trim(selected_agent_id) != "") do
        case socket.assigns.custom_agents do
          [first | _] -> Map.get(first, :id) || Map.get(first, "id")
          [] -> selected_agent_id
        end
      else
        selected_agent_id
      end

    socket =
      socket
      |> assign(:task_mode, mode)
      |> assign(:selected_agent_id, agent_id)

    {:noreply, StatePersistence.maybe_persist_state(socket)}
  end

  @impl true
  def handle_event("retry_model_selection", _params, socket) do
    if ModelSelectionScope.pending_remote?(socket.assigns) or
         EvoDashWeb.RemoteGateComponents.gate_active?(socket.assigns) do
      {:noreply, socket}
    else
      # Reuse the scoped loader; failures retain both the choice and pending
      # browser restore, and success alone restores launch readiness.
      {:noreply, AsyncLoad.maybe_spawn(socket, socket.assigns[:current_node_id])}
    end
  end

  @impl true
  def handle_event("select_provider_profile", %{"provider_profile_id" => id}, socket) do
    change_model_selection(socket, &LLMSelection.select_provider(&1, &2, id))
  end

  def handle_event("select_provider_profile", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_model", %{"model" => model}, socket) do
    change_model_selection(socket, &LLMSelection.select_model(&1, &2, model))
  end

  # Older open tabs send the former flat profile id. Validate explicit ids
  # strictly before migration; reconciliation alone would hide an invalid pin.
  # The empty-string sentinel still means explicit Auto.
  def handle_event("select_model", %{"model_id" => id}, socket) when is_binary(id) do
    change_model_selection(socket, fn bundle, _current ->
      with {:ok, opts} <- LLMSelection.task_opts(bundle, id) do
        {:ok, Keyword.get(opts, :model_spec, %{})}
      end
    end)
  end

  def handle_event("select_model", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_reasoning_effort", %{"reasoning_effort" => index}, socket) do
    change_model_selection(socket, &LLMSelection.select_reasoning_effort(&1, &2, index))
  end

  def handle_event("select_reasoning_effort", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_agent", %{"agent" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_agent_id, id)
     |> StatePersistence.maybe_persist_state()}
  end

  # Speed ↔ quality segmented control. `level` is a STRING from the client
  # (phx-value-level) validated against a whitelist — never String.to_atom
  # (untrusted input, atom-table exhaustion). An unknown value is ignored so
  # the current selection stays.
  @impl true
  def handle_event("select_quality_level", %{"level" => level}, socket)
      when level in @quality_levels do
    {:noreply,
     socket
     |> assign(:quality_level, level)
     |> StatePersistence.maybe_persist_state()}
  end

  def handle_event("select_quality_level", _params, socket), do: {:noreply, socket}
  # Persist-agent-state toggle (Task Options tab). The checkbox carries no
  # `name`/`form` association, so the assign is the single source of truth: a
  # click on a CHECKED checkbox sends `%{"value" => "true"}` while an
  # UNCHECKED click omits the `"value"` key entirely.
  @impl true
  def handle_event("toggle_persist_agent_state", params, socket) do
    {:noreply,
     socket
     |> assign(:persist_agent_state?, params["value"] == "true")
     |> StatePersistence.maybe_persist_state()}
  end

  # --- GitHub Issues Events ---
  #
  # Thin wrappers around EvoDashWeb.ProjectsLive.GitHub (all GitHub data
  # access is async via EvoDash.TaskSupervisor and node-aware via
  # EvoDash.NodeContext — the dashboard never calls gh/git directly).

  @impl true
  def handle_event("open_github_issues", _params, socket) do
    {:noreply, GitHub.open_modal(socket)}
  end

  @impl true
  def handle_event("close_github_modal", _params, socket) do
    {:noreply, GitHub.close_modal(socket)}
  end

  @impl true
  def handle_event("github_filter_state", %{"state" => state}, socket) do
    {:noreply, GitHub.filter_state(socket, state)}
  end

  @impl true
  def handle_event("github_fix_issue", %{"number" => number}, socket) do
    {:noreply, GitHub.fix_issue(socket, number)}
  end

  # Flash acknowledgement for the ClipboardCopy hook
  @impl true
  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
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
    requested_project = socket.assigns.workbench_reconnect_params["project"]
    same_node? = (params["node"] || "local") == (socket.assigns[:current_node_id] || "local")
    same_project? = is_nil(requested_project) or params["project"] in [nil, requested_project]

    if !same_node? or !same_project? do
      {:noreply, socket}
    else
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
        |> StatePersistence.maybe_restore_persist_agent_state(params["persist_agent_state?"])
        |> StatePersistence.maybe_restore_show_advanced(params["show_advanced"])
        |> StatePersistence.maybe_restore_model_selection(params)
        |> StatePersistence.maybe_restore_assign(:selected_agent_id, params["selected_agent_id"])
        |> StatePersistence.maybe_restore_quality_level(params["quality_level"])

      # Always restore task_mode from sessionStorage — the user's explicit choice
      # takes precedence over auto-detection when returning to a project.
      # Normalizes a legacy persisted "reflect" value to "evolve_simple" (the
      # reflect mode was removed from the task form).
      socket =
        if git_task_draft?(socket.assigns.workbench_reconnect_params) do
          socket
        else
          StatePersistence.maybe_restore_task_mode(socket, params["task_mode"])
        end

      # The URL owns project activation, including while a remote load is pending.
      socket =
        if is_nil(requested_project) and is_nil(socket.assigns.active_project) do
          socket =
            socket
            |> StatePersistence.maybe_restore_assign(:task_node_path, params["task_node_path"])

          project_path = params["project"]

          cond do
            not is_binary(project_path) or project_path == "" ->
              socket

            not is_nil(socket.assigns[:current_node_id]) ->
              # Saved remote paths belong to the target filesystem, never the
              # dashboard host. Activation validates them off-process and patches
              # the URL, which triggers the correctly scoped picker reload.
              if ModelSelectionScope.pending_remote?(socket.assigns) or
                   EvoDashWeb.RemoteGateComponents.gate_active?(socket.assigns) do
                socket
              else
                case ProjectFlow.normalize_remote_project_path(
                       socket.assigns[:current_node],
                       project_path
                     ) do
                  {:ok, expanded} ->
                    ProjectFlow.spawn_remote_project_activation(
                      socket,
                      expanded,
                      socket.assigns.task_resume_from
                    )

                  {:error, _reason} ->
                    socket
                end
              end

            File.dir?(project_path) ->
              # Activation invalidates the initial batch's captured path; replace
              # it with a fresh generation scoped to the restored project.
              socket
              |> activate_project(project_path)
              |> AsyncLoad.maybe_spawn(socket.assigns[:current_node_id])

            true ->
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
  end

  @impl true
  def handle_event("task_submit", %{"prompt" => prompt, "mode" => combined_mode} = params, socket) do
    path = socket.assigns.active_project_path
    selected_agent_id = socket.assigns.selected_agent_id
    # Resume foreign-repo restore still in flight (async, see
    # start_foreign_repos_restore/2) — the opts would carry an incomplete
    # foreign_repos list, so refuse to launch and let the user retry.
    restoring_from = socket.assigns.foreign_repos_restoring_from

    cond do
      # A pending remote target still resolves current_node locally. Never
      # dispatch that remote form to the local registry, even for forged events.
      socket.assigns[:current_node_id] != nil and
          (socket.assigns.current_node == node() or
             EvoDashWeb.RemoteGateComponents.gate_active?(socket.assigns)) ->
        {:noreply,
         put_flash(socket, :error, gettext("Connect to the remote node before starting a task."))}

      # All task modes now require an active project (reflect mode was
      # removed) — keep the existing "No project selected" guard.
      is_nil(path) ->
        {:noreply,
         put_flash(socket, :error, gettext("No project selected. Please open a project first."))}

      not is_nil(restoring_from) and restoring_from == socket.assigns.task_resume_from ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Still loading the previous task's settings. Please try again in a moment.")
         )}

      # Custom Agent mode must run a user-defined custom agent as the root
      # agent (the cross-app contract requires the :agent opt) — nil/""/"Auto
      # (recommended)" can never launch a custom-mode task.
      combined_mode == "custom_agent" and
          not (is_binary(selected_agent_id) and String.trim(selected_agent_id) != "") ->
        # zh_CN: Custom Agent → "自定义智能体"（用户自定义的根智能体）
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Custom Agent mode requires selecting a custom agent.")
         )}

      true ->
        do_task_submit(prompt, combined_mode, params, socket)
    end
  end

  # --- Task Management Events ---
  #
  # Store mutations run through `EvoDash.SafeCall`: a `GenServer.call` to the
  # task store can time out (EXIT, not a rescue-able exception) or hit a dead
  # server. They stay SYNCHRONOUS because the user is looking at the row they
  # just acted on — only the reload/notification work is async.

  @impl true
  def handle_event("cancel_task", %{"task_id" => task_id}, socket) do
    case SafeCall.run(fn -> TaskRegistry.cancel_task(task_id) end) do
      {:ok, :ok} ->
        {:noreply,
         socket
         |> EvoDashWeb.LiveHooks.NodeAware.assign_active_tasks()
         |> assign(
           :notified_task_ids,
           MapSet.put(socket.assigns.notified_task_ids, task_id)
         )}

      {:ok, {:error, reason}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to cancel task: %{reason}", reason: inspect(reason))
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to cancel task: %{reason}", reason: inspect(reason))
         )}
    end
  end

  # Clearing the history is a store WRITE plus a full terminal-id re-scan — both
  # run in one supervised task. The notified set is marked NOT READY for the
  # duration so a `:node_aware_reload_tasks` landing mid-clear can never treat
  # the not-yet-cleared rows as new and notify for them; the continuation
  # (`{:task_history_cleared, seq, node, result}`) re-seeds it from the
  # post-clear scan and flips readiness back on.
  @impl true
  def handle_event("clear_task_history", _params, socket) do
    seq = socket.assigns.clear_history_seq + 1
    node = socket.assigns[:current_node] || node()
    parent = self()

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result =
        SafeCall.run(fn ->
          TaskRegistry.clear_finished_tasks()
          Notifications.load_terminal_ids()
        end)

      send(parent, {:task_history_cleared, seq, node, result})
    end)

    {:noreply,
     socket
     |> EvoDashWeb.LiveHooks.NodeAware.assign_active_tasks()
     |> assign(:notified_task_ids_ready?, false)
     |> assign(:clear_history_seq, seq)}
  end

  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    case SafeCall.run(fn -> TaskRegistry.delete_task(task_id) end) do
      {:ok, _} ->
        {:noreply,
         socket
         |> EvoDashWeb.LiveHooks.NodeAware.assign_active_tasks()
         |> assign(
           :notified_task_ids,
           MapSet.put(socket.assigns.notified_task_ids, task_id)
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to delete task: %{reason}", reason: inspect(reason))
         )}
    end
  end

  # --- Project Settings Events ---

  @impl true
  def handle_event("toggle_add_foreign_repo_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_foreign_repo_form, !socket.assigns.show_add_foreign_repo_form)
     |> assign(:new_repo_id, "")
     |> assign(:new_repo_path, "")
     |> assign(:new_repo_description, "")
     |> assign(:new_repo_base_sha, "")
     |> assign(:editing_foreign_repo_id, nil)
     |> assign(:foreign_repo_edit_form, nil)}
  end

  @impl true
  def handle_event("toggle_project_settings", _params, socket) do
    new_show = !socket.assigns.show_project_settings

    {:noreply,
     socket
     |> assign(:show_project_settings, new_show)
     # OPENING the panel always shows CURRENT settings: a fresh genesis.toml
     # read (and mtime) at this moment, so a hand-edited file is picked up
     # without waiting for the next task broadcast. Collapsing is a pure toggle.
     |> then(fn s -> if new_show, do: refresh_project_config(s, true), else: s end)
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

    # Read-write foreign repos: `writable` is the checkbox presence ("true" =
    # checked → writable), `base_sha` is a trimmed optional per-repo starting
    # commit (blank → nil = HEAD). Both are threaded through
    # ProjectFlow.build_foreign_repo/4 → ForeignRepo.new/3 (which coerces
    # them) for local nodes; remote nodes get the raw values in the struct.
    writable = params["writable"] == "true"
    base_sha = String.trim(params["base_sha"] || "")
    base_sha = if base_sha == "", do: nil, else: base_sha

    cond do
      repo_id_str == "" ->
        {:noreply, put_flash(socket, :error, gettext("Repo ID cannot be empty."))}

      true ->
        case ForeignRepos.validate_input(socket.assigns, path, base_sha) do
          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}

          :ok ->
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
              # Node-aware construction: in a remote context the accepted path is
              # a REMOTE node path — `ForeignRepo.new/3` would `Path.expand/1` it
              # against the DASHBOARD's OS and mangle it (`/home/...` on a Windows
              # dashboard, `D:\stuff` cwd-joined on POSIX). Remote contexts store
              # the raw trimmed path via ProjectFlow.build_foreign_repo/4; local
              # contexts keep `ForeignRepo.new/3`'s exact expansion semantics —
              # except UNC/WSL roots on a non-Windows node, which bypass the
              # expansion and are stored verbatim (ForeignRepos.build_for_node/4).
              remote_context? =
                socket.assigns.remote? or socket.assigns[:current_node] != node()

              node = if remote_context?, do: socket.assigns[:current_node], else: node()

              opts =
                []
                |> then(fn o ->
                  if description != "", do: Keyword.put(o, :description, description), else: o
                end)
                |> Keyword.put(:writable, writable)
                |> then(fn o ->
                  if is_binary(base_sha), do: Keyword.put(o, :base_sha, base_sha), else: o
                end)

              repo = ForeignRepos.build_for_node(node, repo_id, path, opts)

              updated_repos =
                ForeignRepos.sort_by_primary([repo | current_repos])

              {:noreply,
               socket
               |> assign(:foreign_repos, updated_repos)
               |> assign(:show_add_foreign_repo_form, false)
               |> assign(:new_repo_id, "")
               |> assign(:new_repo_path, "")
               |> assign(:new_repo_description, "")
               |> assign(:new_repo_base_sha, "")
               |> assign(:editing_foreign_repo_id, nil)
               |> assign(:foreign_repo_edit_form, nil)
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

  @impl true
  def handle_event("edit_foreign_repo", %{"repo_id" => repo_id}, socket) do
    case Enum.find(socket.assigns.foreign_repos, &(&1.id == repo_id)) do
      nil ->
        # Unknown id → error flash (mirrors remove_foreign_repo's choice): a
        # stale repo_id from an outdated render surfaces as a user-visible
        # error instead of a crash.
        {:noreply, put_flash(socket, :error, gettext("Repo '%{id}' not found.", id: repo_id))}

      repo ->
        {:noreply,
         socket
         |> assign(:editing_foreign_repo_id, repo_id)
         |> assign(:foreign_repo_edit_form, %{
           description: repo.description,
           writable: repo.writable,
           base_sha: repo.base_sha
         })}
    end
  end

  @impl true
  def handle_event("save_foreign_repo", params, socket) do
    repo_id = params["repo_id"]
    path = String.trim(params["path"] || "")
    description = String.trim(params["description"] || "")
    # `writable` is the checkbox presence ("true" = checked → writable).
    writable = params["writable"] == "true"
    # `base_sha` is a trimmed optional per-repo starting commit (blank → nil).
    base_sha = String.trim(params["base_sha"] || "")
    base_sha = if base_sha == "", do: nil, else: base_sha

    current_repos = socket.assigns.foreign_repos

    if Enum.any?(current_repos, &(&1.id == repo_id)) do
      case ForeignRepos.validate_input(socket.assigns, path, base_sha) do
        {:error, message} ->
          # Stay in edit mode on validation failure — keep the form + assigns
          # so the user can fix the value without re-opening the editor.
          {:noreply, put_flash(socket, :error, message)}

        :ok ->
          # Node-aware construction — same node resolution as add_foreign_repo:
          # remote contexts rebuild the raw struct (root + base_sha stored
          # verbatim, never Path.expand-ed against the dashboard's OS), local
          # contexts keep ForeignRepo.new/3's exact expansion semantics —
          # except UNC/WSL roots on a non-Windows node, which bypass the
          # expansion and are stored verbatim (ForeignRepos.build_for_node/4).
          remote_context? =
            socket.assigns.remote? or socket.assigns[:current_node] != node()

          node = if remote_context?, do: socket.assigns[:current_node], else: node()

          opts =
            []
            |> then(fn o ->
              if description != "", do: Keyword.put(o, :description, description), else: o
            end)
            |> Keyword.put(:writable, writable)
            |> then(fn o ->
              if is_binary(base_sha), do: Keyword.put(o, :base_sha, base_sha), else: o
            end)

          repo = ForeignRepos.build_for_node(node, repo_id, path, opts)

          updated_repos =
            current_repos
            |> Enum.map(fn r -> if r.id == repo_id, do: repo, else: r end)
            |> ForeignRepos.sort_by_primary()

          {:noreply,
           socket
           |> assign(:foreign_repos, updated_repos)
           |> assign(:editing_foreign_repo_id, nil)
           |> assign(:foreign_repo_edit_form, nil)
           |> StatePersistence.maybe_persist_state()
           |> put_flash(
             :info,
             gettext("Foreign repo '%{repo_id}' updated successfully.", repo_id: repo_id)
           )}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Repo '%{id}' not found.", id: repo_id))}
    end
  end

  @impl true
  def handle_event("cancel_edit_foreign_repo", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_foreign_repo_id, nil)
     |> assign(:foreign_repo_edit_form, nil)}
  end

  # --- Path / Directory Picker Events ---

  @impl true
  def handle_event("path_input", %{"path" => value}, socket) do
    suggestions =
      Project.path_suggestions(
        socket.assigns.current_node,
        value,
        socket.assigns.projects
      )

    {:noreply, assign(socket, :path_suggestions, suggestions)}
  end

  @impl true
  def handle_event("new_project_path_input", %{"path" => value}, socket) do
    # The create-new-project palette form submits a single full project path
    # and is local-only (hidden in remote contexts), but suggestions resolve
    # node-aware like `path_input` for consistency with the shared
    # `@path_suggestions` assign.
    suggestions =
      Project.path_suggestions(
        socket.assigns.current_node,
        value,
        socket.assigns.projects
      )

    {:noreply, assign(socket, :path_suggestions, suggestions)}
  end

  @impl true
  def handle_event("foreign_repo_path_input", %{"path" => value}, socket) do
    # Foreign-repo paths are always LOCAL filesystem paths (project settings
    # are a local dashboard concern), so suggestions resolve against the local
    # node.
    suggestions = Project.path_suggestions(node(), value, socket.assigns.projects)
    {:noreply, assign(socket, :foreign_repo_path_suggestions, suggestions)}
  end

  @impl true
  def handle_event("directory_pick", %{"picker_id" => picker_id}, socket) do
    if socket.assigns.current_node == node() do
      # wx dialogs must only ever pop on the local node. The picker module is
      # resolved from the app env so there is no hard compile-time dependency
      # (the parallel DirectoryPicker work may not be compiled in this tree).
      module =
        Application.get_env(:evo_dash, :directory_picker_module, EvoDash.DirectoryPicker)

      if Code.ensure_loaded?(module) do
        case module.pick(self(), picker_id) do
          :ok ->
            # The dialog runs asynchronously; the result arrives later via
            # {:directory_picker_result, picker_id, result}. NEVER block the
            # LiveView on the modal dialog.
            {:noreply, socket}

          {:error, :unavailable} ->
            {:noreply, push_event(socket, "picker_result:#{picker_id}", %{unavailable: true})}
        end
      else
        {:noreply, push_event(socket, "picker_result:#{picker_id}", %{unavailable: true})}
      end
    else
      # Remote/headless node: never pop a wx dialog there; report unavailable.
      {:noreply, push_event(socket, "picker_result:#{picker_id}", %{unavailable: true})}
    end
  end

  @impl true
  def handle_event("file_pick", params, socket) do
    # Attach-file flow for the objective editor: same server-side picker as
    # "directory_pick" but in :file mode (the parallel DirectoryPicker work
    # adds pick/3 with a kind argument). The current DOM textarea value is
    # passed along and snapshotted as the base so the picked file's text can
    # be appended even if the user keeps typing while the dialog is open.
    #
    # Params are read defensively (Map.get) so this event tolerates the new
    # "kind" key carried by the image/audio attach buttons AND legacy callers
    # / tests that send only picker_id + prompt.
    picker_id = Map.get(params, "picker_id", @attach_picker_id)
    prompt = Map.get(params, "prompt", "")

    # The pick flow itself is kind-agnostic — the kind is implied by the
    # picker id when the directory_picker_result arrives (the text clause
    # starts a text read, image/audio a binary read; see the
    # directory_picker_result handlers below) — so the key is read only to
    # tolerate its presence.
    _kind = Map.get(params, "kind", "text")

    if socket.assigns.current_node == node() do
      # wx dialogs must only ever pop on the local node. The picker module is
      # resolved from the app env so there is no hard compile-time dependency.
      module =
        Application.get_env(:evo_dash, :directory_picker_module, EvoDash.DirectoryPicker)

      if Code.ensure_loaded?(module) do
        case module.pick(self(), picker_id, :file) do
          :ok ->
            # The dialog runs asynchronously; the result arrives later via
            # {:directory_picker_result, picker_id, result}. NEVER block the
            # LiveView on the modal dialog.
            bases = Map.put(socket.assigns.file_pick_bases, picker_id, prompt || "")
            {:noreply, assign(socket, :file_pick_bases, bases)}

          {:error, :unavailable} ->
            {:noreply, push_event(socket, "picker_result:#{picker_id}", %{unavailable: true})}
        end
      else
        {:noreply, push_event(socket, "picker_result:#{picker_id}", %{unavailable: true})}
      end
    else
      # Remote/headless node — never pop a dialog there.
      {:noreply, push_event(socket, "picker_result:#{picker_id}", %{unavailable: true})}
    end
  end

  @impl true
  def handle_event("file_pick_manual", params, socket) do
    # Manual path fallback for the attach-file "+" button: the FilePicker JS
    # hook reveals an inline path input when the native picker is unavailable
    # (headless server, remote node, picker disabled) and submits the typed
    # path here. The body — path validation, base-prompt snapshot and the
    # off-process read — lives in `EvoDashWeb.ProjectsLive.Attachments.manual/2`;
    # this clause head stays here so the page's event surface is unchanged.
    {:noreply, Attachments.manual(socket, params)}
  end

  @impl true
  def handle_event("remove_staged_attachment", %{"index" => index}, socket)
      when is_binary(index) do
    # Remove one staged binary attachment by list index (the chip's
    # phx-value-index). The index arrives as a string; parse it with a
    # rescue-free safe parse (never String.to_atom, never a bare raise) and
    # bounds-check against the current staged list. Invalid indices are a
    # no-op — the staged list only shrinks via valid removes.
    i =
      case Integer.parse(index) do
        {i, ""} when i >= 0 -> i
        _ -> nil
      end

    staged = socket.assigns.staged_attachments

    socket =
      if is_integer(i) and i < length(staged) do
        assign(socket, :staged_attachments, List.delete_at(staged, i))
      else
        socket
      end

    {:noreply, socket}
  end

  # Missing/non-string "index" payload → no-op (never raise on odd shapes).
  def handle_event("remove_staged_attachment", _params, socket) do
    {:noreply, socket}
  end

  # Project-config-defined shell commands can run for up to 30 s (see
  # Commands.run/2), so the System.cmd must NOT run in this process: it
  # would freeze every other event, render and heartbeat on the tab for the
  # whole command. The work moves into a supervised task under
  # EvoDash.TaskSupervisor and the outcome arrives as
  # `{{:command_result, seq, project_root, node, command}, result}` (doubly
  # nested: `EvoDash.SafeCall.start/3` sends `{tag, result}`). The monotonic
  # `:command_seq` is the stale-guard — only the newest run may touch the
  # assigns/flash.
  #
  # NOTE: the Configure dialog's command buttons are rendered by
  # `EvoDashWeb.ProjectComponents` (outside this module), so the in-flight
  # feedback the page itself can give is the `:command_running` assign plus the
  # "Running …" info flash — not a disabled button.
  @impl true
  def handle_event("run_command", %{"command" => command}, socket) do
    commands = socket.assigns.commands
    project_root = socket.assigns.active_project_path
    node = socket.assigns[:current_node] || node()

    case Commands.lookup(commands, command) do
      nil ->
        {:noreply,
         put_flash(socket, :error, gettext("Command not found: %{command}", command: command))}

      cmd_string ->
        seq = socket.assigns.command_seq + 1

        case EvoDash.SafeCall.start(
               self(),
               {:command_result, seq, project_root, node, command},
               fn -> Commands.run(cmd_string, project_root) end
             ) do
          {:ok, _pid} ->
            {:noreply,
             socket
             |> assign(:command_seq, seq)
             |> assign(:command_running, command)
             |> put_flash(:info, gettext("Running '%{command}'…", command: command))}

          {:error, _reason} ->
            # The task never started, so no result will arrive: do NOT set the
            # running assign, and flash a retry-able error (the button still
            # works, nothing is left wedged).
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Could not run '%{command}'. Please try again.", command: command)
             )}
        end
    end
  end

  # Selecting an open project's empty workspace only needs its registered path.
  # Task configuration is loaded when the user enters the task composer.
  defp select_remote_workbench_project(socket, requested_path, path) do
    target = socket.assigns.current_node
    selection = %{target: target, requested_path: requested_path, path: path}

    if socket.assigns.workbench_project_selection == selection do
      socket
    else
      socket
      |> assign(:workbench_project_selection, selection)
      |> start_async(:workbench_project_selection, fn ->
        if NodeContext.dir?(target, path) do
          projects =
            AsyncLoad.filter_absolute_projects_for_node(target, NodeContext.projects(target))

          if Enum.any?(projects, &(&1.path == path)),
            do: {:registered, projects},
            else: :unregistered
        else
          :not_a_directory
        end
      end)
    end
  end

  @impl true
  def handle_async(:workbench_project_selection, result, socket) do
    case {socket.assigns.workbench_project_selection, result} do
      {nil, _} ->
        {:noreply, socket}

      {_, {:ok, {:registered, projects}}} ->
        # `workbench_project_selection` deliberately STAYS set: the render's
        # `workbench_project` fallback reads its `.path` and handle_params/3
        # clears it on a project/node mismatch. Because its presence suppressed
        # this run's batch (handle_params/3 skips maybe_spawn then), the batch
        # is spawned HERE instead — the captured path is unchanged, so the
        # result is not dropped as stale.
        socket = assign(socket, :projects, projects)
        {:noreply, AsyncLoad.maybe_spawn(socket, socket.assigns[:current_node_id])}

      {%{path: path}, {:ok, :unregistered}} ->
        {:noreply,
         socket
         |> assign(:workbench_project_selection, nil)
         |> ProjectFlow.spawn_remote_project_activation(path)}

      {%{path: path}, _} ->
        {:noreply,
         socket
         |> assign(:workbench_project_selection, nil)
         |> put_flash(
           :error,
           gettext("Directory does not exist on the remote node: %{path}", path: path)
         )}
    end
  end

  # --- PubSub Handlers ---

  # Results from the async directory picker (EvoDash.DirectoryPicker sends
  # these to the LiveView pid passed to pick/2).
  #
  # Attach-file flow: the picked file is read OFF-PROCESS (a large PDF/image
  # would freeze the tab) and its content is appended to the objective. These
  # three clauses keep the exact picker-id guards (nothing is re-tagged or
  # reordered) and delegate to the attachment pipeline — the `:attach_pending`
  # guard, the prompt snapshot and the read start — in
  # `EvoDashWeb.ProjectsLive.Attachments` (the kind is implied by the id).
  @impl true
  def handle_info({:directory_picker_result, @attach_picker_id, {:ok, path}}, socket) do
    {:noreply, Attachments.start_pick(socket, @attach_picker_id, path)}
  end

  # Image/audio picker results route to the binary staging flow. These picker
  # ids are the literal counterparts of the @attach_picker_id_image /
  # @attach_picker_id_audio attrs in the Attachments support module (which push
  # the result on the same id's channel), kept as literals in both modules
  # under parallel compilation.
  @impl true
  def handle_info({:directory_picker_result, @attach_picker_id_image, {:ok, path}}, socket) do
    {:noreply, Attachments.start_pick(socket, @attach_picker_id_image, path)}
  end

  @impl true
  def handle_info({:directory_picker_result, @attach_picker_id_audio, {:ok, path}}, socket) do
    {:noreply, Attachments.start_pick(socket, @attach_picker_id_audio, path)}
  end

  # The ONE result message of an off-process attachment read: a plain send/2
  # from the supervised task (EvoDashWeb.ProjectsLive.AttachFile), hence the
  # doubly nested tag. `Attachments.loaded/5` owns the `:attach_pending` guard
  # (a result whose pick is no longer pending — superseded, or discarded by a
  # node switch — is dropped) and applies the base prompt snapshotted when
  # that pick started.
  @impl true
  def handle_info({{:attachment_loaded, picker_id, path, kind}, result}, socket) do
    {:noreply, Attachments.loaded(socket, picker_id, path, kind, result)}
  end

  @impl true
  def handle_info({:directory_picker_result, picker_id, {:ok, path}}, socket) do
    {:noreply, push_event(socket, "picker_result:#{picker_id}", %{path: path})}
  end

  @impl true
  def handle_info({:directory_picker_result, picker_id, :cancelled}, socket) do
    {:noreply, push_event(socket, "picker_result:#{picker_id}", %{cancelled: true})}
  end

  @impl true
  def handle_info({:directory_picker_result, picker_id, :unavailable}, socket) do
    {:noreply, push_event(socket, "picker_result:#{picker_id}", %{unavailable: true})}
  end

  @impl true
  def handle_info({:node_selected, node_id}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)
  end

  @impl true
  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)
  end

  # Sync-error fallback for NodeAware.initiate_remote_connect/2: the subsystem
  # is unavailable / the target is unknown / the manager failed to start — NO
  # "remote_connections" broadcast ever arrives on these arms, so the gate can
  # never reconcile; the flash is the surfacing mechanism. Terminal outcomes
  # arrive only via PubSub broadcasts handled by NodeAware.handle_connection_status/2.
  @impl true
  def handle_info({:remote_connect_result, _target_id, {:error, reason}}, socket) do
    message =
      case reason do
        :remote_connection_unavailable ->
          gettext("Remote connect unavailable — the remote connection subsystem is not running.")

        _ ->
          gettext("Remote connect failed: %{reason}", reason: format_remote_reason(reason))
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  @impl true
  def handle_info({:task_updated, _task_id, _status, _node} = msg, socket) do
    # Node-identity task broadcast — node-filtered (foreign-node events are
    # dropped BEFORE the debounce is scheduled) and debounced (300ms trailing
    # edge) inside NodeAware.handle_task_info/2, which already returns
    # {:noreply, socket}.
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info({:task_deleted, _task_id, _node} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  # Debounced reload fired by NodeAware after task broadcasts: refreshes the
  # sidebar, reloads project settings when the settings panel is open, and
  # spawns the browser-notification scan for newly finished tasks.
  #
  # NOTHING here blocks on the store: the notification scan runs in a
  # supervised task (Notifications.spawn_scan/4 — terminal-id projection + one
  # full-row read per NEWLY terminal id) and its outcome arrives as
  # `{:task_notifications, seq, node, result}`. The scan is skipped entirely
  # until the notified-id set has been SEEDED (`notified_task_ids_ready?`) —
  # diffing against an unseeded empty set would notify for every historical
  # task. Notifications are LOCAL-context only.
  #
  # Node-aware: the sidebar reload goes through
  # NodeAware.load_running_and_pending_tasks/1 (remote tasks via RPC, empty
  # lists in pending/error remote contexts).
  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    # Refresh project settings if shown — but only when genesis.toml actually
    # changed on disk. This debounce fires on the trailing edge of EVERY task
    # broadcast (continuously while a task runs), so re-parsing TOML here would
    # be pure churn: the task debounce alone never reloads unchanged settings.
    # The foreign-repo list is in-memory and is not re-read at all.
    socket =
      if Map.get(socket.assigns, :show_project_settings, false) and
           Map.get(socket.assigns, :active_project_path) do
        refresh_project_config(socket)
      else
        socket
      end

    socket =
      if socket.assigns[:current_node_id] == nil and
           socket.assigns.notified_task_ids_ready? == true do
        seq = socket.assigns.task_notifications_seq + 1

        Notifications.spawn_scan(
          self(),
          seq,
          socket.assigns[:current_node] || node(),
          socket.assigns.notified_task_ids
        )

        assign(socket, :task_notifications_seq, seq)
      else
        socket
      end

    socket = EvoDashWeb.LiveHooks.NodeAware.load_running_and_pending_tasks(socket)

    {:noreply, EvoDashWeb.LiveHooks.NodeAware.clear_task_reload_pending(socket)}
  end

  # Continuation of the notification scan started above. Stale-guarded on the
  # captured seq (a newer scan superseded this one), the node (a node switch
  # happened) and the node context (notifications are local-only). An error
  # result leaves the state untouched — the next debounced reload retries.
  @impl true
  def handle_info({:task_notifications, seq, node, result}, socket) do
    if seq != socket.assigns.task_notifications_seq or
         node != (socket.assigns[:current_node] || node()) or
         socket.assigns[:current_node_id] != nil do
      {:noreply, socket}
    else
      case result do
        {:ok, {new_ids, notifications}} ->
          socket =
            assign(
              socket,
              :notified_task_ids,
              MapSet.union(socket.assigns.notified_task_ids, MapSet.new(new_ids))
            )

          socket =
            Enum.reduce(notifications, socket, fn {_id, title, body}, sock ->
              push_event(sock, "task_notification", %{title: title, body: body})
            end)

          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, socket}
      end
    end
  end

  # Continuation of the ASYNC clear-history batch (see the
  # `clear_task_history` event): re-seeds the notified-id set from the
  # post-clear scan and flips readiness back on. `ids` is nil when the
  # post-clear scan itself failed — the already-notified ids are kept and
  # readiness is restored so detection resumes.
  @impl true
  def handle_info({:task_history_cleared, seq, node, result}, socket) do
    if seq != socket.assigns.clear_history_seq or
         node != (socket.assigns[:current_node] || node()) do
      {:noreply, socket}
    else
      case result do
        {:ok, ids} ->
          {:noreply,
           socket
           |> assign(
             :notified_task_ids,
             MapSet.union(socket.assigns.notified_task_ids, ids || MapSet.new())
           )
           |> assign(:notified_task_ids_ready?, true)}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:notified_task_ids_ready?, true)
           |> put_flash(
             :error,
             gettext("Failed to clear task history: %{reason}", reason: inspect(reason))
           )}
      end
    end
  end

  # Continuation of the ASYNC VCT project-list reload (the `{:vct_updated,
  # node}` PubSub broadcast). Stale-guarded on the seq, the node and the node
  # context; an error leaves the current list alone.
  @impl true
  def handle_info({:projects_loaded, seq, node_id, node, result}, socket) do
    if seq != socket.assigns.projects_seq or
         node_id != socket.assigns[:current_node_id] or
         node != (socket.assigns[:current_node] || node()) do
      {:noreply, socket}
    else
      case result do
        {:ok, projects} ->
          {:noreply, assign(socket, :projects, projects)}

        {:error, _reason} ->
          {:noreply, socket}
      end
    end
  end

  # Continuation of the ASYNC VCT WORKSPACE reload (the AsyncLoad batch and the
  # `{:vct_updated, node}` handler). Stale-guarded on the monotonic
  # `workspaces_seq` and the node; a failed/missing result KEEPS the current
  # list (the next VCT broadcast retries) and never crashes the page.
  @impl true
  def handle_info({:workspaces_loaded, seq, node, result}, socket) do
    if seq != socket.assigns.workspaces_seq or
         node != (socket.assigns[:current_node] || node()) do
      {:noreply, socket}
    else
      case result do
        {:ok, workspaces} when is_list(workspaces) ->
          expanded = socket.assigns.expanded_workspaces
          known = Workspace.points(workspaces)

          {:noreply,
           socket
           |> assign(:workspaces, workspaces)
           |> assign(:expanded_workspaces, Enum.filter(expanded, &(&1 in known)))}

        _ ->
          {:noreply, socket}
      end
    end
  end

  # Continuation of the ASYNC workspace create/replace (see the
  # `create_workspace` event). On success the form is cleared, the palette
  # returns to the menu with the new workspace expanded, and BOTH the workspace
  # and project lists are reloaded authoritatively off-process. A validation
  # error keeps the form (and the chosen members) so the user can correct it.
  # Guarded on `workspace_create_seq` (see the mount seed): the VCT broadcast
  # for this write reloads and bumps `workspaces_seq` BEFORE this reply lands,
  # so only a NEWER create may invalidate it.
  @impl true
  def handle_info({:workspace_created, seq, node, result}, socket) do
    if seq != socket.assigns.workspace_create_seq or
         node != (socket.assigns[:current_node] || node()) do
      {:noreply, socket}
    else
      case result do
        {:ok, mount} when is_map(mount) ->
          point = Map.get(mount, :point)
          label = Map.get(mount, :name) || point

          expanded =
            case point do
              point when is_binary(point) ->
                [point | List.delete(socket.assigns.expanded_workspaces, point)]

              _ ->
                socket.assigns.expanded_workspaces
            end

          socket =
            socket
            |> assign(:new_workspace_members, [])
            |> assign(:palette_mode, :menu)
            |> assign(:expanded_workspaces, expanded)
            |> put_flash(:info, gettext("Workspace %{name} saved.", name: label))
            |> reload_vct()

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, Workspace.error_message(reason))}

        _ ->
          {:noreply, socket}
      end
    end
  end

  # Continuation of the ASYNC optimistic project forget (see the
  # `forget_project` event). The optimistic list already dropped the row;
  # success replaces it with the authoritative filtered list, an error reloads
  # the authoritative list and flashes.
  @impl true
  def handle_info({:projects_forgotten, seq, node, result}, socket) do
    if seq != socket.assigns.projects_seq or
         node != (socket.assigns[:current_node] || node()) do
      {:noreply, socket}
    else
      case result do
        {:ok, projects} ->
          {:noreply, assign(socket, :projects, AsyncLoad.filter_absolute_projects(projects))}

        {:error, reason} ->
          socket =
            case SafeCall.run(fn ->
                   AsyncLoad.load_projects(
                     socket.assigns.remote? == true,
                     socket.assigns[:current_node_id],
                     node
                   )
                 end) do
              {:ok, projects} ->
                assign(socket, :projects, AsyncLoad.filter_absolute_projects(projects))

              {:error, _reason} ->
                socket
            end

          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to forget project: %{reason}", reason: inspect(reason))
           )}
      end
    end
  end

  # Continuation of the ASYNC resume foreign-repo restore (see
  # start_foreign_repos_restore/2). Stale-guarded on the task id (a newer
  # resume landed) and the node; an empty result keeps the genesis.toml repos
  # the project load produced.
  @impl true
  def handle_info({:foreign_repos_restored, task_id, node, result}, socket) do
    if not is_nil(socket.assigns[:current_node_id]) or
         task_id != socket.assigns.task_resume_from or
         node != node() or node != (socket.assigns[:current_node] || node()) do
      {:noreply, socket}
    else
      socket = assign(socket, :foreign_repos_restoring_from, nil)

      case result do
        {:ok, repos} when is_list(repos) and repos != [] ->
          {:noreply, assign(socket, :foreign_repos, repos)}

        {:ok, _} ->
          {:noreply, socket}

        {:error, _reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Could not load the previous task's foreign repositories.")
           )}
      end
    end
  end

  # The VCT project + WORKSPACE lists are reloaded in a supervised task — the
  # registry/RPC read must never run in the LiveView process. A pending/error
  # remote context never consumes the reload (its own activation owns the list).
  @impl true
  def handle_info({:vct_updated, node}, socket) do
    send_update(EvoDashWeb.WorkbenchComponent, id: "workbench-projects", refresh: true)

    pending_remote? =
      is_binary(socket.assigns[:current_node_id]) and socket.assigns[:current_node] == node()

    if node != (socket.assigns[:current_node] || node()) or pending_remote? do
      {:noreply, socket}
    else
      {:noreply, reload_vct(socket)}
    end
  end

  # A config change on THIS page's node invalidates the canonical picker
  # bundle: the core broadcasts `{:config_reloaded, node, dir, generation}`
  # once per content-fingerprint change on the `"config"` topic, so a Settings
  # save (or any other writer) refreshes the provider/model inventory instead
  # of leaving the task form in its "Loading models…" state until a remount.
  # A remote target's config never arrives here (the broadcast comes from the
  # publishing BEAM), and the connection gate owns the pending/connecting UX —
  # a batch spawned then would be dropped by the pending guard.
  @impl true
  def handle_info({:config_reloaded, node, dir, generation}, socket) do
    node_matches? = node == (socket.assigns[:current_node] || node())

    if node_matches? and not ModelSelectionScope.pending_remote?(socket.assigns) and
         not EvoDashWeb.RemoteGateComponents.gate_active?(socket.assigns) do
      if stale_config_generation?(socket.assigns[:config_generation], dir, generation) do
        {:noreply, socket}
      else
        # The handled generation is stored only when a batch is ACTUALLY
        # spawned, so repeated broadcasts cannot pile up loads.
        socket =
          socket
          |> assign(:config_generation, {dir, generation})
          |> AsyncLoad.maybe_spawn(socket.assigns[:current_node_id])

        # Refresh the layout's config-warning banner from the same event.
        send(self(), :load_config_status)

        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
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

  # Continuation of the ASYNC project command run (see the "run_command" event
  # clause). Stale-guarded on the monotonic `:command_seq`, the project root the
  # command was started for, and the node: a superseding run, a project switch
  # or a node switch drops the result (the task's own output never lands on a
  # different project/view).
  @impl true
  def handle_info({{:command_result, seq, project_root, node, command}, result}, socket) do
    if seq != socket.assigns.command_seq or
         project_root != socket.assigns.active_project_path or
         node != (socket.assigns[:current_node] || node()) do
      {:noreply, socket}
    else
      socket = assign(socket, :command_running, nil)

      case result do
        {:ok, {:ok, output, 0}} ->
          {:noreply,
           put_flash(
             socket,
             :info,
             gettext("Command '%{command}' completed:\n%{output}",
               command: command,
               output: Commands.truncate_output(output)
             )
           )}

        {:ok, {:ok, output, exit_code}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Command '%{command}' failed (exit %{code}):\n%{output}",
               command: command,
               code: exit_code,
               output: Commands.truncate_output(output)
             )
           )}

        {:ok, {:error, error}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Error running '%{command}': %{error}",
               command: command,
               error: to_string(error)
             )
           )}

        # The guarded call itself exited/raised inside the task (the OS work is
        # already rescued in Commands.run/2, so this is the SafeCall
        # boundary): report it as the same user-facing error.
        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Error running '%{command}': %{error}",
               command: command,
               error: inspect(reason)
             )
           )}
      end
    end
  end

  # Continuation of the ASYNC task launch (see do_task_submit/4): the start
  # call runs in a supervised task, so THIS is where the prompt, the staged
  # attachments and the printed form are finally cleared — never before the
  # ack, which is what keeps a failed launch retry-able. Stale-guarded on the
  # monotonic `:task_launch_seq`: a superseded launch's result must never clear
  # the form of a newer submission.
  #
  # The message is DOUBLY nested — `EvoDash.SafeCall.start/3` sends
  # `{tag, result}` for the tag `{:task_started, seq, task_type}` — so `result`
  # is the SafeCall envelope: `{:ok, {:ok, task}}` on success,
  # `{:ok, {:error, reason}}` for a refused start, and a bare `{:error, reason}`
  # when the guarded call itself exited/raised inside the task.
  @impl true
  def handle_info({{:task_started, seq, task_type}, result}, socket) do
    if seq != socket.assigns.task_launch_seq do
      {:noreply, socket}
    else
      socket = assign(socket, :task_launching, false)

      case result do
        {:ok, {:ok, task}} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("%{type} task started with ID: %{id}",
               type: String.capitalize(to_string(task_type)),
               id: task.id
             )
           )
           |> EvoDashWeb.LiveHooks.NodeAware.assign_active_tasks()
           # The prompt is intentionally cleared after a successful launch.
           # assign_form_defaults/1 resets @task_prompt to "" (so the server
           # re-seeds data-layout="compact"), and the "clear_prompt" push_event
           # empties the visible textarea — which morphdom skips under
           # phx-update="ignore" — and removes the persisted draft, so neither
           # the DOM nor a reload can resurrect the submitted prompt.
           |> Assigns.assign_form_defaults()
           # Staged binary attachments must survive mode changes but NOT a
           # successful launch — cleared here (after assign_form_defaults,
           # which keeps a fixed key list and has no knowledge of staging)
           # rather than inside assign_form_defaults/1.
           |> assign(:staged_attachments, [])
           |> StatePersistence.maybe_persist_state()
           |> push_event("clear_prompt", %{})}

        {:ok, {:error, :no_task_model}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Configure a model on this server before launching a task.")
           )}

        {:ok, {:error, reason}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to start task: %{reason}", reason: inspect(reason))
           )}

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

  # --- GitHub Issues async results ---
  #
  # Messages from EvoDashWeb.ProjectsLive.GitHub's supervised Tasks. The
  # handlers are stale-guarded on project path + node (+ filter state for the
  # issue list) so a result for a previous project/node never lands on the
  # current view.

  @impl true
  def handle_info({:github_status_result, path, node, result}, socket) do
    {:noreply, GitHub.handle_status_result(socket, path, node, result)}
  end

  @impl true
  def handle_info({:github_issues_result, path, node, state, result}, socket) do
    {:noreply, GitHub.handle_issues_result(socket, path, node, state, result)}
  end

  @impl true
  def handle_info({:github_fix_result, path, node, number, result}, socket) do
    {:noreply, GitHub.handle_fix_result(socket, path, node, number, result)}
  end

  # Async node-aware loads spawned by AsyncLoad.maybe_spawn/2 in
  # handle_params/3 (custom agents, canonical model picker reconciliation,
  # remote project config, the VCT projects list + the
  # notified-terminal-id seed). The handler drops stale results (wrong node or
  # active project) in AsyncLoad.handle_result/5, which reports whether it
  # applied anything, then:
  #
  #   * auto-activates the newest-opened project when this was the
  #     no-`?project=` local run (maybe_auto_activate_project/1 — this
  #     replaces the old synchronous mount seed, so the project opens one frame
  #     later with the same end state);
  #   * re-runs GitHub.maybe_check/1: the remote task_mode now arrives via this
  #     continuation, so the remote upstream-detection needs this second kick —
  #     maybe_check is self-guarding (no-ops once a status is present), so the
  #     extra call is harmless on every other path.
  @impl true
  def handle_info({:async_project_load, node, prev_node_id, path, results}, socket) do
    {socket, applied?} = AsyncLoad.handle_result(socket, node, prev_node_id, path, results)

    socket =
      if applied? && Map.has_key?(results, :task_mode),
        do: use_git_task_mode(socket),
        else: socket

    socket =
      if applied? and Map.get(results, :auto_activate?, false) do
        maybe_auto_activate_project(socket)
      else
        socket
      end

    {:noreply, GitHub.maybe_check(socket)}
  end

  # Async remote project activation — the continuation for the task spawned by
  # ProjectFlow.spawn_remote_project_activation/2 (open_project/select_project
  # events + the palette Enter path). STALE-GUARD: the captured node must
  # still be the current node AND the captured path must still be the
  # in-flight `@remote_project_loading` path — a node switch clears the flag
  # in handle_params/3, and a superseding activation replaces it with a
  # different path, so results from obsolete spawns are dropped here. On
  # success the assigns the sync flow applied today are restored (the palette
  # already closed at spawn), the GitHub state is reset when the project
  # changed (same semantics as the old sync Palette.activate_remote_project/2 —
  # `project_changed?` is computed from the PRE-apply socket), and the URL is
  # patched so handle_params re-runs in the same remote context. On
  # `{:error, :not_a_directory}` the loading flag clears and the error flash
  # fires (the one RPC-derived error of the sequence — it must run in this
  # continuation, not in the event handler). When the applied activation was
  # resume-aware (a non-empty `task_resume_from` was pending), the restored
  # task foreign repos are additionally guarded against the AsyncLoad
  # remote_extras reload the push_patch triggers (see
  # `maybe_flag_resume_foreign_repos/1`).
  @impl true
  def handle_info({:async_remote_project, node, path, result}, socket) do
    cond do
      node != socket.assigns[:current_node] ->
        {:noreply, socket}

      path != socket.assigns.remote_project_loading ->
        {:noreply, socket}

      true ->
        case result do
          {:ok, results} ->
            project_changed? = Map.get(socket.assigns, :active_project_path) != path

            socket =
              socket
              |> assign(:remote_project_loading, nil)
              |> assign(:projects, results.projects)
              |> assign(:active_project, results.active_project)
              |> assign(:active_project_path, results.active_project_path)
              |> assign(:task_mode, results.task_mode)
              |> assign(:task_mode_info, results.task_mode_info)
              |> use_git_task_mode()
              |> assign(:project_config, results.project_config)
              |> assign(:project_config_mtime, Project.project_config_mtime(path))
              |> assign(:worktree_script, results.worktree_script)
              |> assign(:commands, results.commands)
              |> assign(:foreign_repos, results.foreign_repos)
              |> assign(:show_add_foreign_repo_form, false)
              |> maybe_flag_resume_foreign_repos()
              |> maybe_reset_github_state(project_changed?)
              |> GitHub.maybe_check()

            params = socket.assigns.workbench_reconnect_params

            if (params["wb_home"] == "1" or git_task_draft?(params)) and params["project"] == path do
              # The project link already updated the URL. Load node data
              # against the validated project without adding a second entry.
              {:noreply, AsyncLoad.maybe_spawn(socket, socket.assigns.current_node_id)}
            else
              {:noreply, push_patch(socket, to: project_url(socket, path))}
            end

          {:error, :not_a_directory} ->
            socket =
              socket
              |> assign(:remote_project_loading, nil)
              |> put_flash(
                :error,
                gettext("Directory does not exist on the remote node: %{path}", path: path)
              )

            {:noreply, socket}
        end
    end
  end

  # A repeat or OLDER generation for the same config dir is not a new change; a
  # different dir is a new identity.
  defp stale_config_generation?(nil, _dir, _generation), do: false
  defp stale_config_generation?({dir, handled}, dir, generation), do: generation <= handled
  defp stale_config_generation?(_handled, _dir, _generation), do: false

  # When a resume-aware remote activation (see
  # `ProjectFlow.spawn_remote_project_activation/3` — the URL-driven `?project=`
  # + `resume_from` landing) just applied, `results.foreign_repos` already
  # holds the RESUMED task's repos, restored node-aware inside the activation
  # task. The continuation's push_patch below re-runs handle_params, whose
  # AsyncLoad remote_extras reload would otherwise replace them with the
  # project's genesis.toml repos a frame later — the same clobber the LOCAL
  # resume flow avoids by running its task-repos restore AFTER the
  # genesis.toml load. Flag the socket so the next AsyncLoad result skips the
  # `:foreign_repos` key (and clears the flag). Plain activations (no pending
  # resume) set nothing — their genesis.toml values are identical anyway, so
  # the follow-up AsyncLoad refresh stays exactly as before.
  defp maybe_flag_resume_foreign_repos(socket) do
    if is_binary(socket.assigns.task_resume_from) and socket.assigns.task_resume_from != "" do
      assign(socket, :resume_foreign_repos_guard, true)
    else
      socket
    end
  end

  # Auto-activates the newest project once the async seed has produced
  # the projects list (replaces the old synchronous mount-time auto-load). Only
  # for a LOCAL context whose handle_params run carried no `?project=`; a
  # missing/non-existent path leaves the no-project view untouched.
  defp open_project_palette(socket) do
    # Gate guard (defense in depth): never open the palette while a selected
    # remote target is pending/failed — `@current_node` is still the LOCAL
    # BEAM node in that state, so project activation would touch local data
    # while the user believes they are operating on the remote node.
    if EvoDashWeb.RemoteGateComponents.gate_active?(socket.assigns) do
      socket
    else
      socket
      |> assign(:project_palette_open, true)
      |> assign(:palette_mode, :menu)
      |> assign(:palette_search, "")
      |> assign(:palette_selected_index, 0)
    end
  end

  defp maybe_auto_activate_project(socket) do
    if socket.assigns.auto_activate_candidate? == true and
         is_nil(socket.assigns[:current_node_id]) and
         is_nil(socket.assigns.active_project) do
      case List.first(socket.assigns.projects) do
        %{path: project_path} when is_binary(project_path) ->
          if File.dir?(project_path) do
            activated = activate_project(socket, project_path)

            if socket.assigns.workbench_open_requested,
              do: open_project_palette(activated),
              else: activated
          else
            socket
          end

        _ ->
          socket
      end
    else
      socket
    end
  end

  # Restores foreign_repos from a previous task's opts when resuming ("continue
  # from here") — ASYNC: the previous task's row is fetched in a supervised
  # task (a `get_task_lite/1` read never runs in the LiveView process) and the
  # converted repos arrive as `{:foreign_repos_restored, task_id, node,
  # result}`. `foreign_repos_restoring_from` marks the in-flight restore so
  # task_submit can refuse to launch with a half-restored foreign-repo list.
  #
  # The lookup extracts `task.opts[:foreign_repos]` and converts the values to
  # `%ForeignRepo{}` structs, tolerating every persisted shape:
  #   - Fresh `%ForeignRepo{}` structs (from an in-memory task)
  #   - Maps with `"root"` key (Jason-decoded from the DB, via `@derive {Jason.Encoder}`)
  #   - Maps with `"path"` key (sessionStorage serialization format, as a fallback)
  # Remote resume settings are restored by the remote activation task instead.
  defp start_foreign_repos_restore(
         %{assigns: %{current_node_id: target_id, current_node: target_node}} = socket,
         _task_id
       )
       when not is_nil(target_id) or target_node != node(),
       do: socket

  defp start_foreign_repos_restore(socket, task_id) do
    node = socket.assigns[:current_node] || node()
    parent = self()

    case Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
           result =
             SafeCall.run(fn ->
               # Only `opts` is read here, so the lite read (no archive blob) suffices.
               case TaskRegistry.get_task_lite(task_id) do
                 nil -> []
                 task -> ForeignRepos.from_task_opts(task.opts[:foreign_repos])
               end
             end)

           send(parent, {:foreign_repos_restored, task_id, node, result})
         end) do
      # Only mark the restore in flight when the task really started — a spawn
      # failure must not wedge the submit guard forever.
      {:ok, _pid} -> assign(socket, :foreign_repos_restoring_from, task_id)
      {:error, _reason} -> socket
    end
  end

  # ---------------------------------------------------------------------------
  # VCT workspaces (palette "Workspaces" section)
  #
  # A workspace is a pure GROUPING point (`path: nil`): it is never activated,
  # never becomes a task path and never reaches `path_suggestions` or the
  # persisted form state. Only its name/members/description are managed here.
  # ---------------------------------------------------------------------------

  # Authoritative VCT reload (projects + workspaces) OFF the LiveView process.
  # Bumps BOTH monotonic seqs and delivers through the existing
  # `{:projects_loaded, …}` / `{:workspaces_loaded, …}` messages.
  defp reload_vct(socket) do
    node = socket.assigns[:current_node] || node()
    node_id = socket.assigns[:current_node_id]
    remote? = socket.assigns.remote? == true
    projects_seq = socket.assigns.projects_seq + 1
    workspaces_seq = socket.assigns.workspaces_seq + 1
    parent = self()

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      projects = SafeCall.run(fn -> AsyncLoad.load_projects(remote?, node_id, node) end)
      send(parent, {:projects_loaded, projects_seq, node_id, node, projects})

      workspaces = SafeCall.run(fn -> AsyncLoad.load_workspaces(remote?, node_id, node) end)
      send(parent, {:workspaces_loaded, workspaces_seq, node, workspaces})
    end)

    socket
    |> assign(:projects_seq, projects_seq)
    |> assign(:workspaces_seq, workspaces_seq)
  end

  # Builds the dashboard URL for a project path. In a remote context the
  # `&node=` param is appended so the node context survives the push_patch —
  # NOTE: deliberately NOT `EvoDashWeb.Helpers.with_node_param/2`, which
  # appends with `?` and would corrupt the existing `?project=` query.
  defp project_url(socket, path) do
    params = socket.assigns.workbench_reconnect_params

    query =
      [project: path] ++
        Enum.reject([wb_home: params["wb_home"], wb_task: params["wb_task"]], fn {_, value} ->
          is_nil(value)
        end)

    EvoDashWeb.WorkbenchComponent.navigation_path(
      "/projects",
      socket.assigns.current_node_id,
      query
    )
  end

  defp git_task_draft?(%{
         "wb_task" => "1",
         "wb_git_branch" => branch,
         "starting_commit" => commit
       })
       when is_binary(branch) and byte_size(branch) in 1..1024 and is_binary(commit),
       do: Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, commit)

  defp git_task_draft?(_), do: false

  defp use_git_task_mode(socket) do
    if git_task_draft?(socket.assigns.workbench_reconnect_params) do
      assign(socket,
        task_mode: "evolve_simple",
        task_mode_info: mode_info_message("evolve_simple")
      )
    else
      socket
    end
  end

  defp activate_project(socket, path) do
    name = Path.basename(path)
    is_project_change = socket.assigns.active_project_path != path

    # Only auto-detect mode when switching to a different project.
    # Preserve the user's manual mode selection on re-navigation/reconnect.
    {mode, mode_info} =
      if is_project_change do
        detected = Project.detect_mode(path)
        {detected, mode_info_message(detected)}
      else
        current_mode = socket.assigns.task_mode
        {current_mode, socket.assigns.task_mode_info}
      end

    # Load project settings eagerly — read genesis.toml once and thread
    # through all consumers to avoid redundant disk reads.
    config = ProjectConfig.read(path)
    {project_config, worktree_script, commands} = Project.load_project_config(path, config)
    foreign_repos = Project.load_foreign_repos(path, config)

    socket
    |> assign(
      # The display-only VCT identity comes from the projects list ALREADY
      # loaded in assigns (the VCT owns it) — a pure in-memory lookup, so no
      # VCT/RPC call ever runs here.
      active_project: %{
        path: path,
        name: name,
        point: ProjectFlow.mount_point_for(socket.assigns.projects, path)
      },
      active_project_path: path,
      task_mode: mode,
      task_mode_info: mode_info,
      project_palette_open: false,
      palette_mode: :menu,
      palette_search: "",
      palette_selected_index: 0,
      show_project_settings: false,
      project_config: project_config,
      project_config_mtime: Project.project_config_mtime(path),
      worktree_script: worktree_script,
      commands: commands,
      foreign_repos: foreign_repos,
      show_add_foreign_repo_form: false
    )
    |> Project.maybe_put_flash_mode_info(mode_info)
    # `is_project_change` is computed from the PRE-assign socket above.
    |> maybe_reset_github_state(is_project_change)
    |> GitHub.maybe_check()
  end

  # Re-reads the active project's genesis.toml (config + worktree script +
  # commands) and stores the file's mtime beside it.
  #
  # `force?` bypasses the change check (the explicit project-settings OPEN must
  # always show current settings). Otherwise the file is re-parsed ONLY when its
  # mtime differs from the one captured with the config: the
  # `:node_aware_reload_tasks` debounce fires on the trailing edge of EVERY task
  # broadcast — continuously while a task runs — and `File.stat/1` is cheap
  # where a TOML parse is not.
  #
  # A REMOTE project's genesis.toml lives on the other host, so a local read
  # would clobber the RPC-loaded config with nil; that config arrives with the
  # activation / AsyncLoad result instead, and this helper leaves it alone.
  defp refresh_project_config(socket, force? \\ false) do
    path = Map.get(socket.assigns, :active_project_path)
    mtime = Project.project_config_mtime(path)

    if is_binary(path) and not Map.get(socket.assigns, :remote?, false) and
         (force? or mtime != Map.get(socket.assigns, :project_config_mtime)) do
      {project_config, worktree_script, commands} = Project.load_project_config(path)

      socket
      |> assign(:project_config, project_config)
      |> assign(:project_config_mtime, mtime)
      |> assign(:worktree_script, worktree_script)
      |> assign(:commands, commands)
    else
      socket
    end
  end

  # Resets the GitHub issue integration state when the active project path
  # CHANGES (same-path re-activations keep the resolved status/modal). The
  # async detection re-runs via `GitHub.maybe_check/1` after the reset.
  defp maybe_reset_github_state(socket, project_changed?) do
    if project_changed? do
      socket
      |> assign(:github_status, nil)
      |> assign(:github_modal_open, false)
      |> assign(:github_issues, GitHub.idle_issues())
      |> assign(:github_fixing, nil)
    else
      socket
    end
  end

  # Picker transitions are pure and use only the already-loaded node bundle.
  # Invalid events leave the current selection intact; explicit choices discard
  # a pending browser restore so a delayed batch cannot resurrect it.
  defp change_model_selection(socket, transition) do
    case ModelSelectionScope.bundle(socket.assigns) do
      {:ok, bundle} ->
        case transition.(bundle, socket.assigns.selected_model_spec) do
          {:ok, spec} ->
            {:noreply,
             socket
             |> assign(:selected_model_spec, spec)
             |> assign(:pending_model_selection, nil)
             |> StatePersistence.maybe_persist_model_selection()}

          {:error, _reason} ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # do_task_submit/4 — builds the start_task opts and launches the task.
  # Called by handle_event("task_submit") AFTER its guards (project open +
  # custom mode has a selected agent). Lives down here with the other
  # private helpers so the handle_event/3 clauses stay grouped.
  #
  # The option building itself is PURE and lives in
  # EvoDashWeb.ProjectsLive.TaskSubmit: the UI combined-mode → core mode
  # mapping, the message/objective, build system, node path, starting commit,
  # foreign repos, archive, resume-from, the staged-attachment re-check and the
  # base64 `:attachments` opt, ending in the shared LaunchOptions
  # model/agent/quality/persistent-state policy. This function only wires it
  # up: the attachment-cap refusal, the async launch and the flashes.
  defp do_task_submit(prompt, combined_mode, params, socket) do
    path = socket.assigns.active_project_path
    {task_type, mode} = TaskSubmit.mode(combined_mode)

    case TaskSubmit.build_opts(prompt, task_type, mode, path, params, socket.assigns) do
      {:ok, opts} ->
        # The launch itself is a store/RPC write (a `GenServer.call` locally,
        # an `:erpc` round-trip remotely) that can take seconds, so it runs in
        # a supervised task and the page stays responsive. The outcome arrives
        # as `{{:task_started, seq, task_type}, result}` where `result` keeps
        # `start_task`'s documented `{:ok, task} | {:error, reason}` shape:
        # `EvoDash.SafeCall.run/1` turns a dead, busy or timed-out target into
        # an ERROR VALUE instead of an EXIT that would take the page down, and
        # SafeCall.start/3 wraps it as `{tag, result}`.
        #
        # The prompt, the staged attachments and the form are deliberately NOT
        # cleared here: the ack owns that, so a launch that fails still leaves
        # a retry-able form (a "Failed to start task" flash must never arrive
        # with an emptied textarea).
        remote? = socket.assigns.remote?
        current_node = socket.assigns.current_node
        seq = socket.assigns.task_launch_seq + 1

        case SafeCall.start(self(), {:task_started, seq, task_type}, fn ->
               SafeCall.run(fn ->
                 if remote? do
                   NodeContext.start_task(current_node, task_type, opts)
                 else
                   TaskRegistry.start_task(task_type, opts)
                 end
               end)
               |> case do
                 {:ok, start_result} -> start_result
                 {:error, reason} -> {:error, reason}
               end
             end) do
          {:ok, _pid} ->
            {:noreply,
             socket
             |> assign(:task_launch_seq, seq)
             |> assign(:task_launching, true)}

          {:error, reason} ->
            # The task never started, so no ack will arrive: clear the marker
            # and report the failure exactly like a refused launch.
            {:noreply,
             socket
             |> assign(:task_launching, false)
             |> put_flash(
               :error,
               gettext("Failed to start task: %{reason}", reason: inspect(reason))
             )}
        end

      # The staged attachments are deliberately left in place (nothing is
      # cleared) so the user can trim them and retry.
      # zh_CN: 附件超过数量/大小上限，任务未启动，已暂存的附件保留，用户可删除后重试。
      {:error, :attachments_over_cap} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Too many attachments or an attachment is too large — remove some and try again."
           )
         )}

      # No model configured: the pre-spawn guard refuses the launch, so no ack
      # will ever arrive. Render the SAME friendly, actionable line the async
      # ack uses for `:no_task_model`, so both routes agree byte-for-byte
      # instead of falling into the generic "Failed to start task" wording.
      # zh_CN: 服务器尚未配置模型，任务未启动，提示用户先去配置模型。
      {:error, :no_task_model} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Configure a model on this server before launching a task.")
         )}

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
