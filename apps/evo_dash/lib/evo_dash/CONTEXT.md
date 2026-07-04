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

### `:failed`-Transition Analysis — Architectural Impossibility of `:failed → :completed` Recovery

**Diagnostic logging (commit `0d3b9a6`):** All 5 sites that set status to `:failed` call `log_failed_transition/4` BEFORE the `Store.put_task` write, emitting a `Logger.warning` with prefix `"TaskRegistry: FAILED_TRANSITION"` and a current-process stacktrace. Site #3 (cast chokepoint) only logs when `task.status != :failed` (i.e., the FIRST transition into `:failed` is always logged; re-writing `:failed` to an already-`:failed` task does not log).

**The `:failed` status is NEVER broadcast from evo_git** — only `:finalizing` is (`Helpers.notify_finalizing/1`). `:failed`/`:completed` are dashboard-only concepts.

**CRITICAL CONTRADICTION (discovered in investigation):** For a task to go `:failed → :completed`, the result handler (`handle_info({ref, result})` with `{:ok, _}`) or the DOWN-`:normal` handler must fire, which REQUIRES the task to be in `task_refs`. But EVERY `:failed`-transition path either (a) removes the task from `task_refs` (sites #1/#2/#3/#4 all delete from `task_refs` on terminal status via `handle_update_status` lines 425-427 or the PubSub handler lines 978-980), or (b) never adds it to `task_refs` (site #5 reconcile returns `state` unchanged). Therefore **once a task is `:failed`, the result/DOWN handlers cannot find it in `task_refs` → CANNOT produce `:completed`**. The symptom "`:failed` mid-run then resets to `:completed`" is **architecturally impossible in a single TaskRegistry lifecycle**.

**Implications for the observed bug (`:failed` appears without any FAILED_TRANSITION log, then resets to `:completed`):**
1. **NOT a 6th code path**: Exhaustive search confirms exactly 3 `Store.put_task` calls can write `:failed` (lines 423, 525, 976), all logged. The remaining `put_task` calls (start_task:170, cancel_task:219, append_log:329, set_review_status:351, set_review_metadata:366) cannot write `:failed` — they preserve the existing status.
2. **NOT evo_git**: evo_git has ZERO code calls to `EvoDash.Store` or `EvoDash.TaskRegistry` (only `notify_finalizing` broadcasts `:finalizing`; system_check is read-only). No Oban/jobs/migrations write to the store. No schema-level DEFAULT for the status column.
3. **NOT the codec/display layer**: `decode_atom("failed")` faithfully returns `:failed`. No status inference at read time. LiveViews re-fetch from `TaskRegistry.list_tasks()` on every PubSub event — no client-side status computation. No JS-based status inference.
4. **NOT a string-vs-atom mismatch**: The `status == :failed` log guards compare against the atom. `decode_atom` always returns atoms. `update_task_status` callers always pass atoms.
5. **NOT a logger filtering issue**: No `Logger.metadata`, no custom `:logger` handler, no `compile_time_purge_level`, no process-specific group leader. Dev logger includes `:warning` (no level filter; defaults to `:debug`). Prod logger level is `:info` (includes `:warning`). `log_failed_transition` and all helpers (`capture_stacktrace`, `format_stacktrace`) cannot crash — `Process.info(self(), :current_stacktrace)` always succeeds.

**Most likely explanations (in order of probability):**
1. **STALE COMPILED CODE (most likely):** `task_registry.ex` is under `lib/evo_dash/` (domain logic), which is NOT covered by Phoenix's `live_reload` patterns (`dev.exs:51` only watches `lib/evo_dash_web/`). Recompiling the module does NOT update a running GenServer process (Elixir hot code reloading requires explicit `:sys.suspend`+`:code.purge` or a process restart). If the server was running when the logging was committed and was NOT restarted, the TaskRegistry is still executing the OLD compiled code without `log_failed_transition` — so `:failed` IS written but NOT logged. **Action: fully restart the Phoenix server (not just recompile) after adding logging.**
2. **TaskRegistry RESTARTED mid-run** (supervisor `:one_for_one`, `max_restarts: 10`): If the registry crashed and restarted while a task was running, `reconcile_task_status` runs in `init`. If the wrapper pid is alive → re-monitor → stays `:running` (logged as "re-monitoring"). If dead + `sched_meta_has_active_agents?` → stays `:running` but **NOT added to `task_refs`** (line 561) → the task can NEVER complete via result/DOWN handlers → stuck at `:running`/`:finalizing` forever (a DIFFERENT bug). If dead + sched_meta FALSE → `:failed` + LOG (line 566) → permanently `:failed`.
3. **Stale `:failed` from a PREVIOUS task**: The dashboard's `current_tasks/1` returns ALL tasks for the project path, including old genuinely-`:failed` tasks. The user may be observing an old `:failed` task card alongside the current `:running`/`:completed` task.

**Known reconcile bug (line 561):** When `sched_meta_has_active_agents?` returns TRUE but the wrapper pid is dead/nil, the task is kept as `:running` but is NOT added to `task_refs`. This means: (a) no monitor is set up; (b) the result handler cannot match the task when `{ref, result}` arrives; (c) the DOWN handler cannot match. The task becomes **permanently stuck** at `:running` (or `:finalizing` after the PubSub broadcast) — it can never transition to `:completed` or `:failed` through normal handlers. Only a subsequent registry restart + reconcile can resolve it (and only if the pid becomes alive or sched_meta clears).

**FIXED reconcile bug (commit `93cb3131`):** The reconcile bug above is now FIXED. When `sched_meta_has_active_agents?` returns TRUE but the wrapper pid is dead/nil, `reconcile_task_status` now schedules a periodic recheck via `Process.send_after(self(), {:recheck_task, task_id}, 30_000)`. The `handle_info({:recheck_task, task_id}, state)` handler re-checks if agents are still active; if not, it resolves the task (best-effort result lookup from sched_meta ETS, defaults to `:completed` if no result found). This prevents tasks from being permanently stuck at `:running` after a registry restart with active agents.

### Diagnostic Instrumentation (commit `93cb3131`)

Three layers of diagnostic logging were added to investigate the "task shows `:failed` mid-run without any FAILED_TRANSITION log" bug:

1. **Store chokepoint (`Store: FAILED_WRITE`)**: `handle_call({:put_task, task}, ...)` now logs a `Logger.warning` with prefix `"Store: FAILED_WRITE"` BEFORE the INSERT when writing `:failed` as a NEW transition (previous status was not `:failed`). The SELECT for previous status runs ONLY when `task.status == :failed` (efficiency). This is the ULTIMATE chokepoint — it cannot be bypassed. Helper: `log_failed_write_if_transition/2`, `read_task_status/2`.
2. **Startup sentinel (`TaskRegistry: INIT_LOGGING_V3`)**: `init/1` logs a warning confirming the running process has the instrumented code, including `task_refs` map size.

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
