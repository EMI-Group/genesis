defmodule EvoGit.AgentScheduler.ToolPermits do
  @moduledoc """
  Per-call tool permits owned by monitored caller processes.

  Client calls target the scheduler; its hub must route the three calls and
  monitor DOWN messages to the handlers here and apply returned status updates.
  Explicit permits and legacy agent slots share capacity and one FIFO queue.
  Legacy holders retain their historical one-slot-per-agent semantics; explicit
  permits count every call separately, including calls from the same agent.
  """

  alias EvoGit.AgentScheduler.State

  @spec acquire_tool_permit(pos_integer()) :: {:ok, reference()} | {:error, term()}
  def acquire_tool_permit(agent_id),
    do: GenServer.call(EvoGit.AgentScheduler, {:acquire_tool_permit, agent_id}, :infinity)

  @spec transfer_tool_permit(reference(), pid()) :: :ok | {:error, term()}
  def transfer_tool_permit(permit, new_owner_pid),
    do: GenServer.call(EvoGit.AgentScheduler, {:transfer_tool_permit, permit, new_owner_pid})

  @spec release_tool_permit(reference()) :: :ok
  def release_tool_permit(permit),
    do: GenServer.call(EvoGit.AgentScheduler, {:release_tool_permit, permit})

  def handle_acquire(agent_id, {owner, _} = from, %State{} = state) do
    permit = make_ref()
    monitor = Process.monitor(owner)
    entry = %{agent_id: agent_id, owner: owner, monitor: monitor, from: from, status: :waiting}

    state = %State{
      state
      | tool_permits: Map.put(state.tool_permits, permit, entry),
        tool_permit_monitors: Map.put(state.tool_permit_monitors, monitor, {:permit, permit})
    }

    if not state.paused and occupancy(state) < state.max_tool_concurrency do
      {:reply, {:ok, permit}, put_in(state.tool_permits[permit].status, :granted), []}
    else
      state = %{state | tool_waiting: :queue.in({:permit, permit}, state.tool_waiting)}
      {:noreply, state, [{agent_id, :blocked}]}
    end
  end

  def handle_transfer(permit, owner, %State{} = state) do
    case Map.get(state.tool_permits, permit) do
      %{status: :granted} = entry when is_pid(owner) ->
        if owner_alive?(owner) do
          Process.demonitor(entry.monitor, [:flush])
          monitor = Process.monitor(owner)
          entry = %{entry | owner: owner, monitor: monitor}

          monitors =
            state.tool_permit_monitors
            |> Map.delete(entry_monitor(state, permit))
            |> Map.put(monitor, {:permit, permit})

          {:reply, :ok,
           %{
             state
             | tool_permits: Map.put(state.tool_permits, permit, entry),
               tool_permit_monitors: monitors
           }, []}
        else
          {:reply, {:error, :owner_not_alive}, state, []}
        end

      nil ->
        {:reply, {:error, :not_found}, state, []}

      _ ->
        {:reply, {:error, :invalid_owner_or_permit}, state, []}
    end
  end

  # Remote liveness is settled by the monitor (including :noconnection),
  # not Process.alive?/1, which only accepts local pids.
  defp owner_alive?(owner), do: node(owner) != node() or Process.alive?(owner)

  defp entry_monitor(state, permit), do: state.tool_permits[permit].monitor

  def handle_release(permit, %State{} = state) do
    {state, updates} = state |> drop_permit(permit) |> grant_pending()
    {:reply, :ok, state, updates}
  end

  @doc "Returns :unhandled for monitor refs not owned by tool permits."
  def handle_down(monitor, %State{} = state) do
    case Map.get(state.tool_permit_monitors, monitor) do
      nil ->
        :unhandled

      {:permit, permit} ->
        {state, updates} = state |> drop_permit(permit) |> grant_pending()
        {:noreply, state, updates}

      {:legacy, from} ->
        state = %{
          state
          | tool_waiting:
              filter_queue(state.tool_waiting, fn
                {:permit, _} -> true
                {_, queued_from} -> queued_from != from
              end)
        }

        {state, updates} = state |> forget_monitor(monitor) |> grant_pending()
        {:noreply, state, updates}
    end
  end

  def monitor_legacy_waiter(%State{} = state, {_agent_id, {owner, _} = from}) do
    monitor = Process.monitor(owner)
    %{state | tool_permit_monitors: Map.put(state.tool_permit_monitors, monitor, {:legacy, from})}
  end

  def occupancy(state),
    do:
      MapSet.size(state.tool_holders) +
        Enum.count(state.tool_permits, fn {_, entry} -> entry.status == :granted end)

  def release_agent(%State{} = state, agent_id) do
    Enum.reduce(state.tool_permits, state, fn {permit, entry}, acc ->
      if entry.agent_id == agent_id, do: drop_permit(acc, permit), else: acc
    end)
  end

  def purge_waiters(%State{} = state, agent_ids, reply) do
    Enum.reduce(:queue.to_list(state.tool_waiting), state, fn queued, acc ->
      case waiter(acc, queued) do
        {agent_id, from} ->
          if MapSet.member?(agent_ids, agent_id) do
            GenServer.reply(from, reply)
            remove_waiter(acc, queued)
          else
            acc
          end

        nil ->
          acc
      end
    end)
  end

  def grant_pending(%State{paused: true} = state), do: {state, []}

  def grant_pending(%State{} = state) do
    if occupancy(state) >= state.max_tool_concurrency do
      {state, []}
    else
      case :queue.out(state.tool_waiting) do
        {:empty, _} ->
          {state, []}

        {{:value, queued}, rest} ->
          state = %{state | tool_waiting: rest}

          case waiter(state, queued) do
            {agent_id, {owner, _} = from} ->
              if owner_alive?(owner) do
                {state, reply} = grant(state, queued, agent_id, from)
                GenServer.reply(from, reply)
                {state, updates} = grant_pending(state)
                {state, [{agent_id, :running} | updates]}
              else
                state |> remove_waiter(queued) |> grant_pending()
              end

            nil ->
              grant_pending(state)
          end
      end
    end
  end

  defp grant(state, {:permit, permit}, _, _),
    do: {put_in(state.tool_permits[permit].status, :granted), {:ok, permit}}

  defp grant(state, _, agent_id, from),
    do:
      {%{
         forget_legacy_monitor(state, from)
         | tool_holders: MapSet.put(state.tool_holders, agent_id)
       }, :ok}

  defp waiter(state, {:permit, permit}) do
    case Map.get(state.tool_permits, permit) do
      nil -> nil
      entry -> {entry.agent_id, entry.from}
    end
  end

  defp waiter(_, {agent_id, from}), do: {agent_id, from}

  defp remove_waiter(state, {:permit, permit}), do: drop_permit(state, permit)

  defp remove_waiter(state, {_, from} = queued) do
    state = forget_legacy_monitor(state, from)
    %{state | tool_waiting: filter_queue(state.tool_waiting, &(&1 != queued))}
  end

  defp drop_permit(state, permit) do
    case Map.pop(state.tool_permits, permit) do
      {nil, _} ->
        state

      {entry, permits} ->
        state = forget_monitor(state, entry.monitor)

        %{
          state
          | tool_permits: permits,
            tool_waiting: filter_queue(state.tool_waiting, &(&1 != {:permit, permit}))
        }
    end
  end

  defp forget_legacy_monitor(state, from) do
    Enum.reduce(state.tool_permit_monitors, state, fn
      {monitor, {:legacy, ^from}}, acc -> forget_monitor(acc, monitor)
      _, acc -> acc
    end)
  end

  defp forget_monitor(state, monitor) do
    Process.demonitor(monitor, [:flush])
    %{state | tool_permit_monitors: Map.delete(state.tool_permit_monitors, monitor)}
  end

  defp filter_queue(queue, predicate),
    do: queue |> :queue.to_list() |> Enum.filter(predicate) |> :queue.from_list()
end
