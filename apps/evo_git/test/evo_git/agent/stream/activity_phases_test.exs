defmodule EvoGit.Agent.Stream.ActivityPhasesTest do
  @moduledoc """
  Live-activity PHASE coverage for the pure `EvoGit.Agent.Stream.Activity` projection.

  Pure reducer: no scheduler, no session, no ETS row and no app-env write, so the
  module is async-safe. Phase events publish EXACTLY ONE `{:activity, projection}`
  replacement; a retire phase additionally drops the current call so a late chunk
  from the retired attempt cannot resurrect it.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Stream.Activity

  @phases [
    :idle,
    :llm_waiting,
    :llm,
    :llm_complete,
    :retry_wait,
    :tools,
    :compressing,
    :preparing
  ]

  @phase_retire [:idle, :compressing, :preparing]
  @call_phase_retire [:idle, :retry_wait, :compressing, :preparing]

  test "an unkeyed compressing phase retires the populated call and emits one replacement" do
    initial = populated()

    expected = %{phase: :compressing, current_call: nil}
    assert Activity.apply(initial, {:phase, :compressing}) == {expected, [{:activity, expected}]}
  end

  test "an unkeyed preparing phase retires the populated call and emits one replacement" do
    initial = populated()

    expected = %{phase: :preparing, current_call: nil}
    assert Activity.apply(initial, {:phase, :preparing}) == {expected, [{:activity, expected}]}
  end

  test "keyed compressing and preparing phases retire the matching call exactly" do
    initial = populated()

    for phase <- [:compressing, :preparing] do
      expected = %{phase: phase, current_call: nil}

      assert Activity.apply(initial, {:call_phase, "call", phase}) ==
               {expected, [{:activity, expected}]}
    end
  end

  test "stale ids, late chunks and unknown phases leave the populated projection untouched" do
    initial = populated()

    for event <- [
          {:call_phase, "other", :compressing},
          {:call_phase, "other", :preparing},
          {:chunk, "gone", :text, "x"},
          {:phase, :compressingg}
        ] do
      assert Activity.apply(initial, event) == {initial, []}
    end
  end

  test "every phase is accepted by both phase events with their own retire sets" do
    initial = populated()

    for phase <- @phases do
      retained = if phase in @phase_retire, do: nil, else: initial.current_call
      expected = %{phase: phase, current_call: retained}
      assert Activity.apply(initial, {:phase, phase}) == replacement(expected)

      retained = if phase in @call_phase_retire, do: nil, else: initial.current_call
      expected = %{phase: phase, current_call: retained}

      assert Activity.apply(initial, {:call_phase, "call", phase}) ==
               replacement(expected)
    end
  end

  test "reset on a populated projection replaces the whole projection with a new one" do
    initial = populated()

    assert Activity.apply(initial, :reset) == {Activity.new(), [{:activity, Activity.new()}]}
  end

  test "a retired call cannot be resurrected by a late chunk after compressing or preparing" do
    initial = populated()

    for phase <- [:compressing, :preparing] do
      {retired, [{:activity, published}]} = Activity.apply(initial, {:phase, phase})
      assert published == retired
      assert retired == %{phase: phase, current_call: nil}

      assert Activity.apply(retired, {:chunk, "call", :text, "late"}) == {retired, []}
      assert Activity.apply(retired, {:chunk, "call", :thinking, "late"}) == {retired, []}
      assert Activity.apply(retired, {:call_phase, "call", :llm}) == {retired, []}
    end
  end

  defp populated do
    %{
      phase: :llm,
      current_call: %{
        id: "call",
        turn: 3,
        attempt: 1,
        text: "answer",
        thinking: "thought",
        checkpointed: false
      }
    }
  end

  defp replacement(activity), do: {activity, [{:activity, activity}]}
end
