Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

defmodule EvoGit.Agent.Tools.ElixirEval.WorkerTreeTest do
  @moduledoc """
  Real WorkerTree/Broker/Custodian lifecycles with genuine assistant authority.

  Async-safe: each case owns its registry, owner/tool Tasks and unique ETS rows.
  Tracing targets only this evaluation's custodian; no registered names, scheduler
  configuration, global trace patterns or authorization/Dune mocks are changed.
  Every unlinked descendant waits for an explicit test message (or custody kill).
  """
  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.Agent.Tools.ElixirEval.{Authorization, WorkerTree}
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  @deadline 15_000
  @limits %{timeout_ms: 30_000, max_output_bytes: 4_096}

  setup %{store: store, registry: registry} do
    fixture = Fixture.start!(self(), store, registry)
    on_exit(fn -> Fixture.stop(fixture) end)
    %{fixture: fixture}
  end

  for {outcome, expected} <- [
        {:success, {:ok, "finished"}},
        {:raise, {:error, "Evaluation raised an exception."}},
        {:exit, {:error, "Evaluation exited or threw a value."}},
        {:throw, {:error, "Evaluation exited or threw a value."}}
      ] do
    @outcome outcome
    @expected expected
    test "#{outcome} waits for root, child, grandchild DOWN and the custody trace barrier", %{
      fixture: fixture
    } do
      tree = start_tree(fixture)
      assert_held_tree(tree)
      observe_custodian(tree)

      send(tree.root, {tree.tag, @outcome})

      assert Fixture.await(tree.handle) == @expected
      assert_reaped(tree)
      assert_custody_barrier(tree)
      assert_cleanup_ack(tree)
      assert_infrastructure_down(tree)
      assert Process.alive?(fixture.owner_pid)
    end
  end

  test "an uncatchable evaluated worker kill also reaps unlinked descendants", %{fixture: fixture} do
    tree = start_tree(fixture)
    assert_held_tree(tree)
    observe_custodian(tree)
    send(tree.root, {tree.tag, :kill})

    assert Fixture.await(tree.handle) ==
             {:error, "Evaluation worker stopped (memory limit or runtime failure)."}

    assert_reaped(tree)
    assert_custody_barrier(tree)
    assert_cleanup_ack(tree)
    assert_infrastructure_down(tree)
  end

  test "execution timeout reaps a held tree, rather than merely returning timeout text", %{
    fixture: fixture
  } do
    # Only this timeout regression spends an execution budget. All other trees
    # use a generous ceiling and finish on a handshake, not a sleep or busy loop.
    tree = start_tree(fixture, %{@limits | timeout_ms: 1_000})
    assert_held_tree(tree)
    observe_custodian(tree)

    assert Fixture.await(tree.handle) == {:error, "Evaluation timed out."}
    assert_reaped(tree)
    assert_custody_barrier(tree)
    assert_cleanup_ack(tree)
    assert_infrastructure_down(tree)
  end

  test "abrupt guardian loss cannot abandon unlinked child or grandchild", %{fixture: fixture} do
    tree = start_tree(fixture)
    assert_held_tree(tree)
    observe_custodian(tree)

    Process.exit(tree.guardian, :kill)

    assert Fixture.await(tree.handle) == {:error, "Evaluation guardian failed."}
    assert_reaped(tree)
    assert_custody_barrier(tree)
    assert_infrastructure_down(tree)
  end

  test "custody drains a descendant spawn queued before abrupt guardian loss", %{fixture: fixture} do
    tree = start_tree(fixture)
    assert_held_tree(tree)
    observe_custodian(tree)

    # Freeze the actual trace owner, not a stand-in. The late child's inherited
    # spawn event cannot be processed/forwarded before we kill the guardian.
    true = :erlang.suspend_process(tree.custodian)

    try do
      send(tree.child, {tree.tag, :spawn_late})
      tag = tree.tag
      assert_receive {^tag, :late, late}, @deadline
      late_monitor = monitor_for_cleanup(late)
      assert Process.alive?(late)
      assert {:links, []} = Process.info(late, :links)
      assert {:tracer, custodian} = :erlang.trace_info(late, :tracer)
      assert custodian == tree.custodian

      Process.exit(tree.guardian, :kill)
      assert_down(tree.monitors.guardian, tree.guardian, :killed)
      true = :erlang.resume_process(tree.custodian)

      assert Fixture.await(tree.handle) == {:error, "Evaluation guardian failed."}
      assert_reaped(tree)
      assert_down(late_monitor, late, :killed)
      assert_custody_barrier(tree, [late])
      # The guardian DOWN was deliberately consumed before resuming custody.
      assert_down(tree.monitors.custodian, tree.custodian, :normal)
      assert_down(tree.monitors.broker, tree.broker)
    after
      if Process.info(tree.custodian, :status) == {:status, :suspended},
        do: :erlang.resume_process(tree.custodian)
    end
  end

  test "original owner loss reaps descendants and infrastructure while the tool is still alive",
       %{
         fixture: fixture
       } do
    tree = start_tree(fixture)
    assert_held_tree(tree)
    observe_custodian(tree)
    tool_monitor = monitor_for_cleanup(tree.handle.tool_pid)
    owner_monitor = Process.monitor(fixture.owner_pid)

    Process.exit(fixture.owner_pid, :kill)
    assert_down(owner_monitor, fixture.owner_pid, :killed)

    # The fixture normally forwards through its owner. Observe the actual tool's
    # completion directly here: the dead owner cannot forward that result.
    tag = tree.tag
    assert_receive {^tag, :returned, {:error, message}}, @deadline

    assert message in [
             "Evaluation owner stopped.",
             "Evaluation broker stopped.",
             "Evaluation worker stopped (memory limit or runtime failure)."
           ]

    Process.demonitor(tree.handle.owner_monitor, [:flush])
    assert_down(tool_monitor, tree.handle.tool_pid, :normal)
    assert_reaped(tree)
    assert_custody_barrier(tree)
    assert_cleanup_ack(tree)
    assert_infrastructure_down(tree)
  end

  test "original tool loss activates custody even with its guardian suspended", %{
    fixture: fixture
  } do
    tree = start_tree(fixture)
    assert_held_tree(tree)
    observe_custodian(tree)
    tool_monitor = monitor_for_cleanup(tree.handle.tool_pid)

    # A suspended guardian cannot execute watch/1, an after block or finish/2.
    # Custodian's caller monitor must independently kill it and reap the tree.
    true = :erlang.suspend_process(tree.guardian)
    Process.exit(tree.handle.tool_pid, :kill)

    assert_down(tool_monitor, tree.handle.tool_pid, :killed)
    assert Fixture.await(tree.handle) == {:exit, :killed}
    assert_reaped(tree)
    assert_custody_barrier(tree)
    assert_infrastructure_down(tree)
    assert Process.alive?(fixture.owner_pid)
  end

  defp start_tree(fixture, limits \\ @limits) do
    test_pid = self()
    tag = make_ref()

    handle =
      Fixture.call_async(fixture, fn ->
        {:ok, context} = Authorization.authorize()

        result =
          WorkerTree.run(context, :read, limits, fn broker ->
            [guardian] = Process.get(:"$ancestors")
            {:tracer, custodian} = :erlang.trace_info(self(), :tracer)
            send(test_pid, {tag, :root, self(), guardian, broker, custodian})
            root = self()
            spawn(fn -> held_child(test_pid, tag, root) end)

            receive do
              {^tag, :success} -> {:ok, "finished"}
              {^tag, :raise} -> raise "evaluated secret must not escape"
              {^tag, :exit} -> exit({:evaluated_secret, make_ref()})
              {^tag, :throw} -> throw({:evaluated_secret, make_ref()})
              {^tag, :kill} -> Process.exit(self(), :kill)
            end
          end)

        send(test_pid, {tag, :returned, result})
        result
      end)

    assert_receive {^tag, :root, root, guardian, broker, custodian}, @deadline
    assert_receive {^tag, :child, child, ^root}, @deadline
    assert_receive {^tag, :grandchild, grandchild, ^child}, @deadline

    pids = %{
      root: root,
      child: child,
      grandchild: grandchild,
      guardian: guardian,
      broker: broker,
      custodian: custodian
    }

    monitors = Map.new(pids, fn {role, pid} -> {role, monitor_for_cleanup(pid)} end)
    Map.merge(pids, %{tag: tag, handle: handle, monitors: monitors})
  end

  defp held_child(test_pid, tag, root) do
    send(test_pid, {tag, :child, self(), root})
    child = self()

    spawn(fn ->
      send(test_pid, {tag, :grandchild, self(), child})
      hold(tag)
    end)

    child_loop(test_pid, tag)
  end

  defp child_loop(test_pid, tag) do
    receive do
      {^tag, :spawn_late} ->
        spawn(fn ->
          send(test_pid, {tag, :late, self()})
          hold(tag)
        end)

        child_loop(test_pid, tag)
    end
  end

  defp hold(tag) do
    receive do
      {^tag, :release} -> :ok
    end
  end

  defp monitor_for_cleanup(pid) do
    monitor = Process.monitor(pid)
    # Cleanup on assertion failure must not leak a held or suspended process.
    on_exit(fn -> Process.exit(pid, :kill) end)
    monitor
  end

  defp assert_held_tree(tree) do
    for pid <- [tree.root, tree.child, tree.grandchild, tree.guardian, tree.custodian] do
      assert Process.alive?(pid)
      assert {:links, []} = Process.info(pid, :links)
    end

    for pid <- [tree.root, tree.child, tree.grandchild] do
      assert {:tracer, custodian} = :erlang.trace_info(pid, :tracer)
      assert custodian == tree.custodian
      assert {:flags, flags} = :erlang.trace_info(pid, :flags)
      assert :procs in flags
      assert :set_on_spawn in flags
    end

    assert tree.custodian != tree.guardian
    assert tree.custodian != tree.handle.tool_pid
  end

  defp observe_custodian(tree) do
    # Custodian itself is not in its traced evaluation subtree. Observe its real
    # receive/ack protocol without stealing tracing from any evaluation worker.
    assert 1 == :erlang.trace(tree.custodian, true, [:send, :receive, {:tracer, self()}])
  end

  defp assert_reaped(tree) do
    assert_down(tree.monitors.root, tree.root)
    assert_down(tree.monitors.child, tree.child, :killed)
    assert_down(tree.monitors.grandchild, tree.grandchild, :killed)
  end

  defp assert_custody_barrier(tree, extra \\ []) do
    expected = MapSet.new([tree.root, tree.child, tree.grandchild | extra])

    custody_events_until_barrier(
      tree.custodian,
      expected,
      MapSet.new(),
      System.monotonic_time(:millisecond) + @deadline
    )
  end

  defp custody_events_until_barrier(custodian, expected, downs, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:trace, ^custodian, :receive, {:DOWN, _, :process, pid, _}} ->
        custody_events_until_barrier(custodian, expected, MapSet.put(downs, pid), deadline)

      {:trace, ^custodian, :receive, {:trace_delivered, :all, barrier}} ->
        assert is_reference(barrier)
        # A newly delivered spawn invalidates an earlier barrier. Ignore that
        # stale delivery, but require a later barrier AFTER all known deaths.
        unless MapSet.subset?(expected, downs),
          do: custody_events_until_barrier(custodian, expected, downs, deadline)

      {:trace, ^custodian, :receive, _} ->
        custody_events_until_barrier(custodian, expected, downs, deadline)
    after
      remaining -> flunk("custodian never confirmed its trace-delivery barrier")
    end
  end

  defp assert_cleanup_ack(tree) do
    custodian = tree.custodian
    guardian = tree.guardian
    assert_receive {:trace, ^custodian, :send, {token, :cleaned, :ok}, ^guardian}, @deadline
    assert is_reference(token)
  end

  defp assert_infrastructure_down(tree) do
    assert_down(tree.monitors.guardian, tree.guardian)
    assert_down(tree.monitors.custodian, tree.custodian, :normal)
    assert_down(tree.monitors.broker, tree.broker)
  end

  defp assert_down(monitor, pid, expected \\ :normal_or_killed) do
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, @deadline

    if expected == :normal_or_killed,
      do: assert(reason in [:normal, :killed]),
      else: assert(reason == expected)

    refute Process.alive?(pid)
  end
end
