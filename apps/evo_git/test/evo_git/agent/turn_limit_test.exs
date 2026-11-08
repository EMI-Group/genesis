defmodule EvoGit.Agent.TurnLimitTest do
  @moduledoc """
  `async: true` — pure turn-limit recovery trigger/budget checks over an
  in-memory `EvoGit.Agent.LoopState`; no shared/global state is touched.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent
  alias EvoGit.Agent.LoopState

  # Helper to build a minimal LoopState for testing
  defp state(overrides) do
    %LoopState{
      agent_id: 1,
      agent_module: __MODULE__,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new([])
    }
    |> struct(overrides)
  end

  # Simulates the grace continue path: a turn ran and ended with
  # `{:continue, _}` (the turn did not finish the run). The continue call site
  # checks `grace_period_continue_failed?/1` and, when allowed, decrements
  # `grace_turns_remaining`. Returns `{:recovery_failed, turns_completed}` —
  # the number of grace turns that ran before the hard-stop.
  defp continue_until_fail(%LoopState{} = state, turns_completed) do
    if Agent.grace_period_continue_failed?(state) do
      {:recovery_failed, turns_completed + 1}
    else
      continue_until_fail(
        %{state | grace_turns_remaining: state.grace_turns_remaining - 1},
        turns_completed + 1
      )
    end
  end

  # ---------------------------------------------------------------------------
  # trigger_turn_limit_recovery?/1
  # ---------------------------------------------------------------------------

  describe "trigger_turn_limit_recovery?/1" do
    test "normal state (turn=0, well under limit) does not trigger recovery" do
      refute Agent.trigger_turn_limit_recovery?(state(turn: 0, max_turns: 128))
    end

    test "near limit (turn=127, max_turns=128) does not trigger recovery" do
      refute Agent.trigger_turn_limit_recovery?(state(turn: 127, max_turns: 128))
    end

    test "at limit, not in grace period triggers recovery" do
      # This is the bug entry point: turn reaches the limit and recovery fires.
      assert Agent.trigger_turn_limit_recovery?(
               state(turn: 128, max_turns: 128, in_grace_period: false)
             )
    end

    test "at limit, IN grace period does NOT trigger recovery (key fix)" do
      # THIS IS THE KEY FIX TEST: pre-fix code (without the grace period check)
      # would return `true` here, causing the infinite loop because
      # trigger_recovery sets in_grace_period=true and re-enters loop/1 where
      # the same condition re-fires. Post-fix returns `false`, breaking the cycle.
      refute Agent.trigger_turn_limit_recovery?(
               state(turn: 128, max_turns: 128, in_grace_period: true)
             )
    end

    test "over limit, in grace period does NOT trigger recovery" do
      refute Agent.trigger_turn_limit_recovery?(
               state(turn: 200, max_turns: 128, in_grace_period: true)
             )
    end

    test "over limit, not in grace period triggers recovery" do
      assert Agent.trigger_turn_limit_recovery?(
               state(turn: 200, max_turns: 128, in_grace_period: false)
             )
    end
  end

  # ---------------------------------------------------------------------------
  # grace_period_continue_failed?/1
  # ---------------------------------------------------------------------------

  describe "grace_period_continue_failed?/1" do
    test "in grace period with the default counter (0) returns true (continue fails recovery)" do
      assert Agent.grace_period_continue_failed?(state(in_grace_period: true))
    end

    test "not in grace period returns false" do
      refute Agent.grace_period_continue_failed?(state(in_grace_period: false))
    end

    test "the 3-turn budget allows the first two continues and hard-stops at 1" do
      # Turn-limit recovery grants the same 3-turn window as cancel-grace:
      # a turn that ends with a tool call merely consumes one grace turn, so a
      # budget of 1 could never fit the ONE permitted final commit PLUS the
      # tool-free report turn the completion contract requires.
      refute Agent.grace_period_continue_failed?(
               state(in_grace_period: true, grace_turns_remaining: 3)
             )

      refute Agent.grace_period_continue_failed?(
               state(in_grace_period: true, grace_turns_remaining: 2)
             )

      assert Agent.grace_period_continue_failed?(
               state(in_grace_period: true, grace_turns_remaining: 1)
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Combined scenario tests (simulate the full state-machine flow)
  # ---------------------------------------------------------------------------

  describe "combined scenarios" do
    test "hard stop with graceful completion: recovery sets in_grace_period" do
      # Simulate the flow: turn hits limit -> trigger_recovery sets
      # in_grace_period=true -> trigger_turn_limit_recovery? now returns false
      # (loop falls through to do_turn) -> if that turn ends with a plain-text
      # reply and no tool calls, the run finishes successfully.
      at_limit = state(turn: 128, max_turns: 128, in_grace_period: false)

      # The turn-limit condition fires, recovery is triggered
      assert Agent.trigger_turn_limit_recovery?(at_limit)

      # After recovery, in_grace_period is set to true
      after_recovery = %{at_limit | in_grace_period: true}

      # Now the turn-limit recovery no longer re-fires
      refute Agent.trigger_turn_limit_recovery?(after_recovery)
    end

    test "no infinite loop: two consecutive iterations with unchanged turn" do
      # This directly tests the exact scenario that caused the infinite loop.
      # First iteration: turn=128/max_turns=128/in_grace_period=false triggers
      # recovery and sets in_grace_period=true. Second iteration: the SAME turn
      # but in_grace_period=true. Before the fix, trigger_turn_limit_recovery?
      # would return true again, re-entering trigger_recovery which loops back
      # to loop/1 — an infinite cycle with no termination. After the fix, it
      # returns false so the loop falls through to do_turn.
      first_iteration = state(turn: 128, max_turns: 128, in_grace_period: false)
      assert Agent.trigger_turn_limit_recovery?(first_iteration)

      # Simulate trigger_recovery: in_grace_period set to true, turn unchanged
      second_iteration = %{first_iteration | in_grace_period: true}

      # The loop must NOT re-enter trigger_recovery on the second iteration
      refute Agent.trigger_turn_limit_recovery?(second_iteration)
    end

    test "the grace budget is strictly bounded: exactly 3 continues then a hard-stop" do
      # Entering turn-limit recovery sets `grace_turns_remaining` to the budget
      # (3). Each turn that ends with `{:continue, _}` consumes one grace turn:
      #   turn 1 ends with continue (3 > 1) → allowed, decrement to 2
      #   turn 2 ends with continue (2 > 1) → allowed, decrement to 1
      #   turn 3 ends with continue (1 <= 1) → hard-stop
      # So the window is > 1 turn but FINITE — recovery can never spin.
      assert {:recovery_failed, 3} ==
               continue_until_fail(
                 state(in_grace_period: true, grace_turns_remaining: 3),
                 0
               )

      # Sanity: the budget is not a single turn (the real report window is one
      # bounded final commit plus the tool-free report turn).
      refute Agent.grace_period_continue_failed?(
               state(in_grace_period: true, grace_turns_remaining: 3)
             )

      # The frozen struct default (0) hard-stops immediately (kept).
      assert {:recovery_failed, 1} ==
               continue_until_fail(state(in_grace_period: true), 0)
    end
  end
end
