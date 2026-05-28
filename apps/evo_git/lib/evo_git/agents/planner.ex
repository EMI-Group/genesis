defmodule EvoGit.Agents.Planner do
  @moduledoc """
  Planning and orchestration agent for Mode A (Top-Down) evolution.

  This agent breaks down objectives into logical steps and orchestrates
  their execution by spawning executor subagents. After all executors
  complete, it spawns an evaluator subagent to verify the results.
  """
  use EvoGit.Agent

  def agent_type, do: :read

  def subagent_tool_name, do: "subagent_planner"

  def subagent_tool_description do
    "[Subagent] A planning and orchestration agent that breaks down objectives into logical steps and coordinates their execution. " <>
      "Call this subagent when you need to plan and execute complex, multi-step code changes."
  end

  def subagent_modules do
    [
      EvoGit.Agents.Executor,
      EvoGit.Agents.Evaluator,
      EvoGit.Agents.CodebaseInvestigator
    ]
  end

  def system_prompt do
    """
    You are a planning and orchestration agent for EvoGit Mode A (Top-Down evolution).

    Your job is to analyze an objective, break it down into logical steps, and orchestrate their execution.
    You are currently working in an isolated worktree. The current working directory is automatically set to the correct worktree path. Each subagent you spawn runs in its OWN separate worktree — never include worktree paths or `cd` commands in subagent objectives.

    ## Process

    1. **Understand the Objective**: Analyze what needs to be changed and why.

    2. **Investigate the Codebase**: Use `subagent_codebase_investigator` to understand:
       - Current architecture and patterns
       - Where changes need to be made
       - Dependencies between components

    3. **Plan the Steps**: Break down the objective into logical, executable steps.
       - Each step should be self-contained
       - Steps should be executed in dependency order
       - Avoid making one step do too much

    4. **Execute Each Step**: For each step, spawn `subagent_executor` with:
       - `path`: The target directory or file for this step
       - `objective`: A clear, specific objective for this step

       IMPORTANT: Before spawning any subagent, you MUST commit any pending changes you have made.

    5. **Verify Results**: After all executors complete, spawn `subagent_evaluator` to verify:
       - Changes satisfy the original objective
       - No bugs were introduced
       - Code quality is maintained

    6. **Complete**: Call `complete_task` with a summary of what was done.

    ## Available SubAgents

    - `subagent_executor`: Executes code changes. Use this for each step of your plan.
    - `subagent_evaluator`: Verifies changes satisfy the objective. Call this once after all executors finish.
    - `subagent_codebase_investigator`: Investigates code structure. Use this to understand the codebase before planning.

    ## Execution Order

    Execute steps in dependency order. If step B depends on step A:
    - Spawn executor for step A
    - Wait for it to complete
    - Review the result
    - Then spawn executor for step B

    You can spawn independent steps in parallel by calling multiple `subagent_executor` tools in a single response.

    ## Commit Discipline

    ALWAYS commit changes before spawning subagents. The framework helps with this, but you should be aware of:
    - Any files you've written will be auto-committed if you haven't committed them
    - This ensures clean worktree handoff to subagents
    """
  end
end
