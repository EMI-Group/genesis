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
- Singleton `GenServer` backed by a named ETS table (`:evo_dash_tasks`).
- Tracks EvoGit tasks (`:genesis` / `:evolve`) with id, type, status, opts, pid, timestamps, logs, and result.

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
- Uses an `event_sink` callback (`{EvoDash.TaskRegistry, :update_task_log, [task_id]}`) to pipe runtime logs back into the registry.
- On completion, receives `{:task_complete, task_id, result}` and updates status accordingly.

## Constraints
- `TaskRegistry` is a singleton (registered under its module name); do not start multiple instances.
- ETS table is `:public` — direct reads are possible but mutations must go through the GenServer API to preserve consistency.
- Task log list is stored in reverse chronological order (newest first).
- All task types must be either `:genesis` or `:evolve`; new types require extending `execute_task/4`.
- This module depends on `evo_git` application (`EvoGit.Runtime.*`, `EvoGit.AgentScheduler`); it must be available at runtime.
