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

  The page module only ROUTES: `mount/3`, `handle_params/3` and the
  `handle_info/2` / `handle_event/2` clauses delegate every state transition,
  and the work lives in the support modules beside this file —
  `Loader` (the async page-load / refresh spawners), `AgentMerge` +
  `PendingEvents` (the coalesced incremental merges), `LoadData` (the
  node-aware loads), `Inspector` + `StreamWatch` + `AgentList` +
  `HistoryGate` + `OptimisticMessages` (the selected-agent detail panel and
  its push stream), `CommitGraphState` + `CommitGraph` +
  `CommitGraphRefresh` (the temporal commit-history view, its fold state and
  its throttled fetch), `SendMessage` (the "Send Message" modal flow), plus
  `TreeView`, `ContextMeter`, `ThresholdCache`, `StreamPanel`,
  `StreamPresentation`, `StreamLimits`, `RuntimeStream` and `ToolCallDisplay`
  for the presentation helpers the template renders.
  """
  use EvoDashWeb, :live_view

  alias EvoDashWeb.AgentsLive.{
    AgentMerge,
    CommitGraphState,
    ContextMeter,
    Inspector,
    Loader,
    PendingEvents,
    SendMessage,
    StreamPanel,
    StreamWatch
  }

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
    # kicks off the async page load (Loader.start_page_load/1), which populates
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
        # reload itself happens asynchronously below (Loader.start_page_load/1), so
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
        socket |> Inspector.maybe_attach() |> Loader.start_page_load()
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  # Async page-load result (spawned by Loader.start_page_load/1). Applies the fresh
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
            |> CommitGraphState.maybe_load([])

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
            |> CommitGraphState.maybe_load([])

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
        :refresh -> Loader.spawn_refresh(socket)
        :refetch -> Inspector.refetch_selected_history(socket)
        :none -> socket
      end

    # A burst of agent commits extends the graph (new dots + moved rings;
    # throttled/coalesced in CommitGraphState); no-op unless the commit-history
    # view is active.
    {:noreply, CommitGraphState.maybe_load(socket, [])}
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
  # Async commit-graph result (spawned by CommitGraphState). Ownership, the node
  # + seq stale guards and the partial-success folding live there.
  def handle_info({:commit_graph_loaded, node, seq, result}, socket),
    do: CommitGraphState.loaded(socket, node, seq, result)

  @impl true
  # One-shot retry armed when a commit-graph refresh request was throttled.
  def handle_info(:commit_graph_tick, socket), do: CommitGraphState.tick(socket)

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    {:noreply, Inspector.select(socket, id)}
  end

  @impl true
  # Left-panel view switcher (agent tree / commit history) — only the two literal
  # values are accepted; anything else is a no-op (see CommitGraphState).
  def handle_event("switch_left_view", params, socket),
    do: {:noreply, CommitGraphState.switch_left_view(socket, params["view"])}

  @impl true
  # Commit-history FOLD (collapse/expand) — a pure in-process rebuild from
  # @commit_graph_raw, never a git RPC (see CommitGraphState).
  def handle_event("toggle_commit_fold", params, socket),
    do: {:noreply, CommitGraphState.toggle_fold(socket, params)}

  @impl true
  def handle_event("expand_all_commit_folds", _params, socket),
    do: {:noreply, CommitGraphState.expand_all(socket)}

  @impl true
  def handle_event("collapse_all_commit_folds", _params, socket),
    do: {:noreply, CommitGraphState.collapse_all(socket)}

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
  def handle_event("open_send_message", %{"id" => id}, socket),
    do: SendMessage.open(socket, id)

  @impl true
  def handle_event("close_send_message", _params, socket), do: SendMessage.close(socket)

  @impl true
  def handle_event("validate_send_message", %{"message" => message}, socket),
    do: SendMessage.validate(socket, message)

  @impl true
  # The message is delivered synchronously (the user expects immediate feedback)
  # but through the exit-safe boundary and the call-time
  # `:agents_send_message_runner` seam — see EvoDashWeb.AgentsLive.SendMessage.
  def handle_event("send_agent_message", %{"agent_id" => id, "message" => message}, socket),
    do: SendMessage.send(socket, id, message)

  @impl true
  # Retry button on the page-load error banner: clear the recorded error and
  # re-run the SAME async load (no polling, no auto-retry timer).
  def handle_event("retry_agents_load", _params, socket),
    do: {:noreply, Loader.start_page_load(socket)}

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
end
