defmodule EvoGit.Agents.PromptFragments do
  @moduledoc """
  Shared prompt fragments for agent system prompts.

  Every agent implementation module (`EvoGit.Agents.*`) used to inline the same
  boilerplate paragraphs (worktree-isolation notes, delegation principles,
  architecture explanations, code-quality guidance) — copy-pasted across 4–7
  prompts with silent drift. This module centralizes that shared text so a
  wording fix lands in ONE place instead of eight.

  ## Rules for editing

  - **Prompts are behavior.** The composed `system_prompt/0` strings must stay
    byte-identical to what agents saw before. Never normalize, reword, or merge
    fragments — near-duplicates are preserved as their own functions (or left
    inline in the owning module) on purpose.
  - When an agent prompt needs a wording change, update the fragment here (if
    the text is shared) rather than editing the copy in one agent module.
  - When you notice new boilerplate shared by two or more prompts, extract it
    here as a new function instead of copy-pasting.
  - **Verification practice:** dump every agent's `system_prompt/0` before and
    after a prompt change (e.g. via `mix run -e`) and diff — the outputs must
    match character-for-character unless a deliberate wording change was made.

  ## Conventions

  - All fragments are plain strings WITHOUT a trailing newline. Callers insert
    `"\\n"` explicitly where a fragment ends a line, so mid-line composition
    stays exact.
  - Fragment names mirror the first line of the text (e.g.
    `worktree_isolation_note/0` starts with "You are currently working in an
    isolated worktree."). This file is legitimately long — the string literals
    are data, not logic.
  """

  # ── Worktree isolation notes ────────────────────────────────────────────────

  @doc """
  Variant A of the worktree-isolation note — full three-sentence form.

  Used by: Executor, ContextExtractor, TaskScheduler, CodebaseInvestigator
  (each as a standalone paragraph).
  """
  def worktree_isolation_note do
    "You are currently working in an isolated worktree. The current working directory is automatically set to the correct worktree path. Each subagent you spawn runs in its OWN separate worktree — never include worktree paths or `cd` commands in subagent objectives."
  end

  @doc """
  Variant A' of the worktree-isolation note — first two sentences only.

  Used by: SkillExtractor (its prompt omits the subagent-spawning sentence).
  """
  def worktree_isolation_note_short do
    "You are currently working in an isolated worktree. The current working directory is automatically set to the correct worktree path."
  end

  @doc """
  Worktree tail — "Each subagent runs in its OWN isolated worktree …".

  Shared sentence tail used by:
  - Manager (end of the "Your assigned directory is your domain." paragraph)
  - CodebaseLead (end of the "Your two main delegation specialists are …" bullet)

  NOTE: do NOT merge with `subagent_worktree_tail_own/0` — that variant says
  "OWN worktree" (no "isolated") and is used only by CodebaseLead.
  """
  def subagent_worktree_tail_isolated do
    "Each subagent runs in its OWN isolated worktree — never include worktree paths or `cd` commands in subagent objectives."
  end

  # ── Delegation principles ───────────────────────────────────────────────────

  @doc """
  "Investigating child subtrees yourself is rarely the best use of your turns …"

  Used by: Manager (inside the "Strongly prefer delegating child subtree
  investigation." bullet), CodebaseInvestigator (opening of the "# ⚠️ Strongly
  Prefer Delegating Child Subtree Investigation" section).

  Deliberately NOT used by CodebaseLead (wording differs: "Investigating or
  implementing in child subtrees yourself …") or GenesisPlanner ("Investigating
  child subtrees in detail yourself …") — those variants stay inline.
  """
  def delegation_investigation_sentence do
    "Investigating child subtrees yourself is rarely the best use of your turns — a subagent can do it faster and at a more correct level."
  end

  @doc """
  "Occasional targeted reads for quick context are fine, but …"

  Used by: Manager, CodebaseInvestigator, GenesisPlanner (closing sentence of
  the delegation-guidance paragraphs).
  """
  def delegation_occasional_reads_sentence do
    "Occasional targeted reads for quick context are fine, but if you find yourself reading multiple files in a child subtree, that's a strong signal to delegate instead."
  end

  # ── Genesis architecture (Manager + CodebaseLead) ───────────────────────────

  @doc """
  "# Genesis System Architecture" heading plus the framework-intro opening.

  Used by: Manager (continues ". Understanding its design is essential — …"),
  CodebaseLead (continues " built on two orthogonal dimensions. …").
  """
  def genesis_architecture_header do
    "# Genesis System Architecture

Genesis is a recursive software development framework"
  end

  @doc """
  The Context Tree routing-table description clause ("as both documentation …").

  Used by: Manager ("…`CONTEXT.md` file that serves " <> clause <> " This is how
  agents know …"), CodebaseLead ("…`CONTEXT.md` file serving " <> clause <> "
  When you design …").
  """
  def context_tree_routing_table_clause do
    "as both documentation (Intent, API Surface, Constraints) and a **Routing Table** (a map of areas/modules/features to child subdirectories; may also include sibling paths for cross-references like related test directories)."
  end

  @doc """
  "Code evolves through a DAG of immutable Git commits."

  Used by: Manager (sentence in the Phylogenetic Graph section), CodebaseLead
  ("**Temporal Dimension — The Phylogenetic Graph:** " <> sentence <> " …").
  """
  def phylogenetic_graph_sentence do
    "Code evolves through a DAG of immutable Git commits."
  end

  @doc """
  "in the Context Tree (CONTEXT.md files) or the Phylogenetic Graph (Git history)."

  Used by: Manager ("…all persistent memory lives either " <> clause),
  CodebaseLead ("All persistent memory lives " <> clause <> " This means:").
  """
  def transient_memory_clause do
    "in the Context Tree (CONTEXT.md files) or the Phylogenetic Graph (Git history)."
  end

  @doc """
  "Every agent at every level has the same fundamental loop: read CONTEXT.md"

  Used by: Manager (continues " routing table "), CodebaseLead (continues " ").
  Paired with `recursive_loop_tail/0`.
  """
  def recursive_loop_intro do
    "Every agent at every level has the same fundamental loop: read CONTEXT.md"
  end

  @doc """
  "→ delegate to deepest correct child → validate → complete."

  Used by: Manager, CodebaseLead (completes the fundamental-loop sentence).
  Paired with `recursive_loop_intro/0`.
  """
  def recursive_loop_tail do
    "→ delegate to deepest correct child → validate → complete."
  end

  # ── Sibling paths & routing tables ──────────────────────────────────────────

  @doc """
  "Routing tables primarily map to child subdirectories, … Authentication test suite). "

  Used by: Manager (continues "When sibling paths appear, …"), CodebaseLead
  (continues "When including sibling entries, …").
  """
  def routing_sibling_prefix do
    "Routing tables primarily map to child subdirectories, but may also include sibling paths for cross-references (e.g., `../tests/auth_tests/` → Authentication test suite). "
  end

  @doc """
  "`../tests/auth_tests/` → Authentication test suite (sibling — read-only, escalate writes to parent)"

  Used by: Manager (", like: " <> clause <> "."), CodebaseLead ("…, like: " <>
  clause <> ". Agents can …"), ContextExtractor (list item "- " <> clause).
  """
  def sibling_example_parenthetical do
    "`../tests/auth_tests/` → Authentication test suite (sibling — read-only, escalate writes to parent)"
  end

  # ── Code quality & file structure (Manager + CodebaseLead) ──────────────────

  @doc """
  "Single Responsibility (each file has one reason to change), … (related code lives together). "

  Used by: Manager ("…essential software engineering practices: " <> clause <>
  "In the Genesis recursive delegation system, …"), CodebaseLead ("…practices — "
  <> clause <> "In the Genesis system …").
  """
  def solid_principles_sentence do
    "Single Responsibility (each file has one reason to change), Low Coupling (files depend on abstractions, not concrete internals), and High Cohesion (related code lives together). "
  end

  @doc """
  "Some files are long for a good reason — … When you "

  Used by: Manager (continues "encounter a file that exceeds …"),
  CodebaseLead (continues "determine a file is long …"). Paired with
  `large_files_remediation/0`.
  """
  def large_files_intro do
    "Some files are long for a good reason — generated code, comprehensive test suites, data mappings, or protocol definitions that can't be split without losing coherence. When you "
  end

  @doc """
  "leave a short comment at the top of the file … re-investigating whether "

  Used by: Manager (ends "the file should be split."), CodebaseLead (ends
  "it should be split."). Paired with `large_files_intro/0`.
  """
  def large_files_remediation do
    "leave a short comment at the top of the file explaining its role and why it needs to be long (if the file format supports comments). Alternatively, add a note to the directory's CONTEXT.md so future agents understand the rationale and don't waste turns re-investigating whether "
  end

  @doc """
  "the user or project config specifies a particular structure, convention, or file organization,"

  Used by: Manager ("…first** — if " <> clause <> " that is always the highest
  priority."), CodebaseLead ("…ALWAYS the highest priority. If " <> clause <>
  " follow it unconditionally.").
  """
  def user_config_specifies_clause do
    "the user or project config specifies a particular structure, convention, or file organization,"
  end

  @doc """
  "file-structure expectations in the objective (e.g., \"keep files under ~1000 lines, extract shared "

  Used by: Manager (ends "helpers to a common module\")."), CodebaseLead (ends
  "utilities to a common module\").").
  """
  def file_structure_expectations_prefix do
    "file-structure expectations in the objective (e.g., \"keep files under ~1000 lines, extract shared "
  end

  # ── Context Tree definition (CodebaseLead + ContextExtractor) ───────────────

  @doc """
  "spatial, recursive representation of the codebase structure."

  Used by: CodebaseLead ("The Context Tree is the " <> clause), ContextExtractor
  ("The Context Tree is a " <> clause).
  """
  def context_tree_definition_clause do
    "spatial, recursive representation of the codebase structure."
  end

  @doc """
  "simple markdown list mapping each area/module/feature to its owning child subdirectory"

  Used by: CodebaseLead ("(2) Routing Table — a " <> clause <> ", so parent
  agents know …"), ContextExtractor ("**Routing Table** — A " <> clause <>
  ". May also include …").
  """
  def routing_table_markdown_list_clause do
    "simple markdown list mapping each area/module/feature to its owning child subdirectory"
  end

  @doc """
  "where to delegate work without investigating the subtree."

  Used by: CodebaseLead ("…so parent agents know " <> clause), ContextExtractor
  ("…quickly determine " <> clause <> " Example:").
  """
  def delegate_without_investigating_clause do
    "where to delegate work without investigating the subtree."
  end

  # ── Shared canonical phrases ─────────────────────────────────────────────────

  @doc """
  "standard sections (Intent, API Surface, Constraints, Routing Table)"

  Used by: CodebaseLead ("The " <> clause <> " are required; …"),
  CodebaseInvestigator ("not only the " <> clause <> " but also:").

  NOTE: Manager says "standard four sections (Intent, …)" — that variant stays
  inline in manager.ex.
  """
  def standard_sections_enum do
    "standard sections (Intent, API Surface, Constraints, Routing Table)"
  end

  @doc """
  "CONTEXT.md chain from `./` → `./src/` → `./src/auth/` → `./src/auth/oauth/`"

  Used by: Manager ("inherits the full " <> clause), CodebaseLead ("sees the " <>
  clause <> ". This is why …").
  """
  def context_chain_example do
    "CONTEXT.md chain from `./` → `./src/` → `./src/auth/` → `./src/auth/oauth/`"
  end

  @doc """
  "# Genesis Context" heading plus the Context-Tree intro (up to the
  "`CONTEXT.md`" backtick, which is where the two users diverge).

  Used by: TaskScheduler (continues " file with a routing table mapping areas to
  child subdirectories. …"), GenesisPlanner (continues " routing table that maps
  areas to child subdirectories. …").
  """
  def genesis_context_header do
    "# Genesis Context

Genesis models the codebase as a **Context Tree**: a hierarchical tree where every directory node has a `CONTEXT.md`"
  end

  # ── Foreign repositories (CodebaseLead + ContextExtractor) ──────────────────

  @doc """
  "a foreign repository (an absolute path like `/Source/original-proj`),"

  Used by: CodebaseLead ("When your objective involves " <> clause <> " such as
  porting an existing codebase:"), ContextExtractor ("…objective references " <>
  clause <> " you can spawn subagents in that repo …").
  """
  def foreign_repo_absolute_path_clause do
    "a foreign repository (an absolute path like `/Source/original-proj`),"
  end

  @doc """
  "- **Spawn at the right level**: When you know the foreign repo's structure"

  Used by: CodebaseLead (continues ", spawn investigators directly at …"),
  ContextExtractor (continues " (from the objective or from previous
  investigation), spawn subagents directly at …").
  """
  def foreign_repo_spawn_right_level do
    "- **Spawn at the right level**: When you know the foreign repo's structure"
  end

  # ── Objective scope (Executor + ContextExtractor) ───────────────────────────

  @doc """
  "If the objective clearly does not belong to your"

  Used by: Executor (continues " assigned node or requires broader architectural
  changes outside your scope, return immediately with a short message."),
  ContextExtractor (continues " node, return immediately and report the issue.").
  """
  def objective_not_in_node_prefix do
    "If the objective clearly does not belong to your"
  end
end
