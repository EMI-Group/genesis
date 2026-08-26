# Runtime

## Intent
Implements the two-phase execution engine of EvoGit: **Genesis** (initial codebase creation or analysis of an existing codebase) and **Evolution** (iterative modification loop). A shared `PullRequest` module handles post-phase PR creation. There is no centralized `EvoGit.Runtime.Prompts` module — prompts live in agent `system_prompt/0` callbacks and inline strings.

## Routing Table

None — leaf directory (modules: `runtime.ex` (parent dir `../runtime.ex`), `helpers.ex`, `genesis.ex`, `evolution.ex`, `pull_request.ex`, `worktree_init_script.ex`, `skill_extraction.ex`, `self_reflective.ex`).

## API Surface

### Modules

| Module | File | Public API | Description |
|--------|------|------------|-------------|
| `EvoGit.Runtime` | `../runtime.ex` | `ensure_repo/1` | Initializes a git repo with `.gitignore` if missing. The CLI calls `Genesis.run/2` / `Evolution.run/2` directly — no combined orchestration entry point. |
| `EvoGit.Runtime.Helpers` | `helpers.ex` | `merge_and_report/3`, `notify_finalizing/1`, `generate_branch_name/1`, `new_codebase?/1`, `validate_node_path/2`, `resolve_starting_commit/2`, `load_foreign_repos/2`, `merge_foreign_repos/2` | Shared helpers for both phases — branch creation, change detection, node path validation, commit resolution. `load_foreign_repos/2` merges `genesis.toml` foreign repos with CLI-provided repos (CLI precedence); used by all four runtime call sites (Genesis Mode A/B, Evolution, SkillExtraction). `merge_foreign_repos/2` normalizes BOTH lists via `EvoGit.Core.ForeignRepo.normalize/1` before dedup-by-id merge (unparseable entries dropped) — entries may be `%ForeignRepo{}` structs, atom-keyed, or string-keyed maps (SQLite Codec JSON round-trip); raw dot-access on map entries raises `KeyError`. |
| `EvoGit.Runtime.Genesis` | `genesis.ex` | `run/2` | Stage 1 — Creation/Analysis. Auto-detects mode. Returns `{:ok, %{commit_sha, result, tag, branch_name, pr_url}}` or `{:ok, %{..., no_changes: true}}`. |
| `EvoGit.Runtime.Evolution` | `evolution.ex` | `run/2` | Stage 2 — Evolutionary Loop. Modes `:simple` and `:custom`. Same return shape as Genesis. |
| `EvoGit.Runtime.PullRequest` | `pull_request.ex` | `try_create/4`, `generate_title/2`, `format_body/2` | Shared PR utilities: LLM-powered title generation, body formatting, push + PR creation via `gh` CLI. |
| `EvoGit.Runtime.WorktreeInitScript` | `worktree_init_script.ex` | `build_systems/0`, `get_build_system/1`, `scripts_for/1` | Predefined catalog of Worktree Init Scripts for common build systems (Elixir, Node.js, Python, Rust, Go, None); per entry unix (bash) + windows (PowerShell) scripts that copy deps/build artifacts from the source repo into new worktrees. Genesis Mode B writes selected scripts to `genesis.toml` as `script.linux`/`script.macos`/`script.windows` variants. |
| `EvoGit.Runtime.SkillExtraction` | `skill_extraction.ex` | `run/1` | Analyzes a completed PR's changes and distills reusable knowledge into EvoGit skills (`.agents/skills/`). Takes a PR-context keyword list (title, objective, summary, commit history, base_sha, commit_sha, user_note), builds the objective, and spawns a `SkillExtractor` agent. |
| `EvoGit.Runtime.SelfReflective` | `self_reflective.ex` | `run/1`, `run/2`, `source_root/0`, `build_spec/2` | Repo-less self-reflective runtime — chatbot-style system introspection. `source_root/0` delegates to the shared chain `EvoGit.SelfReflectiveSource.reference_path/0` (`:self_reflective_source_root` app env → `GENESIS_SOURCE_ROOT` env var → valid managed clone at `<data_dir>/genesis-source`), terminal fallback `File.cwd!()` — same implementation as `Dispatch.resolve_repo_less_root/0`. `run/2` builds a repo-less spec (phylo nil; context node over the source root when a real dir, else bare `%ContextNode{}` with `"[system]"` placeholder repo), spawns `EvoGit.Agents.SelfReflective` via `AgentScheduler.run_agent/1`, returns `{:ok, %{result: ..., commit_sha: nil, branch_name: nil, tag: nil}}` — no git ops, no merge_and_report, no PR. `build_spec/2` is a test seam (`spec.opts[:repo_less] == true`). Task-type `:reflect` routes here via `TaskExecutor.execute_task/3` (see `task_registry/CONTEXT.md`). |

### `Genesis.run/2` — Steps

1. Parse opts: `repo_path` (default `File.cwd!()`), `foreign_repos`; register foreign repos with `AgentScheduler`.
2. `Runtime.ensure_repo/1` (`git init` if needed); HEAD via `PhyloGraphNode.current_head/1`.
3. Detect mode via `new_codebase?/1` (files beyond `.git`, `README.md`, `.genesis`, `.gitignore`).
4. Mode B only: read `build_system` opt (CLI `--build-system`), `WorktreeInitScript.scripts_for/1` → write `script.linux`/`script.macos`/`script.windows` to `genesis.toml` via `ProjectConfig.write_worktree_script/2`. Skipped when no build system or `:none`.
5. Dispatch: **Mode A (Existing)** → `ContextExtractor` (read-only, recursive CONTEXT.md tree extraction). **Mode B (New)** → `Architect` (read-write, 3-phase: architecture & design → implementation delegation → review & accountability) + second root `Manager` for implementation.
6. `AgentSpec.new(context_node, phylo_node, agent_module, objective)` → `AgentScheduler.run_agent/1` (blocks until complete).
7. Post-processing `merge_and_report/3`: base SHA vs final SHA; changed → `genesis/agent_<hex>` branch at agent commit (+ optional PR); unchanged → `no_changes: true`.

### `Evolution.run/2` — Steps

1. Parse opts: `repo_path`, `mode`, `node_path` (default `"./"`), `foreign_repos`.
2. `mode_atom/1` (`@doc false` test wrapper): nil/absent, `:simple`, `"simple"` → `:simple`; `:custom`/`"custom"` → `:custom`; ANY other value → warning + `:simple` fallback.
3. Custom mode requires an `agent:` opt — nil/empty raises `ArgumentError` ("custom mode requires an agent id; pass agent: <id> (defined in agents.toml)") BEFORE repo/git I/O; unknown ids raise in `Helpers.resolve_root_agent/2`.
4. Register foreign repos; ensure repo + HEAD (same as Genesis).
5. `validate_node_path/2`: path relative, dir exists, contains `CONTEXT.md` (root `"./"` always passes).
6. Dispatch: `:simple` → `Manager` agent (plans, delegates to Executor/TaskScheduler/Investigator subagents); `:custom` → `EvoGit.Agents.Custom` root bound to the `agent:` id. Both modes share one private flow `run_resolved_root_agent/7` parameterized by the resolved root-agent module/opts.
7. Post-processing: same `merge_and_report/3` pattern.

### `starting_commit` Opt — Evolution Only (Genesis Ignores It)

`TaskRegistry.RuntimeOpts.build_common_runtime_opts/3` (`task_registry/runtime_opts.ex:32-37`) passes `:starting_commit` into runtime opts for BOTH `:genesis` and `:evolve`; the CLI passes it for evolve (`cli.ex:89`, `--starting-commit`, `cli/parser.ex:34`). **Only `Evolution.run/2` reads it** (`evolution.ex:14,23` → `Helpers.resolve_starting_commit/2`, `helpers.ex:167-180`: nil → `PhyloGraphNode.current_head/1`; ref → `Git.rev_parse`, error propagates as phase error). `Genesis.run/2` has no `starting_commit` clause — it always starts from `PhyloGraphNode.current_head(repo_path)` (`genesis.ex:23`); a genesis `:starting_commit` is silently ignored. `ResumeContext.apply_resume_context/3` (`task_registry/resume_context.ex:43-54`) sets `:starting_commit` to the previous task's `commit_sha` for evolve-resume tasks (context block prepended to the objective).

**Path to the agent**: resolved SHA → `PhyloGraphNode.new(repo_path, current_sha)` (`phylo_graph_node.ex:23-24`; both `base_commit`/`current_commit` = SHA) → `AgentSpec.phylo_node` → `AgentScheduler.run_agent/1` (`agent_scheduler.ex:593-641`) → worktree created AT that commit: `Worktrees.create_worktree/6` (`worktrees.ex:96-137`) uses `spec.phylo_node.current_commit` for `CowWorktree.create_worktree`/`Git.add_worktree`; `assign_and_prepare_worktree/2` (`worktrees.ex:233-259`) rebuilds the worktree-bound phylo node (repo = worktree path) into ETS. The SHA is NOT injected into prompt text — the agent learns its starting point from the worktree contents (`base_commit`/`current_commit` live only in ETS; described abstractly in Manager's `system_prompt/0`, `agents/manager.ex:57,63`).

### Genesis Mode B Second Root

The second root (`Manager`) spawns only in Mode B after a successful Architect run (`genesis.ex:110-123` → `run_implementation_phase/8`, `genesis.ex:132-217`). No condition on repo non-emptiness or `starting_commit != base` — Mode B is gated only by `resolve_mode/2` (`genesis.ex:238-244`: explicit `:mode` opt or `Helpers.new_codebase?/1`, `helpers.ex:113-121`). The Manager's phylo node starts at the architect's final commit (`architect_output.commit_sha || base_sha`, `genesis.ex:143-144`). Both roots share one `task_id` (`genesis.ex:68-72`); the scheduler's cancel guard (`agent_scheduler.ex:597-607`) refuses the second root when the task is cancelling. On implementation-phase failure the architect's output is merged as partial success (`genesis.ex:208-216`).

### `merge_and_report` Never Merges — `Task.resolve_conflict/3` Is Dead Code

`merge_and_report/3` (`helpers.ex:11-100`) only `rev_parse`s HEAD + `Git.create_branch(repo_path, branch_name, final_sha)` (`helpers.ex:24`) — the agent commit is NOT merged into any target branch; PR creation is not done here. No conflict path in the phases. `EvoGit.Task.resolve_conflict/3` (`task.ex:115-190`) is dead code (no caller anywhere in `apps/`, rg-verified): it git-merges `incoming_sha` into `phylo_node.current_commit` and, on `{:error, {:conflict, _}}`, spawns one `Manager` per conflicted file with an inline conflict-resolution prompt (`task.ex:157-165`), then commits. Real branch merging with conflict reporting lives in `EvoGit.Review.merge_branch/2,3` (dashboard Review flow → `{:conflict, details}`).

### `PullRequest.try_create/4` — Steps

1. `Git.gh_available?/0` check.
2. `Git.has_origin_remote?/1`; if none, `Git.create_origin_remote/1`.
3. Base branch from `Git.origin_default_branch/1`.
4. `generate_title/2` — optional LLM (ReqLLM streaming) ≤8-word title, falls back to branch name.
5. `format_body/2` — header `## 🤖 Auto-generated by EvoGit` + agent result.
6. `Git.push_branch/2` → `Git.create_pull_request/5`.
7. Returns PR URL on success, `nil` on any failure (never raises).

## Constraints

- Both phases: ensure repo → create phylo node → load context node → build spec → run agent → handle result.
- Agent changes go to **isolated branches** (`genesis/agent_<hex>`), never the working tree. PR creation is optional (requires `gh` CLI).
- `merge_and_report/3` is shared via `EvoGit.Runtime.Helpers` — `Helpers.merge_and_report(repo_path, agent_output, phase)` where phase is `"genesis"` or `"evolve"`.
- No centralized `prompts.ex` — all prompt text lives in agent modules' `system_prompt/0` callbacks or inline in `EvoGit.Task`.
- PR creation is best-effort and never fails the phase — all PR errors are logged and return `nil`.
- Evolution `node_path` validation requires a `CONTEXT.md` at the target directory (except root).

### Task Status & Event Emission (Dashboard Contract)

`EvoGit.TaskRegistry` (started by `EvoGit.Application`) tracks task status via TWO mechanisms:

1. **PubSub topic `"tasks"`**: the ONLY runtime-phase emitter is `Helpers.notify_finalizing/1` (`helpers.ex:72-76`; `notify_finalizing(nil)` = `:ok` no-op), broadcasting `{:task_updated, task_id, :finalizing, node()}` immediately after `AgentScheduler.run_agent/1` returns, BEFORE `merge_and_report/3`. Callers: `genesis.ex:57` (Mode A success), `genesis.ex:216` (Mode B implementation success), `genesis.ex:246` (Mode B implementation ERROR arm — partial-success, architect result merged/reported), `evolution.ex:55`, `skill_extraction.ex:34`. No `task_id` (plain CLI path) → no-op; the dashboard path (`TaskExecutor`) always passes it. No `:failed`/`:completed`/`:running` is EVER broadcast on `"tasks"` from the runtime phase modules — the full status set (`:running`, `:cancelling`, `:completed`, `:failed`, `:cancelled`, `:finalizing`, plus `nil` for review-status/review-metadata mutations and `{:task_deleted, task_id, node()}` for deletions) is emitted by `EvoGit.TaskRegistry` (see `lib/evo_git/task_registry/CONTEXT.md`). `AgentScheduler.PubSub` uses different topics/shapes: `"agents"` → `{:agent_registered|:agent_updated|:agent_removed, ..., node}` + `{:agents_updated, node}`; `"scheduler_config"` → `{:scheduler_config_updated, node}`.
2. **Task monitor exit** (`Task.Supervisor.async_nolink` in `EvoGit.TaskRegistry`): any non-`{:ok, _}` runtime-process result (incl. `{:error, _}`) maps to `:failed`.

**Finalizing window** (between the `:finalizing` broadcast and the phase return) contains ONLY: the broadcast, (Mode B success) in-memory `Usage.add`/result merging (`genesis.ex:219-236`), and `merge_and_report/3`'s git calls — `Git.rev_parse` (helpers.ex:16 → git.ex:162-164) + `Git.create_branch` (helpers.ex:24 → git.ex:409-412), both via `Git.run/2` → raw `System.cmd` with **NO timeout (`:infinity`)** (git.ex:18-29) — they can block indefinitely on a slow filesystem (e.g. NFS-mounted home on a remote daemon). `merge_and_report/3` NEVER raises and ALWAYS returns `{:ok, map}`: branch-creation/`rev_parse` failure → success maps with `branch_name: nil` (helpers.ex:43-61, 82-98); `no_changes: true` when base==final SHA. It does NOT create PRs (`pr_url`/`pr_title` always `nil`; PR creation is `PullRequest.try_create/4`, called only from `EvoGit.Review` review.ex:331). Worktree cleanup is NOT in the window: `WorktreeManager` reclaims + destroys via its process monitor on agent exit (`:DOWN` — `File.rm_rf` → `Git.prune_worktrees` → `Git.delete_branch`), asynchronous, never blocks the finalizing path (`Lifecycle.recycle_agent/2` before `run_agent/1` replies performs no worktree I/O).

**Critical implication**: every runtime entry point (`Genesis.run/2`, `Evolution.run/2`, `SkillExtraction.run/1`) returns whatever `AgentScheduler.run_agent/1` returns on the `error` arm — `{:error, _}` propagates to the dashboard, which marks the task `:failed`. The scheduler replies `{:error, _}` in two cases: top-level agent permanently failed (crashed `agent_max_retries` times) → `{:error, :agent_max_retries_exceeded}` (lifecycle.ex:238); top-level agent cancelled → `{:error, :cancelled}` (lifecycle.ex:72). Graceful `{:error, :recovery_failed}` / `{:error, :path_not_exist}` also map to `:failed` (exit the Task `:normal` but non-`{:ok, _}`). See `agent_scheduler/lifecycle.ex` + the `:DOWN` handler (`agent_scheduler.ex:826`) for the full crash→retry→permanent-failure cascade.

### ETS Table Ownership & Crash Resilience

- The three scheduler ETS tables (`:evogit_agent_state`, `:evogit_sched_meta`, `:evogit_archive_records`) are created in `EvoGit.Application.start/2` (`application.ex:13-15`) via the idempotent `ensure_ets_table/2`, owned by the long-lived application process; `AgentScheduler.init/1` only warns if a table is missing. Tables survive an `AgentScheduler` crash/restart.
- `EvoGit.AgentGroupSupervisor` is `strategy: :one_for_all` over `EvoGit.TaskSupervisor` + `EvoGit.AgentScheduler` — a scheduler crash kills/restarts the TaskSupervisor, tearing down ALL running agent Tasks (no orphaned agents). Agent Tasks are spawned via `Task.Supervisor.async_nolink/4` (monitored by the scheduler, NOT linked to the wrapper).
- `merge_and_report/3` is failure-tolerant: `with`/graceful `else` clauses, always `{:ok, _}` — failure → `branch_name: nil`, the agent's committed work remains valid.
- Foreign repos are registered with `AgentScheduler` at the start of each phase if provided.

## Agent Spawning & Coordination

### How Agents Are Spawned

Both phases build an `AgentSpec` and call `AgentScheduler.run_agent/1` (synchronous GenServer call blocking until the agent completes):

```
AgentSpec.new(context_node, phylo_node, agent_module, objective, opts)
|> AgentScheduler.run_agent()
```

The scheduler: 1) assigns a unique `task_id` (GUID), `task_number` (short integer), `agent_id` (`T<task_number>_A<task_local_id>`); 2) computes the worktree path (`worker_T<task_number>_A<task_local_id>`) into sched_meta — **no worktree I/O here**; 3) stores initial state in `:evogit_agent_state` (agent-owned) + `:evogit_sched_meta` (scheduler-owned); 4) spawns a Task running the agent loop; 5) inside the Task, `Runner.setup_dispatch_context/1` requests a FRESH worktree from `WorktreeManager.create_worktree_for_agent/6` (1-hour call; lazy per-repo init + the create pipeline — `git clean`/checkout/init script — offloaded inside WorktreeManager); 6) on `complete_task`/crash/cancel → WorktreeManager reclaims the worktree via its `:DOWN` process monitor, scheduler replies to caller.

### Agent Hierarchy by Phase

- **Genesis Mode A (Existing)**: `ContextExtractor` root → recursive `subagent_context_extractor` children (one per child dir).
- **Genesis Mode B (New)**: `Architect` root (architecture phase; optional `subagent_genesis_planner` for large-scale planning, `subagent_executor` for design artifacts — CONTEXT.md/init commands/directories/API stubs, recursive `subagent_architect` + `subagent_executor` per child dir, `subagent_manager` for implementation delegation) → then `Manager` root (implementation phase, second root agent, same `task_id`) → `subagent_executor`/`subagent_manager` subtrees. Mode B spawns TWO sequential root agents sharing a `task_id`.
- **Evolution Simple Mode**: `Manager` (target node) → `subagent_task_scheduler` (complex objectives — execution sequence), `subagent_investigator` (codebase exploration), `subagent_executor` (code changes), `subagent_manager` (child-node delegation).
- **Evolution Custom Mode**: `EvoGit.Agents.Custom` root (resolved from agents.toml via the `agent:` opt) → subagent modules declared in the custom agent definition. Custom agents are ROOT-only; the module resolves its definition (system prompt, tools, subagents, max_turns, model_id) at run time from `agents.toml` via the process-dictionary `:custom_agent_id` bridge.

### Subagent Spawning Mechanics

`AgentScheduler.spawn_sub_agents/2` (from within the agent process): validates depth ≤ `max_agent_depth`; checks the parent's path isn't git-ignored; marks parent `:waiting` (parent Task blocked; its worktree stays alive — reclaim only on process exit via WorktreeManager's `:DOWN` monitor); dispatches each subagent with its own fresh worktree + incremented task-local ID; blocks until all subagents complete, returns results in order.

## Phase Transitions

No automatic transition between Genesis and Evolution — the CLI dispatches them as independent commands:

```bash
# Genesis — must be called first to bootstrap the Context Tree
evogit genesis "Create a web app" --mode new

# Evolution — called after Genesis (or on any existing codebase)
evogit evolve "Fix the login bug" --mode simple
```

`EvoGit.Runtime` has no combined entry point; each phase is invoked directly:
- `EvoGit.CLI.dispatch(["genesis", ...])` → `Genesis.run/2`
- `EvoGit.CLI.dispatch(["evolve", ...])` → `Evolution.run/2`

## Key Dependencies

| Dependency | Role in Runtime |
|------------|----------------|
| `EvoGit.Core.PhyloGraphNode` | Temporal state — tracks base_commit/current_commit in the git DAG |
| `EvoGit.Core.ContextNode` | Spatial state — represents a directory node in the Context Tree |
| `EvoGit.AgentScheduler` | Lifecycle manager — scheduling, ETS state, slot management, subagent spawning (worktree lifecycle owned by `EvoGit.AgentScheduler.WorktreeManager`) |
| `EvoGit.AgentSpec` | Structured specification passed to scheduler (context_node + phylo_node + module + objective) |
| `EvoGit.Agent.Result` | Structured agent output (result string, commit_sha, tag, branch, base_commit) |
| `EvoGit.Agents.Architect` | Genesis Mode B agent — 3-phase: architecture & design → implementation delegation → review & accountability; accountable for all code in its node path, delegates implementation to Manager subagents |
| `EvoGit.Agents.ContextExtractor` | Genesis Mode A agent — read-only context extraction |
| `EvoGit.Agents.Manager` | Evolution simple-mode root — planning, delegation, validation; also Genesis second root for implementation (after Architect) |
| `EvoGit.Agents.Executor` | Code implementation subagent (spawned by Manager) |
| `EvoGit.Agents.TaskScheduler` | Lightweight task scheduling subagent (spawned by Manager for complex tasks) |
| `EvoGit.Adapters.Git` | All git CLI operations |
| `EvoGit.Task` | Lower-level `mutate/3`, `diagnose/3`, `resolve_conflict/3` — not used directly by runtime phases (`resolve_conflict/3` is dead code) |
| `ReqLLM` | LLM streaming for PR title generation in `PullRequest` |

## Known Issues — repo_path Resolution vs. BEAM cwd (dashboard Windows path bug)

- All three `run/2` entry points resolve a possibly-relative/name-only `:repo_path` against the **BEAM process cwd**: `genesis.ex:20`, `evolution.ex:20`, `skill_extraction.ex:13` — `repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()`.
- The desktop Tauri sidecar spawns the release launcher with **no `current_dir` set** (`desktop/src-tauri/src/sidecar.rs:147-152`) → BEAM cwd inherited from the Tauri process (typically the app install/data dir; Windows: `%LOCALAPPDATA%\genesis-desktop`). `"Test"` → `c:/Users/<user>/AppData/Local/genesis-desktop/Test`. `Runtime.ensure_repo/1` (`runtime.ex:14-32`) **silently `File.mkdir_p!`s + git-inits** a missing repo dir — a name-only path creates a stray repo under the app dir instead of erroring.
- The string "Directory does not exist: <path>" in evo_git is produced ONLY by `Helpers.validate_node_path/2` (`helpers.ex:136`), called from `evolution.ex:35` (evolve tasks with a `:node_path` opt); it prints the raw `node_path` (repo-relative sub-path), NOT the joined `abs_path`. The first branch (`helpers.ex:126-129`) rejects absolute node_paths ("Node path must be relative..."), so on a Windows host the reported full-path string comes from dashboard-side flash messages that print the raw submitted path: `apps/evo_dash/lib/evo_dash_web/live/projects_live/project_flow.ex` `open_project/2`/`select_project/2`; `projects_live.ex` `handle_palette_key/3` (`"Enter"` in `:menu` mode). The dashboard reduces a picked absolute path to its basename only in the JS File System Access API fallback (`apps/evo_dash/assets/js/app.js:171` — `fillInput(handle.name)`), after which `Path.expand/1` (`project_flow.ex:33,98,130`) resolves the bare name against the BEAM cwd.
- **No absolute-ness/existence validation of `:path`/`:repo_path` exists between the dashboard and the runtime**: `TaskRegistry.start_task/2` (`task_registry.ex:51-54`) → `RuntimeOpts.build_common_runtime_opts` (`runtime_opts.ex:17` — `Keyword.fetch!(opts, :path)`, verbatim) → runtime. Only existence checks: `Adapters.Git.run/2` pre-check `File.dir?(cd)` → `{:error, {:enoent, "Repository path does not exist: #{cd}"}}` (`adapters/git.ex:45`) and `validate_node_path/2` (node sub-paths only). `TaskRegistry.add_recent_project/2` (`task_registry.ex:481-494`) stores the path verbatim — no expansion, no validation.
- **Fix direction**: validate/expand the project path at the task boundary (TaskRegistry or RuntimeOpts) and reject non-absolute paths; the dashboard's `ProjectFlow` already expands before registering recents, so the runtime should do the same (and/or `Runtime.ensure_repo/1` should require an absolute path).
