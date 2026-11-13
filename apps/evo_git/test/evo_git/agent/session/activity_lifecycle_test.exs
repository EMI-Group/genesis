defmodule EvoGit.Agent.Session.ActivityLifecycleTest do
  @moduledoc """
  Session-owned activity across terminal, cancellation and interactive boundaries.

  Every session, scheduler row and topic is test-local through StreamCase's
  unique agent identity; no provider, network or app-env seam is involved.
  The LLM seam invokes the real worker-installed Sink callbacks, not fabricated
  activity messages (except explicitly adversarial stale-worker traffic).
  """
  use EvoGit.Agent.StreamCase, async: true

  @timeout 10_000
  @idle %{phase: :idle, current_call: nil}

  test "LLM rejection retires captured activity and flushes the terminal reset", ctx do
    {pid, ref, worker, call, _context, _callbacks} = start_activity(ctx)
    worker_ref = Process.monitor(worker)
    watch_and_hold_flush(ctx.agent_id, pid)
    capture(worker, "unfinished", "private thought")
    assert_live(pid, call, "unfinished", "private thought")

    send(worker, {:reject, "invalid request sentinel"})
    id = ctx.agent_id

    assert_receive {:agent_session_result, ^id, ^pid,
                    {:error, {:llm_request_rejected, "invalid request sentinel"}}},
                   @timeout

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @timeout
    events = drain_events(id)
    assert {:text, "unfinished"} in events
    assert {:thinking, "private thought"} in events
    assert {:finished, :failed} in events
    assert List.last(events) == {:activity, @idle}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, @timeout
  end

  test "current-worker death retires activity and flushes reset without a result", ctx do
    {pid, ref, worker, call, _context, _callbacks} = start_activity(ctx)
    watch_and_hold_flush(ctx.agent_id, pid)
    capture(worker, "abandoned", "")
    assert_live(pid, call, "abandoned", "")

    # :shutdown is a real monitored worker death, not an exchange outcome; it
    # takes the non-crashing DOWN arm without noisy OTP crash diagnostics.
    Process.exit(worker, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @timeout
    assert_reset_flushed(ctx.agent_id, "abandoned")
    refute_received {:agent_session_result, _, ^pid, _}
  end

  test "force cancellation kills the live worker and flushes reset without a result", ctx do
    {pid, ref, worker, call, _context, _callbacks} = start_activity(ctx)
    worker_ref = Process.monitor(worker)
    watch_and_hold_flush(ctx.agent_id, pid)
    capture(worker, "force-discarded", "")
    assert_live(pid, call, "force-discarded", "")

    assert :ok = Session.cancel(pid, :force)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, @timeout
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @timeout
    assert_reset_flushed(ctx.agent_id, "force-discarded")
    refute_received {:agent_session_result, _, ^pid, _}
  end

  test "running graceful cancellation preserves worker, activity and the pending batch", ctx do
    {pid, _ref, worker, call, _context, _callbacks} = start_activity(ctx)
    watch_and_hold_flush(ctx.agent_id, pid)
    capture(worker, "still generating", "still thinking")
    {:running, before} = :sys.get_state(pid)
    assert before.activity.current_call.id == call
    assert before.batcher.events != []

    assert :ok = Session.cancel(pid, :graceful)
    assert :ok = Session.cancel(pid, :graceful)
    {:cancelling, after_cancel} = :sys.get_state(pid)
    assert Process.alive?(worker)
    assert after_cancel.worker == before.worker
    assert after_cancel.activity == before.activity
    assert after_cancel.batcher == before.batcher
    assert after_cancel.event_seq == before.event_seq
    assert SchedStore.cancel_requested?(ctx.agent_id)
    refute_received {:agent_delta, _, _, _}
    refute_received {:agent_session_result, _, ^pid, _}

    # Callbacks remain live while cancelling, not just a preserved old snapshot.
    capture(worker, " + continuation", "")
    assert {:ok, snapshot, _seq} = Stream.snapshot(ctx.agent_id)
    assert snapshot.phase == :cancelling
    assert snapshot.activity.current_call.id == call
    assert snapshot.activity.current_call.text == "still generating + continuation"
    events = drain_events(ctx.agent_id)
    refute {:activity, @idle} in events
    assert :ok = Session.cancel(pid, :force)
  end

  test "yield idles cleanly and resumes on the same session with fresh worker and call", ctx do
    {pid, _ref, worker, first_call, first_context, old_callbacks} = start_activity(ctx)
    worker_ref = Process.monitor(worker)
    assert {:ok, _, initial_seq} = Stream.watch(ctx.agent_id)
    capture(worker, "first partial", "first thought")
    assert {:ok, running, seq} = Stream.snapshot(ctx.agent_id)
    assert seq > initial_seq
    assert running.activity.current_call.id == first_call
    assert {:ok, %{state: initial_state}} = Session.inspect(pid)
    cache_key = initial_state.prompt_cache_key
    assert is_binary(cache_key)

    send(worker, {:reply, "first exact reply"})
    id = ctx.agent_id
    assert_receive {:agent_session_yield, ^id, ^pid, "first exact reply"}, @timeout
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, @timeout
    assert {:ok, idle, idle_seq} = Stream.snapshot(id)
    assert idle.phase == :awaiting_input
    assert idle.activity == @idle
    assert idle_seq > seq
    assert Enum.take(idle.messages, length(first_context.messages)) == first_context.messages
    assert text_of(List.last(idle.messages)) == "first exact reply"
    assert Session.history(pid) == idle.messages
    {:awaiting_input, idle_data} = :sys.get_state(pid)
    assert idle_data.worker == nil
    assert idle_data.batcher == Batcher.new()
    assert {:yield, "first exact reply"} in drain_events(id)
    refute_received {:agent_session_result, ^id, ^pid, _}

    assert :ok = Session.start_input(pid, "resume exact input", :queue)
    assert_receive {:agent_session_resumed, ^id, ^pid}, @timeout
    assert_receive {:activity_call, next_worker, next_call, next_context, _callbacks}, @timeout
    refute next_worker == worker
    refute next_call == first_call
    assert Enum.take(next_context.messages, length(idle.messages)) == idle.messages
    assert Enum.count(next_context.messages, &(text_of(&1) == "resume exact input")) == 1
    assert {:ok, %{state: resumed}} = Session.inspect(pid)
    assert resumed.prompt_cache_key == cache_key
    assert Session.whereis(id) == {:ok, pid}
    assert {:ok, fresh, fresh_seq} = Stream.snapshot(id)
    assert fresh_seq > idle_seq
    assert fresh.phase == :running
    assert fresh.activity.current_call.id == next_call
    assert fresh.activity.current_call.text == ""
    assert fresh.activity.current_call.thinking == ""

    # Late callback closures retain the OLD worker and call identity. Neither
    # those nor explicit old-worker starts may replace the resumed activity.
    old_callbacks[:on_result].("late old text")
    old_callbacks[:on_thinking].("late old thought")
    send(pid, {:activity, worker, {:start_call, "forged-old-call", 999, 0}})
    send(pid, {:exchange_finished, worker, {:error, :stale_outcome}})
    assert {:ok, unchanged, unchanged_seq} = Stream.snapshot(id)
    assert unchanged.activity == fresh.activity
    assert unchanged.messages == fresh.messages
    assert unchanged_seq == fresh_seq

    send(next_worker, {:reply, "second exact reply"})
    assert_receive {:agent_session_yield, ^id, ^pid, "second exact reply"}, @timeout
    assert {:ok, second_idle, second_seq} = Stream.snapshot(id)
    assert second_idle.activity == @idle
    assert second_idle.phase == :awaiting_input
    assert second_seq > fresh_seq
    assert text_of(List.last(second_idle.messages)) == "second exact reply"
    assert pending_messages(id) == []
  end

  test "unwatched genuine chunk callback interrupts once and the next call excludes partial text",
       ctx do
    {pid, _ref, worker, first_call, first_context, _callbacks} = start_activity(ctx)
    capture(worker, "must not become an assistant message", "discard this thought")
    assert Session.watching?(pid) == false
    assert {:ok, partial, 0} = Stream.snapshot(ctx.agent_id)
    assert partial.activity.current_call.id == first_call
    assert partial.activity.current_call.text == "must not become an assistant message"

    assert :ok = Session.start_input(pid, "interrupt exact input", :interrupt)
    assert pending_messages(ctx.agent_id) == ["interrupt exact input"]
    send(worker, :consume_chunk)
    assert_receive {:chunk_interrupted, ^worker, %Interrupted{}, false}, @timeout
    assert_receive {:activity_call, ^worker, next_call, next_context, _callbacks}, @timeout
    refute next_call == first_call

    assert Enum.take(next_context.messages, length(first_context.messages)) ==
             first_context.messages

    assert Enum.count(next_context.messages, &(text_of(&1) == "interrupt exact input")) == 1
    refute Enum.any?(next_context.messages, &(&1.role == :assistant))
    assert pending_messages(ctx.agent_id) == []
    assert {:ok, next, 0} = Stream.snapshot(ctx.agent_id)
    assert next.activity.current_call.id == next_call
    assert next.activity.current_call.text == ""
    assert next.activity.current_call.thinking == ""
    assert {:ok, %{state: state}} = Session.inspect(pid)
    refute state.in_grace_period
    assert state.grace_turns_remaining == 0
    assert Session.watching?(pid) == false

    send(worker, {:reply, "after genuine callback interrupt"})
    id = ctx.agent_id
    assert_receive {:agent_session_yield, ^id, ^pid, "after genuine callback interrupt"}, @timeout
    history = Session.history(pid)
    assert Enum.count(history, &(&1.role == :assistant)) == 1
    assert Enum.count(history, &(text_of(&1) == "interrupt exact input")) == 1
    refute Enum.any?(history, &(text_of(&1) =~ "must not become an assistant message"))
    assert {:ok, idle, 0} = Stream.snapshot(id)
    assert idle.activity == @idle
    refute_received {:agent_delta, ^id, _, _}
  end

  test "streamed nil-id tool declaration stays LLM activity until tool execution starts", ctx do
    test_pid = self()

    tool_batch = fn indexed_calls, _state ->
      barrier()
      send(test_pid, {:tool_batch_started, self(), indexed_calls})

      receive do
        :finish_tools ->
          Enum.map(indexed_calls, fn {call, index} ->
            {index, call.id, ReqLLM.ToolCall.name(call), "tool output sentinel"}
          end)
      end
    end

    {pid, _ref, worker, call, _context, _callbacks} = start_activity(ctx, tool_batch: tool_batch)
    assert {:ok, _, _} = Stream.watch(ctx.agent_id)
    send(worker, :declare_tool)
    assert_receive {:tool_declared, ^worker}, @timeout
    assert {:ok, declared, _} = Stream.snapshot(ctx.agent_id)
    assert declared.activity.phase == :llm
    assert declared.activity.current_call.id == call
    assert {:tool_call, nil, "read"} in drain_events(ctx.agent_id)

    send(worker, :return_tools)
    assert_receive {:tool_batch_started, ^worker, [{tool_call, 0}]}, @timeout
    assert tool_call.id == "activity-tool-id"
    assert {:ok, executing, _} = Stream.snapshot(ctx.agent_id)
    assert executing.activity.phase == :tools
    assert executing.activity.current_call.id == call

    send(worker, :finish_tools)
    assert_receive {:activity_call, ^worker, next_call, next_context, _callbacks}, @timeout
    refute next_call == call

    assert Enum.any?(
             next_context.messages,
             &(&1.role == :tool and text_of(&1) == "tool output sentinel")
           )

    assert {:ok, next, _} = Stream.snapshot(ctx.agent_id)
    assert next.activity.phase == :llm
    assert next.activity.current_call.id == next_call
    send(worker, {:reply, "tools done"})
    id = ctx.agent_id
    assert_receive {:agent_session_yield, ^id, ^pid, "tools done"}, @timeout
  end

  defp start_activity(ctx, opts \\ []) do
    test_pid = self()

    llm_call =
      scripted_llm_call(fn context, _tools, _params, _id, _retries ->
        call = Sink.start_call(0)
        Sink.call_phase(call, :llm)
        callbacks = Sink.stream_opts()
        barrier()
        send(test_pid, {:activity_call, self(), call, context, callbacks})
        drive_call(context, callbacks, test_pid)
      end)

    {:ok, pid, ref} =
      start_session(dispatch_ctx(ctx.agent_id, ctx.tmp_dir, [llm_call: llm_call] ++ opts))

    # StreamCase's last-resort teardown kills the session. Force-cancel first
    # so its monitored parked worker is also reaped, even after an assertion fails.
    on_exit(fn ->
      cleanup_ref = Process.monitor(pid)
      Session.cancel(pid, :force)
      assert_receive {:DOWN, ^cleanup_ref, :process, ^pid, _reason}, @timeout
    end)

    assert_receive {:activity_call, worker, call, context, callbacks}, @timeout
    {pid, ref, worker, call, context, callbacks}
  end

  defp drive_call(context, callbacks, test_pid) do
    receive do
      {:capture, text, thinking} ->
        callbacks[:on_result].(text)
        callbacks[:on_thinking].(thinking)
        barrier()
        send(test_pid, {:captured, self()})
        drive_call(context, callbacks, test_pid)

      {:reject, reason} ->
        {:error, {:llm_request_rejected, reason}}

      {:reply, text} ->
        {:implicit_completion, response(context, text), text}

      :consume_chunk ->
        # This is the genuine installed callback. Only the provider wrapper's
        # error translation is reproduced; never peek instead of invoking it.
        try do
          callbacks[:on_chunk].(%{type: :text, text: "next chunk"})
          flunk("the installed callback did not interrupt")
        rescue
          interrupted in Interrupted ->
            send(test_pid, {:chunk_interrupted, self(), interrupted, Sink.interrupt_requested?()})
            {:interrupted, interrupted}
        end

      :declare_tool ->
        callbacks[:on_tool_call].(%{name: "read"})
        barrier()
        send(test_pid, {:tool_declared, self()})
        drive_call(context, callbacks, test_pid)

      :return_tools ->
        call = ReqLLM.ToolCall.new("activity-tool-id", "read", %{file_path: "unused"})
        message = %ReqLLM.Message{role: :assistant, content: [], tool_calls: [call]}
        reply = response(context, "")
        {:ok, %{reply | message: message, context: ReqLLM.Context.append(context, message)}}
    end
  end

  # Same-sender FIFO: the session has reduced this worker's preceding activity
  # before its inspect reply; a worker->test notice alone cannot guarantee that.
  defp barrier do
    assert {:ok, _} = Session.inspect(Process.get(:evogit_stream_session))
  end

  defp capture(worker, text, thinking) do
    send(worker, {:capture, text, thinking})
    assert_receive {:captured, ^worker}, @timeout
  end

  defp assert_live(pid, call, text, thinking) do
    {_phase, data} = :sys.get_state(pid)
    assert data.activity.phase == :llm
    assert data.activity.current_call.id == call
    assert data.activity.current_call.text == text
    assert data.activity.current_call.thinking == thinking
  end

  defp watch_and_hold_flush(id, pid) do
    assert {:ok, _, _} = Stream.watch(id)
    drain_events(id)

    # A private session's timer reference is pinned before any new events arrive.
    # No timer actually exists: pending events cannot race the 75ms flush under
    # host load. Terminal reset/flush and snapshot still use the real batcher.
    # This tests cancellation's buffer preservation, not timer scheduling.
    :sys.replace_state(pid, fn {phase, data} ->
      assert data.batcher == Batcher.new()
      {phase, %{data | batcher: Batcher.set_timer(data.batcher, make_ref())}}
    end)
  end

  defp assert_reset_flushed(id, text) do
    events = drain_events(id)
    assert {:text, text} in events
    assert List.last(events) == {:activity, @idle}
  end

  # Call only after a synchronous flush or the session's DOWN. PubSub delivery
  # precedes those replies/signals; there is no quiet window or sleep here.
  defp drain_events(id) do
    receive do
      {:agent_delta, ^id, _seq, events} -> events ++ drain_events(id)
    after
      0 -> []
    end
  end
end
