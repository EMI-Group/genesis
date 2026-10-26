defmodule EvoDashWeb.TasksLive do
  @moduledoc """
  Cross-project task list with filtering by status, project, and review state.

  Node-aware: reads task history via `EvoDash.NodeContext` so it works for both
  the local BEAM node and a remote `genesis_remote` daemon (SSH Remote
  Development, Phase 3). Change detection is fully push-based: `:evo_git`
  broadcasts `{:task_updated, task_id, status, node}` and
  `{:task_deleted, task_id, node}` on the `EvoGit.PubSub` "tasks" topic;
  `NodeAware.handle_task_info/2` applies the node filter and schedules a
  debounced `:node_aware_reload_tasks` full-page reload.

  No LiveView process blocks on a store/RPC call: every page load runs in a
  supervised task (`EvoDashWeb.TasksLive.PageLoad`) behind
  `EvoDash.SafeCall.run/1`, and its result arrives as
  `{:tasks_page_loaded, seq, node, result}`. An exit (store timeout / dead
  store) becomes a retry-able `:tasks_error` state, and the user-initiated
  mutating events are SafeCall-wrapped so an exit flashes instead of crashing
  the LiveView.

  The page load transfers the LIGHTWEIGHT summary projection only (no `result`
  / `usage` / `logs` / `archive_metadata`). The heavy data is fetched per card,
  on demand, by `EvoDashWeb.TasksLive.TaskDetail` (lite detail + archive),
  which owns the bounded `:task_details` cache and its `:task_detail_seq`
  stale-guard.
  """
  use EvoDashWeb, :live_view
  use Gettext, backend: EvoDashWeb.Gettext
  use EvoDashWeb.ModalHelpers

  alias EvoDash.SafeCall
  alias EvoDashWeb.TasksLive.PageLoad
  alias EvoDashWeb.TasksLive.TaskDetail

  @default_page_size 25

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:tasks}
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
      <%= if EvoDashWeb.RemoteGateComponents.gate_active?(assigns) do %>
        {EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns)}
      <% else %>
        <!-- Filter Bar -->
        <div class="rounded-lg border border-base-300 bg-base-100 p-3 sm:p-4 mb-4">
          <form id="task-filters" phx-submit="noop">
            <div class="flex flex-col sm:flex-row gap-3">
              <!-- Status Filter -->
              <div class="form-control">
                <select
                  name="status_filter"
                  class="select select-bordered select-md rounded-md bg-base-100 sm:w-48"
                  phx-change="filter_tasks"
                >
                  <option value="all" selected={@status_filter == "all"}>
                    {gettext("All Statuses")}
                  </option>
                  <option value="running" selected={@status_filter == "running"}>
                    {gettext("Running")}
                  </option>
                  <option value="pending" selected={@status_filter == "pending"}>
                    {gettext("Pending")}
                  </option>
                  <option value="cancelling" selected={@status_filter == "cancelling"}>
                    {gettext("Cancelling")}
                  </option>
                  <option value="completed" selected={@status_filter == "completed"}>
                    {gettext("Completed")}
                  </option>
                  <option value="failed" selected={@status_filter == "failed"}>
                    {gettext("Failed")}
                  </option>
                  <option value="cancelled" selected={@status_filter == "cancelled"}>
                    {gettext("Cancelled")}
                  </option>
                </select>
              </div>

              <!-- Project Filter -->
              <div class="form-control">
                <select
                  name="project_filter"
                  class="select select-bordered select-md rounded-md bg-base-100 sm:w-48"
                  phx-change="filter_tasks"
                >
                  <option value="all" selected={@project_filter == "all"}>
                    {gettext("All Projects")}
                  </option>
                  <%= for path <- @project_paths do %>
                    <option value={path} selected={@project_filter == path}>
                      {Path.basename(path)} ({String.slice(path, 0, 30)}...)
                    </option>
                  <% end %>
                </select>
              </div>

              <!-- Review Status Filter -->
              <div class="form-control">
                <select
                  name="review_filter"
                  class="select select-bordered select-md rounded-md bg-base-100 sm:w-48"
                  phx-change="filter_review"
                >
                  <option value="all" selected={@review_status_filter == "all"}>
                    {gettext("All Reviews")}
                  </option>
                  <option value="pending" selected={@review_status_filter == "pending"}>
                    {gettext("Pending Review")}
                  </option>
                  <option value="merged" selected={@review_status_filter == "merged"}>
                    {gettext("Merged")}
                  </option>
                  <option value="rejected" selected={@review_status_filter == "rejected"}>
                    {gettext("Rejected")}
                  </option>
                  <option value="continued" selected={@review_status_filter == "continued"}>
                    {gettext("Continued")}
                  </option>
                </select>
              </div>

              <!-- Search -->
              <div class="form-control flex-1">
                <div class="relative">
                  <.icon
                    name="hero-magnifying-glass"
                    class="absolute left-3 top-1/2 -translate-y-1/2 size-4 text-base-content/60 pointer-events-none z-10"
                  />
                  <%!-- 搜索结果同时匹配 agent 的最终回复消息 --%>
                  <input
                    type="text"
                    name="search_query"
                    value={@search_query}
                    class="input input-bordered input-md rounded-md bg-base-100 pl-10 w-full shadow-sm"
                    placeholder={gettext("Search by task ID, prompt, objective, or response...")}
                    phx-change="search_tasks"
                    phx-debounce="200"
                  />
                </div>
              </div>

              <!-- Actions -->
              <div class="flex items-center gap-2 shrink-0">
                <%!-- 勾选后显示 Home 聊天页(自省智能体, :reflect 仓库外聊天任务)产生的聊天任务 --%>
                <label class="label cursor-pointer gap-2">
                  <input
                    type="checkbox"
                    name="show_reflect_tasks"
                    value="true"
                    checked={@show_reflect_tasks}
                    phx-change="toggle_reflect_tasks"
                    class="checkbox checkbox-sm"
                  />
                  <span class="label-text whitespace-nowrap">{gettext("Show chat tasks")}</span>
                </label>
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
            <div class="flex items-center gap-2 mt-3 pt-3 border-t border-base-300">
              <span class="text-xs text-base-content/70">{gettext("Active filters:")}</span>
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
                  "{String.slice(@search_query, 0, 20)}{if String.length(@search_query) > 20,
                    do: "..."}"
                  <button phx-click="clear_filter" phx-value-filter="search" class="hover:opacity-70">×</button>
                </span>
              <% end %>
              <%= if @review_status_filter != "all" do %>
                <span class="badge badge-accent gap-1 rounded-md">
                  <%= case @review_status_filter do %>
                    <% "pending" -> %>
                      {gettext("Pending Review")}
                    <% "merged" -> %>
                      {gettext("Merged")}
                    <% "rejected" -> %>
                      {gettext("Rejected")}
                    <% "continued" -> %>
                      {gettext("Continued")}
                    <% _ -> %>
                      {@review_status_filter}
                  <% end %>
                  <button phx-click="clear_filter" phx-value-filter="review" class="hover:opacity-70">×</button>
                </span>
              <% end %>
            </div>
          <% end %>
        </div>

        <!-- Task Count (hidden while a load is in flight — otherwise the stale
           count flashes "0 tasks found" during every filter/navigation; also
           hidden when a failed load left no rows at all, where the count would
           contradict the error block below) -->
        <%= if not @tasks_loading and not (@tasks_error != nil and @filtered_tasks == []) do %>
          <div class="flex items-center justify-between mb-4">
            <p class="text-sm text-base-content/60">
              {dngettext(
                "default",
                "%{count} task found",
                "%{count} tasks found",
                length(@filtered_tasks)
              )}
            </p>
          </div>
        <% end %>

        <!-- Background-refresh failure: the already-loaded rows stay on screen,
           so only a compact retry strip is added above the list. -->
        <%= if @tasks_error != nil and @filtered_tasks != [] do %>
          <div
            id="tasks-refresh-error"
            role="alert"
            class="mb-3 flex items-center justify-between gap-3 rounded-lg border border-error/20 bg-error/10 px-3 py-2 text-sm text-error"
          >
            <span class="flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="size-4" />
              {gettext("Could not refresh tasks.")}
            </span>
            <button type="button" class="btn btn-sm btn-ghost text-error" phx-click="retry_load">
              <.icon name="hero-arrow-path" class="size-3.5" /> {gettext("Retry")}
            </button>
          </div>
        <% end %>

        <!-- Task List -->
        <div id="tasks-list" class="space-y-4 lg:space-y-5">
          <%= if @tasks_loading do %>
            <div class="text-center py-12 sm:py-16 text-base-content/70">
              <.icon
                name="hero-arrow-path"
                class="size-10 mx-auto mb-4 text-base-content/40 animate-spin"
              />
              <p class="text-lg font-medium">{gettext("Loading tasks...")}</p>
            </div>
          <% else %>
            <%= if @filtered_tasks == [] do %>
              <%= if @tasks_error != nil do %>
                <div id="tasks-load-error" class="text-center py-12 sm:py-16 text-base-content/70">
                  <.icon
                    name="hero-exclamation-triangle"
                    class="size-10 mx-auto mb-4 text-error/70"
                  />
                  <p class="text-lg font-medium text-error">{gettext("Could not load tasks.")}</p>
                  <button
                    type="button"
                    class="btn btn-sm btn-ghost mt-3 text-error"
                    phx-click="retry_load"
                  >
                    <.icon name="hero-arrow-path" class="size-3.5" /> {gettext("Retry")}
                  </button>
                </div>
              <% else %>
                <div class="text-center py-12 sm:py-16 text-base-content/70">
                  <.icon name="hero-inbox" class="size-10 mx-auto mb-4 text-base-content/40" />
                  <p class="text-lg font-medium">{gettext("No tasks found")}</p>
                  <p class="text-sm mt-1">
                    <%= if @status_filter != "all" or @project_filter != "all" or @search_query != "" or @review_status_filter != "all" or (@total_count > 0 and not @show_reflect_tasks) do %>
                      {gettext("Try adjusting your filters or search query.")}
                    <% else %>
                      {gettext("Tasks will appear here once you start them from the dashboard.")}
                    <% end %>
                  </p>
                </div>
              <% end %>
            <% else %>
              <%= for {task, idx} <- Enum.with_index(@filtered_tasks) do %>
                <div class={[
                  "relative z-10 has-[[open]]:z-30 animate-fade-in-up",
                  animation_delay_class(idx)
                ]}>
                  <EvoDashWeb.TaskCardComponents.task_card
                    task={task}
                    show_details={MapSet.member?(@expanded_task_ids, task.id)}
                    detail={Map.get(@task_details, task.id)}
                    current_node_id={@current_node_id}
                  />
                </div>
              <% end %>
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
            <p class="text-sm text-base-content/70">
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
            <p class="text-xs text-base-content/70">
              {gettext("Page %{current} of %{total}", current: @current_page, total: @total_pages)}
            </p>
          </div>
        <% end %>

        <!-- Clear History (moved to bottom for safety) -->
        <div class="mt-6 flex justify-center sm:justify-end">
          <button
            type="button"
            class="btn btn-ghost btn-sm text-error gap-1"
            phx-click="clear_task_history"
            phx-confirm={gettext("Clear all finished task history? This cannot be undone.")}
          >
            <.icon name="hero-trash" class="size-3.5" /> {gettext("Clear History")}
          </button>
        </div>

        <!-- Full Result Modal — `@selected_result` is a modal STATE, not a raw
             result: %{state: :loading} | %{state: :ok, result: result} |
             %{state: :error, error: reason}. The result itself comes from the
             lazy per-card detail cache (TasksLive.ModalHelpers.view_full_result/2),
             so "not loaded yet" is a first-class, non-crashing state. -->
        <%= if @selected_result do %>
          <EvoDashWeb.Helpers.modal on_close="close_result_modal">
            <:title>
              <.icon name="hero-information-circle" class="size-5 text-base-content/70" />
              {gettext("Task Result")}
            </:title>
            <%= case @selected_result do %>
              <% %{state: :ok, result: result} -> %>
                {EvoDashWeb.TaskCardComponents.render_result_full(result)}
              <% %{state: :error} -> %>
                <p id="full-result-error" class="text-sm text-base-content/70">
                  {gettext("Could not load the task result.")}
                </p>
              <% _ -> %>
                <p id="full-result-loading" class="text-sm text-base-content/70">
                  {gettext("Task result is not loaded yet.")}
                </p>
            <% end %>
            <:actions>
              <%= if match?(%{state: :ok}, @selected_result) do %>
                <button
                  id="full-result-copy"
                  phx-hook="ClipboardCopy"
                  data-content={
                    EvoDashWeb.TaskCardComponents.result_copy_text(Map.get(@selected_result, :result))
                  }
                  class="btn btn-sm btn-ghost rounded-md"
                >
                  <.icon name="hero-clipboard-document" class="size-4 mr-1.5" />
                  <%!-- zh_CN: 复制按钮 --%>{gettext("Copy")}
                </button>
              <% end %>
            </:actions>
          </EvoDashWeb.Helpers.modal>
        <% end %>

        <!-- Full Options Modal -->
        <%= if @selected_options do %>
          <EvoDashWeb.Helpers.modal on_close="close_options_modal">
            <:title>
              <.icon name="hero-chat-bubble-left-ellipsis" class="size-5 text-primary-standalone" />
              {gettext("Full Objective")}
            </:title>
            <pre class="text-sm whitespace-pre-wrap break-words"><%= @selected_options %></pre>
            <:actions>
              <button
                id="full-options-copy"
                phx-hook="ClipboardCopy"
                data-content={@selected_options}
                class="btn btn-sm btn-ghost rounded-md"
              >
                <.icon name="hero-clipboard-document" class="size-4 mr-1.5" />
                <%!-- zh_CN: 复制按钮 --%>{gettext("Copy")}
              </button>
            </:actions>
          </EvoDashWeb.Helpers.modal>
        <% end %>

        <!-- Cancel Task confirmation modal (graceful: agents save + exit) -->
        <%= if @confirm_cancel_task_id do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
            <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="close_cancel_modal">
            </div>
            <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-300 max-w-lg w-full p-6 md:p-8">
              <div class="flex items-center gap-3 mb-4">
                <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
                <h3 class="text-lg font-bold">{gettext("Cancel Task?")}</h3>
              </div>

              <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
                {gettext(
                  "All agents of this task will be informed to immediately save their changes and exit. Intermediate results will be saved."
                )}
              </p>
              <p class="text-xs text-base-content/70 mb-5">
                {gettext("Task: %{task_id}", task_id: @confirm_cancel_task_id)}
              </p>

              <div class="flex justify-end gap-3 pt-2">
                <button
                  type="button"
                  class="btn btn-ghost rounded-md px-6"
                  phx-click="close_cancel_modal"
                >
                  {gettext("Keep Running")}
                </button>
                <button
                  type="button"
                  class="btn btn-warning rounded-md px-6 gap-2"
                  phx-click="confirm_cancel_task"
                >
                  <.icon name="hero-x-mark" class="size-4.5" />
                  {gettext("Cancel Task")}
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <!-- Force Kill Task confirmation modal (brutal: immediate, all progress lost) -->
        <%= if @confirm_force_kill_task_id do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
            <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="close_force_kill_modal">
            </div>
            <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-300 max-w-lg w-full p-6 md:p-8">
              <div class="flex items-center gap-3 mb-4">
                <.icon name="hero-exclamation-triangle" class="size-5 text-error" />
                <h3 class="text-lg font-bold">{gettext("Force Kill Task?")}</h3>
              </div>

              <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
                {gettext(
                  "Immediately stops the task and all of its agents. ALL progress will be completely lost. This cannot be undone."
                )}
              </p>
              <p class="text-xs text-base-content/70 mb-5">
                {gettext("Task: %{task_id}", task_id: @confirm_force_kill_task_id)}
              </p>

              <div class="flex justify-end gap-3 pt-2">
                <button
                  type="button"
                  class="btn btn-ghost rounded-md px-6"
                  phx-click="close_force_kill_modal"
                >
                  {gettext("Keep Running")}
                </button>
                <button
                  type="button"
                  class="btn btn-error rounded-md px-6 gap-2"
                  phx-click="confirm_force_kill_task"
                >
                  <.icon name="hero-x-circle" class="size-4.5" />
                  {gettext("Force Kill")}
                </button>
              </div>
            </div>
          </div>
        <% end %>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
    end

    config_status = config_status()

    socket =
      socket
      |> assign(
        tasks: [],
        # The rendered list (@filtered_tasks) is only ever filled by a landed
        # page load, but the ERROR state reads it before any load has
        # succeeded — seed it empty so a first-load failure renders the retry
        # block instead of crashing on a missing assign.
        filtered_tasks: [],
        # Project paths (the project-filter dropdown's options) are fetched by
        # the async page load (PageLoad.start/3 → PageLoad.load/4, which calls
        # get_unique_paths/1) and land with its {:tasks_page_loaded, ...}
        # result. Seeding empty here keeps mount/3 free of a blocking store
        # query — which would also always run against the LOCAL node, before
        # handle_params/3 resolves the ?node= context.
        project_paths: [],
        status_filter: "all",
        project_filter: "all",
        search_query: "",
        review_status_filter: "all",
        # Reveal preference (default OFF): hides :reflect repo-less Home-chat
        # tasks from the cross-project list. A page-local reveal toggle, NOT a
        # narrowing filter — deliberately left out of reset_filters and the
        # active-filters indicator.
        show_reflect_tasks: false,
        expanded_task_ids: MapSet.new(),
        # Per-card lazy detail cache, owned by EvoDashWeb.TasksLive.TaskDetail:
        # %{task_id => %{state:, task:, error:, seq:, archive:}}. Bounded to
        # ONE page's worth of entries (TaskDetail.prune/2 runs on every landed
        # page load) and seeded empty — nothing is fetched until a card is
        # expanded.
        task_details: %{},
        # Monotonic spawn counter for BOTH detail and archive fetches (the
        # per-entry stale guard) — deliberately its OWN key, independent of
        # :page_load_seq and of NodeAware's :tasks_load_seq.
        task_detail_seq: 0,
        selected_result: nil,
        selected_options: nil,
        confirm_cancel_task_id: nil,
        confirm_force_kill_task_id: nil,
        config_status: config_status,
        current_page: 1,
        page_size: @default_page_size,
        total_count: 0,
        total_pages: 1,
        # Async page-load state: page_load_seq is the monotonic spawn counter
        # for the in-flight page-load task (stale-guard) — deliberately its OWN
        # key, never :tasks_load_seq, which EvoDashWeb.LiveHooks.NodeAware owns
        # for the sidebar's "Active Tasks" fetch. The debounced reload spawns
        # BOTH loads in the same handler, so a shared counter would make each
        # load's bump invalidate the other's in-flight result.
        # tasks_loading drives the loading placeholder; tasks_error holds the
        # reason of the LAST failed page load (nil on success). An error keeps
        # the already-loaded rows untouched and renders a retry affordance.
        page_load_seq: 0,
        tasks_loading: false,
        tasks_error: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    requested_page = parse_page(params["page"])

    # Capture the node context BEFORE `assign_node/2` so a node switch can clear
    # stale confirmation modals: a cancel/force-kill modal opened on one node
    # must not persist (and potentially get confirmed) after switching to
    # another node. `:tasks_node_loaded` is the dedup-guard assign seeded by
    # NodeAware.on_mount and updated by assign_node/2 only when the context
    # tuple `{current_node_id, current_node}` changes — so pagination/filter
    # push_patches (same node) never clear the modals.
    previous_node_ctx = socket.assigns[:tasks_node_loaded]

    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/tasks")

    socket =
      if connected?(socket) do
        # Kick off the page load ONLY on the connected pass: handle_params/3
        # runs on BOTH the disconnected (static HTTP) render and the connected
        # mount, and the disconnected render's async result is discarded —
        # so spawning there would issue a full duplicate query (page SELECT +
        # COUNT + 25-row %TaskInfo{} decode + get_unique_paths) per
        # navigation. The else branch still paints the loading placeholder so
        # the static HTML matches the connected render.
        PageLoad.start(socket, requested_page, true)
      else
        assign(socket, :tasks_loading, true)
      end

    socket =
      if previous_node_ctx != nil and previous_node_ctx != socket.assigns[:tasks_node_loaded] do
        socket
        |> assign(:confirm_cancel_task_id, nil)
        |> assign(:confirm_force_kill_task_id, nil)
        # Cached per-card details belong to the OLD node: drop them so the
        # expanded cards of the new node fetch their own rows (and stale
        # in-flight results are rejected by TaskDetail's node + entry guards).
        |> assign(:task_details, %{})
      else
        socket
      end

    {:noreply, socket}
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
  def handle_info({:task_updated, task_id, _status, node} = msg, socket) do
    # New-shape task event from the "tasks" PubSub topic (node-identity
    # contract). NodeAware.handle_task_info/2 applies the node filter (drops
    # foreign-node events BEFORE the debounce) and schedules the 300ms
    # debounced :node_aware_reload_tasks. It already returns {:noreply, socket}.
    #
    # The cached per-card detail of the AFFECTED task is stale (status / usage /
    # result changed), so drop it first — only for the viewed node, and only
    # before delegating (the delegation result is passed through unchanged). An
    # expanded card refetches immediately instead of blanking.
    socket =
      if EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?(socket.assigns, node) do
        TaskDetail.invalidate(socket, task_id)
      else
        socket
      end

    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info({:task_deleted, task_id, node} = msg, socket) do
    # New-shape task-deletion event — same node filter + cache invalidation +
    # debounce treatment as {:task_updated, ...} above.
    socket =
      if EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?(socket.assigns, node) do
        TaskDetail.invalidate(socket, task_id)
      else
        socket
      end

    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    # Debounce timer fired: refresh the page task list and the sidebar's
    # running/pending tasks, then clear the debounce-pending flag.
    #
    # Serves BOTH local and remote nodes: NodeAware.handle_task_info/2
    # schedules this (trailing-edge 300ms debounce) after any node-matching
    # {:task_updated, ...} / {:task_deleted, ...} broadcast on the "tasks"
    # topic.
    #
    # The page reload goes through the ASYNC path so the LiveView process
    # never blocks on the (single, serialized) store; show_loading? false
    # keeps the stale rows visible until the fresh page arrives. Repeated
    # broadcast bursts coalesce: each spawn bumps the monotonic
    # :page_load_seq, so a superseded load's result is dropped by the
    # stale-guard in the {:tasks_page_loaded, ...} handler below, and the
    # newest in-flight load always clears :tasks_loading when it applies.
    socket = PageLoad.start(socket, socket.assigns.current_page, false)
    socket = EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.clear_task_reload_pending(socket)}
  end

  @impl true
  def handle_info({:tasks_page_loaded, seq, node, result}, socket) do
    if seq < socket.assigns.page_load_seq or node != socket.assigns.current_node do
      # Stale page-load result — a newer page load was started after this one
      # was spawned (or the user switched nodes). Drop it: the newest
      # in-flight load will apply its own result (and clear the loading
      # state). :page_load_seq is bumped ONLY by PageLoad.start/3 —
      # NodeAware's sidebar fetch keeps its own :tasks_load_seq counter, so
      # the two loads a debounced reload spawns never invalidate each other.
      {:noreply, socket}
    else
      socket = assign(socket, :tasks_loading, false)

      case result do
        {:ok, m} ->
          # :reflect tasks are excluded client-side after load (see
          # PageLoad.visible_tasks/2) — the SQL WHERE builder cannot express it.
          visible = PageLoad.visible_tasks(m.tasks, socket.assigns.show_reflect_tasks)

          socket =
            socket
            |> assign(:tasks, visible)
            |> assign(:current_page, m.current_page)
            |> assign(:total_count, m.total_count)
            |> assign(:total_pages, m.total_pages)
            |> assign(:project_paths, m.project_paths)
            |> assign(:filtered_tasks, visible)
            |> assign(:tasks_error, nil)
            # Rows are summary maps now (no result/usage/logs/archive): bound
            # the per-card detail cache to THIS page, then refetch the detail
            # of every card that is still expanded so an open card survives a
            # background refresh / pagination round-trip.
            |> TaskDetail.prune(visible)
            |> TaskDetail.ensure_expanded(visible)

          {:noreply, socket}

        {:error, reason} ->
          # Never clear already-loaded rows on a failed load: a background
          # refresh failure must not blank the page. The reason is a value
          # (SafeCall captured any exit), rendered as a retry-able error state
          # — deliberately not interpolated into the DOM.
          {:noreply, assign(socket, :tasks_error, reason)}
      end
    end
  end

  # Per-card lazy detail result (EvoDashWeb.TasksLive.TaskDetail). The module
  # applies the node + entry + seq guards; a stale/foreign result is dropped.
  @impl true
  def handle_info({:task_detail_loaded, seq, node, task_id, result}, socket) do
    {:noreply, TaskDetail.apply_detail(socket, seq, node, task_id, result)}
  end

  # Per-card lazy archive result — same guarded apply path.
  @impl true
  def handle_info({:task_archive_loaded, seq, node, task_id, result}, socket) do
    {:noreply, TaskDetail.apply_archive(socket, seq, node, task_id, result)}
  end

  # Sync-error fallback for initiate_remote_connect/2: the subsystem is
  # unavailable / the target is unknown / the manager failed to start — NO
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
          gettext("Remote connect failed: %{reason}", reason: inspect(reason))
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_tasks", params, socket) do
    status_filter = params["status_filter"] || socket.assigns.status_filter
    project_filter = params["project_filter"] || socket.assigns.project_filter

    {:noreply,
     socket
     |> assign(:status_filter, status_filter)
     |> assign(:project_filter, project_filter)
     |> PageLoad.start(1, true)}
  end

  @impl true
  def handle_event("filter_review", %{"review_filter" => filter}, socket) do
    {:noreply,
     socket
     |> assign(:review_status_filter, filter)
     |> PageLoad.start(1, true)}
  end

  @impl true
  def handle_event("search_tasks", %{"search_query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> PageLoad.start(1, true)}
  end

  # Prevents page reload when pressing Enter in the filter/search form
  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # Retry after a failed page load. The loading placeholder is shown only when
  # there is nothing on screen to keep (a failed background refresh leaves the
  # previous rows visible while the retry runs).
  @impl true
  def handle_event("retry_load", _params, socket) do
    {:noreply,
     PageLoad.start(socket, socket.assigns.current_page, socket.assigns[:filtered_tasks] == [])}
  end

  # Reveal toggle for :reflect (repo-less Home-chat) tasks, default OFF. The
  # checkbox carries value="true", so a CHECKED box sends "true" and an
  # UNCHECKED box is absent from FormData — anything other than nil/"false"
  # means checked. Deliberately only assigns show_reflect_tasks (the phx-change
  # submits the whole form, but the other filters keep their socket assigns)
  # and reloads through the same async path as the other filters.
  @impl true
  def handle_event("toggle_reflect_tasks", params, socket) do
    show = params["show_reflect_tasks"] not in [nil, "false"]

    {:noreply,
     socket
     |> assign(:show_reflect_tasks, show)
     |> PageLoad.start(1, true)}
  end

  @impl true
  def handle_event("retry_remote_connection", _params, socket) do
    # Async: initiate_remote_connect/2 spawns a supervised Task on
    # EvoDash.TaskSupervisor that runs the remote connect (NodeContext's
    # connect/1); terminal outcomes arrive via "remote_connections" PubSub
    # broadcasts, sync errors via {:remote_connect_result, target_id, {:error,
    # reason}}. Return immediately — no blocking.
    EvoDashWeb.LiveHooks.NodeAware.initiate_remote_connect(socket, socket.assigns.current_node_id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_to_local", _params, socket) do
    send(self(), {:node_selected, "local"})
    {:noreply, socket}
  end

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
     |> PageLoad.start(1, true)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "status"}, socket) do
    {:noreply,
     socket
     |> assign(:status_filter, "all")
     |> PageLoad.start(1, true)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "project"}, socket) do
    {:noreply,
     socket
     |> assign(:project_filter, "all")
     |> PageLoad.start(1, true)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "search"}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> PageLoad.start(1, true)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "review"}, socket) do
    {:noreply,
     socket
     |> assign(:review_status_filter, "all")
     |> PageLoad.start(1, true)}
  end

  @impl true
  def handle_event("goto_page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: tasks_url(socket, page))}
  end

  @impl true
  def handle_event("prev_page", _params, socket) do
    page = max(1, socket.assigns.current_page - 1)
    {:noreply, push_patch(socket, to: tasks_url(socket, page))}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    page = min(socket.assigns.total_pages, socket.assigns.current_page + 1)
    {:noreply, push_patch(socket, to: tasks_url(socket, page))}
  end

  @impl true
  def handle_event("clear_task_history", _params, socket) do
    # SafeCall captures an exit (store timeout / dead store) as a value, so a
    # slow clear flashes instead of crashing the LiveView. The reload after a
    # successful clear stays ASYNC.
    case SafeCall.run(fn ->
           EvoDash.NodeContext.clear_finished_tasks(socket.assigns.current_node)
         end) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:expanded_task_ids, MapSet.new())
         |> PageLoad.start(1, true)}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to clear task history: %{reason}", reason: inspect(reason))
         )}
    end
  end

  @impl true
  def handle_event("toggle_task_details", %{"task_id" => task_id}, socket) do
    {:noreply, TaskDetail.toggle(socket, task_id)}
  end

  # Inline "could not load this task" strip → force a refetch of that card's
  # detail (drops the cached :error entry first).
  @impl true
  def handle_event("retry_task_detail", %{"task_id" => task_id}, socket) do
    {:noreply, TaskDetail.retry(socket, task_id)}
  end

  # The expanded card's archive section asked for its records → lazy, cached
  # archive fetch (no-op while loading / already loaded).
  @impl true
  def handle_event("load_task_archive", %{"task_id" => task_id}, socket) do
    {:noreply, TaskDetail.load_archive(socket, task_id)}
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

  # Fired by the global ClipboardCopy JS hook after a successful copy.
  @impl true
  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
  end

  @impl true
  def handle_event("open_cancel_modal", %{"task_id" => task_id}, socket) do
    # Two-step graceful cancel: open the confirmation modal (and close the
    # force-kill modal if it was somehow open — only one modal at a time).
    {:noreply,
     socket
     |> assign(:confirm_cancel_task_id, task_id)
     |> assign(:confirm_force_kill_task_id, nil)}
  end

  @impl true
  def handle_event("close_cancel_modal", _params, socket) do
    {:noreply, assign(socket, :confirm_cancel_task_id, nil)}
  end

  @impl true
  def handle_event("confirm_cancel_task", _params, socket) do
    case socket.assigns[:confirm_cancel_task_id] do
      nil ->
        # Modal was never opened (or already closed) — no-op.
        {:noreply, socket}

      task_id ->
        # Synchronous single-row mutation (tests assert the store state right
        # after the click); SafeCall turns an exit (store timeout / dead store)
        # into a flash instead of a crashed LiveView.
        result =
          SafeCall.run(fn ->
            EvoDash.NodeContext.cancel_task(socket.assigns.current_node, task_id)
          end)

        case mutation_result(result) do
          :ok ->
            expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

            {:noreply,
             socket
             |> assign(:expanded_task_ids, expanded)
             |> assign(:confirm_cancel_task_id, nil)
             |> PageLoad.start(socket.assigns.current_page, false)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:confirm_cancel_task_id, nil)
             |> put_flash(
               :error,
               gettext("Failed to cancel task: %{reason}", reason: inspect(reason))
             )}
        end
    end
  end

  @impl true
  def handle_event("open_force_kill_modal", %{"task_id" => task_id}, socket) do
    # Two-step brutal cancel: open the force-kill confirmation modal (and close
    # the graceful-cancel modal if it was somehow open).
    {:noreply,
     socket
     |> assign(:confirm_force_kill_task_id, task_id)
     |> assign(:confirm_cancel_task_id, nil)}
  end

  @impl true
  def handle_event("close_force_kill_modal", _params, socket) do
    {:noreply, assign(socket, :confirm_force_kill_task_id, nil)}
  end

  @impl true
  def handle_event("confirm_force_kill_task", _params, socket) do
    case socket.assigns[:confirm_force_kill_task_id] do
      nil ->
        # Modal was never opened (or already closed) — no-op.
        {:noreply, socket}

      task_id ->
        result =
          SafeCall.run(fn ->
            EvoDash.NodeContext.force_kill_task(socket.assigns.current_node, task_id)
          end)

        case mutation_result(result) do
          :ok ->
            expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

            {:noreply,
             socket
             |> assign(:expanded_task_ids, expanded)
             |> assign(:confirm_force_kill_task_id, nil)
             |> PageLoad.start(socket.assigns.current_page, false)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:confirm_force_kill_task_id, nil)
             |> put_flash(
               :error,
               gettext("Failed to force kill task: %{reason}", reason: inspect(reason))
             )}
        end
    end
  end

  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    result =
      SafeCall.run(fn ->
        EvoDash.NodeContext.delete_task(socket.assigns.current_node, task_id)
      end)

    case mutation_result(result) do
      :ok ->
        expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

        {:noreply,
         socket
         |> assign(:expanded_task_ids, expanded)
         |> PageLoad.start(socket.assigns.current_page, false)}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to delete task: %{reason}", reason: inspect(reason))
         )}
    end
  end

  # Helpers

  # Builds a tasks URL with optional node param for pagination navigation.
  # When viewing a remote node, preserves the ?node= param so navigation
  # stays on the same node.
  defp tasks_url(socket, page) do
    node_id = socket.assigns[:current_node_id]

    if node_id do
      ~p"/tasks?page=#{page}&node=#{node_id}"
    else
      ~p"/tasks?page=#{page}"
    end
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

  # Returns a windowed range of page numbers around the current page for the
  # pagination button group. Shows up to 7 page buttons centered on the
  # current page, clamped to the valid range 1..total_pages.
  defp page_window(current_page, total_pages) do
    window = 3
    start_page = max(1, current_page - window)
    end_page = min(total_pages, current_page + window)
    Enum.to_list(start_page..end_page)
  end

  # Normalizes a SafeCall-wrapped mutating store call to `:ok | {:error, reason}`.
  # The `EvoDash.NodeContext` mutating functions return `:ok | {:error, reason}`,
  # so `SafeCall.run/1` yields `{:ok, :ok}` / `{:ok, {:error, reason}}`, while a
  # caught exit/raise (store timeout, dead store) arrives as `{:error, reason}`.
  defp mutation_result({:ok, :ok}), do: :ok
  defp mutation_result({:ok, {:error, reason}}), do: {:error, reason}
  defp mutation_result({:error, reason}), do: {:error, reason}

  defp animation_delay_class(idx) when idx <= 5, do: "animation-delay-#{div(idx, 1) * 100}"
  defp animation_delay_class(_), do: ""
end
