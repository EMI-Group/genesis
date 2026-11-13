defmodule EvoGit.Agent.Session.TerminalHandoffTest do
  @moduledoc """
  A watched inspector retains the authoritative terminal cut after its session exits.

  Direct repo-less sessions use real exchange completion/error/close paths, worker-local
  Sink callbacks and unique production-shaped StreamCase rows. Trace sessions scope
  call patterns to this test's session pid without changing VM-global trace patterns.
  """
  use EvoGit.Agent.StreamCase, async: true

  alias EvoGit.Agent.Session.Summary
  alias EvoGit.Agent.Stream.Activity

  @timeout 10_000

  test "finish flushes pending deltas before handing off the adopted final transcript", ctx do
    {session, ref, worker, initial} = start_parked(ctx)
    id = ctx.agent_id
    assert {:ok, %{state: state}} = Session.inspect(session)
    # An authenticated same-turn checkpoint is accepted before the final reply.
    # The engine's subsequent turn-1 checkpoint is consequently a duplicate;
    # only adoption of the actual finish outcome can supply the final answer.
    run(worker, fn -> send(session, {:checkpoint, self(), %{state | turn: 1}}) end)
    assert {:ok, attached, 0} = Stream.watch(id)
    assert attached.turn == 1
    assert attached.messages == initial.messages
    hold_flush(session)

    run(worker, fn ->
      Sink.start_turn(1)
      call = Sink.start_call(0)
      Sink.call_phase(call, :llm)
    end)

    capture(worker, "streamed fragment, not the final answer", "private partial thought")
    {:running, pending} = :sys.get_state(session)
    assert pending.event_seq == 0
    assert pending.batcher.events != []
    assert pending.activity.current_call.text == "streamed fragment, not the final answer"

    trace = trace_session(session)
    send(worker, {:reply, "authoritative final answer"})
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, @timeout
    messages = drain_mailbox()
    {snapshot, seq} = only_handoff(messages, id)

    assert_terminal(snapshot, id, :done, seq)
    assert snapshot.turn == 1
    assert snapshot.total_tokens == 120
    assert snapshot.usage.input_tokens == 100
    assert snapshot.usage.output_tokens == 20
    assert Enum.take(snapshot.messages, length(initial.messages)) == initial.messages
    assert length(snapshot.messages) == length(initial.messages) + 1
    assert List.last(snapshot.messages).role == :assistant
    assert text_of(List.last(snapshot.messages)) == "authoritative final answer"
    refute Enum.any?(snapshot.messages, &(text_of(&1) =~ "streamed fragment"))
    refute Enum.any?(snapshot.messages, &(text_of(&1) =~ "private partial thought"))

    deltas = for {:agent_delta, ^id, n, events} <- messages, do: {n, events}
    assert [{1, events}] = deltas
    assert seq == 1
    assert {:text, "streamed fragment, not the final answer"} in events
    assert {:thinking, "private partial thought"} in events
    assert {:finished, :completed} in events
    assert List.last(events) == {:activity, Activity.new()}

    assert index_of(messages, &match?({:agent_delta, ^id, _, _}, &1)) <
             index_of(messages, &match?({:agent_stream_closed, ^id, _, _}, &1))

    assert [{:ok, %Result{result: "authoritative final answer"}}] =
             for({:agent_session_result, ^id, ^session, result} <- messages, do: result)

    assert index_of(messages, &match?({:agent_stream_closed, ^id, _, _}, &1)) <
             index_of(messages, &match?({:agent_session_result, ^id, ^session, _}, &1))

    # Session-local tracing also pins the handoff BEFORE the final summary update,
    # rather than hoping this test wins a race to read the old ETS row.
    traces = finish_trace(trace, session, messages)
    closed_index = index_of(traces, &closed_send?(&1, session, id))

    final_summary_index =
      traces
      |> Enum.with_index()
      |> Enum.filter(fn {event, _} -> summary_call?(event, session, id) end)
      |> List.last()
      |> elem(1)

    assert closed_index < final_summary_index

    assert {:error, _} = Stream.snapshot(id)
    assert Session.history(session) == []
    refute Process.alive?(session)
    # Removal cannot invalidate the already delivered plain-data transcript.
    SchedStore.delete_agent_state(id)
    assert Summary.read(id) == nil
    assert text_of(List.last(snapshot.messages)) == "authoritative final answer"
    assert Enum.all?(deltas, fn {n, _} -> Stream.stale?(n, snapshot.seq) end)
  end

  test "error hands off the last accepted checkpoint, never partial current-call content", ctx do
    {session, ref, worker, _initial} = start_parked(ctx)
    id = ctx.agent_id
    assert {:ok, %{state: state}} = Session.inspect(session)

    accepted = %{
      state
      | turn: 2,
        total_tokens: 321,
        context:
          ReqLLM.Context.append(state.context, %ReqLLM.Message{
            role: :assistant,
            content: [ReqLLM.Message.ContentPart.text("accepted checkpoint")]
          })
    }

    run(worker, fn -> send(session, {:checkpoint, self(), accepted}) end)
    assert Session.history(session) == accepted.context.messages
    assert {:ok, _, 0} = Stream.watch(id)
    hold_flush(session)

    run(worker, fn ->
      Sink.start_turn(3)
      call = Sink.start_call(0)
      Sink.call_phase(call, :llm)
    end)

    capture(worker, "unaccepted text", "unaccepted thought")

    assert {:running, %{activity: %{current_call: %{text: "unaccepted text"}}}} =
             :sys.get_state(session)

    send(worker, {:reject, "terminal rejection sentinel"})
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, @timeout
    messages = drain_mailbox()
    {snapshot, seq} = only_handoff(messages, id)
    assert_terminal(snapshot, id, :failed, seq)
    assert snapshot.messages == accepted.context.messages
    assert snapshot.turn == accepted.turn
    assert snapshot.total_tokens == accepted.total_tokens
    assert snapshot.usage == accepted.usage
    assert seq == 1

    assert [{:error, {:llm_request_rejected, "terminal rejection sentinel"}}] =
             for({:agent_session_result, ^id, ^session, result} <- messages, do: result)

    assert [{1, events}] = for({:agent_delta, ^id, n, events} <- messages, do: {n, events})
    assert {:text, "unaccepted text"} in events
    assert {:thinking, "unaccepted thought"} in events
    assert {:finished, :failed} in events
    assert List.last(events) == {:activity, Activity.new()}
    assert {:error, _} = Stream.snapshot(id)
  end

  test "only registered watchers receive one direct handoff, including a non-subscriber", ctx do
    {session, ref, worker, _initial} = start_parked(ctx)
    id = ctx.agent_id
    assert {:ok, _, _} = Stream.watch(id)
    assert {:ok, _, _} = Stream.watch(id)
    direct = recipient()
    removed = recipient()
    subscriber = recipient()
    assert {:ok, _, _} = Stream.register_watcher(session, direct)
    assert {:ok, _, _} = Stream.register_watcher(session, direct)
    assert {:ok, _, _} = Stream.register_watcher(session, removed)
    assert :ok = Stream.unregister_watcher(session, removed)
    recipient_run(subscriber, fn -> Stream.subscribe(id) end)

    for recipient <- [direct, removed, subscriber] do
      recipient_run(recipient, fn ->
        Process.put(:session_monitor, Process.monitor(session))
        :ok
      end)
    end

    send(worker, {:reply, "recipient handoff"})
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, @timeout
    {snapshot, seq} = only_handoff(drain_mailbox(), id)
    assert_terminal(snapshot, id, :done, seq)
    # The relay's drain command comes from this test, NOT the session. Its own
    # session monitor is the FIFO barrier proving every session send arrived.
    assert [{:agent_stream_closed, ^id, ^snapshot, ^seq}] =
             recipient_messages(direct, session)

    assert recipient_messages(removed, session) == []
    subscriber_messages = recipient_messages(subscriber, session)
    assert Enum.any?(subscriber_messages, &match?({:agent_delta, ^id, _, _}, &1))
    refute Enum.any?(subscriber_messages, &match?({:agent_stream_closed, ^id, _, _}, &1))
  end

  test "explicit close hands off the yielded transcript through the finalizer path", ctx do
    {session, ref, worker, _initial} =
      start_parked(ctx, EvoGit.Agent.StreamCase.InteractiveAgent)

    id = ctx.agent_id
    assert {:ok, _, _} = Stream.watch(id)
    send(worker, {:reply, "last yielded answer"})
    assert_receive {:agent_session_yield, ^id, ^session, "last yielded answer"}, @timeout
    assert {:ok, idle, idle_seq} = Stream.snapshot(id)
    refute_received {:agent_stream_closed, ^id, _, _}
    assert :ok = Session.close(session)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, @timeout
    {snapshot, seq} = only_handoff(drain_mailbox(), id)
    assert_terminal(snapshot, id, :done, seq)
    assert snapshot.messages == idle.messages
    assert seq >= idle_seq
    assert text_of(List.last(snapshot.messages)) == "last yielded answer"
  end

  test "unwatched finalization allocates no snapshot and publishes no terminal stream", ctx do
    {session, ref, worker, _initial} = start_parked(ctx)
    id = ctx.agent_id
    trace = trace_session(session)

    # A positive control proves the function-call trace is actually installed.
    assert {:ok, _, _} = Stream.watch(id)
    assert :ok = Stream.unwatch(id)
    controls = trace_barrier(trace, session)
    assert Enum.any?(controls, &snapshot_call?(&1, session))
    assert :ok = Stream.subscribe(id)
    assert Session.watching?(session) == false
    capture(worker, "unwatched partial", "unwatched thought")
    send(worker, {:reply, "unwatched final answer"})
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, @timeout
    messages = drain_mailbox()
    traces = finish_trace(trace, session, messages)
    refute Enum.any?(traces, &snapshot_call?(&1, session))
    refute Enum.any?(messages, &match?({:agent_stream_closed, ^id, _, _}, &1))
    refute Enum.any?(messages, &match?({:agent_delta, ^id, _, _}, &1))

    assert [{:ok, %Result{result: "unwatched final answer"}}] =
             for({:agent_session_result, ^id, ^session, result} <- messages, do: result)
  end

  defp start_parked(ctx, role \\ EvoGit.Agent.StreamCase.OneshotAgent) do
    test_pid = self()

    llm =
      scripted_llm_call(fn context, _tools, _params, _id, _retries ->
        call = Sink.start_call(0)
        Sink.call_phase(call, :llm)
        barrier()
        send(test_pid, {:parked, self(), context})
        drive(context, test_pid)
      end)

    {:ok, session, ref} =
      start_session(dispatch_ctx(ctx.agent_id, ctx.tmp_dir, llm_call: llm, agent_module: role))

    on_exit(fn -> Session.cancel(session, :force) end)
    assert_receive {:parked, worker, context}, @timeout
    {session, ref, worker, context}
  end

  defp drive(context, test_pid) do
    receive do
      {:run, fun} ->
        fun.()
        barrier()
        send(test_pid, {:ran, self()})
        drive(context, test_pid)

      {:reply, text} ->
        {:implicit_completion, response(context, text), text}

      {:reject, reason} ->
        {:error, {:llm_request_rejected, reason}}
    end
  end

  defp barrier, do: assert(match?({:ok, _}, Session.inspect(Process.get(:evogit_stream_session))))

  defp run(worker, fun) do
    send(worker, {:run, fun})
    assert_receive {:ran, ^worker}, @timeout
  end

  defp capture(worker, text, thought) do
    run(worker, fn ->
      callbacks = Sink.stream_opts()
      callbacks[:on_result].(text)
      callbacks[:on_thinking].(thought)
    end)
  end

  defp hold_flush(session) do
    # A fake timer reference prevents any wall-clock flush before finalization.
    :sys.replace_state(session, fn {phase, data} ->
      assert data.batcher == Batcher.new()
      {phase, %{data | batcher: Batcher.set_timer(data.batcher, make_ref())}}
    end)
  end

  defp assert_terminal(snapshot, id, status, seq) do
    assert %Snapshot{} = snapshot
    assert snapshot.agent_id == id
    assert snapshot.phase == :done
    assert Map.fetch!(snapshot, :status) == status
    assert snapshot.seq == seq
    assert snapshot.activity == Activity.new()
  end

  defp only_handoff(messages, id) do
    assert [{snapshot, seq}] =
             for({:agent_stream_closed, ^id, snapshot, seq} <- messages, do: {snapshot, seq})

    {snapshot, seq}
  end

  defp index_of(messages, predicate) do
    index = Enum.find_index(messages, predicate)
    assert is_integer(index)
    index
  end

  defp drain_mailbox do
    receive do
      message -> [message | drain_mailbox()]
    after
      0 -> []
    end
  end

  defp recipient do
    pid = spawn_link(fn -> recipient_loop([]) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp recipient_loop(messages) do
    receive do
      {:run, caller, fun} ->
        result = fun.()
        send(caller, {:recipient_ran, self(), result})
        recipient_loop(messages)

      {:drain_after_exit, caller, session} ->
        ref = Process.get(:session_monitor)

        unless Process.get(:session_exited, false) do
          receive do
            {:DOWN, ^ref, :process, ^session, _} -> :ok
          end
        end

        send(caller, {:recipient_messages, self(), Enum.reverse(messages) ++ drain_mailbox()})
        recipient_loop([])

      {:DOWN, ref, :process, _session, _reason} ->
        assert ref == Process.get(:session_monitor)
        Process.put(:session_exited, true)
        recipient_loop(messages)

      message ->
        recipient_loop([message | messages])
    end
  end

  defp recipient_run(pid, fun) do
    send(pid, {:run, self(), fun})
    assert_receive {:recipient_ran, ^pid, :ok}, @timeout
  end

  defp recipient_messages(pid, session) do
    send(pid, {:drain_after_exit, self(), session})
    assert_receive {:recipient_messages, ^pid, messages}, @timeout
    messages
  end

  defp trace_session(session) do
    trace = :trace.session_create(__MODULE__, self(), [])
    on_exit(fn -> :trace.session_destroy(trace) end)
    :trace.function(trace, {Snapshot, :from, :_}, true, [:local])
    :trace.function(trace, {Summary, :publish, :_}, true, [:local])
    :trace.process(trace, session, true, [:call, :send])
    trace
  end

  defp trace_barrier(trace, session) do
    ref = :trace.delivered(trace, session)
    assert_receive {:trace_delivered, ^session, ^ref}, @timeout
    drain_mailbox()
  end

  defp finish_trace(trace, session, already_received) do
    already_received ++ trace_barrier(trace, session)
  end

  defp snapshot_call?({:trace, pid, :call, {Snapshot, :from, _}}, pid), do: true
  defp snapshot_call?(_, _), do: false
  defp summary_call?({:trace, pid, :call, {Summary, :publish, [id | _]}}, pid, id), do: true
  defp summary_call?(_, _, _), do: false
  defp closed_send?({:trace, pid, :send, {:agent_stream_closed, id, _, _}, _}, pid, id), do: true
  defp closed_send?(_, _, _), do: false
end
