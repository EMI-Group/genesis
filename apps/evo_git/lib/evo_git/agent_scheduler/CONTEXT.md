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

### Worktree Lifecycle (Worktrees module)

Worktrees are **persistent per-agent** (created on dispatch, reused on retry, deleted on recycle):

1. `ensure_initialized/2` — Creates `.evogit/workers/`, prunes stale worktrees and orphaned branches
2. `assign_and_prepare_worktree/2` — Cleans worktree, checks out agent branch, binds repo path
3. `run_init_script/2` — Runs optional init script from `evogit.toml` (primary repo only)
4. `sync_current_commit/2` — Reads HEAD SHA and updates both ETS tables if changed
5. `delete/2` — Removes worktree directory, prunes, deletes branch
6. `teardown_worktrees/1` — Removes entire worker base directory

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
5. `store_sub_result/3` — Stores subagent result at correct index in parent's results map
6. `maybe_resume_parent/2` — Checks if all subagents done, resumes parent if so
7. `dispatch_ready_parent/3` — Replies to parent's GenServer.call with ordered results
8. `build_ordered_results/2` — Builds final results list in original spec order

### Agent Lifecycle (Lifecycle module)

Handles agent completion and crash recovery:

1. `recycle_agent/2` — Deletes worktree and both ETS entries on normal completion
2. `handle_agent_crash/3` — Retry logic (keep worktree, re-dispatch) or permanent failure (cleanup, notify parent/reply error)

## Constraints
- Data structs are plain data with no behaviour or callbacks.
- `Slots`, `Worktrees`, `Dispatch`, `Subagents`, and `Lifecycle` are pure-function modules operating on `State.t()`; they don't maintain their own state.
- `AgentState` is shared (scheduler + agent processes); `SchedMeta` is scheduler-exclusive.
- Both ETS tables are created by parent `AgentScheduler` GenServer, not in this directory.
- GenServer state must always be `%State{}`; use struct update syntax, not `Map.put/3`.
- All helper modules have private ETS helpers (`get_sched_meta`, `put_sched_meta`, etc.) that directly access the same named tables — this is an intentional coupling since these modules are only called from the scheduler process context.
- Cross-module calls: `Dispatch.process_queue/1` calls `Subagents.dispatch_ready_parent/3` for ready parents. `Lifecycle.handle_agent_crash/3` calls `Dispatch.try_dispatch/2`, `Dispatch.process_queue/1`, `Subagents.store_sub_result/3`, and `Subagents.maybe_resume_parent/2`.
