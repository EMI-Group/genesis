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
  4. `EvoDash.TaskStore` (SQLite store — started BEFORE TaskRegistry, which depends on it at init)
  5. `EvoDash.TaskRegistry`
  6. `EvoDashWeb.Endpoint`

### `EvoDash.TaskStore` (`task_store.ex`)
- GenServer wrapping a single xqlite (SQLite) connection, owning the connection in its state.
- Started under supervision with `data_dir:` (a FILE path to the `.sqlite` file) and optional `name:` (defaults to `EvoDash.TaskStore`).
- Two SQLite tables: `tasks` (key = task id TEXT), `projects` (key = project path TEXT). Values stored as `:erlang.term_to_binary/1` BLOBs, decoded via `:erlang.binary_to_term/1`.
- Key-tuple convention — callers pass tuple keys that the store routes to the correct table:
  - `{:task, task_id}` → operates on the `tasks` table
  - `{:project, path}` → operates on the `projects` table
- Crash-safe helpers (`safe_get/2`, `safe_select_all/1`, `safe_size/1`, `integrity_check/1`) rescue decode errors per-row so corrupt blobs never crash callers.
- `integrity_check/1` runs `PRAGMA integrity_check` (SQLite structural health) and scans all rows for undecodable blobs. Undecodable `tasks` rows are **hard-deleted** (lower-value, auto-expiring); undecodable `projects` rows are **quarantined** — the raw BLOB is moved into a `projects_quarantine` table (preserved for recovery/diagnosis), never destroyed. Returns `:ok` / `{:repaired, lost}` / `{:error, reason}`.

### `EvoDash.TaskRegistry` (`task_registry.ex`)
- Singleton `GenServer` backed by SQLite via `EvoDash.TaskStore` (single source of truth).
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

### SQLite Single Source of Truth
- **Primary storage (disk)**: A single SQLite database file (`EvoDash.TaskStore`, backed by the xqlite NIF) is the single source of truth for all tasks and recent projects.
- **Schema**: Two tables — `tasks (id TEXT PRIMARY KEY, data BLOB)` and `projects (id TEXT PRIMARY KEY, data BLOB)`. Values are serialized via `:erlang.term_to_binary/1` into BLOBs and decoded via `:erlang.binary_to_term/1`.
- **Key-tuple convention**: Callers pass `{:task, task_id}` or `{:project, path}`; the TaskStore GenServer routes to the correct table.
- **Runtime-only refs**: The `%Task{}` reference from `Task.Supervisor.async_nolink` is kept in an in-memory `task_refs` map in GenServer state (`%{task_id => %Task{}}`). These are never persisted (tasks always stored with `ref: nil`).

### Task Lifecycle
1. **Creation** (`start_task/2`): Generates random 16-char hex ID, spawns `Task.Supervisor.async_nolink` task, writes `TaskInfo` struct to SQLite under `{:task, id}` (with `ref: nil`), stores the ref in `task_refs`.
2. **Running**: Status updates via `cast` (`update_task_status/3`), log appends via `cast` (`update_task_log/2`). Logs stored as prepend list (newest first) in `TaskInfo.logs`. All writes go through `EvoDash.TaskStore.put/3`.
3. **Completion/Failure**: On terminal status (`:completed`/`:failed`/`:cancelled`), `finished_at` is set, the task is removed from `task_refs`, and `cleanup_expired_tasks/1` runs.
4. **Crash recovery**: On startup, `normalize_tasks/1` reconciles tasks that were `:running`/`:pending`. If a task's persisted `pid` is still alive (still running under the sibling `TaskSupervisor` — which survives a `TaskRegistry` restart due to `:one_for_one` supervision), it is kept as `:running` and **re-monitored** via `Process.monitor/1` (populating `task_refs`). If the `pid` is dead or absent (actual crash / VM restart), it is marked `:failed` with a crash detail message. This prevents the prior bug where a registry restart incorrectly marked live tasks as `:failed`.
5. **DOWN handling**: `handle_info({:DOWN, ref, :process, _pid, reason})` reconciles task termination — `reason == :normal` → `:completed`, abnormal → `:failed`. This handles both re-monitored tasks completing after a restart and tasks that crash without sending `{ref, result}`.
6. **Deletion**: `delete_task/1` removes from SQLite. `clear_finished_tasks/0` removes all non-running/non-pending tasks from SQLite.

### Retention & Eviction
- **Cap-based eviction**: `cleanup_expired_tasks/1` runs on most state mutations and removes finished tasks older than `max_age_days` (default 14) and enforces `max_tasks` (default 100) on finished tasks.
- **Manual cleanup**: UI exposes "Clear Task History" button → `clear_finished_tasks()` which removes finished tasks from SQLite. Individual task delete also available.
- **Recent projects**: Capped at 10 entries via `trim_recent_projects/1` (sorted by `last_opened_at`, oldest evicted).

### Crash Safety & Integrity
- `TaskStore` provides crash-safe helpers (`safe_get/2`, `safe_select_all/1`, `safe_size/1`) that rescue per-row decode errors so corrupt blobs never crash callers. `safe_select_all/1` skips rows whose blobs fail to decode.
- `integrity_check/1` runs `PRAGMA integrity_check` for SQLite-level structural health and scans all rows for undecodable blobs. Undecodable `tasks` rows are **hard-deleted**; undecodable `projects` rows are **quarantined** into `projects_quarantine` (raw BLOB preserved, never destroyed) so a transient decode failure can't silently erase a recently-opened project. If a quarantine INSERT itself fails, the row is left in place rather than destroyed. Returns `:ok` / `{:repaired, lost}` / `{:error, reason}`. Called by TaskRegistry on init.
- All BLOB decoding uses `:erlang.binary_to_term(blob, [:safe])` (every call site) to avoid spurious decode errors.
- **Stringified-module atom repair (read-path)**: The legacy `scrub_db` corruption converted module atoms (e.g. `Calendar.ISO` inside DateTime structs, or `__struct__` fields) into binary strings like `"Elixir.Calendar.ISO"`, crashing `DateTime.compare/2`. The read path now pipes every decoded value through `repair_stringified_modules/1` (routed via the private `decode_blob/1` chokepoint at the 4 return-path decode sites: `do_get/3` ×2, `read_all_table/3`, `safe_read_all_table/3`). It recursively walks maps/structs/keyword-lists/lists/tuples and converts `"Elixir." <> _` strings back to atoms via `String.to_existing_atom/1` — which can NEVER create a new atom (an `ArgumentError` leaves the string untouched, preserving the security intent of the original `String.to_atom` removal). The `__struct__` key VALUE is also repaired so a stringified `"Elixir.DateTime"` becomes a proper struct. `try_decode/1` (the integrity-check decode probe) is intentionally NOT routed through here — it only tests decode-ability and never returns a value. The DB self-heals on next restart: `normalize_tasks/1` reads repaired data via `safe_select_all` and re-persists it clean via `TaskStore.put/3`.
- All store-touching `handle_*` callbacks in TaskRegistry are wrapped in `try/rescue` (bodies extracted to `do_*` privates) — write-failure rescues log at `Logger.error`, read/cleanup rescues at `Logger.warning`.

### One-time DETS→SQLite Migration
- `maybe_migrate_from_dets/1` runs once at init: if the SQLite store is empty AND old DETS files (`tasks.dets`, `recent_projects.dets`) exist in the data dir, it opens them (best-effort, `repair: true`), foldls the records into SQLite under the namespaced-key scheme, then renames the old `.dets` file to `.dets.migrated` so the migration is not retried on every launch.
- The entire migration is wrapped in try/catch — if DETS is corrupt, reads fail and the store starts fresh. This is the ONLY place `:dets` is referenced in lib (for reading legacy data).
- **No CubDB→SQLite migration**: CubDB is no longer a dependency, so old CubDB data files cannot be read at runtime. `maybe_note_legacy_cubdb/0` logs an informational note if a legacy `tasks.cubdb` directory is detected. Old CubDB directories are orphaned but harmless (non-critical, auto-expiring data).

### Schema Migration Gap & Quarantine (mitigated)

> The two issues below were historically fragile; both are now **mitigated**.

- **Schema auto-repair (mitigated)**: Tables are created via `CREATE TABLE IF NOT EXISTS` in `TaskStore.init` (`create_tables/1`). This is a **no-op on an already-existing table**, so there is no schema versioning / `ALTER TABLE`. The historical `path`→`id` column-name bug (commit `0989e6f9` created `projects (path TEXT PRIMARY KEY, data BLOB)` while all SQL referenced `id`) is now **auto-repaired on every init** by `repair_projects_table/1`, which introspects via `PRAGMA table_info(projects)`, detects a non-`id` PK column, and rebuilds the table with the correct `id` column while preserving all data BLOBs. Wrapped in `try/rescue` so a repair hiccup never blocks startup.
- **Recent-projects callbacks are wrapped (mitigated)**: The recent-projects callbacks (`add_recent_project`, `list_recent_projects`, `remove_recent_project`) ARE wrapped in `try/rescue` (bodies in `do_*` privates), at parity with the task callbacks — a projects-table write/read failure no longer crashes the TaskRegistry GenServer outright.
- **Projects quarantine on integrity repair**: Because undecodable `projects` rows are high-value (≤10 recently-opened project paths) and a transient `binary_to_term` failure could erase one, `integrity_check` does NOT hard-delete them. Instead it **quarantines** the raw BLOB into `projects_quarantine` (INSERT raw blob, then DELETE from `projects`) and logs a warning. `tasks` rows remain hard-deletable (lower-value, auto-expiring). If a quarantine INSERT itself fails, the row is left in place — never silently destroyed. This prevents the reported "randomly lose data of recently opened projects" symptom.

## Constraints
- `TaskRegistry` is a singleton (registered under its module name); do not start multiple instances.
- `EvoDash.TaskStore` (SQLite via xqlite) is the single source of truth — all reads and writes go through the TaskStore GenServer API. `:dets` is used ONLY inside the one-time migration function `maybe_migrate_from_dets/1` and its helpers.
- Runtime task refs (`%Task{}`) are kept in-memory only (`task_refs` map); persisted tasks always have `ref: nil`.
- Task log list is stored in reverse chronological order (newest first).
- All task types must be either `:genesis` or `:evolve`; new types require extending `execute_task/4`.
- This module depends on `evo_git` application (`EvoGit.Runtime.*`, `EvoGit.AgentScheduler`); it must be available at runtime.
- Finished tasks are cleaned up by `cleanup_expired_tasks/1` on most state mutations, enforcing `max_age_days` (default 14) and `max_tasks` (default 100) limits.
