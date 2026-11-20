defmodule EvoDashWeb.AgentsLive.AgentMerge do
  @moduledoc """
  In-memory application of the core's incremental agent broadcasts for the
  Agents page.
  The burst contract: every buffered event is only APPENDED to the coalescing
  buffer (see `EvoDashWeb.AgentsLive.PendingEvents`), and ONE trailing-edge
  flush applies the whole burst through `flush/1`, so a burst yields exactly
  one merged agent list and one render.
  The flush contract: `flush/1` drains the buffer in ARRIVAL order, merges the
  events, and answers `{socket, after_flush}` where `after_flush` is `:refresh`
  (one fallback refresh is needed), `:refetch` (the selected agent's history
  needs ONE refetch) or `:none` — the LiveView performs that single action,
  because this module never spawns tasks and never touches the commit graph.
  The index contract: a flush builds ONE `%{id => agent}` row index and ONE
  `%{id => position}` index from the socket's agent list and threads them
  through the whole burst, so an `:agent_updated` merge is a map lookup plus a
  map put instead of an `Enum.find_index/2` scan and a `List.replace_at/2` copy.
  The one-pass contract: accumulated merges are applied to the agent list in
  ONE final `Enum.map` pass, so a burst of k events over n agents costs O(k + n)
  rather than the O(k·n) list copies of the sequential implementation.
  Arrival-order semantics are unchanged: every merge reads the CURRENT row (the
  one already merged earlier in the same burst) as its base, and a rare
  structural event (`:agent_registered` / `:agent_removed`) first folds the
  pending merges into the list, then mutates it.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias EvoGit.Agent.Usage

  alias EvoDashWeb.AgentsLive.{
    AgentList,
    ContextMeter,
    HistoryGate,
    Inspector,
    LoadData,
    OptimisticMessages,
    PendingEvents,
    StreamWatch,
    ThresholdCache,
    TreeView
  }

  alias EvoDashWeb.ModelLabel

  # THE flush — the page's hot path. A streaming agent emits an update roughly
  # every 75ms, so a burst is k events over n agents, and the sequential
  # implementation paid an `Enum.find_index/2` scan plus a `List.replace_at/2`
  # copy PER EVENT (O(k·n) with k·n list copies). Here the burst instead builds
  # ONE `%{id => agent}` + `%{id => position}` index pair, merges every event
  # into that map (O(1) per event, reading the already-merged row as its base),
  # and folds the result back into the list in ONE `Enum.map` pass at the end —
  # O(k + n). The repo trees are likewise rebuilt at most once per flush, from
  # that final list.
  @doc """
  Flushes the coalesced agent-event buffer and answers the ONE follow-up the
  caller still owes (`:refresh`, `:refetch` or `:none`).
  """
  @spec flush(Phoenix.LiveView.Socket.t()) ::
          {Phoenix.LiveView.Socket.t(), :refresh | :refetch | :none}
  def flush(socket) do
    events = PendingEvents.drain(socket.assigns.pending_agent_events)
    refresh? = socket.assigns.pending_agents_refresh

    socket =
      assign(socket,
        pending_agent_events: PendingEvents.new(),
        agent_flush_scheduled: false,
        pending_agents_refresh: false
      )

    # ONE index pair + ONE final list pass for the whole burst (see the
    # moduledoc): events join the reducer in arrival order and every merge reads
    # the row already merged by an earlier event of the same burst.
    state =
      Enum.reduce(events, new_state(socket, refresh?), fn event, acc ->
        apply_buffered_agent_event(event, acc)
      end)
      |> finalize()

    after_flush =
      cond do
        state.needs_refresh? -> :refresh
        state.refetch? -> :refetch
        true -> :none
      end

    {state.socket, after_flush}
  end

  @doc """
  Node-filters an incremental agent event, buffers it and arms the single
  trailing-edge flush timer (both the four-tuple and the three-tuple shapes).
  """
  @spec buffer_event(Phoenix.LiveView.Socket.t(), tuple()) :: Phoenix.LiveView.Socket.t()
  def buffer_event(socket, {_tag, _id, node} = event) do
    buffer_node_event(socket, node, event)
  end

  def buffer_event(socket, {_tag, _id, _payload, node} = event) do
    buffer_node_event(socket, node, event)
  end

  @doc """
  Buffers the coalesced `{:agents_updated, node}` refresh trigger and arms the
  single trailing-edge flush (the flush then spawns at most ONE refresh).
  """
  @spec buffer_refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def buffer_refresh(socket) do
    socket
    |> assign(:pending_agents_refresh, true)
    |> maybe_schedule_agent_flush()
  end

  @doc """
  Applies a fresh agent list (from the async load or a refresh task): recomputes
  the tracking assigns, carries over still-current histories, records the fresh
  message counts and (re)triggers the selected agent's history fetch.
  The caller owns the commit-graph refresh (`CommitGraphState.maybe_load/2`).
  """
  @spec apply_result(Phoenix.LiveView.Socket.t(), [map()]) :: Phoenix.LiveView.Socket.t()
  def apply_result(socket, agents) do
    agents = Enum.map(agents, &Inspector.preserve_terminal(socket, &1))
    current_ids = MapSet.new(agents, & &1.id)
    current_statuses = Map.new(agents, fn a -> {a.id, a.status} end)

    # In-session retention of ended agents: an id that was previously known (live
    # or already retained) but is ABSENT from the fresh list has ended — keep its
    # last-known row marked `ended: true` so the commit-history view keeps its
    # lane and START/END markers after the core recycles the agent (which deletes
    # the agent's ETS rows AND its branch). A live id always SUPERSEDES its
    # retained copy. The FIRST apply (and the first after a node switch) sees an
    # empty @agents + empty @retained_agents, so nothing is mass-retained on
    # load. The agent tree renders @agents only — retained agents never appear
    # there.
    retained_agents =
      socket.assigns.retained_agents
      |> retain_absent_agents(socket.assigns.agents, current_ids)
      |> Map.drop(MapSet.to_list(current_ids))

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
    # (fetched) history is carried over while an old row exists — this keeps the
    # already-rendered entries MOUNTED while the refresh-induced refetch is in
    # flight. Blanking it on a moved message count would swap the whole list for
    # the "Loading history…" spinner and re-animate every entry once the
    # refetch landed. Carry-over is scoped to SAME-NODE agents via
    # HistoryGate.known?/2: the gate is reset on a node switch while @agents is
    # kept mounted, and agent ids are per-node, so without this check a same-id
    # row from the PREVIOUS node could leak its history into the new node's
    # list. A brand-new agent has no gate entry either — but it has history: []
    # anyway, so skipping the carry-over is a no-op for it. The gate is
    # recorded ONLY when the count is unchanged (its last-seen entry), so a
    # moved count still reports "needs fetch" and the refetch is triggered — no
    # redundant re-transfers.
    #
    # ONE index of the previous list replaces the per-agent `Enum.find/2` scan,
    # so a full apply over n agents is a single pass of map lookups.
    old_by_id = AgentList.by_id(socket.assigns.agents)

    {agents, history_gate} =
      Enum.reduce(agents, {[], socket.assigns.history_gate}, fn agent, {acc, gate} ->
        old_agent = Map.get(old_by_id, agent.id)

        keep_history =
          old_agent != nil and old_agent.history != [] and HistoryGate.known?(gate, agent.id)

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
      repo_trees: TreeView.build_repo_trees(agents),
      previous_agent_ids: current_ids,
      previous_statuses: current_statuses,
      new_agent_ids: new_agent_ids,
      changed_status_ids: changed_status_ids,
      agents_initialized: true,
      history_gate: history_gate,
      retained_agents: retained_agents
    )
    |> Inspector.detach_absent()
    |> Inspector.maybe_fetch_selected_history()
  end

  # ---------------------------------------------------------------------------
  # Burst state — ONE row index + ONE position index for the whole flush
  # ---------------------------------------------------------------------------

  # `:base` is the agent LIST the burst started from (its order is the rendered
  # order), `:rows` holds the CURRENT merged row per id, and `:positions` is the
  # id → list-position index the update path uses to tell "in the tree" from
  # "not yet known". Merges only ever replace a row in place, so the base order
  # is stable until a structural event rebuilds both indexes.
  defp new_state(socket, refresh?) do
    agents = socket.assigns.agents

    %{
      socket: socket,
      base: agents,
      rows: AgentList.by_id(agents),
      positions: AgentList.positions(agents),
      repo_dirty?: false,
      needs_refresh?: refresh?,
      refetch?: false
    }
  end

  # Applies the merges accumulated so far to the list in ONE pass, so a
  # structural event observes them before it mutates the list.
  defp materialize(state) do
    agents = merged_list(state)
    %{state | base: agents, socket: assign(state.socket, :agents, agents)}
  end

  # Re-indexes after a structural event replaced the list wholesale. The
  # structural path already rebuilt the repo trees from the new list.
  defp reindex(state, socket) do
    agents = socket.assigns.agents

    %{
      state
      | socket: socket,
        base: agents,
        rows: AgentList.by_id(agents),
        positions: AgentList.positions(agents),
        repo_dirty?: false
    }
  end

  # THE one pass of the flush: every base row is replaced by its merged copy
  # (map lookup per row), preserving the list order exactly.
  defp merged_list(%{base: base, rows: rows}) do
    Enum.map(base, fn row ->
      case Map.fetch(rows, row.id) do
        {:ok, merged} -> merged
        :error -> row
      end
    end)
  end

  defp finalize(state) do
    agents = merged_list(state)
    socket = assign(state.socket, :agents, agents)

    # ONE repo-tree rebuild per flush. An update burst that touched
    # `context_node`/`repo_root` only rebuilds from the FINAL merged list
    # instead of once per event (the tree assembly is a pure function of the
    # list, so the result is identical); structural events rebuild on their own
    # and clear the flag.
    socket =
      if state.repo_dirty? do
        assign(socket, :repo_trees, TreeView.build_repo_trees(agents))
      else
        socket
      end

    %{state | socket: socket}
  end

  # ---------------------------------------------------------------------------
  # Buffered events
  # ---------------------------------------------------------------------------

  defp apply_buffered_agent_event({:agent_registered, agent_id, summary, _node}, state) do
    apply_agent_registered(state, agent_id, summary)
  end

  defp apply_buffered_agent_event({:agent_updated, agent_id, changed_fields, _node}, state) do
    # The refetch is gate-checked by Inspector.refetch_selected_history/1 at the
    # end; here we only remember whether the selected agent's context moved.
    moved? =
      agent_id == state.socket.assigns.selected_agent_id and
        Keyword.has_key?(changed_fields, :message_count)

    state = %{state | refetch?: state.refetch? or moved?}

    apply_agent_updated(state, agent_id, changed_fields)
  end

  defp apply_buffered_agent_event({:agent_removed, agent_id, _node}, state) do
    apply_agent_removed(state, agent_id)
  end

  # Structural event (rare): fold the pending merges into the list, run the
  # list-based merge, then rebuild both indexes for the rest of the burst.
  defp apply_agent_registered(state, agent_id, summary) do
    state = materialize(state)

    case apply_agent_registered_list(state.socket, agent_id, summary) do
      {:ok, socket} -> reindex(state, socket)
      :fallback -> reindex(%{state | needs_refresh?: true}, state.socket)
    end
  end

  # Applies ONE buffered {:agent_registered, id, summary, node} event: a
  # duplicate id (a race with the agents_updated fallback) is a no-op; the
  # event's summary is otherwise merged in-memory for BOTH local and remote
  # events through ONE shared path. Returns {:ok, socket}, or :fallback when
  # the summary lacks fields the tree needs (the caller coalesces one async
  # full refresh instead of merging a broken row).
  defp apply_agent_registered_list(socket, agent_id, summary) do
    already_exists = Enum.any?(socket.assigns.agents, fn a -> a.id == agent_id end)

    retained_terminal? =
      StreamWatch.terminal?(socket, agent_id) and
        Map.has_key?(socket.assigns.retained_agents, agent_id)

    if already_exists or retained_terminal? do
      {:ok, socket}
    else
      merge_registered_agent(socket, agent_id, summary)
    end
  end

  # Applies ONE buffered {:agent_updated, id, changed_fields, node} event to the
  # burst's row index (the body of the former handle_info clause). Returns the
  # updated burst state. The selected-agent history refetch is NOT performed
  # here: the flush tracks it across the whole burst and calls
  # Inspector.refetch_selected_history/1 at most once at the end.
  defp apply_agent_updated(state, agent_id, changed_fields) do
    if Map.get(state.positions, agent_id) == nil do
      settle_retained_agent(state, agent_id, changed_fields)
    else
      merge_live_agent(state, agent_id, changed_fields)
    end
  end

  # The row still has to be settled in the retained (ended) set: a live row never
  # resurrects from it, and an unknown id falls back to the async refresh.
  defp settle_retained_agent(state, agent_id, changed_fields) do
    case Map.get(state.socket.assigns.retained_agents, agent_id) do
      nil ->
        # Race — agent not yet in our list, fall back to an async full refresh
        %{state | needs_refresh?: true}

      retained ->
        if StreamWatch.terminal?(state.socket, agent_id) do
          # Removal can precede the terminal summary. Settle the retained
          # detail without resurrecting a live tree row or its old history.
          agent =
            retained
            |> Map.merge(handle_special_fields(Map.new(changed_fields)))
            |> then(&Inspector.preserve_terminal(state.socket, &1))

          socket =
            assign(
              state.socket,
              :retained_agents,
              Map.put(state.socket.assigns.retained_agents, agent_id, agent)
            )

          %{state | socket: socket}
        else
          %{state | needs_refresh?: true}
        end
    end
  end

  # Merges ONE delta into the CURRENT row (`:positions` and `:rows` are built
  # from the same list, so a present position guarantees a row). Every
  # field-level rule of the sequential implementation is preserved; only the
  # list copy per event is gone.
  defp merge_live_agent(state, agent_id, changed_fields) do
    agent = Map.get(state.rows, agent_id)

    # Track old parent_id for children recalculation
    old_parent_id = agent.parent_id
    previous_threshold = agent.compression_threshold
    previous_context_window = ContextMeter.context_window_from(agent)

    # Convert changed_fields keyword list to a map for merging
    changed_map =
      changed_fields
      |> Enum.into(%{})
      |> handle_special_fields()

    # Merge changed fields into agent
    agent =
      agent |> Map.merge(changed_map) |> then(&Inspector.preserve_terminal(state.socket, &1))

    # A nil/non-positive threshold delta means "unknown" — keep the row's
    # previous (usable) denominator so a bar can never divide by nil.
    agent =
      case agent.compression_threshold do
        threshold when is_integer(threshold) and threshold > 0 ->
          agent

        _ ->
          %{agent | compression_threshold: restore_threshold(previous_threshold, state.socket)}
      end

    # The optional :context_window is NOT part of the delta contract — the
    # merge above therefore keeps the row's value when the delta omits it.
    # A delta carrying an unusable value (nil/non-positive/non-integer) must
    # never reset a known window back to the 200_000 default.
    agent =
      case Map.get(changed_map, :context_window) do
        window when is_integer(window) and window > 0 ->
          %{agent | context_window: window}

        _ ->
          %{agent | context_window: previous_context_window}
      end

    # Recalculate compression_pct when total_tokens OR the threshold changed.
    agent =
      if Keyword.has_key?(changed_fields, :total_tokens) or
           Keyword.has_key?(changed_fields, :compression_threshold) do
        threshold = agent.compression_threshold
        pct = trunc(min(agent.total_tokens / max(threshold, 1) * 100, 100))
        %{agent | compression_pct: pct}
      else
        agent
      end

    state = %{state | rows: Map.put(state.rows, agent_id, agent)}

    # Recalculate children if parent_id changed
    state =
      if Keyword.has_key?(changed_fields, :parent_id) do
        state
        |> refresh_parent_children(old_parent_id)
        |> refresh_parent_children(agent.parent_id)
      else
        state
      end

    # Queue anchoring: the core broadcasts the agent's pending_user_messages
    # queue on every append AND on drain (reset to []). Whenever the delta
    # carries it, snapshot the queue and TERMINALLY prune the optimistic
    # assign — an entry that is no longer queued (and not reflected by the
    # fetched history) has been drained for good, so a later context
    # compression can never resurrect it. A delta WITHOUT
    # :pending_user_messages leaves the snapshot untouched (absent key = queue
    # unknown -> still-pending entries are kept).
    {pending_user_messages, optimistic_messages} =
      if Keyword.has_key?(changed_fields, :pending_user_messages) do
        queue = Keyword.get(changed_fields, :pending_user_messages)

        optimistic_messages =
          OptimisticMessages.prune(
            state.socket.assigns.optimistic_messages,
            agent_id,
            agent.history || [],
            queue
          )

        {(state.socket.assigns.pending_user_messages || %{}) |> Map.put(agent_id, queue),
         optimistic_messages}
      else
        {state.socket.assigns.pending_user_messages, state.socket.assigns.optimistic_messages}
      end

    # Detect status change
    old_status = state.socket.assigns.previous_statuses[agent_id]
    new_status = agent.status

    previous_statuses = state.socket.assigns.previous_statuses
    changed_status_ids = state.socket.assigns.changed_status_ids

    {previous_statuses, changed_status_ids} =
      if old_status != new_status do
        {Map.put(previous_statuses, agent_id, new_status),
         MapSet.put(changed_status_ids, agent_id)}
      else
        {previous_statuses, changed_status_ids}
      end

    # Update id_to_display if task_local_id changed
    id_to_display = state.socket.assigns.id_to_display

    id_to_display =
      if Keyword.has_key?(changed_fields, :task_local_id) do
        Map.put(id_to_display, agent_id, agent.task_local_id || agent_id)
      else
        id_to_display
      end

    socket =
      assign(state.socket,
        id_to_display: id_to_display,
        previous_statuses: previous_statuses,
        changed_status_ids: changed_status_ids,
        pending_user_messages: pending_user_messages,
        optimistic_messages: optimistic_messages
      )

    # A `context_node`/`repo_root` delta invalidates the tree's repository
    # grouping; it is rebuilt ONCE at the end of the flush from the final merged
    # list instead of once per event.
    repo_dirty? =
      state.repo_dirty? or Keyword.has_key?(changed_fields, :context_node) or
        Keyword.has_key?(changed_fields, :repo_root)

    %{state | socket: socket, repo_dirty?: repo_dirty?}
  end

  # The index-based twin of maybe_update_parent_children/2: recomputes ONE
  # parent's children summary from the merged rows without copying the list.
  defp refresh_parent_children(state, nil), do: state

  defp refresh_parent_children(state, parent_id) do
    case Map.fetch(state.rows, parent_id) do
      :error ->
        state

      {:ok, parent} ->
        children = LoadData.find_children_from_agents(parent.id, merged_list(state))

        parent = %{parent | children: children, has_children: length(children) > 0}

        %{state | rows: Map.put(state.rows, parent_id, parent)}
    end
  end

  # Structural event (rare): fold the pending merges into the list, run the
  # list-based removal, then rebuild both indexes for the rest of the burst.
  defp apply_agent_removed(state, agent_id) do
    state = materialize(state)
    reindex(state, remove_live_agent(state.socket, agent_id))
  end

  # Applies ONE buffered {:agent_removed, id, node} event to the socket's
  # in-memory agent tree (the body of the former handle_info clause): drops the
  # row from @agents (the TREE view — an ended agent must not linger there),
  # orphans its children to parent_id: nil, refreshes the parent's children list,
  # cleans the tracking sets/repo_trees, and RETAINS the removed row in
  # @retained_agents (marked `ended: true`) so the commit-history view keeps its
  # lane and START/END markers — the core deletes the agent's ETS rows and
  # branch when it recycles, so nothing else remembers it. Returns the socket.
  defp remove_live_agent(socket, agent_id) do
    socket =
      if socket.assigns.selected_agent_id == agent_id and not StreamWatch.owns?(socket, agent_id) do
        socket
        |> StreamWatch.detach()
        |> Inspector.clear_history_loading_flags(agent_id)
      else
        socket
      end

    agents = socket.assigns.agents
    removed_agent = AgentList.find(agents, agent_id)

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

      repo_trees = TreeView.build_repo_trees(agents)

      # Keep the selected owned watch's ended detail independently of the live
      # tree; retention also preserves the commit graph's lane and markers.
      retained_agents =
        Map.put(socket.assigns.retained_agents, agent_id, Map.put(removed_agent, :ended, true))

      assign(socket,
        agents: agents,
        id_to_display: id_to_display,
        repo_trees: repo_trees,
        previous_agent_ids: previous_agent_ids,
        new_agent_ids: new_agent_ids,
        previous_statuses: previous_statuses,
        retained_agents: retained_agents
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

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
      Map.put(changed_map, :usage, Usage.zero())
    else
      changed_map
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
            AgentList.update(agents, new_agent.parent_id, fn parent ->
              children = LoadData.find_children_from_agents(parent.id, agents)
              %{parent | children: children, has_children: length(children) > 0}
            end)
          else
            agents
          end

        id_to_display =
          Map.put(socket.assigns.id_to_display, agent_id, new_agent.task_local_id || agent_id)

        # A (re-)registered agent is LIVE again — it supersedes any retained
        # (ended) copy of the same id in the commit-history view.
        retained_agents = Map.delete(socket.assigns.retained_agents, agent_id)

        {:ok,
         assign(socket,
           agents: agents,
           id_to_display: id_to_display,
           previous_agent_ids: MapSet.put(socket.assigns.previous_agent_ids, agent_id),
           new_agent_ids: MapSet.put(socket.assigns.new_agent_ids, agent_id),
           repo_trees: TreeView.build_repo_trees(agents),
           retained_agents: retained_agents
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

      # Prefer the summary's OWN pre-computed threshold (per model context
      # window); the node-level value is only the fallback.
      compression_threshold =
        ThresholdCache.threshold_for_agent(summary, safe_compression_threshold(socket))

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
         # Display-only label (same derivation as LoadData.build_agents) so a
         # live-registered agent never renders "N/A" while the full refresh
         # would show a model.
         model_label: ModelLabel.label(summary),
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
         # The model's context window (the Context meter's full-bar width).
         # OPTIONAL in the summary — absent on remote/older daemons, in which
         # case the core default (200_000) applies.
         context_window: ContextMeter.context_window_from(summary),
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
  defp normalize_registered_usage(%Usage{} = usage), do: usage
  defp normalize_registered_usage(_), do: Usage.zero()

  # ---------------------------------------------------------------------------
  # List helpers
  # ---------------------------------------------------------------------------

  # Folds the old live agents that are ABSENT from `current_ids` into the
  # retained map (marked `ended: true`), preserving every field the
  # commit-history view reads (id, task_local_id, task_id, repo_id, repo_root,
  # depth, status, base_commit, current_commit, usage, ...).
  defp retain_absent_agents(retained, old_agents, current_ids) do
    Enum.reduce(old_agents, retained, fn agent, acc ->
      if MapSet.member?(current_ids, agent.id) do
        acc
      else
        Map.put(acc, agent.id, Map.put(agent, :ended, true))
      end
    end)
  end

  defp maybe_update_parent_children(agents, nil), do: agents

  defp maybe_update_parent_children(agents, parent_id) do
    AgentList.update(agents, parent_id, fn parent ->
      children = LoadData.find_children_from_agents(parent.id, agents)
      %{parent | children: children, has_children: length(children) > 0}
    end)
  end

  # ---------------------------------------------------------------------------
  # Compression threshold carry-over
  # ---------------------------------------------------------------------------

  # Reads the NODE-LEVEL compression threshold for the currently viewed node
  # from the threshold cache. The cache is filled ONLY by the async load/refresh
  # tasks (see ThresholdCache) — this never RPCs from the LiveView process. On a
  # cache miss the LOCAL node resolves its config directly (cheap, local); a
  # remote miss falls back to the default until the next async refresh fills the
  # cache. A nil/blank config value now means "unknown" (the setting is
  # optional; the core derives the real trigger per model), so 180_000 here is a
  # LAST-RESORT fallback only — each agent's own summary threshold takes
  # precedence wherever one is available.
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

  # Restores the denominator after a threshold delta that is nil/non-positive
  # ("unknown"): keep the row's previous usable value, else fall back to the
  # node-level threshold (which itself normalizes to the 180_000 last resort).
  defp restore_threshold(previous, _socket) when is_integer(previous) and previous > 0,
    do: previous

  defp restore_threshold(_previous, socket), do: safe_compression_threshold(socket)

  # Node-filters an incremental agent event, appends it to the coalescing
  # buffer (newest-first), and arms the single trailing-edge flush timer.
  # Foreign-node events are dropped BEFORE buffering, so they can never
  # schedule a flush or leak into the currently-viewed node's tree.
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
  # appends to the existing buffer. The window is read AT CALL TIME through the
  # :agents_live_flush_ms app-env seam (production default =
  # PendingEvents.flush_ms() = 300ms); the pure PendingEvents module stays
  # constant-only.
  defp maybe_schedule_agent_flush(socket) do
    if PendingEvents.should_schedule?(socket.assigns.agent_flush_scheduled) do
      Process.send_after(
        self(),
        :flush_agent_events,
        Application.get_env(:evo_dash, :agents_live_flush_ms, PendingEvents.flush_ms())
      )

      assign(socket, :agent_flush_scheduled, true)
    else
      socket
    end
  end
end
