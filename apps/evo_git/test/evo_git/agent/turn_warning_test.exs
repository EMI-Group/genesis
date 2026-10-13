defmodule EvoGit.Agent.TurnWarningTest do
  @moduledoc """
  `async: true` — pure positional/middle turn-warning level and countdown
  helpers in `EvoGit.Agent.TurnWarning`; no shared/global state is touched.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.TurnWarning

  doctest EvoGit.Agent.TurnWarning

  describe "current_positional_level/2" do
    test "returns :none at turn 0" do
      assert TurnWarning.current_positional_level(0, 128) == :none
    end

    test "returns :beginning at ~25% for large budgets" do
      # 25% of 128 = turn 32; turn 32 = 25% used, fires :beginning
      assert TurnWarning.current_positional_level(32, 128) == :beginning
      # turn 31 = 24% used, below threshold
      assert TurnWarning.current_positional_level(31, 128) == :none
    end

    test "returns :end when turns_remaining hits adaptive threshold" do
      # 128-turn budget: end fires at 10 turns remaining (turn 118)
      assert TurnWarning.current_positional_level(118, 128) == :end
    end

    test "returns :critical when turns_remaining hits critical threshold" do
      # 128-turn budget: critical fires at 5 turns remaining (turn 123)
      assert TurnWarning.current_positional_level(123, 128) == :critical
      assert TurnWarning.current_positional_level(122, 128) == :end
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
      # 10 remaining
      assert TurnWarning.current_positional_level(54, 64) == :end
    end

    test "16-turn budget compresses end to 3 turns" do
      # div(16, 6) = 2, so end_remaining = min(10, max(3, 2)) = 3
      # 3 remaining
      assert TurnWarning.current_positional_level(13, 16) == :end
    end
  end

  describe "current_positional_level/2 critical countdown" do
    test "typical 100-turn subagent budget: :critical fires at 5 turns remaining" do
      # end_remaining(100) = 10 (turn 90), critical_remaining(100) = 5 (turn 95)
      assert TurnWarning.current_positional_level(95, 100) == :critical
      assert TurnWarning.current_positional_level(94, 100) == :end
    end

    test "typical 1000-turn root budget: :critical fires at 5 turns remaining" do
      # end_remaining(1000) = 10 (turn 990), critical_remaining(1000) = 5 (turn 995)
      assert TurnWarning.current_positional_level(995, 1000) == :critical
      assert TurnWarning.current_positional_level(994, 1000) == :end
    end

    test "representative budgets: critical/end remaining counts" do
      assert remaining_at_first(:critical, 20) == 1
      assert remaining_at_first(:critical, 30) == 1
      assert remaining_at_first(:critical, 60) == 3
      assert remaining_at_first(:critical, 100) == 5
      assert remaining_at_first(:critical, 1000) == 5
      assert remaining_at_first(:critical, 128) == 5

      assert remaining_at_first(:end, 20) == 3
      assert remaining_at_first(:end, 30) == 5
      assert remaining_at_first(:end, 60) == 10
      assert remaining_at_first(:end, 100) == 10
      assert remaining_at_first(:end, 1000) == 10
    end

    test "for every budget 1..200 the :end band opens strictly before :critical" do
      for max_turns <- 1..200 do
        critical_remaining = remaining_at_first(:critical, max_turns)

        assert is_integer(critical_remaining),
               "expected a :critical band for max_turns=#{max_turns}"

        # A 1-turn budget has a single turn and cannot host a separate :end
        # band (the critical floor is 1 turn remaining); every larger budget
        # must fire :end strictly before :critical.
        if max_turns == 1 do
          assert is_nil(remaining_at_first(:end, max_turns))
        else
          end_remaining = remaining_at_first(:end, max_turns)

          assert is_integer(end_remaining),
                 "expected an :end band for max_turns=#{max_turns}"

          assert end_remaining > critical_remaining,
                 ":end must open before :critical for max_turns=#{max_turns} " <>
                   "(end_remaining=#{end_remaining}, critical_remaining=#{critical_remaining})"

          assert first_turn_for(:end, max_turns) < first_turn_for(:critical, max_turns)
        end
      end
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

      assert {:ok, w3} = TurnWarning.check_positional(123, 128, :end)
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
    test "beginning message includes turn count and delegation guidance" do
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
      # max_turns=4: critical_remaining = min(5, max(1, 0)) = 1, so turn 3 (1 remaining)
      {:ok, warning} = TurnWarning.check_positional(3, 4, :end)
      msg = TurnWarning.message(warning)
      assert msg =~ "1 turn remaining"
      refute msg =~ "1 turns remaining"
    end
  end

  describe "scaling behavior" do
    test "for max_turns=8 (small budget), middle fires at interval 15" do
      assert :none = TurnWarning.check_middle(5, 8, 14)
      assert {:ok, _} = TurnWarning.check_middle(5, 8, 15)
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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # First turn at which `level` fires for a budget (nil when it never fires).
  defp first_turn_for(level, max_turns) do
    Enum.find(0..max_turns, fn turn ->
      TurnWarning.current_positional_level(turn, max_turns) == level
    end)
  end

  # Turns remaining when `level` first fires (nil when it never fires).
  defp remaining_at_first(level, max_turns) do
    case first_turn_for(level, max_turns) do
      nil -> nil
      turn -> max_turns - turn
    end
  end
end
