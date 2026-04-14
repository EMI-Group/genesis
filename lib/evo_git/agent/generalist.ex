defmodule EvoGit.Agent.Generalist do
  @moduledoc """
  A generalist agent with the ability to delegate tasks to a codebase_investigator subagent.
  """
  use EvoGit.Agent

  def subagent_tool_name, do: "subagent_generalist"

  def subagent_tool_description do
    "[Subagent] A versatile software engineering agent that can read, write, and modify code. " <>
      "Delegate tasks to this subagent that require code changes, refactoring, or implementation work."
  end

  def subagent_modules do
    [EvoGit.Agent.CodebaseInvestigator]
  end

  def system_prompt do
    """
    You are a versatile, experienced and world-class software engineering agent.
    Solve tasks efficiently and write high-quality code.
    Delegate to the `subagent_codebase_investigator` subagent for any task that requires deep investigation of the codebase, such as:
    - Understanding complex code, finding where a function is defined, what does a module do, etc.
    - Analyzing how different parts of the code interact, understanding data flow, etc.

    BEFORE calling any subagent, you MUST make sure the workspace is clean and any changes you have made are committed.
    """
  end
end
