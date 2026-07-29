defmodule EvoDashWeb.DashboardLive do
  @moduledoc """
  Project-based task dashboard for launching and monitoring EvoGit tasks.

  Users open a repository, and the dashboard auto-detects the task mode
  (genesis or evolve). Displays active tasks with live logs and inline
  project settings including foreign repositories.
  """
  use EvoDashWeb, :live_view
  alias EvoGit.TaskRegistry
  alias EvoDashWeb.DashboardLive.{StatePersistence, Project, Assigns}
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Platform
  alias EvoGit.ProjectConfig
  use EvoDashWeb.ModalHelpers

  @impl true
  def render(assigns) do
    ~H"""
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
        >
          <div id="tauri-detect" phx-hook="TauriDetect" class="hidden"></div>
          <div id="platform-detect" phx-hook="PlatformDetect" class="hidden"></div>
          <div id="browser-notifications" phx-hook="BrowserNotifications">
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
                                Gettext.gettext(EvoDashWeb.Gettext, String.capitalize(Atom.to_string(s)))

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
                          <% total = Map.get(usage, :total_tokens) || Map.get(agent, :total_tokens) || 0 %>
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
            <!-- ① Select Project -->
            <div class="animate-fade-in-up">
              <.step_header number="1" title={gettext("Select Project")} />
              <EvoDashWeb.ProjectComponents.project_selector
                active_project={@active_project}
                recent_projects={@recent_projects}
                show_open_form={@show_open_project_form}
                show_new_project_form={@show_new_project_form}
                path_suggestions={@path_suggestions}
                tauri_detected={@tauri_detected}
                platform={@platform}
              />
            </div>

            <!-- ② Describe the Task -->
            <div class="mt-6 animate-fade-in-up animation-delay-100">
              <.step_header number="2" title={gettext("Describe the Task")} />
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
            </div>

            <!-- Advanced — hidden, but the entry is obvious -->
            <details class="group mt-5 rounded-2xl border-2 border-dashed border-base-300 bg-base-100 overflow-hidden animate-fade-in-up animation-delay-100" open={@show_advanced}>
              <summary
                class="p-4 cursor-pointer hover:bg-base-200/40 transition-colors flex items-center gap-2.5 list-none [&::-webkit-details-marker]:hidden"
                phx-click="toggle_advanced"
              >
                <.icon name="hero-adjustments-horizontal" class="size-5 text-primary" />
                <span class="text-sm font-bold">{gettext("Advanced")}</span>
                <span class="text-xs text-base-content/45 truncate">
                  {gettext("Model, build system, archive, node/commit, project settings")}
                </span>
                <span class="ml-auto badge badge-ghost badge-sm shrink-0">
                  <%= if @selected_model_id do %>{@selected_model_id}<% else %>{gettext("defaults")}<% end %>
                </span>
                <.icon
                  name="hero-chevron-down"
                  class="size-4 text-base-content/40 group-open:rotate-180 transition-transform shrink-0"
                />
              </summary>
              <div class="p-4 space-y-4 border-t border-base-200">
                <!-- Model / Build System / Archive (associated to task-form) -->
                <div class="flex flex-wrap items-end gap-x-5 gap-y-2.5">
                  <%= if @model_profiles != [] do %>
                    <div class="flex flex-col gap-1">
                      <label class="text-[11px] font-semibold uppercase tracking-wide text-base-content/40 leading-none">
                        {gettext("Model")}
                      </label>
                      <select
                        name="model_id"
                        form="task-form"
                        phx-change="select_model"
                        class="select select-bordered select-sm bg-base-100 shadow-sm font-medium focus:outline-none focus:ring-2 focus:ring-primary/20 min-w-[10rem]"
                      >
                        <%= for profile <- @model_profiles do %>
                          <option value={profile.id} selected={@selected_model_id == profile.id}>
                            {profile.id}
                          </option>
                        <% end %>
                      </select>
                    </div>
                  <% end %>

                  <%= if String.starts_with?(@task_mode, "genesis") do %>
                    <div class="flex flex-col gap-1">
                      <label class="text-[11px] font-semibold uppercase tracking-wide text-base-content/40 leading-none">
                        {gettext("Build System")}
                      </label>
                      <select
                        name="build_system"
                        form="task-form"
                        class="select select-bordered select-sm bg-base-100 shadow-sm font-medium focus:outline-none focus:ring-2 focus:ring-primary/20"
                      >
                        <option value="">{gettext("No build system")}</option>
                        <%= for bs <- @build_systems do %>
                          <option value={to_string(bs.id)} selected={@task_build_system == to_string(bs.id)}>
                            {bs.name}
                          </option>
                        <% end %>
                      </select>
                    </div>
                  <% end %>

                  <div class="flex flex-col gap-1">
                    <label class="text-[11px] font-semibold uppercase tracking-wide text-base-content/40 leading-none">
                      {gettext("Archive")}
                    </label>
                    <label class="label cursor-pointer flex items-center gap-2 py-0">
                      <input type="checkbox" name="archive" form="task-form" value="true" class="toggle toggle-sm toggle-primary" />
                      <span class="text-sm text-base-content/60">{gettext("Archive agent details")}</span>
                    </label>
                  </div>
                </div>

                <EvoDashWeb.TaskFormComponents.advanced_options
                  show_advanced={@show_advanced}
                  node_path={@task_node_path}
                  starting_commit={@task_starting_commit}
                  resume_from={@task_resume_from}
                  mode={@task_mode}
                  disabled={is_nil(@active_project)}
                />
                <%= if @active_project do %>
                  <EvoDashWeb.ProjectComponents.project_settings_panel
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
                    tauri_detected={@tauri_detected}
                    platform={@platform}
                  />
                <% end %>
              </div>
            </details>

            <!-- Task History (merged from /tasks) -->
            <div class="mt-6 animate-fade-in-up animation-delay-200">
              <.step_header number="3" title={gettext("Tasks")} />
              <p class="text-sm text-base-content/50 mb-3 -mt-1">
                {dngettext("default", "%{count} task found", "%{count} tasks found", @total_count)}
              </p>

              <!-- Filter Bar -->
              <div class="rounded-lg border border-base-200 bg-base-100 p-3 sm:p-4 mb-4">
                <form id="task-filters" phx-submit="noop">
                  <div class="flex flex-col sm:flex-row gap-3">
                    <!-- Status Filter -->
                    <div class="form-control">
                      <select
                        name="status_filter"
                        class="select select-bordered select-md rounded-md bg-base-100 sm:w-48 focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary"
                        phx-change="filter_tasks"
                      >
                        <option value="all" selected={@status_filter == "all"}>{gettext("All Statuses")}</option>
                        <option value="running" selected={@status_filter == "running"}>{gettext("Running")}</option>
                        <option value="pending" selected={@status_filter == "pending"}>{gettext("Pending")}</option>
                        <option value="completed" selected={@status_filter == "completed"}>{gettext("Completed")}</option>
                        <option value="failed" selected={@status_filter == "failed"}>{gettext("Failed")}</option>
                        <option value="cancelled" selected={@status_filter == "cancelled"}>{gettext("Cancelled")}</option>
                      </select>
                    </div>

                    <!-- Project Filter -->
                    <div class="form-control">
                      <select
                        name="project_filter"
                        class="select select-bordered select-md rounded-md bg-base-100 sm:w-48 focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary"
                        phx-change="filter_tasks"
                      >
                        <option value="all" selected={@project_filter == "all"}>{gettext("All Projects")}</option>
                        <%= for path <- @project_paths do %>
                          <option value={path} selected={@project_filter == path}>
                            <%= Path.basename(path) %> (<%= String.slice(path, 0, 30) %>...)
                          </option>
                        <% end %>
                      </select>
                    </div>

                    <!-- Review Status Filter -->
                    <div class="form-control">
                      <select
                        name="review_filter"
                        class="select select-bordered select-md rounded-md bg-base-100 sm:w-48 focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary"
                        phx-change="filter_review"
                      >
                        <option value="all" selected={@review_status_filter == "all"}>{gettext("All Reviews")}</option>
                        <option value="pending" selected={@review_status_filter == "pending"}>{gettext("Pending Review")}</option>
                        <option value="merged" selected={@review_status_filter == "merged"}>{gettext("Merged")}</option>
                        <option value="rejected" selected={@review_status_filter == "rejected"}>{gettext("Rejected")}</option>
                        <option value="continued" selected={@review_status_filter == "continued"}>{gettext("Continued")}</option>
                      </select>
                    </div>

                    <!-- Search -->
                    <div class="form-control flex-1">
                      <div class="relative">
                        <.icon
                          name="hero-magnifying-glass"
                          class="absolute left-3 top-1/2 -translate-y-1/2 size-4 text-base-content/40 pointer-events-none z-10"
                        />
                        <input
                          type="text"
                          name="search_query"
                          value={@search_query}
                          class="input input-bordered input-md rounded-md bg-base-100 pl-10 w-full focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary shadow-sm"
                          placeholder={gettext("Search by task ID, prompt, or objective...")}
                          phx-change="search_tasks"
                          phx-debounce="200"
                        />
                      </div>
                    </div>

                    <!-- Actions -->
                    <div class="flex items-center gap-2 shrink-0">
                      <button
                        type="button"
                        class="btn btn-ghost btn-md"
                        phx-click="reset_filters"
                        title={gettext("Reset all filters")}
                      >
                        <.icon name="hero-x-mark" class="size-4" /> {gettext("Reset")}
                      </button>
                    </div>
                  </div>
                </form>

                <!-- Active filters indicator -->
                <%= if @status_filter != "all" or @project_filter != "all" or @search_query != "" or @review_status_filter != "all" do %>
                  <div class="flex items-center gap-2 mt-3 pt-3 border-t border-base-200/50">
                    <span class="text-xs text-base-content/50">{gettext("Active filters:")}</span>
                    <%= if @status_filter != "all" do %>
                      <span class="badge badge-primary gap-1 rounded-md">
                        {@status_filter}
                        <button phx-click="clear_filter" phx-value-filter="status" class="hover:opacity-70">×</button>
                      </span>
                    <% end %>
                    <%= if @project_filter != "all" do %>
                      <span class="badge badge-secondary gap-1 rounded-md">
                        {Path.basename(@project_filter)}
                        <button phx-click="clear_filter" phx-value-filter="project" class="hover:opacity-70">×</button>
                      </span>
                    <% end %>
                    <%= if @search_query != "" do %>
                      <span class="badge badge-accent gap-1 rounded-md">
                        "{String.slice(@search_query, 0, 20)}{if String.length(@search_query) > 20, do: "..."}"
                        <button phx-click="clear_filter" phx-value-filter="search" class="hover:opacity-70">×</button>
                      </span>
                    <% end %>
                    <%= if @review_status_filter != "all" do %>
                      <span class="badge badge-accent gap-1 rounded-md">
                        <%= case @review_status_filter do %>
                          <% "pending" -> %>{gettext("Pending Review")}
                          <% "merged" -> %>{gettext("Merged")}
                          <% "rejected" -> %>{gettext("Rejected")}
                          <% "continued" -> %>{gettext("Continued")}
                          <% _ -> %>{@review_status_filter}
                        <% end %>
                        <button phx-click="clear_filter" phx-value-filter="review" class="hover:opacity-70">×</button>
                      </span>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <!-- Task List -->
              <div class="space-y-4 lg:space-y-5">
                <%= if @history_tasks == [] do %>
                  <div class="text-center py-12 sm:py-16 text-base-content/50">
                    <.icon name="hero-inbox" class="size-10 mx-auto mb-4 opacity-50" />
                    <p class="text-lg font-medium">{gettext("No tasks found")}</p>
                    <p class="text-sm mt-1">
                      <%= if @status_filter != "all" or @project_filter != "all" or @search_query != "" or @review_status_filter != "all" do %>
                        {gettext("Try adjusting your filters or search query.")}
                      <% else %>
                        {gettext("Tasks will appear here once you start them from the dashboard.")}
                      <% end %>
                    </p>
                  </div>
                <% else %>
                  <%= for {task, idx} <- Enum.with_index(@history_tasks) do %>
                    <div class={["relative z-10 has-[[open]]:z-30 animate-fade-in-up", animation_delay_class(idx)]}>
                      <EvoDashWeb.TaskCardComponents.task_card
                        task={task}
                        show_details={MapSet.member?(@expanded_task_ids, task.id)}
                      />
                    </div>
                  <% end %>
                <% end %>
              </div>

              <!-- Pagination Controls -->
              <%= if @total_count > 0 do %>
                <% offset = (@current_page - 1) * @page_size %>
                <% range_start = offset + 1 %>
                <% range_end = min(offset + @page_size, @total_count) %>
                <% pages = page_window(@current_page, @total_pages) %>
                <div class="mt-4 flex flex-col items-center gap-3">
                  <p class="text-sm text-base-content/60">
                    {gettext("Showing %{start}–%{end} of %{total} tasks",
                      start: range_start,
                      end: range_end,
                      total: @total_count
                    )}
                  </p>
                  <div class="flex items-center gap-2">
                    <div class="join">
                      <button
                        class="join-item btn btn-sm"
                        phx-click="prev_page"
                        disabled={@current_page <= 1}
                      >
                        <.icon name="hero-chevron-left" class="size-4" />
                      </button>
                      <%= for p <- pages do %>
                        <%= if p == @current_page do %>
                          <button class="join-item btn btn-sm btn-primary" disabled>
                            {p}
                          </button>
                        <% else %>
                          <button
                            class="join-item btn btn-sm"
                            phx-click="goto_page"
                            phx-value-page={p}
                          >
                            {p}
                          </button>
                        <% end %>
                      <% end %>
                      <button
                        class="join-item btn btn-sm"
                        phx-click="next_page"
                        disabled={@current_page >= @total_pages}
                      >
                        <.icon name="hero-chevron-right" class="size-4" />
                      </button>
                    </div>
                  </div>
                  <p class="text-xs text-base-content/50">
                    {gettext("Page %{current} of %{total}", current: @current_page, total: @total_pages)}
                  </p>
                </div>
              <% end %>

              <!-- Clear History (moved to bottom for safety) -->
              <div class="mt-6 flex justify-center sm:justify-end">
                <button type="button" class="btn btn-ghost btn-sm text-error/60 hover:text-error gap-1" phx-click="clear_task_history" phx-confirm={gettext("Clear all finished task history? This cannot be undone.")}>
                  <.icon name="hero-trash" class="size-3.5" /> {gettext("Clear History")}
                </button>
              </div>
            </div>

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
            <% end %>
            <%!-- end of @remote? else branch --%>
          </div>
        </div>
      </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    # On the dead render (initial HTTP request), check the session for the
    # onboarding flag and redirect to /welcome if not completed. The session
    # is set by WelcomeController.complete/2 when the user finishes onboarding.
    #
    # For WebSocket-connected mounts (e.g. push_navigate after redirect),
    # the session cookie already reflects completed onboarding, so we skip
    # the check here.
    if !connected?(socket) and session["onboarding_completed"] != true do
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
          remote?: false,
          remote_agents: [],
          # Task history section (merged from /tasks)
          history_tasks: [],
          project_paths: [],
          status_filter: "all",
          project_filter: "all",
          search_query: "",
          review_status_filter: "all",
          current_page: 1,
          page_size: 25,
          total_count: 0,
          total_pages: 1,
          query_params: %{}
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
      |> assign(:query_params, params)
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
          |> assign(:tasks, tasks)
          |> assign(
            :notified_task_ids,
            Assigns.build_notified_task_ids(tasks, socket.assigns.notified_task_ids)
          )
          |> assign(
            active_project: nil,
            active_project_path: nil
          )
          |> Assigns.assign_running_and_pending_tasks()
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
                    Assigns.build_notified_task_ids(all_tasks, socket.assigns.notified_task_ids)
                  )
                  |> Assigns.assign_running_and_pending_tasks()
                end

              _ ->
                all_tasks = TaskRegistry.list_tasks()

                socket
                |> assign(:tasks, all_tasks)
                |> assign(
                  :notified_task_ids,
                  Assigns.build_notified_task_ids(all_tasks, socket.assigns.notified_task_ids)
                )
                |> Assigns.assign_running_and_pending_tasks()
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

    # Load the task history page (server-side pagination) unless we're viewing
    # a remote node (the history section is hidden in that branch).
    socket =
      if socket.assigns.remote? do
        socket
      else
        load_page_into_socket(socket, parse_page(params["page"]))
      end

    {:noreply, socket}
  end

  # --- Project Management Events ---

  @impl true
  def handle_event("toggle_open_project_form", _params, socket) do
    {:noreply,
     assign(socket,
       show_open_project_form: !socket.assigns.show_open_project_form,
       show_new_project_form: false
     )}
  end

  @impl true
  def handle_event("toggle_new_project_form", _params, socket) do
    {:noreply,
     assign(socket,
       show_new_project_form: !socket.assigns.show_new_project_form,
       show_open_project_form: false
     )}
  end

  @impl true
  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :show_advanced, !socket.assigns.show_advanced)}
  end

  @impl true
  def handle_event("create_project", %{"location" => location, "name" => name}, socket) do
    location = Path.expand(location)

    cond do
      not File.dir?(location) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Parent directory does not exist: %{path}", path: location)
         )}

      true ->
        case Project.validate_project_name(name) do
          {:error, :invalid_name} ->
            {:noreply, put_flash(socket, :error, gettext("Invalid project name"))}

          {:ok, sanitized} ->
            full_path = Path.join(location, sanitized)
            File.mkdir!(full_path)

            TaskRegistry.add_recent_project(full_path, sanitized)
            recent_projects = TaskRegistry.list_recent_projects()

            socket =
              socket
              |> assign(:recent_projects, recent_projects)
              |> assign(:show_new_project_form, false)
              |> put_flash(:info, gettext("Project created: %{path}", path: full_path))

            {:noreply, push_patch(socket, to: ~p"/?project=#{full_path}")}
        end
    end
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
      {:noreply, push_patch(socket, to: ~p"/?project=#{expanded}")}
    else
      {:noreply,
       socket
       |> put_flash(
         :error,
         gettext(
           "Directory does not exist: %{path}. Create a new project instead?",
           path: path
         )
       )}
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

      {:noreply, push_patch(socket, to: ~p"/?project=#{expanded}")}
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
          Keyword.put(opts, :prompt, prompt)
        else
          Keyword.put(opts, :objective, prompt)
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
           |> assign(:tasks, TaskRegistry.list_tasks_by_path(path))
           |> Assigns.assign_running_and_pending_tasks()
           |> Assigns.assign_form_defaults()
           |> reload_current_page()
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

        {:noreply,
         socket
         |> assign(:tasks, Assigns.current_tasks(socket))
         |> assign(:expanded_task_ids, expanded)
         |> Assigns.assign_running_and_pending_tasks()
         |> reload_current_page()}

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

    {:noreply,
     socket
     |> assign(:tasks, Assigns.current_tasks(socket))
     |> assign(:expanded_task_ids, MapSet.new())
     |> Assigns.assign_running_and_pending_tasks()
     |> reload_current_page()}
  end

  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    TaskRegistry.delete_task(task_id)
    expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

    {:noreply,
     socket
     |> assign(:tasks, Assigns.current_tasks(socket))
     |> assign(:expanded_task_ids, expanded)
     |> Assigns.assign_running_and_pending_tasks()
     |> reload_current_page()}
  end

  # --- Task History Events (merged from /tasks) ---

  @impl true
  def handle_event("filter_tasks", params, socket) do
    status_filter = params["status_filter"] || socket.assigns.status_filter
    project_filter = params["project_filter"] || socket.assigns.project_filter

    {:noreply,
     socket
     |> assign(:status_filter, status_filter)
     |> assign(:project_filter, project_filter)
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("filter_review", %{"review_filter" => filter}, socket) do
    {:noreply,
     socket
     |> assign(:review_status_filter, filter)
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("search_tasks", %{"search_query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> load_page_into_socket(1)}
  end

  # Prevents page reload when pressing Enter in the filter/search form
  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("reset_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(
       status_filter: "all",
       project_filter: "all",
       search_query: "",
       review_status_filter: "all"
     )
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "status"}, socket) do
    {:noreply,
     socket
     |> assign(:status_filter, "all")
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "project"}, socket) do
    {:noreply,
     socket
     |> assign(:project_filter, "all")
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "search"}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "review"}, socket) do
    {:noreply,
     socket
     |> assign(:review_status_filter, "all")
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("goto_page", %{"page" => page}, socket) do
    {:noreply, patch_history_page(socket, page)}
  end

  @impl true
  def handle_event("prev_page", _params, socket) do
    {:noreply, patch_history_page(socket, max(1, socket.assigns.current_page - 1))}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    page = min(socket.assigns.total_pages, socket.assigns.current_page + 1)
    {:noreply, patch_history_page(socket, page)}
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
     |> assign(:tasks, new_tasks)
     |> Assigns.assign_running_and_pending_tasks()
     |> reload_current_page()}
  end

  @impl true
  def handle_info({:task_status, _task_id, _status}, socket) do
    {:noreply,
     socket
     |> assign(:tasks, Assigns.current_tasks(socket))
     |> Assigns.assign_running_and_pending_tasks()
     |> reload_current_page()}
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
      tasks: tasks,
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
    |> Assigns.assign_running_and_pending_tasks()
    |> Project.maybe_put_flash_mode_info(mode_info)
  end

  # --- Task History Helpers (merged from /tasks) ---

  # Numbered step header for the simplified dashboard workflow
  # (1 Select Project → 2 Describe the Task → 3 Tasks).
  attr(:number, :string, required: true)
  attr(:title, :string, required: true)

  defp step_header(assigns) do
    ~H"""
    <div class="step-header flex items-center gap-2.5 mb-3">
      <span class="step-badge inline-flex items-center justify-center w-7 h-7 rounded-lg bg-primary text-primary-content text-sm font-bold shrink-0">
        {@number}
      </span>
      <h2 class="text-base font-bold tracking-tight shrink-0">{@title}</h2>
      <div class="flex-1 border-t border-base-200"></div>
    </div>
    """
  end

  # Parses the ?page= query param into a positive integer (default 1).
  # Uses Integer.parse/1 (returns :error for non-integers) — no try/rescue,
  # no String.to_existing_atom.
  defp parse_page(nil), do: 1

  defp parse_page(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  # push_patch helper for history pagination. Preserves the current query
  # params (project, starting_commit, resume_from, node) so paginating never
  # resets the active project.
  defp patch_history_page(socket, page) do
    query =
      socket.assigns.query_params
      |> Map.put("page", to_string(page))
      |> URI.encode_query()

    push_patch(socket, to: "/?" <> query)
  end

  # Fetches one page of tasks (server-side LIMIT/OFFSET). Returns
  # {tasks, clamped_page, total_count, total_pages}. The requested page is
  # clamped against the actual total_pages derived from the returned count.
  # If clamping changes the page, a second fetch is performed for the
  # clamped page. This is at most one extra fetch and only on edge cases
  # (e.g. a stale/high page number).
  defp load_page(requested_page, page_size, filters) do
    offset = (requested_page - 1) * page_size
    {tasks, total_count} = TaskRegistry.list_tasks_paginated(limit: page_size, offset: offset, filters: filters)
    total_pages = total_pages(total_count, page_size)
    clamped_page = min(max(1, requested_page), total_pages)

    if clamped_page != requested_page do
      clamped_offset = (clamped_page - 1) * page_size

      {clamped_tasks, ^total_count} =
        TaskRegistry.list_tasks_paginated(limit: page_size, offset: clamped_offset, filters: filters)

      {clamped_tasks, clamped_page, total_count, total_pages}
    else
      {tasks, clamped_page, total_count, total_pages}
    end
  end

  defp total_pages(total_count, page_size) when page_size > 0 do
    max(1, ceil(total_count / page_size))
  end

  # Returns a windowed range of page numbers around the current page for the
  # pagination button group. Shows up to 7 page buttons centered on the
  # current page, clamped to the valid range 1..total_pages.
  defp page_window(current_page, total_pages) do
    window = 3
    start_page = max(1, current_page - window)
    end_page = min(total_pages, current_page + window)
    Enum.to_list(start_page..end_page)
  end

  # Reloads the current history page into the socket assigns. Used by PubSub
  # handlers and mutating events so the history section stays consistent.
  defp reload_current_page(socket) do
    if socket.assigns[:remote?] do
      socket
    else
      load_page_into_socket(socket, socket.assigns.current_page)
    end
  end

  defp load_page_into_socket(socket, page) do
    filters = build_filters_from_assigns(socket)
    {tasks, current_page, total_count, total_pages} =
      load_page(page, socket.assigns.page_size, filters)

    socket
    |> assign(:history_tasks, tasks)
    |> assign(:current_page, current_page)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:project_paths, TaskRegistry.get_unique_paths())
  end

  defp build_filters_from_assigns(socket) do
    [
      status: socket.assigns.status_filter,
      project_path: socket.assigns.project_filter,
      review_status: socket.assigns.review_status_filter,
      search: socket.assigns.search_query
    ]
  end

  defp animation_delay_class(idx) when idx <= 5, do: "animation-delay-#{div(idx, 1) * 100}"
  defp animation_delay_class(_), do: ""
end
