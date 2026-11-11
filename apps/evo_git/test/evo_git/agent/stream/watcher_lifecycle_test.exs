defmodule EvoGit.Agent.Stream.WatcherLifecycleTest do
  @moduledoc """
  P4 watcher-lifecycle invariants of the push-only delta contract
  (`docs/agent-runtime-refactor.md` §3 D5, §4.6 and §7 invariant 2):
  the session-owned watcher set is the ONLY streaming gate, so the gate must
  follow watcher DEATH rather than a consumer's cooperation.

  ## Pins

  * **(d) watcher death clears the gate** — a killed consumer is reaped by the
    session's own `:DOWN`; the entry (and its monitor) is really gone, and the
    next exchange emits NO broadcast at all and consumes no sequence number.
  * **(e) remote-style watcher** — the RPC-facing shape: the registered pid is a
    process that is neither the subscribing caller nor the test process and
    subscribes to the topic ITSELF. `register_watcher/2` never subscribes, and a
    monitor on an external pid delivers `:DOWN` exactly like a remote one, so
    this is the local equivalent of a remote consumer ("a monitor on a remote
    pid is a cross-node signal" — `EvoGit.Agent.Stream.Watchers`). Its pushes
    arrive, and its `:DOWN` closes the gate for the NEXT exchange.
  * **(f) N-agent broadcast budget** — three unwatched sessions broadcast
    nothing on their own topics, and no sequence number is consumed.

  Every session is started DIRECTLY (`Session.start_link/1`) against a
  repo-less `dispatch_ctx` whose `:exchange_opts` carry the harness's
  test-driven `:llm_call` seam, so no git repository, worktree, LLM request or
  scheduler dispatch is involved and every step of the exchange is
  deterministic in the WORKER process.

  ## Why `async: true` is safe

  `EvoGit.Agent.StreamCase` installs one PER-TEST UNIQUE agent id
  (`9_960_000 + System.unique_integer/1`) in the BEAM-global
  `:evogit_agent_summary` / `:evogit_sched_meta` ETS tables and deletes exactly
  those rows (plus the temp dir) in `on_exit`; extra agents in (f) are
  registered and removed the same way. PubSub subscriptions are keyed by the
  unique per-agent topic `"agent:<id>"`, so no two suites share a topic, and no
  app-env key, Logger level or `:persistent_term` entry is touched. Nothing
  asserts on a table or topic as a whole.
  """

  use EvoGit.Agent.StreamCase, async: true

  # ---------------------------------------------------------------------------
  # (d) watcher death clears the gate
  # ---------------------------------------------------------------------------

  describe "(d) watcher death clears the streaming gate" do
    test "a killed consumer is reaped by :DOWN and the next exchange broadcasts nothing",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: driver_llm_call(self())))

      # The exchange is parked INSIDE the worker at the seam, so the session is
      # `:running` (and owns a checkpointed `%State{}`) but has emitted nothing.
      assert_receive {:llm_call, worker, _context}, 2_000
      assert Session.watching?(pid) == false

      # A bare consumer: it never subscribes and never handles a message, so
      # only the session's monitor can notice its death.
      consumer =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      on_exit(fn -> Process.exit(consumer, :kill) end)

      assert {:ok, %Snapshot{}, 0} = Stream.register_watcher(pid, consumer)
      assert Session.watching?(pid) == true

      Process.exit(consumer, :kill)

      # The gate closes by the session's OWN `:DOWN` bookkeeping — no
      # bookkeeping process and no cooperation from the consumer.
      assert wait_until(fn -> Session.watching?(pid) == false end)

      # The entry is really gone, not just the boolean: unregistering is
      # idempotent AND proves the monitor bookkeeping did not wedge.
      assert :ok = Stream.unregister_watcher(pid, consumer)

      # ... and the session holds no monitor on the dead consumer any more.
      assert {:monitors, monitors} = Process.info(pid, :monitors)
      refute {:process, consumer} in monitors

      # The test observes the topic WITHOUT being a watcher, so any broadcast
      # attributable to this agent would land here.
      assert :ok = subscribe_topic(agent_id)

      send(worker, {:emit, Enum.map(1..10, &{:text, "dead#{&1}"}), "after watcher death"})
      assert await_yield(pid, "after watcher death") == true

      # Zero watchers: the batch is dropped on arrival (no buffer, no flush, no
      # broadcast) and NO sequence number is consumed.
      assert {:ok, %Snapshot{}, 0} = Stream.snapshot(pid)
      refute_receive {:agent_delta, ^agent_id, _seq, _events}, 300
    end
  end

  # ---------------------------------------------------------------------------
  # (e) remote-style watcher (the local equivalent of a remote consumer)
  # ---------------------------------------------------------------------------

  describe "(e) remote-style watcher: an external, self-subscribed consumer" do
    test "it receives pushes, and its :DOWN closes the gate for the next exchange",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: driver_llm_call(self())))

      assert_receive {:llm_call, worker, _context}, 2_000

      test_pid = self()
      topic = Stream.topic(agent_id)

      # The consumer subscribes ITSELF to its own node's PubSub — `register_watcher/2`
      # deliberately subscribes nothing (a remote consumer has its own node's PubSub).
      consumer =
        spawn(fn ->
          :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, topic)
          send(test_pid, {:consumer_subscribed, self()})
          forward_to(test_pid)
        end)

      on_exit(fn -> Process.exit(consumer, :kill) end)
      assert_receive {:consumer_subscribed, ^consumer}, 2_000

      # The registered pid is NEITHER the subscribing caller NOR the test process:
      # exactly the RPC-facing shape. A monitor on an external pid delivers `:DOWN`
      # exactly like a remote one (a remote monitor is a cross-node signal), so this
      # is the local equivalent of the remote-consumer invariant.
      refute consumer == self()
      assert {:ok, %Snapshot{}, 0} = Stream.register_watcher(pid, consumer)
      assert Session.watching?(pid) == true

      send(worker, {:emit, [{:text, "remote-one"}, {:thinking, "remote-two"}], "remote yield"})

      assert_receive {:consumer_msg, {:agent_delta, ^agent_id, seq, events}}, 2_000
      assert seq > 0
      # The scripted pair opens the batch verbatim and in emission order (the SAME
      # exchange then emits its own `{:turn, …}` and `{:yield, …}` events, which
      # share the ~75 ms coalescing window).
      assert Enum.take(events, 2) == [{:text, "remote-one"}, {:thinking, "remote-two"}]
      assert {:yield, "remote yield"} in events

      assert await_yield(pid, "remote yield") == true

      Process.exit(consumer, :kill)
      assert wait_until(fn -> Session.watching?(pid) == false end)

      # The yield parked the session in `:awaiting_input`; resume it for a SECOND
      # exchange on the SAME session pid. The gate is closed for this exchange.
      assert :ok = Session.start_input(pid, "second", :queue)
      assert_receive {:llm_call, worker2, _context}, 2_000

      assert {:ok, %Snapshot{}, seq_before} = Stream.snapshot(pid)

      # Observe the topic as a non-watcher from here on, so the pin is "gate
      # closed ⇒ no broadcast exists at all" (the killed consumer cannot forward).
      assert :ok = subscribe_topic(agent_id)

      send(worker2, {:emit, [{:text, "after-remote-death"}], "remote done"})
      assert await_yield(pid, "remote done") == true

      refute_receive {:agent_delta, ^agent_id, _seq, _events}, 300
      assert {:ok, %Snapshot{}, seq_after} = Stream.snapshot(pid)
      assert seq_after == seq_before
    end
  end

  # ---------------------------------------------------------------------------
  # (f) N-agent broadcast budget
  # ---------------------------------------------------------------------------

  describe "(f) N-agent broadcast budget" do
    test "three unwatched sessions broadcast nothing and consume no sequence numbers",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      [agent2, agent3] = [new_agent_id(), new_agent_id()]
      dir2 = new_tmp_dir(agent2)
      dir3 = new_tmp_dir(agent3)

      for {id, dir} <- [{agent2, dir2}, {agent3, dir3}] do
        register_agent(id, dir, [])
        on_exit(fn -> unregister_agent(id, dir) end)
      end

      # Start one session per agent, receiving each worker before starting the
      # next, so every `{:llm_call, worker, _}` is unambiguously attributed.
      sessions =
        for {id, dir} <- [{agent_id, tmp_dir}, {agent2, dir2}, {agent3, dir3}] do
          {:ok, pid, _ref} =
            start_session(dispatch_ctx(id, dir, llm_call: driver_llm_call(self())))

          assert_receive {:llm_call, worker, _context}, 2_000
          {id, pid, worker}
        end

      # PubSub has NO wildcard subscription, which is why the test subscribes the
      # SPECIFIC topics: the three agents' own topics plus one id with no session,
      # so any broadcast attributable to these agents would arrive here.
      unassigned = new_agent_id()

      for id <- [agent_id, agent2, agent3, unassigned] do
        assert :ok = subscribe_topic(id)
      end

      sessions
      |> Enum.with_index(1)
      |> Enum.each(fn {{_id, pid, worker}, index} ->
        assert Session.watching?(pid) == false
        send(worker, {:emit, Enum.map(1..5, &{:text, "a#{&1}"}), "done-#{index}"})
      end)

      for {{_id, pid, _worker}, index} <- Enum.with_index(sessions, 1) do
        assert await_yield(pid, "done-#{index}") == true

        # Zero watchers on every one of them: no broadcast and NO sequence number
        # consumed, so every session's `event_seq` is still exactly 0.
        assert {:ok, %Snapshot{}, 0} = Stream.snapshot(pid)
      end

      refute_receive {:agent_delta, _agent_id, _seq, _events}, 400
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # The remote-style consumer: subscribes in ITS OWN process and forwards every
  # PubSub message to the test, so the test can pin what the topic delivered
  # without being the watcher.
  defp forward_to(parent) do
    receive do
      msg ->
        send(parent, {:consumer_msg, msg})
        forward_to(parent)
    end
  end
end
