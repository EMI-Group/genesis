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
- **Pagination + filtering** (`safe_select_paginated_tasks/2`): builds a `WHERE` clause via `build_where/1` from a `filters` keyword list (`:status`, `:project_path`, `:review_status`, `:search`), with incremental `?N` placeholder indexing so `LIMIT/OFFSET` can append their own placeholders. The `:project_path` and `:search` filters use SQL `LIKE` against the raw `opts` TEXT column.
- **CRITICAL — opts LIKE patterns must match the array-of-pairs JSON, NOT object JSON.** `opts` is encoded by `Codec.encode_opts/1` as a **JSON array of 2-element arrays** (compact, NO spaces), e.g. `[path: "/foo"]` → `[["path","/foo"]]` (NOT a JSON object `{"path":"/foo"}`). Therefore the key and value within a pair are separated by a **COMMA**, not a colon. The `:project_path` LIKE pattern is `"%" <> "\"path\",\"#{path}\"" <> "%"` (comma between key and value — this is CORRECT for the array-of-pairs encoding). Do NOT "fix" the comma to a colon unless `encode_opts/1` is changed to emit a JSON object. The `:search` filter is a plain substring match (no key/value assumption). The `:review_status` "pending" composite matches `result LIKE '%"branch_name"%'`. Minor latent edge case: SQL `LIKE` treats `_` and `%` as wildcards; a fully-robust `:project_path` would escape these via `ESCAPE '\'` (not currently done — low severity since project paths rarely collide via single-char substitution).
- Started under supervision with `data_dir:` (a FILE path to the `.sqlite` file) and optional `name:` (defaults to `EvoDash.Store`).
- **Column-based SQLite schema** (NOT term_to_binary blobs): each TaskInfo/RecentProject field maps to a dedicated SQLite column.
- **Explicit durability + memory-efficient PRAGMAs**: `Xqlite.open(path, journal_mode: :wal, synchronous: :normal, cache_size: -2000)` — WAL + NORMAL is the recommended combo for crash safety and write performance. `cache_size: -2000` (~2MB) overrides xqlite's 64MB default page-cache, which was absurdly over-provisioned for a ≤100-row dashboard DB.
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

### `EvoDash.NodeContext` (`node_context.ex`)
- Domain-layer thin client for **SSH Remote Development** (the node-aware dashboard, Phase 2). Not a GenServer — a pure wrapper module and the single entry point for the web layer to manage remote connections and read remote runtime state.
- **Target persistence** (delegates to `EvoGit.RemoteConnections`, pure TOML functions): `list_targets/0`, `get_target/1`, `save_target/1`, `delete_target/1`.
- **Connection lifecycle** (delegates to the `EvoGit.RemoteConnection` GenServer): `connect/1`, `disconnect/1`, `bootstrap/1`, `connection_status/0,1`, `connected?/1` — all **gracefully degrade** to safe fallbacks (`{:error, :remote_connection_unavailable}`, `%{}`, `:disconnected`, `false`) when that module isn't compiled/started (ships as parallel Phase 2 work).
- **Cross-node RPC helpers**: `call_remote/4` wraps `:erpc.call/5` (10s timeout; returns `{:ok, _} | {:error, _}`; local node calls go direct without erpc). State readers `list_agents/1`, `get_agent_history/2`, `get_agent_state/2`, `get_remote_config/1`, `get_remote_config_status/1`, `paused?/1` read local ETS directly when `node == node()` and route through `:erpc` to `EvoGit.AgentScheduler.RemoteAPI` when remote.
- All degradation is centralized in a private `with_remote_connection/4` guard (`Code.ensure_loaded?/1` + `catch :exit`). The only exception handling: a justified `try/catch` in `call_remote/4` (cross-node RPC boundary) and a justified `catch :exit` for the possibly-dead GenServer.

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

Diagnostic logging was added to investigate the "task shows `:failed` mid-run without any FAILED_TRANSITION log" bug:

- **Store chokepoint (`Store: FAILED_WRITE`)**: `handle_call({:put_task, task}, ...)` now logs a `Logger.warning` with prefix `"Store: FAILED_WRITE"` BEFORE the INSERT when writing `:failed` as a NEW transition (previous status was not `:failed`). The SELECT for previous status runs ONLY when `task.status == :failed` (efficiency). This is the ULTIMATE chokepoint — it cannot be bypassed. Helper: `log_failed_write_if_transition/2`, `read_task_status/2`.
- **Startup sentinel** was removed — no longer needed.

## Retention & Eviction
- `cleanup_expired_tasks/1`: removes finished tasks older than `max_age_days` (default 14) and enforces `max_tasks` (default 100). Uses `delete_tasks/2` for batch deletion.
- Recent projects capped at 10 via `trim_recent_projects/1`.

## Memory Usage Patterns (Idle Footprint Investigation)

**Reported idle cost:** `EvoDash.TaskRegistry` ~14MB, `EvoDash.Store` ~7MB (process memory, e.g. via `:erlang.process_info/2` or :observer).

### Key finding 1 — Neither GenServer holds large in-memory state

Both GenServers have **minimal state by design**:

- **`EvoDash.TaskRegistry` state** (`task_registry.ex:149-153`): `%{data_dir, task_store, task_refs: %{}}`. The `task_refs` map holds only `%Task{}` refs for *currently running* tasks — empty when idle. Task data itself is NEVER cached in the GenServer state; every read (`get_task`, `list_tasks`, etc.) is a synchronous `GenServer.call` to `EvoDash.Store`. There is **no in-memory cache** of task data.
- **`EvoDash.Store` state** (`store.ex:237`): `%{conn, data_dir}` — just the xqlite connection reference. No row cache, no pre-allocated buffers.

### Key finding 2 — `EvoDash.Store` idle memory comes from the xqlite/SQLite page cache

**Root cause:** The `xqlite` library (v0.8.0, `deps/xqlite/lib/xqlite.ex:41-46`) overrides SQLite's default `cache_size` PRAGMA to **`-64000` (64 MB)**:

```elixir
# deps/xqlite/lib/xqlite.ex:41-46
cache_size: [
  type: :integer,
  default: -64_000,
  doc: "Page cache size. Negative values mean KB (e.g., `-64000` = 64MB). SQLite default is 2MB."
],
```

This default is applied to **every** connection opened via `Xqlite.open/2` (the pragma is in `@pragma_order` at line 76, applied unconditionally in `apply_pragmas/1` at lines 271-280 via the catch-all `set_pragma_value/2` clause at line 312-313). The `EvoDash.Store` opens its connection at `store.ex:232`:

```elixir
# store.ex:232 — does NOT pass cache_size:, inherits the 64MB default
case Xqlite.open(data_dir, journal_mode: :wal, synchronous: :normal) do
```

The `cache_size` is **never overridden** anywhere in EvoDash's code or config (confirmed: zero matches for `cache_size` in `apps/evo_dash/` and `config/`). The 64MB is a *maximum* (SQLite allocates page-cache memory lazily as pages are touched), but the Store's `init/1` immediately runs `create_tables` + `migrate_schema` + (called by TaskRegistry.init) `integrity_check` + `scan_and_repair` which `SELECT *` from all tables, populating the cache. This page-cache memory is allocated inside the SQLite C library via the NIF and is attributed to the Store GenServer process (the connection owner). **This is the primary source of the Store's ~7MB idle footprint.**

**Mitigation (not yet applied):** Pass `cache_size: -2000` (8MB, SQLite's own default) or lower to `Xqlite.open/2` in `store.ex:232`. For a dashboard task-history DB with at most 100 rows, even `-512` (2MB) would be ample.

### Key finding 3 — `EvoDash.TaskRegistry` idle memory comes from init-time full-table scans inflating the BEAM heap

The TaskRegistry does NOT own a SQLite connection, so its memory is **BEAM heap**, not NIF/SQLite cache. The primary driver is `init/1` (`task_registry.ex:133-178`), which triggers **three sequential full-table scans** that each load ALL tasks into the TaskRegistry process heap as decoded `%TaskInfo{}` structs:

1. **`EvoDash.Store.integrity_check/1`** (line 158) → Store's `do_integrity_check` → `scan_and_repair` does `SELECT * FROM tasks` + `SELECT * FROM projects` (`store.ex:840-841`, `scan_and_repair` at lines 952-978). Raw rows flow through the Store process, but the *return value* is just `:ok`/`{:repaired, n}` — minimal heap impact on TaskRegistry.

2. **`normalize_tasks/1`** (line 163, defined at lines 518-531) → calls `select_all_tasks(state)` → `Store.safe_select_all_tasks` → `SELECT * FROM tasks` + decode **every row** into a full `%TaskInfo{}` struct (including `logs`, `result`, `archive_metadata` — all JSON-decoded). The **entire list of structs** is held in the TaskRegistry process heap during the `Enum.reduce`. Each `%TaskInfo{}` can be large: `logs` is a list of strings, `result` is a decoded map (possibly embedding `%EvoGit.Agent.Usage{}`), `archive_metadata` is a list of per-agent maps. After the reduce completes, the list becomes garbage, but **BEAM's generational GC may not immediately reclaim it** — the heap high-water mark persists until a major GC or fullsweep.

3. **`Cleanup.cleanup_expired_tasks/1`** (line 166) → `EvoDash.Store.safe_select_all_tasks` → **another** `SELECT * FROM tasks` + full decode. This rebuilds the entire task list again in the TaskRegistry heap.

After init, the TaskRegistry's heap has been inflated by holding the full decoded task dataset (potentially 100 tasks × multiple-KB each). The BEAM process memory (`:erlang.process_info(pid, :memory)`) reports the **current heap size including unreclaimed garbage**, which can remain elevated. This is the most likely source of the ~14MB idle figure.

**Secondary contributors:**
- **PubSub subscription** (`task_registry.ex:169`): `Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")` — the PG2 adapter (`:pg`) tracks the subscriber; negligible per-process cost but adds monitor entries.
- **`EvoDash.TaskRegistry.ProcessRegistry`** (a `Registry`, started in `application.ex:21`): creates an internal ETS table for `:unique` key tracking. Owned by the Registry process (a sibling under `:one_for_one`), NOT by TaskRegistry. Empty when idle — negligible.

### Key finding 4 — Coding patterns that amplify transient heap (not retained, but inflate high-water mark)

- **`select_all_tasks(state)` helper** (`task_registry.ex:504-506`): Every call to `list_tasks`, `list_tasks_by_path`, `get_unique_paths`, `clear_finished_tasks` loads the **entire** tasks table into the GenServer heap. There is no streaming/cursor approach. With 100 tasks (the `max_tasks` retention cap), each carrying logs/result/usage JSON, a single `list_tasks` call can transiently allocate several MB.
- **`append_log`** (`task_registry.ex:377-388`): Does a `get_task` (single row) then `put_task` with the **entire logs list** re-encoded — O(n) copy of the full log list on every log append.
- **`handle_update_status`** (`task_registry.ex:432-494`): On terminal status, calls `Cleanup.cleanup_expired_tasks` which does **another** full `SELECT * FROM tasks`.

### Key finding 5 — No other EvoDash modules hold significant state

Only two GenServers exist in `apps/evo_dash/lib/evo_dash/`: `TaskRegistry` and `Store` (confirmed via grep for `use GenServer`). Other modules are pure functions (`Codec`, `Cleanup`, `Diagnostics`, `Lease`, `RuntimeOpts`, `ResumeContext`, `TaskExecutor`, `MarkdownRender`, `NodeContext`, `SettingsUtils`) or structs (`TaskInfo`, `RecentProject`). No `Agent`, no `persistent_term`, no ETS table creation in EvoDash domain code.

### evo_git attribution (ruled out)

The `:evo_git` core runtime creates 3 ETS tables (`:evogit_agent_state`, `:evogit_sched_meta`, `:evogit_archive_records`) — all `:public`/`:named_table`, owned by the **evo_git application master process**, and **empty at idle**. EvoDash reads `:evogit_sched_meta` directly (via `Lease.sched_meta_has_active_agents?/1` using `:ets.tab2list/1`), but ETS memory is always attributed to the **owning** process, not readers. The evo_git AgentScheduler has minimal state (empty maps/queues at idle). **None of evo_git's memory is attributable to EvoDash processes.**

## Constraints
- `TaskRegistry` is a singleton; do not start multiple instances.
- `EvoDash.Store` is the single source of truth — all reads/writes go through the typed GenServer API.
- Runtime task refs (`%Task{}`) are in-memory only; persisted tasks always have `ref: nil`.
- Task log list stored in reverse chronological order (newest first).
- All task types must be `:genesis`, `:evolve`, or `:extract_skills`.
- Depends on `evo_git` application at runtime.
- `put_task` rejects non-`%TaskInfo{}` input with `{:error, :invalid_task_struct}`.
- `put_project` rejects non-`%RecentProject{}` input with `{:error, :invalid_project_struct}`.
