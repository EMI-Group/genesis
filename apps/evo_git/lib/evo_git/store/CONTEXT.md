# EvoGit.Store — SQLite Persistence Layer

## Intent

Contains the `EvoGit.Store` GenServer and its support modules for the SQLite persistence layer. The main store module (`store.ex`) lives in `:evo_git` so the headless remote daemon can persist task data, and is split into focused sub-modules.

## Routing Table

- `../store.ex` → Main GenServer module (`EvoGit.Store`) — public API, GenServer callbacks, private helpers
- `./codec.ex` → `EvoGit.Store.Codec` — pure serialization/deserialization functions (no I/O)
- `./schema.ex` → `EvoGit.Store.Schema` — table creation, idempotent column migration, timestamp normalization
- `./queries.ex` → `EvoGit.Store.Queries` — SQL builder helpers (WHERE, SET, clamping, column encoding)
- `./errors.ex` → `EvoGit.Store.Errors` — disk-full error classifier (pure; public `disk_full_error?/1` for testability)

## API Surface

### `EvoGit.Store` (`../store.ex`)

GenServer wrapping a single xqlite (SQLite) connection. Public API for task and project CRUD and lightweight queries.

**Internal helper patterns (worth knowing before editing `store.ex`)**:
- `offload/3` (store.ex:963) — spawns a short-lived linked `Task.start` that performs the query+decode and replies via `GenServer.reply/2` (`{:noreply, state}` immediately), keeping large decoded terms off the GenServer heap; used by the heavy query handlers (see "Heavy SELECT handlers offloaded to short-lived Tasks").
- `fetch_single_row/4` (store.ex:1236) — single-row SELECT + decode-fn; deliberately NO catch-all `_` clause, so an unexpected query/row shape raises exactly as before (crash semantics preserved).
- `count_table/2` (store.ex:1307) — shared by the `:count_tasks`/`:count_projects` handlers.

**Length note** — `store.ex` (~1310 lines) is the main persistence GenServer (WAL writes, decode/offload read handlers, bookkeeping); the focused support modules (Codec, Schema, Queries, Errors) live in this `store/` directory — it stays cohesive, do NOT split it without a plan.

### `EvoGit.Store.Codec` (`codec.ex`)

| Function | Description |
|----------|-------------|
| `task_columns/0` | Ordered list of task table column names |
| `project_columns/0` | Ordered list of project table column names |
| `encode_task/1` | TOTAL encode (never raises) — serializes `%TaskInfo{}` into column values |
| `decode_task/1` | Deserializes column values into `%TaskInfo{}`. Raises on bad data (callers skip undecodable rows + `Logger.warning`). |
| `encode_project/1` | TOTAL encode for `%RecentProject{}` structs |
| `decode_project/1` | Deserializes column values into `%RecentProject{}` |
| `validate_task/1` | Validates a task list for structural correctness |
| `validate_project/1` | Validates a project list for structural correctness |

### `EvoGit.Store.Schema` (`schema.ex`)

| Function | Description |
|----------|-------------|
| `create_tables/1` | Creates tables (tasks, projects) and indexes |
| `migrate_schema/1` | Idempotent column migration — adds missing columns to existing DBs (incl. `updated_at`); invoked by the `mix migrate.store` task (`Store.init/1` does not auto-migrate) |
| `normalize_timestamps/1` | Idempotent, SQL-only data migration — rewrites existing timestamp rows to the fixed-precision format |
| `existing_columns/2` | Reads column names via `PRAGMA table_info` |

### `EvoGit.Store.Queries` (`queries.ex`)

| Function | Description |
|----------|-------------|
| `task_select_sql/0` | SELECT SQL string for all task columns |
| `project_select_sql/0` | SELECT SQL string for all project columns |
| `build_update_set/2` | Builds SET clause and value list for targeted UPDATE |
| `encode_column_value/2` | Encodes a single column value via the appropriate `Codec.encode_*` |
| `clamp_limit/1` | Ensures limit is a positive integer (default 50) |
| `clamp_offset/1` | Ensures offset is a non-negative integer (default 0) |
| `build_where/1` | Builds SQL WHERE clause and param list from filter options |
| `escape_like/1` | Escapes SQL LIKE-special characters |

### Field-level encoders/decoders (Codec)
- **Atoms**: `encode_atom/1` (nil/atoms/strings), `decode_atom/1` (`String.to_atom/1` guarded by closed whitelist `@known_atoms`); `String.to_existing_atom/1` only in `decode_reason/1` (the one justified try/rescue).
- **DateTime**: `encode_datetime/1` emits fixed-precision 24-char ISO-8601 (`%Y-%m-%dT%H:%M:%S.SSSZ`, 3 fractional digits via `DateTime.truncate(:millisecond)` + `to_iso8601/1`) — lexicographically sortable in SQLite. `Schema.normalize_timestamps/1` migrates existing rows to this format.
- **Result tuples**: `encode_result/1`/`decode_result/1` round-trip `{:ok, map}`, `{:error, reason}`, `{:exit, reason}` via `__result_tag__` JSON discriminator. Plain strings (crash fallbacks) are ALWAYS JSON-wrapped with a `"string"` tag (`{"__result_tag__":"string","value":<str>}`) so every result value is valid JSON (enables future `json_valid`-guarded `json_extract` SQL filters). `decode_result/1` is STRICTLY canonical: nil + the 4 tagged forms only (`ok` map data, `error`, `exit`, `string` binary); raw strings, untagged JSON (objects/arrays/scalars), invalid JSON, and JSON null raise `ArgumentError` (`"Codec: undecodable result value in DB (missing canonical __result_tag__): ..."`).
- **Usage**: `encode_usage/1`, `decode_usage/1` — `%EvoGit.Agent.Usage{}` ↔ JSON string; `decode_usage_map/1` rebuilds via precomputed `@usage_field_pairs` (string+atom key fallback, zero-allocation).
- **Archive metadata**: `encode_archive_metadata/1`, `decode_archive_metadata/1`
- **Opts/Logs**: JSON via Jason. `encode_opts/1` writes a JSON OBJECT with string keys (`{"path": "...", "mode": "..."}` — JSON-path addressable for future SQL pushdowns); `decode_opts/1` decodes to a keyword list, atomizing known keys via `decode_opt_key/1` (`@known_opt_keys`); non-object JSON (legacy pair-array rows, scalars, JSON null) and invalid JSON raise `ArgumentError` — no legacy decode path. Essential-keys fallback (`[:path, :mode, :prompt, :objective]`) + nil-on-failure.

## Design Principles

1. **TOTAL encode**: Encode functions never raise (all JSON via non-crashing `Jason.encode/1` with `case`/`with`).
2. **Decode raises on bad data**: structurally bad rows raise (incl. non-canonical JSON via `ArgumentError`). Safe-select helpers + summary reads (`select_tasks_summary`, `select_tasks_summary_by_path`, `select_tasks_changed_since`) catch, skip the row, log `Logger.warning`. Inline narrow reads that decode `opts` (e.g. `select_task_update_info`) deliberately do NOT catch — crash loudly so corrupt rows surface; run `mix migrate.store` first.
3. **Atom safety**: closed whitelists with `Map.get/3` for atom conversion from DB-sourced strings.
4. **Result tuple round-tripping**: `{:ok, _}`/`{:error, _}`/`{:exit, _}` survive JSON via `__result_tag__`; plain strings via the `"string"` tag.
5. **One justified `try/rescue`**: `decode_reason/1` (`String.to_existing_atom/1` has no non-crashing variant; unknown reason strings legitimately stay strings).

## Quarantine-free design

No quarantine/integrity subsystem — no `tasks_quarantine`/`projects_quarantine` tables, no `integrity_check`/`scan_and_repair`/`recover_quarantine` functions. SQLite in WAL mode is crash-safe and essentially never corrupts, so a quarantine net is unnecessary.

- No quarantine tables are created (`Schema.create_tables/1`); leftover quarantine tables in live DBs are ignored, never dropped.
- Undecodable rows are SKIPPED + `Logger.warning` (no INSERT-into-quarantine + DELETE-from-live pair).
- The only startup DB check is lease reconciliation — pure SQL (`EvoGit.Store.select_running_lease_info/1` in `TaskRegistry.init/1`, see root CONTEXT.md "Stuck-`:finalizing`-forever bug"). No whole-table integrity scrub at init.

## Schema: `updated_at` column (store-internal bookkeeping)

- `tasks` has a 19th column `updated_at TEXT` (after `branch_name`), written via targeted `update_task_columns` with `Queries.encode_column_value(:updated_at, dt)` → `Codec.encode_datetime/1` (fixed-precision ISO, same as `started_at`/`finished_at`).
- Deliberately NOT in `Codec.@task_columns` nor `%TaskInfo{}` (changed-since poll tracking); positional `encode_task`/`decode_task` and `Queries.task_select_sql/0` never touch it.
- Indexes (idempotent `IF NOT EXISTS`): `idx_tasks_updated_at ON tasks(updated_at)` (backs the changed-since poll query) and `idx_tasks_started_at ON tasks(started_at)` (backs `safe_select_paginated_tasks`'s `ORDER BY started_at DESC`).
- Migration: `Schema.migrate_schema/1` adds it (`ALTER TABLE tasks ADD COLUMN updated_at TEXT` when missing, same pattern as lease_expires_at/model_id/project_path/branch_name clauses); fresh DBs get it from `create_tables/1` DDL directly.

## Canonical result encoding

`encode_result/1` ALWAYS JSON-wraps plain strings (crash fallbacks like `"Task process exited: …"`) with the `__result_tag__` scheme, so every `result` value is valid JSON:

```json
{"__result_tag__":"string","value":"Task process exited: ..."}
```

- Encode: `Jason.encode!/1` of a binary can never fail (TOTAL-encode philosophy).
- Decode: strictly canonical — nil + the 4 tagged forms only (`ok` map data, `error`, `exit`, `string` binary); raw strings, untagged JSON, invalid JSON, JSON null raise `ArgumentError`.
- Enables future `json_valid`-guarded `json_extract` SQL filters. DBs that have NOT run `mix migrate.store` may contain legacy rows — they RAISE on decode; run the migration first (its canonical-result rewrite, step 4: JSON literal `null` text → SQL NULL; raw strings AND untagged JSON objects/arrays/scalars → `"string"`-tag wrap verbatim). Tagged rows are untouched.

## Opts object encoding (JSON-path addressable)

`encode_opts/1` stores a JSON object with string keys:

```json
{"path":"/tmp/repo","mode":"simple","prompt":"..."}
```

- Encode: `Map.new/2` over the keyword list (atom keys → strings), essential-keys fallback + nil-on-failure.
- Decode: `decode_opts/1` rebuilds a keyword list, atomizing known keys via `decode_opt_key/1` (`@known_opt_keys`). Non-object JSON (legacy pair-array rows, scalars, JSON null) and invalid JSON raise `ArgumentError` — no legacy decode path; run the `mix migrate.store` opts-object rewrite before reading old DBs.
- `Queries.build_where/1` `:search` filter (`opts/result LIKE ?N ESCAPE '\'`) matches over the serialized JSON text — `"path"`/`"mode"` key names and string values alike; the `result` column's raw JSON carries the final agent report under its `"result"` data key, matching with the same semantics.

## Store.init does not auto-migrate

`Store.init/1` runs only `create_tables/1`. Schema upgrades for existing DBs go through **`mix migrate.store`** (`apps/evo_git/lib/mix/tasks/migrate.store.ex`): standalone (never starts the `:evo_git` application), opens the DB directly, invokes `Schema.migrate_schema/1` (+ `normalize_timestamps/1`), and rewrites canonical results (step 4) + opts objects (step 5). Fresh DBs are created with the full current DDL by `create_tables/1`.

## Fixed-precision timestamps

- `Codec.encode_datetime/1` → constant 24-char `:millisecond` ISO-8601 (`%Y-%m-%dT%H:%M:%S.SSSZ`, `.000Z` even for whole seconds) via `DateTime.truncate(dt, :millisecond)` + `DateTime.to_iso8601/1`. Lexicographically sortable in SQLite — a mixed-precision `:auto` format would mis-sort (`'Z'` (0x5A) > `'.'` (0x2E)) — making SQL-side datetime filtering/ordering pushdowns safe.
- `Schema.normalize_timestamps/1` migrates existing rows (tasks.started_at / tasks.finished_at / projects.last_opened_at). Idempotent (GLOB guard `'*.[0-9][0-9][0-9]Z'` skips normalized rows; `%f` round-trips them unchanged); skips unparseable rows (`julianday(...) IS NOT NULL` guard — never overwritten with NULL). Invoked only via `mix migrate.store` (step 3) or direct `Schema` calls in tests.

## SQL Access Patterns

- **Only two xqlite entry points**: `XqliteNIF.query/3` (SELECT/PRAGMA) and `XqliteNIF.execute/3` (INSERT/UPDATE/DELETE/DDL). No `Xqlite` module-wrapper helpers (no `q/2`, no `exec/3`). Dep: `{:xqlite, "~> 0.10"}` (`apps/evo_git/mix.exs:35`).
- **All user values parameterized** with `?N` numbered placeholders + params list. The ONLY interpolated identifiers are table names, column lists, PK names — all from closed module-level sets (Codec column lists, hardcoded literals), never user input.
- **No prepared statements** (one-shot prepare+execute via the NIF per call) and **no transactions** (zero `with_transaction|BEGIN|COMMIT|ROLLBACK` matches in `apps/evo_git/lib`; every execute is its own autocommit). WAL mode set at open (`store.ex:340`: `journal_mode: :wal, synchronous: :normal, cache_size: -2000`); `PRAGMA wal_checkpoint(TRUNCATE)` on terminate (`store.ex:346,364-365`).
- **SQLite JSON1 functions — migration task only**: `mix migrate.store` step 4 uses `json_valid`/`json_type`/`json_object`/`json_extract` when the bundled SQLite has JSON1 (bundled 3.53.2), with an Elixir/Jason fallback. Everywhere else JSON handling is Elixir/Jason; `build_where/1` `:search` LIKEs over raw JSON text of the `opts` and `result` columns (the result column's `"result"` data key carries the final agent report text, so response fragments are searchable); `id`/`project_path` LIKE matches are the only other search surfaces — no JSON-path querying.
- **Heavy vs cheap decode**: `decode_task/1` + `decode_result/1` are HEAVY (full struct reconstruction, JSON decode of result/opts/logs/usage/archive); `decode_atom/1`, `decode_datetime/1`, `decode_logs/1`, `decode_archive/1`, `decode_usage/1` are cheap-to-medium scalar decodes that never raise (nil/[] fallbacks). Raise vectors: positional pattern mismatches in `decode_task/1`/`decode_project/1`, `ArgumentError` from `decode_result/1`/`decode_opts/1` on non-canonical JSON — safe-select + summary callers catch, skip, warn. `decode_reason/1` is the only decode-side try/rescue.

## Heavy SELECT handlers offloaded to short-lived Tasks

`select_tasks_summary`, `select_tasks_summary_by_path`, `select_tasks_changed_since`, `select_all_tasks`, `safe_select_all_tasks`, and `safe_select_paginated_tasks` run query AND decode inside a short-lived linked `Task.start` via the shared private `offload/3` helper (spawns the Task, replies via `GenServer.reply/2`, returns `{:noreply, state}` immediately) — large decoded terms never inflate the Store GenServer heap. Cross-process xqlite use is safe (NIF mutex-guarded: `deps/xqlite/native/xqlitenif/src/connection.rs` `with_conn`/`with_conn_mut`, NO owner-process constraint; NIFs `DirtyIo`-scheduled). The link preserves crash-on-raise behavior exactly — including the skip-and-log boundary (`decode_skipping_bad` runs in the Task process) and the `_ -> []` query-failure arms. Caller's 30s `@call_timeout` unchanged (a slow Task = caller timeout). Bodies in `do_*` private helpers (store.ex `do_select_all_tasks`/`do_safe_select_paginated_tasks`/`do_safe_select_all_tasks`/`do_select_tasks_summary*`/`do_select_tasks_changed_since`). **Kept synchronous** (single-row/tiny — a Task spawn would cost more than the decode): `get_task`, `select_task_logs`, `select_task_update_info`, `get_task_status`, `get_project`, all id-only projections (`select_task_paths`, `select_finished_task_ids`, `select_task_ids`, `select_running_lease_info`, `select_cleanup_info/1,/3`), `count_tasks`, `count_projects`, `size`, `select_all_projects`/`safe_select_all_projects` (≤10 rows after trim).

## Disk-Full Handling

**Contract:** disk-full-class write errors — `SQLITE_FULL` (13), `SQLITE_IOERR` (10), `SQLITE_READONLY` (8) — are detected at the write boundary and converted to `{:error, :disk_full}` instead of crashing the Store GenServer. Reads keep working; writes can be retried (a full disk is transient, unlike a corrupt DB). Every other write error keeps the same failure shape: an identical `MatchError` (via `raise MatchError, term: error` to avoid a statically-impossible pattern warning) crashes the GenServer and the supervisor restarts it.

### xqlite error surfacing (deps/xqlite v0.10)

- `XqliteNIF.query/3` and `XqliteNIF.execute/3` RETURN tuples, never raise: Rust `Result<_, XqliteError>` encodes as `{:ok, _} | {:error, reason}` (`deps/xqlite/native/xqlitenif/src/nif.rs:99-115`). `query` → `{:ok, %{columns, rows, num_rows}}`; `execute` → `{:ok, affected_count}`.
- Disk-full-class shapes (`error.rs` `classify_sqlite_error` + `Encoder` impl):
  - `{:error, {:sqlite_failure, code, extended_code, message | nil}}` — generic fallback arm (error.rs:746-750); SQLITE_FULL (13) and SQLITE_IOERR (10) land here (only READONLY/INTERRUPT/BUSY/LOCKED/SCHEMA/AUTH/CONSTRAINT + 4 text-prefix classes are special-cased, error.rs:683-751). `message` is `Option<String>` → binary or nil.
  - `{:error, {:read_only_database, extended_code, message}}` — SQLITE_READONLY (8), classified specially (error.rs:688-691).
- Classifier `EvoGit.Store.Errors.disk_full_error?/1` (public, pure, testable): matches `{:sqlite_failure, code, _, _}` with `code in [8, 10, 13]`, `{:read_only_database, _, _}`, PLUS a message-text fallback — `String.contains?(String.downcase(msg), "database or disk is full")` on the `:sqlite_failure` message — catching the canonical SQLITE_FULL text on unidentifiable codes. NOT reached by trigger RAISEs: SQLite reports them as `SQLITE_CONSTRAINT_TRIGGER` (code 19) → `{:error, {:constraint_violation, :constraint_trigger, %{message: ...}}}` — a shape the classifier deliberately does not match (graceful crash as before, never a misclassification).

### Write boundary

All 8 write handlers (`put_task`, `delete_task`, `delete_tasks`, `clear_tasks`, `update_lease_expires_at`, `update_task_columns`, `put_project`, `delete_project`) route through the private `execute_write(conn, data_dir, sql, params)` helper (store.ex): `{:ok, _}` → `:ok`; disk-full-class → `log_disk_full/2` (Logger.warning including the DB path from `state.data_dir` + a "free disk space" hint) → `{:error, :disk_full}`; anything else → `raise MatchError, term: error`. No try/rescue — a plain `case` on the NIF return (NIFs never raise; the only justified try/rescue is `terminate/2`'s WAL checkpoint).

**Per-function error contract:**

| Function | Success | Disk-full | Other errors |
|---|---|---|---|
| `put_task` | `:ok` | `{:error, :disk_full}` | crash (MatchError) |
| `delete_task` | `:ok` | `{:error, :disk_full}` | crash |
| `delete_tasks` (chunked) | `:ok` | `{:error, :disk_full}` (partial deletion across chunks possible; stops at failing chunk) | crash |
| `clear_tasks` | `:ok` | `{:error, :disk_full}` | crash |
| `update_lease_expires_at` | `:ok` | `{:error, :disk_full}` | crash |
| `update_task_columns` | `:ok` | `{:error, :disk_full}` | crash |
| `put_project` | `:ok` | `{:error, :disk_full}` | crash |
| `delete_project` | `:ok` | `{:error, :disk_full}` | crash |

(`put_task`/`put_project` also return `{:error, :invalid_task_struct}`/`{:error, :invalid_project_struct}` on validation failure.)

### Caller degradation (task_registry.ex + cleanup.ex)

- `start_task` put_task: log + continue — task runs in-memory (unpersisted); the next status write retries persistence.
- `force_kill_task` (`update_task_columns`): in-memory cleanup still runs (task_refs deleted, cancelling marker cleared); returns `{:error, :disk_full}`.
- `cancel_task` pending branch: returns `{:error, :disk_full}` (persisted status stays `:pending`; a retry would work).
- `append_log` / `delete_task` / `set_review_status` / `set_review_metadata` casts + `:heartbeat` (`update_lease_expires_at`): fire-and-forget — swallow + log (log-loss and stale review/lease state acceptable on a full disk).
- `handle_update_status/6` (all terminal-status casts incl. startup reconciliation) and `{:task_updated, id, :finalizing, node}` handler: log; in-memory terminal cleanup still runs (clear marker + delete task_refs).
- `resolve_recheck_task`, `:lease_sweep` (`put_task`): log + continue (sweep still counts the task as changed).
- `clear_finished_tasks` (`delete_tasks`): returns `{:error, :disk_full}` (finished rows remain).
- `add_recent_project` / `remove_recent_project` / `trim_recent_projects`: log + continue, reply `:ok`.
- `Cleanup.cleanup_expired_tasks` (`delete_tasks`): log + continue; the 5-min `:periodic_cleanup` retries.

### Testability

- **No read-only open flag in use**: `Xqlite.open/2` has no `:read_only` option; `Xqlite.open_readonly/1` exists but `Store.init/1` doesn't use it (WAL opts at store.ex:411). Chmod-based triggers are unreliable: chmod 0444 on the DB file after open does NOT block WAL-mode writes (writes go to `-wal`/`-shm`); chmod 555 on the parent DIRECTORY blocks `-wal`/`-shm` creation → READONLY/CANTOPEN — but root bypasses chmod (CI often runs as root; a root-guard is needed).
- **Validated technique — `PRAGMA query_only = ON` on the Store's own connection**: obtain the connection via `:sys.get_state(Store)` (xqlite NIFs are mutex-guarded, so cross-process use is safe) → every subsequent write fails with genuine `{:error, {:read_only_database, 8, ...}}` (SQLITE_READONLY) → `{:error, :disk_full}` at the write boundary; `PRAGMA query_only = OFF` restores writes (retry test). Deterministic, root-proof, CI-safe. The `RAISE(FAIL, 'database or disk is full')` trigger does NOT work — SQLite reports it as `SQLITE_CONSTRAINT_TRIGGER` (19) → classifier doesn't match → MatchError instead of `{:error, :disk_full}`.
- **Tests** — `apps/evo_git/test/evo_git/store_disk_full_test.exs` (module `EvoGit.StoreDiskFullTest`):
  1. Classifier unit tests over synthetic shapes: `{:error, {:sqlite_failure, 13, 13, msg}}` → true, code 10 → true, code 8 → true, `{:read_only_database, 8, msg}` → true, `{:sqlite_failure, 1, 1, "database or disk is full"}` → true (message fallback), `{:ok, _}` → false, `{:sqlite_failure, 19, 19, nil}` → false (constraint class — incl. trigger RAISEs), unknown code + nil message → false.
  2. Integration (via `PRAGMA query_only = ON`): `put_task` → `{:error, :disk_full}`, Store stays alive (`Process.alive?`), subsequent reads (`get_task`/`select_task_ids`) still work, warning logged (`ExUnit.CaptureLog`), retried `put_task` succeeds after `query_only = OFF`.
  3. TaskRegistry degradation: `start_task` doesn't crash the registry (runs in-memory, unpersisted).
  4. Non-disk-full errors still crash: not integration-tested (no seam for a real non-disk-full NIF error — the classifier unit tests cover the mapping; crash path is `raise MatchError` in `execute_write/4`).

## Known Gaps

- **`type` and `review_status` are unindexed** — the "pending" review filter is driven by the indexed `status = 'completed'` predicate. Indexed columns: `status`, `finished_at`, `lease_expires_at`, `project_path`, `updated_at`, `started_at` (`idx_tasks_started_at` makes the paginated list query's hardcoded `ORDER BY started_at DESC LIMIT ?N OFFSET ?M`, store.ex:468-471, O(page) instead of full-scan + sort).
- **Search matches raw JSON text**: the `:search` filter LIKEs against the serialized `opts` and `result` JSON, so hits depend on JSON key/string representation (e.g. underscores escaped) — a search matches only if the JSON text contains the value verbatim. The `result` column's JSON carries the final agent report under its `"result"` data key, making response-text fragments searchable.

## SQLite Optimization Notes

Goal: lower work into SQL instead of Elixir. Already SQL-side: pagination, filters, DISTINCT, status filtering, COUNT (`safe_select_paginated_tasks` store.ex:459-489, `select_finished_task_ids` store.ex:517-529, `select_task_paths` store.ex:500-512), plus lightweight queries avoiding full-struct decode.

1. **Narrow reads in TaskRegistry hot paths**: `append_log` → `select_task_logs/2`; `set_review_status`/`set_review_metadata` → `get_task_status/2`; `handle_update_status/6` → `select_task_update_info/2`; `cancel_task`/`force_kill_task` → `get_task_status/2` — all write back via targeted `update_task_columns`. Remaining full `task_get` decodes: `{:task_updated, id, :finalizing, node}` handler and `{:recheck_task}`/`resolve_recheck_task` (a targeted `update_task_columns` + narrow status read would suffice for the status-flip); `:DOWN`/result-handler diagnostics and lease_sweep detail reads legitimately need full rows.
2. **`select_running_lease_info`**: status filter pushed into SQL — `SELECT id, status, lease_expires_at FROM tasks WHERE status IN ('running','finalizing','cancelling')` (store.ex:678-695); only `decode_atom` per row. `id not in owned_ids` + lease-validity checks stay Elixir-side (in-memory task_refs + wall-clock).
3. **`select_cleanup_info/3`**: both filters in SQL — Q1 age-expired (`finished_at IS NOT NULL AND finished_at < ?cutoff`), Q2 count trim (`finished_at >= ?cutoff ORDER BY finished_at DESC LIMIT -1 OFFSET ?max_tasks`), returning `q1_ids ++ q2_ids` (store.ex:807-829). String comparison safe on the fixed-precision 24-char ISO format. `select_cleanup_info/1` (legacy `%{id, finished_at}` maps) kept for backward compat (tests pin it).
4. **`result` dropped from the summary projection**: `select_tasks_summary`/`_by_path`/`select_tasks_changed_since` decode only the 15-key `@summary_columns` — `result` is never selected/decoded. Consumers only need `branch_name` from result (`show_review_button?` at evo_dash projects_live/assigns.ex), denormalized as a column (codec.ex:85,100-106; store.ex:544-548). `opts` decode remains (sidebar task label reads `opts[:objective]/[:prompt]`). Decode runs on the offloaded Task — no Store GenServer heap churn.
5. **`started_at` indexed** (`idx_tasks_started_at`, schema.ex): paginated query hardcodes `ORDER BY started_at DESC` (store.ex:470); the index makes paging O(page).
6. **`trim_recent_projects`/`list_recent_projects`** (task_registry.ex:216, 1059): full project decode + Elixir sort; table capped at 10 rows so impact is nil. If ever pushed to SQL: SQLite `ORDER BY last_opened_at DESC` puts NULLs LAST (matches the nil-safe Elixir sort); fixed-precision ISO sorts chronologically.
7. **Absent functions**: `Cleanup.cleanup_expired_tasks/2` (pre-loaded variant) and `Lease.set_crash_details/1` do not exist (grep-verified zero callers in lib + test). `Lease.lookup_sched_meta_result/1` is used by `resolve_recheck_task/3` (task_registry.ex).

### Blockers to full SQL-lowering
- **(g5) Single GenServer connection serializes all SQLite I/O** — SQL pushdown reduces bytes/decode/GC but NOT contention; the 30s `@call_timeout` (store.ex:55) exists for NFS-slow disks, where fewer+smaller statements help directly. No transactions anywhere (each execute is autocommit).
- **(g6) No prepared-statement reuse** — `Xqlite.prepare/2`/`step/1` exist in the dep (deps/xqlite/lib/xqlite.ex:983,1009) but only one-shot `XqliteNIF.query/3`/`execute/3` is used. Micro-optimization only; not a blocker for WHERE/LIMIT pushdown.

### Justified vs accidental whole-table reads
- **Justified**: `safe_select_all_tasks` for `list_tasks` dashboard "show all" (API contract, offloaded to Task process); `safe_select_all_projects` (≤10 rows); the remaining `task_get` full decodes in `{:task_updated, id, :finalizing, node}`/`{:recheck_task}`/`:DOWN` diagnostics/lease_sweep detail reads.
- **Avoided via narrow reads + SQL pushdown**: `select_running_lease_info` (status filter in SQL), `select_cleanup_info/3` (age/count filters in SQL), TaskRegistry hot paths (`append_log`/`handle_update_status`/`set_review_*`/`cancel_task`/`force_kill_task` use narrow reads + `update_task_columns`), `delete_tasks` chunked `DELETE ... WHERE id IN (...)` (500/chunk).
- Column order matters — `@task_columns` and `@project_columns` define positional encoding/decoding.
- JSON encoding via Jason; complex fields stored as JSON TEXT in SQLite columns.
- Known-atom whitelists must stay in sync with the application's valid status/review_status/type atoms.
- Crash philosophy: no try/rescue in handle_call/2; only `terminate/2` has a justified try/rescue for graceful connection close. Two deliberate exceptions: (1) disk-full-class write errors → `{:error, :disk_full}` at the `execute_write/4` boundary instead of crashing; (2) the 6 heavy full-decode read handlers run on a short-lived linked Task (crash-on-raise behavior preserved via the link).
