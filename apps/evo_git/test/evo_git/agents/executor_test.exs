defmodule EvoGit.Agents.ExecutorTest do
  use ExUnit.Case, async: true

  describe "subagent_modules/0" do
    test "declares only the Investigator — never itself" do
      assert EvoGit.Agents.Executor.subagent_modules() == [EvoGit.Agents.Investigator]
    end

    test "does not expose the subagent_executor tool in its own subagent schema" do
      names = EvoGit.Agent.SubagentSchemas.tools(EvoGit.Agents.Executor)

      refute EvoGit.Agents.Executor.subagent_tool_name() in names
      assert "subagent_investigator" in names
    end

    test "still advertises subagent_tool_name/0 so other agents can delegate to it" do
      assert EvoGit.Agents.Executor.subagent_tool_name() == "subagent_executor"
    end
  end
end
