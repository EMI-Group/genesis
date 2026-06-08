# Runtime

## Intent
Implements the two-phase execution engine of EvoGit: **Genesis** (initial codebase creation or analysis of an existing codebase) and **Evolution** (iterative modification loop). A shared `PullRequest` module handles post-phase PR creation. The design doc's centralized `EvoGit.Runtime.Prompts` module was never implemented — prompts live in agent `system_prompt/0` callbacks and inline strings.

## API Surface

### Modules

| Module | File | Public API | Description |
|--------|------|------------|-------------|
| `EvoGit.Runtime` | `../runtime.ex` | `ensure_repo/1` | Top-level coordinator. `ensure_repo/1` initializes a git repo with `.gitignore` if missing. The CLI (`EvoGit.CLI`) calls `Genesis.run/2` and `Evolution.run/2` directly — there is no combined orchestration entry point. |
| `EvoGit.Runtime.Helpers` | `helpers.ex` | `merge_and_report/3`, `notify_finalizing/1`, `generate_branch_name/1`, `new_codebase?/1`, `validate_node_path/2`, `resolve_starting_commit/2` | Shared helper functions for both runtime phases — branch creation, change detection, node path validation, commit resolution. |
| `EvoGit.Runtime.Genesis` | `genesis.ex` | `run/2` | Stage 1 — Creation/Analysis. Auto-detects mode. Returns `{:ok, %{commit_sha, result, tag, branch_name, pr_url}}` or `{:ok, %{..., no_changes: true}}`. |
| `EvoGit.Runtime.Evolution` | `evolution.ex` | `run/2` | Stage 2 — Evolutionary Loop. Supports `:simple` and `:complex` modes. Same return shape as Genesis. |
| `EvoGit.Runtime.PullRequest` | `pull_request.ex` | `try_create/4`, `generate_title/2`, `format_body/2` | Shared PR utilities: LLM-powered title generation, body formatting, push + PR creation via `gh` CLI. |
| `EvoGit.Runtime.Evolution.Engine` | `evolution/engine.ex` | `run/5` | Complex Evolution orchestrator — novelty-driven evolution loop with MAP-Elites, LLM crossover/mutation, and solution synthesis. |
| `EvoGit.Runtime.Evolution.Fragment` | `evolution/fragment.ex` | `new/2`, `extract_structural_features/1`, `to_feature_vector/1`, `summarize/1` | Code fragment data structure with AST feature extraction and feature vector conversion. |
| `EvoGit.Runtime.Evolution.SeedFragments` | `evolution/seed_fragments.ex` | `all/0`, `by_category/1`, `random/1`, `generate_with_llm/3` | 15 built-in cross-domain seed fragments + LLM-powered diverse fragment generation. |
| `EvoGit.Runtime.Evolution.EntropyPool` | `evolution/entropy_pool.ex` | `start_link/1`, `insert/1`, `insert_all/1`, `get/1`, `all/0`, `size/0`, `select_novel/1`, `select_random/1`, `evict_most_redundant/0`, `update_fragment/1`, `clear/0`, `stop/0` | ETS-backed GenServer for fragment storage with novelty-based selection and auto-eviction. |
| `EvoGit.Runtime.Evolution.MapElites` | `evolution/map_elites.ex` | `start_link/1`, `insert/1`, `get_elites/0`, `get_elite/1`, `all_fragments/0`, `size/0`, `descriptor_for/1`, `clear/0`, `stop/0` | MAP-Elites quality diversity archive — grid indexed by complexity × paradigm. |
| `EvoGit.Runtime.Evolution.NoveltyMetric` | `evolution/novelty_metric.ex` | `novelty_score/3`, `distance/2`, `batch_novelty_scores/3`, `structural_features/1`, `behavioral_profile/2`, `most_redundant/1` | k-NN novelty scoring in feature space, AST structural analysis, LLM behavioral profiling. |
| `EvoGit.Runtime.Evolution.LLMSynthesis` | `evolution/llm_synthesis.ex` | `crossover/4`, `mutate/3`, `evaluate_viability/1`, `generate_diverse_fragments/4` | LLM-powered semantic crossover, mutation, syntax viability checking, and diverse fragment generation. |

### `Genesis.run/2` — Step by Step

1. **Parse options**: Extracts `repo_path` (default `File.cwd!()`), `foreign_repos`.
2. **Register foreign repos**: If `foreign_repos` provided, registers them with `AgentScheduler`.
3. **Ensure repo**: Calls `Runtime.ensure_repo/1` to `git init` if needed.
4. **Get HEAD**: `PhyloGraphNode.current_head/1` → current commit SHA.
5. **Detect mode**: `new_codebase?/1` checks if directory has files beyond `.git`, `README.md`, `.evogit`, `.gitignore`.
6. **Dispatch agent**:
   - **Mode A (Existing)** → `ContextExtractor` agent (read-only, builds CONTEXT.md tree via recursive subagent extraction).
   - **Mode B (New)** → `CodebaseArchitect` agent (read-write, 3-phase: skeleton → implementation → review).
7. **AgentSpec construction**: `AgentSpec.new(context_node, phylo_node, agent_module, objective)` → `AgentScheduler.run_agent/1` (blocks until complete).
8. **Post-processing** (`merge_and_report/3`): Compares base SHA vs agent's final SHA. If changed, creates `evogit/genesis_<hex>` branch at agent commit, optionally creates PR. If unchanged, returns `no_changes: true`.

### `Evolution.run/2` — Step by Step

1. **Parse options**: Extracts `repo_path`, `mode` (default `:simple`), `node_path` (default `"./"`), `foreign_repos`.
2. **Register foreign repos**: Same as Genesis.
3. **Ensure repo + get HEAD**: Same as Genesis.
4. **Validate node path**: `validate_node_path/2` ensures path is relative, directory exists, and contains `CONTEXT.md` (root `"./"` always passes).
5. **Dispatch agent by mode**:
   - **`:simple`** → `Manager` agent (plans, delegates to Executor/TaskScheduler/Investigator subagents).
   - **`:complex`** → `Engine.run/5` — novelty-driven evolution loop with MAP-Elites quality diversity, LLM-powered crossover/mutation, solution synthesis, and Manager agent application.
6. **Post-processing**: Same `merge_and_report/3` pattern — creates `evogit/evolve_<hex>` branch, optionally PR.

### `PullRequest.try_create/4` — Step by Step

1. **Check `gh` CLI available** via `Git.gh_available?/0`.
2. **Check origin remote** via `Git.has_origin_remote?/1`. If none, attempts `Git.create_origin_remote/1` to create one.
3. **Determine base branch** from `Git.origin_default_branch/1`.
4. **Generate title**: Calls `generate_title/2` which optionally uses LLM (ReqLLM streaming) to produce ≤8-word title. Falls back to branch name.
5. **Format body**: Standard header with `## 🤖 Auto-generated by EvoGit` + agent result.
6. **Push branch** via `Git.push_branch/2`.
7. **Create PR** via `Git.create_pull_request/5`.
8. **Returns** PR URL on success, `nil` on any failure (never raises).

## Agent Spawning & Coordination

### How Agents Are Spawned

Both phases build an `AgentSpec` struct and call `AgentScheduler.run_agent/1` (synchronous GenServer call that blocks until the agent completes):

```
AgentSpec.new(context_node, phylo_node, agent_module, objective, opts)
|> AgentScheduler.run_agent()
```

The scheduler (`AgentScheduler`):
1. Assigns a unique `task_id` and `agent_id` (format: `T<task_id>_A<task_local_id>`).
2. Allocates an isolated git worktree (directory: `worker_T<task_id>_A<task_local_id>`).
3. Prepares the worktree (`git clean` + `git checkout`).
4. Stores initial state in two ETS tables: `:evogit_agent_state` (agent-owned) and `:evogit_sched_meta` (scheduler-owned).
5. Spawns a Task process that runs the agent loop.
6. The agent calls `complete_task` when done → scheduler reclaims worktree, replies to caller.

### Agent Hierarchy by Phase

**Genesis Mode A (Existing Codebase)**:
```
ContextExtractor (root)
  ├── subagent_context_extractor (child dir 1)
  │     └── subagent_context_extractor (grandchild...)
  ├── subagent_context_extractor (child dir 2)
  └── ...
```

**Genesis Mode B (New Codebase)**:
```
CodebaseArchitect (root)
  ├── subagent_task_scheduler (optional — complex architecture scheduling)
  ├── subagent_codebase_architect (child dir)
  │     ├── subagent_codebase_architect (grandchild...)
  │     └── subagent_generalist (implementation)
  └── subagent_generalist (implementation)
```

**Evolution Simple Mode**:
```
Manager (target node)
  ├── subagent_task_scheduler (complex objectives — produces execution sequence)
  ├── subagent_codebase_investigator (codebase exploration)
  ├── subagent_executor (code changes)
  ├── subagent_manager (delegation to child nodes)
  └── ...
```

**Evolution Complex Mode**:
```
Engine.run/5 (orchestrator)
  ├── EntropyPool (GenServer — fragment storage)
  ├── MapElites (GenServer — quality diversity archive)
  │   [NoveltyMetric, LLMSynthesis, SeedFragments — pure modules]
  └── Manager (final phase — applies synthesized solution to codebase)
        ├── subagent_executor (code changes)
        └── ...
```

### Subagent Spawning Mechanics

Agents call `AgentScheduler.spawn_sub_agents/2` (from within the agent process). The scheduler:
- Validates depth doesn't exceed `max_agent_depth`.
- Checks the parent's path isn't git-ignored.
- Marks parent as `:waiting` (its worktree becomes reclaimable if pool is exhausted).
- Dispatches each subagent with its own worktree and incremented task-local ID.
- Blocks until all subagents complete, returns results in order.

## Bottom-Up / Complex Evolution

**Complex mode (`:complex`)** is implemented in `EvoGit.Runtime.Evolution.Engine`. When `Evolution.run/2` is called with `mode: :complex`, it delegates to `Engine.run/5` which runs the full novelty-driven evolution loop:

1. **Initialize**: Populate the Entropy Pool with 15 built-in seed fragments + LLM-generated diverse fragments. Extract structural features (AST analysis) and behavioral profiles (LLM), compute novelty scores.
2. **Evolve**: Iterate generations of parent selection (top-k novel), child synthesis (LLM crossover + mutation), viability filtering, novelty scoring, and pool/archive insertion with redundancy eviction. Stops at max generations or stagnation limit.
3. **Synthesize**: LLM generates a coherent implementation plan from the most novel evolved fragments.
4. **Apply**: Spawn a Manager agent with the synthesized solution as its objective; agent makes code changes, commits, and creates branch/PR.

The two modes serve different use cases:
- **`:simple` (Top-Down)**: Used for clear, well-defined tasks. Manager plans and delegates directly.
- **`:complex` (Bottom-Up)**: For open-ended, creative tasks requiring exploration. Engine evolves diverse genetic material before applying a synthesized solution.

## Phase Transitions

There is **no automatic transition** between Genesis and Evolution. The CLI dispatches them as independent commands:

```bash
# Genesis — must be called first to bootstrap the Context Tree
evogit genesis "Create a web app" --mode new

# Evolution — called after Genesis (or on any existing codebase)
evogit evolve "Fix the login bug" --mode simple
```

The `EvoGit.Runtime` module does not have a combined entry point. Each phase is invoked directly:
- `EvoGit.CLI.dispatch(["genesis", ...])` → `Genesis.run/2`
- `EvoGit.CLI.dispatch(["evolve", ...])` → `Evolution.run/2`

## Key Dependencies

| Dependency | Role in Runtime |
|------------|----------------|
| `EvoGit.Core.PhyloGraphNode` | Temporal state — tracks base_commit and current_commit in the git DAG |
| `EvoGit.Core.ContextNode` | Spatial state — represents a directory node in the Context Tree |
| `EvoGit.AgentScheduler` | Lifecycle manager — worktrees, ETS state, slot management, subagent spawning |
| `EvoGit.AgentSpec` | Structured specification passed to scheduler (context_node + phylo_node + module + objective) |
| `EvoGit.Agent.Result` | Structured agent output (result string, commit_sha, tag, branch, base_commit) |
| `EvoGit.Agents.CodebaseArchitect` | Genesis Mode B agent — 3-phase: skeleton → implementation → review |
| `EvoGit.Agents.ContextExtractor` | Genesis Mode A agent — read-only context extraction |
| `EvoGit.Agents.Manager` | Evolution simple mode agent — planning, delegation, validation |
| `EvoGit.Agents.Executor` | Code implementation subagent (spawned by Manager) |
| `EvoGit.Agents.TaskScheduler` | Lightweight task scheduling subagent (spawned by Manager for complex tasks) |
| `EvoGit.Agents.Generalist` | General-purpose subagent (used by CodebaseArchitect for implementation) |
| `EvoGit.Adapters.Git` | All git CLI operations |
| `EvoGit.Task` | Lower-level `mutate/3`, `diagnose/3`, `resolve_conflict/3` — not used directly by runtime phases |
| `ReqLLM` | LLM streaming for PR title generation in `PullRequest`, and for evolution synthesis/behavioral profiling |
| `EvoGit.Runtime.Evolution.Engine` | Complex mode orchestrator — novelty-driven evolution loop |
| `EvoGit.Runtime.Evolution.Fragment` | Code fragment data structure with structural features and behavioral profiles |
| `EvoGit.Runtime.Evolution.SeedFragments` | Built-in + LLM-generated diverse seed fragments for pool initialization |
| `EvoGit.Runtime.Evolution.EntropyPool` | ETS-backed GenServer for fragment storage with novelty-based selection |
| `EvoGit.Runtime.Evolution.MapElites` | Quality diversity archive — grid of behavior descriptors to elite solutions |
| `EvoGit.Runtime.Evolution.NoveltyMetric` | k-NN novelty scoring, AST structural analysis, LLM behavioral profiling |
| `EvoGit.Runtime.Evolution.LLMSynthesis` | LLM-powered semantic crossover, mutation, and viability evaluation |

## Constraints

- Both phases follow the same pattern: ensure repo → create phylo node → load context node → build spec → run agent → handle result.
- Agent changes go to **isolated branches** (`evogit/genesis_<hex>` / `evogit/evolve_<hex>`), never directly to the working tree. PR creation is optional (requires `gh` CLI).
- `merge_and_report/3` is shared via `EvoGit.Runtime.Helpers` — both phases delegate to `Helpers.merge_and_report(repo_path, agent_output, phase)` where phase is `"genesis"` or `"evolve"`.
- Complex/Bottom-Up evolution mode delegates to `Engine.run/5` which manages its own temporary supervisor tree for `EntropyPool` and `MapElites` GenServers.
- No centralized `prompts.ex` — all prompt text lives in agent modules' `system_prompt/0` callbacks or inline in `EvoGit.Task`.
- PR creation is best-effort and never fails the overall phase — all PR errors are logged and return `nil`.
- `node_path` validation in Evolution requires a `CONTEXT.md` at the target directory (except root).
- Foreign repos are registered with `AgentScheduler` at the start of each phase if provided.
