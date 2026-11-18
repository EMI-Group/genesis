defmodule EvoGit.AgentState.PauseDurabilityTest do
  @moduledoc """
  The paused outcome's HONEST durability verdict.

  `EvoGit.Agent.Session.Pause` only claims `durable: true` when the writer's
  `flush/1` answered `:ok`; every belt-and-braces path (a killed finalizer, an
  aborted exchange worker) builds its payload through `Pause.info/3`, which
  defaults to `durable: false`. There is no database and no global state here —
  hence `async: true`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Session.Pause
  alias EvoGit.Agent.State

  @state %State{
    agent_id: 7,
    task_id: "task-pause-durable",
    agent_module: EvoGit.Agents.SelfReflective,
    depth: 0,
    node_path: "./",
    context: nil
  }

  test "info/3 defaults to durable: false (the paths that never flush)" do
    info = Pause.info(@state, "abc123", "genesis/agent_1")

    assert info.agent_id == 7
    assert info.task_id == "task-pause-durable"
    assert info.checkpoint == "abc123"
    assert info.branch == "genesis/agent_1"
    assert info.durable == false
    assert info.reason == :task_pause
  end

  test "info/4 carries the writer's verdict" do
    assert Pause.info(@state, "abc123", "genesis/agent_1", true).durable == true
    assert Pause.info(@state, "abc123", "genesis/agent_1", false).durable == false
    # Only a literal `true` may claim durability.
    assert Pause.info(@state, nil, nil, :ok).durable == false
  end
end
