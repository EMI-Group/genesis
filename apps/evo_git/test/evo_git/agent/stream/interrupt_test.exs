defmodule EvoGit.Agent.Stream.InterruptTest do
  @moduledoc """
  P4 pin **(g): `:interrupt` pre-empts a streaming turn**
  (`docs/agent-runtime-refactor.md` §3 D5, §4.7, §4.12, §5 P4 and §7 invariant
  2), driven end-to-end through a REAL `EvoGit.Agent.Session`:

  * **(g1) the in-flight turn ends early and the queued message reaches the NEXT
    LLM context** — `Session.start_input/3` appends the message FIRST and then
    signals the running exchange worker with `{:evogit_interrupt, ref}`
    (`EvoGit.Agent.Session.interrupt_worker/1`). The worker's per-chunk check
    (`EvoGit.Agent.Stream.Sink.interrupt_requested?/0`) consumes that message
    exactly once and raises `EvoGit.Agent.Stream.Interrupted`, which the LLM path
    turns into `{:interrupted, reason}` and `ToolDispatch.do_turn/6` handles as
    an EARLY TURN END — no assistant message, no protocol violation, no grace
    turn — by re-entering `loop_fn.(state)` in the SAME worker. The loop top then
    drains the pending message into the context, so the very next LLM call sees
    it as the last `:user` message.
  * **(g2) with ZERO watchers the interrupt degrades to next-turn-boundary
    delivery and is never lost** — `Sink.stream_opts/0` is `[]` without a
    watcher, so no per-chunk callback is installed and nothing can pre-empt the
    stream; the message stays in the settled transport until the loop top of the
    next exchange drains it (exactly once, in order, before any later input).

  ## Why the seam performs the interrupt check itself

  Every case here drives the exchange through the `:llm_call` engine seam, which
  REPLACES `EvoGit.Agent.LLMPrompting.prompt_until_tools_or_limit/5` — and with
  it the single `ReqLLM.StreamResponse.process_stream(stream_resp, Sink.stream_opts())`
  call site that invokes `:on_chunk`. Pin (g1) therefore polls
  `Sink.interrupt_requested?/0` from inside the seam, in the WORKER process,
  which is exactly where `Session.Worker.run/3` installed the sink and where the
  `{:evogit_interrupt, ref}` message lands. That is the same check, on the same
  message, in the same process as the production per-chunk callback; the only
  difference is that the seam observes it directly instead of through a stream
  chunk (turning the real streaming path on would need a loopback SSE responder
  plus a pinned global scheduler model pool, and would pin ReqLLM's chunking
  rather than EvoGit's interrupt contract).

  ## Why `async: true` is safe

  Every agent id is per-test unique (`EvoGit.Agent.StreamCase`), so the
  BEAM-global summary/sched-meta rows, the control-plane inbox and the PubSub
  topic keyed by that id are private to the test; the harness deletes exactly
  those rows in `on_exit`. No app-env key, Logger level or `:persistent_term`
  entry is touched, and no assertion filters on another agent's traffic.
  """

  use EvoGit.Agent.StreamCase, async: true

  # ---------------------------------------------------------------------------
  # (g1) :interrupt pre-empts a streaming turn
  # ---------------------------------------------------------------------------
  describe "(g1) :interrupt ends the streaming turn early and injects the message" do
    test "the interrupt is consumed once, the aborted turn appends nothing, and the next LLM call sees the message",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      seam = interrupt_seam(self())

      {:ok, pid, _ref} = start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: seam))

      assert_receive {:llm_call, 1, worker, _context}, 5_000

      # Zero watchers: `Sink.stream_opts/0` is `[]`, so NO `process_stream/2`
      # callback is installed on this turn. The sink itself is still installed in
      # the worker (`Session.Worker.run/3` does that unconditionally), which is
      # why the worker can still observe the `{:evogit_interrupt, ref}` message —
      # the seam below performs that check in the worker process.
      assert Session.watching?(pid) == false

      assert :ok = Session.start_input(pid, "interrupt me now", :interrupt)

      # The worker saw the signal, consumed it EXACTLY once (the second peek is
      # `false`), and the message was already in the pending-message transport
      # BEFORE the signal arrived — the load-bearing append-then-send order of
      # `Session.handle_event({:call, from}, {:start_input, …})`.
      assert_receive {:interrupt_observed, true, pending, false}, 5_000
      assert pending == ["interrupt me now"]

      assert_receive {:llm_call, 2, worker2, context2}, 5_000

      # The SAME worker re-entered the loop (the `{:interrupted, _}` arm of
      # `do_turn/6`), rather than ending the run.
      assert worker2 == worker

      # The loop top drained the message into the NEXT LLM request, last.
      assert List.last(context2.messages).role == :user
      assert text_of(List.last(context2.messages)) =~ "interrupt me now"

      assert await_yield(pid, "after interrupt") == true

      history = Session.history(pid)

      # The aborted turn appended NO assistant message: exactly one system
      # message and exactly one assistant message (the answer after the
      # interrupt).
      assert Enum.count(history, &(&1.role == :system)) == 1
      assert Enum.count(history, &(&1.role == :assistant)) == 1
      assert text_of(List.last(history)) == "after interrupt"

      assert Enum.any?(
               history,
               &(&1.role == :user and text_of(&1) =~ "interrupt me now")
             )

      # Drained exactly once, and an interrupt is NOT a terminal outcome: the
      # interactive session yields and parks in `:awaiting_input`.
      assert pending_messages(agent_id) == []
      refute_terminal(agent_id, pid, 200)
    end
  end

  # ---------------------------------------------------------------------------
  # (g2) zero watchers ⇒ next-turn-boundary delivery, never lost
  # ---------------------------------------------------------------------------
  describe "(g2) with zero watchers the interrupt degrades to the next turn boundary" do
    test "the message survives the first exchange and is drained by the next one, in order",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: driver_llm_call(self())))

      assert_receive {:llm_call, worker, _context}, 5_000
      assert Session.watching?(pid) == false

      assert :ok = Session.start_input(pid, "queued while running", :interrupt)

      # Appended synchronously BEFORE the `:ok` reply.
      assert pending_messages(agent_id) == ["queued while running"]

      # Finish the first exchange normally: with no watcher no callback was
      # installed, so the signal could not pre-empt anything and the message is
      # STILL pending — nothing consumed it.
      send(worker, {:reply, "first done"})
      assert await_yield(pid, "first done") == true
      assert pending_messages(agent_id) == ["queued while running"]

      assert :ok = Session.start_input(pid, "second", :queue)

      assert_receive {:llm_call, worker2, context2}, 5_000

      # A NEW exchange worker per exchange (the previous one was released by the
      # yield), but the SAME session, conversation and agent identity.
      assert worker2 != worker

      user_texts =
        context2.messages
        |> Enum.filter(&(&1.role == :user))
        |> Enum.map(&text_of/1)

      first_idx = Enum.find_index(user_texts, &(&1 =~ "queued while running"))
      second_idx = Enum.find_index(user_texts, &(&1 =~ "second"))

      assert is_integer(first_idx)
      assert is_integer(second_idx)
      assert first_idx < second_idx

      # Both messages were drained exactly once by the loop top of the new
      # exchange, before its LLM call.
      assert pending_messages(agent_id) == []

      send(worker2, {:reply, "second done"})
      assert await_yield(pid, "second done") == true
      refute_terminal(agent_id, pid, 200)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers — the seam runs in the WORKER process, so it sends observations to
  # the test pid and never asserts/flunks there.
  # ---------------------------------------------------------------------------

  # Call 1: report the request, wait (bounded) for the `{:evogit_interrupt, ref}`
  # message to arrive, CONSUME it through the production peek, report what the
  # transport still holds, then return the `{:interrupted, _}` halt the LLM layer
  # produces. Call 2: report the request (which now carries the drained message)
  # and finish with a tool-free reply.
  defp interrupt_seam(test_pid) do
    scripted_llm_call(fn context, _tools, _params, agent_id, _retries ->
      case Process.get(:interrupt_test_calls, 0) do
        0 ->
          Process.put(:interrupt_test_calls, 1)
          send(test_pid, {:llm_call, 1, self(), context})

          observed = await_interrupt(deadline(5_000))

          # Peeked BEFORE returning: the drain happens at the loop top AFTER
          # this call returns, so the message must still be queued here.
          pending = pending_messages(agent_id)
          send(test_pid, {:interrupt_observed, observed, pending, Sink.interrupt_requested?()})

          {:interrupted, %Interrupted{reason: :client_interrupt}}

        1 ->
          Process.put(:interrupt_test_calls, 2)
          send(test_pid, {:llm_call, 2, self(), context})
          {:implicit_completion, response(context, "after interrupt"), "after interrupt"}
      end
    end)
  end

  # Bounded, event-driven wait for the interrupt signal: the production peek
  # consumes the message when it is present, so a `true` here is the ONE
  # observation the worker makes.
  defp await_interrupt(deadline) do
    if Sink.interrupt_requested?() do
      true
    else
      if remaining(deadline) > 0 do
        Process.sleep(5)
        await_interrupt(deadline)
      else
        false
      end
    end
  end
end
