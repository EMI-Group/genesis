defmodule EvoDashWeb.DashboardLive do
  @moduledoc """
  Project-based task dashboard for launching and monitoring EvoGit tasks.

  Users open a repository, and the dashboard auto-detects the task mode
  (genesis or evolve). Displays active tasks with live logs and inline
  project settings including foreign repositories.
  """
  use EvoDashWeb, :live_view
  alias EvoGit.TaskRegistry
  alias EvoDashWeb.DashboardLive.{StatePersistence, Project, Assigns, ProjectFlow, RemoteView}
  alias EvoDashWeb.ThemeColor
  alias EvoDashWeb.ExampleTask
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Platform
  alias EvoGit.ProjectConfig

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
      >
        <%!--
          --project-accent carries the TASK-MODE accent: genesis_new → red,
          genesis_existing → blue, evolve_simple → green (lighter green when a
          resume task id is set — evolve only). It drives the objective box
          (.input-card). --project-ring-accent carries the PROJECT-NAME-HASH
          accent (ThemeColor.accent_color/1) — stable per project name — and
          drives the top-bar project ring (.project-palette-trigger:hover).
          The --project-accent var name is historical; renaming it would
          require touching assets/css/app.css (out of scope).
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
                         event, which drives the AdaptiveInput autogrow AND the
                         task_prompt_change phx-change (debounced) — syncing
                         @task_prompt and switching the layout to expanded. --%>
                    <div class="mx-auto w-full max-w-3xl px-4 pb-4 shrink-0">
                      <details
                        class="group rounded-lg border border-base-300 bg-base-100/60 shadow-sm"
                        open
                      >
                        <summary class="flex items-center gap-2 px-4 py-3 text-sm font-medium text-base-content/80 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
                          <.icon name="hero-sparkles" class="size-4 shrink-0 text-primary/70" />
                          <span>{gettext("New to Genesis? Start with an example")}</span>
                          <span class="ml-auto text-xs font-normal text-base-content/40">
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
                <!-- Connected remote node: remote top bar (target badge,
                     Configure dropdown hidden) + the remote node's active
                     agents. The local task list and project management are
                     LOCAL concerns — the remote daemon runs evo_git only, no
                     evo_dash (no TaskRegistry/Store). -->
                <RemoteView.top_bar
                  remote={true}
                  current_node_name={@current_node_name}
                  active_project={@active_project}
                  active_project_path={@active_project_path}
                  recent_projects={@recent_projects}
                  palette_open={@project_palette_open}
                  palette_search={@palette_search}
                  palette_mode={@palette_mode}
                  palette_selected_index={@palette_selected_index}
                  path_suggestions={@path_suggestions}
                  tauri_detected={@tauri_detected}
                  platform={@platform}
                />

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
                  recent_projects={@recent_projects}
                  palette_open={@project_palette_open}
                  palette_search={@palette_search}
                  palette_mode={@palette_mode}
                  palette_selected_index={@palette_selected_index}
                  path_suggestions={@path_suggestions}
                  tauri_detected={@tauri_detected}
                  platform={@platform}
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
                  recent_projects={@recent_projects}
                  palette_open={@project_palette_open}
                  palette_search={@palette_search}
                  palette_mode={@palette_mode}
                  palette_selected_index={@palette_selected_index}
                  path_suggestions={@path_suggestions}
                  tauri_detected={@tauri_detected}
                  platform={@platform}
                />
                <RemoteView.error_state
                  current_node_name={@current_node_name}
                  last_error={Map.get(@remote_status || %{}, :last_error)}
                />
            <% end %>
            <%!-- end of node-context cond --%>
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
          show_configure_dropdown: false,
          model_profiles: model_profiles,
          selected_model_id: selected_model_id,
          build_systems: build_systems,
          tauri_detected: false,
          platform: "linux",
          notified_task_ids: Assigns.build_notified_task_ids(MapSet.new())
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
    prev_node_id = socket.assigns[:current_node_id]

    # NOTE: `remote?` must be derived from the socket AFTER `assign_node/2`
    # re-assigns `current_node` — computing it inside the pipe from the outer
    # `socket` variable would read the PRE-assign_node value, so a page load at
    # a connected `?node=` URL would render the error gate on the first pass.
    socket = EvoDashWeb.LiveHooks.NodeAware.assign_node(socket, params)
    socket = assign(socket, :current_path, ~p"/")
    socket = assign(socket, :remote?, socket.assigns.current_node != node())

    # Each node context (local + each remote target) has its own persisted
    # dashboard state; switching nodes clears the client-side state and
    # re-persists it under the new node key so no state leaks across nodes.
    socket =
      StatePersistence.maybe_clear_state_on_node_switch(
        socket,
        prev_node_id,
        socket.assigns[:current_node_id]
      )

    # When viewing a connected remote node, the dashboard shows the remote
    # node's active agents instead of local tasks/projects. Load them here so
    # the render branch has the data (connected contexts only — pending/error
    # contexts render connecting/error states without agent data).
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
    # When connected to a remote node, load via RPC; in a pending/error remote
    # context no recents are shown (local recents must never leak into a
    # remote view); when local, load from the local TaskRegistry.
    socket =
      cond do
        socket.assigns.remote? ->
          assign(
            socket,
            :recent_projects,
            EvoDash.NodeContext.list_recent_projects(socket.assigns.current_node)
          )

        socket.assigns[:current_node_id] != nil ->
          assign(socket, :recent_projects, [])

        true ->
          assign(socket, :recent_projects, TaskRegistry.list_recent_projects())
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
        if project_path && project_path != "" do
          expanded = Path.expand(project_path)

          if File.dir?(expanded) do
            activate_project(socket, expanded)
          else
            # Project path in URL is invalid, clear it
            socket
            |> Assigns.assign_running_and_pending_tasks()
            |> assign(
              :notified_task_ids,
              Assigns.build_notified_task_ids(socket.assigns.notified_task_ids)
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
                    socket
                    |> Assigns.assign_running_and_pending_tasks()
                    |> assign(
                      :notified_task_ids,
                      Assigns.build_notified_task_ids(socket.assigns.notified_task_ids)
                    )
                  end

                _ ->
                  socket
                  |> Assigns.assign_running_and_pending_tasks()
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
  def handle_event("task_prompt_change", %{"prompt" => prompt}, socket) do
    {:noreply,
     socket
     |> assign(:task_prompt, prompt)
     |> StatePersistence.maybe_persist_state()}
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
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("%{type} task started with ID: %{id}",
               type: String.capitalize(to_string(task_type)),
               id: task.id
             )
           )
           |> Assigns.assign_running_and_pending_tasks()
           # The textarea keeps its text (`phx-update="ignore"`), so @task_prompt
           # must mirror the visible content or the server-side layout computation
           # (from prompt length) desyncs. Side effect: the draft prompt now
           # survives reloads via localStorage — intentional improvement.
           |> Assigns.assign_form_defaults()
           |> assign(:task_prompt, prompt)
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
        {:noreply,
         socket
         |> Assigns.assign_running_and_pending_tasks()
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
     |> Assigns.assign_running_and_pending_tasks()
     |> assign(:notified_task_ids, notified)}
  end

  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    TaskRegistry.delete_task(task_id)

    {:noreply,
     socket
     |> Assigns.assign_running_and_pending_tasks()
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
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.debounce_task_reload(socket)}
  end

  @impl true
  def handle_info({:task_status, _task_id, _status}, socket) do
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.debounce_task_reload(socket)}
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
          EvoDash.NodeContext.list_recent_projects(socket.assigns.current_node)

        socket.assigns[:current_node_id] != nil ->
          # Pending/error remote context — never show local recents
          []

        true ->
          TaskRegistry.list_recent_projects()
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
        expanded = Path.expand(project.path)

        if socket.assigns[:current_node_id] != nil do
          activate_remote_palette_project(socket, project, expanded)
        else
          if File.dir?(expanded) do
            TaskRegistry.add_recent_project(expanded, Path.basename(expanded))
            recent_projects = TaskRegistry.list_recent_projects()

            socket
            |> assign(:recent_projects, recent_projects)
            |> assign(:project_palette_open, false)
            |> assign(:palette_mode, :menu)
            |> push_patch(to: "/?project=#{URI.encode(expanded)}")
          else
            socket
            |> assign(:project_palette_open, false)
            |> put_flash(:error, gettext("Directory does not exist: %{path}", path: project.path))
          end
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

  # Remote palette selection: validates the directory on the remote node,
  # registers it in the remote node's recent projects, and sets a DISPLAY-ONLY
  # active project (no local project config / mode detection — those are local
  # concerns). The push_patch URL carries the `&node=` param so handle_params
  # re-runs in the same remote context.
  defp activate_remote_palette_project(socket, project, expanded) do
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
      node = socket.assigns[:current_node]

      if EvoDash.NodeContext.dir?(node, expanded) do
        EvoDash.NodeContext.add_recent_project(node, expanded, Path.basename(expanded))
        recent_projects = EvoDash.NodeContext.list_recent_projects(node)

        socket
        |> assign(:recent_projects, recent_projects)
        |> assign(:project_palette_open, false)
        |> assign(:palette_mode, :menu)
        |> assign(:active_project, %{path: expanded, name: Path.basename(expanded)})
        |> assign(:active_project_path, expanded)
        |> push_patch(to: project_url(socket, expanded))
      else
        socket
        |> assign(:project_palette_open, false)
        |> put_flash(
          :error,
          gettext("Directory does not exist on the remote node: %{path}", path: project.path)
        )
      end
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

  # Builds the dashboard URL for a project path. In a remote context the
  # `&node=` param is appended so the node context survives the push_patch —
  # NOTE: deliberately NOT `EvoDashWeb.Helpers.with_node_param/2`, which
  # appends with `?` and would corrupt the existing `?project=` query.
  defp project_url(socket, path) do
    case socket.assigns[:current_node_id] do
      nil -> "/?project=#{URI.encode(path)}"
      node_id -> "/?project=#{URI.encode(path)}&node=#{node_id}"
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
    |> Assigns.assign_running_and_pending_tasks()
    |> Project.maybe_put_flash_mode_info(mode_info)
  end
end
