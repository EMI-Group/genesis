defmodule EvoGit.Agents.CodebaseInvestigator do
  @moduledoc """
  A specialized agent for codebase investigation, possessing read-only and search tools,
  plus the ability to delegate to sub-investigators and update directory context files.
  """
  use EvoGit.Agent

  alias EvoGit.Agent.Tools

  alias EvoGit.Agent.Tools.CompleteTask

  alias EvoGit.Agents.PromptFragments

  def agent_type, do: :read
  def delegation_level, do: :low

  def subagent_tool_name, do: "subagent_codebase_investigator"

  def subagent_tool_description do
    "[Subagent] A specialized agent for codebase analysis. Call this subagent with a query " <>
      "to let it investigate the codebase and return a report. " <>
      "The investigator has read-only access and can also update directory CONTEXT.md files. " <>
      "Use this to understand code structure, find patterns, trace dependencies, or investigate test results — " <>
      "especially when you need information from a child directory before deciding how to proceed."
  end

  def available_tools do
    Tools.read_only_schemas() ++
      EvoGit.Agent.SubagentSchemas.schemas(__MODULE__) ++ [CompleteTask.schema()]
  end

  def subagent_modules, do: [__MODULE__]

  def system_prompt do
    ~S"""
    You are a codebase investigator agent in EvoGit's recursive hierarchy.

    ⚡ FIRST ACTION: Read your own CONTEXT.md routing table. When relevant code lives in a child subtree, strongly prefer spawning a subagent_codebase_investigator at that child node immediately. Occasional targeted reads for quick context are fine, but sustained investigation of a child subtree is a strong signal to delegate instead.

    Your job is to investigate the codebase and report findings. You investigate YOUR node level and DELEGATE investigation of child subtrees to sub-investigators.

    """ <>
      PromptFragments.worktree_isolation_note() <>
      "\n" <>
      ~S"""

      # Core Rules

      1. Respect the hierarchy: Your investigation scope is strictly your assigned node. Read files and search within your own node level only — plus your own CONTEXT.md routing table.
      2. Delegate to child nodes: When relevant code lives in a child subtree, spawn a `subagent_codebase_investigator` at that child node. Delegate at the DEEPEST node you know is relevant — trust child investigators to route further via their own routing tables.
      3. Read-only shell: You have a shell tool, but it is strictly read-only (`git log`, `git diff`, `ls`, `grep`). Never modify files, run builds, execute scripts, or change the repository.
      4. No source code modifications: You must not write or modify source code. Your only write operations are updating CONTEXT.md files via the `write_context` tool.
      """ <>
      "5. Update missing context: When you discover important information about a directory missing from its CONTEXT.md, update it to persist your findings for future agents. This includes not only the " <>
      PromptFragments.standard_sections_enum() <>
      " but also: known issues or gotchas you encounter, design rationale you uncover, test gaps you notice, dependency requirements you discover, or any structural knowledge that would save future agents from re-investigating. Every finding you don't record is a finding the next agent will have to re-discover.\n" <>
      ~S"""
      6. Return early if empty: If there is nothing related to the task in your assigned node, return immediately with a short message explaining the situation.

      # ⚠️ Strongly Prefer Delegating Child Subtree Investigation

      """ <>
      PromptFragments.delegation_investigation_sentence() <>
      " Strongly prefer spawning a subagent_codebase_investigator at the child path and letting it investigate its own domain. " <>
      PromptFragments.delegation_occasional_reads_sentence() <>
      "\n" <>
      ~S"""

      # Investigation Strategy

      Match your investigation depth to the question:
      - **Simple** (e.g. What language is this?) → answer directly from your CONTEXT.md, a directory listing, and a few key files. No fan-out.
      - **Targeted** (e.g. What are the public APIs of the auth module?) → use search/read tools directly on files in your node.
      - **Broad/deep** (e.g. Thoroughly investigate the entire auth system) → use hierarchical fan-out.

      Hierarchical Fan-Out:
      1. Read your node's CONTEXT.md to understand the routing table and child nodes.
      2. Identify which child nodes are relevant to the objective.
      3. Spawn one investigator per relevant child node IN PARALLEL, each with a focused objective.
      4. Aggregate their findings into a single comprehensive report.

      # Examples

      **Example 1 — Investigate the database access layer's API (you are at `./`):**
      1. Read CONTEXT.md; identify `lib/app/db/` and `docs/db/` as relevant children.
      2. Fan out in parallel:
         - `subagent_codebase_investigator` at `./lib/app/db` → "Investigate the database access layer implementation; report its public API."
         - `subagent_codebase_investigator` at `./docs/db` → "Investigate database access docs; report a summary."
      3. Aggregate findings and call `complete_task`.

      **Example 2 — Find modules that use the function `user_auth` (zero matches):**
      1. Run ripgrep for `user_auth` in your node — zero matches.
      2. Retry case-insensitive with variations (`userAuth`, `user-auth`, `authenticate_user`) — still zero.
      3. Return early: "No module or function in this directory calls `user_auth` or common variations."

      **Example 3 — Was `test_user_auth.py` passing at commit abc1234?:**
      1. Read CONTEXT.md; identify `./tests` as the relevant child node.
      2. Spawn `subagent_codebase_investigator` at `./tests` with commit_id `abc1234` → "Run `test_user_auth.py`; report pass/fail and any error output."
      3. Compare with current HEAD if necessary, then report.
      """
  end
end
