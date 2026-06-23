defmodule EvoGit.Agent.TurnWarningTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.TurnWarning

  describe "current_positional_level/2" do
    test "returns :none at turn 0" do
      assert TurnWarning.current_positional_level(0, 128) == :none
    end

    test "returns :beginning at ~15% for large budgets" do
      # 15% of 128 = turn ~19.2; turn 20 = 15% used, fires :beginning
      assert TurnWarning.current_positional_level(20, 128) == :beginning
      # turn 19 = 14% used, below threshold
      assert TurnWarning.current_positional_level(19, 128) == :none
    end

    test "returns :end when turns_remaining hits adaptive threshold" do
      # 128-turn budget: end fires at 10 turns remaining (turn 118)
      assert TurnWarning.current_positional_level(118, 128) == :end
    end

    test "returns :critical when turns_remaining hits critical threshold" do
      # 128-turn budget: critical fires at 3 turns remaining (turn 125)
      assert TurnWarning.current_positional_level(125, 128) == :critical
      assert TurnWarning.current_positional_level(124, 128) == :end
    end

    test "small budget (8 turns) skips beginning, goes straight to :end" do
      # div(8, 6) = 1, end_remaining = min(10, max(3, 1)) = 3
      # At turn 5, turns_remaining = 3, so :end fires before :beginning (turn 6)
      assert TurnWarning.current_positional_level(5, 8) == :end
      assert TurnWarning.current_positional_level(0, 8) == :none
    end

    test "beginning does not fire before minimum turn floor" do
      # For max_turns=16, 25% = turn 4, but floor is 6
      assert TurnWarning.current_positional_level(4, 16) == :none
      assert TurnWarning.current_positional_level(6, 16) == :beginning
    end
  end

  describe "current_positional_level/2 adaptive countdown" do
    test "64-turn budget uses same 10-turn end threshold" do
      # div(64, 6) = 10, so end_remaining = min(10, max(3, 10)) = 10
      assert TurnWarning.current_positional_level(54, 64) == :end  # 10 remaining
    end

    test "16-turn budget compresses end to 3 turns" do
      # div(16, 6) = 2, so end_remaining = min(10, max(3, 2)) = 3
      assert TurnWarning.current_positional_level(13, 16) == :end  # 3 remaining
    end
  end

  describe "check_positional/3" do
    test "returns {:ok, warning} when escalating to a new level" do
      assert {:ok, warning} = TurnWarning.check_positional(32, 128, :none)
      assert warning.level == :beginning
      assert warning.turn == 32
      assert warning.turns_remaining == 96
      assert warning.max_turns == 128
      assert warning.percent_used == 25
    end

    test "returns :none when at same level" do
      assert :none = TurnWarning.check_positional(33, 128, :beginning)
      assert :none = TurnWarning.check_positional(50, 128, :beginning)
    end

    test "returns :none when last level is higher" do
      # If already at :end, :beginning won't re-fire
      assert :none = TurnWarning.check_positional(32, 128, :end)
    end

    test "escalates through beginning → end → critical in sequence for 128-turn budget" do
      assert {:ok, w1} = TurnWarning.check_positional(32, 128, :none)
      assert w1.level == :beginning

      assert :none = TurnWarning.check_positional(33, 128, :beginning)

      assert {:ok, w2} = TurnWarning.check_positional(118, 128, :beginning)
      assert w2.level == :end

      assert {:ok, w3} = TurnWarning.check_positional(125, 128, :end)
      assert w3.level == :critical
    end

    test "returns :none when no level applies" do
      assert :none = TurnWarning.check_positional(0, 128, :none)
      assert :none = TurnWarning.check_positional(5, 128, :none)
    end
  end

  describe "check_middle/3" do
    test "returns :none when turns_since_subagent < 15" do
      assert :none = TurnWarning.check_middle(10, 128, 0)
      assert :none = TurnWarning.check_middle(10, 128, 5)
      assert :none = TurnWarning.check_middle(10, 128, 14)
    end

    test "returns {:ok, warning} when turns_since_subagent >= 15" do
      assert {:ok, warning} = TurnWarning.check_middle(20, 128, 15)
      assert warning.level == :middle
      assert warning.turn == 20
      assert warning.turns_since_subagent == 15
    end

    test "warning includes turns_since_subagent in the struct" do
      assert {:ok, warning} = TurnWarning.check_middle(30, 128, 20)
      assert warning.turns_since_subagent == 20
      assert warning.level == :middle
      refute is_nil(warning.turns_since_subagent)
    end

    test "can fire repeatedly (no monotonic blocking)" do
      # Calling check_middle twice with the same turns_since_subagent both return {:ok, ...}
      assert {:ok, _} = TurnWarning.check_middle(20, 128, 15)
      assert {:ok, _} = TurnWarning.check_middle(21, 128, 15)
      assert {:ok, _} = TurnWarning.check_middle(22, 128, 15)
    end

    test "returns :none at turn 0" do
      assert :none = TurnWarning.check_middle(0, 128, 15)
    end
  end

  describe "message/1" do
    test "beginning message includes turn count, percent, and delegation guidance" do
      {:ok, warning} = TurnWarning.check_positional(32, 128, :none)
      msg = TurnWarning.message(warning)
      assert msg =~ "[NOTICE]"
      assert msg =~ "Turn 32/128"
      assert msg =~ "25% used"
      assert msg =~ "96 turns remaining"
      assert msg =~ "routing table"
      assert msg =~ "subagent"
    end

    test "middle message includes turns_since_subagent and delegation reminder" do
      {:ok, warning} = TurnWarning.check_middle(30, 128, 20)
      msg = TurnWarning.message(warning)
      assert msg =~ "[NOTICE]"
      assert msg =~ "Turn 30/128"
      assert msg =~ "20 turns have passed"
      assert msg =~ "delegate"
    end

    test "end message includes urgency, wrap-up steps, and suggestions" do
      {:ok, warning} = TurnWarning.check_positional(118, 128, :beginning)
      msg = TurnWarning.message(warning)
      assert msg =~ "[WARNING]"
      assert msg =~ "Turn 118/128"
      assert msg =~ "10 turns remaining"
      assert msg =~ "wrapping up"
      assert msg =~ "complete_task"
    end

    test "critical message is urgent and mentions complete_task" do
      {:ok, warning} = TurnWarning.check_positional(125, 128, :end)
      msg = TurnWarning.message(warning)
      assert msg =~ "[URGENT]"
      assert msg =~ "Turn 125/128"
      assert msg =~ "3 turns remaining"
      assert msg =~ "complete_task"
      assert msg =~ "IMMEDIATELY"
    end

    test "uses singular 'turn' when 1 turn remaining" do
      # max_turns=4: critical_remaining = min(3, max(1, 0)) = 1, so turn 3 (1 remaining)
      {:ok, warning} = TurnWarning.check_positional(3, 4, :end)
      msg = TurnWarning.message(warning)
      assert msg =~ "1 turn remaining"
      refute msg =~ "1 turns remaining"
    end
  end

  describe "scaling behavior" do
    test "for max_turns=8 (small budget), middle never fires" do
      # turns_since_subagent can't reach 15 since max_turns is only 8
      assert :none = TurnWarning.check_middle(5, 8, 14)
    end

    test "for max_turns=128 (large budget), middle fires multiple times if counter keeps growing" do
      # First fire at 15
      assert {:ok, w1} = TurnWarning.check_middle(16, 128, 15)
      assert w1.turns_since_subagent == 15

      # After reset (0) and growing again to 15
      assert {:ok, w2} = TurnWarning.check_middle(32, 128, 15)
      assert w2.turns_since_subagent == 15

      # And again at 30 (if somehow not reset)
      assert {:ok, w3} = TurnWarning.check_middle(48, 128, 30)
      assert w3.turns_since_subagent == 30
    end
  end

  describe "low delegation level behavior" do
    test ":low agents never get :beginning level" do
      assert TurnWarning.current_positional_level(32, 128, :low) == :none
    end

    test ":low agents need turns_since_subagent >= 45 for middle to fire" do
      assert :none = TurnWarning.check_middle(20, 128, 44, :low)
      assert {:ok, _} = TurnWarning.check_middle(50, 128, 45, :low)
    end

    test ":low agents still get :end" do
      assert {:ok, warning} = TurnWarning.check_positional(118, 128, :none, :low)
      assert warning.level == :end
    end

    test ":low agents still get :critical" do
      assert {:ok, warning} = TurnWarning.check_positional(125, 128, :none, :low)
      assert warning.level == :critical
    end

    test ":low agents: check_positional(32, 128, :none, :low) returns :none (beginning suppressed)" do
      assert :none = TurnWarning.check_positional(32, 128, :none, :low)
    end
  end
end
