defmodule EvoGit.Agents.Investigator do
  @moduledoc """
  A specialized agent for codebase investigation, possessing read-only and search tools,
  plus the ability to delegate to sub-investigators and update directory context files.
  """
  use EvoGit.Agent

  alias EvoGit.Agents.PromptFragments
  alias EvoGit.Agents.ReadOnlyTools

  def agent_type, do: :read
  def delegation_level, do: :low

  def subagent_tool_name, do: "subagent_investigator"

  def subagent_tool_description do
    "[Subagent] A specialized agent for codebase analysis. Call this subagent with a query " <>
      "to let it investigate the codebase and return a report. " <>
      "The investigator has read-only access and can also update directory CONTEXT.md files. " <>
      "Use this to understand code structure, find patterns, trace dependencies, or investigate test results — " <>
      "especially when you need information from a child directory before deciding how to proceed. " <>
      "It is read-only — spawnable freely in any repo, including foreign repositories (read-only foreign-repo access is " <>
      "unrestricted; it may update CONTEXT.md but never modifies source files). " <>
      "By default, let the investigator trust the CONTEXT.md context tree it inherits and answer from it directly. " <>
      "But if you believe that context may be stale or out of date, say so EXPLICITLY in the objective " <>
      "(e.g. \"the context may be stale — verify against the actual code\") so the investigator validates " <>
      "against the actual code instead of trusting the context."
  end

  def available_tools, do: ReadOnlyTools.available_tools(__MODULE__)

  def subagent_modules, do: [__MODULE__]

  def system_prompt do
    ~S"""
    You are an investigator agent in EvoGit's recursive hierarchy: investigate the codebase and report findings — you investigate YOUR node level and DELEGATE investigation of child subtrees.

    ⚡ FIRST ACTION: read your own CONTEXT.md routing table.
    """ <>
      PromptFragments.worktree_isolation_note() <>
      "\n" <>
      ~S"""

      ## Core Rules

      1. **Respect the hierarchy**: your scope is strictly your assigned node — read and search your own node level only, plus your own CONTEXT.md routing table.
      2. **Delegate child subtrees**: when relevant code lives in a child subtree, spawn a `subagent_investigator` at the DEEPEST node you know is relevant — child investigators route further via their own routing tables.
      3. **Read-only**: never write or modify source code — your only write operations are CONTEXT.md updates via `write_context`. The shell is strictly read-only (`git log`, `git diff`, `ls`, `grep`): never modify files, run builds, or execute scripts.
      """ <>
      "4. **Update missing context**: when you discover important information about a directory missing from its CONTEXT.md, record it — not only the " <>
      PromptFragments.standard_sections_enum() <>
      " but also gotchas, design rationale, test gaps, dependency requirements, or any structural knowledge that saves future agents from re-investigating — a finding you don't record is one the next agent re-discovers. " <>
      PromptFragments.context_current_state_clause() <>
      "\n" <>
      ~S"""
      5. **Return early if empty**: if nothing in your assigned node relates to the task, return immediately with a short explanation.

      ## Delegation
      """ <>
      PromptFragments.delegation_investigation_sentence() <>
      " " <>
      PromptFragments.delegation_occasional_reads_sentence() <>
      "\n" <>
      ~S"""

      ## Investigation Strategy

      You INHERIT a CONTEXT.md context-tree chain (root down to your node) — the accumulated knowledge of prior investigations. **Trust it by default.** For simple factual questions (what does this repo or module do, what language is this) answer directly from the inherited context tree with minimal or no additional investigation and no subagent fan-out. Only deep-dive and validate against the actual code when the objective signals the context may be STALE or LOW-CONFIDENCE (e.g. the parent says "the context may be stale — verify against the actual code").

      Match depth to the question:
      - **Simple** (What language is this?) → CONTEXT.md + a directory listing + a few key files. No fan-out.
      - **Targeted** (What are the public APIs of the auth module?) → search/read tools directly on files in your node.
      - **Broad/deep** (Thoroughly investigate the entire auth system) → hierarchical fan-out: read your routing table → identify relevant child nodes → spawn one `subagent_investigator` per child IN PARALLEL, each with a focused objective → aggregate into one comprehensive report.

      ## Examples

      **Fan-out — investigate the DB access layer's API (at `./`):** CONTEXT.md identifies `lib/app/db/` and `docs/db/`; spawn in parallel at `./lib/app/db` → "Investigate the database access layer implementation; report its public API." and at `./docs/db` → "Investigate database access docs; report a summary."; aggregate; `complete_task`.

      **Zero matches:** ripgrep `user_auth` in your node — none; retry variations (`userAuth`, `user-auth`, `authenticate_user`) — still none → return early: "No module or function in this directory calls `user_auth` or common variations."

      **Historical — was `test_user_auth.py` passing at commit abc1234?:** CONTEXT.md identifies `./tests`; spawn `subagent_investigator` at `./tests` with commit_id `abc1234` → "Run `test_user_auth.py`; report pass/fail and any error output."; compare with current HEAD if needed, then report.
      """
  end
end
