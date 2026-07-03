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
  2. `Phoenix.PubSub` (registered as `EvoDash.PubSub`)
  3. `EvoDash.Store` (SQLite store — started BEFORE TaskRegistry, which depends on it at init)
  4. `EvoDash.TaskRegistry`
  5. `EvoDashWeb.Endpoint`

### `EvoDash.RecentProject` (`store.ex`)
- Struct representing a recently opened project: `%RecentProject{path: String.t(), name: String.t(), last_opened_at: DateTime.t() | nil}`.

### `EvoDash.Store` (`store.ex`)
- GenServer wrapping a single xqlite (SQLite) connection, owning the connection in its state.
- Started under supervision with `data_dir:` (a FILE path to the `.sqlite` file) and optional `name:` (defaults to `EvoDash.Store`).
- **Column-based SQLite schema** (NOT term_to_binary blobs): each TaskInfo/RecentProject field maps to a dedicated SQLite column.
- **Explicit durability PRAGMAs**: `Xqlite.open(path, journal_mode: :wal, synchronous: :normal)` — WAL + NORMAL is the recommended combo for crash safety and write performance.
- **Graceful connection close**: `terminate/2` calls `XqliteNIF.close(conn)` (wrapped in justified try/rescue — GenServer terminate/2 must never raise).
- **Crash philosophy / try-rescue anti-pattern**: `handle_call`/`handle_cast`/`handle_info` callbacks have NO try/rescue (crashes propagate to supervisor for restart). The codec uses non-crashing `Jason.encode/1` + `case` for TOTAL encode (no try/rescue). Justified try/rescue remains only in: `terminate/2` (shutdown safety), quarantine/recovery logic (`safe_select_all_rows`, `integrity_check`, `scan_and_repair`, `quarantine_row` — deliberate data-recovery boundaries that quarantine corrupt rows instead of crashing). All justified try/rescue blocks have comments explaining (1) whether the error is expected and (2) why try/rescue is the cleanest approach.

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

### `EvoDash.TaskRegistry` (`task_registry.ex`)
- Singleton `GenServer` backed by SQLite via `EvoDash.Store` (single source of truth).
- Tracks EvoGit tasks (`:genesis` / `:evolve` / `:extract_skills`) with id, type, status, opts, pid, timestamps, logs, result, review metadata, usage, archive_metadata.
- Runtime-only task references (`%Task{}`) are kept in an in-memory `task_refs` map (`%{task_id => %Task{}}`), not persisted.
- All store-touching `handle_*` callbacks have NO try/rescue — if the Store is down, the GenServer crashes and the supervisor restarts it. This is correct process isolation and prevents silent data loss.
- **try/rescue anti-pattern cleanup**: `init/1` calls `Store.integrity_check/1` directly (no try/rescue — it returns `{:error, _}` rather than raising). `normalize_tasks/1` has no try/rescue (crashes propagate to supervisor). `sched_meta_has_active_agents?/1` uses `:ets.info/1` (returns `:undefined` for missing tables, non-crashing) instead of try/rescue. `cancel_task_agents` uses `catch :exit` (legitimate for cross-app GenServer calls to a possibly-dead process) with logging instead of silent `rescue _ -> :ok`.

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
4. **Crash recovery**: `normalize_tasks/1` reconciles `:running`/`:pending` tasks on startup. Live pids are re-monitored; dead/nil pids marked `:failed` (unless `:evogit_sched_meta` ETS still has active agents for the task_id).
5. **DOWN handling**: `handle_info({:DOWN, ...})` reconciles task termination.
6. **Deletion**: `delete_task/1` → `Store.delete_task/2`. `clear_finished_tasks/0` → `Store.delete_tasks/2`.

### All `:failed`-Transition Sites (status set to `:failed`)
| # | Site (file:line) | Trigger | Guard/Condition |
|---|---|---|---|
| 1 | `task_registry.ex:848-867` (`handle_info({ref, result})`) | Wrapper Task returns a result | Catch-all `_ -> :failed` for any result NOT `{:ok, _}` (covers `{:error,_}`, `{:exit,_}`, unexpected shapes) |
| 2 | `task_registry.ex:939` (`handle_info({:DOWN, ref, ...})`) | Wrapper process exits | `reason != :normal` AND `sched_meta_has_active_agents?(task_id)` returns **false** |
| 3 | `task_registry.ex:306-348` (`handle_cast({:update_status, ...})`) | Receives ANY status via cast | Persists `:failed` if cast — called by sites #1 and #2. Has a stale-terminal-status guard that **ignores** a DIFFERENT terminal status if one is already set (logs "Ignoring stale status update"). |
| 4 | `task_registry.ex:804-836` (`handle_info({:task_status, task_id, status})`) | PubSub `"tasks"` topic | Blindly persists whatever status atom arrives. Has a terminal-status guard that ignores updates once terminal. NOTE: the evo_git runtime only EVER broadcasts `:finalizing` here (see `runtime/helpers.ex:102`); `:failed`/`:completed` are never broadcast over PubSub — they only originate from sites #1/#2. |
| 5 | `task_registry.ex:542` (`reconcile_task_status`) | Registry restart (init) | Dead/nil pid AND `sched_meta_has_active_agents?(task_id)` returns false |

### Known Concurrency Hazard — premature `:failed` while work is ongoing

**Symptom:** Tasks get marked `:failed` while still running normally, then subsequent `:finalizing`/`:completed` updates are logged as "Ignoring stale ... already terminal (failed)".

**The `:failed` status is NEVER broadcast from evo_git** — only `:finalizing` is (`Helpers.notify_finalizing/1`, called on the success path AFTER `run_agent/1` returns, BEFORE `merge_and_report/3`). Therefore the premature `:failed` MUST originate inside EvoDash, from one of these two monitors on the wrapper `Task.Supervisor.async_nolink` process:

1. **`handle_info({ref, result})` (line 840)** — the `{ref, result}` message handler. Maps any non-`{:ok,_}` return to `:failed`. But the runtime ALWAYS returns `{:ok,_}` on success, so this only fires `:failed` on a genuine runtime error/exit. **This is NOT the culprit** for a task that later succeeds.

2. **`handle_info({:DOWN, ref, :process, pid, reason})` (line 907)** — the process-down handler. Guarded by `sched_meta_has_active_agents?(task_id)`. **This is the prime suspect.** A `:DOWN` with `reason != :normal` arrives for the wrapper process BEFORE the runtime's `{:ok,_}` result is delivered, and `sched_meta_has_active_agents?` returns **false** (race window), so the task is marked `:failed`. The legitimate `{:ok,_}` result then arrives at `handle_info({ref, result})` and calls `update_task_status(:completed)`, but `handle_cast({:update_status,...})` (line 315) now rejects it as a stale-terminal-status change.

**Race conditions that defeat the `sched_meta_has_active_agents?` guard (line 931/555):**
- The ETS `:evogit_sched_meta` table is scanned via `:ets.tab2list()` then filtered by `task_id`. Entries are deleted (`Store.delete_sched_meta/1`) during `Lifecycle` agent teardown (`lifecycle.ex:37,93,185,225`). If the top-level agent's SchedMeta has already been removed before the `:DOWN` handler runs, the check returns false → spurious `:failed`.
- `sched_meta_has_active_agents?` only matches on `Map.get(meta, :task_id) == task_id`. If the wrapper crashed but the scheduler's agents are tracked under a different/derived task grouping, the check misses them.
- The guard returns false if the `:evogit_sched_meta` table does not exist (`:undefined` / `ArgumentError`), which happens if `AgentScheduler` is not started or after a full VM restart.

**Likely root cause of the observed bug:** The wrapper `Task.Supervisor.async_nolink` process (started at line 146) exits abnormally — e.g. because the scheduler replies to the wrapper and the wrapper exits with a non-`:normal` reason, or a transient crash — at a moment when the scheduler has ALREADY torn down the agent's `SchedMeta` ETS entry (so the active-agents check returns false). The `:DOWN` handler then marks the task `:failed`. The runtime's `{:ok,_}` result (produced by `merge_and_report`, which logs "Agent produced changes" and "Created branch") arrives immediately after and is discarded as stale.

## Retention & Eviction
- `cleanup_expired_tasks/1`: removes finished tasks older than `max_age_days` (default 14) and enforces `max_tasks` (default 100). Uses `delete_tasks/2` for batch deletion.
- Recent projects capped at 10 via `trim_recent_projects/1`.

## Constraints
- `TaskRegistry` is a singleton; do not start multiple instances.
- `EvoDash.Store` is the single source of truth — all reads/writes go through the typed GenServer API.
- Runtime task refs (`%Task{}`) are in-memory only; persisted tasks always have `ref: nil`.
- Task log list stored in reverse chronological order (newest first).
- All task types must be `:genesis`, `:evolve`, or `:extract_skills`.
- Depends on `evo_git` application at runtime.
- `put_task` rejects non-`%TaskInfo{}` input with `{:error, :invalid_task_struct}`.
- `put_project` rejects non-`%RecentProject{}` input with `{:error, :invalid_project_struct}`.
