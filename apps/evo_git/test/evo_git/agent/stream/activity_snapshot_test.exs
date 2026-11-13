defmodule EvoGit.Agent.Stream.ActivitySnapshotTest do
  @moduledoc """
  Pending-batch consistent cuts through real session watch/snapshot commands.

  The session is suspended while its current worker invokes the installed Sink
  callbacks and queues an actual gen_statem request from that SAME worker.
  Those messages are already FIFO-ordered before resume: the 75 ms timer cannot
  overtake the request, even if the test process is descheduled for a long time.
  This exercises capture and snapshot flushing, not provider retry/nudge wiring.

  StreamCase supplies unique agent rows/topics and a parked repo-less worker;
  no global configuration, scheduler mutation or network request is involved.
  """

  use EvoGit.Agent.StreamCase, async: true

  for command <- [:snapshot, :watch] do
    @command command

    test "#{command} flushes a genuinely pending batch before replying with activity and seq",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      test_pid = self()

      llm_call =
        scripted_llm_call(fn _context, _tools, _params, _agent_id, _retries ->
          session = Process.get(:evogit_stream_session)
          # Settle any turn-start reset from this worker before the test watches.
          baseline = Stream.snapshot(session)
          send(test_pid, {:callback_worker, self(), baseline})
          callback_driver(session, test_pid, nil)
        end)

      {:ok, pid, _ref} = start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: llm_call))
      assert_receive {:callback_worker, worker, {:ok, %Snapshot{seq: 0}, 0}}, 5_000

      assert {:ok, %Snapshot{activity: %{phase: :idle, current_call: nil}}, 0} =
               Stream.watch(pid)

      assert {:ok, first, 1} =
               pending_cut(pid, worker, @command, text: "hel", thinking: "rea", text: "lo")

      call_id = first.activity.current_call.id
      assert is_binary(call_id)
      assert first.activity == activity(call_id, "hello", "rea")
      assert first.phase == :running
      assert first.seq == 1
      # Live activity must not be confused with the last checkpointed transcript.
      assert first.turn == 0
      assert Enum.map(first.messages, & &1.role) == [:system, :user]

      waiting = %{activity(call_id, "", "") | phase: :llm_waiting}

      batch1 =
        assert_batch(agent_id, 1, [
          {:activity, waiting},
          {:activity, activity(call_id, "", "")},
          {:text, "hel"},
          {:thinking, "rea"},
          {:text, "lo"}
        ])

      assert_drained(pid, 1)

      # Re-watch with a new pending batch, not just an already settled snapshot.
      assert {:ok, second, 2} =
               pending_cut(pid, worker, :watch, thinking: "son", text: "!")

      assert second.activity == activity(call_id, "hello!", "reason")
      assert second.seq == 2
      assert second.phase == :running
      assert second.messages == first.messages
      batch2 = assert_batch(agent_id, 2, [{:thinking, "son"}, {:text, "!"}])
      assert_drained(pid, 2)

      # The public facade also re-subscribes idempotently. With no pending events,
      # watch/snapshot must neither consume seq nor publish another batch.
      assert {:ok, ^second, 2} = Stream.watch(pid)
      assert {:ok, ^second, 2} = Stream.watch(pid)
      assert {:ok, ^second, 2} = Stream.snapshot(pid)
      refute_receive {:agent_delta, ^agent_id, _, _}, 0
      {:running, data} = :sys.get_state(pid)
      assert Map.keys(data.watchers) == [self()]

      # A consumer can receive covered batches after taking its resync snapshot.
      # Drop BOTH older seq and equal seq (including duplicates) before appending.
      consumer = {second.seq, second.activity}
      assert consume(consumer, [batch1, batch2, batch2]) == consumer

      assert {:ok, third, 3} =
               pending_cut(pid, worker, :snapshot, text: " next", thinking: " more")

      batch3 = assert_batch(agent_id, 3, [{:text, " next"}, {:thinking, " more"}])
      assert_drained(pid, 3)
      assert third.seq == 3
      assert third.phase == :running
      assert third.activity == activity(call_id, "hello! next", "reason more")
      assert third.messages == first.messages

      # Only the subsequent batch is new. Advancing the consumer watermark makes
      # delivery of that same append twice harmless, without losing either field.
      assert consume(consumer, [batch1, batch2, batch3, batch3]) ==
               {third.seq, third.activity}

      refute_receive {:agent_delta, ^agent_id, _, _}, 0
    end
  end

  defp pending_cut(session, worker, command, chunks) do
    token = make_ref()
    assert :ok = :sys.suspend(session)

    try do
      send(worker, {:pending_cut, token, command, chunks})
      assert_receive {:cut_queued, ^token}, 5_000
    after
      # Even an assertion failure must not strand a suspended session in cleanup.
      :sys.resume(session)
    end

    assert_receive {:cut_reply, ^token, reply}, 5_000
    reply
  end

  defp callback_driver(session, test_pid, callbacks) do
    receive do
      {:pending_cut, token, command, chunks} ->
        callbacks =
          callbacks ||
            (fn ->
               # The engine seam replaces LLMPrompting, so start this call
               # explicitly; callbacks still belong to the real installed sink.
               id = Sink.start_call(0)
               Sink.call_phase(id, :llm)
               Sink.stream_opts()
             end).()

        Enum.each(chunks, fn
          {:text, text} -> Keyword.fetch!(callbacks, :on_result).(text)
          {:thinking, text} -> Keyword.fetch!(callbacks, :on_thinking).(text)
        end)

        request = if command == :watch, do: {:watch, test_pid}, else: {:snapshot}
        request_id = :gen_statem.send_request(session, request)
        send(test_pid, {:cut_queued, token})
        {:reply, reply} = :gen_statem.wait_response(request_id, 10_000)
        send(test_pid, {:cut_reply, token, reply})
        callback_driver(session, test_pid, callbacks)
    end
  end

  defp activity(id, text, thinking) do
    %{
      phase: :llm,
      current_call: %{id: id, turn: 0, attempt: 0, text: text, thinking: thinking}
    }
  end

  defp assert_batch(agent_id, seq, events) do
    assert_receive {:agent_delta, ^agent_id, ^seq, ^events}, 5_000
    {seq, events}
  end

  defp assert_drained(session, seq) do
    {:running, data} = :sys.get_state(session)
    assert data.event_seq == seq
    assert Batcher.empty?(data.batcher)
    assert Batcher.timer(data.batcher) == nil
  end

  # Minimal consumer of the documented public replacement/append vocabulary.
  # This deliberately does not feed public chunks into the internal Activity
  # reducer (internal chunks have call IDs; public append events do not).
  defp consume(consumer, batches) do
    Enum.reduce(batches, consumer, fn {seq, events}, {last_seq, projection} = acc ->
      if Stream.stale?(seq, last_seq) do
        acc
      else
        {seq, Enum.reduce(events, projection, &apply_public/2)}
      end
    end)
  end

  defp apply_public({:activity, projection}, _old), do: projection

  defp apply_public({field, text}, projection) when field in [:text, :thinking] do
    update_in(projection, [:current_call, field], &(&1 <> text))
  end
end
