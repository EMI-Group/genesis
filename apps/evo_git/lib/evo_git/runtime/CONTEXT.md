# Runtime

## Intent
Implements the two-phase execution engine of EvoGit: **Genesis** (initial codebase creation/analysis) and **Evolution** (iterative refinement loop). The centralized `EvoGit.Runtime.Prompts` module referenced in design docs does **not exist as a separate file** — prompts are defined directly in each agent module's `system_prompt/0` callback and in inline prompt strings in `EvoGit.Task`.

## API Surface

### Modules

- **`EvoGit.Runtime`** (`../runtime.ex`) — Top-level coordinator. Provides `ensure_repo/1` to initialize a git repo if missing. Orchestrates Genesis then Evolution.

- **`EvoGit.Runtime.Genesis`** (`genesis.ex`) — Stage 1: Creation Phase.
  - `run(objective, opts \\ [])` — Entry point. Detects whether the codebase is new (Mode B → `CodebaseArchitect`) or existing (Mode A → `ContextExtractor`), creates a `PhyloGraphNode`, builds an `AgentSpec`, runs the agent via `AgentScheduler`, and merges the agent branch back to the main workspace.
  - Returns `{:ok, %{commit_sha, result, tag, branch_name, pr_url, no_changes?}}` on success.

- **`EvoGit.Runtime.Evolution`** (`evolution.ex`) — Stage 2: Evolutionary Loop.
  - `run(objective, opts \\ [])` — Entry point. Supports `:simple` (Manager agent) and `:complex` (not yet implemented, falls back to simple) modes. Dispatches an agent via `AgentScheduler`, creates a branch, and optionally creates a PR.
  - Returns `{:ok, %{commit_sha, result, tag, branch_name, pr_url, no_changes?}}` on success.

### Prompt Architecture (No `prompts.ex` file)

The design document referenced a centralized `EvoGit.Runtime.Prompts` module, but **it was never implemented**. Instead, prompts are distributed:

1. **Agent `system_prompt/0` callbacks** — Each agent module defines its own system prompt as a heredoc string. See `../agent/` for all agent modules and their prompts.

2. **Inline prompts in `EvoGit.Task`** — The `mutate/3`, `diagnose/3`, and `resolve_conflict/3` functions construct user prompts inline.

3. **Agent loop generated prompts** — The `EvoGit.Agent` `use` macro automatically constructs the initial user prompt by combining the context tree + objective. It also injects budget warnings and recovery prompts dynamically.

4. **Context compression prompt** — Defined inline in `agent.ex` `try_compress_chat/1` when token threshold is exceeded.

5. **Budget warnings** — Defined in `EvoGit.Agent.Warnings` as template functions at 25%, 50%, 80% thresholds for both time and turns.

### Key Dependencies
- `EvoGit.Core.PhyloGraphNode`, `EvoGit.Core.ContextNode` — Core data structures
- `EvoGit.AgentScheduler`, `EvoGit.AgentSpec` — Agent execution
- `EvoGit.Agent.CodebaseArchitect`, `EvoGit.Agent.ContextExtractor`, `EvoGit.Agent.Manager` — Agent modules
- `EvoGit.Adapters.Git` — Git operations
- `EvoGit.Task` — Diagnosis routing

## Constraints
- The parent coordinator (`EvoGit.Runtime` in `../runtime.ex`) orchestrates Genesis first, then Evolution.
- Both phases follow the same pattern: ensure repo → create phylo node → load context node → run agent → handle result.
- Evolution uses a **branch-based approach**: agent changes are placed on a dedicated branch (e.g. `evogit/evolve_abcdef`) instead of merging directly into the working tree. A PR is optionally created if the `gh` CLI is available.
- Genesis similarly creates a branch (`evogit/genesis_abcdef`) and optionally creates a PR.
- There is no centralized `prompts.ex` — all prompt text is in agent modules or inline in `EvoGit.Task`.
