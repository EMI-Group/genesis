defmodule EvoGit.AgentScheduler.Slots do
  @moduledoc """
  LLM and tool slot management for the AgentScheduler.

  Provides pure functions that operate on the scheduler state map
  to manage concurrent LLM call and tool execution slots.

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

  # --- LLM Slot Management ---

  @doc """
  Handles an LLM slot request.

  Returns `{:reply, :ok, state, status_updates}` if a slot is immediately available,
  or `{:noreply, state, status_updates}` if the agent must wait (no slots or in backoff).
  """
  def handle_request_llm_slot(agent_id, from, state) do
    now = System.monotonic_time(:millisecond)

    # Check if we're in a global backoff period
    if state.llm_backoff_until && now < state.llm_backoff_until do
      # Still in backoff - queue the request
      llm_waiting = :queue.in({agent_id, from, state.llm_backoff_until}, state.llm_waiting)
      {:noreply, %{state | llm_waiting: llm_waiting}, [{agent_id, :blocked}]}
    else
      if state.llm_slots_available > 0 do
        state = %{state | llm_slots_available: state.llm_slots_available - 1}
        {:reply, :ok, state, []}
      else
        llm_waiting = :queue.in({agent_id, from, nil}, state.llm_waiting)
        {:noreply, %{state | llm_waiting: llm_waiting}, [{agent_id, :blocked}]}
      end
    end
  end

  @doc """
  Handles an LLM slot release.

  Increments available slots and grants pending requests.
  Returns `{:reply, :ok, state, status_updates}`.
  """
  def handle_release_llm_slot(_agent_id, state) do
    state = %{state | llm_slots_available: min(state.llm_slots_available + 1, state.max_concurrency)}
    {state, unblocked} = grant_pending_llm_slots(state)
    {:reply, :ok, state, unblocked}
  end

  @doc """
  Handles an LLM error report.

  Rate-limit errors trigger a 60-second global backoff, re-queuing all waiting
  agents with the backoff timestamp. Other error types are no-ops.
  Returns `{:reply, :ok, state, status_updates}`.
  """
  def handle_report_llm_error(_agent_id, :rate_limit, state) do
    # Set global backoff: 60 seconds from now
    backoff_until = System.monotonic_time(:millisecond) + 60_000
    Logger.warning("AgentScheduler: LLM rate limit detected, global backoff until #{backoff_until}")

    # Re-queue all currently waiting agents with the backoff timestamp
    llm_waiting = update_waiting_with_backoff(state.llm_waiting, backoff_until)

    # Schedule a retry after backoff expires to unstick waiting agents
    Process.send_after(self(), :retry_llm_waiting, 65_000)

    # No status changes - agents that were blocked remain blocked
    {:reply, :ok, %{state | llm_backoff_until: backoff_until, llm_waiting: llm_waiting}, []}
  end

  def handle_report_llm_error(_agent_id, _error_type, state) do
    # Other error types don't trigger global backoff
    {:reply, :ok, state, []}
  end

  @doc """
  Handles the retry_llm_waiting timer.

  Grants pending LLM slots after a backoff period expires.
  Returns `{:noreply, state, status_updates}`.
  """
  def handle_retry_llm_waiting(state) do
    {state, unblocked} = grant_pending_llm_slots(state)
    {:noreply, state, unblocked}
  end

  # --- Tool Slot Management ---

  @doc """
  Handles a tool slot request.

  Returns `{:reply, :ok, state, status_updates}` if a slot is immediately available,
  or `{:noreply, state, status_updates}` if the agent must wait.
  """
  def handle_request_tool_slot(agent_id, from, state) do
    if state.tool_slots_available > 0 do
      state = %{state | tool_slots_available: state.tool_slots_available - 1}
      {:reply, :ok, state, []}
    else
      tool_waiting = :queue.in({agent_id, from}, state.tool_waiting)
      {:noreply, %{state | tool_waiting: tool_waiting}, [{agent_id, :blocked}]}
    end
  end

  @doc """
  Handles a tool slot release.

  Increments available slots and grants pending requests.
  Returns `{:reply, :ok, state, status_updates}`.
  """
  def handle_release_tool_slot(_agent_id, state) do
    state = %{state | tool_slots_available: min(state.tool_slots_available + 1, state.max_tool_concurrency)}
    {state, unblocked} = grant_pending_tool_slots(state)
    {:reply, :ok, state, unblocked}
  end

  # --- Private Helpers: LLM Slots ---

  # Grants pending LLM slots that are no longer in backoff.
  # Returns {state, unblocked} where unblocked is a list of {agent_id, :running}.
  defp grant_pending_llm_slots(%{llm_waiting: waiting, llm_slots_available: slots} = state)
       when slots > 0 do
    now = System.monotonic_time(:millisecond)

    case :queue.out(waiting) do
      {{:value, {agent_id, from}}, rest_waiting} ->
        # 2-tuple entry: no backoff, grant immediately
        GenServer.reply(from, :ok)
        state = maybe_clear_llm_backoff(state)
        {state, more} = grant_pending_llm_slots(%{state | llm_waiting: rest_waiting, llm_slots_available: slots - 1})
        {state, [{agent_id, :running} | more]}

      {{:value, {agent_id, from, backoff_until}}, rest_waiting} ->
        if backoff_until && now < backoff_until do
          # Still in backoff - re-enqueue at front of rest and stop processing
          state = maybe_clear_llm_backoff(state)
          updated_waiting = :queue.in_r({agent_id, from, backoff_until}, rest_waiting)
          {state, []}
        else
          # Backoff expired or not set - grant the slot
          GenServer.reply(from, :ok)
          state = maybe_clear_llm_backoff(state)
          {state, more} = grant_pending_llm_slots(%{state | llm_waiting: rest_waiting, llm_slots_available: slots - 1})
          {state, [{agent_id, :running} | more]}
        end

      {:empty, _} ->
        {state, []}
    end
  end

  defp grant_pending_llm_slots(state), do: {state, []}

  # Clears the global LLM backoff if it has expired
  defp maybe_clear_llm_backoff(%{llm_backoff_until: backoff_until} = state) do
    now = System.monotonic_time(:millisecond)

    if backoff_until && now >= backoff_until do
      Logger.info("AgentScheduler: LLM global backoff expired, resuming normal operations")
      %{state | llm_backoff_until: nil}
    else
      state
    end
  end

  # --- Private Helpers: Tool Slots ---

  # Grants pending tool slots.
  # Returns {state, unblocked} where unblocked is a list of {agent_id, :running}.
  defp grant_pending_tool_slots(%{tool_waiting: waiting, tool_slots_available: slots} = state)
       when slots > 0 do
    case :queue.out(waiting) do
      {{:value, {agent_id, from}}, rest_waiting} ->
        GenServer.reply(from, :ok)
        {state, more} = grant_pending_tool_slots(%{state | tool_waiting: rest_waiting, tool_slots_available: slots - 1})
        {state, [{agent_id, :running} | more]}

      {:empty, _} ->
        {state, []}
    end
  end

  defp grant_pending_tool_slots(state), do: {state, []}

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
