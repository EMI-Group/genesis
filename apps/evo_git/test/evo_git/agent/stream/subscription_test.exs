defmodule EvoGit.Agent.Stream.SubscriptionTest do
  @moduledoc """
  The IDEMPOTENT-subscription contract of the push-only streaming layer, plus the
  `EvoGit.RemoteNode` watch verbs built on top of it.

  ## Pins
  * `Stream.subscribe/1` is idempotent per consumer process: a second subscribe for
    the SAME agent (a dashboard re-mount, a retried attach) delivers ONE copy of
    each `{:agent_delta, …}` batch, not two. `Phoenix.PubSub`'s subscription
    registry is `keys: :duplicate`, so without the consumer-local memo a duplicate
    subscribe really would duplicate every delta.
  * `Stream.unsubscribe/1` clears the memo, so a later `subscribe/1` subscribes for
    real again, and it is idempotent.
  * The memo is CONSUMER-LOCAL: two processes each hold their own subscription.
  * `RemoteNode.watch_agent/2` subscribes the CALLING process (never an `:erpc`
    worker), registers it on the owning node and returns the FLAT
    `{:ok, %Snapshot{}, seq}`; re-watching does not duplicate deltas; a REFUSED
    watch leaves no subscription behind.
  * `RemoteNode.unwatch_agent/2` unregisters and always clears the local
    subscription, even when the session is already gone.
  * `RemoteNode.watch_snapshot/2` is a one-shot read that registers and subscribes
    nothing.

  ## Why `async: true` is safe
  Every fixture uses a PER-TEST UNIQUE agent id (`EvoGit.Agent.StreamCase`'s
  disjoint `9_9xx_xxx` range) and its own `"agent:<id>"` topic, so no other module
  can observe or satisfy a broadcast; nothing asserts on a table or topic as a
  whole and no app-env key, Logger level or `:persistent_term` entry is touched.
  """
  use EvoGit.Agent.StreamCase, async: true

  alias EvoGit.RemoteNode

  describe "Stream.subscribe/1 is idempotent (consumer-local memo)" do
    test "a second subscribe from the SAME process delivers ONE copy of each batch", _ctx do
      agent_id = new_agent_id()

      assert :ok = Stream.subscribe(agent_id)
      assert :ok = Stream.subscribe(agent_id)

      broadcast(agent_id, 1, [:once])

      assert_receive {:agent_delta, ^agent_id, 1, [:once]}, 1_000
      refute_receive {:agent_delta, ^agent_id, 1, [:once]}, 250
    end

    test "unsubscribe/1 clears the memo, so a later subscribe subscribes for real", _ctx do
      agent_id = new_agent_id()

      assert :ok = Stream.subscribe(agent_id)
      assert :ok = Stream.unsubscribe(agent_id)

      # Idempotent even when this process is not subscribed at all.
      assert :ok = Stream.unsubscribe(agent_id)

      broadcast(agent_id, 1, [:dropped])
      refute_receive {:agent_delta, ^agent_id, 1, _events}, 250

      assert :ok = Stream.subscribe(agent_id)
      broadcast(agent_id, 2, [:again])
      assert_receive {:agent_delta, ^agent_id, 2, [:again]}, 1_000
    end

    test "the memo is CONSUMER-LOCAL: a second process holds its own subscription", _ctx do
      agent_id = new_agent_id()
      parent = self()

      assert :ok = Stream.subscribe(agent_id)

      consumer =
        spawn(fn ->
          # Its OWN memo is empty, so this is a real subscription despite the
          # parent already being subscribed to the same topic.
          :ok = Stream.subscribe(agent_id)
          send(parent, {:consumer_subscribed, self()})
          forward_to(parent)
        end)

      on_exit(fn -> Process.exit(consumer, :kill) end)
      assert_receive {:consumer_subscribed, ^consumer}, 1_000

      broadcast(agent_id, 7, [:both])

      assert_receive {:agent_delta, ^agent_id, 7, [:both]}, 1_000
      assert_receive {:consumer_msg, {:agent_delta, ^agent_id, 7, [:both]}}, 1_000
    end
  end

  describe "RemoteNode.watch_agent/2 — local node" do
    test "subscribes the CALLER, registers it and returns the FLAT shape",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: driver_llm_call(self())))

      assert_receive {:llm_call, worker, _context}, 2_000

      assert {:ok, %Snapshot{} = snapshot, seq} = RemoteNode.watch_agent(node(), agent_id)
      assert snapshot.agent_id == agent_id
      assert is_integer(seq)
      assert Session.watching?(pid)

      # Re-watching is idempotent: the caller is already subscribed, so the same
      # batch arrives ONCE (a duplicate subscription would deliver it twice).
      assert {:ok, %Snapshot{}, _seq} = RemoteNode.watch_agent(node(), agent_id)

      send(worker, {:emit, [{:text, "one"}], "done"})

      assert_receive {:agent_delta, ^agent_id, delta_seq, events}, 2_000
      assert {:text, "one"} in events
      assert delta_seq > seq
      refute_receive {:agent_delta, ^agent_id, ^delta_seq, ^events}, 250

      assert :ok = RemoteNode.unwatch_agent(node(), agent_id)
      assert await_yield(pid, "done") == true
      assert wait_until(fn -> Session.watching?(pid) == false end)
    end

    test "a REFUSED watch leaves no subscription behind", _ctx do
      # No session exists for this id: the watch is refused.
      missing = new_agent_id()

      assert {:error, {:not_found, :session_not_found}} =
               RemoteNode.watch_agent(node(), missing)

      broadcast(missing, 1, [:never])
      refute_receive {:agent_delta, ^missing, 1, _events}, 250
    end

    test "unwatch_agent/2 clears the local subscription even when the session is gone", _ctx do
      missing = new_agent_id()
      assert :ok = Stream.subscribe(missing)

      assert {:error, {:not_found, :session_not_found}} =
               RemoteNode.unwatch_agent(node(), missing)

      broadcast(missing, 1, [:never])
      refute_receive {:agent_delta, ^missing, 1, _events}, 250
    end
  end

  describe "RemoteNode.watch_snapshot/2" do
    test "reads once, registers and subscribes NOTHING",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: driver_llm_call(self())))

      assert_receive {:llm_call, _worker, _context}, 2_000

      assert {:ok, %Snapshot{} = snapshot, seq} = RemoteNode.watch_snapshot(node(), agent_id)
      assert snapshot.agent_id == agent_id
      assert seq == 0
      refute Session.watching?(pid)
    end

    test "an unknown agent answers the flat refusal", _ctx do
      assert {:error, {:not_found, :session_not_found}} =
               RemoteNode.watch_snapshot(node(), new_agent_id())
    end
  end

  # The remote-style consumer: forwards everything it receives to the test, so the
  # test can pin what the topic delivered to a SECOND process.
  defp forward_to(parent) do
    receive do
      msg ->
        send(parent, {:consumer_msg, msg})
        forward_to(parent)
    end
  end

  defp broadcast(agent_id, seq, events) do
    Phoenix.PubSub.broadcast(
      EvoGit.PubSub,
      Stream.topic(agent_id),
      {:agent_delta, agent_id, seq, events}
    )
  end
end
