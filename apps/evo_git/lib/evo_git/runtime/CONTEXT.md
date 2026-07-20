# Runtime

## Intent
Implements the two-phase execution engine of EvoGit: **Genesis** (initial codebase creation or analysis of an existing codebase) and **Evolution** (iterative modification loop). A shared `PullRequest` module handles post-phase PR creation. The design doc's centralized `EvoGit.Runtime.Prompts` module was never implemented — prompts live in agent `system_prompt/0` callbacks and inline strings.

## Routing Table

None — leaf directory (modules: `runtime.ex`, `helpers.ex`, `genesis.ex`, `evolution.ex`, `pull_request.ex`, `worktree_init_script.ex`, `skill_extraction.ex`).

## API Surface

### Modules

| Module | File | Public API | Description |
|--------|------|------------|-------------|
| `EvoGit.Runtime` | `../runtime.ex` | `ensure_repo/1` | Top-level coordinator. `ensure_repo/1` initializes a git repo with `.gitignore` if missing. The CLI (`EvoGit.CLI`) calls `Genesis.run/2` and `Evolution.run/2` directly — there is no combined orchestration entry point. |
| `EvoGit.Runtime.Helpers` | `helpers.ex` | `merge_and_report/3`, `notify_finalizing/1`, `generate_branch_name/1`, `new_codebase?/1`, `validate_node_path/2`, `resolve_starting_commit/2` | Shared helper functions for both runtime phases — branch creation, change detection, node path validation, commit resolution. |
| `EvoGit.Runtime.Genesis` | `genesis.ex` | `run/2` | Stage 1 — Creation/Analysis. Auto-detects mode. Returns `{:ok, %{commit_sha, result, tag, branch_name, pr_url}}` or `{:ok, %{..., no_changes: true}}`. |
| `EvoGit.Runtime.Evolution` | `evolution.ex` | `run/2` | Stage 2 — Evolutionary Loop. Supports `:simple` mode only. Same return shape as Genesis. |
| `EvoGit.Runtime.PullRequest` | `pull_request.ex` | `try_create/4`, `generate_title/2`, `format_body/2` | Shared PR utilities: LLM-powered title generation, body formatting, push + PR creation via `gh` CLI. |
| `EvoGit.Runtime.WorktreeInitScript` | `worktree_init_script.ex` | `build_systems/0`, `get_build_system/1`, `scripts_for/1` | Predefined catalog of Worktree Init Scripts for common build systems (Elixir, Node.js, Python, Rust, Go, None). Each entry provides unix (bash) and windows (PowerShell) scripts that copy dependencies/build artifacts from the source repo into new worktrees. Genesis Mode B writes the selected scripts to `genesis.toml` as OS-specific variants (`script.linux`, `script.macos`, `script.windows`) so the existing per-worktree init-script infrastructure picks them up. |
| `EvoGit.Runtime.SkillExtraction` | `skill_extraction.ex` | `run/1` | Skill Extraction Phase — analyzes a completed PR's changes and distills reusable knowledge into EvoGit skills (`.agents/skills/`). Takes a keyword list of PR context opts (title, objective, summary, commit history, base_sha, commit_sha, user_note). Builds the objective from PR context and spawns a `SkillExtractor` agent. |

### `Genesis.run/2` — Step by Step

1. **Parse options**: Extracts `repo_path` (default `File.cwd!()`), `foreign_repos`.
2. **Register foreign repos**: If `foreign_repos` provided, registers them with `AgentScheduler`.
3. **Ensure repo**: Calls `Runtime.ensure_repo/1` to `git init` if needed.
4. **Get HEAD**: `PhyloGraphNode.current_head/1` → current commit SHA.
5. **Detect mode**: `new_codebase?/1` checks if directory has files beyond `.git`, `README.md`, `.genesis`, `.gitignore`.
6. **Worktree init script (Mode B only)**: Before spawning the agent, `Genesis` reads `build_system` from opts (selected interactively via CLI or via `--build-system` flag), looks up predefined scripts via `WorktreeInitScript.scripts_for/1`, and writes them to `genesis.toml` as OS-specific variants (`script.linux`, `script.macos`, `script.windows`) via `ProjectConfig.write_worktree_script/2` so the existing per-worktree init-script infra copies deps/build cache into new worktrees. Skipped when no build system is selected or `:none` is chosen.
7. **Dispatch agent**:
   - **Mode A (Existing)** → `ContextExtractor` agent (read-only, builds CONTEXT.md tree via recursive subagent extraction).
   - **Mode B (New)** → `CodebaseLead` agent (read-write, 3-phase: architecture & design → implementation delegation → review & accountability). Also spawns a second root Manager agent for implementation.
8. **AgentSpec construction**: `AgentSpec.new(context_node, phylo_node, agent_module, objective)` → `AgentScheduler.run_agent/1` (blocks until complete).
9. **Post-processing** (`merge_and_report/3`): Compares base SHA vs agent's final SHA. If changed, creates `evogit/genesis_<hex>` branch at agent commit, optionally creates PR. If unchanged, returns `no_changes: true`.

### `Evolution.run/2` — Step by Step

1. **Parse options**: Extracts `repo_path`, `mode` (default `:simple`), `node_path` (default `"./"`), `foreign_repos`.
2. **Register foreign repos**: Same as Genesis.
3. **Ensure repo + get HEAD**: Same as Genesis.
4. **Validate node path**: `validate_node_path/2` ensures path is relative, directory exists, and contains `CONTEXT.md` (root `"./"` always passes).
5. **Dispatch agent**: Spawns a `Manager` agent (plans, delegates to Executor/TaskScheduler/Investigator subagents).
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
1. Assigns a unique `task_id` (GUID) and `task_number` (short integer), and `agent_id` (format: `T<task_number>_A<task_local_id>`).
2. Allocates an isolated git worktree (directory: `worker_T<task_number>_A<task_local_id>`).
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
CodebaseLead (root — architecture phase)
  ├── subagent_genesis_planner (optional — large-scale planning)
  ├── subagent_executor (design artifacts: CONTEXT.md, init commands, directories, public API stubs)
  ├── subagent_codebase_lead (child dir architecture)
  │     ├── subagent_codebase_lead (grandchild...)
  │     └── subagent_executor (design artifacts)
  └── subagent_manager (implementation delegation)

Manager (root — implementation phase, second root agent, same task_id)
  ├── subagent_executor (code changes)
  ├── subagent_manager (child subtree implementation)
  └── ...
```
Note: Mode B spawns TWO sequential root agents sharing a task_id — CodebaseLead first (architecture), then Manager (implementation).

**Evolution Simple Mode**:
```
Manager (target node)
  ├── subagent_task_scheduler (complex objectives — produces execution sequence)
  ├── subagent_codebase_investigator (codebase exploration)
  ├── subagent_executor (code changes)
  ├── subagent_manager (delegation to child nodes)
  └── ...
```

### Subagent Spawning Mechanics

Agents call `AgentScheduler.spawn_sub_agents/2` (from within the agent process). The scheduler:
- Validates depth doesn't exceed `max_agent_depth`.
- Checks the parent's path isn't git-ignored.
- Marks parent as `:waiting` (its worktree becomes reclaimable if pool is exhausted).
- Dispatches each subagent with its own worktree and incremented task-local ID.
- Blocks until all subagents complete, returns results in order.

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
| `EvoGit.Agents.CodebaseLead` | Genesis Mode B agent — 3-phase: architecture & design → implementation delegation → review & accountability. Accountable for all code in its node path but delegates implementation to Manager subagents. |
| `EvoGit.Agents.ContextExtractor` | Genesis Mode A agent — read-only context extraction |
| `EvoGit.Agents.Manager` | Evolution simple mode agent — planning, delegation, validation; also used in genesis as the second root agent for implementation (after CodebaseLead establishes architecture) |
| `EvoGit.Agents.Executor` | Code implementation subagent (spawned by Manager) |
| `EvoGit.Agents.TaskScheduler` | Lightweight task scheduling subagent (spawned by Manager for complex tasks) |
| `EvoGit.Adapters.Git` | All git CLI operations |
| `EvoGit.Task` | Lower-level `mutate/3`, `diagnose/3`, `resolve_conflict/3` — not used directly by runtime phases |
| `ReqLLM` | LLM streaming for PR title generation in `PullRequest` |

## Constraints

- Both phases follow the same pattern: ensure repo → create phylo node → load context node → build spec → run agent → handle result.
- Agent changes go to **isolated branches** (`evogit/genesis_<hex>` / `evogit/evolve_<hex>`), never directly to the working tree. PR creation is optional (requires `gh` CLI).
- `merge_and_report/3` is shared via `EvoGit.Runtime.Helpers` — both phases delegate to `Helpers.merge_and_report(repo_path, agent_output, phase)` where phase is `"genesis"` or `"evolve"`.
- No centralized `prompts.ex` — all prompt text lives in agent modules' `system_prompt/0` callbacks or inline in `EvoGit.Task`.
- PR creation is best-effort and never fails the overall phase — all PR errors are logged and return `nil`.
- `node_path` validation in Evolution requires a `CONTEXT.md` at the target directory (except root).

### Task Status & Event Emission (Dashboard Contract)
`EvoGit.TaskRegistry` (in `:evo_git`, started by `EvoGit.Application`) tracks task status via TWO mechanisms:
1. **PubSub** on topic `"tasks"`: the ONLY emitter is `Helpers.notify_finalizing/1` (`helpers.ex:102`, broadcast at line 104), broadcasting `{:task_status, task_id, :finalizing}`. This is called ONLY on the `{:ok, _}` success arm, immediately after `AgentScheduler.run_agent/1` returns and BEFORE `merge_and_report/3`. No `:failed`, `:completed`, or `:running` is EVER broadcast on `"tasks"` from the evo_git runtime. (`AgentScheduler.PubSub` broadcasts on *different* topics — `@agent_topic` (`"agents"`) / `@config_topic` (`"scheduler_config"`) — with different message shapes: `{:agents_updated}` and `{:scheduler_config_updated}`.) Callers of `notify_finalizing/1`: `genesis.ex:51` (Mode A) & `:78` (Mode B); `evolution.ex:58`; `skill_extraction.ex:34`.
2. **Task monitor exit** (`Task.Supervisor.async_nolink` in `EvoGit.TaskRegistry`): when the runtime process exits, ANY non-`{:ok, _}` result (including `{:error, _}`) is mapped to `:failed`.

**Critical implication**: Every runtime entry point (`Genesis.run/2`, `Evolution.run/2`, `SkillExtraction.run/1`) returns whatever `AgentScheduler.run_agent/1` returns on the `error` arm — propagating `{:error, _}` to the dashboard, which marks the task `:failed`. The scheduler replies `{:error, _}` to the top-level caller in two cases:
- Top-level agent permanently failed (crashed `agent_max_retries` times) → `{:error, :agent_max_retries_exceeded}` (lifecycle.ex:238).
- Top-level agent cancelled → `{:error, :cancelled}` (lifecycle.ex:72).
A graceful agent return of `{:error, :recovery_failed}` / `{:error, :path_not_exist}` also flows through and is mapped to `:failed` (these exit the Task `:normal` but are non-`{:ok, _}`). See `agent_scheduler/lifecycle.ex` and the `:DOWN` handler (`agent_scheduler.ex:826`) for the full crash→retry→permanent-failure cascade.

### Spurious `:failed` Hazard — ETS Ownership & Crash Cascade (FIXED)

⚠️ **The original bug described below has been FIXED in current HEAD** (commit `5f30b0dd`, "fix(evo_git): move ETS table creation to Application to survive AgentScheduler crashes"). The three scheduler ETS tables (`:evogit_agent_state`, `:evogit_sched_meta`, `:evogit_archive_records`) are now created in **`EvoGit.Application.start/2`** (`application.ex:13-15`) via the idempotent `ensure_ets_table/2` helper, owned by the long-lived application process. `AgentScheduler.init/1` now only performs a defensive check (warning if a table is missing). The tables survive an `AgentScheduler` crash/restart.

For historical reference, the ORIGINAL (now-fixed) cascade was: the three ETS tables were created in `AgentScheduler.init/1` and therefore owned by the GenServer process (no `:heir`). If the `AgentScheduler` GenServer crashed and its supervisor restarted it, the tables were destroyed and recreated empty, triggering:
1. `AgentScheduler` crashes → ETS tables destroyed.
2. The EvoDash wrapper process's blocking `GenServer.call(__MODULE__, {:run_agent, spec}, :infinity)` (`agent_scheduler.ex:76-78`) raised (caller died) → wrapper process crashed.
3. EvoDash `TaskRegistry`'s `:DOWN` handler (`task_registry.ex:907`) checked `sched_meta_has_active_agents?(task_id)` against the now-empty/missing ETS table → returned `false`.
4. Task prematurely marked `:failed` (`task_registry.ex:939`) even though the agent processes were still alive under `EvoGit.TaskSupervisor` and would eventually commit their work.

**Note on the supervision restructure**: `EvoGit.AgentGroupSupervisor` (commit `fbe3b0fe`) uses `strategy: :one_for_all` wrapping `EvoGit.TaskSupervisor` and `EvoGit.AgentScheduler`. This means if the `AgentScheduler` GenServer crashes, the `TaskSupervisor` is ALSO killed and restarted, which tears down ALL running agent Task processes. So after the ETS fix, an AgentScheduler crash no longer leaves orphaned agents running (the `one_for_all` strategy tears them down together). Agent Tasks are spawned via `Task.Supervisor.async_nolink/4` (monitored by the scheduler, NOT linked to the wrapper).

A **second, related trigger** was fixed in `f0d01679` ("handle git failures gracefully in merge_and_report/3", IN `HEAD`): the old `merge_and_report/3` used strict matches (`{:ok, base_sha} = Git.rev_parse(...)` and `{:ok, _} = Git.create_branch(...)`) that raised `MatchError` if git failed under concurrent load, crashing the runtime wrapper → task marked `:failed`. The current `helpers.ex:11-100` uses `with`/graceful `else` clauses and always returns `{:ok, _}` (the agent's committed work is valid even if branch creation fails).
- Foreign repos are registered with `AgentScheduler` at the start of each phase if provided.
