# Agent Scheduler Data Structures and Helper Modules

## Intent
Contains data structs and extracted helper modules used internally by `EvoGit.AgentScheduler` GenServer. The data structs back two ETS tables (`:evogit_agent_state` and `:evogit_sched_meta`) tracking agent execution state and scheduling metadata. Helper modules encapsulate slot management, worktree lifecycle, agent dispatching, subagent management, and agent lifecycle logic.

## API Surface

| Module | Description |
|---|---|
| `EvoGit.AgentScheduler.State` | GenServer state struct — configuration, agent lifecycle queues, slot counters |
| `EvoGit.AgentScheduler.AgentState` | Live agent state in `:evogit_agent_state` ETS — context_node, phylo_node, objective, repo_id |
| `EvoGit.AgentScheduler.SchedMeta` | Scheduler-private metadata in `:evogit_sched_meta` ETS — status, depth, worktree, subagent tracking |
| `EvoGit.AgentScheduler.Slots` | Pure-function LLM/tool slot management with FIFO queuing and rate-limit backoff |
| `EvoGit.AgentScheduler.Worktrees` | Pure-function worktree lifecycle: init, assign, prepare, sync, delete, teardown |
| `EvoGit.AgentScheduler.Dispatch` | Agent registration, dispatching, auto-commit, repo root resolution, queue processing |
| `EvoGit.AgentScheduler.Subagents` | Subagent validation/spawning, spatial contract checks, result tracking, parent resumption |
| `EvoGit.AgentScheduler.Lifecycle` | Agent recycling (cleanup) and crash handling (retry logic, permanent failure) |

### Slot Management (Slots module)

Two independent slot pools with FIFO queuing:

| Pool | State Keys | Default Size | Backoff |
|------|-----------|--------------|---------|
| LLM slots | `llm_slots_available`, `llm_waiting`, `llm_backoff_until` | `max_concurrency` (3) | 60s global cooldown on `:rate_limit` errors |
| Tool slots | `tool_slots_available`, `tool_waiting` | `max_tool_concurrency` (2) | None |

All slot functions return `{result, state, status_updates}` where `status_updates` is a list of `{agent_id, :blocked | :running}` tuples applied to ETS SchedMeta for dashboard visibility.

### Multi-Task Repo Root Resolution

The scheduler supports multiple concurrent tasks targeting different repos. Repo root resolution follows this priority:

1. **Per-agent ETS** (`AgentState.repo_root`) — set at registration via `Dispatch.resolve_agent_repo_root/2`, derived from spec data. Used by `Lifecycle` for worktree cleanup.
2. **Process dictionary** (`Process.get(:evogit_repo_root)`) — set at dispatch time in `try_dispatch/2`. Preferred by `current_repo_root/0` for runtime lookups.

There is no global `state.repo_root` fallback — repo root resolution is always per-agent. The scheduler tracks which repos have been initialized via the `initialized_repos` map (`%{String.t() => true}`).

`resolve_agent_repo_root/2` in Dispatch is self-contained for primary repos (strips worktree suffix from `spec.phylo_node.repo`). For foreign repos, it looks up `state.foreign_repos` by `spec.repo_id`.

### Worktree Lifecycle (Worktrees module)

Worktrees are **persistent per-agent** (created on dispatch, reused on retry, deleted on recycle):

1. `ensure_initialized/2` — Creates `.evogit/workers/`, prunes stale worktrees and orphaned branches. Tracks initialized repos in `state.initialized_repos` (`%{String.t() => true}`) to support multiple concurrent tasks targeting different repos. When agents are already running and a new repo comes in, registers it additively in `initialized_repos` without tearing down existing worktrees.
2. `assign_and_prepare_worktree/2` — Cleans worktree, checks out agent branch, binds repo path
3. `run_init_script/2` — Runs optional init script from `evogit.toml` (primary repo only)
4. `sync_current_commit/2` — Reads HEAD SHA and updates both ETS tables if changed
5. `delete/2` — Removes worktree directory, prunes, deletes branch (takes explicit `repo_root` param)
6. `teardown_worktrees/2` — Removes entire worker base directory for a given repo root
7. `teardown_worktrees/1` — Resets the `initialized` flag without filesystem cleanup (for when repo root is unknown)

### Agent Dispatching (Dispatch module)

Handles the mechanics of registering and dispatching agents:

1. `register_agent/6` — Assigns agent IDs, computes task-local IDs, resolves event sink inheritance, writes both ETS tables
2. `try_dispatch/2` — Creates persistent worktree, runs init script, spawns Task, updates ETS
3. `auto_commit_fallback/2` — Commits pending changes before transitions (pre-delegation, completion)
4. `resolve_agent_repo_root/2` — Resolves repo root from spec (primary vs foreign repo)
5. `dispatch_queued_agents/1` — Drains queue dispatching agents (used after resume)
6. `process_queue/1` — Processes queue with ready-parent detection (delegates to Subagents)

### Subagent Management (Subagents module)

Handles subagent validation, spawning, and result collection:

1. `spawn_validated_subagents/5` — Validates all specs, registers valid ones, replies immediately if all invalid
2. `validate_single_subagent/5` — Per-spec validation chain (depth, ignored, spatial)
3. `validate_subagent_depth/3`, `validate_subagent_not_ignored/1` — Individual validation checks
4. `validate_spatial_contract_for_spec/3`, `validate_spawn_spatiality/4` — Spatial contract enforcement
5. `store_sub_result/3` — Stores subagent result at correct index in parent's results map. Also tracks foreign repo commit SHAs in `SchedMeta.foreign_repo_commits` — when a foreign-repo subagent completes successfully, its `commit_sha` is recorded under the `repo_id` key so subsequent subagents targeting the same foreign repo start from that commit instead of HEAD.
6. `maybe_resume_parent/2` — Checks if all subagents done, resumes parent if so
7. `dispatch_ready_parent/3` — Replies to parent's GenServer.call with ordered results
8. `build_ordered_results/2` — Builds final results list in original spec order

### Agent Lifecycle (Lifecycle module)

Handles agent completion and crash recovery:

1. `recycle_agent/2` — Deletes worktree and both ETS entries on normal completion. Resolves `repo_root` from the agent's own `AgentState` ETS entry (not global state) so worktree cleanup targets the correct repo in multi-task scenarios. If per-agent repo_root is unavailable, skips worktree deletion with a warning.
2. `handle_agent_crash/3` — Retry logic (keep worktree, re-dispatch) or permanent failure (cleanup, notify parent/reply error). Both paths resolve `repo_root` from per-agent ETS state; worktree deletion is skipped if repo_root cannot be determined.

## Constraints
- Data structs are plain data with no behaviour or callbacks.
- `Slots`, `Worktrees`, `Dispatch`, `Subagents`, and `Lifecycle` are pure-function modules operating on `State.t()`; they don't maintain their own state.
- `AgentState` is shared (scheduler + agent processes); `SchedMeta` is scheduler-exclusive.
- Both ETS tables are created by parent `AgentScheduler` GenServer, not in this directory.
- GenServer state must always be `%State{}`; use struct update syntax, not `Map.put/3`.
- All helper modules have private ETS helpers (`get_sched_meta`, `put_sched_meta`, etc.) that directly access the same named tables — this is an intentional coupling since these modules are only called from the scheduler process context.
- Cross-module calls: `Dispatch.process_queue/1` calls `Subagents.dispatch_ready_parent/3` for ready parents. `Lifecycle.handle_agent_crash/3` calls `Dispatch.try_dispatch/2`, `Dispatch.process_queue/1`, `Subagents.store_sub_result/3`, and `Subagents.maybe_resume_parent/2`.
