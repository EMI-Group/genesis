defmodule EvoGit.AgentScheduler.Slots do
  @moduledoc """
  LLM and tool slot management for the AgentScheduler.

  Provides pure functions that operate on the scheduler state map
  to manage concurrent LLM call and tool execution slots.

  ## Slot Tracking

  Slots are tracked as `MapSet`s of agent IDs (`llm_holders` / `tool_holders`).
  Available capacity is derived: `capacity - map_size(holders)`. This makes
  leaks impossible by construction — when an agent dies, it is removed from
  the holder sets in `release_agent_slots/2`, restoring the slot automatically.

  ## Slot Types

  - **LLM slots** — Controls how many agents can make concurrent LLM calls.
    Includes a global backoff mechanism for rate limit errors (60-second cooldown).

  - **Tool slots** — Controls how many agents can execute tools concurrently.
    Simple semaphore without backoff.

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

  @type slot_result :: {:reply, :ok, State.t(), [{pos_integer(), atom()}]}
                     | {:noreply, State.t(), [{pos_integer(), atom()}]}

  # --- LLM Slot Management ---

  @doc """
  Handles an LLM slot request.

  Returns `{:reply, :ok, state, status_updates}` if a slot is immediately available,
  or `{:noreply, state, status_updates}` if the agent must wait (no slots or in backoff).
  """
  @spec handle_request_llm_slot(pos_integer(), GenServer.from(), State.t()) :: slot_result()
  def handle_request_llm_slot(agent_id, from, %State{} = state) do
    if state.paused do
      llm_waiting = :queue.in({agent_id, from, nil}, state.llm_waiting)
      {:noreply, %State{state | llm_waiting: llm_waiting}, [{agent_id, :blocked}]}
    else
      do_handle_request_llm_slot(agent_id, from, state)
    end
  end

  defp do_handle_request_llm_slot(agent_id, from, %State{} = state) do
    now = System.monotonic_time(:millisecond)

    if state.llm_backoff_until && now < state.llm_backoff_until do
      llm_waiting = :queue.in({agent_id, from, state.llm_backoff_until}, state.llm_waiting)
      {:noreply, %State{state | llm_waiting: llm_waiting}, [{agent_id, :blocked}]}
    else
      if MapSet.size(state.llm_holders) < state.max_concurrency do
        state = %State{state | llm_holders: MapSet.put(state.llm_holders, agent_id)}
        {:reply, :ok, state, []}
      else
        llm_waiting = :queue.in({agent_id, from, nil}, state.llm_waiting)
        {:noreply, %State{state | llm_waiting: llm_waiting}, [{agent_id, :blocked}]}
      end
    end
  end

  @doc """
  Handles an LLM slot release.

  Removes the agent from the holder set and grants pending requests.
  Returns `{:reply, :ok, state, status_updates}`.
  """
  @spec handle_release_llm_slot(pos_integer(), State.t()) ::
          {:reply, :ok, State.t(), [{pos_integer(), atom()}]}
  def handle_release_llm_slot(agent_id, %State{} = state) do
    state = %State{state | llm_holders: MapSet.delete(state.llm_holders, agent_id)}
    {state, unblocked} = grant_pending_llm_slots(state)
    {:reply, :ok, state, unblocked}
  end

  @doc """
  Handles an LLM error report.

  Rate-limit errors trigger a 60-second global backoff, re-queuing all waiting
  agents with the backoff timestamp. Other error types are no-ops.
  Returns `{:reply, :ok, state, status_updates}`.
  """
  @spec handle_report_llm_error(pos_integer(), atom(), State.t()) ::
          {:reply, :ok, State.t(), [{pos_integer(), atom()}]}
  def handle_report_llm_error(_agent_id, :rate_limit, %State{} = state) do
    backoff_until = System.monotonic_time(:millisecond) + 60_000
    Logger.warning("AgentScheduler: LLM rate limit detected, global backoff until #{backoff_until}")

    llm_waiting = update_waiting_with_backoff(state.llm_waiting, backoff_until)

    Process.send_after(self(), :retry_llm_waiting, 65_000)

    {:reply, :ok, %State{state | llm_backoff_until: backoff_until, llm_waiting: llm_waiting}, []}
  end

  def handle_report_llm_error(_agent_id, _error_type, %State{} = state) do
    {:reply, :ok, state, []}
  end

  @doc """
  Handles the retry_llm_waiting timer.

  Grants pending LLM slots after a backoff period expires.
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
  the agent from both LLM and tool holder sets, then grants any newly-
  available slots to pending waiters. Also purges the agent from both
  waiting queues (a crashed agent waiting for a slot must be removed or
  it would consume a granted slot as a dead process).

  Returns `{state, status_updates}`.
  """
  @spec release_agent_slots(State.t(), pos_integer()) :: {State.t(), [{pos_integer(), atom()}]}
  def release_agent_slots(%State{} = state, agent_id) do
    # Remove from holder sets
    state = %State{
      state
      | llm_holders: MapSet.delete(state.llm_holders, agent_id),
        tool_holders: MapSet.delete(state.tool_holders, agent_id)
    }

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
  Purges agents from both LLM and tool waiting queues.

  Replies `{:error, :cancelled}` to each purged agent's blocked GenServer.from
  so their waiting calls unblock cleanly. Returns the updated state with
  rebuilt queues excluding the purged agent IDs.

  Returns `{state, status_updates}`.
  """
  @spec purge_agents_from_queues(State.t(), MapSet.t(pos_integer())) :: {State.t(), [{pos_integer(), atom()}]}
  def purge_agents_from_queues(%State{} = state, agent_ids) do
    {llm_kept, llm_removed} = partition_llm_waiting(state.llm_waiting, agent_ids)
    {tool_kept, tool_removed} = partition_tool_waiting(state.tool_waiting, agent_ids)

    Enum.each(llm_removed, fn {_agent_id, from, _backoff} -> GenServer.reply(from, {:error, :cancelled}) end)
    Enum.each(tool_removed, fn {_agent_id, from} -> GenServer.reply(from, {:error, :cancelled}) end)

    state = %State{state | llm_waiting: llm_kept, tool_waiting: tool_kept}
    {state, []}
  end

  # Partitions the LLM waiting queue into kept and removed entries based on agent_ids.
  defp partition_llm_waiting(waiting, agent_ids) do
    {kept, removed} =
      waiting
      |> :queue.to_list()
      |> Enum.split_with(fn
        {agent_id, _from} -> not MapSet.member?(agent_ids, agent_id)
        {agent_id, _from, _backoff} -> not MapSet.member?(agent_ids, agent_id)
      end)

    {:queue.from_list(kept), removed}
  end

  # Partitions the tool waiting queue into kept and removed entries based on agent_ids.
  defp partition_tool_waiting(waiting, agent_ids) do
    {kept, removed} =
      waiting
      |> :queue.to_list()
      |> Enum.split_with(fn {agent_id, _from} -> not MapSet.member?(agent_ids, agent_id) end)

    {:queue.from_list(kept), removed}
  end

  # --- Private Helpers: LLM Slots ---

  # Grants pending LLM slots that are no longer in backoff.
  # Uses holder sets: grants while map_size(holders) < capacity.
  # Returns {state, unblocked} where unblocked is a list of {agent_id, :running}.
  defp grant_pending_llm_slots(%State{} = state) do
    grant_llm_from_queue(state)
  end

  defp grant_llm_from_queue(%State{} = state) do
    now = System.monotonic_time(:millisecond)

    cond do
      MapSet.size(state.llm_holders) >= state.max_concurrency ->
        {state, []}

      true ->
        case :queue.out(state.llm_waiting) do
          {{:value, {agent_id, from}}, rest_waiting} ->
            GenServer.reply(from, :ok)
            state = maybe_clear_llm_backoff(state)
            state = %State{state | llm_waiting: rest_waiting, llm_holders: MapSet.put(state.llm_holders, agent_id)}
            {state, more} = grant_llm_from_queue(state)
            {state, [{agent_id, :running} | more]}

          {{:value, {agent_id, from, backoff_until}}, rest_waiting} ->
            if backoff_until && now < backoff_until do
              # Still in backoff - re-enqueue at front and stop
              state = maybe_clear_llm_backoff(state)
              state = %State{state | llm_waiting: :queue.in_r({agent_id, from, backoff_until}, rest_waiting)}
              {state, []}
            else
              GenServer.reply(from, :ok)
              state = maybe_clear_llm_backoff(state)
              state = %State{state | llm_waiting: rest_waiting, llm_holders: MapSet.put(state.llm_holders, agent_id)}
              {state, more} = grant_llm_from_queue(state)
              {state, [{agent_id, :running} | more]}
            end

          {:empty, _} ->
            {state, []}
        end
    end
  end

  # Clears the global LLM backoff if it has expired
  defp maybe_clear_llm_backoff(%State{llm_backoff_until: backoff_until} = state) do
    now = System.monotonic_time(:millisecond)

    if backoff_until && now >= backoff_until do
      Logger.info("AgentScheduler: LLM global backoff expired, resuming normal operations")
      %State{state | llm_backoff_until: nil}
    else
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
          state = %State{state | tool_waiting: rest_waiting, tool_holders: MapSet.put(state.tool_holders, agent_id)}
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
