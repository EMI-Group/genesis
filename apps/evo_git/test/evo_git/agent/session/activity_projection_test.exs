defmodule EvoGit.Agent.Session.ActivityProjectionTest do
  @moduledoc """
  Session-owned activity versus checkpointed conversation, using real repo-less
  sessions and the actual exchange worker's installed Sink (no provider or git).

  Every worker command ends with a same-sender Session.inspect barrier BEFORE its
  acknowledgement. Tests never infer session mailbox ordering from a worker-to-test
  notice. Workers park indefinitely until explicitly commanded or killed by cleanup.
  Unique StreamCase rows/topics and dispatch-local seams keep this suite async-safe.
  """
  use EvoGit.Agent.StreamCase, async: true

  alias EvoGit.Agent.Session.Summary
  alias EvoGit.Agent.Stream.Activity
  alias EvoGit.Agent.ToolBatch

  @deadline 30_000

  test "unwatched callbacks retain partial text/thinking without public buffer, timer or seq",
       fixture do
    {session, worker, context} = parked_session(fixture)
    agent_id = fixture.agent_id
    assert :ok = Stream.subscribe(agent_id)
    original_history = Session.history(session)
    original_summary = Summary.read(agent_id)
    assert original_history == context.messages

    {call_id, callbacks} = begin_call(worker, 1)

    run(worker, fn ->
      callbacks[:on_result].("partial ")
      callbacks[:on_thinking].("private reasoning")
      callbacks[:on_result].("answer")
      callbacks[:on_tool_call].(%{name: "declared_not_executed"})
      Sink.emit({:tool_call, "declared-id", "also_not_executed"})
    end)

    expected = activity(call_id, 1, "partial answer", "private reasoning")
    data = session_data(session)
    assert data.activity == expected
    assert data.watchers == %{}
    assert data.event_seq == 0
    assert data.batcher == Batcher.new()
    assert Session.history(session) == original_history
    assert Summary.read(agent_id) == original_summary
    # A synchronous barrier and an empty/no-timer batch prove absence, not a
    # timed quiet window. Subscribing alone must not open the publication gate.
    refute_received {:agent_delta, ^agent_id, _, _}

    assert {:ok, snapshot, 0} = Stream.watch(session)
    assert snapshot.activity == expected
    assert snapshot.messages == original_history
    assert snapshot.turn == 0
    assert snapshot.phase == :running
    assert snapshot.seq == 0
    assert Session.watching?(session)
    assert session_data(session).batcher == Batcher.new()
    refute_received {:agent_delta, ^agent_id, _, _}

    # The very SAME callbacks installed before watch now publish subsequent
    # chunks. Previously captured text belongs to the snapshot, not a replay.
    {:ok, next, 1} =
      pending_cut(worker, {:snapshot}, fn ->
        callbacks[:on_result].("!")
        callbacks[:on_thinking].("!")
      end)

    assert next.activity == activity(call_id, 1, "partial answer!", "private reasoning!")
    assert next.messages == original_history
    assert_receive {:agent_delta, ^agent_id, 1, events}, @deadline
    assert events == [{:text, "!"}, {:thinking, "!"}]
    assert Stream.stale?(1, next.seq)
  end

  test "watch and snapshot flush pending deltas into one consistent cut for seq-based dedup",
       fixture do
    {session, worker, _context} = parked_session(fixture)
    agent_id = fixture.agent_id
    {call_id, callbacks} = begin_call(worker, 1)
    assert {:ok, initial, 0} = Stream.watch(session)
    assert initial.activity == activity(call_id, 1, "", "")

    test_pid = self()

    # Queue emissions and the read while the session is suspended. The read is
    # already in its mailbox BEFORE any 75ms timer can be created, so it MUST
    # flush a pending batch, even if the host deschedules either process.
    {covered, seq} =
      Enum.reduce([{:watch, test_pid}, {:snapshot}], {initial, 0}, fn request,
                                                                      {previous, previous_seq} ->
        assert {:ok, cut, seq} =
                 pending_cut(worker, request, fn ->
                   callbacks[:on_result].("text")
                   callbacks[:on_thinking].("thought")
                 end)

        assert seq == previous_seq + 1
        assert cut.seq == seq
        assert cut.phase == :running
        assert cut.messages == previous.messages
        assert cut.turn == previous.turn
        assert cut.activity.current_call.text == previous.activity.current_call.text <> "text"

        assert cut.activity.current_call.thinking ==
                 previous.activity.current_call.thinking <> "thought"

        assert_receive {:agent_delta, ^agent_id, ^seq, events}, @deadline
        assert events == [{:text, "text"}, {:thinking, "thought"}]
        assert session_data(session).batcher == Batcher.new()

        # Consumer resync: a batch already covered by the snapshot cannot be
        # appended a second time, nor can any older batch.
        for old_seq <- 0..seq, do: assert(Stream.stale?(old_seq, cut.seq))
        assert apply_batch(cut.activity, seq, events, cut.seq) == cut.activity
        {cut, seq}
      end)

    assert {:ok, later, later_seq} =
             pending_cut(worker, {:snapshot}, fn -> callbacks[:on_result].(" fresh") end)

    assert later_seq == seq + 1
    assert_receive {:agent_delta, ^agent_id, ^later_seq, fresh_events}, @deadline
    refute Stream.stale?(later_seq, covered.seq)
    assert apply_batch(covered.activity, later_seq, fresh_events, covered.seq) == later.activity
    assert later.activity.current_call.id == call_id
    assert later.activity.current_call.text == "texttext fresh"
    assert later.messages == initial.messages
  end

  for {call_turn, preserved?} <- [{1, false}, {2, true}, {3, true}] do
    @call_turn call_turn
    @preserved preserved?
    test "advancing checkpoint turn 2 #{if preserved?, do: "preserves", else: "retires"} call at turn #{call_turn}",
         fixture do
      {session, worker, _context} = parked_session(fixture)
      {call_id, callbacks} = begin_call(worker, @call_turn)

      run(worker, fn ->
        callbacks[:on_result].("in flight")
        callbacks[:on_thinking].("still thinking")
      end)

      assert {:ok, _, 0} = Stream.watch(session)
      {:ok, _, seq} = pending_cut(worker, {:snapshot}, fn -> callbacks[:on_result].("!") end)
      assert seq == 1
      before = session_data(session)
      summary_before = Summary.read(fixture.agent_id)
      checkpoint = checkpoint(before.state, 2, "committed turn two")

      # Poison the WORKER COPY of the session-owned fields. The adopted state
      # must use the live monitored watchers and sequence, never these values.
      checkpoint = %{checkpoint | watchers: %{}, event_seq: 98_765, phase: :awaiting_input}
      run(worker, fn -> send(session, {:checkpoint, self(), checkpoint}) end)
      assert {:ok, snapshot, snapshot_seq} = Stream.snapshot(session)
      adopted = session_data(session)
      assert adopted.state.turn == 2
      assert adopted.state.context == checkpoint.context
      assert adopted.state.total_tokens == checkpoint.total_tokens
      assert adopted.state.watchers == before.watchers
      assert adopted.state.event_seq == seq
      assert adopted.watchers == before.watchers
      assert adopted.event_seq == snapshot_seq
      assert is_reference(Map.fetch!(adopted.watchers, self()))
      assert Session.watching?(session)
      assert Session.history(session) == checkpoint.context.messages

      assert snapshot.phase == :running
      assert snapshot.turn == 2
      assert snapshot.messages == checkpoint.context.messages

      if @preserved do
        assert snapshot.activity == activity(call_id, @call_turn, "in flight!", "still thinking")
        assert snapshot_seq == seq
      else
        assert snapshot.activity == Activity.new()
        assert snapshot_seq == seq + 1
        agent_id = fixture.agent_id

        assert_receive {:agent_delta, ^agent_id, ^snapshot_seq, [{:activity, projection}]},
                       @deadline

        assert projection == Activity.new()
      end

      assert %AgentState{} = summary = Summary.read(fixture.agent_id)
      assert %AgentState{} = previous_summary = summary_before
      assert summary.turn == 2
      assert summary.total_tokens == checkpoint.total_tokens
      assert summary.message_count == length(checkpoint.context.messages)
      assert summary != previous_summary
      refute Map.has_key?(summary, :activity)
      refute Map.has_key?(summary, :context)
    end
  end

  test "adopting a batch-start checkpoint marks the retained live call checkpointed and announces it",
       fixture do
    {session, worker, _context} = parked_session(fixture)
    agent_id = fixture.agent_id
    {call_id, callbacks} = begin_call(worker, 1)
    assert {:ok, _, 0} = Stream.watch(session)
    # The batch-start boundary is the FIRST adoption that carries the assistant
    # message this live call describes — the duplication precondition.
    assert {:ok, live, 1} =
             pending_cut(worker, {:snapshot}, fn -> callbacks[:on_result].("in flight") end)

    assert_receive {:agent_delta, ^agent_id, 1, [{:text, "in flight"}]}, @deadline
    assert live.activity == activity(call_id, 1, "in flight", "")
    refute live.activity.current_call.checkpointed
    batch = marker_batch(1)
    checkpoint = batch_checkpoint(session_data(session).state, 1, "tool-calling turn", batch)
    run(worker, fn -> send(session, {:checkpoint, self(), checkpoint}) end)
    # The flip rides the ORDINARY activity path: exactly ONE public replacement.
    assert_receive {:agent_delta, ^agent_id, 2, [{:activity, projection}]}, @deadline
    assert projection.phase == :llm
    assert projection.current_call.id == call_id
    assert projection.current_call.text == "in flight"
    assert projection.current_call.checkpointed

    assert {:ok, during, 2} = Stream.snapshot(session)
    assert during.activity == projection
    assert during.messages == checkpoint.context.messages
    assert Enum.any?(during.messages, &(text_of(&1) == "tool-calling turn"))
    data = session_data(session)
    assert data.state.turn == 1
    assert data.state.pending_tool_batch == batch
    assert data.activity == projection
    refute_received {:agent_delta, ^agent_id, _, _}
  end

  test "re-adopting a batch-start checkpoint emits no second marker and the marker never outlives its call",
       fixture do
    {session, worker, _context} = parked_session(fixture)
    agent_id = fixture.agent_id
    {call_id, callbacks} = begin_call(worker, 1)
    assert {:ok, _, 0} = Stream.watch(session)
    {:ok, _, 1} = pending_cut(worker, {:snapshot}, fn -> callbacks[:on_result].("in flight") end)
    assert_receive {:agent_delta, ^agent_id, 1, [{:text, "in flight"}]}, @deadline
    first = batch_checkpoint(session_data(session).state, 1, "tool-calling turn", marker_batch(1))
    run(worker, fn -> send(session, {:checkpoint, self(), first}) end)
    assert_receive {:agent_delta, ^agent_id, 2, [{:activity, marked}]}, @deadline
    assert marked.current_call.id == call_id
    assert marked.current_call.checkpointed
    # A duplicate of that SAME boundary is not adoptable at all: no state, no
    # projection and no sequence change.
    data_before = session_data(session)
    run(worker, fn -> send(session, {:checkpoint, self(), first}) end)
    assert session_data(session) == data_before
    # Closing the batch (marker CLEARED, same turn, transcript grown) IS adoptable
    # and keeps the live call — and because the incoming marker is gone there is
    # no new `{:activity, _}` replacement.
    closing = %{checkpoint(data_before.state, 1, "tool results turn") | pending_tool_batch: nil}
    run(worker, fn -> send(session, {:checkpoint, self(), closing}) end)
    closed = session_data(session)
    assert closed.state.pending_tool_batch == nil
    assert closed.state.turn == 1
    assert closed.activity == marked
    assert closed.event_seq == 2
    refute_received {:agent_delta, ^agent_id, _, _}
    # An ADVANCING batch-start adoption retains the call, but re-marking an
    # ALREADY marked call is an idempotent no-op: nothing is published.
    second = batch_checkpoint(closed.state, 2, "next tool turn", marker_batch(2))
    run(worker, fn -> send(session, {:checkpoint, self(), second}) end)
    adopted = session_data(session)
    assert adopted.state.turn == 2
    assert adopted.activity == marked
    assert adopted.event_seq == 2
    refute_received {:agent_delta, ^agent_id, _, _}
    # The marker never outlives its call: the next turn's fresh call is
    # uncheckpointed by definition.
    {next_id, _callbacks} = begin_call(worker, 3)
    assert {:ok, fresh, _seq} = Stream.snapshot(session)
    assert fresh.activity.current_call.id == next_id
    refute next_id == call_id
    refute fresh.activity.current_call.checkpointed
    assert Session.watching?(session)
  end

  test "duplicate, older and identity-free checkpoints change neither projection, transcript nor summary",
       fixture do
    {session, worker, _context} = parked_session(fixture)
    {_id, callbacks} = begin_call(worker, 3)
    assert {:ok, _, 0} = Stream.watch(session)
    {:ok, _, _seq} = pending_cut(worker, {:snapshot}, fn -> callbacks[:on_result].("live") end)
    base = session_data(session).state
    accepted = checkpoint(base, 2, "accepted boundary")
    run(worker, fn -> send(session, {:checkpoint, self(), accepted}) end)
    assert {:ok, baseline, seq} = Stream.snapshot(session)
    data_before = session_data(session)
    summary_before = Summary.read(fixture.agent_id)
    agent_id = fixture.agent_id

    for kind <- [:duplicate, :older, :identity_free] do
      invalid = checkpoint(base, if(kind == :duplicate, do: 2, else: 1), "REJECT #{kind}")
      invalid = %{invalid | watchers: %{}, event_seq: seq + 100, total_tokens: 99_999}

      run(worker, fn ->
        message =
          if kind == :identity_free,
            do: {:checkpoint, %{invalid | turn: 50}},
            else: {:checkpoint, self(), invalid}

        send(session, message)
      end)

      assert session_data(session) == data_before
      assert Summary.read(agent_id) == summary_before
      assert {:ok, ^baseline, ^seq} = Stream.snapshot(session)
      assert Session.history(session) == accepted.context.messages
    end
  end

  test "resumed session rejects actual previous-worker callbacks, activity and advancing checkpoints",
       fixture do
    {session, first_worker, _context} = parked_session(fixture)
    {_old_call_id, old_callbacks} = begin_call(first_worker, 1)
    assert {:ok, _, 0} = Stream.watch(session)
    first_ref = Process.monitor(first_worker)
    send(first_worker, {:reply, "exact first yield"})
    agent_id = fixture.agent_id
    assert_receive {:agent_session_yield, ^agent_id, ^session, "exact first yield"}, @deadline
    assert_receive {:DOWN, ^first_ref, :process, ^first_worker, :normal}, @deadline
    assert {:ok, %{phase: :awaiting_input}} = Session.inspect(session)
    assert :ok = Session.start_input(session, "resume explicitly")
    assert_receive {:projection_worker, worker, resumed_context}, @deadline
    refute worker == first_worker
    {call_id, callbacks} = begin_call(worker, 2)
    {:ok, _, _} = pending_cut(worker, {:snapshot}, fn -> callbacks[:on_result].("new worker") end)
    assert {:ok, baseline, seq} = Stream.snapshot(session)
    data_before = session_data(session)
    summary_before = Summary.read(agent_id)

    # The old callback closes over the genuine previous worker, despite being
    # INVOKED in the current worker. Also send a matching current call id with
    # the stale worker, isolating worker authentication from call-id filtering.
    run(worker, fn ->
      old_callbacks[:on_result].("STALE callback")
      old_callbacks[:on_thinking].("STALE thinking")
      send(session, {:activity, first_worker, {:chunk, call_id, :text, "STALE matching id"}})
      send(session, {:activity, first_worker, {:start_call, "STALE", 500, 1}})
      send(session, {:activity, first_worker, :reset})

      send(
        session,
        {:checkpoint, first_worker, checkpoint(data_before.state, 500, "STALE transcript")}
      )
    end)

    assert session_data(session) == data_before
    assert Summary.read(agent_id) == summary_before
    assert {:ok, ^baseline, ^seq} = Stream.snapshot(session)
    assert baseline.activity == activity(call_id, 2, "new worker", "")
    assert Enum.any?(baseline.messages, &(text_of(&1) == "exact first yield"))
    # The pre-LLM safety boundary retains drained input immediately, so stopping
    # the current reply cannot erase a user message before its first completed turn.
    assert Enum.any?(resumed_context.messages, &(text_of(&1) == "resume explicitly"))
    assert Enum.any?(baseline.messages, &(text_of(&1) == "resume explicitly"))
    assert Session.watching?(session)
  end

  # These helpers stay local: unlike StreamCase's legacy emit driver they use
  # real Sink callbacks, authenticate the actual worker and never auto-release.
  defp parked_session(%{agent_id: agent_id, tmp_dir: tmp_dir}) do
    test_pid = self()

    llm =
      scripted_llm_call(fn context, _tools, _params, _agent_id, _retries ->
        session = Process.get(:evogit_stream_session)
        assert is_pid(session)
        assert Sink.installed?()
        assert {:ok, _} = Session.inspect(session, @deadline)
        send(test_pid, {:projection_worker, self(), context})
        drive(test_pid, session, context)
      end)

    {:ok, session, _ref} = start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: llm))
    on_exit(fn -> Session.cancel(session, :force) end)
    assert_receive {:projection_worker, worker, context}, @deadline
    assert session_data(session).worker.pid == worker
    {session, worker, context}
  end

  defp drive(test_pid, session, context) do
    receive do
      {:projection_command, ref, fun} ->
        result = fun.()
        assert {:ok, _} = Session.inspect(session, @deadline)
        send(test_pid, {:projection_ack, ref, result})
        drive(test_pid, session, context)

      {:reply, text} ->
        {:implicit_completion, response(context, text), text}
    end
  end

  defp run(worker, fun) do
    ref = make_ref()
    send(worker, {:projection_command, ref, fun})
    assert_receive {:projection_ack, ^ref, result}, @deadline
    result
  end

  defp begin_call(worker, turn) do
    run(worker, fn ->
      Sink.start_turn(turn)
      id = Sink.start_call(1)
      Sink.call_phase(id, :llm)
      callbacks = Sink.stream_opts()

      assert Enum.sort(Keyword.keys(callbacks)) == [
               :on_chunk,
               :on_result,
               :on_thinking,
               :on_tool_call
             ]

      {id, callbacks}
    end)
  end

  defp pending_cut(worker, request, emit) do
    run(worker, fn ->
      session = Process.get(:evogit_stream_session)
      :ok = :sys.suspend(session)

      request_id =
        try do
          emit.()
          :gen_statem.send_request(session, request)
        after
          :ok = :sys.resume(session)
        end

      assert {:reply, reply} = :gen_statem.wait_response(request_id, @deadline)
      reply
    end)
  end

  defp session_data(session) do
    {_phase, data} = :sys.get_state(session)
    data
  end

  defp checkpoint(state, turn, text) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      metadata: %{turn: turn}
    }

    %{
      state
      | turn: turn,
        total_tokens: turn * 123,
        context: ReqLLM.Context.append(state.context, message)
    }
  end

  # A real tool-batch marker for `turn`: `pending_tool_batch != nil` is exactly
  # the state a batch-START checkpoint carries.
  defp marker_batch(turn) do
    ToolBatch.build([%{id: "batch-call-#{turn}", name: "read"}], turn, [])
  end

  # The batch-START boundary: the assistant message the live call describes is
  # ALREADY in this transcript, which is why the call is marked checkpointed.
  defp batch_checkpoint(state, turn, text, batch) do
    %{checkpoint(state, turn, text) | pending_tool_batch: batch}
  end

  defp activity(id, turn, text, thinking) do
    %{
      phase: :llm,
      current_call: %{
        id: id,
        turn: turn,
        attempt: 1,
        text: text,
        thinking: thinking,
        checkpointed: false
      }
    }
  end

  defp apply_batch(activity, seq, events, snapshot_seq) do
    if Stream.stale?(seq, snapshot_seq) do
      activity
    else
      Enum.reduce(events, activity, fn
        {:activity, replacement}, _acc ->
          replacement

        {kind, text}, acc when kind in [:text, :thinking] ->
          update_in(acc, [:current_call, kind], &(&1 <> text))
      end)
    end
  end
end
