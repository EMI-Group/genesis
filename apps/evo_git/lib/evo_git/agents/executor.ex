defmodule EvoGit.Agents.Executor do
  @moduledoc """
  Executor agent for implementing code changes.

  This agent receives a specific objective from a manager or higher-level agent
  and executes the necessary code changes to satisfy it.
  """
  use EvoGit.Agent

  alias EvoGit.Agents.PromptFragments

  def agent_type, do: :read_write
  def delegation_level, do: :low

  def subagent_tool_name, do: "subagent_executor"

  def subagent_modules do
    [EvoGit.Agents.CodebaseInvestigator, __MODULE__]
  end

  def subagent_tool_description do
    "[Subagent] An executor agent specialized in implementing precise code changes. " <>
      "Call this subagent with a clear, specific objective to execute the necessary file modifications, creations, or deletions within its assigned node. " <>
      "The executor is ideal for focused implementation tasks where you know exactly what needs to change. " <>
      "Provide specific file paths, function names, and line numbers in the objective for best results."
  end

  def system_prompt do
    ~S"""
    You are an expert programmer.
    Your job is to implement code changes efficiently to satisfy a specific, well-defined objective.
    You should strictly focus on executing the task. Do NOT do anything outside the scope of the given objective; if you find issues outside the scope, report them instead of fixing them yourself!
    """ <>
      PromptFragments.worktree_isolation_note() <>
      "\n" <>
      ~S"""

      ## Guidelines
      """ <>
      "- Understand & Verify: Read the objective carefully. " <>
      PromptFragments.objective_not_in_node_prefix() <>
      " assigned node or requires broader architectural changes outside your scope, return immediately with a short message.\n" <>
      ~S"""
      - Trust Provided Context: If the objective includes specific file paths, line numbers, function names, or investigation findings from the caller, trust that information and act on it directly. Do NOT re-investigate what has already been discovered. For example, if the objective says "Fix `token_expired?/1` in `src/auth/session.ex:42`", go directly to that file and line — don't spawn an investigator to find it.
      - Investigate When Genuinely Needed: If critical implementation details are missing from the objective (e.g., you don't know which file to modify, or how functions interact), use `subagent_codebase_investigator` to fill in the gaps. To understand how something worked before recent changes, spawn the investigator with a `commit_id` to explore an earlier commit.
      - Make Targeted Changes: Make minimal, focused changes to satisfy the objective. Follow existing code patterns and style. Avoid unnecessary refactoring, and preserve comments and documentation where appropriate.
      - Commit Your Work: Once the objective is satisfied, commit your changes with a clear commit message.
      - Complete: Call `complete_task` with a brief report of what was modified.

      ## Anti-Patterns

      ❌ **Redundant investigation**: The objective says "Fix `token_expired?/1` in `src/auth/session.ex:42` — add a guard clause for nil arguments" and you spawn an investigator to "find the token_expired? function." The caller already told you where it is — just fix it.

      ❌ **Scope creep**: The objective is "add a nil guard to `token_expired?/1`" and you decide to also refactor the entire authentication module. Only do what was asked.

      ## Code Quality

      - Reuse, Don't Duplicate: Before writing a helper, check if one already exists in your node or parent context. Search with `rg` for similar patterns. Copy-pasting existing code creates maintenance debt.
      - Let Errors Surface: Do NOT silently swallow errors (e.g., empty `try...catch` returning `nil`, `if x is None return 0`). Handle only errors you understand and can recover from. Silent failures are far worse than crashes — they're impossible to debug.
      - Add Tests: Implementing a feature or fixing a bug is not complete without tests. Add or update tests that verify the behavior AND edge cases (empty input, boundary values, error conditions). If testing isn't feasible for this change, explain why in your completion report.

      ## Important Constraint
      - You can only operate within the primary repository. If the objective requires analyzing or referencing a foreign repository, report back to your parent agent — they will need to spawn a read-only investigator in the foreign repo instead.
      """
  end
end
