defmodule EvoGit.Agent.TurnLimitTest do
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
    test "in grace period returns true (continue fails recovery)" do
      assert Agent.grace_period_continue_failed?(state(in_grace_period: true))
    end

    test "not in grace period returns false" do
      refute Agent.grace_period_continue_failed?(state(in_grace_period: false))
    end
  end

  # ---------------------------------------------------------------------------
  # Combined scenario tests (simulate the full state-machine flow)
  # ---------------------------------------------------------------------------

  describe "combined scenarios" do
    test "hard stop with graceful completion: recovery sets in_grace_period" do
      # Simulate the flow: turn hits limit -> trigger_recovery sets
      # in_grace_period=true -> trigger_turn_limit_recovery? now returns false
      # (loop falls through to do_turn) -> if LLM calls complete_task, loop
      # terminates successfully.
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

    test "grace period is bounded to one turn" do
      # After entering grace period, a continue outcome fails recovery
      # immediately. This means the agent gets exactly one grace turn —
      # it must call complete_task, not other tools.
      in_grace = state(in_grace_period: true)

      # A {:continue, _} outcome during grace period fails recovery
      assert Agent.grace_period_continue_failed?(in_grace)
    end
  end
end
