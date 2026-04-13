defmodule EvoGit.Agent.Generalist do
  @moduledoc """
  A generalist agent with the ability to delegate tasks to a codebase_investigator subagent.
  """
  use EvoGit.Agent

  # Override available_tools to include all standard tools plus the subagent tool
  def available_tools do
    EvoGit.Agent.Tools.schemas() ++ [codebase_investigator_schema(), completion_schema()]
  end

  def system_prompt do
    """
    You are a versatile, experienced and world-class software engineering agent.
    Solve tasks efficiently and write high-quality code.
    A delegate to the codebase_investigator subagent for any task that requires deep investigation of the codebase, such as:
    - Understanding complex code, finding where a function is defined, what does a module do, etc.
    - Analyzing how different parts of the code interact, understanding data flow, etc.
    """
  end

  defp codebase_investigator_schema do
    ReqLLM.tool(
      name: "codebase_investigator",
      description:
        "A specialized agent for codebase analysis. Call this agent with a query to let it investigate the codebase and return a report.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "objective" => %{
            "type" => "string",
            "description" =>
              "A clear and specific query describing what you want the codebase investigator to analyze or find out."
          }
        },
        "required" => ["objective"]
      },
      callback: fn _args -> {:ok, nil} end
    )
  end

  # Override execute_tool to handle the specific "codebase_investigator" tool call
  def execute_tool(%{name: "codebase_investigator", arguments: args}, state) do
    query = Map.get(args, "objective")

    # Route sub-agent through the scheduler so the parent is tracked as :waiting
    # and its worktree becomes reclaimable.
    [result] =
      EvoGit.AgentScheduler.spawn_sub_agents([
        fn _worktree_path ->
          case EvoGit.Agent.CodebaseInvestigator.run(query, state.caller_pid) do
            {:ok, result} -> result
            {:error, reason} -> "Error: Subagent failed with reason: #{inspect(reason)}"
          end
        end
      ])

    result
  end

  # Fallback to default behavior for all other tools
  def execute_tool(call, state) do
    super(call, state)
  end
end
