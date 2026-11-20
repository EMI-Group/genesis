defmodule EvoDashWeb.AgentsLive do
  @moduledoc """
  Agent tree inspector.

  Renders the recursive agent hierarchy from the scheduler's runtime state with
  chat-history and token/cost usage viewers. Node-aware: reads scheduler state
  via `EvoDash.NodeContext` so it works for both the local BEAM node and a
  remote `genesis_remote` daemon (SSH Remote Development, Phase 3). Fully
  push-based: the `:evo_git` runtime broadcasts node-identity agent events on
  `EvoGit.PubSub` topic `"agents"` (`{:agent_registered, id, summary, node}`,
  `{:agent_updated, id, changed_fields, node}`, `{:agent_removed, id, node}`,
  `{:agents_updated, node}`), which are applied incrementally in-memory through
  ONE shared path for local and remote events — foreign-node events are
  dropped.

  ALL node-aware data loading is ASYNC: the page load (spawned by
  `handle_params/3` on the CONNECTED mount only), broadcast-triggered
  refreshes, and history fetches run in `EvoDash.TaskSupervisor` children —
  the LiveView process never blocks on a cross-node RPC. Every spawned loader
  runs its call through `EvoDash.SafeCall.run/1`, so a `GenServer.call`
  timeout / dead target (an EXIT, not a rescue-able exception) comes back as an
  error VALUE and the result message is always sent. Results arrive as tagged
  messages guarded by monotonic generation/sequence counters (stale results are
  dropped) and the node currently being viewed. History transfers are gated on
  the `RemoteAPI.list_agents/0` `:message_count` field: an agent's full history is
  re-fetched only when its message count changed (see `HistoryGate`).
  A failed page load keeps the last good tree, clears the loading flag and
  records a retry-able `@agents_error` banner.
  """
  use EvoDashWeb, :live_view

  alias EvoDash.SafeCall

  alias EvoDashWeb.AgentsLive.{
    AgentMerge,
    CommitGraph,
    CommitGraphRefresh,
    ContextMeter,
    Inspector,
    LoadData,
    OptimisticMessages,
    PendingEvents,
    StreamPanel,
    StreamWatch,
    ToolCallDisplay
  }

  # Minimum interval between commit-graph fetches. Refreshes are already coalesced
  # by the agent-event flush; this further throttles the (heavier) per-repo git
  # RPC. A throttled request arms ONE one-shot :commit_graph_tick — never a poll.
  # The window is read AT CALL TIME via commit_graph_min_interval_ms/0 (the
  # :agents_live_commit_graph_tick_ms test seam, production default 1000ms) so the
  # throttle check and the armed tick delay can never diverge.
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "agents")
    end

    # current_node is set to node() by the NodeAware on_mount hook (runs before
    # mount). handle_params/3 runs assign_node/2 next, which may switch to a
    # remote node and trigger the async load there.
    current_node = socket.assigns[:current_node] || node()

    # No synchronous loads here: handle_params/3 always runs after mount and
    # kicks off the async page load (start_async_load/1), which populates
    # agents/config_status/threshold_cache. The initial render (dead render
    # included) shows the loading state via @agents_loading.
    socket =
      assign(socket,
        page_title: gettext("Agents"),
        selected_agent_id: nil,
        requested_agent_id: nil,
        inspector_stream: nil,
        inspector_stream_token: 0,
        inspector_stream_worker: nil,
        inspector_stream_worker_monitor: nil,
        inspector_history_seq: 0,
        inspector_history_error: false,
        selected_history_entry: nil,
        selected_objective: nil,
        show_usage: false,
        send_message_agent_id: nil,
        send_message_text: "",
        agents: [],
        id_to_display: %{},
        repo_trees: [],
        config_status: nil,
        previous_agent_ids: MapSet.new(),
        agents_initialized: false,
        previous_statuses: %{},
        new_agent_ids: MapSet.new(),
        changed_status_ids: MapSet.new(),
        previous_node: current_node,
        # Optimistic user messages keyed by agent_id (agent_id => [%{content,
        # sent_at}]). Independent of @agents — survives agent/history reloads;
        # merged into the displayed history at render time and TERMINALLY
        # pruned (OptimisticMessages.prune/4) once an entry is confirmed
        # drained or no longer queued.
        optimistic_messages: %{},
        # Last `pending_user_messages` queue broadcast by the core, keyed by
        # agent_id (agent_id => list of queued contents). Anchors the optimistic
        # pruning: an entry still present in this queue stays pending, one that
        # vanished from it (drained) is removed. Absent key = queue unknown.
        pending_user_messages: %{},
        # Async page-load state: agents_loading gates the tree's loading UI;
        # load_generation is a monotonic counter that stale-guards async load
        # results (only the newest generation may apply). The initial value is
        # TRUE so the dead render paints the loading shell — the load itself is
        # spawned ONLY by the connected mount (handle_params/3 gates it on
        # connected?/1), never by the dead render.
        agents_loading: true,
        load_generation: 0,
        # Last page-load failure (nil = no error). Set alongside
        # `agents_loading: false` by the {:agents_data_loaded, ...} error
        # branch and rendered as a retry-able inline banner; cleared whenever a
        # load starts and on any successful load.
        agents_error: nil,
        # Monotonic sequence for async refresh tasks (broadcast-triggered
        # fallbacks) — never reset; the newest seq wins (mirrors
        # system_live's chart_seed_seq pattern).
        refresh_seq: 0,
        # Last-seen message_count per agent id (see HistoryGate) — reset on
        # node switch (agent ids are per-node).
        history_gate: %{},
        # {node, threshold, fetched_at_monotonic} compression-threshold cache
        # (see ThresholdCache) — fetched only inside async tasks.
        threshold_cache: nil,
        # Agent id whose history is currently being fetched (small spinner in
        # the chat-history section).
        history_loading_agent_id: nil,
        # Agent id whose history is being fetched for a full-message modal
        # (view_full_message safety net).
        full_message_pending_index: nil,
        full_message_pending_agent_id: nil,
        # Agent-event coalescing (see EvoDashWeb.AgentsLive.PendingEvents):
        # buffered incremental events awaiting the 300ms trailing-edge flush,
        # a once-per-window scheduling flag, and a coalesced refresh trigger.
        pending_agent_events: PendingEvents.new(),
        agent_flush_scheduled: false,
        pending_agents_refresh: false,
        # Left-panel view switcher + TEMPORAL (git commit history) view state.
        # left_view survives node switches (a user preference); the commit-graph
        # data does not — agent ids/commits are per-node (reset in handle_params).
        left_view: :tree,
        commit_graph: [],
        commit_graph_raw: %{},
        commit_graph_loaded: false,
        commit_graph_loading: false,
        commit_graph_error: nil,
        # Monotonic seq stale-guarding async commit-graph fetches — NEVER reset,
        # mirroring :refresh_seq.
        commit_graph_seq: 0,
        commit_graph_fetched_at: nil,
        commit_graph_tick_scheduled: false,
        # Commit-relevance fingerprint of the LAST-BUILT commit-graph agent set
        # (CommitGraphRefresh.fingerprint/1) — nil until the first build/fetch;
        # an unchanged fingerprint lets a commit-irrelevant agent-update flush
        # skip BOTH the rebuild and the git-RPC refetch. Per-node like the
        # other commit-graph data.
        commit_graph_fingerprint: nil,
        # COMMIT-HISTORY FOLD (collapse/expand) state: the set of fold keys the
        # user has EXPANDED (a MapSet of binaries; empty = the fully collapsed
        # default). Per-NODE view state — reset on a node switch together with
        # the rest of the commit-graph data (fold keys name that node's commits)
        # — but NOT a preference like @left_view, so it is threaded into EVERY
        # CommitGraph.build/3 call and therefore survives push refreshes.
        commit_fold_expanded: MapSet.new(),
        # In-session RETENTION of ended agents: agent_id => the agent's last
        # known map with `ended: true`. The core DELETES an agent's ETS rows (and
        # its evogit-agent-* branch) when it is recycled, so a finished agent        # would otherwise vanish from the commit-history view and take its lane
        # (plus its START/END markers) with it. Retained agents feed the
        # commit-graph lanes ONLY — never the agent tree. Reset on a node switch
        # (agent ids are per-node). In-session only: the core persists no
        # per-agent commit attribution, so it does not survive a page reload.
        retained_agents: %{}
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    previous_scope = {socket.assigns[:current_node_id], socket.assigns.current_node}

    # Unsubscribe in the consumer before NodeAware can replace either identity.
    # Keep the serial worker and monotonic tokens alive across scope resets.
    socket =
      socket
      |> StreamWatch.detach()
      |> assign(
        history_loading_agent_id: nil,
        full_message_pending_index: nil,
        full_message_pending_agent_id: nil
      )
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/agents")
      |> assign(:requested_agent_id, Inspector.parse_agent_id(params["agent_id"]))

    current_node = socket.assigns.current_node

    socket =
      if current_node != socket.assigns.previous_node or
           {socket.assigns[:current_node_id], current_node} != previous_scope do
        # Keep the persisted node check: NodeAware may have changed current_node
        # before handle_params runs. The scope check also catches target changes
        # that resolve to the same node.
        # Node changed (e.g. user switched from Local to a remote target, or
        # vice versa). Clear per-agent selection state, the history gate, and
        # the threshold cache — agent ids and config are per-node. The agent
        # reload itself happens asynchronously below (start_async_load/1), so
        # the page never blocks on cross-node RPCs.
        socket
        |> assign(
          agents: [],
          repo_trees: [],
          id_to_display: %{},
          previous_agent_ids: MapSet.new(),
          agents_initialized: false,
          previous_statuses: %{},
          new_agent_ids: MapSet.new(),
          changed_status_ids: MapSet.new(),
          selected_agent_id: nil,
          selected_history_entry: nil,
          selected_objective: nil,
          send_message_agent_id: nil,
          send_message_text: "",
          previous_node: current_node,
          # Agent ids are per-node; optimistic messages (and the queue snapshot
          # anchoring them) from the previous node must not leak into a
          # different node's agent list.
          optimistic_messages: %{},
          pending_user_messages: %{},
          history_gate: %{},
          threshold_cache: nil,
          agents_error: nil,
          history_loading_agent_id: nil,
          inspector_history_error: false,
          full_message_pending_index: nil,
          full_message_pending_agent_id: nil,
          # Drop any buffered agent events from the previous node so stale-node
          # events never leak into the newly-viewed node's tree. A flush timer
          # already in flight is harmless: the buffer is empty, so the flush is
          # a no-op.
          pending_agent_events: PendingEvents.new(),
          agent_flush_scheduled: false,
          pending_agents_refresh: false,
          # Commit-graph data is per-node: reset it on a node switch. @left_view
          # (the user's view preference) survives; @commit_graph_seq is monotonic.
          commit_graph: [],
          commit_graph_raw: %{},
          commit_graph_loaded: false,
          commit_graph_loading: false,
          commit_graph_error: nil,
          # Fingerprint of the LAST-BUILT commit-graph agent set (see
          # CommitGraphRefresh.fingerprint/1) — nil until a build/fetch runs,
          # and reset together with the other per-node data.
          commit_graph_fingerprint: nil,
          commit_graph_fetched_at: nil,
          commit_graph_tick_scheduled: false,
          # Fold (collapse/expand) state names THIS node's commit groups, so it
          # is per-node view state and returns to the collapsed default.
          commit_fold_expanded: MapSet.new(),
          # Retained ended agents are per-node too (agent ids are per-node).
          retained_agents: %{}
        )
      else
        assign(socket, :previous_node, current_node)
      end

    # Kick off the async page load (agents + config status + threshold cache),
    # but ONLY on the connected mount: the dead render paints the shell and
    # must not spawn a load whose result would be sent to a dying process. The
    # generation guard in handle_info({:agents_data_loaded, ...}) drops stale
    # results, so the connected load is safe to start unconditionally.
    socket =
      if connected?(socket) do
        socket |> Inspector.maybe_attach() |> start_async_load()
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  # Async page-load result (spawned by start_async_load/1). Applies the fresh
  # agents + config status + threshold cache when still current.
  def handle_info({:agents_data_loaded, node, generation, result}, socket) do
    # Stale-guard: drop results from an older load generation or a different
    # node (the user switched away while the task was in flight).
    if node != socket.assigns.current_node or
         generation < Map.get(socket.assigns, :load_generation, 0) do
      {:noreply, socket}
    else
      case result do
        {:ok, %{agents: agents, config_status: config_status, threshold_cache: threshold_cache}} ->
          socket =
            socket
            |> AgentMerge.apply_result(agents)
            |> assign(
              config_status: config_status,
              threshold_cache: threshold_cache,
              agents_loading: false,
              agents_error: nil,
              previous_node: node
            )
            |> Inspector.select_requested()
            |> maybe_load_commit_graph([])

          {:noreply, socket}

        {:error, reason} ->
          # Keep whatever is currently rendered (the last good tree) and clear
          # the loading flag, recording a retry-able error the template renders
          # as an inline banner with a Retry button. No polling / auto-retry:
          # the broadcast paths and the explicit retry event re-run the load.
          {:noreply, assign(socket, agents_loading: false, agents_error: reason)}
      end
    end
  end

  @impl true
  # Throttled bulk-update broadcast. Coalesced like the incremental events
  # below: the refresh trigger is buffered (never spawned per event) and the
  # 300ms trailing-edge flush spawns AT MOST ONE async refresh. Foreign-node
  # events are dropped (the socket is unchanged).
  def handle_info({:agents_updated, node}, socket) do
    if EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, AgentMerge.buffer_refresh(socket)}
    else
      # Foreign-node event — dropped before buffering so it never schedules a
      # flush.
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:node_selected, node_id}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(StreamWatch.detach(socket), node_id)
  end

  @impl true
  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    # NodeAware only patches the URL on a node transition; handle_params
    # detaches before resolving that new identity. Duplicate status pushes must
    # not silently detach a healthy watch without scheduling a reattachment.
    EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)
  end

  @impl true
  # Synchronous connect-error fallback: errors like an unknown target,
  # unavailable subsystem, or manager-start failure are returned ONLY on arms
  # that never broadcast, so no {:remote_connection_status, ...} event will
  # ever arrive to reconcile the gate — the flash is the surfacing mechanism.
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

  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    # Debounce timer fired — reload the sidebar's running/pending tasks.
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)}
  end

  @impl true
  # Async refresh result (broadcast-triggered refreshes). Applies the fresh
  # agent tree when this is the newest refresh for the viewed node.
  def handle_info({:agents_refresh_result, seq, node, result}, socket) do
    # Stale-guard: only the newest spawned refresh may apply (older in-flight
    # tasks' results are dropped), and only for the node currently viewed.
    if seq < Map.get(socket.assigns, :refresh_seq, 0) or node != socket.assigns.current_node do
      {:noreply, socket}
    else
      case result do
        {:ok, agents, threshold_cache} ->
          socket =
            socket
            |> AgentMerge.apply_result(agents)
            |> assign(threshold_cache: threshold_cache)
            |> maybe_load_commit_graph([])

          {:noreply, socket}

        {:error, _reason} ->
          # Keep the last good tree; the next broadcast will retry.
          {:noreply, socket}
      end
    end
  end

  @impl true
  # Incremental agent events are COALESCED: each clause only node-filters and
  # buffers the raw event (see EvoDashWeb.AgentsLive.AgentMerge + PendingEvents),
  # then arms a single 300ms trailing-edge flush. No merge work happens here —
  # the whole burst collapses into ONE merge + render on :flush_agent_events
  # below, so a burst cannot starve the LiveView mailbox (a user phx-click no
  # longer waits behind N synchronous merges) and cannot flush as N rapid DOM
  # patches.
  def handle_info({:agent_registered, _id, _summary, _node} = event, socket) do
    {:noreply, AgentMerge.buffer_event(socket, event)}
  end

  @impl true
  def handle_info({:agent_updated, _id, _changed_fields, _node} = event, socket) do
    {:noreply, AgentMerge.buffer_event(socket, event)}
  end

  @impl true
  def handle_info({:agent_removed, _id, _node} = event, socket) do
    {:noreply, AgentMerge.buffer_event(socket, event)}
  end

  @impl true
  # Trailing-edge flush of the coalesced agent-event buffer. AgentMerge drains
  # the buffered events in ARRIVAL order, applies the whole burst in ONE merged
  # list (see its moduledoc) and answers the single follow-up still owed:
  # :refresh (spawn the ONE fallback refresh), :refetch (refresh the selected
  # agent's history once) or :none. Either way the burst yields exactly one
  # render/diff.
  def handle_info(:flush_agent_events, socket) do
    {socket, after_flush} = AgentMerge.flush(socket)

    socket =
      case after_flush do
        # A refresh was spawned — its result path already runs
        # Inspector.maybe_fetch_selected_history/1, so do not also refetch here.
        :refresh -> spawn_agents_refresh(socket)
        :refetch -> Inspector.refetch_selected_history(socket)
        :none -> socket
      end

    # A burst of agent commits extends the graph (new dots + moved rings;
    # throttled/coalesced); no-op unless the commit-history view is active.
    {:noreply, maybe_load_commit_graph(socket, [])}
  end

  @impl true
  # Inspector stream/history results — ownership, sequencing and the terminal
  # projection live in EvoDashWeb.AgentsLive.Inspector.
  def handle_info({:inspector_stream_ready, target, token, id, result}, socket) do
    {:noreply, Inspector.stream_ready(socket, target, token, id, result)}
  end

  def handle_info({:inspector_stream_reconciled, target, token, id, request, result}, socket) do
    {:noreply, Inspector.stream_reconciled(socket, target, token, id, request, result)}
  end

  def handle_info({:agent_delta, id, seq, events}, socket) do
    {:noreply, Inspector.stream_push(socket, id, seq, events)}
  end

  def handle_info({:agent_stream_closed, id, snapshot, seq}, socket) do
    {:noreply, Inspector.stream_closed(socket, id, snapshot, seq)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, socket) do
    {:noreply, Inspector.stream_down(socket, ref, pid, reason)}
  end

  @impl true
  # Async history-fetch result — ownership and stale guards live in Inspector.
  def handle_info({:agent_history_loaded, agent_id, node, seq, token, result, index}, socket) do
    Inspector.apply_history_result(socket, agent_id, node, seq, token, result, index)
  end

  # Old unscoped responses have no ownership proof.
  def handle_info({:agent_history_loaded, _, _, _, _}, socket), do: {:noreply, socket}

  @impl true
  # Async commit-graph result (spawned by spawn_commit_graph_fetch/1). Applies the
  # fresh graph when it is the newest fetch for the node being viewed. An error
  # keeps the last good graph (the view never wedges on a spinner); a PARTIAL
  # success (≥1 group ok, others failed) is an {:ok, ...} carrying the successful
  # groups only — the failed groups' lanes still render from the agent set, their
  # commits just stop at the last fetch.
  def handle_info({:commit_graph_loaded, node, seq, result}, socket) do
    if node != socket.assigns.current_node or
         seq < Map.get(socket.assigns, :commit_graph_seq, 0) do
      {:noreply, socket}
    else
      case result do
        {:ok, raw_by_repo} ->
          # Lanes come from the MERGED agent set (live + in-session retained) so
          # a recycled agent's lane/START-END markers survive; the agent tree
          # (@agents) is untouched. The fingerprint is re-stored for the agent
          # set THIS build consumed, so the next fingerprint-gated flush
          # compares against what was actually rendered.
          agents = commit_graph_agents(socket)

          {:noreply,
           assign(socket,
             commit_graph:
               CommitGraph.build(raw_by_repo, agents, socket.assigns.commit_fold_expanded),
             commit_graph_raw: raw_by_repo,
             commit_graph_loaded: true,
             commit_graph_loading: false,
             commit_graph_error: nil,
             commit_graph_fingerprint: CommitGraphRefresh.fingerprint(agents)
           )}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             commit_graph_loading: false,
             commit_graph_error: reason
           )}
      end
    end
  end

  @impl true
  # One-shot retry armed by schedule_commit_graph_tick/1 when a refresh request was
  # throttled: re-attempt with the throttle bypassed so a commit created inside
  # the throttle window (a new dot, or an agent ring that moved to a fresh tip)
  # is still reflected. Not periodic — it is armed ONLY by a throttled request.
  def handle_info(:commit_graph_tick, socket) do
    socket = assign(socket, :commit_graph_tick_scheduled, false)
    {:noreply, maybe_load_commit_graph(socket, force: true)}
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    {:noreply, Inspector.select(socket, id)}
  end

  @impl true
  # Left-panel view switcher (agent tree / commit history). Only the two literal
  # values are accepted; anything else is ignored (whitelist, no atom conversion).
  def handle_event("switch_left_view", %{"view" => "tree"}, socket) do
    {:noreply, assign(socket, :left_view, :tree)}
  end

  def handle_event("switch_left_view", %{"view" => "commits"}, socket) do
    {:noreply, socket |> assign(:left_view, :commits) |> maybe_load_commit_graph(force: true)}
  end

  def handle_event("switch_left_view", _params, socket), do: {:noreply, socket}

  @impl true
  # Commit-history FOLD (collapse/expand). The raw commit data is ALREADY in
  # @commit_graph_raw, so a fold change only re-runs the pure view-model
  # assembly in this process — no git RPC, no fetch spawn, no throttle/tick and
  # no fingerprint consultation. The fold key is whitelisted by shape only (a
  # binary straight from the rendered gap row — never atomized).
  def handle_event("toggle_commit_fold", %{"fold-key" => key}, socket) when is_binary(key) do
    if commit_folds_active?(socket) do
      expanded = socket.assigns.commit_fold_expanded

      expanded =
        if MapSet.member?(expanded, key),
          do: MapSet.delete(expanded, key),
          else: MapSet.put(expanded, key)

      {:noreply,
       socket |> assign(:commit_fold_expanded, expanded) |> rebuild_commit_graph_folds()}
    else
      {:noreply, socket}
    end
  end

  # Odd params (non-binary / missing key) are a no-op.
  def handle_event("toggle_commit_fold", _params, socket), do: {:noreply, socket}

  @impl true
  # Expands EVERY fold of the current raw data. `fold_keys/2` is the builder's
  # single source of the fold inventory, so the page never guesses key shapes.
  def handle_event("expand_all_commit_folds", _params, socket) do
    if commit_folds_active?(socket) do
      expanded =
        MapSet.union(
          socket.assigns.commit_fold_expanded,
          CommitGraph.fold_keys(socket.assigns.commit_graph_raw, commit_graph_agents(socket))
        )

      {:noreply,
       socket |> assign(:commit_fold_expanded, expanded) |> rebuild_commit_graph_folds()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("collapse_all_commit_folds", _params, socket) do
    if commit_folds_active?(socket) do
      {:noreply,
       socket |> assign(:commit_fold_expanded, MapSet.new()) |> rebuild_commit_graph_folds()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  # Inspector detail-panel events — state transitions live in Inspector.
  def handle_event("retry_inspector_stream", _params, socket) do
    {:noreply, Inspector.retry_stream(socket)}
  end

  def handle_event("retry_inspector_history", _params, socket) do
    {:noreply, Inspector.retry_history(socket)}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    {:noreply, Inspector.close_details(socket)}
  end

  @impl true
  def handle_event("toggle_usage", _params, socket) do
    {:noreply, Inspector.toggle_usage(socket)}
  end

  @impl true
  def handle_event("view_full_message", %{"index" => index}, socket) do
    {:noreply, Inspector.view_full_message(socket, index)}
  end

  @impl true
  def handle_event("close_message_modal", _params, socket) do
    {:noreply, Inspector.close_message_modal(socket)}
  end

  @impl true
  def handle_event("view_full_objective", _params, socket) do
    {:noreply, Inspector.view_full_objective(socket)}
  end

  @impl true
  def handle_event("close_objective_modal", _params, socket) do
    {:noreply, Inspector.close_objective_modal(socket)}
  end

  @impl true
  def handle_event("retry_remote_connection", _params, socket) do
    EvoDashWeb.LiveHooks.NodeAware.initiate_remote_connect(socket, socket.assigns.current_node_id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_to_local", _params, socket) do
    send(self(), {:node_selected, "local"})
    {:noreply, socket}
  end

  @impl true
  def handle_event("open_send_message", %{"id" => id}, socket) do
    agent_id = String.to_integer(id)
    {:noreply, assign(socket, send_message_agent_id: agent_id, send_message_text: "")}
  end

  @impl true
  def handle_event("close_send_message", _params, socket) do
    {:noreply, assign(socket, send_message_agent_id: nil, send_message_text: "")}
  end

  @impl true
  def handle_event("validate_send_message", %{"message" => message}, socket) do
    {:noreply, assign(socket, :send_message_text, message)}
  end

  @impl true
  def handle_event("send_agent_message", %{"agent_id" => id, "message" => message}, socket) do
    agent_id = String.to_integer(id)
    node = socket.assigns.current_node

    # Return shapes (verified): success = {:ok, :ok} (local and remote); a
    # missing agent surfaces as a NESTED {:ok, {:error, :not_found}} on the
    # local path (RemoteNode wraps the RemoteAPI result in {:ok, _}); erpc
    # failures surface as {:error, reason}. Only {:ok, :ok} is a real success —
    # matching the old {:ok, _} falsely reported success for missing agents.
    # Deliberately synchronous (the user expects immediate feedback —
    # optimistic display — and this call is a cheap local/remote store append),
    # but wrapped in the exit-safe boundary: a GenServer.call timeout / dead
    # scheduler EXITS its caller, which would crash the page instead of
    # flashing an error.
    case send_user_message_safely(node, agent_id, message) do
      {:ok, :ok} ->
        optimistic_messages =
          OptimisticMessages.append(socket.assigns.optimistic_messages, agent_id, message)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Message sent to agent"))
         |> assign(
           send_message_agent_id: nil,
           send_message_text: "",
           optimistic_messages: optimistic_messages
         )}

      {:ok, {:error, reason}} ->
        {:noreply, send_message_error_flash(socket, reason)}

      {:error, reason} ->
        {:noreply, send_message_error_flash(socket, reason)}

      other ->
        {:noreply, send_message_error_flash(socket, other)}
    end
  end

  @impl true
  # Retry button on the page-load error banner: clear the recorded error and
  # re-run the SAME async load (no polling, no auto-retry timer).
  def handle_event("retry_agents_load", _params, socket) do
    {:noreply, socket |> assign(:agents_error, nil) |> start_async_load()}
  end

  # Sends a user message through the exit-safe boundary and FLATTENS
  # `EvoDash.SafeCall`'s wrapper, so the result keeps its documented shape:
  # `{:ok, :ok}` (success), `{:ok, {:error, reason}}` (missing agent) or
  # `{:error, reason}` (RPC / exit failure — a `GenServer.call` timeout lands
  # here instead of killing the LiveView).
  # The transport is the call-time seam `:agents_send_message_runner` (the same
  # default-inert shape as `:agents_history_runner` / `:agents_list_runner`):
  # `(node, agent_id, message) -> {:ok, :ok} | {:ok, {:error, reason}} |
  # {:error, reason}`, resolved HERE — at the call site — so a test can drive
  # `send_agent_message` without the shared `EvoGit.AgentScheduler` GenServer
  # call (whose production 5 s budget EXITS on a loaded host). Production
  # behaviour is unchanged: the default is the real node-aware delegate.
  defp send_user_message_safely(node, agent_id, message) do
    runner =
      Application.get_env(
        :evo_dash,
        :agents_send_message_runner,
        &EvoDash.NodeContext.send_user_message/3
      )

    case SafeCall.run(fn -> runner.(node, agent_id, message) end) do
      {:ok, value} -> value
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Async load machinery
  # ---------------------------------------------------------------------------

  # Kicks off the async page load (agents + config status + threshold cache).
  # Sets the loading flag and a fresh generation; the task sends
  # {:agents_data_loaded, node, gen, result} back, which is stale-guarded by
  # generation + node in handle_info/2.
  defp start_async_load(socket) do
    parent = self()
    node = socket.assigns.current_node
    gen = Map.get(socket.assigns, :load_generation, 0) + 1
    threshold_cache = socket.assigns.threshold_cache

    # A new load supersedes any previous failure: the banner clears as soon as
    # the retry is in flight.
    socket = assign(socket, agents_loading: true, load_generation: gen, agents_error: nil)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      # Exit-safe boundary: the load RPCs to a possibly-dead remote daemon (or a
      # node that disconnected mid-flight). `SafeCall.run/1` captures an `exit`
      # (a GenServer.call timeout / dead target, which `rescue` cannot catch) as
      # an error VALUE, so the result message is ALWAYS sent and
      # `agents_loading` can never wedge.
      result =
        case SafeCall.run(fn -> LoadData.load(node, threshold_cache) end) do
          {:ok, {:ok, data}} -> {:ok, data}
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
          {:ok, other} -> {:error, {:unexpected_load_result, other}}
        end

      send(parent, {:agents_data_loaded, node, gen, result})
    end)

    socket
  end

  # Spawns the shared async agent refresh (used by the {:agents_updated, node}
  # broadcasts, the {:agent_registered} summary-fallback, and the
  # {:agent_updated} missing-agent race). Bumps the monotonic :refresh_seq
  # (never reset); the result is stale-guarded by seq + node in handle_info/2.
  defp spawn_agents_refresh(socket) do
    parent = self()
    node = socket.assigns.current_node
    seq = Map.get(socket.assigns, :refresh_seq, 0) + 1
    threshold_cache = socket.assigns.threshold_cache

    socket = assign(socket, :refresh_seq, seq)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      # Exit-safe boundary: the refresh RPCs to a possibly-dead remote daemon.
      # `SafeCall.run/1` turns an exit (which `rescue` cannot catch) into an
      # error value, so the result message is always sent; the seq stale-guard
      # drops late/duplicate results and an error keeps the last good tree.
      result =
        case SafeCall.run(fn -> LoadData.refresh(node, threshold_cache) end) do
          {:ok, {agents, cache}} -> {:ok, agents, cache}
          {:error, reason} -> {:error, reason}
          {:ok, other} -> {:error, {:unexpected_refresh_result, other}}
        end

      send(parent, {:agents_refresh_result, seq, node, result})
    end)

    socket
  end

  @impl true
  def terminate(_reason, socket) do
    StreamWatch.detach(socket)
    :ok
  end

  # Inspector/template entry points that the (unchanged) template calls as bare
  # local functions — the implementation lives in EvoDashWeb.AgentsLive.Inspector.
  defp selected_inspector_agent(assigns), do: Inspector.selected_inspector_agent(assigns)

  defp inspector_scope(assigns), do: Inspector.inspector_scope(assigns)

  defp inspector_message_marker(entry, index),
    do: Inspector.inspector_message_marker(entry, index)

  # Fetches (or refreshes) the commit graph, but ONLY while the commit-history
  # view is active — the tree view must never trigger a git RPC. Mirrors the
  # other async loads: the task runs in an EvoDash.TaskSupervisor child (never in
  # the LiveView process), the runner seam is resolved AT SPAWN TIME (inside the
  # task), and the result is stale-guarded on a monotonic seq + the viewed node.
  #
  # First keeps the rendered graph in sync with the CURRENT agent list (a
  # newly-spawned child's progress path/ring appears immediately), then
  # refetches — throttled to commit_graph_min_interval_ms/0; a throttled request
  # arms a one-shot tick. `force: true` bypasses the throttle AND the
  # fingerprint gate (first activation, the one-shot tick, a view re-switch).
  #
  # FINGERPRINT GATE (fingerprint-gated calls only, i.e. NOT force: true and
  # the graph is already loaded): a commit-relevance fingerprint of the
  # temporal view's agent set (CommitGraphRefresh.fingerprint/1 — the grouping
  # key, task/task_local ids, depth, parent, the base/tip shas and the ended
  # flag) is compared against the one stored by the last build. UNCHANGED →
  # the flush was status/token/usage/message-count-only, commit-irrelevant:
  # skip BOTH the rebuild and the refetch spawn (no git RPC). CHANGED →
  # rebuild + refetch as before and store the new fingerprint. A fetch already
  # in flight (@commit_graph_loading) is never skipped-changed: its result
  # applies through {:commit_graph_loaded, ...}, which re-stores the
  # fingerprint of the agent set it built from — so the in-flight fetch always
  # converges and no fetch/result loop can form (a result yielding identical
  # raw data stores the CURRENT fingerprint; the next flush then compares
  # equal and skips).
  defp maybe_load_commit_graph(socket, opts) do
    if socket.assigns.left_view != :commits do
      socket
    else
      agents = commit_graph_agents(socket)
      force? = Keyword.get(opts, :force, false) or not socket.assigns.commit_graph_loaded

      # Skip the fingerprint work entirely on the bypass paths.
      cond do
        force? ->
          refresh_commit_graph(socket, agents, force: true, gate: false)

        # A fetch is already in flight: never gate (and never re-spawn) — its
        # result applies the freshest data and re-stores the fingerprint.
        socket.assigns.commit_graph_loading ->
          refresh_commit_graph(socket, agents, force: false, gate: false)

        true ->
          refresh_commit_graph(socket, agents, force: false, gate: true)
      end
    end
  end

  # Rebuild + (maybe) refetch. `gate: true` compares the agent set's
  # commit-relevance fingerprint against the stored one and short-circuits on
  # a match; `gate: false` always rebuilds. `force: true` additionally bypasses
  # the fetch throttle (view switch / tick fire); `force: false` follows the
  # throttle/tick rules.
  defp refresh_commit_graph(socket, agents, force: force?, gate: gate?) do
    if gate? do
      fingerprint = CommitGraphRefresh.fingerprint(agents)

      if MapSet.size(fingerprint) > 0 and fingerprint == socket.assigns.commit_graph_fingerprint do
        # Commit-irrelevant change — the view model would be identical.
        socket
      else
        socket
        |> rebuild_commit_graph(agents, fingerprint)
        |> fetch_commit_graph(agents, fingerprint, force?)
      end
    else
      socket
      |> rebuild_commit_graph(agents, nil)
      |> fetch_commit_graph(agents, nil, force?)
    end
  end

  # Rebuilds @commit_graph from the last fetched raw data + the given agents,
  # so the overlay (progress paths, ring positions) tracks agents without a
  # git RPC. A no-op before the first successful fetch. `fingerprint` (nil on
  # the bypass paths) is stored so the NEXT fingerprint-gated call compares
  # against what was actually built. The user's fold (collapse/expand) set is
  # threaded through, so a refresh never resets the fold state.
  defp rebuild_commit_graph(socket, agents, fingerprint) do
    if socket.assigns.commit_graph_loaded do
      assign(socket,
        commit_graph:
          CommitGraph.build(
            socket.assigns.commit_graph_raw,
            agents,
            socket.assigns.commit_fold_expanded
          ),
        commit_graph_fingerprint: fingerprint || CommitGraphRefresh.fingerprint(agents)
      )
    else
      socket
    end
  end

  # Fold events are inert unless the commits view is the ACTIVE view over an
  # already-fetched graph: there are no gap rows to click and nothing to
  # re-fold — and critically, they must never start a fetch of their own.
  defp commit_folds_active?(socket) do
    socket.assigns.left_view == :commits and socket.assigns.commit_graph_loaded
  end

  # Rebuilds @commit_graph in place for a FOLD (collapse/expand) change — the
  # raw commit data is already in memory, so this is pure view-model work: no
  # git RPC, no fetch spawn, no throttle/fingerprint consultation. A no-op
  # before the first successful fetch (there is nothing to re-fold).
  defp rebuild_commit_graph_folds(socket) do
    if socket.assigns.commit_graph_loaded do
      assign(socket,
        commit_graph:
          CommitGraph.build(
            socket.assigns.commit_graph_raw,
            commit_graph_agents(socket),
            socket.assigns.commit_fold_expanded
          )
      )
    else
      socket
    end
  end

  # Spawns the refetch (or arms the one-shot tick when throttled) and stores
  # `fingerprint` so the fetch's result path knows which agent set it captured.
  # `force?` bypasses the throttle (view switch / tick fire).
  defp fetch_commit_graph(socket, agents, fingerprint, force?) do
    groups = commit_graph_groups(agents)

    cond do
      groups == [] ->
        assign(socket,
          commit_graph: [],
          commit_graph_loaded: true,
          commit_graph_loading: false,
          commit_graph_fingerprint: fingerprint || CommitGraphRefresh.fingerprint(agents)
        )

      force? or not commit_graph_throttled?(socket) ->
        spawn_commit_graph_fetch(socket, fingerprint)

      true ->
        schedule_commit_graph_tick(socket)
    end
  end

  # The agent set the TEMPORAL view is built from: the LIVE agents (@agents)  # MERGED with the in-session RETAINED (ended) agents (@retained_agents),
  # de-duplicated by id with the LIVE copy winning. Retained agents contribute
  # lane metadata (and their START/END markers) but never tips, because their
  # commits already live in the task's durable ref ancestry. The agent TREE
  # (@agents) is deliberately NOT fed from here.
  defp commit_graph_agents(socket) do
    live = socket.assigns.agents
    live_ids = MapSet.new(live, & &1.id)

    retained =
      socket.assigns.retained_agents
      |> Map.values()
      |> Enum.reject(&MapSet.member?(live_ids, &1.id))

    live ++ retained
  end

  # Eligible agents' commit ranges grouped for the TASK-scoped commit-graph RPC.
  # A group is `{repo_key, task_id}` (both binaries — the durable task ref is
  # per task AND per repo) and carries only the NON-ended agents' tips
  # (`live_tips`): a retained/ended agent's commits are already in the task's
  # durable ref ancestry, so it contributes its lane but no tip. Agents lacking
  # a repo_key, base_commit, current_commit or task_id are skipped. Sorted by
  # `{repo_key, task_id}` for deterministic task input.
  defp commit_graph_groups(agents) do
    agents
    |> Enum.filter(fn a ->
      is_binary(Map.get(a, :repo_root)) and is_binary(Map.get(a, :base_commit)) and
        is_binary(Map.get(a, :current_commit)) and is_binary(Map.get(a, :task_id))
    end)
    |> Enum.group_by(fn a -> {Map.get(a, :repo_root), Map.get(a, :task_id)} end)
    |> Enum.map(fn {{repo_key, task_id}, group} ->
      live_tips =
        group
        |> Enum.reject(&(Map.get(&1, :ended) == true))
        |> Enum.map(&Map.get(&1, :current_commit))
        |> Enum.uniq()

      %{repo_key: repo_key, task_id: task_id, live_tips: live_tips}
    end)
    |> Enum.sort_by(fn %{repo_key: repo_key, task_id: task_id} -> {repo_key, task_id} end)
  end

  # The commit-graph minimum interval, resolved AT CALL TIME so both the throttle
  # check and the armed one-shot tick delay read the same value. The app-env seam
  # :agents_live_commit_graph_tick_ms lets tests shrink the window; production
  # behaviour is unchanged (default 1000ms) when it is unset.
  defp commit_graph_min_interval_ms do
    Application.get_env(:evo_dash, :agents_live_commit_graph_tick_ms, 1000)
  end

  # True when the last fetch is inside the minimum interval.
  defp commit_graph_throttled?(socket) do
    case socket.assigns.commit_graph_fetched_at do
      nil -> false
      at -> System.monotonic_time(:millisecond) - at < commit_graph_min_interval_ms()
    end
  end

  # Arms ONE one-shot tick (never a repeating timer) so a throttled refresh is
  # eventually served. The boolean assign guarantees a single timer per window.
  defp schedule_commit_graph_tick(socket) do
    if socket.assigns.commit_graph_tick_scheduled do
      socket
    else
      Process.send_after(self(), :commit_graph_tick, commit_graph_min_interval_ms())
      assign(socket, :commit_graph_tick_scheduled, true)
    end
  end

  # Spawns the async commit-graph fetch: ONE runner call per `{repo_key, task_id}`
  # group, passing that task's live tips + the limit. The seam
  # :agents_commit_graph_runner (default &EvoDash.NodeContext.list_task_commit_graph/5)
  # is resolved AT SPAWN TIME so tests can stub it. The per-group replies are
  # folded by CommitGraphRefresh.fetch_result/3 with PARTIAL-SUCCESS semantics:
  # a failing group drops only ITS data (recorded as a
  # {:commit_graph_repo_failed, {repo_key, task_id}, reply} failure) while the
  # successful groups still fold into ONE %{repo_key => %{commits, refs}} map —
  # the keying the pure assembler expects (it groups agents by
  # `repo_root || repo_id`); {:error, _} surfaces ONLY when EVERY group fails.
  # The `fingerprint` captured at spawn time rides along as the fetch's
  # bookkeeping value (see fetch_commit_graph/3).
  defp spawn_commit_graph_fetch(socket, fingerprint) do
    parent = self()
    node = socket.assigns.current_node
    seq = Map.get(socket.assigns, :commit_graph_seq, 0) + 1
    groups = commit_graph_groups(commit_graph_agents(socket))

    socket =
      assign(socket,
        commit_graph_seq: seq,
        commit_graph_loading: true,
        commit_graph_fingerprint: fingerprint,
        commit_graph_fetched_at: System.monotonic_time(:millisecond),
        commit_graph_tick_scheduled: false
      )

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      runner =
        Application.get_env(
          :evo_dash,
          :agents_commit_graph_runner,
          &EvoDash.NodeContext.list_task_commit_graph/5
        )

      # Exit-safe boundary: the commit-graph RPC targets a possibly-dead remote
      # daemon (or a node that disconnected mid-flight). `SafeCall.run/1`
      # captures an exit (which `rescue` cannot catch) as an error value, so the
      # result message is ALWAYS sent and the commit view can never wedge on a
      # spinner. A folded per-group `{:error, failure}` passes through verbatim
      # (the renderer's stale-warning strip / first-load error strip).
      result =
        case SafeCall.run(fn -> CommitGraphRefresh.fetch_result(groups, runner, node) end) do
          {:ok, folded_result} -> folded_result
          {:error, _reason} -> {:error, :commit_graph_fetch_failed}
        end

      send(parent, {:commit_graph_loaded, node, seq, result})
    end)

    socket
  end

  defp commit_bg_class(agent) do
    if agent.current_commit != agent.base_commit do
      # Uncommitted changes on this agent's branch — warning-family highlight
      # (semantic meaning preserved) on the hairline commit chip.
      "bg-warning/20 border border-warning/30"
    else
      "bg-base-200/60 border border-base-300"
    end
  end

  defp shorten_sha(sha) when is_binary(sha) do
    if String.length(sha) > 8 do
      String.slice(sha, 0, 8) <> "…"
    else
      sha
    end
  end

  defp shorten_sha(other), do: other

  # Shared error flash for failed send attempts (nested {:ok, {:error, _}} on
  # the local path and {:error, _} erpc failures both land here).
  defp send_message_error_flash(socket, reason) do
    put_flash(
      socket,
      :error,
      gettext("Failed to send message: %{reason}", reason: inspect(reason))
    )
  end
end
