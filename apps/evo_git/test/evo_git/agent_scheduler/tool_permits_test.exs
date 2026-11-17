defmodule EvoGit.AgentScheduler.ToolPermitsTest do
  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.{State, ToolPermits}

  # In-process handlers own their monitors and State; no singleton configuration,
  # ETS writes, app env or live scheduler calls are needed. Public client wrappers
  # target the global scheduler, so these tests exercise its routing directly.
  setup do
    %{agent: 2_100_000_000 + System.unique_integer([:positive, :monotonic])}
  end

  test "concurrent invocations by one agent consume distinct permits and release once", %{
    agent: agent
  } do
    state = %State{max_tool_concurrency: 2}
    {first, state} = acquire(state, agent)
    {second, state} = acquire(state, agent)
    refute first == second
    assert ToolPermits.occupancy(state) == 2
    assert MapSet.size(state.tool_holders) == 0

    {third, reply, state} = enqueue(state, agent)
    assert ToolPermits.occupancy(state) == 2
    refute_received {^reply, _}

    assert {:reply, :ok, state, [{^agent, :running}]} =
             ToolPermits.handle_release(first, self(), state)

    assert_received {^reply, {:ok, ^third}}
    assert ToolPermits.occupancy(state) == 2
    assert Map.keys(state.tool_permits) |> MapSet.new() == MapSet.new([second, third])
    assert :queue.is_empty(state.tool_waiting)
    assert ToolPermits.handle_release(first, self(), state) == {:reply, :ok, state, []}
    assert ToolPermits.grant_pending(state) == {state, []}
    refute_received {^reply, _}

    state = release(state, second)
    state = release(state, third)
    assert_empty(state)
  end

  test "queued caller DOWN removes its permit and monitor without disturbing the FIFO", %{
    agent: agent
  } do
    {holder, state} = acquire(%State{max_tool_concurrency: 1}, agent)
    owner = parked_owner()
    {dead, _reply, state} = enqueue(state, agent, owner)
    monitor = state.tool_permits[dead].monitor
    {survivor, reply, state} = enqueue(state, agent)

    stop_and_receive_down(owner, monitor)
    assert {:noreply, state, []} = ToolPermits.handle_down(monitor, state)
    refute Map.has_key?(state.tool_permits, dead)
    refute Map.has_key?(state.tool_permit_monitors, monitor)
    assert :queue.to_list(state.tool_waiting) == [{:permit, survivor}]
    assert ToolPermits.occupancy(state) == 1
    assert ToolPermits.handle_down(monitor, state) == :unhandled
    refute_received {^reply, _}

    assert {:reply, :ok, state, [{^agent, :running}]} =
             ToolPermits.handle_release(holder, self(), state)

    assert_received {^reply, {:ok, ^survivor}}
    assert ToolPermits.grant_pending(state) == {state, []}
    refute_received {^reply, _}
    assert_empty(release(state, survivor))
  end

  test "hub transfer is capability-based and stale original-owner release is inert", %{
    agent: agent
  } do
    original = parked_owner()
    recipient = parked_owner()
    unrelated_caller = {self(), make_ref()}

    assert {:reply, {:ok, permit}, state} =
             AgentScheduler.handle_call(
               {:acquire_tool_permit, agent},
               {original, make_ref()},
               %State{max_tool_concurrency: 1}
             )

    old_monitor = state.tool_permits[permit].monitor

    # The background registry can transfer on behalf of a tool task: the
    # transferring caller intentionally differs from the original owner.
    assert {:reply, :ok, state} =
             AgentScheduler.handle_call(
               {:transfer_tool_permit, permit, recipient},
               unrelated_caller,
               state
             )

    assert state.tool_permits[permit].owner == recipient
    new_monitor = state.tool_permits[permit].monitor
    refute new_monitor == old_monitor
    assert state.tool_permit_monitors == %{new_monitor => {:permit, permit}}
    assert ToolPermits.handle_down(old_monitor, state) == :unhandled

    assert AgentScheduler.handle_call(
             {:release_tool_permit, permit},
             {original, make_ref()},
             state
           ) == {:reply, :ok, state}

    assert ToolPermits.occupancy(state) == 1

    assert {:reply, :ok, state} =
             AgentScheduler.handle_call(
               {:release_tool_permit, permit},
               {recipient, make_ref()},
               state
             )

    assert_empty(state)
    assert ToolPermits.handle_down(new_monitor, state) == :unhandled
  end

  test "transferred owner death reclaims capacity and grants a queued invocation exactly once", %{
    agent: agent
  } do
    original = parked_owner()
    recipient = parked_owner()
    {permit, state} = acquire(%State{max_tool_concurrency: 1}, agent, original)
    old_monitor = state.tool_permits[permit].monitor
    assert {:reply, :ok, state, []} = ToolPermits.handle_transfer(permit, recipient, state)
    {waiting, reply, state} = enqueue(state, agent)

    # Observe original death independently: transfer must have disarmed its
    # scheduler monitor, and even an already-delivered old DOWN is harmless.
    original_watch = Process.monitor(original)
    stop_and_receive_down(original, original_watch)
    assert ToolPermits.handle_down(old_monitor, state) == :unhandled
    assert ToolPermits.occupancy(state) == 1
    refute_received {^reply, _}

    monitor = state.tool_permits[permit].monitor
    stop_and_receive_down(recipient, monitor)
    assert {:noreply, state, [{^agent, :running}]} = ToolPermits.handle_down(monitor, state)
    assert_received {^reply, {:ok, ^waiting}}
    refute Map.has_key?(state.tool_permits, permit)
    assert ToolPermits.occupancy(state) == 1
    assert ToolPermits.handle_down(monitor, state) == :unhandled
    assert ToolPermits.grant_pending(state) == {state, []}
    refute_received {^reply, _}
    assert_empty(release(state, waiting))
  end

  test "invalid transfers preserve state and missing releases are idempotent", %{agent: agent} do
    {permit, state} = acquire(%State{max_tool_concurrency: 1}, agent)
    {waiting, reply, state} = enqueue(state, agent)
    dead = parked_owner()
    stop_and_receive_down(dead, Process.monitor(dead))

    for {candidate, owner, error} <- [
          {make_ref(), self(), :not_found},
          {permit, :not_a_pid, :invalid_owner_or_permit},
          {waiting, self(), :invalid_owner_or_permit},
          {permit, dead, :owner_not_alive}
        ] do
      assert ToolPermits.handle_transfer(candidate, owner, state) ==
               {:reply, {:error, error}, state, []}
    end

    assert ToolPermits.handle_release(make_ref(), self(), state) == {:reply, :ok, state, []}
    assert ToolPermits.occupancy(state) == 1
    refute_received {^reply, _}
    state = release(state, waiting)
    assert_empty(release(state, permit))
  end

  defp acquire(state, agent, owner \\ self()) do
    assert {:reply, {:ok, permit}, state, []} =
             ToolPermits.handle_acquire(agent, {owner, make_ref()}, state)

    assert is_reference(permit)
    {permit, state}
  end

  defp enqueue(state, agent, owner \\ self()) do
    reply = make_ref()

    assert {:noreply, state, [{^agent, :blocked}]} =
             ToolPermits.handle_acquire(agent, {owner, reply}, state)

    assert {:permit, permit} = :queue.to_list(state.tool_waiting) |> List.last()
    assert state.tool_permits[permit].status == :waiting
    {permit, reply, state}
  end

  defp release(state, permit) do
    assert {:reply, :ok, state, []} = ToolPermits.handle_release(permit, self(), state)
    state
  end

  defp assert_empty(state) do
    assert state.tool_permits == %{}
    assert state.tool_permit_monitors == %{}
    assert :queue.is_empty(state.tool_waiting)
    assert ToolPermits.occupancy(state) == 0
  end

  defp parked_owner do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp stop_and_receive_down(pid, monitor) do
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 30_000
  end
end
