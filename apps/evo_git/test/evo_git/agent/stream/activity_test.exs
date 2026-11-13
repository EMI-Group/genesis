defmodule EvoGit.Agent.Stream.ActivityTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Stream.Activity

  test "new activity is exactly idle with no current call" do
    assert Activity.new() == %{phase: :idle, current_call: nil}
  end

  test "starting a call replaces the entire previous attempt, including text and thinking" do
    first = call_activity("first", 7, 0)

    {first, [{:text, "old answer"}]} =
      Activity.apply(first, {:chunk, "first", :text, "old answer"})

    {first, [{:thinking, "old thought"}]} =
      Activity.apply(first, {:chunk, "first", :thinking, "old thought"})

    expected = call_activity("retry", 7, 1)
    assert Activity.apply(first, {:start_call, "retry", 7, 1}) == replacement(expected)

    # A nudge may restart the attempt counter, but it is still a different call.
    nudged = call_activity("nudge", 7, 0)
    assert Activity.apply(expected, {:start_call, "nudge", 7, 0}) == replacement(nudged)
  end

  test "matching text and thinking append separately and publish only the exact append event" do
    initial = call_activity("call", 2, 0)

    {activity, events} = Activity.apply(initial, {:chunk, "call", :text, "hello "})
    assert events == [{:text, "hello "}]
    assert activity == put_in(initial.current_call.text, "hello ")

    {activity, events} = Activity.apply(activity, {:chunk, "call", :thinking, "reason\n"})
    assert events == [{:thinking, "reason\n"}]

    assert activity == %{
             initial
             | current_call: %{initial.current_call | text: "hello ", thinking: "reason\n"}
           }

    {activity, events} = Activity.apply(activity, {:chunk, "call", :text, "世界"})
    assert events == [{:text, "世界"}]
    assert activity.current_call.text == "hello 世界"
    assert activity.current_call.thinking == "reason\n"
    assert Activity.apply(activity, {:chunk, "call", :text, ""}) == {activity, [{:text, ""}]}
  end

  test "every valid keyed phase emits an exact replacement, clearing only idle and retry wait" do
    initial = populated_call()

    for phase <- [:idle, :llm_waiting, :llm, :llm_complete, :retry_wait, :tools] do
      retained = if phase in [:idle, :retry_wait], do: nil, else: initial.current_call
      expected = %{phase: phase, current_call: retained}
      assert Activity.apply(initial, {:call_phase, "call", phase}) == replacement(expected)
    end
  end

  test "unkeyed phase changes preserve the call except idle, including retry wait" do
    initial = populated_call()

    for phase <- [:idle, :llm_waiting, :llm, :llm_complete, :retry_wait, :tools] do
      retained = if phase == :idle, do: nil, else: initial.current_call
      expected = %{phase: phase, current_call: retained}
      assert Activity.apply(initial, {:phase, phase}) == replacement(expected)

      empty = %{phase: phase, current_call: nil}
      assert Activity.apply(Activity.new(), {:phase, phase}) == replacement(empty)
    end
  end

  test "llm complete and tools retain the full current call and still accept matching chunks" do
    initial = populated_call()

    for phase <- [:llm_complete, :tools] do
      expected = %{initial | phase: phase}
      assert Activity.apply(initial, {:call_phase, "call", phase}) == replacement(expected)

      appended = put_in(expected.current_call.text, "answer tail")

      assert Activity.apply(expected, {:chunk, "call", :text, " tail"}) ==
               {appended, [{:text, " tail"}]}
    end
  end

  test "idle, keyed retry wait and reset retire the call so late chunks cannot resurrect it" do
    initial = populated_call()

    for event <- [
          {:phase, :idle},
          {:call_phase, "call", :idle},
          {:call_phase, "call", :retry_wait},
          :reset
        ] do
      {retired, events} = Activity.apply(initial, event)
      assert retired.current_call == nil
      assert events == [{:activity, retired}]

      for late <- [
            {:chunk, "call", :text, "late"},
            {:chunk, "call", :thinking, "late"},
            {:call_phase, "call", :llm}
          ] do
        assert Activity.apply(retired, late) == {retired, []}
      end
    end

    assert Activity.apply(initial, :reset) == replacement(Activity.new())
    assert Activity.apply(Activity.new(), :reset) == replacement(Activity.new())
  end

  test "stale call IDs cannot append or change any phase of the replacement attempt" do
    current = populated_call()

    for id <- ["previous", nil, 42],
        event <- [
          {:chunk, id, :text, "stale answer"},
          {:chunk, id, :thinking, "stale thought"},
          {:call_phase, id, :llm},
          {:call_phase, id, :idle},
          {:call_phase, id, :retry_wait}
        ] do
      assert Activity.apply(current, event) == {current, []}
      assert Activity.apply(Activity.new(), event) == {Activity.new(), []}
    end
  end

  test "invalid events leave both idle and populated projections byte-identical without public events" do
    invalid = [
      nil,
      :unknown,
      %{},
      {:start_call, nil, 1, 0},
      {:start_call, 12, 1, 0},
      {:start_call, "missing_fields"},
      {:phase, :unknown},
      {:phase, "llm"},
      {:call_phase, "call", :unknown},
      {:call_phase, "call", "llm"},
      {:chunk, "call", :unknown, "text"},
      {:chunk, "call", :text, nil},
      {:chunk, "call", :thinking, 1},
      {:chunk, "call", :text, ["not a binary"]},
      {:chunk, "call", :text}
    ]

    for initial <- [Activity.new(), populated_call()], event <- invalid do
      assert Activity.apply(initial, event) == {initial, []}
    end
  end

  defp call_activity(id, turn, attempt) do
    %{
      phase: :llm_waiting,
      current_call: %{id: id, turn: turn, attempt: attempt, text: "", thinking: ""}
    }
  end

  defp populated_call do
    %{
      call_activity("call", 3, 1)
      | current_call: %{id: "call", turn: 3, attempt: 1, text: "answer", thinking: "thought"}
    }
  end

  defp replacement(activity), do: {activity, [{:activity, activity}]}
end
