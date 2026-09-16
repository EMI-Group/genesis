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

  ALL node-aware data loading is ASYNC: the page load (`handle_params`),
  broadcast-triggered refreshes, and history fetches run in
  `EvoDash.TaskSupervisor` children — the LiveView process never blocks on a
  cross-node RPC. Results arrive as tagged messages guarded by monotonic
  generation/sequence counters (stale results are dropped) and the node
  currently being viewed. History transfers are gated on the
  `RemoteAPI.list_agents/0` `:message_count` field: an agent's full history is
  re-fetched only when its message count changed (see `HistoryGate`).
  """
  use EvoDashWeb, :live_view

  alias EvoDashWeb.AgentsLive.{
    HistoryGate,
    LoadData,
    OptimisticMessages,
    PendingEvents,
    ThresholdCache,
    ToolCallDisplay
  }

  alias EvoGit.Platform

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
        selected_agent_id: nil,
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
        # merged into the displayed history at render time and dropped once the
        # agent's next turn drains the message into context.
        optimistic_messages: %{},
        # Async page-load state: agents_loading gates the tree's loading UI;
        # load_generation is a monotonic counter that stale-guards async load
        # results (only the newest generation may apply).
        agents_loading: true,
        load_generation: 0,
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
        full_message_pending_agent_id: nil,
        # Agent-event coalescing (see EvoDashWeb.AgentsLive.PendingEvents):
        # buffered incremental events awaiting the 300ms trailing-edge flush,
        # a once-per-window scheduling flag, and a coalesced refresh trigger.
        pending_agent_events: PendingEvents.new(),
        agent_flush_scheduled: false,
        pending_agents_refresh: false
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/agents")

    current_node = socket.assigns.current_node
    previous_node = socket.assigns[:previous_node] || current_node

    socket =
      if current_node != previous_node do
        # Node changed (e.g. user switched from Local to a remote target, or
        # vice versa). Clear per-agent selection state, the history gate, and
        # the threshold cache — agent ids and config are per-node. The agent
        # reload itself happens asynchronously below (start_async_load/1), so
        # the page never blocks on cross-node RPCs.
        socket
        |> assign(
          previous_agent_ids: MapSet.new(),
          agents_initialized: false,
          previous_statuses: %{},
          new_agent_ids: MapSet.new(),
          changed_status_ids: MapSet.new(),
          selected_agent_id: nil,
          selected_history_entry: nil,
          selected_objective: nil,
          previous_node: current_node,
          # Agent ids are per-node; optimistic messages from the previous node
          # must not leak into a different node's agent list.
          optimistic_messages: %{},
          history_gate: %{},
          threshold_cache: nil,
          history_loading_agent_id: nil,
          full_message_pending_agent_id: nil,
          # Drop any buffered agent events from the previous node so stale-node
          # events never leak into the newly-viewed node's tree. A flush timer
          # already in flight is harmless: the buffer is empty, so the flush is
          # a no-op.
          pending_agent_events: PendingEvents.new(),
          agent_flush_scheduled: false,
          pending_agents_refresh: false
        )
      else
        assign(socket, :previous_node, current_node)
      end

    # Kick off the async page load (agents + config status + threshold cache).
    # The generation guard in handle_info({:agents_data_loaded, ...}) drops
    # stale results, so starting unconditionally here is safe.
    socket = start_async_load(socket)

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
            |> apply_agents_result(agents)
            |> assign(
              config_status: config_status,
              threshold_cache: threshold_cache,
              agents_loading: false,
              previous_node: node
            )

          {:noreply, socket}

        {:error, _reason} ->
          # Keep whatever is currently rendered; just clear the loading flag so
          # the page is usable (the broadcast paths will retry).
          {:noreply, assign(socket, :agents_loading, false)}
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
      socket
      |> assign(:pending_agents_refresh, true)
      |> maybe_schedule_agent_flush()
      |> then(&{:noreply, &1})
    else
      # Foreign-node event — dropped before buffering so it never schedules a
      # flush.
      {:noreply, socket}
    end
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
          gettext("Remote connect failed: %{reason}", reason: inspect(reason))
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
            |> apply_agents_result(agents)
            |> assign(threshold_cache: threshold_cache)

          {:noreply, socket}

        {:error, _reason} ->
          # Keep the last good tree; the next broadcast will retry.
          {:noreply, socket}
      end
    end
  end

  @impl true
  # Incremental agent events are COALESCED: each clause only node-filters and
  # buffers the raw event (see EvoDashWeb.AgentsLive.PendingEvents), then arms
  # a single 300ms trailing-edge flush. No merge work happens here — the whole
  # burst collapses into ONE merge + render on :flush_agent_events below, so a
  # burst cannot starve the LiveView mailbox (a user phx-click no longer waits
  # behind N synchronous merges) and cannot flush as N rapid DOM patches.
  def handle_info({:agent_registered, _id, _summary, _node} = event, socket) do
    {:noreply, buffer_agent_event(socket, event)}
  end

  @impl true
  def handle_info({:agent_updated, _id, _changed_fields, _node} = event, socket) do
    {:noreply, buffer_agent_event(socket, event)}
  end

  @impl true
  def handle_info({:agent_removed, _id, _node} = event, socket) do
    {:noreply, buffer_agent_event(socket, event)}
  end

  @impl true
  # Trailing-edge flush of the coalesced agent-event buffer. Drains the
  # buffered events in ARRIVAL order and applies them through the same
  # in-memory merge paths as before — threading the socket through each apply
  # and returning a SINGLE {:noreply, socket}, so the burst yields exactly one
  # render/diff. The fallback refresh and the selected-agent history refetch
  # are coalesced to at most one each.
  def handle_info(:flush_agent_events, socket) do
    events = PendingEvents.drain(socket.assigns.pending_agent_events)
    refresh? = socket.assigns.pending_agents_refresh

    socket =
      assign(socket,
        pending_agent_events: PendingEvents.new(),
        agent_flush_scheduled: false,
        pending_agents_refresh: false
      )

    {socket, needs_refresh?, refetch?} =
      Enum.reduce(events, {socket, refresh?, false}, &apply_buffered_agent_event/2)

    socket =
      cond do
        # A refresh was spawned — its result path already runs
        # maybe_fetch_selected_history/1, so do not also refetch here.
        needs_refresh? -> spawn_agents_refresh(socket)
        refetch? -> refetch_selected_history(socket)
        true -> socket
      end

    {:noreply, socket}
  end

  @impl true
  # Async history-fetch result (select_agent / view_full_message / broadcast
  # refresh paths). `index` is nil for the select/refresh flows and an integer
  # for the view_full_message safety-net flow (the modal entry is set from the
  # fetched history at that index).
  def handle_info({:agent_history_loaded, agent_id, node, result, index}, socket) do
    # Stale-guard: only apply history for the currently selected agent on the
    # node being viewed (the user may have selected another agent or switched
    # nodes while the fetch was in flight).
    if agent_id != socket.assigns.selected_agent_id or node != socket.assigns.current_node do
      {:noreply, socket}
    else
      case result do
        {:ok, entries} ->
          agents =
            update_agent_in_list(socket.assigns.agents, agent_id, fn agent ->
              %{agent | history: entries}
            end)

          # Record the message count this history corresponds to so the poll
          # does not re-fetch while the agent's conversation is unchanged. The
          # count comes from the most recent list_agents summary for this
          # agent (fall back to the fetched length when absent).
          agent = Enum.find(agents, &(&1.id == agent_id))
          count = (agent && agent.message_count) || length(entries)
          history_gate = HistoryGate.record(socket.assigns.history_gate, agent_id, count)

          socket =
            assign(socket,
              agents: agents,
              history_gate: history_gate,
              history_loading_agent_id: nil,
              full_message_pending_agent_id: nil
            )

          socket =
            if is_integer(index) do
              entry = Enum.at(entries, index)
              assign(socket, :selected_history_entry, entry)
            else
              socket
            end

          {:noreply, socket}

        {:error, _reason} ->
          # Clear the pending flags so the UI recovers; the broadcast
          # paths will retry the fetch.
          {:noreply,
           assign(socket,
             history_loading_agent_id: nil,
             full_message_pending_agent_id: nil
           )}
      end
    end
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    agent_id = String.to_integer(id)

    socket =
      assign(socket,
        selected_agent_id: agent_id,
        show_usage: false,
        selected_history_entry: nil,
        full_message_pending_agent_id: nil
      )

    # Lazy-load chat history for the selected agent — asynchronously so the
    # page never blocks on the (possibly cross-node) history RPC. First
    # selection always fetches (no last-seen entry in the gate); later
    # selections fetch only when the message count moved on.
    agent = Enum.find(socket.assigns.agents, &(&1.id == agent_id))

    socket =
      if agent &&
           HistoryGate.need_fetch?(socket.assigns.history_gate, agent_id, agent.message_count) &&
           socket.assigns.history_loading_agent_id != agent_id do
        socket
        |> assign(history_loading_agent_id: agent_id)
        |> spawn_history_fetch(agent_id, nil)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    {:noreply,
     assign(socket,
       selected_agent_id: nil,
       selected_history_entry: nil,
       selected_objective: nil,
       show_usage: false
     )}
  end

  @impl true
  def handle_event("toggle_usage", _params, socket) do
    {:noreply, assign(socket, :show_usage, !socket.assigns.show_usage)}
  end

  @impl true
  def handle_event("view_full_message", %{"index" => index}, socket) do
    index = String.to_integer(index)

    agent = Enum.find(socket.assigns.agents, &(&1.id == socket.assigns.selected_agent_id))

    if agent && agent.history == [] do
      # Safety net: history is empty — fetch it asynchronously and set the
      # selected entry when the result arrives (the index is carried in the
      # result message). A brief loading state shows in the chat section.
      socket =
        socket
        |> assign(
          full_message_pending_agent_id: agent.id,
          history_loading_agent_id: agent.id
        )
        |> spawn_history_fetch(agent.id, index)

      {:noreply, socket}
    else
      entry =
        agent && Enum.at(merged_history(agent, socket.assigns.optimistic_messages), index)

      {:noreply, assign(socket, :selected_history_entry, entry)}
    end
  end

  @impl true
  def handle_event("close_message_modal", _params, socket) do
    {:noreply, assign(socket, :selected_history_entry, nil)}
  end

  @impl true
  def handle_event("view_full_objective", _params, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.id == socket.assigns.selected_agent_id))

    if agent do
      {:noreply, assign(socket, :selected_objective, agent.objective)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_objective_modal", _params, socket) do
    {:noreply, assign(socket, :selected_objective, nil)}
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
    # Deliberately synchronous: the user expects immediate feedback (optimistic
    # display), and this call is a cheap local/remote store append.
    case EvoDash.NodeContext.send_user_message(node, agent_id, message) do
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

    socket = assign(socket, agents_loading: true, load_generation: gen)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      # Node-boundary rescue: the load RPCs to a possibly-dead remote daemon
      # (or a node that disconnected mid-flight). (1) Do we expect this error?
      # Yes — the remote daemon can die or the SSH tunnel drop between polls.
      # (2) Is try/rescue the cleanest approach? Yes — the alternative is the
      # page wedging at the loading state forever; the stale-guard below drops
      # late results and an error just clears the loading flag.
      result =
        try do
          EvoDashWeb.AgentsLive.LoadData.load(node, threshold_cache)
        rescue
          _ -> {:error, :load_failed}
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
      # Node-boundary rescue: the refresh RPCs to a possibly-dead remote
      # daemon. (1) Do we expect this error? Yes — the remote node can die or
      # disconnect mid-flight. (2) Is try/rescue the cleanest approach? Yes —
      # the seq stale-guard drops late/duplicate results and an error keeps the
      # last good tree.
      result =
        try do
          {agents, cache} = EvoDashWeb.AgentsLive.LoadData.refresh(node, threshold_cache)
          {:ok, agents, cache}
        rescue
          _ -> {:error, :refresh_failed}
        end

      send(parent, {:agents_refresh_result, seq, node, result})
    end)

    socket
  end

  # Spawns an async history fetch for `agent_id` on the viewed node. `index`
  # is nil for select/refresh flows, or the clicked entry index for the
  # view_full_message safety net. The history runner is injectable via the
  # :agents_history_runner env seam, resolved AT SPAWN TIME (inside the task)
  # so tests can stub it.
  defp spawn_history_fetch(socket, agent_id, index) do
    parent = self()
    node = socket.assigns.current_node

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      # Node-boundary rescue: the history RPC targets a possibly-dead remote
      # daemon. (1) Do we expect this error? Yes — the remote node can die
      # mid-flight. (2) Is try/rescue the cleanest approach? Yes — the
      # stale-guard drops late results and an error just clears the loading
      # flags.
      result =
        try do
          runner =
            Application.get_env(
              :evo_dash,
              :agents_history_runner,
              &EvoDash.NodeContext.get_agent_history/2
            )

          entries = runner.(node, agent_id) |> messages_to_history_entries()
          {:ok, entries}
        rescue
          _ -> {:error, :history_fetch_failed}
        end

      send(parent, {:agent_history_loaded, agent_id, node, result, index})
    end)

    socket
  end

  # Shared application of a fresh agent list (from the async load or a refresh
  # task): recomputes all the tracking assigns, carries over already-fetched
  # histories when the history gate says they are still current, records the
  # fresh message counts into the gate, and (re)triggers a history fetch for
  # the selected agent when its count moved on.
  defp apply_agents_result(socket, agents) do
    current_ids = MapSet.new(agents, & &1.id)
    current_statuses = Map.new(agents, fn a -> {a.id, a.status} end)

    # Detect new agents. The FIRST apply per node (initial page mount and the
    # first load after a node switch) must not mark pre-existing agents as
    # new — otherwise every already-registered agent plays the one-shot
    # spawn animation on page load.
    new_agent_ids =
      if socket.assigns.agents_initialized do
        MapSet.difference(current_ids, socket.assigns.previous_agent_ids)
      else
        MapSet.new()
      end

    # Detect status changes (agents that exist in both but have different status)
    changed_status_ids =
      current_ids
      |> MapSet.intersection(socket.assigns.previous_agent_ids)
      |> MapSet.filter(fn id ->
        current_statuses[id] != socket.assigns.previous_statuses[id]
      end)

    id_to_display = Map.new(agents, fn a -> {a.id, a.task_local_id || a.id} end)

    # Carry over already-fetched histories and (conditionally) record the gate.
    # A fresh agent built from summaries carries history: [], so the old
    # (fetched) history is ALWAYS carried over while an old row exists — this
    # keeps the already-rendered entries MOUNTED while the refresh-induced
    # refetch is in flight. Blanking it on a moved message count would swap the
    # whole list for the "Loading history…" spinner and re-animate every entry
    # once the refetch landed. The gate is recorded ONLY when the count is
    # unchanged (its last-seen entry), so a moved count still reports
    # "needs fetch" and the refetch is triggered — no redundant re-transfers.
    old_agents = socket.assigns.agents

    {agents, history_gate} =
      Enum.reduce(agents, {[], socket.assigns.history_gate}, fn agent, {acc, gate} ->
        old_agent = Enum.find(old_agents, &(&1.id == agent.id))

        keep_history = old_agent != nil and old_agent.history != []

        agent = if keep_history, do: %{agent | history: old_agent.history}, else: agent

        gate =
          if keep_history and not HistoryGate.need_fetch?(gate, agent.id, agent.message_count) do
            HistoryGate.record(gate, agent.id, agent.message_count)
          else
            gate
          end

        {[agent | acc], gate}
      end)

    agents = Enum.reverse(agents)

    socket
    |> assign(
      agents: agents,
      id_to_display: id_to_display,
      repo_trees: build_repo_trees(agents),
      previous_agent_ids: current_ids,
      previous_statuses: current_statuses,
      new_agent_ids: new_agent_ids,
      changed_status_ids: changed_status_ids,
      agents_initialized: true,
      history_gate: history_gate
    )
    |> maybe_fetch_selected_history()
  end

  # Triggers an async history fetch for the selected agent when the history
  # gate says the stored history (if any) no longer matches the agent's current
  # message count. No-op when nothing is selected, the agent is gone, the gate
  # says the history is current, or a fetch is already in flight.
  defp maybe_fetch_selected_history(socket) do
    selected_agent_id = socket.assigns.selected_agent_id

    if selected_agent_id do
      agent = Enum.find(socket.assigns.agents, &(&1.id == selected_agent_id))

      if agent &&
           HistoryGate.need_fetch?(
             socket.assigns.history_gate,
             selected_agent_id,
             agent.message_count
           ) &&
           socket.assigns.history_loading_agent_id != selected_agent_id do
        socket
        |> assign(history_loading_agent_id: selected_agent_id)
        |> spawn_history_fetch(selected_agent_id, nil)
      else
        socket
      end
    else
      socket
    end
  end

  # Triggers an async history fetch for the selected agent when the
  # :message_count carried by the {:agent_updated, ...} broadcast moved on vs
  # the gate's last-seen entry. Called ONLY when changed_fields contains
  # :message_count (the contract: it does whenever the agent's context
  # changed) — the merged agent's count is then the fresh one. No-op when
  # nothing is selected, the agent is gone, the gate says the history is
  # current, or a fetch is already in flight.
  defp refetch_selected_history(socket) do
    selected_agent_id = socket.assigns.selected_agent_id

    if selected_agent_id do
      agent = Enum.find(socket.assigns.agents, &(&1.id == selected_agent_id))

      if agent &&
           HistoryGate.need_fetch?(
             socket.assigns.history_gate,
             selected_agent_id,
             agent.message_count
           ) &&
           socket.assigns.history_loading_agent_id != selected_agent_id do
        socket
        |> assign(history_loading_agent_id: selected_agent_id)
        |> spawn_history_fetch(selected_agent_id, nil)
      else
        socket
      end
    else
      socket
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Agent-event coalescing (see EvoDashWeb.AgentsLive.PendingEvents)
  # ---------------------------------------------------------------------------

  # Node-filters an incremental agent event, appends it to the coalescing
  # buffer (newest-first), and arms the single trailing-edge flush timer.
  # Foreign-node events are dropped BEFORE buffering, so they can never
  # schedule a flush or leak into the currently-viewed node's tree.
  # (Two clauses: the four-tuple registered/updated shapes and the three-tuple
  # removed shape.)
  defp buffer_agent_event(socket, {_tag, _id, node} = event) do
    buffer_node_event(socket, node, event)
  end

  defp buffer_agent_event(socket, {_tag, _id, _payload, node} = event) do
    buffer_node_event(socket, node, event)
  end

  defp buffer_node_event(socket, node, event) do
    if EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?(socket.assigns, node) do
      socket
      |> assign(
        :pending_agent_events,
        PendingEvents.append(socket.assigns.pending_agent_events, event)
      )
      |> maybe_schedule_agent_flush()
    else
      socket
    end
  end

  # Schedules the trailing-edge flush timer ONLY when one is not already
  # pending — the first event of a window arms it, every subsequent event just
  # appends to the existing buffer.
  defp maybe_schedule_agent_flush(socket) do
    if PendingEvents.should_schedule?(socket.assigns.agent_flush_scheduled) do
      Process.send_after(self(), :flush_agent_events, PendingEvents.flush_ms())
      assign(socket, :agent_flush_scheduled, true)
    else
      socket
    end
  end

  # Reducer over the buffered events in ARRIVAL order: threads the socket
  # through each apply and threads two coalescing flags — whether a single
  # fallback refresh is needed, and whether the selected agent needs ONE
  # history refetch (any buffered :agent_updated for the selected agent that
  # carried :message_count). The caller performs at most one of each after the
  # whole burst is applied.
  defp apply_buffered_agent_event(
         {:agent_registered, agent_id, summary, _node},
         {socket, needs_refresh?, refetch?}
       ) do
    case apply_agent_registered(socket, agent_id, summary) do
      {:ok, socket} -> {socket, needs_refresh?, refetch?}
      :fallback -> {socket, true, refetch?}
    end
  end

  defp apply_buffered_agent_event(
         {:agent_updated, agent_id, changed_fields, _node},
         {socket, needs_refresh?, refetch?}
       ) do
    # The refetch is gate-checked by refetch_selected_history/1 at the end;
    # here we only remember whether the selected agent's context moved.
    moved? =
      agent_id == socket.assigns.selected_agent_id and
        Keyword.has_key?(changed_fields, :message_count)

    refetch? = refetch? or moved?

    case apply_agent_updated(socket, agent_id, changed_fields) do
      {:ok, socket} -> {socket, needs_refresh?, refetch?}
      :fallback -> {socket, true, refetch?}
    end
  end

  defp apply_buffered_agent_event(
         {:agent_removed, agent_id, _node},
         {socket, needs_refresh?, refetch?}
       ) do
    {apply_agent_removed(socket, agent_id), needs_refresh?, refetch?}
  end

  # Applies ONE buffered {:agent_registered, id, summary, node} event: a
  # duplicate id (a race with the agents_updated fallback) is a no-op; the
  # event's summary is otherwise merged in-memory for BOTH local and remote
  # events through ONE shared path. Returns {:ok, socket}, or :fallback when
  # the summary lacks fields the tree needs (the caller coalesces one async
  # full refresh instead of merging a broken row).
  defp apply_agent_registered(socket, agent_id, summary) do
    already_exists = Enum.any?(socket.assigns.agents, fn a -> a.id == agent_id end)

    if already_exists do
      {:ok, socket}
    else
      merge_registered_agent(socket, agent_id, summary)
    end
  end

  # Applies ONE buffered {:agent_updated, id, changed_fields, node} event to
  # the socket's in-memory agent tree (the body of the former handle_info
  # clause). Returns {:ok, socket} (already merged), or :fallback when the
  # agent is not yet in our list (a race) — the caller then coalesces a single
  # async full refresh. The selected-agent history refetch is NOT performed
  # here: the flush tracks it across the whole burst and calls
  # refetch_selected_history/1 at most once at the end.
  defp apply_agent_updated(socket, agent_id, changed_fields) do
    agents = socket.assigns.agents
    agent_idx = Enum.find_index(agents, fn a -> a.id == agent_id end)

    if agent_idx == nil do
      # Race — agent not yet in our list, fall back to an async full refresh
      :fallback
    else
      agent = Enum.at(agents, agent_idx)

      # Track old parent_id for children recalculation
      old_parent_id = agent.parent_id

      # Convert changed_fields keyword list to a map for merging
      changed_map =
        changed_fields
        |> Enum.into(%{})
        |> handle_special_fields()

      # Merge changed fields into agent
      agent = Map.merge(agent, changed_map)

      # Recalculate compression_pct if total_tokens changed
      agent =
        if Keyword.has_key?(changed_fields, :total_tokens) do
          threshold = agent.compression_threshold
          pct = trunc(min(agent.total_tokens / max(threshold, 1) * 100, 100))
          %{agent | compression_pct: pct}
        else
          agent
        end

      agents = List.replace_at(agents, agent_idx, agent)

      # Recalculate children if parent_id changed
      agents =
        if Keyword.has_key?(changed_fields, :parent_id) do
          new_parent_id = agent.parent_id

          agents
          |> maybe_update_parent_children(old_parent_id)
          |> maybe_update_parent_children(new_parent_id)
        else
          agents
        end

      socket = assign(socket, :agents, agents)

      # Detect status change
      old_status = socket.assigns.previous_statuses[agent_id]
      new_status = agent.status

      previous_statuses = socket.assigns.previous_statuses
      changed_status_ids = socket.assigns.changed_status_ids

      {previous_statuses, changed_status_ids} =
        if old_status != new_status do
          {Map.put(previous_statuses, agent_id, new_status),
           MapSet.put(changed_status_ids, agent_id)}
        else
          {previous_statuses, changed_status_ids}
        end

      # Update id_to_display if task_local_id changed
      id_to_display = socket.assigns.id_to_display

      id_to_display =
        if Keyword.has_key?(changed_fields, :task_local_id) do
          Map.put(id_to_display, agent_id, agent.task_local_id || agent_id)
        else
          id_to_display
        end

      # Rebuild repo_trees only if context_node or repo_root changed
      repo_trees =
        if Keyword.has_key?(changed_fields, :context_node) or
             Keyword.has_key?(changed_fields, :repo_root) do
          build_repo_trees(agents)
        else
          socket.assigns.repo_trees
        end

      {:ok,
       assign(socket,
         id_to_display: id_to_display,
         repo_trees: repo_trees,
         previous_statuses: previous_statuses,
         changed_status_ids: changed_status_ids
       )}
    end
  end

  # Applies ONE buffered {:agent_removed, id, node} event to the socket's
  # in-memory agent tree (the body of the former handle_info clause): drops the
  # row, orphans its children to parent_id: nil, refreshes the parent's
  # children list, cleans the tracking sets/repo_trees, and clears the
  # selection when the removed agent was selected. Returns the socket.
  defp apply_agent_removed(socket, agent_id) do
    agents = socket.assigns.agents
    removed_agent = Enum.find(agents, fn a -> a.id == agent_id end)

    if removed_agent == nil do
      socket
    else
      parent_id = removed_agent.parent_id

      # Remove the agent
      agents = Enum.reject(agents, fn a -> a.id == agent_id end)

      # Set parent_id to nil for orphaned children
      agents =
        Enum.map(agents, fn a ->
          if a.parent_id == agent_id, do: %{a | parent_id: nil}, else: a
        end)

      # Recalculate children for the removed agent's parent
      agents = maybe_update_parent_children(agents, parent_id)

      # Remove from tracking sets
      id_to_display = Map.delete(socket.assigns.id_to_display, agent_id)
      previous_agent_ids = MapSet.delete(socket.assigns.previous_agent_ids, agent_id)
      new_agent_ids = MapSet.delete(socket.assigns.new_agent_ids, agent_id)
      previous_statuses = Map.delete(socket.assigns.previous_statuses, agent_id)

      # Clear selection if the removed agent was selected
      selected_agent_id =
        if socket.assigns.selected_agent_id == agent_id do
          nil
        else
          socket.assigns.selected_agent_id
        end

      repo_trees = build_repo_trees(agents)

      assign(socket,
        agents: agents,
        id_to_display: id_to_display,
        repo_trees: repo_trees,
        previous_agent_ids: previous_agent_ids,
        new_agent_ids: new_agent_ids,
        previous_statuses: previous_statuses,
        selected_agent_id: selected_agent_id
      )
    end
  end

  defp handle_special_fields(changed_map) do
    changed_map =
      if Map.has_key?(changed_map, :context_node) do
        context_node = changed_map[:context_node]
        path = context_node && context_node.path

        changed_map
        |> Map.put(:context_path, path)
        |> Map.delete(:context_node)
      else
        changed_map
      end

    changed_map =
      if Map.has_key?(changed_map, :phylo_node) do
        phylo_node = changed_map[:phylo_node]
        current_commit = phylo_node && phylo_node.current_commit

        changed_map
        |> Map.put(:current_commit, current_commit)
        |> Map.delete(:phylo_node)
      else
        changed_map
      end

    if Map.has_key?(changed_map, :usage) && is_nil(changed_map[:usage]) do
      Map.put(changed_map, :usage, EvoGit.Agent.Usage.zero())
    else
      changed_map
    end
  end

  defp update_agent_in_list(agents, agent_id, updater_fn) do
    idx = Enum.find_index(agents, fn a -> a.id == agent_id end)

    if idx do
      List.replace_at(agents, idx, updater_fn.(Enum.at(agents, idx)))
    else
      agents
    end
  end

  # Incremental agent registration for BOTH local and remote events. The
  # {:agent_registered, id, summary, node} broadcast carries the agent's
  # summary (the same RemoteAPI.list_agents/0 summary shape
  # LoadData.build_agents consumes — a native term in both cases, no ETS
  # reads and no RPC), so the row is built in-memory and merged into the
  # tree at its sorted position, recomputing the derived fields
  # (children/has_children from parent_id, compression_pct from total_tokens
  # + the node threshold). Returns {:ok, socket}, or :fallback when the
  # summary lacks fields the tree needs (the caller spawns a full async
  # refresh instead).
  defp merge_registered_agent(socket, agent_id, summary) when is_map(summary) do
    case build_registered_agent(socket, agent_id, summary) do
      {:ok, new_agent} ->
        agents = socket.assigns.agents

        # Insert at correct sorted position (by {depth, id})
        insert_idx =
          Enum.find_index(agents, fn a -> {a.depth, a.id} > {new_agent.depth, new_agent.id} end)

        agents =
          if insert_idx do
            List.insert_at(agents, insert_idx, new_agent)
          else
            agents ++ [new_agent]
          end

        # Update parent's children if parent_id is set
        agents =
          if new_agent.parent_id do
            update_agent_in_list(agents, new_agent.parent_id, fn parent ->
              children = LoadData.find_children_from_agents(parent.id, agents)
              %{parent | children: children, has_children: length(children) > 0}
            end)
          else
            agents
          end

        id_to_display =
          Map.put(socket.assigns.id_to_display, agent_id, new_agent.task_local_id || agent_id)

        {:ok,
         assign(socket,
           agents: agents,
           id_to_display: id_to_display,
           previous_agent_ids: MapSet.put(socket.assigns.previous_agent_ids, agent_id),
           new_agent_ids: MapSet.put(socket.assigns.new_agent_ids, agent_id),
           repo_trees: build_repo_trees(agents)
         )}

      :error ->
        :fallback
    end
  end

  defp merge_registered_agent(_socket, _agent_id, _summary), do: :fallback

  # Builds a full tree row from an {:agent_registered} event summary (the
  # RemoteAPI.list_agents/0 summary shape — field mapping mirrors
  # LoadData.build_agents). Returns {:ok, agent_map}, or :error when the
  # summary lacks the fields the tree needs to render a meaningful row
  # (the caller then falls back to a full refresh).
  defp build_registered_agent(socket, agent_id, summary) do
    required = [:status, :depth, :parent_id]

    if Enum.all?(required, &Map.has_key?(summary, &1)) do
      total_tokens = summary[:total_tokens] || 0
      compression_count = summary[:compression_count] || 0
      compression_threshold = safe_compression_threshold(socket)

      compression_pct =
        trunc(min(total_tokens / max(compression_threshold, 1) * 100, 100))

      {:ok,
       %{
         id: agent_id,
         task_local_id: summary[:task_local_id] || agent_id,
         repo_id: summary[:repo_id] || "primary",
         repo_root: summary[:repo_root],
         task_id: summary[:task_id],
         task_number: summary[:task_number],
         status: summary[:status] || :pending,
         depth: summary[:depth] || 0,
         parent_id: summary[:parent_id],
         worktree: summary[:worktree],
         retries: summary[:retries] || 0,
         agent_module: summary[:agent_module],
         model_id: summary[:model_id],
         objective: summary[:objective] || "",
         context_path: summary[:context_path],
         current_commit: summary[:current_commit],
         base_commit: summary[:base_commit],
         children: [],
         has_children: false,
         pending_sub_agents: [],
         sub_agent_results: %{},
         task_ref: nil,
         result_sent: false,
         history: [],
         usage: normalize_registered_usage(summary[:usage]),
         total_tokens: total_tokens,
         compression_count: compression_count,
         compression_threshold: compression_threshold,
         compression_pct: compression_pct,
         # History-gate input: number of messages in the agent's context. NOT
         # recorded into the gate here — the history is empty until first fetch,
         # and recording a count would wrongly suppress the fetch on selection.
         message_count: summary[:message_count]
       }}
    else
      :error
    end
  end

  # Normalizes the usage value from a registered-event summary into a struct
  # so the rendering code (which reads usage.input_tokens etc.) works
  # uniformly. A native %EvoGit.Agent.Usage{} passes through; nil or any
  # other shape falls back to zero.
  defp normalize_registered_usage(%EvoGit.Agent.Usage{} = usage), do: usage
  defp normalize_registered_usage(_), do: EvoGit.Agent.Usage.zero()

  defp maybe_update_parent_children(agents, nil), do: agents

  defp maybe_update_parent_children(agents, parent_id) do
    update_agent_in_list(agents, parent_id, fn parent ->
      children = LoadData.find_children_from_agents(parent.id, agents)
      %{parent | children: children, has_children: length(children) > 0}
    end)
  end

  defp build_repo_trees(agents) do
    agents
    |> Enum.group_by(&grouping_key/1)
    |> Enum.map(fn {key, repo_agents} ->
      display_name = repo_display_name(key)
      tree = build_path_tree(repo_agents)
      # Rename the "." root node to the repo display name so each repo has a distinct root
      tree = rename_root(tree, display_name)
      {display_name, tree}
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  defp grouping_key(agent) do
    agent.repo_root || agent.repo_id
  end

  defp rename_root(nodes, new_name) do
    Enum.map(nodes, fn
      %{name: "."} = node -> %{node | name: new_name}
      node -> node
    end)
  end

  defp repo_display_name("primary"), do: gettext("Primary Repo")
  defp repo_display_name(:primary), do: gettext("Primary Repo")
  defp repo_display_name(nil), do: gettext("Primary Repo")

  # An absolute path on any platform (Unix /foo or Windows C:\foo) — use the basename.
  defp repo_display_name(key) when is_binary(key) do
    if Platform.absolute_path?(key) do
      Path.basename(key)
    else
      gettext("Repo: %{repo_id}", repo_id: key)
    end
  end

  defp repo_display_name(_), do: gettext("Unknown Repo")

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

  defp build_path_tree(agents) do
    tree =
      Enum.reduce(agents, %{}, fn agent, acc ->
        path = agent.context_path || "./"
        path = if path == "/", do: "./", else: path

        segments =
          path
          |> Path.split()
          |> case do
            ["." | rest] -> ["." | rest]
            other -> ["." | other]
          end

        insert_into_tree(acc, segments, [], agent)
      end)

    sort_tree(tree)
  end

  defp insert_into_tree(tree, [], _acc_segments, _agent), do: tree

  defp insert_into_tree(tree, [segment | rest], acc_segments, agent) do
    current_segments = acc_segments ++ [segment]
    current_path = Path.join(current_segments)

    node = Map.get(tree, segment, %{name: segment, path: current_path, agents: [], children: %{}})

    if rest == [] do
      node = %{node | agents: [agent | node.agents]}
      Map.put(tree, segment, node)
    else
      node = %{node | children: insert_into_tree(node.children, rest, current_segments, agent)}
      Map.put(tree, segment, node)
    end
  end

  defp sort_tree(tree) do
    tree
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn node ->
      %{node | children: sort_tree(node.children), agents: Enum.sort_by(node.agents, & &1.id)}
    end)
  end

  # Reads the compression threshold for the currently viewed node from the
  # threshold cache. The cache is filled ONLY by the async load/refresh tasks
  # (see ThresholdCache) — this never RPCs from the LiveView process. On a
  # cache miss the LOCAL node resolves its config directly (cheap, local); a
  # remote miss falls back to the default until the next async refresh fills
  # the cache.
  defp safe_compression_threshold(socket) do
    node = socket.assigns.current_node

    case ThresholdCache.read(
           socket.assigns.threshold_cache,
           node,
           System.monotonic_time(:millisecond)
         ) do
      {:ok, threshold} ->
        threshold

      :miss ->
        if node == node() do
          EvoGit.Config.resolve([:llm, :compression_threshold_tokens]) ||
            ThresholdCache.default_threshold()
        else
          ThresholdCache.default_threshold()
        end
    end
  end

  # Converts native %ReqLLM.Message{} structs into the %{turn, type, data}
  # entry format the template consumes. The only legitimate conversion here is
  # extracting display text from the ContentPart list → a single string; all
  # other fields are passed through as native terms.
  defp messages_to_history_entries(messages) when is_list(messages) do
    Enum.map(messages, &message_to_history_entry/1)
  end

  defp message_to_history_entry(%ReqLLM.Message{} = msg) do
    %{
      turn: Map.get(msg.metadata, :turn) || 0,
      # Wall-clock timestamp stamped by the :evo_git runtime at the source
      # (Unix-seconds integer or DateTime; absent on historical messages).
      timestamp: Map.get(msg.metadata, :timestamp),
      type: Atom.to_string(msg.role),
      data: %{
        content:
          msg.content
          |> Enum.map(fn part ->
            case content_part_label(part) do
              nil -> Map.get(part, :text)
              label -> label
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join(),
        tool_calls: msg.tool_calls,
        reasoning_details: msg.reasoning_details,
        tool_name: Map.get(msg.metadata, :tool_name) || msg.name,
        metadata: msg.metadata
      }
    }
  end

  # Renders a short metadata label for image/audio content parts so multimodal
  # history isn't blank, e.g. "[image: foo.png]" / "[audio: track.mp3]". Every
  # other part type (text/image_url/video_url/thinking/unknown) returns nil —
  # those contribute nothing beyond what the text extraction already yields.
  # Handles %ReqLLM.Message.ContentPart{} structs and atom/string-keyed maps.
  # TOTAL: never raises, never touches the part's `data` binary.
  defp content_part_label(part) when is_map(part) do
    type = pget(part, :type)

    cond do
      type in [:image, "image"] -> "[image#{part_name_suffix(part)}]"
      audio_part?(part, type) -> "[audio#{part_name_suffix(part)}]"
      true -> nil
    end
  end

  defp content_part_label(_part), do: nil

  # Audio rides as type :audio or as type :file with an audio/* media_type
  # (is_binary guard keeps it total on non-string media_type values).
  defp audio_part?(_part, type) when type in [:audio, "audio"], do: true

  defp audio_part?(part, type) when type in [:file, "file"] do
    case pget(part, :media_type) do
      mt when is_binary(mt) -> String.starts_with?(mt, "audio/")
      _ -> false
    end
  end

  defp audio_part?(_part, _type), do: false

  # ": <filename>" when a filename is available, else "" — never a bare
  # binary; prefers the real schema `filename` field, falls back to a `name`
  # key (string or atom) for defensive map shapes.
  defp part_name_suffix(part) do
    case pget(part, :filename) || pget(part, :name) do
      name when is_binary(name) and name != "" -> ": " <> name
      _ -> ""
    end
  end

  # Atom-or-string-key tolerant getter (total on any map shape).
  defp pget(part, key), do: Map.get(part, key) || Map.get(part, to_string(key))

  # Merges an agent's real history with its pending optimistic user messages
  # (see OptimisticMessages). Optimistic entries are appended AFTER the real
  # history (never interleaved), so indices into the base history are unchanged
  # — callers that look up history entries by index can keep using them.
  defp merged_history(agent, optimistic_messages) do
    OptimisticMessages.merge(agent.history || [], Map.get(optimistic_messages || %{}, agent.id))
  end

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
