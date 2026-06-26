# `apps/evo_dash/lib/evo_dash/` — Domain & Business Logic

## Intent
Core domain layer for the EvoDash Phoenix application. Houses the OTP application supervision tree and the task management registry that bridges the web layer to the EvoGit runtime engine.

## API Surface

### `EvoDash` (`../evo_dash.ex`)
- Placeholder module for future contexts/domain logic.

### `EvoDash.Application` (`application.ex`)
- OTP Application callback module.
- **Supervision tree children** (strategy: `one_for_one`):
  1. `EvoDashWeb.Telemetry`
  2. `DNSCluster`
  3. `Phoenix.PubSub` (registered as `EvoDash.PubSub`)
  4. `EvoDash.TaskRegistry`
  5. `EvoDashWeb.Endpoint`

### `EvoDash.TaskRegistry` (`task_registry.ex`)
- Singleton `GenServer` backed by DETS (single source of truth).
- Tracks EvoGit tasks (`:genesis` / `:evolve`) with id, type, status, opts, pid, timestamps, logs, and result.
- Runtime-only task references (`%Task{}`) are kept in an in-memory `task_refs` map (`%{task_id => %Task{}}`), not persisted.

**Client API:**
| Function | Description |
|---|---|
| `start_task(task_type, opts)` | Starts a `:genesis` or `:evolve` task; spawns a linked process running `EvoGit.Runtime.Genesis.run/2` or `EvoGit.Runtime.Evolution.run/2`. Returns `{:ok, task}`. |
| `get_task(task_id)` | Retrieves a single task by ID. |
| `list_tasks()` | Returns all tracked tasks. |
| `list_tasks_by_path(path)` | Returns tasks filtered by repo path (path-expanded for consistent comparison). |
| `get_unique_paths()` | Returns list of unique repo paths across all tasks. |
| `cancel_task(task_id)` | Kills the task process and marks it `:cancelled`. |
| `update_task_status(task_id, status, result \\ nil)` | Casts a status update (`:running`/`:completed`/`:failed`/`:cancelled`). |
| `update_task_log(task_id, log_entry)` | Appends a log entry (prepending) to the task's log list. |
| `delete_task(task_id)` | Removes a task from the ETS table. |

**Task execution:**
- Extracts options: `path`, `prompt`/`objective`, `mode`, `concurrency`, `retries`, `agent_max_retries`.
- Calls `EvoGit.AgentScheduler.update_config/1` at runtime before executing.
- Subscribes to `EvoGit.PubSub` topic `"tasks"` to receive task status updates from the runtime engine.
- On completion, receives `{:task_complete, task_id, result}` and updates status accordingly.

## Task Storage & Persistence Architecture

### Dual-Layer Storage (ETS + DETS)
- **Primary (in-memory)**: Named ETS table `:evo_dash_tasks` (`:set` type, `:public`) holds all live tasks for fast read access.
- **Persistence (disk)**: DETS table `:evo_dash_tasks_dets` stores the most recent 10 finished tasks + all running tasks to `<platform_data_dir>/tasks.dets`.
- **Similar pattern for Recent Projects**: ETS `:evo_dash_recent_projects` + DETS `:evo_dash_projects_dets` → `recent_projects.dets`, capped at 10 entries.

### Task Lifecycle
1. **Creation** (`start_task/2`): Generates random 16-char hex ID, spawns `Task.Supervisor.async_nolink` task, inserts `TaskInfo` struct into ETS, persists to DETS.
2. **Running**: Status updates via `cast` (`update_task_status/3`), log appends via `cast` (`update_task_log/2`). Logs stored as prepend list (newest first) in `TaskInfo.logs`.
3. **Completion/Failure**: On terminal status (`:completed`/`:failed`/`:cancelled`), `finished_at` is set and DETS is synced. The `TaskInfo.ref` field (non-serializable `%Task{}`) is nulled before persistence.
4. **Crash recovery**: On startup, tasks loaded from DETS that were `:running`/`:pending` are reset to `:failed` with a crash detail message.
5. **Deletion**: `delete_task/1` removes from ETS and re-persists to DETS. `clear_finished_tasks/0` removes all non-running/non-pending tasks from ETS and re-persists.

### Retention & Eviction
- **No automatic expiry/TTL/sweep**: There is no background timer, cron, or automatic cleanup process.
- **Cap-based eviction**: `persist_tasks_to_dets/0` keeps ALL running tasks + the 10 most recent finished tasks (sorted by `started_at` descending). Older finished tasks are simply not written to DETS — they survive in ETS only until server restart or manual `clear_finished_tasks`.
- **Manual cleanup only**: UI exposes "Clear Task History" button → `clear_finished_tasks()` which removes finished tasks from ETS + DETS. Individual task delete also available.
- **Recent projects**: Capped at 10 entries via `trim_recent_projects/0` (sorted by `last_opened_at`, oldest evicted).

### DETS Corruption Recovery
- `open_or_reset_dets/2`: If DETS file fails to open, it is deleted and recreated.
- `load_tasks_from_dets/1` / `load_recent_projects_from_dets/1`: On load errors, the DETS table is reset (deleted and recreated).

## Constraints
- `TaskRegistry` is a singleton (registered under its module name); do not start multiple instances.
- ETS table is `:public` — direct reads are possible but mutations must go through the GenServer API to preserve consistency.
- Task log list is stored in reverse chronological order (newest first).
- All task types must be either `:genesis` or `:evolve`; new types require extending `execute_task/4`.
- This module depends on `evo_git` application (`EvoGit.Runtime.*`, `EvoGit.AgentScheduler`); it must be available at runtime.
- No automatic task cleanup — finished tasks accumulate in ETS until manual clear or server restart; only 10 most recent persist across restarts.
- DETS persistence is synchronous (`:dets.sync`) and triggered on every status change to a terminal state, which could become a bottleneck under high task throughput.
