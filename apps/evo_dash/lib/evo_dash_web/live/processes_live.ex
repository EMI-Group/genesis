defmodule EvoDashWeb.ProcessesLive do
  @moduledoc """
  Managed-process inspector: every execution `EvoGit.ProcessManager` tracks on
  the viewed node — built-in tool calls that run in-process (no OS process),
  external commands and background jobs — with its live resource usage.
  External OS processes additionally carry the operator controls
  (pause / resume / terminate / kill); a built-in in-BEAM execution has no OS
  process handle, so it renders no controls.

  Node-aware like every other dashboard page: the initial snapshot is fetched
  from `@current_node` and liveness is PUSH-based. `EvoGit.ProcessManager`
  broadcasts on the `EvoGit.PubSub` `"processes"` topic:

    * `{:process_started, execution, node}`
    * `{:process_updated, id, changes, node}`
    * `{:process_exited, execution, node}`
    * `{:process_sample, node, seq, entries}`
    * `{:process_control, id, entry, node}`

  Each event carries the emitting BEAM node and is dropped unless it matches
  the node the user is currently viewing
  (`EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?/2`), so a local and
  a remote dashboard never mix their process tables. There is NO polling: the
  page loads once per node/core-filter change and then applies the broadcasts.

  No LiveView process blocks on an RPC — neither for data nor for controls.
  The initial load runs in a supervised task
  (`EvoDashWeb.ProcessesLive.Load`) inside `EvoDash.SafeCall.run/1` and lands
  as `{:processes_loaded, seq, node, result}`; every control action
  (pause / resume / terminate / kill) is spawned through
  `EvoDash.SafeCall.start/3` and lands as
  `{{:process_control_result, id, action}, result}`, so a slow or dead manager
  (or remote node) can never freeze the socket. A per-row `:action_busy` map
  drops a duplicate click while its call is still in flight and is cleared on
  EVERY outcome, success or failure.

  Filters are URL state (`?status=`, `?kind=`, `?q=`, `?agent_id=`,
  `?task_id=`, plus `node`): status/kind/text narrow the already-loaded rows
  (`EvoDashWeb.ProcessesLive.Format.filter/2`), while `agent_id`/`task_id`
  narrow the tracked set itself and therefore refetch.

  ## Derived render state

  `:filtered`, `:counts` and `:filters_active` are never computed in
  `render/1`. ONE private `recompute/1` derives all three from the current
  `:executions` and filter assigns, and every place that mutates either —
  the load result, every `"processes"` broadcast, the enter-animation clear
  and `handle_params/3` — calls it once, so a 3-second sample tick re-filters
  the list once (or not at all when the sample changed no row) instead of
  twice per render.

  ## Keyed row stream

  The table body is a LiveView STREAM (`phx-update="stream"`,
  `id="processes-rows"`), so a broadcast patches ONE row instead of diffing
  the whole list. `:executions` stays a plain list — it is the source
  `recompute/1` and every merge helper read — while `@streams.executions` is
  the render projection only. The stream `dom_id` is `row_dom_id/1`, which
  mirrors the `<tr>` id the row component derives from the same record
  (`process-row-<id>`, `process-row-unknown` when the id is nil), and the
  DOM declares the `ListEnter` hook scope around the table.

  Membership is kept EXACTLY equal to `:filtered` by two operations:
  `stream_reset/1` replaces the whole stream from `:filtered` (the load
  result, a node switch and every filter change — the same places that clear
  the enter animation) and `stream_touch/2` patches only the ids ONE push
  event touched, inserting a still-visible row from `:filtered` and
  deleting a row that is now filtered out. A push NEVER bulk-inserts the
  filtered list, and `update_executions/3` drops the ids whose row the event
  left byte-identical, so an unchanged 3-second sample re-renders nothing.

  ## Row enter animation

  A row that arrives AFTER the initial snapshot — a genuinely new id, i.e. one
  the page does not already show — is rendered with the `process-row-enter`
  class (`EvoDashWeb.ProcessComponents.execution_row/1`'s `entering` attr) for
  one TTL, then cleared by a `{:clear_entering, ids}` self-message. The initial
  load, a refetch, a Retry and a node/core-filter switch NEVER animate (they
  replace the whole stream), and a later `{:process_sample, ...}` /
  `{:process_updated, ...}` patch for an already-cleared id cannot bring the
  class back.

  The TTL is read AT CALL TIME from
  `Application.get_env(:evo_dash, :processes_entering_ttl_ms, 1500)` — the
  default is 1500 ms; the key exists as a TEST seam (production never sets it),
  and a non-integer/negative value falls back to the default. Timers are only
  scheduled on a connected socket, so the static render arms none.
  """

  use EvoDashWeb, :live_view
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDash.SafeCall
  alias EvoDashWeb.LiveHooks.NodeAware
  alias EvoDashWeb.ProcessComponents
  alias EvoDashWeb.ProcessesLive.Actions
  alias EvoDashWeb.ProcessesLive.Format
  alias EvoDashWeb.ProcessesLive.Load

  @processes_topic "processes"

  # How long a newly joined row keeps the enter-animation class. Overridable at
  # call time through `Application.get_env(:evo_dash, :processes_entering_ttl_ms)`
  # (test seam only — production never sets it).
  @default_entering_ttl_ms 1500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, @processes_topic)
    end

    # No load in mount: the node context is not resolved until handle_params/3
    # (the ?node= param lives on the URL), so a mount-time fetch would always
    # query the LOCAL node.
    socket =
      socket
      |> seed_layout_assigns()
      |> assign(
        # `Layouts.app` reads `@config_status` on EVERY render (dead render
        # included), so the page must own the assign — an unset one raises
        # KeyError before the first paint. Resolved here like the other pages
        # (local read of config.toml, no RPC).
        page_title: gettext("Processes"),
        config_status: config_status(),
        executions: [],
        executions_loading: false,
        executions_error: nil,
        executions_loaded: false,
        load_seq: 0,
        status_filter: "live",
        kind_filter: "all",
        search_query: "",
        agent_filter: nil,
        task_filter: nil,
        # Derived from :executions + the filter assigns by recompute/1 only.
        filtered: [],
        counts: %{live: 0, finished: 0, all: 0},
        filters_active: false,
        expanded: MapSet.new(),
        # String ids of rows that arrived AFTER the initial snapshot; each one
        # renders with the enter-animation class until its own TTL expires.
        entering: MapSet.new(),
        # Row ids (Format.id_string/1) whose control call is still in flight;
        # a second click on such a row is dropped instead of posting a
        # duplicate control. Cleared on every outcome.
        action_busy: %{},
        confirm: nil,
        confirm_reason: "",
        confirm_error: nil
      )

    # The table body is a keyed stream: `dom_id` is configured ONCE, before the
    # stream exists (LiveView refuses a later re-configure), and the empty
    # creation here guarantees every later `stream_insert/3` has a stream to
    # patch. `:executions` above stays the plain list `recompute/1` reads.
    {:ok,
     socket |> stream_configure(:executions, dom_id: &row_dom_id/1) |> stream(:executions, [])}
  end

  # Assigns owned by the `NodeAware` / `Appearance` / `DesktopQuit` /
  # `UpdateStatus` / `Guide` on-mount hooks. They run BEFORE this mount, so
  # `assign_new/3` never overwrites them — the seeds only keep a render total
  # when a page is mounted without those hooks (a bare component test), so no
  # assign is read through a `||` fallback.
  defp seed_layout_assigns(socket) do
    Enum.reduce(
      [
        current_node: node(),
        current_node_name: "Local",
        current_node_id: nil,
        remote_status: nil,
        remote_targets: [],
        connection_statuses: %{},
        running_tasks: [],
        pending_tasks: [],
        session_list: [],
        session_list_loading: false,
        session_list_error: nil,
        current_session_id: nil,
        accent_color: "blue",
        desktop_quit_confirm: false,
        update_status: nil,
        guide: nil
      ],
      socket,
      fn {key, value}, acc -> assign_new(acc, key, fn -> value end) end
    )
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Capture the node + CORE-side filters BEFORE `assign_node/2` so a node or
    # filter change can drop the previous node's rows and any open confirmation
    # modal (a terminate modal opened on one node must never be confirmed
    # against another).
    previous =
      {socket.assigns.current_node, socket.assigns.agent_filter, socket.assigns.task_filter}

    socket =
      socket
      |> NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/processes")
      |> assign(:status_filter, Format.normalize_status_tab(string_param(params["status"])))
      |> assign(:kind_filter, Format.normalize_kind(string_param(params["kind"])))
      |> assign(:search_query, string_param(params["q"]) || "")
      |> assign(:agent_filter, string_param(params["agent_id"]))
      |> assign(:task_filter, string_param(params["task_id"]))

    current =
      {socket.assigns.current_node, socket.assigns.agent_filter, socket.assigns.task_filter}

    socket =
      if current != previous do
        # A node or core-filter switch replaces the whole table, so nothing on
        # screen is "newly joined": drop the previous node's rows, any open
        # confirmation modal and every pending enter animation.
        assign(socket,
          executions: [],
          executions_loaded: false,
          entering: MapSet.new(),
          expanded: MapSet.new(),
          action_busy: %{},
          confirm: nil
        )
      else
        socket
      end

    # The filters just changed (or the table was emptied): derive the render
    # state once, here, instead of on every render. The stream is REBUILT from
    # the new `:filtered` (a filter/node switch replaces the whole table, so no
    # row may keep a stale element), which also drops any enter animation.
    socket = socket |> recompute() |> stream_reset()

    cond do
      # The disconnected (static HTTP) render's async result is discarded, so
      # only the connected pass issues an RPC; the static HTML still paints the
      # loading placeholder so both renders match.
      not connected?(socket) ->
        {:noreply, assign(socket, :executions_loading, true)}

      socket.assigns.executions_loaded ->
        {:noreply, socket}

      true ->
        {:noreply, Load.start(socket)}
    end
  end

  # ---------------------------------------------------------------------------
  # Load result
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:processes_loaded, seq, node, result}, socket) do
    # Stale guards: a later load (filter/node change) bumps :load_seq, and a
    # node switch changes :current_node — either way the answer is obsolete.
    if seq != socket.assigns.load_seq or node != socket.assigns.current_node do
      {:noreply, socket}
    else
      {:noreply, apply_load_result(socket, result)}
    end
  end

  # ---------------------------------------------------------------------------
  # "processes" PubSub events (node-filtered, never a poll)
  # ---------------------------------------------------------------------------

  def handle_info({:process_started, execution, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, upsert_execution(socket, execution, &prepend_execution/2)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:process_updated, id, changes, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and is_map(changes) do
      {:noreply, update_executions(socket, &update_execution(&1, id, changes), [id])}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:process_exited, execution, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, upsert_execution(socket, execution, &put_execution/2)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:process_sample, node, _seq, entries}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, update_executions(socket, &apply_sample(&1, entries), sample_ids(entries))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:process_control, id, entry, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and is_map(entry) do
      {:noreply, update_executions(socket, &append_control_entry(&1, id, entry), [id])}
    else
      {:noreply, socket}
    end
  end

  # Async control outcome (`EvoDash.SafeCall.start/3`): the RPC ran off-process,
  # so the socket stayed answerable for its whole duration.
  def handle_info({{:process_control_result, id, action}, result}, socket) do
    {:noreply, apply_control_result(socket, id, action, result)}
  end

  # Enter-animation expiry: drop exactly the ids whose TTL elapsed, so a later
  # patch of that row can never re-run the animation. Only the rows that lost
  # the class are re-sent — every other row is untouched.
  def handle_info({:clear_entering, ids}, socket) when is_list(ids) do
    entering = socket.assigns.entering
    cleared = Enum.filter(ids, &MapSet.member?(entering, &1))

    {:noreply,
     socket
     |> assign(:entering, MapSet.difference(entering, MapSet.new(ids)))
     |> recompute()
     |> stream_touch(cleared)}
  end

  # ---------------------------------------------------------------------------
  # Node-context plumbing (NodeAware owns the resolution)
  # ---------------------------------------------------------------------------

  def handle_info({:node_selected, node_id}, socket) do
    NodeAware.handle_node_selected(socket, node_id)
  end

  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    NodeAware.handle_connection_status(socket, msg)
  end

  def handle_info({:remote_connect_result, target_id, {:error, reason}}, socket) do
    if target_id == socket.assigns.current_node_id do
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Remote connect failed: %{reason}", reason: Format.term_text(reason))
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Row expansion + reversible controls
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_process_row", params, socket) do
    case id_param(params) do
      nil ->
        {:noreply, socket}

      id ->
        # `expanded` is a render attribute of the streamed row, so the row has
        # to be re-inserted into the stream for the disclosure to show up.
        {:noreply,
         socket
         |> assign(:expanded, toggle_expanded(socket.assigns.expanded, id))
         |> stream_touch([id])}
    end
  end

  def handle_event("pause_process", params, socket) do
    {:noreply, run_reversible_control(socket, params, :pause)}
  end

  def handle_event("resume_process", params, socket) do
    {:noreply, run_reversible_control(socket, params, :resume)}
  end

  def handle_event("open_terminate", params, socket) do
    {:noreply, open_confirm(socket, params, :terminate)}
  end

  def handle_event("open_kill", params, socket) do
    {:noreply, open_confirm(socket, params, :kill)}
  end

  def handle_event("close_confirm", _params, socket) do
    {:noreply, assign(socket, confirm: nil, confirm_reason: "", confirm_error: nil)}
  end

  def handle_event("confirm_control", %{"reason" => reason}, socket) do
    {:noreply, confirm_control(socket, reason)}
  end

  def handle_event("confirm_control", _params, socket) do
    {:noreply, confirm_control(socket, "")}
  end

  def handle_event("retry", _params, socket) do
    {:noreply, Load.start(socket)}
  end

  def handle_event("retry_remote_connection", _params, socket) do
    {:noreply, NodeAware.initiate_remote_connect(socket, socket.assigns.current_node_id)}
  end

  def handle_event("switch_to_local", _params, socket) do
    NodeAware.handle_node_selected(socket, "local")
  end

  # ---------------------------------------------------------------------------
  # Filter events — every one is a push_patch, so the URL stays the state
  # ---------------------------------------------------------------------------

  def handle_event("set_status", %{"status" => status}, socket) do
    {:noreply,
     push_patch(socket, to: filters_url(socket, %{status: Format.normalize_status_tab(status)}))}
  end

  def handle_event("set_kind", %{"kind" => kind}, socket) do
    {:noreply, push_patch(socket, to: filters_url(socket, %{kind: Format.normalize_kind(kind)}))}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, push_patch(socket, to: filters_url(socket, %{q: query}))}
  end

  def handle_event("remove_agent_filter", _params, socket) do
    {:noreply, push_patch(socket, to: filters_url(socket, %{agent_id: nil}))}
  end

  def handle_event("remove_task_filter", _params, socket) do
    {:noreply, push_patch(socket, to: filters_url(socket, %{task_id: nil}))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: filters_url(socket, %{kind: "all", q: nil, agent_id: nil, task_id: nil})
     )}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    # NO filtering here: `:filtered`, `:counts` and `:filters_active` are
    # derived by recompute/1 whenever the rows or a filter change (see the
    # moduledoc), so a render — which runs on every 3-second sample tick — is
    # a pure read of already-computed assigns.
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:processes}
      config_status={@config_status}
      current_node_id={@current_node_id}
      remote_targets={@remote_targets}
      connection_statuses={@connection_statuses}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      session_list={@session_list}
      session_list_loading={@session_list_loading}
      session_list_error={@session_list_error}
      current_session_id={@current_session_id}
      pending_tasks={@pending_tasks}
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
      accent_color={@accent_color}
    >
      <header class="mb-5">
        <h1 class="text-xl font-semibold text-base-content">{gettext("Processes")}</h1>
        <p
          :if={!EvoDashWeb.RemoteGateComponents.gate_active?(assigns)}
          class="mt-1 text-sm text-base-content/70"
        >
          {gettext("Monitor tool calls and background jobs on this node.")}
        </p>
      </header>
      <%= if EvoDashWeb.RemoteGateComponents.gate_active?(assigns) do %>
        {EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns)}
      <% else %>
        <!-- Filter bar -->
        <div class="rounded-lg border border-base-300 bg-base-100 p-3 sm:p-4 mb-4">
          <div class="flex flex-col lg:flex-row lg:items-center gap-3">
            <div
              class="flex flex-wrap items-center gap-1 rounded-lg bg-base-200/60 p-1"
              aria-label={gettext("Process status")}
              role="group"
            >
              <button
                :for={tab <- Format.status_tabs()}
                type="button"
                phx-click="set_status"
                phx-value-status={tab}
                class={[
                  "min-h-[var(--control-h-sm)] pointer-coarse:min-h-[var(--touch-target)] flex-1 px-3 py-1.5 rounded-md text-sm font-medium cursor-pointer transition-colors whitespace-nowrap",
                  @status_filter == tab && "bg-base-100 shadow-sm text-base-content",
                  @status_filter != tab &&
                    "hover:bg-base-200/80 text-base-content/70 hover:text-base-content"
                ]}
                aria-current={if @status_filter == tab, do: "page", else: false}
              >
                {status_tab_label(tab)}
                <span class="ml-1 text-xs text-base-content/60">{status_tab_count(@counts, tab)}</span>
              </button>
            </div>

            <.form
              for={to_form(%{"kind" => @kind_filter})}
              id="process-kind-filter"
              phx-change="set_kind"
              class="form-control"
            >
              <select
                name="kind"
                class="select select-bordered w-full rounded-md bg-base-100 lg:w-44"
                aria-label={gettext("Process kind")}
              >
                <option value="all" selected={@kind_filter == "all"}>
                  {gettext("All kinds")}
                </option>
                <option value="tool_call" selected={@kind_filter == "tool_call"}>
                  {gettext("Tool calls")}
                </option>
                <option value="background_job" selected={@kind_filter == "background_job"}>
                  {gettext("Background jobs")}
                </option>
              </select>
            </.form>

            <.form
              for={to_form(%{"q" => @search_query})}
              id="process-search"
              phx-change="search"
              phx-submit="search"
              class="flex-1 min-w-0"
            >
              <input
                type="search"
                name="q"
                phx-debounce="200"
                value={@search_query}
                placeholder={gettext("Search processes")}
                class="input input-bordered w-full rounded-md"
                aria-label={gettext("Search processes")}
              />
            </.form>
          </div>

          <!-- Active core-side filters -->
          <div
            :if={@agent_filter != nil or @task_filter != nil}
            class="flex items-center flex-wrap gap-2 mt-3 pt-3 border-t border-base-300"
          >
            <span class="text-xs text-base-content/70">{gettext("Filters:")}</span>
            <span
              :if={@agent_filter != nil}
              class="inline-flex max-w-full items-center gap-1 rounded-md bg-base-200 pl-2 text-xs font-mono"
            >
              <span class="min-w-0 break-all">{gettext("Agent")} {@agent_filter}</span>
              <button
                type="button"
                phx-click="remove_agent_filter"
                class="inline-flex size-8 shrink-0 cursor-pointer items-center justify-center rounded-md hover:bg-base-300"
                aria-label={gettext("Remove agent filter")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </span>
            <span
              :if={@task_filter != nil}
              class="inline-flex max-w-full items-center gap-1 rounded-md bg-base-200 pl-2 text-xs font-mono"
            >
              <span class="min-w-0 break-all">{gettext("Task")} {@task_filter}</span>
              <button
                type="button"
                phx-click="remove_task_filter"
                class="inline-flex size-8 shrink-0 cursor-pointer items-center justify-center rounded-md hover:bg-base-300"
                aria-label={gettext("Remove task filter")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </span>
          </div>
        </div>

        <!-- First-load placeholder -->
        <div
          :if={@executions_loading and @executions == []}
          role="status"
          class="rounded-lg border border-base-300 px-4 py-10 text-center sm:py-14"
        >
          <.icon
            name="hero-arrow-path"
            class="size-10 mx-auto mb-4 text-base-content/40 animate-spin"
          />
          <p class="text-lg font-semibold text-base-content/70">{gettext("Loading processes...")}</p>
        </div>

        <!-- Load failure with nothing to show -->
        <div
          :if={@executions_error != nil and @executions == [] and not @executions_loading}
          id="processes-load-error"
          role="alert"
          class="rounded-lg border border-base-300 px-4 py-10 text-center sm:py-14"
        >
          <.icon name="hero-exclamation-triangle" class="size-10 mx-auto mb-4 text-error/70" />
          <p class="text-lg font-semibold text-error">{gettext("Could not load processes.")}</p>
          <p class="text-xs text-base-content/60 mt-1 font-mono break-all">{@executions_error}</p>
          <button type="button" class="btn btn-sm btn-ghost mt-3 text-error" phx-click="retry">
            <.icon name="hero-arrow-path" class="size-3.5" /> {gettext("Retry")}
          </button>
        </div>

        <!-- Background-refresh failure: the loaded rows stay on screen -->
        <div
          :if={@executions_error != nil and @executions != []}
          id="processes-refresh-error"
          role="alert"
          class="mb-4 flex items-center justify-between gap-3 rounded-lg border border-error/20 bg-error/10 px-3 py-2 text-sm text-error"
        >
          <span class="flex items-center gap-2 min-w-0">
            <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
            <span class="truncate">{gettext("Could not refresh processes.")}</span>
          </span>
          <button type="button" class="btn btn-sm btn-ghost text-error" phx-click="retry">
            <.icon name="hero-arrow-path" class="size-3.5" /> {gettext("Retry")}
          </button>
        </div>

        <!-- Empty state, per tab -->
        <div
          :if={
            @filtered == [] and not @executions_loading and
              (@executions_error == nil or @executions != [])
          }
          id="processes-empty"
          class="rounded-lg border border-base-300 px-4 py-10 text-center text-base-content/70 sm:py-14"
        >
          <.icon name="hero-cpu-chip" class="size-10 mx-auto mb-4 text-base-content/40" />
          <p class="text-base font-semibold text-base-content">
            {if @filters_active,
              do: gettext("No processes match these filters."),
              else: empty_message(@status_filter)}
          </p>
          <button
            :if={@filters_active}
            id="processes-clear-filters"
            type="button"
            class="btn btn-outline btn-sm mt-4"
            phx-click="clear_filters"
          >
            {gettext("Clear filters")}
          </button>
          <button
            :if={!@filters_active and @status_filter == "live" and @counts.finished > 0}
            id="processes-show-finished"
            type="button"
            class="btn btn-outline btn-sm mt-4"
            phx-click="set_status"
            phx-value-status="finished"
          >
            {gettext("Show finished processes")}
          </button>
        </div>

        <!-- Process table (newest first, as the core returns them) -->
        <div
          :if={@filtered != []}
          id="processes-results"
          phx-hook="ListEnter"
          data-list-enter-scope={list_enter_scope(assigns)}
          class="rounded-lg border border-base-300 bg-base-100"
        >
          <table
            role="table"
            aria-label={gettext("Processes")}
            class="table table-sm block xl:table"
          >
            <thead role="rowgroup" class="hidden xl:table-header-group">
              <tr role="row" class="bg-base-200/50 text-xs text-base-content/70">
                <th scope="col" role="columnheader">{gettext("Status")}</th>
                <th scope="col" role="columnheader">{gettext("Agent")}</th>
                <th scope="col" role="columnheader">{gettext("Task")}</th>
                <th scope="col" role="columnheader" class="w-full">{gettext("Command")}</th>
                <th scope="col" role="columnheader" class="hidden 2xl:table-cell">
                  {gettext("Runtime")}
                </th>
                <th scope="col" role="columnheader" class="hidden 2xl:table-cell">
                  {gettext("Backend")}
                </th>
                <th scope="col" role="columnheader" class="hidden 2xl:table-cell">
                  {gettext("Target")}
                </th>
                <th scope="col" role="columnheader">{gettext("Uptime")}</th>
                <th scope="col" role="columnheader" class="text-right">{gettext("CPU")}</th>
                <th scope="col" role="columnheader" class="text-right">{gettext("Memory")}</th>
                <th scope="col" role="columnheader" class="text-right">{gettext("Exit")}</th>
                <th scope="col" role="columnheader" class="text-right">{gettext("Actions")}</th>
              </tr>
            </thead>
            <tbody
              id="processes-rows"
              role="rowgroup"
              phx-update="stream"
              class="block xl:table-row-group"
            >
              <ProcessComponents.execution_row
                :for={{_dom_id, execution} <- @streams.executions}
                execution={execution}
                expanded={MapSet.member?(@expanded, Format.id_string(Map.get(execution, :id)))}
                entering={MapSet.member?(@entering, Format.id_string(Map.get(execution, :id)))}
                node_id={@current_node_id}
              />
            </tbody>
          </table>
        </div>

        <ProcessComponents.confirm_modal
          :if={@confirm != nil}
          confirm={@confirm}
          reason={@confirm_reason}
          error={@confirm_error}
        />
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Load results
  # ---------------------------------------------------------------------------

  defp apply_load_result(socket, {:ok, executions}) when is_list(executions) do
    socket
    |> assign(
      executions: executions,
      executions_loaded: true,
      executions_loading: false,
      executions_error: nil,
      # The whole table was replaced: nothing on screen is newly joined.
      entering: MapSet.new()
    )
    |> recompute()
    |> stream_reset()
  end

  defp apply_load_result(socket, {:ok, other}) do
    apply_load_result(socket, {:error, {:invalid_result, other}})
  end

  defp apply_load_result(socket, {:error, reason}) do
    # The rows stay on screen, so the stream is not rebuilt — only the rows
    # whose enter animation was still pending need the class removed.
    cleared = MapSet.to_list(socket.assigns.entering)

    socket
    |> assign(
      executions_loading: false,
      executions_error: Format.term_text(reason),
      entering: MapSet.new()
    )
    |> recompute()
    |> stream_touch(cleared)
  end

  defp apply_load_result(socket, other) do
    apply_load_result(socket, {:error, {:invalid_result, other}})
  end

  # ---------------------------------------------------------------------------
  # Execution-list updates (pure helpers over the socket's :executions)
  # ---------------------------------------------------------------------------

  # Every mutation of `:executions` funnels through here, so the derived
  # render state is recomputed exactly once per change — and not at all when
  # the event left the rows untouched (a sample for an id this page does not
  # show, a repeat `started` broadcast, a foreign-node record).
  #
  # `ids` are the ids THIS event could have touched. Only the ones whose row
  # actually changed are patched into the stream, so an unchanged 3-second
  # sample re-renders nothing at all instead of the whole live table.
  defp update_executions(socket, fun, ids) when is_function(fun, 1) do
    previous = executions_list(socket)
    updated = fun.(previous)

    socket = assign(socket, :executions, updated)
    socket = if updated == previous, do: socket, else: recompute(socket)

    touched = Enum.filter(ids, &(find_execution(previous, &1) != find_execution(updated, &1)))

    stream_touch(socket, touched)
  end

  defp executions_list(socket) do
    case Map.get(socket.assigns, :executions) do
      list when is_list(list) -> list
      _other -> []
    end
  end

  # A broadcast that introduces an id the page does NOT already show is a
  # genuinely new row: it joins the head (`fun` is `prepend_execution/2` for a
  # start, `put_execution/2` for an exit the page never saw start) and is
  # marked `entering` for one TTL so its enter animation runs exactly once.
  # A repeat broadcast for a known id only patches its row — no row movement,
  # no animation.
  defp upsert_execution(socket, execution, fun) when is_function(fun, 2) do
    previous = Map.get(socket.assigns, :executions)
    id = Map.get(execution, :id)
    # Decide BEFORE the insert (the same guard that suppresses a duplicate
    # prepend), and mark `entering` FIRST so the row the stream inserts below
    # already carries the animation class.
    newly_joined? = find_execution(previous, id) == nil

    socket = if newly_joined?, do: mark_entering(socket, [id]), else: socket

    update_executions(socket, fn rows -> fun.(rows, execution) end, [id])
  end

  # Adds ids to `:entering` and schedules their own clear; ids are compared in
  # their STRING form (`Format.id_string/1`), the same form the render uses, so
  # a native integer id from the core and a string id from a DOM value agree.
  # An empty-string id (a malformed record) is never animated, and the static
  # render arms no timers because it has no connected socket to message.
  defp mark_entering(socket, ids) do
    new_ids =
      ids
      |> Enum.map(&Format.id_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case new_ids do
      [] ->
        socket

      ids ->
        if connected?(socket) do
          Process.send_after(self(), {:clear_entering, ids}, entering_ttl_ms())
        end

        entering = Enum.reduce(ids, socket.assigns.entering, &MapSet.put(&2, &1))
        assign(socket, :entering, entering)
    end
  end

  # Read AT CALL TIME (never a compile-time constant) so a test can shrink it.
  defp entering_ttl_ms do
    case Application.get_env(:evo_dash, :processes_entering_ttl_ms, @default_entering_ttl_ms) do
      ttl when is_integer(ttl) and ttl >= 0 -> ttl
      _other -> @default_entering_ttl_ms
    end
  end

  # A newly tracked process joins the head (the list is newest first); a repeat
  # broadcast for an already-known id is dropped.
  defp prepend_execution(executions, execution) do
    id = Map.get(execution, :id)

    if id != nil and find_execution(executions, id) != nil do
      executions
    else
      [execution | executions]
    end
  end

  # Exit: the record is complete, so replace it in place (or prepend it when the
  # page never saw it start — e.g. a process spawned before this page opened).
  defp put_execution(executions, execution) do
    id = Map.get(execution, :id)

    cond do
      id == nil -> executions
      find_execution(executions, id) == nil -> [execution | executions]
      true -> Enum.map(executions, fn row -> if same_id?(row, id), do: execution, else: row end)
    end
  end

  # `{:process_updated, id, changes}` carries only the changed fields.
  defp update_execution(executions, id, changes) do
    Enum.map(executions, fn execution ->
      if same_id?(execution, id), do: merge_changes(execution, changes), else: execution
    end)
  end

  # `{:process_sample, node, seq, entries}` is a batch of resource samples:
  # only :status / :stats are applied, and only to rows the page already shows
  # (an unknown id is a process from another filter, not a new row).
  defp apply_sample(executions, entries) when is_list(executions) do
    case sample_updates(entries) do
      updates when map_size(updates) == 0 ->
        executions

      updates ->
        Enum.map(executions, fn execution ->
          case Map.get(updates, Map.get(execution, :id)) do
            nil -> execution
            changes -> merge_changes(execution, changes)
          end
        end)
    end
  end

  defp apply_sample(executions, _entries), do: executions

  defp sample_updates(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      id = Format.entry_get(entry, :id)

      if id == nil do
        acc
      else
        changes =
          %{}
          |> put_present(:status, Format.entry_get(entry, :status))
          |> put_present(:stats, Format.entry_get(entry, :stats))

        if map_size(changes) == 0, do: acc, else: Map.put(acc, id, changes)
      end
    end)
  end

  defp sample_updates(_entries), do: %{}

  # `{:process_control, id, entry}` appends the operator action to that row's
  # control log. The broadcast reaches every viewer, INCLUDING the page whose
  # click caused it (the control answer carries no log entry), so the dedupe
  # guard keeps a redelivery from showing the same action twice.
  defp append_control_entry(executions, id, entry) do
    Enum.map(executions, fn execution ->
      log = existing_control_log(execution)

      cond do
        not same_id?(execution, id) -> execution
        duplicate_entry?(log, entry) -> execution
        true -> put_control_log(execution, log ++ [entry])
      end
    end)
  end

  defp existing_control_log(execution) do
    case Map.get(execution, :control_log) do
      entries when is_list(entries) -> entries
      _other -> []
    end
  end

  defp duplicate_entry?(log, entry) do
    case List.last(log) do
      %{} = newest ->
        Format.entry_get(newest, :at) == Format.entry_get(entry, :at) and
          Format.entry_get(newest, :action) == Format.entry_get(entry, :action)

      _other ->
        false
    end
  end

  defp put_control_log(execution, log) when is_struct(execution) do
    if Map.has_key?(execution, :control_log) do
      Map.replace!(execution, :control_log, log)
    else
      execution
    end
  end

  defp put_control_log(execution, log) when is_map(execution),
    do: Map.put(execution, :control_log, log)

  defp merge_changes(execution, changes) when is_struct(execution) do
    Enum.reduce(changes, execution, fn
      {key, value}, acc when is_atom(key) ->
        if Map.has_key?(acc, key), do: Map.replace!(acc, key, value), else: acc

      _other, acc ->
        acc
    end)
  end

  defp merge_changes(execution, changes) when is_map(execution) and is_map(changes),
    do: Map.merge(execution, changes)

  defp merge_changes(execution, _changes), do: execution

  defp find_execution(executions, id) when is_list(executions) do
    Enum.find(executions, fn execution -> same_id?(execution, id) end)
  end

  defp find_execution(_executions, _id), do: nil

  # Ids cross the boundary as native terms (the page's own DOM values are
  # strings), so comparison goes through the shared string form.
  defp same_id?(execution, id) when is_map(execution) do
    Format.id_string(Map.get(execution, :id)) == Format.id_string(id)
  end

  defp same_id?(_execution, _id), do: false

  # ---------------------------------------------------------------------------
  # Stream projection (`@streams.executions` mirrors `:filtered`)
  # ---------------------------------------------------------------------------

  # Replaces the whole rendered stream from the current `:filtered`. Used where
  # the membership is recomputed GLOBALLY — a snapshot load, a node switch and
  # every filter change — because rows may have disappeared without any event
  # naming them.
  defp stream_reset(socket) do
    stream(socket, :executions, Map.get(socket.assigns, :filtered, []), reset: true)
  end

  # Patches ONLY the ids one push event touched: a still-visible row is
  # re-inserted from `:filtered` at the index it occupies there, and a row the
  # filters now exclude is DELETED — a shorter list alone would leave a stale
  # `<tr>` in a `phx-update="stream"` container.
  #
  # Every touched id is deleted FIRST: the row component renders the summary
  # `<tr>` plus, when `expanded`, a sibling `process-details-<id>` `<tr>`, and a
  # same-id re-insert alone only morphs the row element in place — collapsing
  # would leave the stale details row behind.
  defp stream_touch(socket, ids) do
    filtered = Map.get(socket.assigns, :filtered, [])

    {visible, hidden} =
      ids
      |> Enum.map(&Format.id_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.reduce({[], []}, fn key, {visible, hidden} ->
        case Enum.find_index(filtered, &(Format.id_string(Map.get(&1, :id)) == key)) do
          nil -> {visible, [key | hidden]}
          index -> {[{index, key, Enum.at(filtered, index)} | visible], hidden}
        end
      end)

    socket =
      Enum.reduce(hidden, socket, fn key, acc ->
        delete_row(acc, key)
      end)

    # Ascending position, so a batch that inserts several rows lands each one at
    # the index it occupies in `:filtered`.
    visible
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(socket, fn {index, key, execution}, acc ->
      acc
      |> delete_row(key)
      |> stream_insert(:executions, execution, at: index)
    end)
  end

  # Drops BOTH elements one row can own, so the following insert (if any) is the
  # only copy left in the container.
  defp delete_row(socket, key) do
    socket
    |> stream_delete_by_dom_id(:executions, row_dom_id(%{id: key}))
    |> stream_delete_by_dom_id(:executions, details_dom_id(key))
  end

  # The details `<tr>` id the row component renders when the disclosure is open
  # (`key` is already the normalized id string).
  defp details_dom_id(key), do: "process-details-" <> key

  # The stream `dom_id` MUST equal the `<tr>` id the row component renders from
  # the same record (`"process-row-#{@id || "unknown"}"`), because LiveView
  # matches stream children by element id. A nil/absent id is the component's
  # `"unknown"` arm.
  defp row_dom_id(execution) do
    id = if is_map(execution), do: Map.get(execution, :id), else: nil
    "process-row-" <> if(id == nil, do: "unknown", else: Format.id_string(id))
  end

  # The ids a `{:process_sample, ...}` batch names (its entries may be
  # malformed, in which case the id is simply absent).
  defp sample_ids(entries) when is_list(entries) do
    Enum.map(entries, &Format.entry_get(&1, :id))
  end

  defp sample_ids(_entries), do: []

  # ---------------------------------------------------------------------------
  # Control actions (async: the RPC never runs in the LiveView process)
  # ---------------------------------------------------------------------------

  defp run_reversible_control(socket, params, action) do
    case id_param(params) do
      nil ->
        socket

      id ->
        start_control(socket, id, action, action, Actions.default_reason(action))
    end
  end

  defp open_confirm(socket, params, action) do
    case id_param(params) do
      nil ->
        socket

      id ->
        execution = find_execution(socket.assigns.executions, id) || %{id: id}

        assign(socket,
          confirm: %{id: id, action: action, execution: execution},
          confirm_reason: "",
          confirm_error: nil
        )
    end
  end

  defp confirm_control(socket, reason) do
    case socket.assigns.confirm do
      %{id: id, action: action} when action in [:terminate, :kill] ->
        case Actions.validate_reason(reason) do
          :blank ->
            message = gettext("A reason is required.")

            socket
            |> assign(:confirm_reason, reason_text(reason))
            |> assign(:confirm_error, message)
            |> put_flash(:error, message)

          :ok ->
            # The operator's text stays on the socket for the whole flight, so
            # a failed action can keep the modal open with it intact.
            socket
            |> assign(:confirm_reason, reason_text(reason))
            |> assign(:confirm_error, nil)
            |> start_control(id, action, control_action(action), String.trim(reason))
        end

      _other ->
        socket
    end
  end

  # Spawns ONE control call under `EvoDash.SafeCall` and marks the row busy.
  # `label_action` is the page-level action the flash text is derived from
  # (`:terminate` / `:kill`), `core_action` the term the core's manager
  # receives (`{:signal, "TERM"}` / `:kill`).
  defp start_control(socket, id, label_action, core_action, reason) do
    key = Format.id_string(id)

    if Map.has_key?(socket.assigns.action_busy, key) do
      # A click on a row whose previous control is still in flight: drop it so
      # one operator gesture cannot post two controls.
      socket
    else
      node = socket.assigns.current_node

      case SafeCall.start(self(), {:process_control_result, id, label_action}, fn ->
             Actions.control(node, id, core_action, reason)
           end) do
        {:ok, _pid} ->
          assign(socket, :action_busy, Map.put(socket.assigns.action_busy, key, label_action))

        {:error, reason} ->
          # No result message will ever arrive, so the row must not be marked
          # busy — surface the failure instead of wedging the control.
          {kind, message} = Actions.result_message(label_action, {:error, reason})
          put_flash(socket, kind, message)
      end
    end
  end

  # Settles one async control outcome: the row's busy marker is cleared on
  # EVERY arm (success, failure and SafeCall exit alike), so a control can
  # never stay wedged, and the outcome is always flashed.
  defp apply_control_result(socket, id, label_action, raw_result) do
    result = normalize_control_result(raw_result)
    {kind, message} = Actions.result_message(label_action, result)

    socket =
      socket
      |> assign(:action_busy, Map.delete(socket.assigns.action_busy, Format.id_string(id)))
      |> put_flash(kind, message)

    socket
    |> settle_confirm(id, label_action, result, message)
    # The row's own markup does not change here, but the control outcome is
    # the one place that leaves the busy marker: patch just that id.
    |> stream_touch([id])
  end

  # Only the modal that STARTED this call is settled: one opened (or closed)
  # meanwhile belongs to another gesture and is left untouched.
  defp settle_confirm(socket, id, action, result, message)
       when action in [:terminate, :kill] do
    case socket.assigns.confirm do
      %{id: ^id, action: ^action} ->
        case result do
          :ok ->
            assign(socket, confirm: nil, confirm_reason: "", confirm_error: nil)

          {:error, _reason} ->
            # Keep the modal open with the operator's text preserved (already
            # assigned at submit time) and the failure shown in place.
            assign(socket, :confirm_error, message)
        end

      _other ->
        socket
    end
  end

  defp settle_confirm(socket, _id, _action, _result, _message), do: socket

  # `Actions.control/4` already answers `:ok | {:error, reason}`; the wrapper
  # below only unwraps SafeCall's own envelope (and stays total for anything
  # else, so a surprise value is a flashable error instead of a crash).
  defp normalize_control_result({:ok, :ok}), do: :ok
  defp normalize_control_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_control_result({:ok, other}), do: {:error, {:unexpected_result, other}}
  defp normalize_control_result({:error, reason}), do: {:error, reason}
  defp normalize_control_result(other), do: {:error, {:unexpected_result, other}}

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(_reason), do: ""

  # Terminate asks politely (TERM); Kill is the destructive escalation.
  defp control_action(:kill), do: :kill
  defp control_action(_action), do: {:signal, "TERM"}

  # ---------------------------------------------------------------------------
  # Filters + URL state
  # ---------------------------------------------------------------------------

  # The ONE derivation of the page's render state: the visible rows, the three
  # tab counts (over every OTHER dimension, so the numbers stay stable while
  # the operator switches tabs) and the "is anything narrowed" flag.
  defp recompute(socket) do
    filters = filters(socket.assigns)
    executions = executions_list(socket)

    socket
    |> assign(:filtered, Format.filter(executions, filters))
    |> assign(:counts, Format.counts(Format.filter(executions, Map.delete(filters, :status))))
    |> assign(
      :filters_active,
      filters.kind != "all" or filters.q != "" or filters.agent_id != nil or
        filters.task_id != nil
    )
  end

  defp filters(assigns) do
    %{
      status: Map.get(assigns, :status_filter),
      kind: Map.get(assigns, :kind_filter),
      q: Map.get(assigns, :search_query),
      agent_id: Map.get(assigns, :agent_filter),
      task_id: Map.get(assigns, :task_filter)
    }
  end

  # Rebuilds /processes from the current filters overlaid with `overrides`.
  # Because this page always carries a query string, `node` is appended with
  # "&" by hand — `EvoDashWeb.Helpers.with_node_param/2` appends "?" and would
  # produce a broken URL here.
  defp filters_url(socket, overrides) do
    filters = %{
      status: override(overrides, :status, socket.assigns.status_filter),
      kind: override(overrides, :kind, socket.assigns.kind_filter),
      q: override(overrides, :q, socket.assigns.search_query),
      agent_id: override(overrides, :agent_id, socket.assigns.agent_filter),
      task_id: override(overrides, :task_id, socket.assigns.task_filter)
    }

    query =
      filters
      |> Enum.reject(fn {key, value} -> blank?(value) or (key == :kind and value == "all") end)
      |> URI.encode_query()

    path = ~p"/processes"
    base = if query == "", do: path, else: path <> "?" <> query

    append_node_param(base, Map.get(socket.assigns, :current_node_id))
  end

  defp override(overrides, key, default), do: Map.get(overrides, key, default)

  defp append_node_param(url, node_id) when is_binary(node_id) and node_id != "" do
    # `node` is a VCT/connection target id (a slug), so form encoding is enough
    # and keeps the URL parseable by the node-aware hook.
    encoded = URI.encode_www_form(node_id)

    if String.contains?(url, "?"),
      do: url <> "&node=" <> encoded,
      else: url <> "?node=" <> encoded
  end

  defp append_node_param(url, _node_id), do: url

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  # ---------------------------------------------------------------------------
  # Param readers (total: a malformed/missing value is nil)
  # ---------------------------------------------------------------------------

  defp string_param(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_param(_value), do: nil

  defp id_param(params) when is_map(params) do
    case Map.get(params, "id") do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp id_param(_params), do: nil

  defp toggle_expanded(expanded, id) do
    if MapSet.member?(expanded, id) do
      MapSet.delete(expanded, id)
    else
      MapSet.put(expanded, id)
    end
  end

  # ---------------------------------------------------------------------------
  # Render helpers
  # ---------------------------------------------------------------------------

  # The `ListEnter` hook's view identity: a filter, tab or node change is a NEW
  # scope, so the hook re-seeds its silent baseline instead of animating the
  # whole replacement list. Total: an unset filter contributes an empty part.
  defp list_enter_scope(assigns) do
    parts =
      [
        "processes",
        Map.get(assigns, :current_node_id) || "local",
        Map.get(assigns, :status_filter),
        Map.get(assigns, :kind_filter),
        Map.get(assigns, :search_query),
        Map.get(assigns, :agent_filter),
        Map.get(assigns, :task_filter)
      ]

    Enum.map_join(parts, ":", fn
      nil -> ""
      part -> Format.id_string(part)
    end)
  end

  defp status_tab_label("live"), do: gettext("Live")
  defp status_tab_label("finished"), do: gettext("Finished processes")
  defp status_tab_label(_tab), do: gettext("All")

  defp status_tab_count(counts, "live"), do: Map.get(counts, :live, 0)
  defp status_tab_count(counts, "finished"), do: Map.get(counts, :finished, 0)
  defp status_tab_count(counts, _tab), do: Map.get(counts, :all, 0)

  defp empty_message("live"), do: gettext("No live processes.")
  defp empty_message("finished"), do: gettext("No finished processes.")
  defp empty_message(_tab), do: gettext("No processes match these filters.")

  # Kept for the `:stats` sample shape: only present values are merged, so a
  # partial sample never blanks a field the page already shows.
  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
