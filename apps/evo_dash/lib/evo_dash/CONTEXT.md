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
  4. `EvoDash.TaskStore` (CubDB store — started BEFORE TaskRegistry, which depends on it at init)
  5. `EvoDash.TaskRegistry`
  6. `EvoDashWeb.Endpoint`

### `EvoDash.TaskStore` (`task_store.ex`)
- Thin wrapper around a single CubDB instance (CubDB does not provide its own `child_spec/1`).
- Started under supervision with `data_dir:` (a filesystem path) and optional `name:` (defaults to `EvoDash.TaskStore`).
- CubDB is started with `auto_file_sync: true` for durable writes (data-loss protection).
- Keys are namespaced tuples:
  - `{:task, task_id}` → `%TaskInfo{}` (stored directly as the value)
  - `{:project, path}` → `%{path:, name:, last_opened_at:}` map
- Pure Elixir, zero NIF — append-only B+tree design makes DETS-style corruption (`{:bad_object, :read_buckets}`) structurally impossible.

### `EvoDash.TaskRegistry` (`task_registry.ex`)
- Singleton `GenServer` backed by CubDB via `EvoDash.TaskStore` (single source of truth).
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

### CubDB Single Source of Truth
- **Primary storage (disk)**: A single CubDB instance (`EvoDash.TaskStore`) is the single source of truth for all tasks and recent projects. CubDB is a pure-Elixir, zero-NIF, append-only B+tree key-value store — its append-only design makes DETS-style corruption structurally impossible.
- **Namespaced keys**: Tasks are stored under key `{:task, task_id}` → `%TaskInfo{}` (struct stored directly as the value). Recent projects under key `{:project, path}` → `%{path:, name:, last_opened_at:}` map. Both live in the ONE store.
- **Durability**: CubDB started with `auto_file_sync: true` — every write is durable on return.
- **Runtime-only refs**: The `%Task{}` reference from `Task.Supervisor.async_nolink` is kept in an in-memory `task_refs` map in GenServer state (`%{task_id => %Task{}}`). These are never persisted (tasks always stored with `ref: nil`).

### Task Lifecycle
1. **Creation** (`start_task/2`): Generates random 16-char hex ID, spawns `Task.Supervisor.async_nolink` task, writes `TaskInfo` struct to CubDB under `{:task, id}` (with `ref: nil`), stores the ref in `task_refs`.
2. **Running**: Status updates via `cast` (`update_task_status/3`), log appends via `cast` (`update_task_log/2`). Logs stored as prepend list (newest first) in `TaskInfo.logs`. All writes go directly to CubDB.
3. **Completion/Failure**: On terminal status (`:completed`/`:failed`/`:cancelled`), `finished_at` is set, the task is removed from `task_refs`, and `cleanup_expired_tasks/1` runs.
4. **Crash recovery**: On startup, CubDB entries that were `:running`/`:pending` are reset to `:failed` with a crash detail message (`normalize_tasks/1` runs in-place).
5. **Deletion**: `delete_task/1` removes from CubDB. `clear_finished_tasks/0` removes all non-running/non-pending tasks from CubDB.

### Retention & Eviction
- **Cap-based eviction**: `cleanup_expired_tasks/1` runs on most state mutations and removes finished tasks older than `max_age_days` (default 14) and enforces `max_tasks` (default 100) on finished tasks.
- **Manual cleanup**: UI exposes "Clear Task History" button → `clear_finished_tasks()` which removes finished tasks from CubDB. Individual task delete also available.
- **Recent projects**: Capped at 10 entries via `trim_recent_projects/1` (sorted by `last_opened_at`, oldest evicted).

### ⚠️ Known Crash Hazard: Corrupt CubDB Entries
`TaskStore` is a pure pass-through with **no query or error-guard helpers** — all CubDB reads/iterations are done directly in `TaskRegistry`. The two iteration helpers `select_all_tasks/1` (line 480) and `select_all_projects/1` (line 487) use an unguarded `Stream.filter(fn {{ns, _id}, _v} -> ... end)` that **raises `FunctionClauseError` if any key is not a 2-tuple-of-tuples**. `cleanup_expired_tasks/1` (line 647) additionally does unguarded field access (`task.finished_at`, `task.id`) and `DateTime.compare/2` on stored values, which raises if a value is not a proper `TaskInfo` struct with `DateTime` fields. Because `cleanup_expired_tasks/1` runs at `init` and on every terminal-status mutation, a single corrupt entry can crash the GenServer; combined with `:one_for_one` + default restart intensity in `Application`, repeated init crashes take down the whole supervisor. `normalize_tasks/1` (line 606) has a try/rescue, but it calls `select_all_tasks(state)` *before* the try block (line 607), so the crash is not caught; and its comprehension silently *skips* (rather than deletes) non-`TaskInfo` values. A fix should make the iteration helpers defensive and delete/repair corrupt entries.

### One-time DETS→CubDB Migration
- `maybe_migrate_from_dets/1` runs once at init: if the CubDB store is empty AND old DETS files (`tasks.dets`, `recent_projects.dets`) exist in the data dir, it opens them (best-effort, `repair: true`), foldls the records into CubDB under the namespaced-key scheme, then renames the old `.dets` file to `.dets.migrated` so the migration is not retried on every launch.
- The entire migration is wrapped in try/catch — if DETS is corrupt (the corruption that motivated this migration), reads fail and the store starts fresh. This is the ONLY place `:dets` is referenced in lib (for reading legacy data).

## Constraints
- `TaskRegistry` is a singleton (registered under its module name); do not start multiple instances.
- `EvoDash.TaskStore` (CubDB) is the single source of truth — all reads and writes go through CubDB via the GenServer API. `:dets` is used ONLY inside the one-time migration function `maybe_migrate_from_dets/1` and its helpers.
- Runtime task refs (`%Task{}`) are kept in-memory only (`task_refs` map); persisted tasks always have `ref: nil`.
- Task log list is stored in reverse chronological order (newest first).
- All task types must be either `:genesis` or `:evolve`; new types require extending `execute_task/4`.
- This module depends on `evo_git` application (`EvoGit.Runtime.*`, `EvoGit.AgentScheduler`); it must be available at runtime.
- Finished tasks are cleaned up by `cleanup_expired_tasks/1` on most state mutations, enforcing `max_age_days` (default 14) and `max_tasks` (default 100) limits.
