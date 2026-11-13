defmodule EvoDashWeb.AgentsStreamWatchLifecycleTest do
  # Forcing globals: :evo_dash :agents_watch_runner / :agents_unwatch_runner
  # are BEAM-global RPC seams, shared with every real StreamWatch worker.
  use ExUnit.Case, async: false

  alias EvoDashWeb.AgentsLive.StreamWatch
  alias EvoGit.Agent.Stream.Snapshot

  @timeout 30_000
  @old_node :inspector_old@host
  @new_node :inspector_new@host
  @seams [:agents_watch_runner, :agents_unwatch_runner]

  setup do
    owner = self()
    previous = Map.new(@seams, &{&1, Application.fetch_env(:evo_dash, &1)})
    # Unlinked bookkeeping survives the test process, so on_exit can await ALL
    # workers before restoring the global seams, including after an assertion fails.
    {:ok, workers} = Agent.start(fn -> MapSet.new() end)

    for {key, kind} <- [agents_watch_runner: :watch, agents_unwatch_runner: :unwatch] do
      Application.put_env(:evo_dash, key, fn target_node, id, consumer ->
        rpc(owner, kind, target_node, id, consumer)
      end)
    end

    consumer = spawn(fn -> consume(socket(), owner, workers) end)

    on_exit(fn ->
      consumer_monitor = Process.monitor(consumer)
      send(consumer, :stop)
      assert_receive {:DOWN, ^consumer_monitor, :process, ^consumer, _}, @timeout

      for worker <- Agent.get(workers, &MapSet.to_list/1, @timeout) do
        monitor = Process.monitor(worker)
        assert_receive {:DOWN, ^monitor, :process, ^worker, _}, @timeout
      end

      Agent.stop(workers)

      for {key, value} <- previous do
        case value do
          {:ok, runner} -> Application.put_env(:evo_dash, key, runner)
          :error -> Application.delete_env(:evo_dash, key)
        end
      end
    end)

    %{consumer: consumer}
  end

  test "blocked A to B to A coalesces without an old unregister removing the new A", %{
    consumer: consumer
  } do
    a = unique_id()
    b = unique_id()
    first = select(consumer, a)
    worker = first.inspector_stream_worker
    first_call = expect_rpc(:watch, @old_node, a, consumer, worker)

    middle = select(consumer, b)
    last = select(consumer, a)
    assert last.inspector_stream_worker == worker
    assert first.inspector_stream.token < middle.inspector_stream.token
    assert middle.inspector_stream.token < last.inspector_stream.token

    release(first_call, snapshot(a))
    # The stale success has the SAME target: it must neither seed nor enqueue
    # cleanup of A. The next operation is another watch, never an unwatch or B.
    stale = expect_ready(first.inspector_stream.token)
    assert stale.inspector_stream.snapshot == nil
    second_call = expect_rpc(:watch, @old_node, a, consumer, worker)
    release(second_call, snapshot(a, 9))
    ready = expect_ready(last.inspector_stream.token)
    assert ready.inspector_stream.snapshot.seq == 9
    assert StreamWatch.active?(%Phoenix.LiveView.Socket{assigns: ready}, a)

    assert command(consumer, :detach).inspector_stream == nil
    release(expect_rpc(:unwatch, @old_node, a, consumer, worker), :ok)
    stop_and_await(consumer, worker)
    refute_receive {:rpc, _, _, _, _, _, _}, 0
  end

  test "obsolete registrations are unregistered serially before the next target registers", %{
    consumer: consumer
  } do
    a = unique_id()
    b = unique_id()
    first = select(consumer, a)
    worker = first.inspector_stream_worker
    release(expect_rpc(:watch, @old_node, a, consumer, worker), snapshot(a))
    expect_ready(first.inspector_stream.token)

    middle = select(consumer, b)
    # Hold A's unregister: B cannot register concurrently with it.
    cleanup_a = expect_rpc(:unwatch, @old_node, a, consumer, worker)
    release(cleanup_a, :ok)
    blocked_b = expect_rpc(:watch, @old_node, b, consumer, worker)
    last = select(consumer, a)
    release(blocked_b, snapshot(b))
    stale = expect_ready(middle.inspector_stream.token)
    assert stale.inspector_stream.agent_id == a
    assert stale.inspector_stream.snapshot == nil
    # ready/5 can also enqueue redundant stale cleanup. All cleanup MUST be
    # serialized ahead of the new A, and no cleanup of A is allowed afterwards.
    next_watch = cleanup_until_watch(consumer, worker, b, a)
    release(next_watch, snapshot(a))
    assert expect_ready(last.inspector_stream.token).inspector_stream.snapshot.agent_id == a

    command(consumer, :detach)
    release(expect_rpc(:unwatch, @old_node, a, consumer, worker), :ok)
    stop_and_await(consumer, worker)
    refute_receive {:rpc, _, _, _, _, _, _}, 0
  end

  test "detach clears immediately during a blocked watch and node switch cleans the old node", %{
    consumer: consumer
  } do
    id = unique_id()
    first = select(consumer, id)
    worker = first.inspector_stream_worker
    blocked = expect_rpc(:watch, @old_node, id, consumer, worker)
    detached = command(consumer, :detach)
    assert detached.inspector_stream == nil
    assert detached.inspector_stream_token > first.inspector_stream.token
    switched = command(consumer, {:select, id, @new_node})
    assert switched.inspector_stream.node == @new_node
    assert switched.inspector_stream_worker == worker
    release(blocked, snapshot(id))
    stale = expect_ready(first.inspector_stream.token)
    assert stale.inspector_stream.node == @new_node
    assert stale.inspector_stream.snapshot == nil

    # The id is unchanged, but node identity makes this an obsolete registration.
    next_watch = cleanup_until_watch(consumer, worker, id, id, @old_node, @new_node)
    release(next_watch, snapshot(id))
    assert expect_ready(switched.inspector_stream.token).inspector_stream.snapshot.agent_id == id
    command(consumer, :detach)
    release(expect_rpc(:unwatch, @new_node, id, consumer, worker), :ok)
    stop_and_await(consumer, worker)
    refute_receive {:rpc, _, _, _, _, _, _}, 0
  end

  test "consumer death unregisters its established watch and exits the worker", %{
    consumer: consumer
  } do
    id = unique_id()
    selected = select(consumer, id)
    worker = selected.inspector_stream_worker
    release(expect_rpc(:watch, @old_node, id, consumer, worker), snapshot(id))
    expect_ready(selected.inspector_stream.token)

    monitor = Process.monitor(worker)
    Process.exit(consumer, :kill)
    release(expect_rpc(:unwatch, @old_node, id, consumer, worker), :ok)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, @timeout
    refute_receive {:rpc, _, _, _, _, _, _}, 0
  end

  test "consumer death during registration cleans the late success before worker exit", %{
    consumer: consumer
  } do
    id = unique_id()
    worker = select(consumer, id).inspector_stream_worker
    blocked = expect_rpc(:watch, @old_node, id, consumer, worker)
    consumer_monitor = Process.monitor(consumer)
    worker_monitor = Process.monitor(worker)
    Process.exit(consumer, :kill)
    assert_receive {:DOWN, ^consumer_monitor, :process, ^consumer, :killed}, @timeout
    release(blocked, snapshot(id))
    release(expect_rpc(:unwatch, @old_node, id, consumer, worker), :ok)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, @timeout
    refute_receive {:rpc, _, _, _, _, _, _}, 0
  end

  test "failed registrations are cleaned and retry keeps the worker and consumer identity", %{
    consumer: consumer
  } do
    id = unique_id()
    first = select(consumer, id)
    worker = first.inspector_stream_worker

    for {action, reason} <- [
          {{:return, {:error, :offline}}, :offline},
          {{:exit, :rpc_down}, {:exit, :rpc_down}},
          {{:raise, "watch broke"}, {:exception, %RuntimeError{message: "watch broke"}}},
          {{:return, :malformed}, {:invalid_watch_result, {:ok, :malformed}}}
        ] do
      selected = command(consumer, :state)
      call = expect_rpc(:watch, @old_node, id, consumer, worker)
      respond(call, action)
      failed = expect_ready(selected.inspector_stream.token)
      assert failed.inspector_stream.error == reason
      assert failed.inspector_stream.snapshot == nil
      assert failed.inspector_stream.pending == []
      release(expect_rpc(:unwatch, @old_node, id, consumer, worker), :ok)
      retry = select(consumer, id)
      assert retry.inspector_stream_worker == worker
      assert retry.inspector_stream.error == nil
      assert retry.inspector_stream.token > selected.inspector_stream.token
    end

    final = command(consumer, :state)
    release(expect_rpc(:watch, @old_node, id, consumer, worker), snapshot(id))
    assert expect_ready(final.inspector_stream.token).inspector_stream.snapshot.agent_id == id
    command(consumer, :detach)
    release(expect_rpc(:unwatch, @old_node, id, consumer, worker), :ok)
    stop_and_await(consumer, worker)
    refute_receive {:rpc, _, _, _, _, _, _}, 0
  end

  test "cleanup failure is logged once without retrying or stranding the next selection", %{
    consumer: consumer
  } do
    a = unique_id()
    b = unique_id()
    first = select(consumer, a)
    worker = first.inspector_stream_worker
    release(expect_rpc(:watch, @old_node, a, consumer, worker), snapshot(a))
    expect_ready(first.inspector_stream.token)

    # Keep the warning's emitting worker inside the capture window through its
    # terminal DOWN, not merely through the asynchronous detach/selection call.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        next = select(consumer, b)
        respond(expect_rpc(:unwatch, @old_node, a, consumer, worker), {:exit, :cleanup_down})
        release(expect_rpc(:watch, @old_node, b, consumer, worker), snapshot(b))
        assert expect_ready(next.inspector_stream.token).inspector_stream.snapshot.agent_id == b
        command(consumer, :detach)
        release(expect_rpc(:unwatch, @old_node, b, consumer, worker), :ok)
        stop_and_await(consumer, worker)
        refute_receive {:rpc, _, _, _, _, _, _}, 0
      end)

    assert log =~ "Inspector stream cleanup failed"
    assert log =~ "cleanup_down"
    assert length(Regex.scan(~r/Inspector stream cleanup failed/, log)) == 1
  end

  defp socket do
    %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}, current_node: @old_node, inspector_stream: nil}
    }
  end

  # All public helper calls run in the isolated consumer, just as they must run
  # in a connected LiveView. No fabricated worker pid or direct worker command.
  defp consume(socket, owner, workers) do
    receive do
      {:command, from, ref, operation} ->
        socket =
          case operation do
            {:select, id, target_node} ->
              socket
              |> Phoenix.Component.assign(:current_node, target_node)
              |> StreamWatch.attach(id)

            :detach ->
              StreamWatch.detach(socket)

            :state ->
              socket
          end

        if worker = socket.assigns[:inspector_stream_worker] do
          Agent.update(workers, &MapSet.put(&1, worker), @timeout)
        end

        send(from, {ref, socket.assigns})
        consume(socket, owner, workers)

      {:inspector_stream_ready, target_node, token, id, result} ->
        socket = StreamWatch.ready(socket, target_node, token, id, result)
        send(owner, {:ready_applied, token, socket.assigns})
        consume(socket, owner, workers)

      :stop ->
        :ok
    end
  end

  defp rpc(owner, kind, target_node, id, consumer) do
    ref = make_ref()
    monitor = Process.monitor(owner)
    send(owner, {:rpc, kind, target_node, id, consumer, self(), ref})

    # The owner monitor is teardown-only escape machinery: if a test fails with
    # an RPC blocked, it releases naturally so on_exit can await the real worker.
    action =
      receive do
        {^ref, action} ->
          action

        {:DOWN, ^monitor, :process, ^owner, _} ->
          {:return, if(kind == :watch, do: snapshot(id), else: :ok)}
      after
        @timeout -> raise "test did not release #{kind} RPC"
      end

    Process.demonitor(monitor, [:flush])

    case action do
      {:return, result} -> result
      {:exit, reason} -> exit(reason)
      {:raise, message} -> raise message
    end
  end

  defp command(consumer, operation) do
    ref = make_ref()
    send(consumer, {:command, self(), ref, operation})
    assert_receive {^ref, assigns}, @timeout
    assigns
  end

  defp select(consumer, id), do: command(consumer, {:select, id, @old_node})

  defp expect_rpc(kind, target_node, id, consumer, worker) do
    # Match the NEXT RPC, not just an eventual matching call: any unexpected
    # unregister, target, concurrency or worker/consumer identity fails loudly.
    assert_receive {:rpc, actual_kind, actual_node, actual_id, actual_consumer, actual_worker,
                    ref},
                   @timeout

    assert {actual_kind, actual_node, actual_id, actual_consumer, actual_worker} ==
             {kind, target_node, id, consumer, worker}

    refute worker == consumer
    {worker, ref}
  end

  defp release(call, result), do: respond(call, {:return, result})
  defp respond({worker, ref}, action), do: send(worker, {ref, action})

  defp expect_ready(token) do
    assert_receive {:ready_applied, ^token, assigns}, @timeout
    assigns
  end

  # Stale ready/5 and worker reconciliation may both request safe cleanup of an
  # obsolete target. Accept those ONLY, and require at least one before watch.
  defp cleanup_until_watch(
         consumer,
         worker,
         old_id,
         new_id,
         old_node \\ @old_node,
         new_node \\ @old_node
       ) do
    release(expect_rpc(:unwatch, old_node, old_id, consumer, worker), :ok)
    await_next_watch(consumer, worker, old_id, new_id, old_node, new_node, 1)
  end

  defp await_next_watch(consumer, worker, old_id, new_id, old_node, new_node, remaining) do
    assert_receive {:rpc, kind, target_node, id, actual_consumer, actual_worker, ref}, @timeout
    assert {actual_consumer, actual_worker} == {consumer, worker}

    case kind do
      :unwatch ->
        assert remaining > 0
        assert {target_node, id} == {old_node, old_id}
        release({worker, ref}, :ok)
        await_next_watch(consumer, worker, old_id, new_id, old_node, new_node, remaining - 1)

      :watch ->
        assert {target_node, id} == {new_node, new_id}
        # Return the actual blocked call, never inject a worker command.
        {worker, ref}
    end
  end

  defp stop_and_await(consumer, worker) do
    consumer_monitor = Process.monitor(consumer)
    worker_monitor = Process.monitor(worker)
    send(consumer, :stop)
    assert_receive {:DOWN, ^consumer_monitor, :process, ^consumer, :normal}, @timeout
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, @timeout
  end

  defp snapshot(id, seq \\ 5), do: {:ok, %Snapshot{agent_id: id, seq: seq, phase: :running}, seq}
  defp unique_id, do: System.unique_integer([:positive]) + 100_000_000
end
