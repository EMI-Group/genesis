defmodule EvoGit.Agent.Stream.PureContractTest do
  @moduledoc """
  The PURE unit contract of the P4 push-only streaming layer
  (`docs/agent-runtime-refactor.md` §3 D5, §4.7, §7 invariant 2).

  Every pin here is a pure data/function contract — no session process, no
  scheduler, no exchange. One `describe` per unit:

  * `Stream.topic/1` — the ONE topic name shape (`"agent:" <> to_string(id)`).
  * `Stream.stale?/2` — the WHOLE reconciliation rule: `seq <= snapshot_seq` is
    dropped, and a pair that is not two integers fails CLOSED (a dropped delta
    is repaired by a fresh snapshot; an applied stale delta could be applied
    twice).
  * `Stream.normalize_batch/1` — an emitter's `nil` / single event / list shape
    becomes one flat ordered list.
  * `Batcher` — the one coalescing buffer: empty default with no timer,
    emission-ordered appends, `take/1` draining into a FRESH timer-less batcher
    (a fired timer reference is never reused), the timer round trip and the
    documented 75 ms window.
  * `Watchers` pure functions — the watcher set is plain session DATA
    (`pid => monitor ref`): register/watching?/watcher_ref?/unregister, a
    re-registration that replaces the ref without stranding a monitor, the
    stale-`:DOWN` guard of `unregister_ref/3`, and `cancel_timer/1` dropping the
    timer while KEEPING the buffered events.
  * `Watchers.flush/4` — the ONE broadcast site: an empty batch is untouched, a
    zero-watcher batch is DROPPED without consuming a sequence number, and a
    watched batch publishes exactly ONE `{:agent_delta, agent_id, seq + 1,
    events}`.
  * `Snapshot.from/2` — a point-in-time snapshot is plain JSON-clean data (no
    `%ReqLLM.Context{}` anywhere), carries the context's message list, and
    degrades to `[]` for a context that is not a messages map.
  * `Interrupted` — the exception message shape of the in-stream abort.

  ## Why `async: true` is safe
  Nothing here mutates BEAM-global state: no app-env key, no ETS table, no
  `:persistent_term`, no `Logger` level and no session process. The only shared
  process touched is the app-booted `EvoGit.PubSub`, and every subscription and
  assertion is scoped to a PER-TEST-UNIQUE `"agent:<id>"` topic
  (`9_970_000 + System.unique_integer([:positive])`), so no other module can
  observe or satisfy a broadcast. Watcher entries are monitors owned by the test
  process and die with it.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.State
  alias EvoGit.Agent.Stream
  alias EvoGit.Agent.Stream.{Batcher, Interrupted, Snapshot, Watchers}
  alias EvoGit.Agent.Usage

  @agent_id_base 9_970_000

  describe "Stream.topic/1" do
    test "is \"agent:\" <> to_string(id) for both integer and binary ids" do
      assert Stream.topic(123) == "agent:123"
      assert Stream.topic("abc") == "agent:abc"
    end
  end

  describe "Stream.stale?/2" do
    test "seq <= snapshot_seq is the whole reconciliation rule" do
      n = 42

      # {seq of the delta, seq of the snapshot, stale?}
      cases = [
        # The boundary: a delta AT the snapshot's seq is already covered.
        {n, n, true},
        # Behind the snapshot: the consumer already has it.
        {n - 1, n, true},
        {1, n, true},
        {0, n, true},
        # Ahead of the snapshot: a genuine new delta.
        {n + 1, n, false}
      ]

      for {seq, snapshot_seq, expected} <- cases do
        assert Stream.stale?(seq, snapshot_seq) == expected,
               "expected stale?(#{inspect(seq)}, #{inspect(snapshot_seq)}) == #{expected}"
      end
    end

    test "fails CLOSED for a pair that is not two integers" do
      # A malformed/absent tag is a dropped delta: a fresh snapshot restores it,
      # while applying it could apply the same event twice.
      for {seq, snapshot_seq} <- [
            {nil, 1},
            {"1", 1},
            {1, nil},
            {nil, nil},
            {"1", "1"},
            {1.0, 1}
          ] do
        assert Stream.stale?(seq, snapshot_seq),
               "expected stale?(#{inspect(seq)}, #{inspect(snapshot_seq)}) to fail CLOSED"
      end
    end
  end

  describe "Stream.normalize_batch/1" do
    test "nil is nothing emitted, a single event is wrapped, a list is itself" do
      assert Stream.normalize_batch(nil) == []

      event = {:text, "hello"}
      assert Stream.normalize_batch(event) == [event]

      list = [{:text, "a"}, {:thinking, "b"}, {:tool_call, nil, "read"}]
      assert Stream.normalize_batch(list) == list
    end
  end

  describe "Batcher" do
    test "new/0 is empty with no pending timer" do
      batcher = Batcher.new()

      assert batcher == %Batcher{events: [], timer: nil}
      assert Batcher.empty?(batcher)
      assert Batcher.timer(batcher) == nil
    end

    test "push/2 appends one event, a list of events, and preserves EMISSION order" do
      batcher =
        Batcher.new()
        |> Batcher.push({:text, "one"})
        |> Batcher.push([{:text, "two"}, {:thinking, "three"}])
        |> Batcher.push({:tool_call, nil, "read"})
        |> Batcher.push(nil)

      # `nil` contributes nothing, and the ordered list is exactly emission order.
      assert batcher.events == [
               {:text, "one"},
               {:text, "two"},
               {:thinking, "three"},
               {:tool_call, nil, "read"}
             ]

      refute Batcher.empty?(batcher)
    end

    test "take/1 drains the buffer into a FRESH batcher with NO timer" do
      ref = Process.send_after(self(), :noop, 60_000)

      batcher =
        Batcher.new()
        |> Batcher.push({:text, "x"})
        |> Batcher.set_timer(ref)

      {events, fresh} = Batcher.take(batcher)

      assert events == [{:text, "x"}]
      assert fresh == Batcher.new()
      assert Batcher.timer(fresh) == nil
      # The fired/held reference is never carried across a drain.
      refute Batcher.timer(fresh) == ref

      _ = Process.cancel_timer(ref)
    end

    test "set_timer/2, timer/1 and clear_timer/1 round trip" do
      ref = Process.send_after(self(), :noop, 60_000)

      batcher = Batcher.set_timer(Batcher.new(), ref)
      assert Batcher.timer(batcher) == ref
      assert Batcher.timer(Batcher.clear_timer(batcher)) == nil

      _ = Process.cancel_timer(ref)
    end

    test "flush_interval_ms/0 is the documented 60-80 ms coalescing window" do
      interval = Batcher.flush_interval_ms()

      assert is_integer(interval)
      assert interval in 60..80
      assert interval == 75
    end
  end

  describe "Watchers (pure)" do
    test "watching?/1 is the streaming gate" do
      refute Watchers.watching?(%{})

      watchers = Watchers.register(%{}, self())
      assert Watchers.watching?(watchers)
      assert map_size(watchers) == 1
    end

    test "register/2 stores a monitor reference for the consumer" do
      watchers = Watchers.register(%{}, self())
      ref = watchers[self()]

      assert is_reference(ref)
      assert Watchers.watcher_ref?(watchers, self(), ref)
    end

    test "watcher_ref?/3 is false for a different reference and a different pid" do
      watchers = Watchers.register(%{}, self())
      ref = watchers[self()]
      other = parking_process()

      refute Watchers.watcher_ref?(watchers, self(), make_ref())
      refute Watchers.watcher_ref?(watchers, other, ref)
      refute Watchers.watcher_ref?(%{}, self(), ref)
    end

    test "unregister/2 is idempotent" do
      assert Watchers.unregister(%{}, self()) == %{}

      watchers = Watchers.register(%{}, self())
      emptied = Watchers.unregister(watchers, self())

      assert emptied == %{}
      assert Watchers.unregister(emptied, self()) == %{}
      refute Watchers.watching?(emptied)
    end

    test "re-registering the SAME pid replaces the ref and keeps exactly one entry" do
      first = Watchers.register(%{}, self())
      ref_before = first[self()]

      second = Watchers.register(first, self())
      ref_after = second[self()]

      assert map_size(second) == 1
      refute ref_before == ref_after
      assert Watchers.watcher_ref?(second, self(), ref_after)
      refute Watchers.watcher_ref?(second, self(), ref_before)
    end

    test "unregister_ref/3 removes the entry ONLY for the stored ref (stale :DOWN guard)" do
      watchers = Watchers.register(%{}, self())
      ref = watchers[self()]

      # A `:DOWN` from an OLDER registration must never evict a live one.
      assert Watchers.unregister_ref(watchers, self(), make_ref()) == watchers
      assert Watchers.watching?(Watchers.unregister_ref(watchers, self(), make_ref()))

      # The real ref does remove it.
      assert Watchers.unregister_ref(watchers, self(), ref) == %{}
    end

    test "cancel_timer/1 cancels the pending timer and KEEPS the buffered events" do
      ref = Process.send_after(self(), :noop, 60_000)

      batcher =
        Batcher.new()
        |> Batcher.push([{:text, "a"}, {:text, "b"}])
        |> Batcher.set_timer(ref)

      cancelled = Watchers.cancel_timer(batcher)

      assert Batcher.timer(cancelled) == nil
      assert {[{:text, "a"}, {:text, "b"}], fresh} = Batcher.take(cancelled)
      assert Batcher.empty?(fresh)

      # Best-effort cancellation: the timer is gone, so no `:noop` ever arrives.
      refute_receive :noop, 0
    end

    test "cancel_timer/1 is a no-op on a timer-less batcher" do
      batcher = Batcher.new() |> Batcher.push({:text, "kept"})

      assert Watchers.cancel_timer(batcher) == batcher
      assert Watchers.cancel_timer(Batcher.new()) == Batcher.new()
    end
  end

  describe "Watchers.flush/4 — the ONE broadcast site" do
    test "an EMPTY batch flushes nothing and returns the batcher and seq untouched" do
      agent_id = unique_agent_id()
      :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, Stream.topic(agent_id))

      # A registered watcher makes the silence attributable to EMPTINESS, not to
      # the zero-watcher gate.
      watchers = Watchers.register(%{}, self())
      batcher = Batcher.new()

      assert {^batcher, 12} = Watchers.flush(watchers, batcher, agent_id, 12)
      refute_receive {:agent_delta, _, _, _}, 0
    end

    test "a NON-empty batch with ZERO watchers is DROPPED and consumes no seq" do
      agent_id = unique_agent_id()
      :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, Stream.topic(agent_id))

      batcher = Batcher.new() |> Batcher.push({:text, "unwatched"})

      assert {%Batcher{} = drained, 7} = Watchers.flush(%{}, batcher, agent_id, 7)
      # The events are dropped, not buffered for later.
      assert Batcher.empty?(drained)
      refute_receive {:agent_delta, _, _, _}, 0
    end

    test "a watched batch publishes EXACTLY ONE delta and advances seq by exactly 1" do
      agent_id = unique_agent_id()
      :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, Stream.topic(agent_id))

      watchers = Watchers.register(%{}, self())

      batcher =
        Batcher.new()
        |> Batcher.push({:text, "hel"})
        |> Batcher.push({:text, "lo"})

      {drained, seq} = Watchers.flush(watchers, batcher, agent_id, 41)

      assert seq == 42
      assert Batcher.empty?(drained)
      assert_receive {:agent_delta, ^agent_id, 42, [{:text, "hel"}, {:text, "lo"}]}
      refute_receive {:agent_delta, _, _, _}, 0
    end
  end

  describe "Snapshot.from/2" do
    test "carries every field, the context's messages, the phase, and no ReqLLM.Context" do
      message = %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text("hi")]}
      context = ReqLLM.Context.new([message])
      usage = %Usage{input_tokens: 10, output_tokens: 2, total_tokens: 12, total_cost: 0.5}
      model_spec = %{"provider_profile_id" => "acct", "model" => "m"}

      state =
        state!(
          agent_id: unique_agent_id(),
          event_seq: 7,
          turn: 3,
          total_tokens: 42,
          usage: usage,
          mode: :interactive,
          model_spec: model_spec,
          compression_count: 2,
          context: context
        )

      snapshot = Snapshot.from(state, :running)

      assert snapshot.agent_id == state.agent_id
      assert snapshot.phase == :running
      assert snapshot.seq == 7
      assert snapshot.turn == 3
      assert snapshot.total_tokens == 42
      assert snapshot.usage == usage
      assert snapshot.messages == [message]
      assert snapshot.messages == context.messages
      assert snapshot.mode == :interactive
      assert snapshot.model_spec == model_spec
      assert snapshot.compression_count == 2
      assert snapshot.activity == %{phase: :idle, current_call: nil}

      activity = %{
        phase: :llm,
        current_call: %{id: "live-call", turn: 4, attempt: 1, text: "partial", thinking: "why"}
      }

      live_snapshot = Snapshot.from(state, :running, activity: activity)
      assert live_snapshot.activity == activity
      assert %{live_snapshot | activity: snapshot.activity} == snapshot

      # Plain JSON-clean data: no `%ReqLLM.Context{}` (the whole conversation
      # struct) is ever carried into a snapshot.
      values = snapshot |> Map.from_struct() |> Map.values()
      refute Enum.any?(values, &match?(%ReqLLM.Context{}, &1))
    end

    test "a context that is not a messages map yields messages == []" do
      state = state!(agent_id: unique_agent_id(), context: %{})

      assert Snapshot.from(state, :awaiting_input).messages == []
    end
  end

  describe "Interrupted" do
    test "defaults to a plain \"stream interrupted\" message" do
      assert Exception.message(%Interrupted{}) == "stream interrupted"
    end

    test "renders a binary reason verbatim and an atom with inspect/1" do
      assert Exception.message(%Interrupted{reason: "boom"}) == "stream interrupted: boom"

      assert Exception.message(%Interrupted{reason: :interrupted}) ==
               "stream interrupted: :interrupted"
    end
  end

  # --- helpers ---

  defp unique_agent_id, do: @agent_id_base + System.unique_integer([:positive])

  # `%State{}` has enforced keys, so a test carries production-shaped defaults and
  # overrides only what it pins.
  defp state!(overrides) do
    struct!(
      State,
      [
        agent_id: unique_agent_id(),
        agent_module: EvoGit.Agents.Manager,
        depth: 0,
        node_path: "./",
        context: ReqLLM.Context.new([])
      ] ++ overrides
    )
  end

  # A stable second pid, so the "different pid" cases are deterministic.
  defp parking_process do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    pid
  end
end
