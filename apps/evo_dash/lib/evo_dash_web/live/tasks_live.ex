defmodule EvoDashWeb.TasksLive do
  @moduledoc """
  Cross-project task list with filtering by status, project, and review state.

  Node-aware: reads task history via `EvoDash.NodeContext` so it works for both
  the local BEAM node and a remote `genesis_remote` daemon (SSH Remote
  Development, Phase 3). For remote nodes it polls periodically since
  cross-node PubSub may be unreliable.
  """
  use EvoDashWeb, :live_view
  use Gettext, backend: EvoDashWeb.Gettext
  use EvoDashWeb.ModalHelpers

  alias EvoDashWeb.TasksLive.DirtyTracker

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
    >
      <%= if EvoDashWeb.RemoteGateComponents.gate_active?(assigns) do %>
        {EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns)}
      <% else %>
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
                  class="select select-bordered select-md rounded-md bg-base-100 sm:w-48 focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary"
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
                  class="select select-bordered select-md rounded-md bg-base-100 sm:w-48 focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary"
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
           count flashes "0 tasks found" during every filter/navigation) -->
        <%= if not @tasks_loading do %>
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

        <!-- Task List -->
        <div class="space-y-4 lg:space-y-5">
          <%= if @tasks_loading do %>
            <div class="text-center py-12 sm:py-16 text-base-content/50">
              <.icon name="hero-arrow-path" class="size-10 mx-auto mb-4 opacity-50 animate-spin" />
              <p class="text-lg font-medium">{gettext("Loading tasks...")}</p>
            </div>
          <% else %>
            <%= if @filtered_tasks == [] do %>
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
              <%= for {task, idx} <- Enum.with_index(@filtered_tasks) do %>
                <div class={[
                  "relative z-10 has-[[open]]:z-30 animate-fade-in-up",
                  animation_delay_class(idx)
                ]}>
                  <EvoDashWeb.TaskCardComponents.task_card
                    task={task}
                    show_details={MapSet.member?(@expanded_task_ids, task.id)}
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
          <button
            type="button"
            class="btn btn-ghost btn-sm text-error/60 hover:text-error gap-1"
            phx-click="clear_task_history"
            phx-confirm={gettext("Clear all finished task history? This cannot be undone.")}
          >
            <.icon name="hero-trash" class="size-3.5" /> {gettext("Clear History")}
          </button>
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

        <!-- Cancel Task confirmation modal (graceful: agents save + exit) -->
        <%= if @confirm_cancel_task_id do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
            <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="close_cancel_modal">
            </div>
            <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-200 max-w-lg w-full p-6 md:p-8">
              <div class="flex items-center gap-3 mb-4">
                <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
                <h3 class="text-lg font-bold">{gettext("Cancel Task?")}</h3>
              </div>

              <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
                {gettext(
                  "All agents of this task will be informed to immediately save their changes and exit. Intermediate results will be saved."
                )}
              </p>
              <p class="text-xs text-base-content/40 mb-5">
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
            <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-200 max-w-lg w-full p-6 md:p-8">
              <div class="flex items-center gap-3 mb-4">
                <.icon name="hero-exclamation-triangle" class="size-5 text-error" />
                <h3 class="text-lg font-bold">{gettext("Force Kill Task?")}</h3>
              </div>

              <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
                {gettext(
                  "Immediately stops the task and all of its agents. ALL progress will be completely lost. This cannot be undone."
                )}
              </p>
              <p class="text-xs text-base-content/40 mb-5">
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

    # Project paths are cheap-ish and needed for the filter dropdown regardless
    # of pagination. Tasks are loaded in handle_params (server-side pagination).
    # At mount time the node is local (set by the NodeAware on-mount hook before
    # mount), so we read the node defensively.
    node = socket.assigns[:current_node] || node()
    project_paths = EvoDash.NodeContext.get_unique_paths(node)

    config_status = config_status()

    socket =
      socket
      |> assign(
        tasks: [],
        project_paths: project_paths,
        status_filter: "all",
        project_filter: "all",
        search_query: "",
        review_status_filter: "all",
        expanded_task_ids: MapSet.new(),
        selected_result: nil,
        selected_options: nil,
        confirm_cancel_task_id: nil,
        confirm_force_kill_task_id: nil,
        config_status: config_status,
        current_page: 1,
        page_size: @default_page_size,
        total_count: 0,
        total_pages: 1,
        # Dirty-check state for remote-node polling; seeded in handle_params
        # (never used on the local node).
        dirty_tracker: nil,
        # Async page-load state: tasks_load_seq is the monotonic spawn counter
        # for the in-flight page-load task (stale-guard), tasks_loading drives
        # the loading placeholder.
        tasks_load_seq: 0,
        tasks_loading: false,
        # Monotonic spawn counter for the remote-poll dirty-check tasks
        # (stale-guard for out-of-order tick results).
        poll_seq: 0
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

    # The dirty tracker is seeded (async, inside the page-load task) only when
    # it is missing or bound to a different node — pagination/filter
    # push_patches keep the same node, so the tracker is left untouched (no
    # extra summary fetch per page turn).
    seed? =
      (tracker = socket.assigns[:dirty_tracker]) == nil or
        tracker.node != socket.assigns.current_node

    socket = start_async_page_load(socket, requested_page, seed?, true)

    socket =
      if previous_node_ctx != nil and previous_node_ctx != socket.assigns[:tasks_node_loaded] do
        socket
        |> assign(:confirm_cancel_task_id, nil)
        |> assign(:confirm_force_kill_task_id, nil)
      else
        socket
      end

    current_node = socket.assigns.current_node

    # For remote nodes, cross-node PubSub may not deliver task-status events
    # reliably. Start a periodic poll (reschedules itself in the handler only
    # while viewing a remote node). For the local node we rely on PubSub, so no
    # poll is scheduled. Guard with the :remote_poll_timer assign so we don't
    # schedule overlapping timers on repeated handle_params calls.
    socket =
      if current_node != node() and connected?(socket) and
           !socket.assigns[:remote_poll_timer] do
        Process.send_after(self(), :remote_poll, 3_000)
        assign(socket, :remote_poll_timer, true)
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
  def handle_info({:tasks_updated} = msg, socket) do
    # Debounced via NodeAware — the page refresh + sidebar reload happen once in
    # handle_info(:node_aware_reload_tasks, socket) when the debounce timer fires.
    # handle_task_info/2 already returns {:noreply, socket}.
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info({:task_status, _task_id, _status} = msg, socket) do
    # Task status transitions (e.g. :finalizing, :running) are broadcast on the
    # "tasks" PubSub topic. Re-fetch the current page so the UI reflects the change.
    # Debounced via NodeAware — see handle_info(:node_aware_reload_tasks, socket).
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    # Debounce timer fired: refresh the page task list and the sidebar's
    # running/pending tasks, then clear the debounce-pending flag.
    #
    # NOTE: the dirty tracker is deliberately NOT advanced here — the next
    # :remote_poll tick re-detects the change and self-corrects, so at most
    # one redundant full reload happens (local nodes don't use the tracker).
    socket = reload_current_page(socket)
    socket = EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.clear_task_reload_pending(socket)}
  end

  @impl true
  def handle_info({:tasks_page_loaded, seq, node, result}, socket) do
    if seq < socket.assigns.tasks_load_seq or node != socket.assigns.current_node do
      # Stale page-load result — a newer load was started after this one was
      # spawned (or the user switched nodes). Drop it: the newest in-flight
      # load will apply its own result (and clear the loading state).
      {:noreply, socket}
    else
      socket = assign(socket, :tasks_loading, false)

      case result do
        {:ok, m} ->
          socket =
            socket
            |> assign(:tasks, m.tasks)
            |> assign(:current_page, m.current_page)
            |> assign(:total_count, m.total_count)
            |> assign(:total_pages, m.total_pages)
            |> assign(:project_paths, m.project_paths)
            |> assign(:filtered_tasks, m.tasks)

          socket =
            if m.ids_snapshot != nil do
              maybe_seed_tracker(socket, m.ids_snapshot)
            else
              socket
            end

          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to load tasks."))}
      end
    end
  end

  @impl true
  def handle_info(:remote_poll, socket) do
    current_node = socket.assigns.current_node

    if current_node != node() do
      # Still viewing a remote node — reschedule FIRST (steady 3s cadence even
      # while a dirty-check task is in flight, system_live precedent), then
      # spawn the dirty check async. Each tick transfers only the lightweight
      # `list_task_ids` snapshot (3 keys per row: id/status/updated_at) over
      # `:erpc`; the full page of TaskInfo structs is fetched only when the
      # tracker reports :reload or :resync.
      Process.send_after(self(), :remote_poll, 3_000)

      seq = socket.assigns.poll_seq + 1
      socket = assign(socket, :poll_seq, seq)

      parent = self()
      statuses = statuses_for_filter(socket.assigns.status_filter)

      Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
        ids =
          try do
            EvoDash.NodeContext.list_task_ids(current_node, statuses)
          rescue
            # (1) Do we expect this error? YES — the tick crosses the node
            #     boundary: the remote daemon may be dead/disappearing
            #     mid-poll.
            # (2) Is try/rescue the cleanest approach? YES — without it the
            #     tick wedges and the 3s poll chain dies; an empty snapshot is
            #     the safe fallback (the tracker treats it as no-change).
            _ -> []
          end

        send(parent, {:tasks_poll_result, seq, current_node, ids})
      end)

      {:noreply, socket}
    else
      # Switched back to local — stop polling (PubSub handles local updates).
      {:noreply, assign(socket, :remote_poll_timer, false)}
    end
  end

  @impl true
  def handle_info({:tasks_poll_result, seq, node, ids}, socket) do
    if seq < socket.assigns.poll_seq or node != socket.assigns.current_node do
      # Stale/out-of-order tick result (older spawn or a previously-viewed
      # node) — drop it. Ticks never overlap in the LiveView (seq is
      # monotonic), so a dropped result is never the latest one.
      {:noreply, socket}
    else
      socket = maybe_seed_tracker(socket, ids)

      tracker = socket.assigns[:dirty_tracker]
      {action, tracker} = DirtyTracker.evaluate(tracker, ids)
      socket = assign(socket, :dirty_tracker, tracker)

      case action do
        :noop ->
          # Steady state — nothing changed, no full page transfer.
          {:noreply, socket}

        :reload ->
          # Something changed — reload in the background (no loading state;
          # stale data stays until fresh arrives).
          {:noreply, start_async_page_load(socket, socket.assigns.current_page, false, false)}

        :resync ->
          # Periodic full re-sync (deletion safeguard) — same background
          # reload as :reload.
          {:noreply, start_async_page_load(socket, socket.assigns.current_page, false, false)}
      end
    end
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
     |> start_async_page_load(1, false, true)}
  end

  @impl true
  def handle_event("filter_review", %{"review_filter" => filter}, socket) do
    {:noreply,
     socket
     |> assign(:review_status_filter, filter)
     |> start_async_page_load(1, false, true)}
  end

  @impl true
  def handle_event("search_tasks", %{"search_query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> start_async_page_load(1, false, true)}
  end

  # Prevents page reload when pressing Enter in the filter/search form
  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry_remote_connection", _params, socket) do
    EvoDash.NodeContext.connect(socket.assigns.current_node_id)
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
     |> start_async_page_load(1, false, true)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "status"}, socket) do
    {:noreply,
     socket
     |> assign(:status_filter, "all")
     |> start_async_page_load(1, false, true)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "project"}, socket) do
    {:noreply,
     socket
     |> assign(:project_filter, "all")
     |> start_async_page_load(1, false, true)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "search"}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> start_async_page_load(1, false, true)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "review"}, socket) do
    {:noreply,
     socket
     |> assign(:review_status_filter, "all")
     |> start_async_page_load(1, false, true)}
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
    EvoDash.NodeContext.clear_finished_tasks(socket.assigns.current_node)

    {:noreply,
     socket
     |> assign(:expanded_task_ids, MapSet.new())
     |> sync_apply_page(1)}
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
        case EvoDash.NodeContext.cancel_task(socket.assigns.current_node, task_id) do
          :ok ->
            expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

            {:noreply,
             socket
             |> assign(:expanded_task_ids, expanded)
             |> assign(:confirm_cancel_task_id, nil)
             |> reload_current_page()}

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
        case EvoDash.NodeContext.force_kill_task(socket.assigns.current_node, task_id) do
          :ok ->
            expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

            {:noreply,
             socket
             |> assign(:expanded_task_ids, expanded)
             |> assign(:confirm_force_kill_task_id, nil)
             |> reload_current_page()}

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
    EvoDash.NodeContext.delete_task(socket.assigns.current_node, task_id)
    expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

    {:noreply,
     socket
     |> assign(:expanded_task_ids, expanded)
     |> reload_current_page()}
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

  # Fetches one page of tasks (server-side LIMIT/OFFSET). Returns
  # {tasks, clamped_page, total_count, total_pages}. The requested page is
  # clamped against the actual total_pages derived from the returned count.
  # If clamping changes the page, a second fetch is performed for the
  # clamped page. This is at most one extra fetch and only on edge cases
  # (e.g. a stale/high page number).
  defp load_page(node, requested_page, page_size, filters) do
    offset = (requested_page - 1) * page_size

    {tasks, total_count} =
      EvoDash.NodeContext.list_tasks_paginated(node,
        limit: page_size,
        offset: offset,
        filters: filters
      )

    total_pages = total_pages(total_count, page_size)
    clamped_page = min(max(1, requested_page), total_pages)

    if clamped_page != requested_page do
      clamped_offset = (clamped_page - 1) * page_size

      {clamped_tasks, ^total_count} =
        EvoDash.NodeContext.list_tasks_paginated(node,
          limit: page_size,
          offset: clamped_offset,
          filters: filters
        )

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

  # Reloads the current page's tasks synchronously (no loading state, no seq
  # bump). Used by mutating events (cancel/force-kill/delete/clear-history)
  # and the :node_aware_reload_tasks PubSub debounce so the UI reflects
  # changes immediately — the remote-poll path reloads async instead.
  defp reload_current_page(socket) do
    sync_apply_page(socket, socket.assigns.current_page)
  end

  # Synchronous fetch + apply of one page: the page of tasks, the pagination
  # counters, the project paths, and the filtered view. Deliberately does NOT
  # touch :tasks_loading or :tasks_load_seq (the async page-load path owns
  # those).
  defp sync_apply_page(socket, page) do
    node = socket.assigns.current_node
    filters = build_filters_from_assigns(socket)

    {tasks, current_page, total_count, total_pages} =
      load_page(node, page, socket.assigns.page_size, filters)

    socket
    |> assign(:tasks, tasks)
    |> assign(:current_page, current_page)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:project_paths, EvoDash.NodeContext.get_unique_paths(node))
    |> assign(:filtered_tasks, tasks)
  end

  # Spawns one async page load in a supervised Task (same pattern as
  # review_live's start_async_load/2 and SettingsLive's LLM test) so the
  # LiveView never blocks on cross-node RPCs. The result arrives later as a
  # `{:tasks_page_loaded, seq, node, result}` message; `tasks_load_seq` is
  # monotonic (incremented per spawn), so stale results from superseded loads
  # are dropped by the handle_info stale-guard.
  #
  # When `seed?`, the task ALSO fetches the `list_task_ids` snapshot (3-key
  # id/status/updated_at projection, status-filtered) for the dirty tracker —
  # this is the handle_params seed on node switch (tracker missing or bound to
  # a different node). `show_loading?` controls the loading placeholder:
  # user-initiated loads (handle_params, filters) show it; background refresh
  # reloads from the remote poll do not (no UI flash every ~30s resync — stale
  # data stays until the fresh page arrives).
  defp start_async_page_load(socket, page, seed?, show_loading?) do
    seq = socket.assigns.tasks_load_seq + 1
    socket = assign(socket, :tasks_load_seq, seq)
    socket = if show_loading?, do: assign(socket, :tasks_loading, true), else: socket

    parent = self()
    node = socket.assigns.current_node
    page_size = socket.assigns.page_size
    filters = build_filters_from_assigns(socket)
    statuses = statuses_for_filter(filters[:status])

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result =
        try do
          ids =
            if seed? do
              EvoDash.NodeContext.list_task_ids(node, statuses)
            else
              nil
            end

          {tasks, current_page, total_count, total_pages} =
            load_page(node, page, page_size, filters)

          paths = EvoDash.NodeContext.get_unique_paths(node)

          {:ok,
           %{
             tasks: tasks,
             current_page: current_page,
             total_count: total_count,
             total_pages: total_pages,
             project_paths: paths,
             ids_snapshot: ids
           }}
        rescue
          # (1) Do we expect this error? YES — the load crosses the node
          #     boundary: the RPC target may be a dead/disappearing remote
          #     daemon, or the task store may be mid-restart.
          # (2) Is try/rescue the cleanest approach? YES — without it the page
          #     would wedge at the loading state forever with no message;
          #     mirrors the justified rescue in review_live.ex
          #     start_async_load/2.
          _ -> {:error, :load_failed}
        end

      send(parent, {:tasks_page_loaded, seq, node, result})
    end)

    socket
  end

  # Seeds the dirty tracker when it is missing or bound to a different node.
  # Belt-and-braces: normally the page-load seed (handle_params on node
  # switch) already bound it; if not (e.g. the LiveView was mounted before
  # this feature, or the first load's result raced), the poll result seeds now
  # so the baseline is never nil. No-op otherwise — preserves the "no reseed
  # on pagination/filter" behavior (the tracker keeps advancing across them).
  defp maybe_seed_tracker(socket, ids) do
    current_node = socket.assigns.current_node
    tracker = socket.assigns[:dirty_tracker]

    if is_nil(tracker) or tracker.node != current_node do
      assign(
        socket,
        :dirty_tracker,
        DirtyTracker.seed(DirtyTracker.new(), current_node, ids)
      )
    else
      socket
    end
  end

  # Whitelist lookup (per codebase atom policy — never String.to_atom) from a
  # status-filter string to the status atoms used by `list_task_ids`. "all"
  # and unknown values map to `[]` (all statuses).
  @statuses_by_filter %{
    "running" => [:running],
    "pending" => [:pending],
    "cancelling" => [:cancelling],
    "completed" => [:completed],
    "failed" => [:failed],
    "cancelled" => [:cancelled]
  }

  defp statuses_for_filter(status) do
    Map.get(@statuses_by_filter, status, [])
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
