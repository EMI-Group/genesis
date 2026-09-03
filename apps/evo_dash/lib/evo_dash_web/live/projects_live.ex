defmodule EvoDashWeb.ProjectsLive do
  @moduledoc """
  Project-based task dashboard for launching and monitoring EvoGit tasks.

  Users open a repository, and the dashboard auto-detects the task mode
  (genesis or evolve). Displays active tasks with live logs and inline
  project settings including foreign repositories.
  """
  use EvoDashWeb, :live_view
  alias EvoGit.TaskRegistry

  alias EvoDashWeb.ProjectsLive.{
    StatePersistence,
    Project,
    Assigns,
    ProjectFlow,
    RemoteView,
    AttachFile,
    GitHub,
    AsyncLoad
  }

  alias EvoDashWeb.ThemeColor
  alias EvoDashWeb.ExampleTask
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Platform
  alias EvoDash.NodeContext
  alias EvoGit.ProjectConfig

  # Picker id for the objective editor's attach-file button — must match the
  # `data-picker-id` on the FilePicker hook button in
  # EvoDashWeb.TaskFormComponents.task_form/1 and the `@attach_picker_id`
  # literal in the AttachFile support module (kept as a literal in both
  # modules — a compile-time function call in a module attribute is fragile
  # under parallel compilation).
  @attach_picker_id "objective_file"

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
        desktop_quit_confirm={@desktop_quit_confirm}
        update_status={@update_status}
        guide={@guide}
        accent_color={assigns[:accent_color] || "blue"}
      >
        <%!--
          Full-bleed Phoenix LiveDashboard: no header chrome — the iframe
          fills the entire main content area. The `Layouts.app` main content
          is `flex-1` inside an `h-screen` flex column with `py-4` padding
          (1rem top + 1rem bottom = 2rem), so `calc(100vh - 2rem)` spans
          exactly the available area with no wasted space.
        --%>
        <iframe
          src={~p"/phoenix/dashboard/home"}
          class="w-full"
          style="min-height: calc(100vh - 2rem); border: none;"
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
        running_tasks={@running_tasks}
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
          phx-hook="StatePersistence"
          data-project={@active_project_path}
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
            class="flex-1 flex flex-col min-h-0"
          >
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
            <%= cond do %>
              <% is_nil(@current_node_id) -> %>
                <div class="flex-1 flex flex-col min-h-0 gap-3">
                  <RemoteView.top_bar
                    active_project={@active_project}
                    active_project_path={@active_project_path}
                    no_project_hint_dismissed={@no_project_hint_dismissed}
                    recent_projects={@recent_projects}
                    palette_open={@project_palette_open}
                    palette_search={@palette_search}
                    palette_mode={@palette_mode}
                    palette_selected_index={@palette_selected_index}
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
                    foreign_repo_path_suggestions={@foreign_repo_path_suggestions}
                    show_add_foreign_repo_form={@show_add_foreign_repo_form}
                    new_repo_id={@new_repo_id}
                    new_repo_path={@new_repo_path}
                    new_repo_description={@new_repo_description}
                    disabled={is_nil(@active_project)}
                    show_configure_dropdown={@show_configure_dropdown}
                    github_status={@github_status}
                  />

                  <%!-- No-project page dim: purely visual (position: fixed,
                       pointer-events: none — CSS in app.css), tied to the same
                       flag as the top-bar hint pill so dismissing the hint
                       also lifts the dim. --%>
                  <%= if is_nil(@active_project) and !@no_project_hint_dismissed do %>
                    <div class="no-project-overlay" aria-hidden="true"></div>
                  <% end %>

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
                    custom_agents={@custom_agents}
                    selected_agent_id={@selected_agent_id}
                    show_auto_model_option={@model_selection_enabled}
                    build_systems={@build_systems}
                    selected_build_system={@task_build_system}
                  />

                  <%= if is_nil(@active_project) do %>
                    <%!-- Empty-state example task help — shown only while no
                         project is open (disappears once one is activated).
                         Collapsible <details> + max-height scrollable <pre> keep
                         it compact so it can never overflow on small screens.
                         The hidden textarea is an RCDATA holder: reading .value
                         in JS returns the exact example text (including the
                         literal <link>/<script> strings) without HTML injection.
                         The prefill button sets the prompt textarea's .value
                         (never innerHTML) and dispatches a bubbling `input`
                         event, which drives the AdaptiveInput hook (autogrow
                         + client-side layout switch — the example exceeds the
                         600-grapheme threshold, so the layout flips to
                         expanded; the flip can also be height-driven). No
                         server event is involved; @task_prompt
                         is only updated by restore_state / task_submit. --%>
                    <div class="mx-auto w-full max-w-3xl px-4 pb-4 shrink-0">
                      <details
                        class="group rounded-lg border border-base-300 bg-base-100/60 shadow-sm"
                        open
                      >
                        <summary class="flex items-center gap-2 px-4 py-3 text-sm font-medium text-base-content/80 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
                          <.icon name="hero-sparkles" class="size-4 shrink-0 text-primary/70" />
                          <span>{gettext("New to Genesis? Start with an example")}</span>
                          <span class="ml-auto text-xs font-normal text-base-content/60">
                            <span class="group-open:hidden">{gettext("Show example")}</span>
                            <span class="hidden group-open:inline">{gettext("Hide example")}</span>
                          </span>
                        </summary>
                        <div class="px-4 pb-4 pt-1">
                          <p class="text-sm text-base-content/70 mb-3">
                            {gettext(
                              "Set an end goal, launch, and Genesis builds it — it figures out the architecture, delegates agents, and writes the code."
                            )}
                          </p>
                          <div class="relative rounded-md border border-base-300 bg-base-200/50">
                            <pre class="max-h-48 overflow-y-auto p-3 pr-12 font-mono text-xs leading-relaxed whitespace-pre-wrap text-base-content/80"><%= ExampleTask.example_objective() %></pre>
                            <button
                              id="example-task-copy"
                              phx-hook="ClipboardCopy"
                              data-content={ExampleTask.example_objective()}
                              class="btn btn-ghost btn-sm btn-square absolute top-2 right-2 bg-base-100/80"
                              title={gettext("Copy")}
                            >
                              <.icon name="hero-clipboard" class="size-4" />
                            </button>
                          </div>
                          <button
                            id="example-task-prefill"
                            type="button"
                            onclick="var h=document.getElementById('example-task-objective');var p=document.getElementById('prompt');if(h&&p){p.value=h.value;p.dispatchEvent(new Event('input',{bubbles:true}));}"
                            class="btn btn-ghost btn-sm mt-3 gap-1.5"
                          >
                            <.icon name="hero-arrow-down-tray" class="size-4" />
                            {gettext("Use this example")}
                          </button>
                        </div>
                      </details>
                      <textarea
                        id="example-task-objective"
                        class="hidden"
                        readonly
                        tabindex="-1"
                        aria-hidden="true"
                      ><%= ExampleTask.example_objective() %></textarea>
                    </div>
                  <% end %>
                </div>
              <% @remote? -> %>
                <div class="flex-1 flex flex-col min-h-0 gap-3">
                  <RemoteView.top_bar
                    remote={true}
                    current_node_name={@current_node_name}
                    active_project={@active_project}
                    active_project_path={@active_project_path}
                    no_project_hint_dismissed={@no_project_hint_dismissed}
                    recent_projects={@recent_projects}
                    palette_open={@project_palette_open}
                    palette_search={@palette_search}
                    palette_mode={@palette_mode}
                    palette_selected_index={@palette_selected_index}
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
                    foreign_repo_path_suggestions={@foreign_repo_path_suggestions}
                    show_add_foreign_repo_form={@show_add_foreign_repo_form}
                    new_repo_id={@new_repo_id}
                    new_repo_path={@new_repo_path}
                    new_repo_description={@new_repo_description}
                    disabled={is_nil(@active_project)}
                    show_configure_dropdown={@show_configure_dropdown}
                    github_status={@github_status}
                  />

                  <div class="mt-2 mb-4 rounded-lg border border-info/30 bg-info/5 p-3 flex items-start gap-2">
                    <.icon name="hero-server-stack" class="size-5 text-info shrink-0 mt-0.5" />
                    <p class="text-sm text-base-content/70">
                      {gettext("You are viewing a remote node. Tasks launched here will run on the remote machine.")}
                    </p>
                  </div>

                  <%!-- Remote project activation in flight: the RPC-heavy
                       sequence runs in a supervised task (spawned by
                       ProjectFlow.spawn_remote_project_activation/2), so this
                       banner is the only feedback until the result applies.
                       The path shown is the one being loaded. --%>
                  <%= if @remote_project_loading != nil do %>
                    <div class="mb-2 rounded-lg border border-base-300 bg-base-200/50 px-3 py-2 flex items-center gap-2">
                      <span class="loading loading-spinner loading-sm text-primary"></span>
                      <%!-- 正在通过远程节点加载所选项目，加载完成前任务表单保持禁用 --%>
                      <span class="text-sm text-base-content/70">{gettext("Loading project…")}</span>
                      <code class="text-xs text-base-content/70 font-mono truncate min-w-0">
                        {@remote_project_loading}
                      </code>
                    </div>
                  <% end %>

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
                    custom_agents={@custom_agents}
                    selected_agent_id={@selected_agent_id}
                    show_auto_model_option={@model_selection_enabled}
                    build_systems={@build_systems}
                    selected_build_system={@task_build_system}
                  />
                </div>

                <%= if @remote_agents == [] do %>
                  <div class="mt-6 text-center py-10 text-base-content/70 animate-fade-in-up">
                    <div class="animate-float">
                      <.icon name="hero-inbox" class="size-14 mx-auto mb-3 text-base-content/40" />
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
                        <div class="rounded-lg border border-base-300 bg-base-100 p-4">
                          <div class="flex items-center justify-between gap-3 mb-2">
                            <div class="flex items-center gap-2 min-w-0">
                              <span class="badge badge-ghost badge-sm font-mono shrink-0">
                                #{Map.get(agent, :id, "?")}
                              </span>
                              <code class="text-xs text-base-content/70 truncate">
                                {Map.get(agent, :agent_module, "")}
                              </code>
                            </div>
                            <span class={[
                              "badge badge-sm shrink-0",
                              case Map.get(agent, :status) do
                                :running -> "badge-success"
                                :pending -> "badge-warning"
                                :blocked -> "badge-warning"
                                :waiting -> "badge-info"
                                :ready -> "badge-info"
                                _ -> "badge-ghost"
                              end
                            ]}>
                              {case Map.get(agent, :status) do
                                s when is_atom(s) ->
                                  agent_status_label(s)

                                _ ->
                                  gettext("Unknown")
                              end}
                            </span>
                          </div>
                          <% objective = Map.get(agent, :objective) %>
                          <%= if objective do %>
                            <p class="text-sm text-base-content/70 line-clamp-2">{objective}</p>
                          <% end %>
                          <div class="flex flex-wrap gap-3 mt-2 text-xs text-base-content/70">
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
              <% phase in [:connecting, :bootstrapping, :disconnecting] -> %>
                <!-- Pending remote context: connecting chrome only — no
                     project data, no task form, no local recents (the
                     node-switch clear already reset project state). -->
                <RemoteView.top_bar
                  remote={true}
                  hide_palette={true}
                  current_node_name={@current_node_name}
                  active_project={@active_project}
                  active_project_path={@active_project_path}
                  no_project_hint_dismissed={@no_project_hint_dismissed}
                  recent_projects={@recent_projects}
                  palette_open={@project_palette_open}
                  palette_search={@palette_search}
                  palette_mode={@palette_mode}
                  palette_selected_index={@palette_selected_index}
                  path_suggestions={@path_suggestions}
                  tauri_detected={@tauri_detected}
                  platform={@platform}
                  github_status={@github_status}
                />
                <RemoteView.connecting_state current_node_name={@current_node_name} />
              <% true -> %>
                <!-- Failed/disconnected remote context: prominent error state
                     with Retry / Manage Connections / Switch to Local. -->
                <RemoteView.top_bar
                  remote={true}
                  hide_palette={true}
                  current_node_name={@current_node_name}
                  active_project={@active_project}
                  active_project_path={@active_project_path}
                  no_project_hint_dismissed={@no_project_hint_dismissed}
                  recent_projects={@recent_projects}
                  palette_open={@project_palette_open}
                  palette_search={@palette_search}
                  palette_mode={@palette_mode}
                  palette_selected_index={@palette_selected_index}
                  path_suggestions={@path_suggestions}
                  tauri_detected={@tauri_detected}
                  platform={@platform}
                  github_status={@github_status}
                />
                <RemoteView.error_state
                  current_node_name={@current_node_name}
                  last_error={Map.get(@remote_status || %{}, :last_error)}
                />
            <% end %>
            <%!-- end of node-context cond --%>

            <%!-- GitHub issues modal — rendered OUTSIDE the node-context cond
                 so it works in both the local and remote-connected branches.
                 It can only be opened from those branches anyway: the top-bar
                 GitHub button renders only after the async upstream check
                 resolves :ok, and project/node switches reset the flag. --%>
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

      recent_projects = filter_absolute_recent_projects(TaskRegistry.list_recent_projects())

      # Pre-resolve config once and memoize via Process dict so that the
      # deferred :load_config_status handler can reuse this result instead
      # of re-reading and re-parsing config.toml.
      Process.put(:memo_config_resolve, EvoGit.Config.resolve())

      # Defer config_status to handle_info — it reads config.toml +
      # credentials.toml and is NOT needed for the first paint. The
      # config warning banner can appear a frame later.
      config_status = nil

      # Node-aware: at mount the NodeAware on_mount hook has seeded
      # current_node to the LOCAL node (the ?node= param is resolved later in
      # handle_params), so this is the local config path — but the node is
      # threaded explicitly so the loader never consults the local
      # :memo_config_resolve memo for a remote context.
      {model_profiles, selected_model_id} =
        Project.load_model_profiles(socket.assigns[:current_node])

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
          no_project_hint_dismissed: false,
          project_palette_open: false,
          palette_search: "",
          palette_mode: :menu,
          palette_selected_index: 0,
          recent_projects: recent_projects,
          path_suggestions: [],
          foreign_repo_path_suggestions: [],
          show_project_settings: false,
          project_config: nil,
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
          show_configure_dropdown: false,
          model_profiles: model_profiles,
          selected_model_id: selected_model_id,
          custom_agents: custom_agents,
          selected_agent_id: nil,
          model_selection_enabled: model_selection_enabled,
          build_systems: build_systems,
          tauri_detected: false,
          platform: "linux",
          notified_task_ids: Assigns.build_notified_task_ids(MapSet.new()),
          # Prompt snapshot per attach-file picker id, taken when the native
          # file dialog opens (see handle_event("file_pick")) so the picked
          # file's text can be appended even if the user keeps typing while
          # the dialog is open.
          file_pick_bases: %{},
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
          config_tab: "task_options",
          remote?: false,
          remote_agents: []
        )

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    prev_node_id = socket.assigns[:current_node_id]

    # NOTE: `remote?` must be derived from the socket AFTER `assign_node/2`
    # re-assigns `current_node` — computing it inside the pipe from the outer
    # `socket` variable would read the PRE-assign_node value, so a page load at
    # a connected `?node=` URL would render the error gate on the first pass.
    socket = EvoDashWeb.LiveHooks.NodeAware.assign_node(socket, params)
    socket = assign(socket, :current_path, ~p"/projects")
    socket = assign(socket, :remote?, socket.assigns.current_node != node())

    # Node-aware refresh (custom agents + model-selection script state, model
    # profiles + the node-switch `selected_model_id` validation, remote
    # agents / remote project config, and recent projects) now runs in ONE
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
      if prev_node_id != socket.assigns[:current_node_id] do
        socket
        |> assign(:file_pick_bases, %{})
        |> assign(:remote_project_loading, nil)
        |> assign(:github_status, nil)
        |> assign(:github_modal_open, false)
        |> assign(:github_issues, GitHub.idle_issues())
        |> assign(:github_fixing, nil)
      else
        socket
      end

    project_path = params["project"]

    socket =
      if socket.assigns[:current_node_id] != nil do
        # Any remote context (connected OR pending): never activate or
        # auto-load a LOCAL project — skip `params["project"]` expansion,
        # `File.dir?` checks, and auto-load-most-recent entirely. A
        # display-only remote project selection made via the palette must
        # survive same-node handle_params runs; the node-switch clear above is
        # what resets it.
        socket
      else
        if is_binary(project_path) do
          case ProjectFlow.normalize_project_path(project_path) do
            {:ok, expanded} ->
              if File.dir?(expanded) do
                activate_project(socket, expanded)
              else
                # Project path in URL is invalid, clear it
                socket
                |> assign(
                  :notified_task_ids,
                  Assigns.build_notified_task_ids(socket.assigns.notified_task_ids)
                )
                |> assign(
                  active_project: nil,
                  active_project_path: nil
                )
              end

            # Relative or blank project params (stale/legacy URLs, or entries
            # from previously-polluted recents) are silently ignored: never
            # `Path.expand` against the VM cwd — the Windows desktop backend
            # inherits the Tauri process cwd, so a relative input would join
            # against the install dir. handle_params runs on every navigation,
            # so no flash here; the param just doesn't activate a project.
            {:error, _reason} ->
              socket
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
                    socket
                    |> assign(
                      :notified_task_ids,
                      Assigns.build_notified_task_ids(socket.assigns.notified_task_ids)
                    )
                  end

                _ ->
                  socket
                  |> assign(
                    :notified_task_ids,
                    Assigns.build_notified_task_ids(socket.assigns.notified_task_ids)
                  )
              end
            else
              # We had a project but navigated away and back without it
              socket
            end

          socket
        end
      end

    # Spawn the grouped async node-aware load (custom agents, model profiles,
    # remote agents / remote project config, recent projects — see the
    # comment above and EvoDashWeb.ProjectsLive.AsyncLoad). The spawn runs
    # AFTER the node-switch state clearing AND the project-activation block
    # above, so it captures the post-clear, post-activation active project
    # path — the identity the AsyncLoad stale-guard compares against, so a
    # result spawned for the very activation that just happened is never
    # dropped as "stale" (and a remote→local switch can never keep a remote
    # node's agents/model profiles/recents after a local project activates).
    socket = AsyncLoad.maybe_spawn(socket, prev_node_id)

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

    # Async GitHub-upstream detection (never runs synchronously — spawns a
    # supervised Task). Runs AFTER project restoration above so
    # `active_project_path`/`task_mode` are settled; no-ops when no project
    # is active, the mode is genesis_new, or a status is already present.
    socket = GitHub.maybe_check(socket)

    {:noreply, socket}
  end

  # --- Project Management Events ---

  @impl true
  def handle_event("open_project_palette", _params, socket) do
    # Gate guard (defense in depth): never open the palette while a selected
    # remote target is pending/failed — `@current_node` is still the LOCAL
    # BEAM node in that state, so project activation would touch local data
    # while the user believes they are operating on the remote node.
    if EvoDashWeb.RemoteGateComponents.gate_active?(socket.assigns) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:project_palette_open, true)
       |> assign(:palette_mode, :menu)
       |> assign(:palette_search, "")
       |> assign(:palette_selected_index, 0)
       |> assign(:show_configure_dropdown, false)}
    end
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

  # Dismisses the "Open or create a project" hint pill in the top bar (the
  # no-project page dim overlay is tied to the same flag). The hint returns
  # for future no-project sessions — activate_project/2 resets the flag.
  @impl true
  def handle_event("dismiss_no_project_hint", _params, socket) do
    {:noreply, assign(socket, :no_project_hint_dismissed, true)}
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
    mode =
      case mode_str do
        "open_path" -> :open_path
        "new_project" -> :new_project
        _ -> :menu
      end

    socket =
      socket
      |> assign(:palette_mode, mode)

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
            socket.assigns.recent_projects
          )
        )
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("palette_keydown", %{"key" => key}, socket) do
    socket = handle_palette_key(socket, key, socket.assigns.palette_mode)
    {:noreply, socket}
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

  # Deletes a recent-project entry from the open-project palette WITHOUT
  # opening the project. LOCAL-only: recent-project removal is not exposed
  # over the remote RPC chain, and remote projects are read-only by design —
  # the delete button only renders in local contexts (palette_menu hides it
  # when `remote`), so this guard is defensive. `remove_recent_project`
  # broadcasts {:recent_projects_updated} on PubSub, but we also re-read and
  # re-assign immediately so the list updates on this render cycle; the
  # broadcast handler then refreshes it again idempotently. The selected
  # index resets to 0 so keyboard navigation stays in sync with the
  # shortened list.
  @impl true
  def handle_event("remove_recent_project", %{"path" => path}, socket) do
    if socket.assigns[:current_node_id] != nil do
      {:noreply, socket}
    else
      TaskRegistry.remove_recent_project(path)

      {:noreply,
       socket
       |> assign(
         :recent_projects,
         filter_absolute_recent_projects(TaskRegistry.list_recent_projects())
       )
       |> assign(:palette_selected_index, 0)}
    end
  end

  # --- Remote Node Events ---

  # Re-initiates a connection to the currently selected (failed/disconnected)
  # remote target. The connection manager runs asynchronously; the status
  # broadcast triggers handle_connection_status → push_patch once connected.
  @impl true
  def handle_event("retry_remote_connection", _params, socket) do
    if node_id = socket.assigns[:current_node_id] do
      EvoDash.NodeContext.connect(node_id)
    end

    {:noreply, socket}
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
    selected_agent_id = socket.assigns[:selected_agent_id]

    agent_id =
      if mode == "custom_agent" and
           not (is_binary(selected_agent_id) and String.trim(selected_agent_id) != "") do
        case socket.assigns[:custom_agents] do
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
  def handle_event("select_model", %{"model_id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_model_id, id)
     |> StatePersistence.maybe_persist_state()}
  end

  @impl true
  def handle_event("select_agent", %{"agent" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_agent_id, id)
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

  # Flash acknowledgement for the ClipboardCopy hook (example task copy button)
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
    # Per-node sessionStorage gate: the StatePersistence JS hook merges
    # `node` (from #dashboard-root's data-node-id) into the persisted state.
    # If the saved state belongs to a different node context (or an older
    # session without the node key), skip restoring ALL persisted values so
    # no task/project state leaks across nodes.
    # Per-node storage gate: state persisted under one node context must never
    # be restored in another. The StatePersistence JS hook always sends the
    # `node` key (defaulting to "local"); a missing key is treated as "local"
    # for backward compatibility with legacy callers.
    if (params["node"] || "local") != (socket.assigns[:current_node_id] || "local") do
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
        |> StatePersistence.maybe_restore_show_advanced(params["show_advanced"])
        |> StatePersistence.maybe_restore_assign(:selected_model_id, params["selected_model_id"])
        |> StatePersistence.maybe_restore_assign(:selected_agent_id, params["selected_agent_id"])

      # Always restore task_mode from sessionStorage — the user's explicit choice
      # takes precedence over auto-detection when returning to a project.
      # Normalizes a legacy persisted "reflect" value to "evolve_simple" (the
      # reflect mode was removed from the task form).
      socket = StatePersistence.maybe_restore_task_mode(socket, params["task_mode"])

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
  end

  @impl true
  def handle_event("task_submit", %{"prompt" => prompt, "mode" => combined_mode} = params, socket) do
    path = socket.assigns[:active_project_path]
    selected_agent_id = socket.assigns[:selected_agent_id]

    cond do
      # All task modes now require an active project (reflect mode was
      # removed) — keep the existing "No project selected" guard.
      is_nil(path) ->
        {:noreply,
         put_flash(socket, :error, gettext("No project selected. Please open a project first."))}

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

  @impl true
  def handle_event("cancel_task", %{"task_id" => task_id}, socket) do
    case TaskRegistry.cancel_task(task_id) do
      :ok ->
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
           gettext("Failed to cancel task: %{reason}", reason: inspect(reason))
         )}
    end
  end

  @impl true
  def handle_event("clear_task_history", _params, socket) do
    notified = Assigns.build_notified_task_ids(socket.assigns.notified_task_ids)
    TaskRegistry.clear_finished_tasks()

    {:noreply,
     socket
     |> EvoDashWeb.LiveHooks.NodeAware.assign_active_tasks()
     |> assign(:notified_task_ids, notified)}
  end

  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    TaskRegistry.delete_task(task_id)

    {:noreply,
     socket
     |> EvoDashWeb.LiveHooks.NodeAware.assign_active_tasks()
     |> assign(
       :notified_task_ids,
       MapSet.put(socket.assigns.notified_task_ids, task_id)
     )}
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
        case validate_foreign_repo_input(socket, path, base_sha) do
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
              # expansion and are stored verbatim (build_foreign_repo_for_node/4).
              remote_context? =
                socket.assigns[:remote?] or socket.assigns[:current_node] != node()

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

              repo = build_foreign_repo_for_node(node, repo_id, path, opts)

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
      case validate_foreign_repo_input(socket, path, base_sha) do
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
          # expansion and are stored verbatim (build_foreign_repo_for_node/4).
          remote_context? =
            socket.assigns[:remote?] or socket.assigns[:current_node] != node()

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

          repo = build_foreign_repo_for_node(node, repo_id, path, opts)

          updated_repos =
            current_repos
            |> Enum.map(fn r -> if r.id == repo_id, do: repo, else: r end)
            |> Enum.sort_by(fn r ->
              {if(ForeignRepo.primary?(r.id), do: 0, else: 1), r.id}
            end)

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
        socket.assigns.recent_projects
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
        socket.assigns.recent_projects
      )

    {:noreply, assign(socket, :path_suggestions, suggestions)}
  end

  @impl true
  def handle_event("foreign_repo_path_input", %{"path" => value}, socket) do
    # Foreign-repo paths are always LOCAL filesystem paths (project settings
    # are a local dashboard concern), so suggestions resolve against the local
    # node.
    suggestions = Project.path_suggestions(node(), value, socket.assigns.recent_projects)
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
  def handle_event("file_pick", %{"picker_id" => picker_id, "prompt" => prompt}, socket) do
    # Attach-file flow for the objective editor: same server-side picker as
    # "directory_pick" but in :file mode (the parallel DirectoryPicker work
    # adds pick/3 with a kind argument). The current DOM textarea value is
    # passed along and snapshotted as the base so the picked file's text can
    # be appended even if the user keeps typing while the dialog is open.
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
            bases = Map.put(socket.assigns.file_pick_bases || %{}, picker_id, prompt || "")
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
    # path here. Runs the SAME attachment pipeline as the native picker result
    # (AttachFile.handle_attach_result/2); the submitted textarea value is
    # snapshotted into file_pick_bases, exactly like "file_pick" does for the
    # native flow, so base-prompt semantics are identical.
    picker_id = Map.get(params, "picker_id", @attach_picker_id)
    path = Map.get(params, "path")
    prompt = Map.get(params, "prompt")
    prompt = if is_binary(prompt), do: prompt, else: ""

    cond do
      not is_binary(path) or path == "" ->
        # zh_CN: 手动输入为空 → "请输入文件路径。"
        reason = gettext("Please enter a file path.")
        {:noreply, push_manual_attach_error(socket, picker_id, reason)}

      not File.regular?(path) ->
        # zh_CN: 输入的路径不是可读文件 → "文件不存在：%{path}"
        reason = gettext("File not found: %{path}", path: path)
        {:noreply, push_manual_attach_error(socket, picker_id, reason)}

      true ->
        bases = Map.put(socket.assigns.file_pick_bases || %{}, picker_id, prompt)

        socket =
          socket
          |> assign(:file_pick_bases, bases)
          |> AttachFile.handle_attach_result(path)

        {:noreply, socket}
    end
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

  # Validation failure in the manual attach flow: error flash (native flow
  # parity) + `%{error: true, reason: ...}` push — the FilePicker hook shows
  # the reason inline next to the path input and keeps it open.
  defp push_manual_attach_error(socket, picker_id, reason) do
    socket
    |> put_flash(:error, reason)
    |> push_event("picker_result:#{picker_id}", %{error: true, reason: reason})
  end

  defp truncate_output(output) when byte_size(output) > 2000 do
    String.slice(output, 0, 2000) <> "..."
  end

  defp truncate_output(output), do: String.trim(output)

  # --- PubSub Handlers ---

  # Results from the async directory picker (EvoDash.DirectoryPicker sends
  # these to the LiveView pid passed to pick/2).
  #
  # Attach-file flow: read the picked file with EvoDash.AttachedFile and append
  # its content to the objective. The textarea is phx-update="ignore" (the
  # DOM is authoritative), so the new value must reach the client via
  # push_event — the FilePicker JS hook writes it into the textarea. Shared
  # pipeline with the manual path fallback (file_pick_manual) lives in
  # EvoDashWeb.ProjectsLive.AttachFile.
  @impl true
  def handle_info({:directory_picker_result, @attach_picker_id, {:ok, path}}, socket) do
    {:noreply, AttachFile.handle_attach_result(socket, path)}
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
  # pushes browser notifications for newly finished tasks. Notification
  # detection uses the minimal id+status projection — only newly-terminal rows
  # are fetched in full (get_task per new id), bounding decode cost instead of
  # scanning the entire terminal history on every broadcast.
  #
  # Node-aware: the sidebar reload goes through
  # NodeAware.load_running_and_pending_tasks/1 (remote tasks via RPC, empty
  # lists in pending/error remote contexts), and browser notifications are
  # LOCAL-context only — a remote/pending context must never fire local
  # notifications.
  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
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

    socket =
      if socket.assigns[:current_node_id] == nil do
        # Detect newly finished tasks for browser notifications (local context
        # only — remote nodes have no local TaskRegistry to scan)
        terminal_ids = TaskRegistry.list_task_ids([:completed, :failed, :cancelled])
        previously_notified = socket.assigns.notified_task_ids

        {new_ids, updated_notified} =
          Enum.reduce(terminal_ids, {[], previously_notified}, fn %{id: id}, {acc, notified} ->
            if MapSet.member?(notified, id) do
              {acc, notified}
            else
              {[id | acc], MapSet.put(notified, id)}
            end
          end)

        socket =
          Enum.reduce(new_ids, socket, fn id, sock ->
            case TaskRegistry.get_task(id) do
              %EvoGit.TaskInfo{} = task ->
                {title, body} = Project.task_notification_content(task)
                push_event(sock, "task_notification", %{title: title, body: body})

              _ ->
                # task vanished between queries — still marked notified, no crash
                sock
            end
          end)

        assign(socket, :notified_task_ids, updated_notified)
      else
        socket
      end

    socket = EvoDashWeb.LiveHooks.NodeAware.load_running_and_pending_tasks(socket)

    {:noreply, EvoDashWeb.LiveHooks.NodeAware.clear_task_reload_pending(socket)}
  end

  @impl true
  def handle_info({:recent_projects_updated}, socket) do
    recent_projects =
      cond do
        socket.assigns.remote? ->
          # Connected remote node — reload the remote node's recents via RPC
          filter_absolute_recent_projects_for_node(
            socket.assigns.current_node,
            EvoDash.NodeContext.list_recent_projects(socket.assigns.current_node)
          )

        socket.assigns[:current_node_id] != nil ->
          # Pending/error remote context — never show local recents
          []

        true ->
          filter_absolute_recent_projects(TaskRegistry.list_recent_projects())
      end

    {:noreply, assign(socket, :recent_projects, recent_projects)}
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
  # handle_params/3 (custom agents, model profiles + the selected_model_id
  # switch validation, remote agents / remote project config, recent
  # projects). The handler drops stale results (wrong node or active project)
  # in AsyncLoad.handle_result/5, then re-runs GitHub.maybe_check/1: the
  # remote task_mode now arrives via this continuation (it used to be
  # assigned synchronously before the maybe_check call at the end of
  # handle_params), so the remote upstream-detection needs this second kick —
  # maybe_check is self-guarding (no-ops once a status is present), so the
  # extra call is harmless on every other path.
  @impl true
  def handle_info({:async_project_load, node, prev_node_id, path, results}, socket) do
    socket = AsyncLoad.handle_result(socket, node, prev_node_id, path, results)
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
  # changed (same semantics as the old sync activate_remote_palette_project —
  # `project_changed?` is computed from the PRE-apply socket), and the URL is
  # patched so handle_params re-runs in the same remote context. On
  # `{:error, :not_a_directory}` the loading flag clears and the error flash
  # fires (the one RPC-derived error of the sequence — it must run in this
  # continuation, not in the event handler).
  @impl true
  def handle_info({:async_remote_project, node, path, result}, socket) do
    cond do
      node != socket.assigns[:current_node] ->
        {:noreply, socket}

      path != socket.assigns[:remote_project_loading] ->
        {:noreply, socket}

      true ->
        case result do
          {:ok, results} ->
            project_changed? = socket.assigns[:active_project_path] != path

            socket =
              socket
              |> assign(:remote_project_loading, nil)
              |> assign(:recent_projects, results.recent_projects)
              |> assign(:active_project, results.active_project)
              |> assign(:active_project_path, results.active_project_path)
              |> assign(:task_mode, results.task_mode)
              |> assign(:task_mode_info, results.task_mode_info)
              |> assign(:project_config, results.project_config)
              |> assign(:worktree_script, results.worktree_script)
              |> assign(:commands, results.commands)
              |> assign(:foreign_repos, results.foreign_repos)
              |> assign(:show_add_foreign_repo_form, false)
              |> maybe_reset_github_state(project_changed?)
              |> GitHub.maybe_check()

            {:noreply, push_patch(socket, to: project_url(socket, path))}

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

                  # Read-write foreign repos: thread `writable` and `base_sha`
                  # through the guarded constructor (which for non-UNC inputs
                  # is `ForeignRepo.new/3` — it coerces/validates them: only
                  # literal true is writable, blank base_sha → nil). The UNC
                  # guard keeps `//wsl.localhost/...` / `\\server\share\...`
                  # roots verbatim on non-Windows nodes — `ForeignRepo.new/3`'s
                  # `Path.expand` would collapse/cwd-join them (see
                  # `foreign_repo_new_guarded/3`).
                  # Tolerant writable check for string-keyed persisted shapes.
                  writable =
                    Map.get(repo, "writable", Map.get(repo, :writable, false))

                  base_sha = Map.get(repo, "base_sha") || Map.get(repo, :base_sha)

                  opts =
                    if(is_binary(desc) and desc != "",
                      do: [description: desc],
                      else: []
                    )
                    |> Keyword.put(:writable, writable == true or writable == "true")
                    |> then(fn o ->
                      if is_binary(base_sha) and base_sha != "",
                        do: Keyword.put(o, :base_sha, base_sha),
                        else: o
                    end)

                  foreign_repo_new_guarded(id, root, opts)

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

  # ───────────────────────────────────────────────────────────────────────────
  # Command Palette keyboard navigation helpers
  # ───────────────────────────────────────────────────────────────────────────

  # In :open_path and :new_project modes, Escape is handled by the client-side
  # phx-key binding on the input (which sends palette_keydown with key="Escape").
  # Non-menu modes are no-ops here (the input's own Escape binding closes it
  # via the palette_keydown → Escape clause below which matches any mode).
  defp handle_palette_key(socket, "Escape", _mode) do
    socket
    |> assign(:project_palette_open, false)
    |> assign(:palette_mode, :menu)
    |> assign(:palette_search, "")
    |> assign(:palette_selected_index, 0)
  end

  defp handle_palette_key(socket, "ArrowDown", :menu) do
    max_index = palette_item_count(socket) - 1
    new_index = min(socket.assigns.palette_selected_index + 1, max_index)
    assign(socket, :palette_selected_index, max(new_index, 0))
  end

  defp handle_palette_key(socket, "ArrowUp", :menu) do
    new_index = socket.assigns.palette_selected_index - 1
    assign(socket, :palette_selected_index, max(new_index, 0))
  end

  defp handle_palette_key(socket, "Enter", :menu) do
    filtered =
      EvoDashWeb.ProjectComponents.filter_projects(
        socket.assigns.recent_projects,
        socket.assigns.palette_search
      )

    action_base = length(filtered)
    index = socket.assigns.palette_selected_index

    cond do
      index < action_base and index < length(filtered) ->
        # Activate the selected recent project via push_patch (node-aware:
        # remote contexts validate/register on the remote node and carry the
        # `&node=` param so the node context survives the patch)
        project = Enum.at(filtered, index)

        # Never `Path.expand` against the VM cwd: recents are absolute-path
        # filtered at assignment, but a stale/relative entry would cwd-join
        # on Windows (Tauri install dir). A relative selection just doesn't
        # open — same UX as a failed open, without the cwd join.
        case ProjectFlow.normalize_project_path(project.path) do
          {:ok, expanded} ->
            if socket.assigns[:current_node_id] != nil do
              activate_remote_palette_project(socket, expanded)
            else
              if File.dir?(expanded) do
                TaskRegistry.add_recent_project(expanded, Path.basename(expanded))

                recent_projects =
                  filter_absolute_recent_projects(TaskRegistry.list_recent_projects())

                socket
                |> assign(:recent_projects, recent_projects)
                |> assign(:project_palette_open, false)
                |> assign(:palette_mode, :menu)
                |> push_patch(to: "/projects?project=#{URI.encode(expanded)}")
              else
                socket
                |> assign(:project_palette_open, false)
                |> put_flash(
                  :error,
                  gettext("Directory does not exist: %{path}", path: project.path)
                )
              end
            end

          {:error, _reason} ->
            socket
            |> assign(:project_palette_open, false)
            |> put_flash(:error, gettext("Directory does not exist: %{path}", path: project.path))
        end

      index == action_base ->
        socket
        |> assign(:palette_mode, :open_path)
        |> assign(
          :path_suggestions,
          Project.path_suggestions(
            socket.assigns.current_node,
            "",
            socket.assigns.recent_projects
          )
        )

      index == action_base + 1 ->
        # Unreachable when remote (palette_item_count clamps to action_base)
        assign(socket, :palette_mode, :new_project)

      true ->
        socket
    end
  end

  defp handle_palette_key(socket, _key, _mode), do: socket

  # Remote palette selection — ASYNC. The synchronous part is only the gate
  # guard; the RPC-heavy sequence (remote dir? validation, recent-project
  # registration + reload, config/mode/foreign-repo loading) runs OUTSIDE the
  # LiveView process via ProjectFlow.spawn_remote_project_activation/2 so the
  # UI never blocks on the 6-7 cross-node round-trips per palette Enter. The
  # palette closes immediately at spawn; the result arrives as a
  # `{:async_remote_project, node, path, result}` message handled by
  # handle_info/2, which stale-guards it, applies the assigns, resets the
  # GitHub state when the project changed, and push_patches the `&node=` URL
  # so handle_params re-runs in the same remote context.
  defp activate_remote_palette_project(socket, expanded) do
    # Gate guard (defense in depth): while the selected remote target is
    # pending/failed, `@current_node` is still the LOCAL BEAM node — validating
    # or registering the path here would leak into the local filesystem and
    # local TaskRegistry recents. Close the palette and surface an error.
    if EvoDashWeb.RemoteGateComponents.gate_active?(socket.assigns) do
      socket
      |> assign(:project_palette_open, false)
      |> assign(:palette_mode, :menu)
      |> put_flash(
        :error,
        gettext(
          "Cannot open project: remote node %{name} is not connected. Retry the connection first.",
          name: socket.assigns[:current_node_name] || "remote"
        )
      )
    else
      ProjectFlow.spawn_remote_project_activation(socket, expanded)
    end
  end

  # Counts the total number of items in the palette menu list:
  # filtered recent projects + 2 actions (Open by Path, Create New) locally;
  # the "Create New Project" action is hidden in remote contexts, so the count
  # is filtered + 1 there (keeps ArrowDown clamping in sync with the DOM).
  defp palette_item_count(socket) do
    filtered =
      EvoDashWeb.ProjectComponents.filter_projects(
        socket.assigns.recent_projects,
        socket.assigns.palette_search
      )

    length(filtered) + if socket.assigns[:current_node_id] != nil, do: 1, else: 2
  end

  # Filters recent-project entries to absolute paths only. Stale cwd-joined
  # entries (produced by the pre-fix Windows relative-input bug, which
  # `Path.expand`ed bare folder names against the Tauri install dir) must
  # never render in the palette, feed auto-load, or reach path suggestions.
  # Applied at every `:recent_projects` assignment site in this module.
  # Implementation lives in EvoDashWeb.ProjectsLive.AsyncLoad (shared with
  # the async handle_params load).
  defp filter_absolute_recent_projects(recent_projects) do
    AsyncLoad.filter_absolute_recent_projects(recent_projects)
  end

  # Node-aware variant of the filter above, used ONLY at the remote recents
  # sites (handle_params remote branch, the :recent_projects_updated handler,
  # and activate_remote_palette_project). Delegates to the single shared
  # predicate `ProjectFlow.absolute_path_for_node?/2`: local nodes keep the
  # strict `Platform.absolute_path?/1` semantics; remote nodes accept POSIX-
  # or Windows-absolute paths so remote recents survive a dashboard running
  # on a different OS (e.g. `/home/user/repo` on a Windows dashboard).
  defp filter_absolute_recent_projects_for_node(node, recent_projects) do
    AsyncLoad.filter_absolute_recent_projects_for_node(node, recent_projects)
  end

  # The add-foreign-repo form is reachable in remote mode (RemoteView renders
  # it via `show_add_foreign_repo`), so its path must be validated for the
  # node being viewed: a POSIX path on a remote Linux daemon is wrongly
  # rejected by the local-only `Platform.absolute_path?/1` on a Windows
  # dashboard (`Path.type/1` → `:volumerelative`), and vice versa. In a
  # remote context the shared node-aware predicate is used; local contexts
  # keep the local semantics. Both branches ACCEPT Windows UNC / WSL roots —
  # `//wsl.localhost/Ubuntu-22.04/...`, `\\server\share\...` and drive
  # letters — via `EvoGit.Platform.absolute_path?/1` (UNC `//`-forms match
  # `Path.type/1` → `:absolute`; `\\`-forms match its Windows-absolute
  # regex). STORAGE follows the same node split (see the `add_foreign_repo`
  # handler): remote contexts build RAW structs via
  # `ProjectFlow.build_foreign_repo/4` — the root is stored verbatim with NO
  # local `Path.expand` (`ForeignRepo.new/3` would mangle remote
  # POSIX/Windows paths against the dashboard's OS); local contexts keep
  # `ForeignRepo.new/3`'s `Path.expand` semantics unchanged — EXCEPT UNC/WSL
  # roots on a non-Windows node, which bypass the expansion and are stored
  # verbatim (see `build_foreign_repo_for_node/4` below).
  defp foreign_repo_path_absolute?(socket, path) do
    if socket.assigns[:remote?] or socket.assigns[:current_node] != node() do
      ProjectFlow.absolute_path_for_node?(socket.assigns[:current_node], path)
    else
      Platform.absolute_path?(path)
    end
  end

  # ── UNC/WSL foreign-repo storage guard ─────────────────────────────────
  # `EvoGit.Core.ForeignRepo.new/3` `Path.expand`s its root internally. On a
  # WINDOWS node that is safe for UNC roots — Elixir's `Path.expand` preserves
  # a `//`-prefixed UNC root and normalizes the `\\server\share` form to
  # `//server/share`. On a NON-Windows node it corrupts them:
  # `Path.expand("//wsl.localhost/x")` collapses the prefix to
  # `/wsl.localhost/x`, and `Path.expand("\\server\share\x")` is cwd-joined
  # against the dashboard's working directory. UNC/WSL roots must therefore
  # NEVER pass through `ForeignRepo.new/3` on a non-Windows node — they are
  # stored verbatim (forward-slash-normalized, trailing separators trimmed)
  # with the same returned struct shape.
  defp unc_prefixed?(path) when is_binary(path) do
    String.starts_with?(path, "//") or String.starts_with?(path, "\\\\")
  end

  defp normalize_unc_root(path) do
    normalized =
      path
      |> EvoGit.Platform.normalize_separators()
      |> EvoGit.Platform.trim_trailing_separators()

    if normalized == "", do: "//", else: normalized
  end

  # `ForeignRepo.new/3` with the UNC-expansion guard: UNC/WSL roots on a
  # non-Windows node bypass the internal `Path.expand/1` (which would mangle
  # the `//`/`\\` prefix against the local OS) and build the same struct shape
  # with the verbatim root; every other input keeps `ForeignRepo.new/3`'s
  # exact expansion and `writable`/`base_sha` coercion semantics.
  defp foreign_repo_new_guarded(id, root, opts) do
    if unc_prefixed?(root) and not Platform.windows?() do
      %ForeignRepo{
        id: id,
        root: normalize_unc_root(root),
        description: Keyword.get(opts, :description),
        writable: Keyword.get(opts, :writable, false),
        base_sha: Keyword.get(opts, :base_sha)
      }
    else
      ForeignRepo.new(id, root, opts)
    end
  end

  # Node-aware `%ForeignRepo{}` construction with the UNC guard: local nodes
  # go through `foreign_repo_new_guarded/3` (== `ForeignRepo.new/3` except UNC
  # roots are never `Path.expand`ed against the local OS); remote nodes keep
  # `ProjectFlow.build_foreign_repo/4`'s verbatim raw-struct behavior.
  defp build_foreign_repo_for_node(node, repo_id, path, opts) do
    if node == nil or node == node() do
      foreign_repo_new_guarded(repo_id, path, opts)
    else
      ProjectFlow.build_foreign_repo(node, repo_id, path, opts)
    end
  end

  # Validates a foreign-repo path + optional base_sha for the node being
  # viewed. Returns `:ok` or `{:error, flash_message}`. Shared by the
  # `add_foreign_repo` and `save_foreign_repo` handlers so both entry points
  # enforce IDENTICAL rules (real checks, never crashes — cond/case only, no
  # try/rescue):
  #
  #   - path non-blank + absolute (the existing checks)
  #   - existence: local → `File.dir?/1`; remote → `NodeContext.dir?/2`
  #   - git-ness:  local → core `EvoGit.Adapters.Git.rev_parse/1` (NEVER shell
  #     out); remote → `NodeContext.list_branches/2`
  #   - base_sha resolvability (when non-nil): local → `rev_parse(path, sha)`;
  #     REMOTE base_sha check deliberately SKIPPED — NodeContext exposes no
  #     ref-resolution wrapper (verified), and the core's up-front
  #     task-start validation (`Runtime.Helpers.load_foreign_repos/2`) still
  #     raises ArgumentError for a bad remote base_sha, failing the task
  #     before any agent spawns (see projects_live/CONTEXT.md).
  defp validate_foreign_repo_input(socket, path, base_sha) do
    remote_context? =
      socket.assigns[:remote?] or socket.assigns[:current_node] != node()

    node = if remote_context?, do: socket.assigns[:current_node], else: node()

    cond do
      path == "" ->
        {:error, gettext("Path cannot be empty.")}

      not foreign_repo_path_absolute?(socket, path) ->
        {:error, gettext("Path must be absolute.")}

      not foreign_repo_path_exists?(node, remote_context?, path) ->
        {:error, gettext("Foreign repo path does not exist: %{path}", path: path)}

      not foreign_repo_is_git_repo?(node, remote_context?, path) ->
        {:error, gettext("Path is not a git repository: %{path}", path: path)}

      is_binary(base_sha) and base_sha != "" and remote_context? ->
        # Remote base_sha check skipped by design (see function doc). The
        # core's task-start ArgumentError still catches bad values.
        :ok

      is_binary(base_sha) and base_sha != "" ->
        case EvoGit.Adapters.Git.rev_parse(path, base_sha) do
          {:ok, _} ->
            :ok

          _ ->
            {:error,
             gettext("Base commit %{base_sha} not found in repository: %{path}",
               base_sha: base_sha,
               path: path
             )}
        end

      true ->
        :ok
    end
  end

  defp foreign_repo_path_exists?(node, true, path), do: NodeContext.dir?(node, path)
  defp foreign_repo_path_exists?(_node, false, path), do: File.dir?(path)

  defp foreign_repo_is_git_repo?(node, true, path) do
    case NodeContext.list_branches(node, path) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp foreign_repo_is_git_repo?(_node, false, path) do
    match?({:ok, _}, EvoGit.Adapters.Git.rev_parse(path))
  end

  # Builds the dashboard URL for a project path. In a remote context the
  # `&node=` param is appended so the node context survives the push_patch —
  # NOTE: deliberately NOT `EvoDashWeb.Helpers.with_node_param/2`, which
  # appends with `?` and would corrupt the existing `?project=` query.
  defp project_url(socket, path) do
    case socket.assigns[:current_node_id] do
      nil -> "/projects?project=#{URI.encode(path)}"
      node_id -> "/projects?project=#{URI.encode(path)}&node=#{node_id}"
    end
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

    # Load project settings eagerly — read genesis.toml once and thread
    # through all consumers to avoid redundant disk reads.
    config = ProjectConfig.read(path)
    {project_config, worktree_script, commands} = Project.load_project_config(path, config)
    foreign_repos = Project.load_foreign_repos(path, config)

    socket
    |> assign(
      active_project: %{path: path, name: name},
      active_project_path: path,
      # Re-arm the no-project hint so it returns for a future no-project
      # session (dismissal is per no-project session, not permanent).
      no_project_hint_dismissed: false,
      notified_task_ids: Assigns.build_notified_task_ids(socket.assigns.notified_task_ids),
      task_mode: mode,
      task_mode_info: mode_info,
      project_palette_open: false,
      palette_mode: :menu,
      palette_search: "",
      palette_selected_index: 0,
      show_project_settings: false,
      project_config: project_config,
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

  # do_task_submit/4 — builds the start_task opts and launches the task.
  # Called by handle_event("task_submit") AFTER its guards (project open +
  # custom mode has a selected agent). Lives down here with the other
  # private helpers so the handle_event/3 clauses stay grouped.
  defp do_task_submit(prompt, combined_mode, params, socket) do
    path = socket.assigns[:active_project_path]

    {task_type, mode} =
      case combined_mode do
        "genesis_new" -> {:genesis, "new"}
        "genesis_existing" -> {:genesis, "existing"}
        "evolve_simple" -> {:evolve, "simple"}
        # Custom Agent mode is evolve-family: an :evolve task with the
        # selected custom agent as the root agent (the core contract's mode
        # string is "custom" — distinct from the UI's combined-mode string).
        "custom_agent" -> {:evolve, "custom"}
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
    # An explicit user choice ALSO sets :model_id_locked => true (the
    # runtime's model-selection script is deferred for this task); when
    # "Auto (by rules)" is chosen (selected_model_id is nil/"") neither key
    # is set and the script (or the default model) decides. The lock is set
    # unconditionally on an explicit choice per the cross-app contract —
    # it is a no-op when no script is configured.
    selected_model_id = socket.assigns[:selected_model_id]

    opts =
      if is_binary(selected_model_id) and selected_model_id != "" do
        opts
        |> Keyword.put(:model_id, selected_model_id)
        |> Keyword.put(:model_id_locked, true)
      else
        opts
      end

    # Thread the selected custom agent id into opts ("Auto (recommended)" /
    # nil/"" threads nothing — the runtime spawns its default root agent).
    # Custom Agent mode is validated in handle_event/3 before this point, so
    # a non-empty agent is guaranteed whenever mode == "custom".
    selected_agent_id = socket.assigns[:selected_agent_id]

    opts =
      if is_binary(selected_agent_id) and selected_agent_id != "" do
        Keyword.put(opts, :agent, selected_agent_id)
      else
        opts
      end

    resume_from = params["resume_from"]

    opts =
      if task_type == :evolve and is_binary(resume_from) and String.trim(resume_from) != "" do
        Keyword.put(opts, :resume_from, String.trim(resume_from))
      else
        opts
      end

    start_result =
      if socket.assigns.remote? do
        NodeContext.start_task(socket.assigns.current_node, task_type, opts)
      else
        TaskRegistry.start_task(task_type, opts)
      end

    case start_result do
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
         |> EvoDashWeb.LiveHooks.NodeAware.assign_active_tasks()
         # The prompt is intentionally cleared after a successful launch.
         # assign_form_defaults/1 resets @task_prompt to "" (so the server
         # re-seeds data-layout="compact"), and the "clear_prompt" push_event
         # empties the visible textarea — which morphdom skips under
         # phx-update="ignore" — and removes the persisted draft, so neither
         # the DOM nor a reload can resurrect the submitted prompt.
         |> Assigns.assign_form_defaults()
         |> StatePersistence.maybe_persist_state()
         |> push_event("clear_prompt", %{})}

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
