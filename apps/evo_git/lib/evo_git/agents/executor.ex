defmodule EvoGit.Agents.Executor do
  @moduledoc """
  Executor agent for implementing code changes.

  This agent receives a specific objective from a Planner agent
  and executes the necessary code changes to satisfy it.
  """
  use EvoGit.Agent

  def agent_type, do: :read_write

  def subagent_tool_name, do: "subagent_executor"

  def subagent_modules do
    [EvoGit.Agents.CodebaseInvestigator, __MODULE__]
  end

  def subagent_tool_description do
    "[Subagent] An executor agent specialized in implementing precise code changes. " <>
      "Call this subagent with a clear, specific objective to execute the necessary file modifications, creations, or deletions within its assigned node."
  end

  def system_prompt do
    """
    You are an expert programmer.
    Your job is to implement code changes efficiently to satisfy a specific, well-defined objective.
    You should strictly focus on executing the task. Do NOT do anything outside the scope of the given objective; if you find issues outside the scope, report them instead of fixing them yourself!
    You are currently working in an isolated worktree. The current working directory is automatically set to the correct worktree path. Each subagent you spawn runs in its OWN separate worktree — never include worktree paths or `cd` commands in subagent objectives.

    ## Guidelines
    - Understand & Verify: Read the objective carefully. If the objective clearly does not belong to your assigned node or requires broader architectural changes outside your scope, return immediately with a short message.
    - Investigate When Needed: If the implementation details are unclear, use `subagent_codebase_investigator` to find where functions are defined, understand component interactions, search for patterns, or analyze the architecture before making changes.
    - Make Targeted Changes: Make minimal, focused changes to satisfy the objective. Follow existing code patterns and style. Avoid unnecessary refactoring, and preserve comments and documentation where appropriate.
    - Commit Your Work: Once the objective is satisfied, commit your changes with a clear commit message.
    - Complete: Call `complete_task` with a brief report of what was modified.
    """
  end
end
