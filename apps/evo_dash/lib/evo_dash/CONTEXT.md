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
  4. `EvoDash.Store` (SQLite store — started BEFORE TaskRegistry, which depends on it at init)
  5. `EvoDash.TaskRegistry`
  6. `EvoDashWeb.Endpoint`

### `EvoDash.RecentProject` (`store.ex`)
- Struct representing a recently opened project: `%RecentProject{path: String.t(), name: String.t(), last_opened_at: DateTime.t() | nil}`.

### `EvoDash.Store` (`store.ex`)
- GenServer wrapping a single xqlite (SQLite) connection, owning the connection in its state.
- Started under supervision with `data_dir:` (a FILE path to the `.sqlite` file) and optional `name:` (defaults to `EvoDash.Store`).
- **Column-based SQLite schema** (NOT term_to_binary blobs): each TaskInfo/RecentProject field maps to a dedicated SQLite column.
- **Explicit durability PRAGMAs**: `Xqlite.open(path, journal_mode: :wal, synchronous: :normal)` — WAL + NORMAL is the recommended combo for crash safety and write performance.
- **Graceful connection close**: `terminate/2` calls `XqliteNIF.close(conn)` (wrapped in try/rescue).

#### Schema

```sql
-- tasks: one column per TaskInfo field
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, type TEXT, status TEXT NOT NULL, opts TEXT,
  pid TEXT, started_at TEXT, finished_at TEXT, logs TEXT, result TEXT,
  review_status TEXT, usage TEXT, agent_count INTEGER,
  base_sha TEXT, commit_sha TEXT, archive_metadata TEXT
);
-- projects: one column per RecentProject field
CREATE TABLE projects (path TEXT PRIMARY KEY, name TEXT, last_opened_at TEXT);
-- quarantine tables (preserve undecodable rows for recovery)
CREATE TABLE tasks_quarantine (id TEXT PRIMARY KEY, data TEXT);
CREATE TABLE projects_quarantine (id TEXT PRIMARY KEY, data TEXT);
```

#### Encoding Strategy
| Field type | Encoding | Notes |
|------------|----------|-------|
| Scalars (id, type, status, SHAs) | Native SQLite TEXT/INTEGER | Atoms → strings |
| DateTime (started_at, finished_at, last_opened_at) | ISO8601 string | `DateTime.to_iso8601/1` / `DateTime.from_iso8601/1` |
| Atoms (type, status, review_status) | `encode_atom/1` → string | Stored as TEXT; `encode_atom/1` accepts nil, atoms, AND strings (round-trip safe). Decoded via `decode_atom/1` using `String.to_existing_atom/1` (returns nil for unknown values — never crashes) |
| opts (keyword list) | JSON array of `[key_string, value]` pairs | Jason encode/decode. Known opt keys atomized via whitelist; unknown keys kept as strings |
| logs (list of strings) | JSON array | Jason encode/decode |
| **result** (opaque Elixir term) | **JSON with `"__result_tag__"` discriminator** | Tuple shape (`{:ok, _}`, `{:error, _}`, `{:exit, _}`) faithfully rebuilt. Atom keys in the success map atomized via `@result_data_fields` whitelist. Embedded `%EvoGit.Agent.Usage{}` rebuilt. Plain strings stored verbatim. |
| usage (`EvoGit.Agent.Usage`) | JSON map (`Map.from_struct/1`) | Decoded back into `%EvoGit.Agent.Usage{}` struct |
| archive_metadata (list of maps) | JSON array | Maps decode with string keys (web layer normalizes) |
| pid | `:erlang.pid_to_list/1` → string | Restored via `:erlang.list_to_pid/1`; stale after VM restart |

#### Typed Public API
```elixir
# Tasks
put_task(store, %TaskInfo{}) :: :ok | {:error, term()}   # validates id + status present
get_task(store, task_id) :: TaskInfo.t() | nil
delete_task(store, task_id) :: :ok
delete_tasks(store, [task_id]) :: :ok                     # batch delete
select_all_tasks(store) :: [TaskInfo.t()]
count_tasks(store) :: non_neg_integer()
clear_tasks(store) :: :ok

# Projects
put_project(store, %RecentProject{}) :: :ok | {:error, term()}  # validates path present
get_project(store, path) :: RecentProject.t() | nil
delete_project(store, path) :: :ok
select_all_projects(store) :: [RecentProject.t()]
count_projects(store) :: non_neg_integer()

# Safety / Integrity
safe_select_all_tasks(store) :: [TaskInfo.t()]            # quarantines bad rows, never raises
safe_select_all_projects(store) :: [RecentProject.t()]
integrity_check(store) :: :ok | {:repaired, count} | {:error, reason}
size(store) :: non_neg_integer()                          # total across both tables
```

- `integrity_check/1`: Runs `PRAGMA integrity_check`, scans all rows, quarantines undecodable rows (INSERT raw JSON into quarantine table + DELETE from live). If quarantine INSERT fails, row is left in place (never destroyed). Returns `:ok` / `{:repaired, count}` / `{:error, reason}`. Called by TaskRegistry on init.
- **Schema migration**: `maybe_migrate_old_schema/1` detects old `(id, data BLOB)` schema via `PRAGMA table_info`, drops both tables, and recreates with the new column-based schema. Old data is lost (acceptable in early development).

### `EvoDash.TaskRegistry` (`task_registry.ex`)
- Singleton `GenServer` backed by SQLite via `EvoDash.Store` (single source of truth).
- Tracks EvoGit tasks (`:genesis` / `:evolve` / `:extract_skills`) with id, type, status, opts, pid, timestamps, logs, result, review metadata, usage, archive_metadata.
- Runtime-only task references (`%Task{}`) are kept in an in-memory `task_refs` map (`%{task_id => %Task{}}`), not persisted.
- All store-touching `handle_*` callbacks have NO try/rescue — if the Store is down, the GenServer crashes and the supervisor restarts it. This is correct process isolation and prevents silent data loss.

**Client API:**
| Function | Description |
|---|---|
| `start_task(task_type, opts)` | Starts a `:genesis` or `:evolve` task; spawns a linked process. Returns `{:ok, task}`. |
| `get_task(task_id)` | Retrieves a single task by ID. |
| `list_tasks()` | Returns all tracked tasks. |
| `list_tasks_by_path(path)` | Returns tasks filtered by repo path. |
| `get_unique_paths()` | Returns list of unique repo paths. |
| `cancel_task(task_id)` | Kills the task process and marks it `:cancelled`. |
| `update_task_status(task_id, status, result \\ nil)` | Casts a status update. |
| `update_task_log(task_id, log_entry)` | Appends a log entry (prepending). |
| `set_review_status(task_id, status)` | Sets review status. |
| `set_review_metadata(task_id, base_sha, commit_sha)` | Sets review SHAs. |
| `delete_task(task_id)` | Removes a task. |
| `clear_finished_tasks()` | Removes all finished tasks. |

## Task Lifecycle
1. **Creation** (`start_task/2`): Generates random 16-char hex ID, spawns `Task.Supervisor.async_nolink` task, writes `TaskInfo` to SQLite via `put_task` (ref nulled), stores ref in `task_refs`.
2. **Running**: Status updates via `cast`. All writes go through `EvoDash.Store.put_task/2`.
3. **Completion/Failure**: On terminal status, `finished_at` is set, task removed from `task_refs`, `cleanup_expired_tasks/1` runs.
4. **Crash recovery**: `normalize_tasks/1` reconciles `:running`/`:pending` tasks on startup. Live pids are re-monitored; dead/nil pids marked `:failed`.
5. **DOWN handling**: `handle_info({:DOWN, ...})` reconciles task termination.
6. **Deletion**: `delete_task/1` → `TaskStore.delete_task/2`. `clear_finished_tasks/0` → `TaskStore.delete_tasks/2`.

## Retention & Eviction
- `cleanup_expired_tasks/1`: removes finished tasks older than `max_age_days` (default 14) and enforces `max_tasks` (default 100). Uses `delete_tasks/2` for batch deletion.
- Recent projects capped at 10 via `trim_recent_projects/1`.

## One-time DETS→SQLite Migration
- `maybe_migrate_from_dets/1`: if SQLite store is empty AND old DETS files exist, migrates records via `put_task`/`put_project`, then renames `.dets` files to `.dets.migrated`.

## Constraints
- `TaskRegistry` is a singleton; do not start multiple instances.
- `EvoDash.Store` is the single source of truth — all reads/writes go through the typed GenServer API.
- Runtime task refs (`%Task{}`) are in-memory only; persisted tasks always have `ref: nil`.
- Task log list stored in reverse chronological order (newest first).
- All task types must be `:genesis`, `:evolve`, or `:extract_skills`.
- Depends on `evo_git` application at runtime.
- `put_task` rejects non-`%TaskInfo{}` input with `{:error, :invalid_task_struct}`.
- `put_project` rejects non-`%RecentProject{}` input with `{:error, :invalid_project_struct}`.
