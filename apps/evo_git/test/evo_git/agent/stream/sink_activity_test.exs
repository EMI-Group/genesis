defmodule EvoGit.Agent.Stream.SinkActivityTest do
  @moduledoc """
  Process-local Sink contracts composed with the pure Activity reducer.
  The [0, 1, 0] attempt sequence models retry/nudge identities only; these
  tests do not exercise LLMPrompting's actual retry or nudge wiring.
  No session, watcher, scheduler, network or global configuration is used.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Stream.{Activity, Interrupted, Sink}

  setup do
    Sink.uninstall()
    :ok
  end

  test "without installation every emission is inert and callbacks are absent" do
    refute Sink.installed?()
    assert Sink.stream_opts() == []
    assert :ok = Sink.start_turn(9)
    id = Sink.start_call(0)
    assert is_binary(id)
    assert byte_size(id) > 0
    assert :ok = Sink.call_phase(id, :llm)
    assert :ok = Sink.phase(:tools)
    assert :ok = Sink.reset()
    assert :ok = Sink.emit({:text, "ignored"})
    assert :ok = Sink.uninstall()
    refute_received _
  end

  test "fresh string IDs survive attempt counter restarts and capture the current turn" do
    assert :ok = Sink.install(self(), :agent)
    assert :ok = Sink.start_turn(11)
    assert take_activity() == :reset

    ids =
      for attempt <- [0, 1, 0] do
        id = Sink.start_call(attempt)
        assert is_binary(id)
        assert byte_size(id) > 0
        assert take_activity() == {:start_call, id, 11, attempt}
        id
      end

    assert MapSet.size(MapSet.new(ids)) == 3

    assert :ok = Sink.start_turn(12)
    assert take_activity() == :reset
    next = Sink.start_call(0)
    refute next in ids
    assert take_activity() == {:start_call, next, 12, 0}
    refute_received _
  end

  test "an installed sink captures binary text and thinking without any watcher" do
    assert :ok = Sink.install(self(), :agent)
    id = Sink.start_call(0)
    assert take_activity() == {:start_call, id, 0, 0}
    initial = started(id, 0, 0)
    opts = Sink.stream_opts()

    assert Keyword.keys(opts) == [:on_result, :on_thinking, :on_tool_call, :on_chunk]
    assert Enum.all?(opts, fn {_name, callback} -> is_function(callback, 1) end)

    assert :ok = opts[:on_result].("answer\n")
    assert :ok = opts[:on_thinking].("thinking 世界")
    assert take_activity() == {:chunk, id, :text, "answer\n"}
    assert take_activity() == {:chunk, id, :thinking, "thinking 世界"}

    assert Activity.apply(initial, {:chunk, id, :text, "answer\n"}) ==
             {put_in(initial.current_call.text, "answer\n"), [{:text, "answer\n"}]}

    assert :ok = opts[:on_chunk].(%{})
    interrupt = make_ref()
    send(self(), {:evogit_interrupt, interrupt})
    assert_raise Interrupted, fn -> opts[:on_chunk].(%{}) end
    assert :ok = opts[:on_chunk].(%{})
    refute Sink.interrupt_requested?()
    refute_received _
  end

  test "A callback closures retain session, worker and call identity after B starts" do
    assert :ok = Sink.install(self(), :agent)
    Sink.start_turn(4)
    assert take_activity() == :reset
    a = Sink.start_call(0)
    assert take_activity() == {:start_call, a, 4, 0}
    a_opts = Sink.stream_opts()

    b = Sink.start_call(1)
    assert take_activity() == {:start_call, b, 4, 1}
    refute a == b
    b_opts = Sink.stream_opts()
    current = started(b, 4, 1)

    # Invoke A in a different process with no installed sink. The envelope must
    # still name the original worker, not this callback invocation process.
    task =
      Task.async(fn ->
        refute Sink.installed?()
        assert :ok = a_opts[:on_result].("late A text")
        assert :ok = a_opts[:on_thinking].("late A thought")
      end)

    Task.await(task)

    assert take_activity() == {:chunk, a, :text, "late A text"}
    assert take_activity() == {:chunk, a, :thinking, "late A thought"}

    for event <- [
          {:chunk, a, :text, "late A text"},
          {:chunk, a, :thinking, "late A thought"}
        ] do
      assert Activity.apply(current, event) == {current, []}
    end

    # Sink forwards stale keyed phases, but must not retire B's local identity.
    for phase <- [:llm, :idle, :retry_wait, :llm_complete, :tools] do
      assert :ok = Sink.call_phase(a, phase)
      event = take_activity()
      assert event == {:call_phase, a, phase}
      assert Activity.apply(current, event) == {current, []}
    end

    assert :ok = Sink.stream_opts()[:on_result].("B text")
    event = take_activity()
    assert event == {:chunk, b, :text, "B text"}
    {current, [{:text, "B text"}]} = Activity.apply(current, event)

    assert :ok = b_opts[:on_thinking].("B thought")
    event = take_activity()
    assert event == {:chunk, b, :thinking, "B thought"}
    {current, [{:thinking, "B thought"}]} = Activity.apply(current, event)

    assert :ok = Sink.call_phase(b, :llm_complete)
    event = take_activity()
    assert event == {:call_phase, b, :llm_complete}

    expected = %{
      phase: :llm_complete,
      current_call: %{id: b, turn: 4, attempt: 1, text: "B text", thinking: "B thought"}
    }

    assert Activity.apply(current, event) == {expected, [{:activity, expected}]}
    refute_received _
  end

  test "keyed retry wait, idle, reset and turn reset retire local callback identity" do
    assert :ok = Sink.install(self(), :agent)

    for retirement <- [:retry_wait, :idle, :phase_idle, :reset, :next_turn] do
      id = Sink.start_call(0)
      {:start_call, ^id, turn, 0} = take_activity()
      current = started(id, turn, 0)
      old_opts = Sink.stream_opts()

      expected_event =
        case retirement do
          phase when phase in [:retry_wait, :idle] ->
            assert :ok = Sink.call_phase(id, phase)
            {:call_phase, id, phase}

          :phase_idle ->
            assert :ok = Sink.phase(:idle)
            {:phase, :idle}

          :reset ->
            assert :ok = Sink.reset()
            :reset

          :next_turn ->
            assert :ok = Sink.start_turn(8)
            :reset
        end

      assert take_activity() == expected_event
      {retired, [{:activity, public}]} = Activity.apply(current, expected_event)
      assert public == retired
      assert retired.current_call == nil
      assert retired.phase == if(retirement == :retry_wait, do: :retry_wait, else: :idle)

      # Existing closures keep their old ID; newly captured callbacks have none.
      assert :ok = old_opts[:on_result].("old")
      assert take_activity() == {:chunk, id, :text, "old"}
      assert :ok = Sink.stream_opts()[:on_result].("unbound")
      assert take_activity() == {:chunk, nil, :text, "unbound"}
      assert Activity.apply(retired, {:chunk, id, :text, "old"}) == {retired, []}
      assert Activity.apply(retired, {:chunk, nil, :text, "unbound"}) == {retired, []}
    end

    refute_received _
  end

  test "reinstallation clears call, turn and interrupts; uninstall is idempotent" do
    assert :ok = Sink.install(self(), :first_agent)
    Sink.start_turn(19)
    assert take_activity() == :reset
    old = Sink.start_call(3)
    assert take_activity() == {:start_call, old, 19, 3}
    send(self(), {:evogit_interrupt, make_ref()})
    send(self(), {:evogit_interrupt, make_ref()})

    assert :ok = Sink.install(self(), :second_agent)
    assert Sink.installed?()
    refute Sink.interrupt_requested?()
    assert :ok = Sink.stream_opts()[:on_thinking].("no call")
    assert take_activity() == {:chunk, nil, :thinking, "no call"}

    fresh = Sink.start_call(0)
    refute fresh == old
    assert take_activity() == {:start_call, fresh, 0, 0}
    assert :ok = Sink.uninstall()
    assert :ok = Sink.uninstall()
    refute Sink.installed?()
    assert Sink.stream_opts() == []
    assert :ok = Sink.reset()
    refute_received _
  end

  test "non-retiring phases retain the Sink call identity and exact reducer projection" do
    Sink.install(self(), :agent)
    id = Sink.start_call(0)
    assert take_activity() == {:start_call, id, 0, 0}
    initial = started(id, 0, 0)

    for phase <- [:llm_waiting, :llm, :llm_complete, :tools] do
      assert :ok = Sink.call_phase(id, phase)
      event = take_activity()
      assert event == {:call_phase, id, phase}
      expected = %{initial | phase: phase}
      assert Activity.apply(initial, event) == {expected, [{:activity, expected}]}

      assert :ok = Sink.phase(phase)
      event = take_activity()
      assert event == {:phase, phase}
      assert Activity.apply(initial, event) == {expected, [{:activity, expected}]}

      assert :ok = Sink.stream_opts()[:on_result].("still bound")
      assert take_activity() == {:chunk, id, :text, "still bound"}
    end

    refute_received _
  end

  test "malformed callback chunks and invalid phases are forwarded but rejected by Activity" do
    Sink.install(self(), :agent)
    id = Sink.start_call(0)
    assert take_activity() == {:start_call, id, 0, 0}
    current = started(id, 0, 0)
    opts = Sink.stream_opts()

    for {callback, kind} <- [{:on_result, :text}, {:on_thinking, :thinking}],
        chunk <- [nil, 42, %{text: "not a binary"}, ["not a binary"]] do
      assert :ok = opts[callback].(chunk)
      event = take_activity()
      assert event == {:chunk, id, kind, chunk}
      assert Activity.apply(current, event) == {current, []}
    end

    assert :ok = Sink.call_phase(id, :unknown)
    event = take_activity()
    assert event == {:call_phase, id, :unknown}
    assert Activity.apply(current, event) == {current, []}
    assert :ok = Sink.phase(:unknown)
    event = take_activity()
    assert event == {:phase, :unknown}
    assert Activity.apply(current, event) == {current, []}
    refute_received _
  end

  test "tool declarations remain legacy unkeyed deltas rather than activity chunks" do
    Sink.install(self(), :agent)
    id = Sink.start_call(0)
    assert take_activity() == {:start_call, id, 0, 0}
    opts = Sink.stream_opts()
    assert :ok = opts[:on_tool_call].(%{name: "read", id: "provider-id"})
    assert_received {:delta, [{:tool_call, nil, "read"}]}
    refute_received _
  end

  defp take_activity do
    worker = self()
    assert_received {:activity, ^worker, event}
    event
  end

  defp started(id, turn, attempt) do
    {activity, events} = Activity.apply(Activity.new(), {:start_call, id, turn, attempt})
    assert events == [{:activity, activity}]
    activity
  end
end
