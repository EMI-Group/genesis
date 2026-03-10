defmodule EvoGit.Agent.Generalist do
  @moduledoc """
  A generalist agent with the ability to delegate tasks to a codebase_investigator subagent.
  """
  use EvoGit.Agent.Coder

  # Override available_tools to include all standard tools plus the subagent tool
  def available_tools do
    EvoGit.Agent.Tools.schemas() ++ [codebase_investigator_schema(), completion_schema()]
  end

  defp codebase_investigator_schema do
    ReqLLM.tool(
      name: "codebase_investigator",
      description:
        "A specialized agent for codebase analysis. Call this to investigate the codebase and return a comprehensive report.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "objective" => %{
            "type" => "string",
            "description" =>
              "A comprehensive and detailed description of what needs to be investigated."
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

    system_prompt =
      "You are an expert codebase investigator. Investigate thoroughly and report your findings."

    # Start the subagent synchronously. Pass the actual caller_pid so events flow directly
    case EvoGit.Agent.CodebaseInvestigator.run(query, state.caller_pid, system_prompt) do
      {:ok, result} -> result
      {:error, reason} -> "Error: Subagent failed with reason: #{inspect(reason)}"
    end
  end

  # Fallback to default behavior for all other tools
  def execute_tool(call, state) do
    super(call, state)
  end
end
