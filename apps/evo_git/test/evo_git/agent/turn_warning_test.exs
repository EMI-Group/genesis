defmodule EvoGit.Agent.TurnWarningTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.TurnWarning

  describe "current_level/2" do
    test "returns :none at turn 0" do
      assert TurnWarning.current_level(0, 128) == :none
    end

    test "returns :nudge at ~25% for large budgets" do
      assert TurnWarning.current_level(32, 128) == :nudge
    end

    test "returns :accelerate at ~50% for large budgets" do
      assert TurnWarning.current_level(64, 128) == :accelerate
    end

    test "returns :near_limit when turns_remaining hits adaptive threshold" do
      # 128-turn budget: near_limit fires at 10 turns remaining (turn 118)
      assert TurnWarning.current_level(118, 128) == :near_limit
      assert TurnWarning.current_level(117, 128) == :accelerate
    end

    test "returns :critical when turns_remaining hits critical threshold" do
      # 128-turn budget: critical fires at 3 turns remaining (turn 125)
      assert TurnWarning.current_level(125, 128) == :critical
      assert TurnWarning.current_level(124, 128) == :near_limit
    end
  end

  describe "current_level/2 adaptive countdown" do
    test "64-turn budget uses same 10-turn near-limit" do
      # div(64, 6) = 10, so near_remaining = min(10, max(3, 10)) = 10
      assert TurnWarning.current_level(54, 64) == :near_limit  # 10 remaining
      assert TurnWarning.current_level(53, 64) == :accelerate
    end

    test "16-turn budget compresses near-limit to 3 turns" do
      # div(16, 6) = 2, so near_remaining = min(10, max(3, 2)) = 3
      assert TurnWarning.current_level(13, 16) == :near_limit  # 3 remaining
      assert TurnWarning.current_level(12, 16) == :accelerate
    end

    test "small budget (8 turns) skips nudge/accelerate" do
      # div(8, 6) = 1, near_remaining = min(10, max(3, 1)) = 3
      # At turn 5, turns_remaining = 3, so near_limit fires before nudge (turn 6)
      assert TurnWarning.current_level(5, 8) == :near_limit
      assert TurnWarning.current_level(0, 8) == :none
    end
  end

  describe "current_level/2 minimum floors" do
    test "nudge does not fire before minimum turn floor" do
      # For max_turns=16, 25% = turn 4, but floor is 6
      assert TurnWarning.current_level(4, 16) == :none
      assert TurnWarning.current_level(6, 16) == :nudge
    end

    test "accelerate does not fire before minimum turn floor" do
      # For max_turns=16, 50% = turn 8, floor is 8 — boundary
      assert TurnWarning.current_level(7, 16) == :nudge
      assert TurnWarning.current_level(8, 16) == :accelerate
    end
  end

  describe "check/3 escalation" do
    test "returns {:ok, warning} when escalating to a new level" do
      assert {:ok, warning} = TurnWarning.check(32, 128, :none)
      assert warning.level == :nudge
      assert warning.turn == 32
      assert warning.turns_remaining == 96
      assert warning.max_turns == 128
      assert warning.percent_used == 25
    end

    test "returns :none when at same level as last warned" do
      assert :none = TurnWarning.check(33, 128, :nudge)
      assert :none = TurnWarning.check(50, 128, :nudge)
    end

    test "returns :none when last level is higher" do
      # If already at :near_limit, nudge/accelerate won't re-fire
      assert :none = TurnWarning.check(32, 128, :near_limit)
    end

    test "escalates through all levels in sequence for 128-turn budget" do
      assert {:ok, w1} = TurnWarning.check(32, 128, :none)
      assert w1.level == :nudge

      assert :none = TurnWarning.check(33, 128, :nudge)

      assert {:ok, w2} = TurnWarning.check(64, 128, :nudge)
      assert w2.level == :accelerate

      assert {:ok, w3} = TurnWarning.check(118, 128, :accelerate)
      assert w3.level == :near_limit

      assert {:ok, w4} = TurnWarning.check(125, 128, :near_limit)
      assert w4.level == :critical
    end

    test "returns :none when no level applies" do
      assert :none = TurnWarning.check(0, 128, :none)
      assert :none = TurnWarning.check(5, 128, :none)
    end
  end

  describe "message/1" do
    test "nudge message includes turn count and turns remaining" do
      {:ok, warning} = TurnWarning.check(32, 128, :none)
      msg = TurnWarning.message(warning)
      assert msg =~ "[NOTICE]"
      assert msg =~ "Turn 32/128"
      assert msg =~ "96 turns remaining"
      assert msg =~ "subagent"
    end

    test "accelerate message includes halfway context" do
      {:ok, warning} = TurnWarning.check(64, 128, :nudge)
      msg = TurnWarning.message(warning)
      assert msg =~ "[NOTICE]"
      assert msg =~ "Turn 64/128"
      assert msg =~ "64 turns remaining"
      assert msg =~ "halfway"
    end

    test "near_limit message conveys urgency and wrap-up instructions" do
      {:ok, warning} = TurnWarning.check(118, 128, :accelerate)
      msg = TurnWarning.message(warning)
      assert msg =~ "[WARNING]"
      assert msg =~ "Turn 118/128"
      assert msg =~ "10 turns remaining"
      assert msg =~ "complete_task"
    end

    test "critical message is urgent" do
      {:ok, warning} = TurnWarning.check(125, 128, :near_limit)
      msg = TurnWarning.message(warning)
      assert msg =~ "[URGENT]"
      assert msg =~ "Turn 125/128"
      assert msg =~ "3 turns remaining"
      assert msg =~ "complete_task"
    end

    test "uses singular 'turn' when 1 turn remaining" do
      {:ok, warning} = TurnWarning.check(127, 128, :near_limit)
      msg = TurnWarning.message(warning)
      assert msg =~ "1 turn remaining"
      refute msg =~ "1 turns remaining"
    end
  end
end
