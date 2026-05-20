# Runtime

## Intent
Implements the two-phase execution engine of EvoGit: **Genesis** (initial codebase creation/analysis) and **Evolution** (iterative refinement loop). Also contains the centralized prompt repository that provides all LLM prompt templates used across the system.

## API Surface

### Modules

- **`EvoGit.Runtime.Genesis`** (`genesis.ex`) — Stage 1: Creation Phase.
  - `run(root_prompt, opts \\ [])` — Entry point. Detects whether the codebase is new (Mode B → `CodebaseArchitect`) or existing (Mode A → `ContextExtractor`), creates a `PhyloGraphNode`, builds an `AgentSpec`, runs the agent via `AgentScheduler`, and merges the agent branch back to the main workspace.
  - Returns `{:ok, commit_sha}` on success.

- **`EvoGit.Runtime.Evolution`** (`evolution.ex`) — Stage 2: Evolutionary Loop.
  - `run(objective, opts \\ [])` — Entry point. Calls `Task.diagnose/3` to identify the target path, dispatches an agent (default: `EvoGit.Agent.Manager`) via `AgentScheduler`, and creates a branch for the agent's changes (with optional PR via `gh` CLI).
  - Returns `{:ok, %{commit_sha, result, tag, branch_name, pr_url}}` on success. Includes `no_changes: true` when no changes were detected.

- **`EvoGit.Runtime.Prompts`** (`prompts.ex`) — Centralized LLM prompt repository.
  - `agent_mutation(objective)` — Mutation instruction for agent loop.
  - `agent_diagnosis(objective, file_tree)` — Diagnosis prompt for analyst agent (returns JSON `path`).
  - `agent_conflict_resolution(file)` — Merge conflict resolution prompt.
  - `genesis_plan(:directory | :file, node_path, instruction)` — Genesis planning prompt (context definition only, no implementation).
  - `genesis_realize(:directory | :file, node_path)` — Genesis realization prompt (scaffold structure or implement code).
  - `genesis_new_codebase(objective)` — Mode B prompt for initializing a brand-new codebase.
  - `genesis_existing_codebase(objective)` — Mode A prompt for analyzing an existing codebase.

### Key Dependencies
- `EvoGit.Core.PhyloGraphNode`, `EvoGit.Core.ContextNode` — Core data structures
- `EvoGit.AgentScheduler`, `EvoGit.AgentSpec` — Agent execution
- `EvoGit.Agent.CodebaseArchitect`, `EvoGit.Agent.ContextExtractor`, `EvoGit.Agent.Generalist` — Agent modules
- `EvoGit.Adapters.Git` — Git operations (requires: `create_branch/3`, `current_branch/1`, `gh_available?/0`, `create_pull_request/5`)
- `EvoGit.Task` — Diagnosis routing

## Routing Table

This directory has no child subdirectories — all work is handled by the individual files within this directory (`genesis.ex`, `evolution.ex`, `prompts.ex`). For any changes to the Genesis/Evolution runtime orchestration or LLM prompt templates, work directly on the relevant file in this node; no subagent delegation to child paths is needed.

## Constraints
- The parent coordinator (`EvoGit.Runtime` in `../runtime.ex`) orchestrates Genesis first, then Evolution.
- Both phases follow the same pattern: ensure repo → create phylo node → load context node → run agent → handle result.
- Prompts are the single source of truth for all LLM instructions; do not inline prompt text in agent or runtime modules.
- `genesis_plan` and `genesis_realize` are two-step (plan then realize) — plan writes CONTEXT.md/headers only; realize creates files/implements code.
- Evolution uses a **branch-based approach**: agent changes are placed on a dedicated branch (e.g. `evogit/evolve_abcdef`) instead of merging directly into the working tree. A PR is optionally created if the `gh` CLI is available.
- The `EvoGit.Adapters.Git` module must provide: `create_branch/3`, `current_branch/1`, `gh_available?/0`, and `create_pull_request/5` for the Evolution branch-based flow to work.
