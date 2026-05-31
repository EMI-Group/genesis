# Agent Scheduler Data Structures and Helper Modules

## Intent
Contains data structs and extracted helper modules used internally by `EvoGit.AgentScheduler` GenServer. The data structs back two ETS tables (`:evogit_agent_state` and `:evogit_sched_meta`) tracking agent execution state and scheduling metadata. Helper modules (`Slots`, `Worktrees`) encapsulate slot management and worktree lifecycle logic.

## API Surface

| Module | Description |
|---|---|
| `EvoGit.AgentScheduler.State` | GenServer state struct — configuration, agent lifecycle queues, slot counters |
| `EvoGit.AgentScheduler.AgentState` | Live agent state in `:evogit_agent_state` ETS — context_node, phylo_node, objective, repo_id |
| `EvoGit.AgentScheduler.SchedMeta` | Scheduler-private metadata in `:evogit_sched_meta` ETS — status, depth, worktree, subagent tracking |
| `EvoGit.AgentScheduler.Slots` | Pure-function LLM/tool slot management with FIFO queuing and rate-limit backoff |
| `EvoGit.AgentScheduler.Worktrees` | Pure-function worktree lifecycle: init, assign, prepare, sync, delete, teardown |

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

## Constraints
- Data structs are plain data with no behaviour or callbacks.
- `Slots` and `Worktrees` are pure-function modules operating on `State.t()`; they don't maintain their own state.
- `AgentState` is shared (scheduler + agent processes); `SchedMeta` is scheduler-exclusive.
- Both ETS tables are created by parent `AgentScheduler` GenServer, not in this directory.
- GenServer state must always be `%State{}`; use struct update syntax, not `Map.put/3`.
- `Worktrees` module has private ETS helpers (`get_sched_meta`, `put_sched_meta`, etc.) that directly access the same named tables — this is an intentional coupling since the module is only called from the scheduler process context.
