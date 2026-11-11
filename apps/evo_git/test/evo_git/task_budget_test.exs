defmodule EvoGit.TaskBudgetTest do
  use ExUnit.Case, async: true
  alias EvoGit.{TaskBudget, AgentSpec}
  alias EvoGit.AgentScheduler.{Dispatch, State}

  test "normalizes a bounded budget and rejects unknown or invalid limits" do
    assert {:ok, budget} =
             TaskBudget.normalize(%{"max_agents" => 2, "max_duration_seconds" => 30})

    assert budget["max_agents"] == 2
    assert budget["max_depth"] == 2

    for bad <- [
          %{"max_agents" => 0},
          %{"max_depth" => -1},
          %{"max_turns" => "60"},
          %{"surprise" => 1}
        ] do
      assert {:error, _} = TaskBudget.normalize(bad)
    end
  end

  test "root phase changes cannot reset a task's cumulative agent budget" do
    {:ok, budget} = TaskBudget.normalize(%{"max_agents" => 1})

    spec = %AgentSpec{
      context_node: %EvoGit.Core.ContextNode{path: ".", repo: "/tmp"},
      phylo_node: nil,
      agent_module: EvoGit.Agents.Executor,
      objective: "next phase",
      opts: [budget: budget]
    }

    state = Map.put(%State{}, :task_budget_counts, %{"multi-phase" => 1})

    assert {:error, :task_agent_budget_exhausted} =
             Dispatch.register_agent(state, spec, nil, nil, 0, "multi-phase", 1)
  end

  test "retrying an agent cannot reset its consumed turns" do
    id = System.unique_integer([:positive]) + 2_000_000_000
    {:ok, budget} = TaskBudget.normalize(%{})

    state = %EvoGit.AgentScheduler.AgentState{
      context_node: nil,
      llm_model: nil,
      max_depth: 2,
      max_retries: 1,
      max_turns: 2,
      budget: budget
    }

    :ok = EvoGit.AgentScheduler.Store.put_agent_state(id, state)
    on_exit(fn -> EvoGit.AgentScheduler.Store.delete_agent_state(id) end)
    assert :ok = EvoGit.AgentScheduler.Store.consume_budget_turn(id)
    assert :ok = EvoGit.AgentScheduler.Store.consume_budget_turn(id)

    :ok =
      EvoGit.AgentScheduler.Store.batch_update_agent(id, turn: 0, context: nil, phylo_node: nil)

    assert {:error, :turn_budget_exhausted} = EvoGit.AgentScheduler.Store.consume_budget_turn(id)
  end

  test "registration rejects exhausted agent and depth budgets before allocating state" do
    {:ok, budget} = TaskBudget.normalize(%{"max_agents" => 1, "max_depth" => 1})

    spec = %AgentSpec{
      context_node: %EvoGit.Core.ContextNode{path: ".", repo: "/tmp"},
      phylo_node: nil,
      agent_module: EvoGit.Agents.Executor,
      objective: "work",
      opts: [budget: budget]
    }

    state = %State{task_agent_counts: %{"limited" => 1}}

    assert {:error, :task_agent_budget_exhausted} =
             Dispatch.register_agent(state, spec, nil, nil, 0, "limited", 1)

    assert {:error, :task_depth_budget_exhausted} =
             Dispatch.register_agent(%State{}, spec, nil, nil, 2, "limited", 1)

    assert state.next_agent_id == 1
  end
end
