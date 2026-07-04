# Agent Scheduler Data Structures and Helper Modules

## Intent

Contains data structs and extracted helper modules used internally by `EvoGit.AgentScheduler` GenServer. The data structs back two ETS tables (`:evogit_agent_state` and `:evogit_sched_meta`) tracking agent execution state and scheduling metadata. Helper modules encapsulate slot management, worktree lifecycle, agent dispatching, subagent management, and agent lifecycle logic.

## API Surface

| Module | Description |
|---|---|
| `EvoGit.AgentScheduler.State` | GenServer state struct — configuration, agent lifecycle queues, slot holder sets |
| `EvoGit.AgentScheduler.AgentState` | Live agent state in `:evogit_agent_state` ETS — context_node, phylo_node, objective, repo_id |
| `EvoGit.AgentScheduler.SchedMeta` | Scheduler-private metadata in `:evogit_sched_meta` ETS — status, depth, worktree, subagent tracking |
| `EvoGit.AgentScheduler.Slots` | Pure-function LLM/tool slot management using holder MapSets with FIFO queuing and rate-limit backoff |
| `EvoGit.AgentScheduler.Worktrees` | Pure-function worktree lifecycle: init, assign, prepare, sync, delete, teardown |
| `EvoGit.AgentScheduler.Dispatch` | Agent registration, dispatching, agent-process git commit, repo root resolution, queue processing |
| `EvoGit.AgentScheduler.Subagents` | Subagent validation/spawning, spatial contract checks, result tracking, parent resumption |
| `EvoGit.AgentScheduler.Lifecycle` | Agent recycling (cleanup) and crash handling (retry logic, permanent failure) |

### Slot Management (Slots module)

Two independent slot pools tracked as `MapSet`s of agent IDs. Available capacity is derived: `capacity - map_size(holders)`. This makes slot leaks impossible by construction — when an agent dies, `release_agent_slots/2` removes it from both holder sets, restoring the slot automatically.

| Pool | State Keys | Capacity | Backoff |
|------|-----------|----------|---------|
| LLM slots | `llm_holders`, `llm_waiting`, `llm_backoff_until` | `max_concurrency` (3) | 60s global cooldown on `:rate_limit` errors |
| Tool slots | `tool_holders`, `tool_waiting` | `max_tool_concurrency` (2) | None |

Key functions:
- `handle_request_llm_slot/3`, `handle_request_tool_slot/3` — Grant if capacity available, else enqueue
- `handle_release_llm_slot/2`, `handle_release_tool_slot/2` — Remove from holder set, grant pending
- `release_agent_slots/2` — Called on agent death (`:DOWN` handler): removes from both holder sets, purges from queues, grants pending slots
- `purge_agents_from_queues/2` — Removes agents from waiting queues, replies `{:error, :cancelled}` to each
- `grant_pending_on_resume/1` — Grants all available slots when resuming from pause

All slot functions return `{result, state, status_updates}` where `status_updates` is a list of `{agent_id, :blocked | :running}` tuples applied to ETS SchedMeta for dashboard visibility.

### Running Count

There is no `running_count` field. The running count is always derived as `map_size(state.ref_to_agent)`. Every agent lifecycle transition (dispatch, completion, crash) pops or puts from `ref_to_agent`, keeping the count authoritative at all times.

### Multi-Task Repo Root Resolution

The scheduler supports multiple concurrent tasks targeting different repos. Repo root resolution follows this priority:

1. **Per-agent ETS** (`AgentState.repo_root`) — set at registration via `Dispatch.resolve_agent_repo_root/2`, derived from spec data. Used by `Lifecycle` for worktree cleanup.
2. **Process dictionary** (`Process.get(:evogit_repo_root)`) — set at dispatch time in `try_dispatch/2`. Preferred by `current_repo_root/0` for runtime lookups.

There is no global `state.repo_root` fallback — repo root resolution is always per-agent. The scheduler tracks which repos have been initialized via the `initialized_repos` map (`%{String.t() => true}`).

`resolve_agent_repo_root/2` in Dispatch is self-contained for primary repos (strips worktree suffix from `spec.phylo_node.repo`). For foreign repos, it looks up the repo root from the agent's own `spec.foreign_repos` list by `spec.repo_id` — foreign repos are carried per-agent, not stored in global scheduler state.

### Worktree Lifecycle (Worktrees module)

Worktrees are **persistent per-agent** (created on dispatch, reused on retry, deleted on recycle):

1. `ensure_initialized/2` — Creates `.genesis/workers/`, prunes stale worktrees and orphaned branches. Tracks initialized repos in `state.initialized_repos` (`%{String.t() => true}`) to support multiple concurrent tasks targeting different repos. When agents are already running and a new repo comes in, registers it additively in `initialized_repos` without tearing down existing worktrees.
2. `assign_and_prepare_worktree/2` — Cleans worktree, checks out agent branch, binds repo path
3. `run_init_script/3` — Runs optional init script from `genesis.toml` (primary repo only). Accepts `opts` keyword list with `:source_worktree_path` (parent agent's worktree or repo root for top-level). Sets env vars: `SOURCE_REPO_PATH`, `TARGET_WORKTREE_PATH`, `SOURCE_WORKTREE_PATH`.
4. `sync_current_commit/2` — Reads HEAD SHA and updates both ETS tables if changed
5. `delete/2` — Removes worktree directory, prunes, deletes branch (takes explicit `repo_root` param)
6. `teardown_worktrees/2` — Removes entire worker base directory for a given repo root
7. `teardown_worktrees/1` — Resets the `initialized` flag without filesystem cleanup (for when repo root is unknown)

### Agent Dispatching (Dispatch module)

Handles the mechanics of registering and dispatching agents:

1. `register_agent/6` — Assigns agent IDs, computes task-local IDs, resolves event sink inheritance, writes both ETS tables
2. `try_dispatch/2` — **Two-phase dispatch** for parallel subagent startup. Uses `with` guard to bail cleanly if ETS entries are missing (genuine race).
   - **Phase 1 (GenServer, fast):** Computes worktree path, stores it in sched_meta **before** spawning the task (so `cancel_agent` can find the worktree), spawns the task immediately via the 4-arity `Task.Supervisor.async_nolink/4` **named-function** form (`spec.agent_module, :run, [spec.objective, dispatch_ctx]`), updates `ref_to_agent`. **NO git commands or init scripts run here** — the GenServer never does blocking I/O. The named-function form (instead of an anonymous fn) means the spawned process shows up as a meaningful `module.run/2` in process inspection (observer/Process.info).
   - **Phase 2 (Task process, slow/concurrent):** `setup_worktree/5` runs inside the agent's `run/2` (the single true entry point for an agent), before the agent loop: creates the worktree (`Git.add_worktree`), prepares it (`assign_and_prepare_worktree`), and runs the init script on first creation (primary repo only). All of this runs concurrently across subagents, so `spawn_validated_subagents`' `Enum.reduce` over `try_dispatch` spawns all tasks immediately.
3. `commit_pending_in_worktree/0` — Best-effort git commit of pending changes, designed to run in the **agent process** (not the scheduler). Uses `Process.get(:repo_path)` for the worktree path. Handles all git adapter error tuples (`{:ok, _}`, `{:error, _}`, `{:conflict, _}`) explicitly via a `with` block rather than a broad `try/rescue`, so failures are logged but never crash. Called via `try/after` in the agent's `run/2` (the dispatch entry point) after the agent loop. **The scheduler process NEVER calls git directly.**
4. `resolve_agent_repo_root/2` — Resolves repo root from spec (primary vs foreign repo)
5. `dispatch_queued_agents/1` — Drains queue dispatching agents (used after resume)
6. `process_queue/1` — Processes queue with ready-parent detection (delegates to Subagents)

### Subagent Management (Subagents module)

Handles subagent validation, spawning, and result collection:

1. `spawn_validated_subagents/5` — Validates all specs, registers valid ones, replies immediately if all invalid. The parent agent commits its pending changes BEFORE calling `spawn_sub_agents` (done in the agent process via `Dispatch.commit_pending_in_worktree/0`), so the scheduler does not perform git operations.
2. `validate_single_subagent/5` — Per-spec validation chain (depth, ignored, spatial)
3. `validate_subagent_depth/3`, `validate_subagent_not_ignored/1` — Individual validation checks
4. `validate_spatial_contract_for_spec/3`, `validate_spawn_spatiality/4` — Spatial contract enforcement
5. `store_sub_result/3` — Stores subagent result at correct index in parent's results map. Also tracks foreign repo commit SHAs in `SchedMeta.foreign_repo_commits` — when a foreign-repo subagent completes successfully, its `commit_sha` is recorded under the `repo_id` key so subsequent subagents targeting the same foreign repo start from that commit instead of HEAD.
6. `maybe_resume_parent/2` — Checks if all subagents done, resumes parent if so
7. `dispatch_ready_parent/3` — Replies to parent's GenServer.call with ordered results
8. `build_ordered_results/2` — Builds final results list in original spec order

### Agent Lifecycle (Lifecycle module)

Handles agent completion and crash recovery:

1. `recycle_agent/2` — Deletes worktree and both ETS entries on normal completion. Uses `with` guard to return state unchanged if ETS entry is already gone (genuine race between `:DOWN` completion and another cleanup path). Resolves `repo_root` from the agent's own `AgentState` ETS entry (not global state).
2. `cancel_agent/2` — Kills the agent's Task process via `Task.shutdown(meta.task_ref, :brutal_kill)`. The `task_ref` field stores a full `%Task{}` struct (not a bare reference), enabling proper shutdown. Replies to blocked callers, deletes worktree and ETS entries. Uses `case` to skip worktree deletion if agent_state is missing.
3. `handle_agent_crash/3` — Retry logic (keep worktree, re-dispatch) or permanent failure (cleanup, notify parent/reply error). Both paths resolve `repo_root` from per-agent ETS state.

## Constraints

- Data structs are plain data with no behaviour or callbacks.
- `Slots`, `Worktrees`, `Dispatch`, `Subagents`, and `Lifecycle` are pure-function modules operating on `State.t()`; they don't maintain their own state.
- `AgentState` is shared (scheduler + agent processes); `SchedMeta` is scheduler-exclusive.
- Both ETS tables are created by **`EvoGit.Application`** (the application process), NOT by the `AgentScheduler` GenServer (see `application.ex:13-15`). This is deliberate: the tables have **no heir**, so ownership must outlive a scheduler crash. Because they are owned by the long-lived application process, the tables **SURVIVE an `AgentScheduler` restart** — stale `SchedMeta` entries from the crashed instance remain. (Restart semantics: `AgentGroupSupervisor` is `strategy: :one_for_all`, so a scheduler crash also kills `EvoGit.TaskSupervisor` and all running agent Tasks. The GenServer `%State{}` is reset fresh on restart, but the ETS tables persist.)
- GenServer state must always be `%State{}`; use struct update syntax, not `Map.put/3`.
- The scheduler process NEVER calls git directly — all git operations (auto-commit, sync) happen in the agent (Task) process. The scheduler only does filesystem operations (worktree creation/deletion).
- Slot availability is derived from holder MapSets, never stored as a counter — this eliminates leak/deadlock bugs by construction.
- `SchedMeta.task_ref` stores a `%Task{}` struct (for `Task.shutdown/2`), NOT a bare reference. The `ref_to_agent` map still keys on `task.ref` (the monitor reference).
- `case`/`with` guards on ETS lookups are used ONLY where a genuine race can cause the entry to be absent (recycle_agent, try_dispatch, cancel_agent). Not used defensively everywhere.
- Cross-module calls: `Dispatch.process_queue/1` calls `Subagents.dispatch_ready_parent/3` for ready parents. `Lifecycle.handle_agent_crash/3` calls `Dispatch.try_dispatch/2`, `Dispatch.process_queue/1`, `Subagents.store_sub_result/3`, and `Subagents.maybe_resume_parent/2`.