defmodule EvoGit.AgentScheduler.Slots do
  @moduledoc """
  LLM and tool slot management for the AgentScheduler.

  Provides pure functions that operate on the scheduler state map
  to manage concurrent LLM call and tool execution slots.

  ## Per-Model LLM Slot Pools

  LLM slots are organized into **per-model pools**. Each model profile gets
  its own concurrency limit, holder set, waiting queue, and backoff timer.
  The agent's `model_id` (read from ETS via `AgentState`) determines which
  pool it belongs to.

  The key benefit: a rate-limit on one provider no longer blocks agents
  using a different model. Backoff is scoped per-model.

  ## Slot Tracking

  Slots are tracked as `MapSet`s of agent IDs (`llm_holders[model_id]` / `tool_holders`).
  Available capacity is derived: `capacity - map_size(holders)`. This makes
  leaks impossible by construction — when an agent dies, it is removed from
  the holder sets in `release_agent_slots/2`, restoring the slot automatically.

  ## Slot Types

  - **LLM slots** — Controls how many agents can make concurrent LLM calls,
    per-model. Includes a per-model backoff mechanism for rate limit errors
    (60-second cooldown).

  - **Tool slots** — Controls how many agents can execute tools concurrently.
    Simple semaphore without backoff (shared across all agents regardless of model).

  Both slot types use blocking calls — agents wait in queues when no slots
  are available and are granted slots via `GenServer.reply/2` when freed.

  ## Return Format

  All handler functions return tuples that include a `status_updates` list
  of `{agent_id, new_status}` pairs. The caller (AgentScheduler) applies
  these updates to the ETS-based `SchedMeta` entries so the dashboard
  can accurately reflect when agents are blocked waiting for slots.
  """

  require Logger

  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store

  @type slot_result ::
          {:reply, :ok, State.t(), [{pos_integer(), atom()}]}
          | {:noreply, State.t(), [{pos_integer(), atom()}]}

  # --- Model ID Resolution ---

  @doc """
  Resolves the model_id for an agent by reading its AgentState from ETS.

  Falls back to the state's default model_id if the agent has no explicit
  model_id or is not found in ETS.
  """
  @spec resolve_model_id(pos_integer(), State.t()) :: String.t()
  def resolve_model_id(agent_id, %State{} = state) do
    case Store.get_model_id(agent_id) do
      nil ->
        State.default_model_id(state)

      "" ->
        State.default_model_id(state)

      model_id ->
        model_id
    end
  end

  # --- LLM Slot Management ---

  @doc """
  Handles an LLM slot request.

  Resolves the agent's model_id from ETS, then checks the per-model pool.
  Returns `{:reply, :ok, state, status_updates}` if a slot is immediately available,
  or `{:noreply, state, status_updates}` if the agent must wait (no slots or in backoff).
  """
  @spec handle_request_llm_slot(pos_integer(), GenServer.from(), State.t()) :: slot_result()
  def handle_request_llm_slot(agent_id, from, %State{} = state) do
    model_id = resolve_model_id(agent_id, state)

    if state.paused do
      waiting = State.waiting_for(state, model_id)
      waiting = :queue.in({agent_id, from, nil}, waiting)
      state = State.update_waiting(state, model_id, waiting)
      {:noreply, state, [{agent_id, :blocked}]}
    else
      do_handle_request_llm_slot(agent_id, from, state, model_id)
    end
  end

  defp do_handle_request_llm_slot(agent_id, from, %State{} = state, model_id) do
    now = System.monotonic_time(:millisecond)
    backoff = State.backoff_for(state, model_id)
    holders = State.holders_for(state, model_id)
    concurrency = State.concurrency_for(state, model_id)

    if backoff && now < backoff do
      waiting = State.waiting_for(state, model_id)
      waiting = :queue.in({agent_id, from, backoff}, waiting)
      state = State.update_waiting(state, model_id, waiting)
      {:noreply, state, [{agent_id, :blocked}]}
    else
      if MapSet.size(holders) < concurrency do
        state =
          state
          |> State.update_holders(model_id, MapSet.put(holders, agent_id))
          |> State.update_last_granted(
            model_id,
            Map.put(State.last_granted_for(state, model_id), agent_id, now)
          )

        {:reply, :ok, state, []}
      else
        waiting = State.waiting_for(state, model_id)
        waiting = :queue.in({agent_id, from, nil}, waiting)
        state = State.update_waiting(state, model_id, waiting)
        {:noreply, state, [{agent_id, :blocked}]}
      end
    end
  end

  @doc """
  Handles an LLM slot release.

  Removes the agent from the per-model holder set and grants pending requests
  for that model. Returns `{:reply, :ok, state, status_updates}`.
  """
  @spec handle_release_llm_slot(pos_integer(), State.t()) ::
          {:reply, :ok, State.t(), [{pos_integer(), atom()}]}
  def handle_release_llm_slot(agent_id, %State{} = state) do
    model_id = resolve_model_id(agent_id, state)
    holders = State.holders_for(state, model_id)
    state = State.update_holders(state, model_id, MapSet.delete(holders, agent_id))
    {state, unblocked} = grant_pending_llm_slots(state)
    {:reply, :ok, state, unblocked}
  end

  @doc """
  Handles an LLM error report.

  Rate-limit errors trigger a **per-model** 60-second backoff, re-queuing all
  waiting agents for that model with the backoff timestamp. Other error types
  are no-ops. Returns `{:reply, :ok, state, status_updates}`.

  This is the key win of per-model pools: a rate-limit on one provider
  no longer blocks agents using a different model.
  """
  @spec handle_report_llm_error(pos_integer(), atom(), State.t()) ::
          {:reply, :ok, State.t(), [{pos_integer(), atom()}]}
  def handle_report_llm_error(agent_id, :rate_limit, %State{} = state) do
    model_id = resolve_model_id(agent_id, state)
    backoff_until = System.monotonic_time(:millisecond) + 60_000

    Logger.warning(
      "AgentScheduler: LLM rate limit detected for model '#{model_id}', " <>
        "per-model backoff until #{backoff_until}"
    )

    waiting = State.waiting_for(state, model_id)
    waiting = update_waiting_with_backoff(waiting, backoff_until)

    state =
      state
      |> State.update_waiting(model_id, waiting)
      |> State.update_backoff(model_id, backoff_until)

    Process.send_after(self(), :retry_llm_waiting, 65_000)

    {:reply, :ok, state, []}
  end

  def handle_report_llm_error(_agent_id, _error_type, %State{} = state) do
    {:reply, :ok, state, []}
  end

  @doc """
  Handles the retry_llm_waiting timer.

  Grants pending LLM slots for all models whose backoff has expired.
  Returns `{:noreply, state, status_updates}`.
  """
  @spec handle_retry_llm_waiting(State.t()) :: {:noreply, State.t(), [{pos_integer(), atom()}]}
  def handle_retry_llm_waiting(%State{} = state) do
    {state, unblocked} = grant_pending_llm_slots(state)
    {:noreply, state, unblocked}
  end

  # --- Tool Slot Management ---

  @doc """
  Handles a tool slot request.

  Returns `{:reply, :ok, state, status_updates}` if a slot is immediately available,
  or `{:noreply, state, status_updates}` if the agent must wait.
  """
  @spec handle_request_tool_slot(pos_integer(), GenServer.from(), State.t()) :: slot_result()
  def handle_request_tool_slot(agent_id, from, %State{} = state) do
    if state.paused do
      tool_waiting = :queue.in({agent_id, from}, state.tool_waiting)
      {:noreply, %State{state | tool_waiting: tool_waiting}, [{agent_id, :blocked}]}
    else
      do_handle_request_tool_slot(agent_id, from, state)
    end
  end

  defp do_handle_request_tool_slot(agent_id, from, %State{} = state) do
    if MapSet.size(state.tool_holders) < state.max_tool_concurrency do
      state = %State{state | tool_holders: MapSet.put(state.tool_holders, agent_id)}
      {:reply, :ok, state, []}
    else
      tool_waiting = :queue.in({agent_id, from}, state.tool_waiting)
      {:noreply, %State{state | tool_waiting: tool_waiting}, [{agent_id, :blocked}]}
    end
  end

  @doc """
  Handles a tool slot release.

  Removes the agent from the holder set and grants pending requests.
  Returns `{:reply, :ok, state, status_updates}`.
  """
  @spec handle_release_tool_slot(pos_integer(), State.t()) ::
          {:reply, :ok, State.t(), [{pos_integer(), atom()}]}
  def handle_release_tool_slot(agent_id, %State{} = state) do
    state = %State{state | tool_holders: MapSet.delete(state.tool_holders, agent_id)}
    {state, unblocked} = grant_pending_tool_slots(state)
    {:reply, :ok, state, unblocked}
  end

  # --- Agent Death Cleanup ---

  @doc """
  Releases all slots held by an agent and purges it from waiting queues.

  Called on agent death (`:DOWN` handler) to prevent slot leaks. Removes
  the agent from both the per-model LLM holder set(s) and the tool holder
  set, then grants any newly-available slots to pending waiters. Also
  purges the agent from all waiting queues (LLM per-model + tool).

  Returns `{state, status_updates}`.
  """
  @spec release_agent_slots(State.t(), pos_integer()) :: {State.t(), [{pos_integer(), atom()}]}
  def release_agent_slots(%State{} = state, agent_id) do
    # Remove from tool holders
    state = %State{
      state
      | tool_holders: MapSet.delete(state.tool_holders, agent_id)
    }

    # Remove from LLM holders across ALL model pools (an agent may have been
    # registered with any model; we don't know which pool without ETS, but
    # the agent is dead so ETS may be gone — scan all pools).
    state =
      Enum.reduce(State.all_model_ids(state), state, fn model_id, acc_state ->
        holders = State.holders_for(acc_state, model_id)

        if MapSet.member?(holders, agent_id) do
          acc_state = State.update_holders(acc_state, model_id, MapSet.delete(holders, agent_id))

          last_granted = State.last_granted_for(acc_state, model_id)
          State.update_last_granted(acc_state, model_id, Map.delete(last_granted, agent_id))
        else
          acc_state
        end
      end)

    # Purge from waiting queues (in case the agent was blocked, not holding)
    {state, _} = purge_agents_from_queues(state, MapSet.new([agent_id]))

    # Grant any newly-available slots to pending waiters
    {state, llm_unblocked} = grant_pending_llm_slots(state)
    {state, tool_unblocked} = grant_pending_tool_slots(state)

    {state, llm_unblocked ++ tool_unblocked}
  end

  @doc """
  Grants all pending LLM and tool slots that are available.
  Used when resuming from a paused state.

  Returns `{state, status_updates}` where status_updates is a list of
  `{agent_id, :running}` pairs for each agent that was unblocked.
  """
  @spec grant_pending_on_resume(State.t()) :: {State.t(), [{pos_integer(), atom()}]}
  def grant_pending_on_resume(%State{} = state) do
    {state, llm_unblocked} = grant_pending_llm_slots(state)
    {state, tool_unblocked} = grant_pending_tool_slots(state)
    {state, llm_unblocked ++ tool_unblocked}
  end

  @doc """
  Purges agents from both LLM (per-model) and tool waiting queues.

  Replies `{:error, :cancelled}` to each purged agent's blocked GenServer.from
  so their waiting calls unblock cleanly. Returns the updated state with
  rebuilt queues excluding the purged agent IDs.

  Returns `{state, status_updates}`.
  """
  @spec purge_agents_from_queues(State.t(), MapSet.t(pos_integer())) ::
          {State.t(), [{pos_integer(), atom()}]}
  def purge_agents_from_queues(%State{} = state, agent_ids) do
    # Purge from all LLM model pools
    %State{} = state = purge_llm_waiting_queues(state, agent_ids)

    # Purge from tool waiting queue
    {tool_kept, tool_removed} =
      partition_waiting(state.tool_waiting, agent_ids, fn
        {agent_id, _from}, agent_ids -> not MapSet.member?(agent_ids, agent_id)
      end)

    Enum.each(tool_removed, fn {_agent_id, from} ->
      GenServer.reply(from, {:error, :cancelled})
    end)

    state = %State{state | tool_waiting: tool_kept}
    {state, []}
  end

  defp purge_llm_waiting_queues(%State{} = state, agent_ids) do
    Enum.reduce(State.all_model_ids(state), state, fn model_id, %State{} = acc_state ->
      waiting = State.waiting_for(acc_state, model_id)

      {kept, removed} =
        partition_waiting(waiting, agent_ids, fn
          {agent_id, _from}, agent_ids -> not MapSet.member?(agent_ids, agent_id)
          {agent_id, _from, _backoff}, agent_ids -> not MapSet.member?(agent_ids, agent_id)
        end)

      Enum.each(removed, fn
        {_agent_id, from} -> GenServer.reply(from, {:error, :cancelled})
        {_agent_id, from, _backoff} -> GenServer.reply(from, {:error, :cancelled})
      end)

      State.update_waiting(acc_state, model_id, kept)
    end)
  end

  # Partitions a waiting queue into kept and removed entries in a single pass.
  # The predicate receives (entry, agent_ids) and must return true for entries to keep.
  defp partition_waiting(waiting, agent_ids, pred_fun) do
    {kept_rev, removed_rev} =
      waiting
      |> :queue.to_list()
      |> Enum.reduce({[], []}, fn entry, {kept_acc, removed_acc} ->
        if pred_fun.(entry, agent_ids) do
          {[entry | kept_acc], removed_acc}
        else
          {kept_acc, [entry | removed_acc]}
        end
      end)

    {:queue.from_list(:lists.reverse(kept_rev)), :lists.reverse(removed_rev)}
  end

  # --- Private Helpers: LLM Slots ---

  # Grants pending LLM slots across all model pools, clearing expired backoffs.
  # Returns {state, unblocked} where unblocked is a list of {agent_id, :running}.
  defp grant_pending_llm_slots(%State{} = state) do
    now = System.monotonic_time(:millisecond)

    # First, clear expired backoffs for all models
    state =
      Enum.reduce(State.all_model_ids(state), state, fn model_id, acc_state ->
        maybe_clear_model_backoff(acc_state, model_id, now)
      end)

    # Then grant from each model pool
    Enum.reduce(State.all_model_ids(state), {state, []}, fn model_id, {acc_state, acc_updates} ->
      {new_state, updates} = grant_llm_from_queue(acc_state, model_id)
      {new_state, acc_updates ++ updates}
    end)
  end

  # Grants pending LLM slots for a single model pool.
  # Uses holder sets: grants while map_size(holders) < capacity.
  # The recency/depth prioritization stays the same, just scoped to this model's queue.
  # Returns {state, unblocked} where unblocked is a list of {agent_id, :running}.
  defp grant_llm_from_queue(%State{} = state, model_id) do
    now = System.monotonic_time(:millisecond)
    holders = State.holders_for(state, model_id)
    concurrency = State.concurrency_for(state, model_id)
    waiting = State.waiting_for(state, model_id)

    if MapSet.size(holders) >= concurrency or :queue.is_empty(waiting) do
      {state, []}
    else
      entries = :queue.to_list(waiting)

      # Single reduce: partition into in_backoff / eligible and track best candidate
      {in_backoff_rev, eligible_rev, best} =
        Enum.reduce(entries, {[], [], nil}, fn entry, {in_bo_rev, elig_rev, best_so_far} ->
          agent_id = entry_agent_id(entry)

          case entry do
            {_aid, _from, backoff_until} when backoff_until != nil and now < backoff_until ->
              {[entry | in_bo_rev], elig_rev, best_so_far}

            _ ->
              new_best = better_entry(best_so_far, entry, agent_id, state, model_id)
              {in_bo_rev, [entry | elig_rev], new_best}
          end
        end)

      if best == nil do
        # All entries in backoff — preserve order and stop
        {%State{
           state
           | llm_waiting:
               Map.put(
                 state.llm_waiting,
                 model_id,
                 :queue.from_list(:lists.reverse(in_backoff_rev))
               )
         }, []}
      else
        {agent_id, from, _backoff} = best

        GenServer.reply(from, :ok)

        # Rebuild queue: reverse eligible to forward order, prepend (skipping best) to in_backoff_rev, reverse once
        queue_rev =
          eligible_rev
          |> :lists.reverse()
          |> Enum.reduce(in_backoff_rev, fn
            ^best, acc -> acc
            item, acc -> [item | acc]
          end)

        queue_list = :lists.reverse(queue_rev)

        state =
          state
          |> State.update_waiting(model_id, :queue.from_list(queue_list))
          |> State.update_holders(model_id, MapSet.put(holders, agent_id))
          |> State.update_last_granted(
            model_id,
            Map.put(State.last_granted_for(state, model_id), agent_id, now)
          )

        {state, more} = grant_llm_from_queue(state, model_id)
        {state, [{agent_id, :running} | more]}
      end
    end
  end

  # Extracts agent_id from a waiting queue entry (2-tuple or 3-tuple).
  defp entry_agent_id({agent_id, _from}), do: agent_id
  defp entry_agent_id({agent_id, _from, _backoff}), do: agent_id
  defp entry_agent_id(_), do: nil

  # Compares two eligible entries and returns the better one.
  # Prefers most-recently-granted first, then lowest depth.
  defp better_entry(nil, entry, _agent_id, _state, _model_id), do: entry

  defp better_entry(best, entry, agent_id, state, model_id) do
    best_agent_id = entry_agent_id(best)
    last_granted = State.last_granted_for(state, model_id)

    best_score = {-Map.get(last_granted, best_agent_id, 0), depth_of(best_agent_id)}
    this_score = {-Map.get(last_granted, agent_id, 0), depth_of(agent_id)}

    if this_score < best_score, do: entry, else: best
  end

  # Looks up an agent's recursion depth from the scheduler ETS table via Store.
  # Returns a large default if not found so unknown agents sort last.
  defp depth_of(agent_id) do
    case Store.depth_of(agent_id) do
      nil -> 999
      depth -> depth
    end
  end

  # Clears a per-model backoff if it has expired.
  defp maybe_clear_model_backoff(%State{} = state, model_id, now) do
    case State.backoff_for(state, model_id) do
      nil ->
        state

      backoff when now >= backoff ->
        Logger.info(
          "AgentScheduler: LLM backoff expired for model '#{model_id}', resuming normal operations"
        )

        State.update_backoff(state, model_id, nil)

      _backoff ->
        state
    end
  end

  # --- Private Helpers: Tool Slots ---

  # Grants pending tool slots using holder sets.
  # Returns {state, unblocked} where unblocked is a list of {agent_id, :running}.
  defp grant_pending_tool_slots(%State{} = state) do
    grant_tool_from_queue(state)
  end

  defp grant_tool_from_queue(%State{} = state) do
    if MapSet.size(state.tool_holders) >= state.max_tool_concurrency do
      {state, []}
    else
      case :queue.out(state.tool_waiting) do
        {{:value, {agent_id, from}}, rest_waiting} ->
          GenServer.reply(from, :ok)

          state = %State{
            state
            | tool_waiting: rest_waiting,
              tool_holders: MapSet.put(state.tool_holders, agent_id)
          }

          {state, more} = grant_tool_from_queue(state)
          {state, [{agent_id, :running} | more]}

        {:empty, _} ->
          {state, []}
      end
    end
  end

  # Updates all waiting LLM entries with a new backoff timestamp
  defp update_waiting_with_backoff(waiting, backoff_until) do
    entries = :queue.to_list(waiting)

    updated =
      Enum.map(entries, fn
        {agent_id, from, _old_backoff} -> {agent_id, from, backoff_until}
        {agent_id, from} -> {agent_id, from, backoff_until}
      end)

    :queue.from_list(updated)
  end
end
