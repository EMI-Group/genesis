defmodule EvoGit.Agent.Stream.GateTest do
  @moduledoc """
  P4 push-only streaming invariants (`docs/agent-runtime-refactor.md` §3 D5,
  §4.6, §4.12 and §7 invariant 2) that need a REAL session:

  * **(a) zero watchers ⇒ capture and interruption, but zero broadcasts** —
    `Sink.stream_opts/0` returns four callbacks whenever a sink is installed,
    and `[]` only without one. The callbacks capture live text/thinking and
    honor interrupts independently of watchers; the session gates publication.
    The end-to-end cases pin that an unwatched exchange retains its current
    call for a snapshot but produces no `{:agent_delta, …}` and consumes no `seq`.
  * **(b) one watcher ⇒ coalesced batches** — 100 individually-emitted chunks
    arrive as a handful of batches, all events preserved in emission order.
  * **(c) seq ordering + snapshot reconciliation** — monotonic per-session
    `seq`, one increment per broadcast, and `stale?/2` against a fresh
    snapshot as the ONLY resync (no replay, never double-applied).

  ## Why no `process_stream/2` trace

  Every case here drives the exchange through the `:llm_call` engine seam, which
  REPLACES `LLMPrompting.prompt_until_tools_or_limit/5` — so `process_stream/2`
  is never called and a call trace over it would vacuously pass in both
  the watched and unwatched case. Turning the real streaming path on would need
  a loopback SSE responder plus a pinned global scheduler model pool (the
  `implicit_completion_test.exs` machinery), which buys nothing beyond what the
  Sink unit test already pins at the exact argument value the real call site
  passes. The unwatched end-to-end case below is the behavioural half.

  ## Why `async: true` is safe

  Every agent id is per-test unique (`EvoGit.Agent.StreamCase`), so the
  BEAM-global summary/sched-meta rows and the PubSub topic keyed by that id are
  private to the test; no app-env key, Logger level or `:persistent_term` entry
  is touched and no assertion filters on another agent's traffic.
  """

  use EvoGit.Agent.StreamCase, async: true

  # ---------------------------------------------------------------------------
  # (a) zero watchers
  # ---------------------------------------------------------------------------
  describe "(a) zero watchers retain capture and interruption but broadcast nothing" do
    test "Sink.stream_opts/0 is [] when the sink is not installed in this process" do
      refute Sink.installed?()
      assert Sink.stream_opts() == []
    end

    test "an unwatched installed sink captures callbacks and honors interrupts without publishing",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      test_pid = self()
      assert :ok = subscribe_topic(agent_id)

      llm_call =
        scripted_llm_call(fn context, _tools, _params, _agent_id, _retries ->
          # Run in the genuine exchange worker: the session rejects activity
          # envelopes from any other process, including the test process.
          call_id = Sink.start_call(0)
          opts = Sink.stream_opts()
          send(test_pid, {:callbacks_ready, self(), opts, call_id})

          receive do
            :capture -> :ok
          end

          assert :ok = opts[:on_result].("unwatched ")
          assert :ok = opts[:on_result].("text")
          assert :ok = opts[:on_thinking].("private ")
          assert :ok = opts[:on_thinking].("thinking")
          assert :ok = opts[:on_tool_call].(%{name: "read"})
          assert :ok = opts[:on_chunk].(:chunk)

          send(self(), {:evogit_interrupt, make_ref()})
          assert_raise Interrupted, fn -> opts[:on_chunk].(:chunk) end
          # The interrupt is consumed exactly once, not left to poison a later chunk.
          assert :ok = opts[:on_chunk].(:chunk)
          send(test_pid, {:callbacks_captured, self()})

          receive do
            :finish ->
              text = "unwatched callback yield"
              {:implicit_completion, response(context, text), text}
          end
        end)

      {:ok, pid, _ref} = start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: llm_call))
      assert_receive {:callbacks_ready, worker, opts, call_id}, 5_000
      refute Session.watching?(pid)
      assert Keyword.keyword?(opts)

      assert opts |> Keyword.keys() |> Enum.sort() == [
               :on_chunk,
               :on_result,
               :on_thinking,
               :on_tool_call
             ]

      assert Enum.all?(opts, fn {_key, fun} -> is_function(fun, 1) end)
      send(worker, :capture)
      assert_receive {:callbacks_captured, ^worker}, 5_000

      # The worker's acknowledgment and the snapshot request have different
      # senders. Wait for the captured state, not a timer or mailbox race.
      assert wait_until(fn ->
               case Stream.snapshot(pid) do
                 {:ok,
                  %Snapshot{
                    activity: %{
                      current_call: %{text: "unwatched text", thinking: "private thinking"}
                    }
                  }, 0} ->
                   true

                 _ ->
                   false
               end
             end)

      assert {:ok,
              %Snapshot{
                seq: 0,
                activity: %{
                  current_call: %{
                    id: ^call_id,
                    attempt: 0,
                    text: "unwatched text",
                    thinking: "private thinking"
                  }
                }
              }, 0} = Stream.snapshot(pid)

      refute_receive {:agent_delta, ^agent_id, _seq, _events}, 0

      # A late watcher recovers captured content, without replay or a consumed seq.
      assert {:ok, %Snapshot{activity: %{current_call: %{id: ^call_id, text: "unwatched text"}}},
              0} =
               Stream.watch(pid)

      assert Session.watching?(pid)
      refute_receive {:agent_delta, ^agent_id, _seq, _events}, 0
      send(worker, :finish)
      assert await_yield(pid, "unwatched callback yield")
    end

    test "a running exchange with NO watcher emits no {:agent_delta, _} and consumes no seq",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      # Subscribe as an OBSERVER only (never a watcher): any broadcast would arrive.
      assert :ok = subscribe_topic(agent_id)

      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: driver_llm_call(self())))

      assert_receive {:llm_call, worker, _context}, 5_000
      refute Session.watching?(pid)

      send(worker, {:emit, Enum.map(1..20, &{:text, "n#{&1}"}), "zero-watcher yield"})

      assert await_yield(pid, "zero-watcher yield") == true

      # No watcher ⇒ every {:delta, …} was dropped on arrival: no buffer, no
      # timer, no broadcast and NO sequence number consumed.
      assert {:ok, %Snapshot{phase: :awaiting_input, seq: 0}, 0} = Stream.snapshot(pid)

      refute_receive {:agent_delta, ^agent_id, _seq, _events}, 300
    end
  end

  # ---------------------------------------------------------------------------
  # (b) one watcher ⇒ coalesced batches
  # ---------------------------------------------------------------------------
  describe "(b) one watcher ⇒ coalesced batches" do
    test "100 individually-emitted chunks arrive as a handful of ordered batches, none lost",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: driver_llm_call(self())))

      assert_receive {:llm_call, worker, _context}, 5_000

      assert {:ok, %Snapshot{}, 0} = Stream.watch(pid)

      # Two 50-chunk waves in ONE LLM attempt. The second wave is HELD until
      # the test has observed the first wave's batch, so "more than one batcher
      # window" is a deterministic event, not a sleep.
      wave_a = Enum.map(1..50, &{:text, "a#{&1}"})
      wave_b = Enum.map(1..50, &{:text, "b#{&1}"})
      send(worker, {:emit_waves, [wave_a, wave_b], "wave yield"})

      first = collect_deltas(agent_id)

      assert first != []
      assert Enum.all?(first, fn {_seq, events} -> is_list(events) and events != [] end)
      assert length(first) < 50
      assert length(first) <= 5

      first_texts =
        first |> Enum.flat_map(fn {_seq, events} -> events end) |> Enum.filter(&text_event?/1)

      assert first_texts == wave_a

      seqs_a = Enum.map(first, fn {seq, _events} -> seq end)
      assert seqs_a == Enum.sort(seqs_a)
      assert length(Enum.uniq(seqs_a)) == length(seqs_a)
      assert hd(seqs_a) > 0

      send(worker, :next_wave)
      second = collect_deltas(agent_id)

      assert second != []
      assert Enum.all?(second, fn {_seq, events} -> is_list(events) and events != [] end)

      second_texts =
        second |> Enum.flat_map(fn {_seq, events} -> events end) |> Enum.filter(&text_event?/1)

      assert second_texts == wave_b

      seqs_b = Enum.map(second, fn {seq, _events} -> seq end)
      assert seqs_b == Enum.sort(seqs_b)
      assert hd(seqs_b) > List.last(seqs_a)

      # A burst spread over more than one window produced more than one batch,
      # and every chunk was delivered exactly once (50 + 50 text events).
      assert length(first) + length(second) > 1
      assert length(first_texts) + length(second_texts) == 100
      assert length(first) + length(second) < 100

      assert await_yield(pid, "wave yield") == true
      refute_terminal(agent_id, pid, 200)
    end
  end

  # ---------------------------------------------------------------------------
  # (c) seq ordering + snapshot reconciliation
  # ---------------------------------------------------------------------------
  describe "(c) seq ordering and snapshot reconciliation" do
    test "seq is strictly increasing per broadcast, and a fresh snapshot makes every earlier delta stale",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: driver_llm_call(self())))

      assert_receive {:llm_call, worker, _context}, 5_000

      assert {:ok, %Snapshot{}, 0} = Stream.watch(pid)

      send(worker, {:emit_waves, [seq_wave(1, 5), seq_wave(2, 5)], "seq yield"})

      first = collect_deltas(agent_id)
      assert first != []
      first_seqs = Enum.map(first, fn {seq, _events} -> seq end)

      # ONE broadcast per flush, so the seqs are strictly increasing, and each
      # broadcast advanced by exactly one from the previous one.
      assert first_seqs == Enum.sort(first_seqs)
      assert length(Enum.uniq(first_seqs)) == length(first_seqs)
      assert hd(first_seqs) == 1
      assert first_seqs == Enum.to_list(1..length(first_seqs))

      # The ONE resync path: a snapshot re-stamps the current seq.
      assert {:ok, %Snapshot{} = snapshot, snapshot_seq} = Stream.snapshot(pid)
      assert snapshot_seq == List.last(first_seqs)
      assert snapshot.seq == snapshot_seq
      assert snapshot.phase == :running

      # Everything at or before the snapshot is stale; anything newer is kept.
      for stale_seq <- [0, 1, snapshot_seq] do
        assert Stream.stale?(stale_seq, snapshot_seq)
      end

      refute Stream.stale?(snapshot_seq + 1, snapshot_seq)

      # The subscribe→snapshot gap: a delta broadcast in that window is tagged
      # with a seq the snapshot already covers, so the documented rule drops it
      # and it can never be applied twice. Simulated by broadcasting exactly
      # that shape — the watched session's own broadcast is indistinguishable
      # from it on the wire. `Stream.watch/1` already subscribed THIS process
      # (and `Phoenix.PubSub.subscribe/2` in this version is NOT idempotent:
      # the Registry is `keys: :duplicate`, so a second subscribe would deliver
      # every message twice), which is exactly why `register_watcher/2`
      # deliberately does not subscribe anything.
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        Stream.topic(agent_id),
        {:agent_delta, agent_id, snapshot_seq, [{:text, "gap"}]}
      )

      assert_receive {:agent_delta, ^agent_id, ^snapshot_seq, [{:text, "gap"}]}, 1_000
      assert Stream.stale?(snapshot_seq, snapshot_seq)

      send(worker, :next_wave)
      second = collect_deltas(agent_id)
      assert second != []

      second_seqs = Enum.map(second, fn {seq, _events} -> seq end)
      assert second_seqs == Enum.sort(second_seqs)

      # Every delta of the second window is NEWER than the snapshot the consumer
      # reconciles against, so none of them is dropped as stale.
      assert Enum.all?(second_seqs, &(&1 > snapshot_seq))

      assert await_yield(pid, "seq yield") == true
      assert {:ok, %Snapshot{}, final_seq} = Stream.snapshot(pid)
      assert final_seq >= List.last(second_seqs)

      # A gone session is the documented not-found shape, never a raise.
      assert :ok = Session.cancel(pid, :force)
      assert wait_until(fn -> not Process.alive?(pid) end)
      assert Stream.snapshot(pid) == {:error, {:not_found, :session_unavailable}}
      assert Stream.watch(pid) == {:error, {:not_found, :session_unavailable}}
      assert Stream.unwatch(pid) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  defp text_event?({:text, text}) when is_binary(text), do: true
  defp text_event?(_other), do: false

  defp seq_wave(prefix, count), do: Enum.map(1..count, &{:text, "#{prefix}:#{&1}"})
end
