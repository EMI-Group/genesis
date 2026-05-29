# Agent Scheduler Data Structures

## Intent
Contains data struct models and extracted helper modules used internally by the parent `EvoGit.AgentScheduler` GenServer. The data structs back two dedicated ETS tables (`:evogit_agent_state` and `:evogit_sched_meta`) that track live agent execution state and scheduling metadata respectively. The helper modules encapsulate slot management and worktree lifecycle logic extracted from the main GenServer for maintainability.

## API Surface

| Module | Description |
|---|---|
| `EvoGit.AgentScheduler.State` | GenServer state struct for the `AgentScheduler`. Typed struct with 20 fields covering initialization (`initialized`, `repo_root`, `repos`, `base_sha`), configuration (`max_concurrency`, `max_tool_concurrency`, `agent_max_retries`, `max_depth`, `llm_model`, `max_retries`), agent lifecycle (`next_agent_id`, `next_task_id`, `running_count`, `ref_to_agent`, `queue`), and slot management (`llm_slots_available`, `llm_waiting`, `llm_backoff_until`, `tool_slots_available`, `tool_waiting`). |
| `EvoGit.AgentScheduler.AgentState` | Live spatial/temporal state for a **running** agent. Stored in `:evogit_agent_state` ETS. Fields: `context` (ReqLLM.Context \| nil), `context_node` (ContextNode), `phylo_node` (PhyloGraphNode \| nil), `event_sink` (pid \| nil), `llm_model`, `max_retries`, `max_depth`, `parent_id`, `objective`, `repo_id` (atom, default `:primary`). Enforced keys: `[:context_node, :llm_model, :max_retries, :max_depth]`. |
| `EvoGit.AgentScheduler.SchedMeta` | Scheduling metadata for a **registered** agent. Stored in `:evogit_sched_meta` ETS. Fields: `id`, `depth`, `spec` (AgentSpec), `status` (`:pending \| :running \| :waiting \| :ready \| :blocked`), `worktree`, `task_ref`, `from`, `parent_id`, `task_id` (groups agents from the same top-level `run_agent` call), `retries`, `result_sent`, `sub_agent_from`, `total_sub_specs`, `pending_sub_agents` (MapSet), `sub_agent_results` (map), `sub_agent_indices` (map). Enforced keys: `[:id, :depth, :spec]`. |
| `EvoGit.AgentScheduler.Slots` | LLM and tool slot management as pure functions operating on `State.t()`. Handles request/release, global backoff for rate-limit errors, and pending queue grants. All public functions are fully typespec'd. |
| `EvoGit.AgentScheduler.Worktrees` | Worktree lifecycle management as pure functions operating on `State.t()`: initialization, teardown, assignment/preparation, init script execution, deletion, and orphaned branch cleanup. All public functions are fully typespec'd. |

### ETS Table Layout

Both tables are created as `:named_table, :public, :set` with `read_concurrency: true`.

#### `:evogit_agent_state` — Agent Process State
| Key | Value | Ownership |
|-----|-------|-----------|
| `agent_id` (pos_integer) | `%AgentState{}` struct | **Shared**: Scheduler writes initial values on dispatch; agent processes update `phylo_node`, `context` during execution; scheduler reads for subagent validation and merge operations. |

Agent processes access this table via public functions on `AgentScheduler`:
- `AgentScheduler.get_agent_state/1` — read full state
- `AgentScheduler.get_agent_context/1` — read conversation context
- `AgentScheduler.update_agent_context/2` — update context (also streams to event_sink)
- `AgentScheduler.update_phylo_node/2` — update phylo_node after commits
- `AgentScheduler.get_event_sink/1` — get event sink pid

#### `:evogit_sched_meta` — Scheduler Metadata
| Key | Value | Ownership |
|-----|-------|-----------|
| `agent_id` (pos_integer) | `%SchedMeta{}` struct | **Exclusive**: Only the scheduler GenServer reads and writes this table. Agents never access it directly. |

The scheduler uses private helpers (`get_sched_meta/1`, `put_sched_meta/2`, `delete_sched_meta/1`) for this table. The `Worktrees` helper module also has private copies of these helpers since it needs to update both tables during worktree operations.

### Agent Status Lifecycle

```
:pending → :running → :waiting (subagents spawned) → :ready (all subagents done) → :running (resumed) → completion → recycled
                  ↘ crash → :pending (retry) → :running ... → recycled (after max retries)
```

### Slot Management (Slots module)

Two independent slot pools with FIFO queuing:

| Pool | State Keys | Default Size | Backoff |
|------|-----------|--------------|---------|
| LLM slots | `llm_slots_available`, `llm_waiting` (queue), `llm_backoff_until` | `max_concurrency` (3) | 60s global cooldown on `:rate_limit` errors |
| Tool slots | `tool_slots_available`, `tool_waiting` (queue) | `max_tool_concurrency` (2) | None |

LLM backoff mechanism: On `:rate_limit` error, all queued agents get a backoff timestamp. A `Process.send_after` timer fires at 65s to unstick any remaining agents. `grant_pending_llm_slots/1` drains the queue, skipping entries still in backoff.

### Worktree Lifecycle (Worktrees module)

Worktrees are **persistent per-agent** (created on first dispatch, reused on retry, deleted on recycle):

1. `ensure_initialized/2` — Creates `.evogit/workers/` dir, prunes stale worktrees, cleans orphaned `evogit-agent*` branches, registers `:primary` repo
2. `assign_and_prepare_worktree/2` — Cleans worktree, checks out agent branch, updates agent's `phylo_node` with worktree-bound repo path
3. `run_init_script/2` — Runs optional init script from `evogit.toml` with `$SOURCE_REPO_PATH` and `$TARGET_WORKTREE_PATH` env vars (primary repo only)
4. `sync_current_commit/2` — Reads HEAD SHA from worktree and updates both ETS tables if changed
5. `delete/2` — Removes worktree directory, prunes, deletes branch
6. `teardown_worktrees/1` — Removes entire worker base directory, resets `initialized` flag

### External Consumer Access (Dashboard)

The EvoDash dashboard (`EvoDashWeb.AgentsLive`) directly reads both ETS tables using `:ets.tab2list/1` with safety checks (`:ets.whereis/1` to handle table not yet created). This allows real-time polling of all agent states without going through the GenServer. Key dashboard queries:
- **Agent list**: Joins `:evogit_sched_meta` and `:evogit_agent_state` by agent_id to build a unified view (status, module, objective, context_path, commits, children)
- **Agent history**: Reads `context` (ReqLLM.Context) from `:evogit_agent_state` and converts messages to history entries
- **Config management**: Uses `AgentScheduler.update_config/1`, `AgentScheduler.get_config/0`, `AgentScheduler.get_config/1`
- **Foreign repo management**: Uses `AgentScheduler.register_foreign_repo/1`, `AgentScheduler.unregister_foreign_repo/1`, `AgentScheduler.get_foreign_repos/0`

The dashboard polls every 1 second via `:timer.send_interval(1000, self(), :refresh_agents)`.

## Constraints
- Data structs are plain data with no behaviour or callbacks.
- **Helper modules contain business logic**: `Slots` and `Worktrees` are pure-function modules that operate on the scheduler's `State.t()` struct. They are called by the parent GenServer's callbacks but do not maintain their own state.
- **Ownership model**: `AgentState` is primarily owned by agent processes (scheduler writes initial values, agents update `phylo_node` and `context`). `SchedMeta` is owned **exclusively** by the scheduler process; agents never read or write it.
- Both structs are persisted in dedicated ETS tables created by the parent `AgentScheduler` GenServer, not in this directory.
- New fields may be added to either struct as scheduling features evolve, but ownership boundaries must be respected.
- The `Worktrees` module has its own private copies of the ETS helper functions (`get_sched_meta`, `put_sched_meta`, `get_agent_state`, `put_agent_state`) because it needs to update both tables during worktree operations but is not the GenServer itself.
- **State struct discipline**: The `AgentScheduler` GenServer state must always be a `%State{}` struct. All updates must preserve the struct type (use `%State{state | ...}` syntax, not `Map.put/3`).
