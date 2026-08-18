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

### `EvoGit.Store.Codec` (`codec.ex`)

| Function | Description |
|----------|-------------|
| `task_columns/0` | Returns the ordered list of task table column names |
| `project_columns/0` | Returns the ordered list of project table column names |
| `encode_task/1` | TOTAL encode (never raises) — serializes a `%TaskInfo{}` struct into a list of column values |
| `decode_task/1` | Deserializes a list of column values back into a `%TaskInfo{}` struct. Raises on bad data (callers skip undecodable rows + `Logger.warning`). |
| `encode_project/1` | TOTAL encode for `%RecentProject{}` structs |
| `decode_project/1` | Deserializes column values into `%RecentProject{}` |
| `validate_task/1` | Validates a task list for structural correctness |
| `validate_project/1` | Validates a project list for structural correctness |

### `EvoGit.Store.Schema` (`schema.ex`)

| Function | Description |
|----------|-------------|
| `create_tables/1` | Creates tables (tasks, projects) and indexes |
| `migrate_schema/1` | Idempotent column migration — adds missing columns to existing DBs (incl. `updated_at`); invoked by the `mix migrate.store` task to upgrade existing databases (`Store.init/1` does not auto-migrate) |
| `normalize_timestamps/1` | Idempotent, SQL-only data migration — rewrites existing timestamp rows to the fixed-precision format (see below) |
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
- **Atoms**: `encode_atom/1` (accepts nil/atoms/strings), `decode_atom/1` (uses `String.to_atom/1` guarded by a closed whitelist `@known_atoms` — safe because the set is bounded and application-controlled; `String.to_existing_atom/1` is only used in `decode_reason/1`, the one justified try/rescue)
- **DateTime**: `encode_datetime/1`, `decode_datetime/1` — `encode_datetime/1` emits a **fixed-precision** constant 24-char ISO-8601 format (`%Y-%m-%dT%H:%M:%S.SSSZ`, exactly 3 fractional digits via `DateTime.truncate(:millisecond)` + `to_iso8601/1`), which is lexicographically sortable in SQLite. Legacy variable-precision rows are migrated by `Schema.normalize_timestamps/1`.
- **Result tuples**: `encode_result/1`, `decode_result/1` — round-trips `{:ok, map}`, `{:error, reason}`, `{:exit, reason}` via `__result_tag__` JSON discriminator. **Canonical encoding** (see "Canonical result encoding" below): plain strings (crash fallbacks) are ALWAYS JSON-wrapped with a `"string"` tag (`{"__result_tag__":"string","value":<str>}`) so every result value is valid JSON — enabling future `json_valid`-guarded `json_extract` SQL filters. `decode_result/1` is STRICTLY canonical: nil passthrough + the 4 tagged forms only (`ok` with map data, `error`, `exit`, `string` with binary value); raw strings, untagged JSON, invalid JSON, and JSON null raise `ArgumentError` — legacy rows must be migrated with `mix migrate.store` first.
- **Usage**: `encode_usage/1`, `decode_usage/1` — `%EvoGit.Agent.Usage{}` struct ↔ JSON string (map); `decode_usage_map/1` rebuilds the struct using precomputed `@usage_field_pairs` (string+atom key fallback lookup, zero-allocation)
- **Archive metadata**: `encode_archive_metadata/1`, `decode_archive_metadata/1`
- **Opts/Logs**: JSON encode/decode via Jason. `encode_opts/1` writes a **JSON OBJECT with string keys** (`{"path": "...", "mode": "..."}` — values are JSON-path addressable for future SQL pushdowns); `decode_opts/1` decodes the object into a keyword list (atomizing keys via the `@known_opt_keys` whitelist); non-object JSON (legacy pair-array rows, scalars, invalid JSON) raises `ArgumentError` — there is no legacy decode path. Essential-keys fallback (`[:path, :mode, :prompt, :objective]`) + nil-on-failure semantics unchanged.

## Design Principles

1. **TOTAL encode**: Encode functions never raise. All JSON encoding uses non-crashing `Jason.encode/1` with `case`/`with`.
2. **Decode raises on bad data**: Decode functions raise on structurally bad rows (incl. non-canonical JSON shapes via `ArgumentError` in `decode_result/1`/`decode_opts/1`). The safe-select helpers and the summary reads (`select_tasks_summary`, `select_tasks_summary_by_path`, `select_tasks_changed_since`) catch these, skip the row, and log a `Logger.warning` (no quarantine table — see "Quarantine-free design" below). Inline narrow reads that decode `opts` (e.g. `select_task_update_info`) deliberately do NOT catch — they crash loudly so corrupt rows surface; run `mix migrate.store` first.
3. **Atom safety**: Uses closed whitelists with `Map.get/3` for atom conversion from DB-sourced strings.
4. **Result tuple round-tripping**: `{:ok, %{...}}`, `{:error, _}`, `{:exit, _}` tuples survive JSON encode/decode via the `__result_tag__` discriminator; plain strings survive via the `"string"` tag.
5. **One justified `try/rescue`**: `decode_reason/1` — `String.to_existing_atom/1` has no non-crashing variant; unknown reason strings legitimately stay strings.

## Quarantine-free design (undecodable rows are skipped + logged)

The store has no quarantine/integrity subsystem — no `tasks_quarantine`/`projects_quarantine` tables and no `integrity_check`/`scan_and_repair`/`recover_quarantine` functions. SQLite in WAL mode (`journal_mode: :wal`) is crash-safe and essentially never corrupts, so a quarantine safety net is unnecessary.

**Current semantics:**

- **No quarantine tables are created** (`Schema.create_tables/1`); existing quarantine tables in live DBs are NOT dropped — harmless leftover rows are simply ignored.
- **Undecodable rows are SKIPPED + `Logger.warning`** — decode errors in read paths are caught and logged, with no INSERT-into-quarantine + DELETE-from-live pair.
- **The only startup DB check is lease reconciliation**, done with pure SQL (`EvoGit.Store.select_running_lease_info/1` in `TaskRegistry.init/1` — see root CONTEXT.md "Stuck-`:finalizing`-forever bug"). No whole-table integrity scrub at init.

## Schema: `updated_at` column (store-internal bookkeeping)

- `tasks` has a 19th column `updated_at TEXT` (after `branch_name`), written via targeted `update_task_columns` calls with `Queries.encode_column_value(:updated_at, dt)` → `Codec.encode_datetime/1` (fixed-precision ISO-8601, same as `started_at`/`finished_at`).
- **`updated_at` is deliberately NOT in `Codec.@task_columns`** and NOT in `%TaskInfo{}` — it is store-internal bookkeeping (changed-since poll tracking). Positional `encode_task`/`decode_task` do not include it, so `Queries.task_select_sql/0` never selects it.
- **Indexes** (`Schema.create_tables/1`, idempotent `IF NOT EXISTS`): `idx_tasks_updated_at ON tasks(updated_at)` (backs the changed-since poll query) and `idx_tasks_started_at ON tasks(started_at)` (backs `safe_select_paginated_tasks`'s `ORDER BY started_at DESC`).
- **Migration**: `Schema.migrate_schema/1` includes a clause — `if "updated_at" not in columns do ALTER TABLE tasks ADD COLUMN updated_at TEXT end` (same pattern as the lease_expires_at/model_id/project_path/branch_name clauses). `Store.init/1` does not auto-migrate; existing databases are upgraded by the **`mix migrate.store`** task, which invokes `migrate_schema/1` (fresh DBs get the column from `create_tables/1` DDL directly).

## Canonical result encoding (result column is uniformly valid JSON)

`encode_result/1` ALWAYS JSON-wraps plain strings (crash fallbacks like `"Task process exited: …"`) with the `__result_tag__` discriminator scheme, so every `result` value is valid JSON:

```json
{"__result_tag__":"string","value":"Task process exited: ..."}
```

- Encode: `Jason.encode!/1` of a binary can never fail (per the TOTAL-encode philosophy).
- Decode: `decode_result/1` is STRICTLY canonical — nil passthrough + the 4 tagged forms only (`ok` with map data, `error`, `exit`, `string` with binary value). Raw strings, untagged JSON (objects/arrays/scalars), invalid JSON, and JSON null all raise `ArgumentError`.
- This enables future `json_valid`-guarded `json_extract` SQL filters over the whole column. ⚠️ DBs that have NOT run `mix migrate.store` may still contain legacy rows — they will RAISE on decode, so run the migration first (its canonical-result rewrite, step 4, converts JSON `null` text → SQL NULL and wraps every other untagged value — raw strings AND untagged JSON objects/arrays/scalars — verbatim in a `"string"`-tag).

## Opts object encoding (JSON-path addressable)

`encode_opts/1` stores a JSON **object** with string keys, so values are JSON-path addressable:

```json
{"path":"/tmp/repo","mode":"simple","prompt":"..."}
```

- Encode: `Map.new/2` over the keyword list (atom keys → strings), keeping the essential-keys fallback (`[:path, :mode, :prompt, :objective]`) and nil-on-failure semantics.
- Decode: `decode_opts/1` decodes the object and rebuilds a keyword list, atomizing known keys via the `decode_opt_key/1` whitelist (`@known_opt_keys`). Non-object JSON (legacy pair-array rows, scalars, JSON null) and invalid JSON raise `ArgumentError` — there is no legacy decode path; the `mix migrate.store` opts-object rewrite must run before reading old DBs.
- The `:search` filter in `Queries.build_where/1` (`opts LIKE ?N ESCAPE '\'`) matches over the serialized JSON text — `"path"` / `"mode"` key names and string values alike.

## Strict canonical decode (no legacy branches)

`decode_result/1` and `decode_opts/1` are strictly canonical — legacy shapes do not decode:

- `decode_result/1`: nil passthrough; only the 4 tagged forms (`ok` with map data, `error`, `exit`, `string` with binary value). Raw strings, untagged JSON (objects/arrays/scalars), invalid JSON, and JSON null all raise `ArgumentError` (`"Codec: undecodable result value in DB (missing canonical __result_tag__): ..."`).
- `decode_opts/1`: nil passthrough; only JSON objects decode to a keyword list (known keys atomized via `decode_opt_key/1`). Non-object JSON (legacy pair-array rows, scalars, JSON null) and invalid JSON raise `ArgumentError`.

**Skip-and-log boundary**: the safe-select helpers (`safe_select_all_tasks`, `safe_select_all_projects`, `safe_select_paginated_tasks`) and the summary reads (`select_tasks_summary`, `select_tasks_summary_by_path`, `select_tasks_changed_since`) catch these raises, skip the row, and log a `Logger.warning`. Inline narrow reads that decode `opts` (e.g. `select_task_update_info`) do NOT catch — a corrupt row crashes loudly, signalling that `mix migrate.store` must be run first.

## Store.init does not auto-migrate

`EvoGit.Store.init/1` does not call `migrate_schema/1`. Schema upgrades for existing databases go through the **`mix migrate.store`** Mix task (`apps/evo_git/lib/mix/tasks/migrate.store.ex`), which opens the DB directly and invokes `Schema.migrate_schema/1` (+ `normalize_timestamps/1` where applicable). The task is **standalone — it never starts the `:evo_git` application**, so it can safely rewrite rows without booting the OTP runtime. Its canonical-result rewrite (step 4) converts legacy result rows: 4a JSON literal `null` text → SQL NULL, 4b raw strings AND untagged JSON (objects/arrays/scalars) → `"string"`-tag wrap (content preserved verbatim as the string value). Tagged rows are untouched. Fresh databases are created with the full current DDL by `create_tables/1`.

## Fixed-precision timestamps (normalize_timestamps + encode_datetime)

- `Codec.encode_datetime/1` emits a **constant 24-char `:millisecond` ISO-8601 format** (`%Y-%m-%dT%H:%M:%S.SSSZ`, exactly 3 fractional digits — `.000Z` even for whole seconds) via `DateTime.truncate(dt, :millisecond)` + `DateTime.to_iso8601/1`. This format is **lexicographically sortable** in SQLite — a mixed-precision `:auto` format would mis-sort (`'Z'` (0x5A) > `'.'` (0x2E)) — which is what makes SQL-side datetime filtering/ordering pushdowns safe.
- `Schema.normalize_timestamps/1` migrates **existing** DB rows (tasks.started_at / tasks.finished_at / projects.last_opened_at) to the same format. It is idempotent (GLOB guard `'*.[0-9][0-9][0-9]Z'` skips already-normalized rows; `%f` round-trips them unchanged) and skips unparseable rows (`julianday(...) IS NOT NULL` guard — never overwritten with NULL). It is invoked only via the `mix migrate.store` task (step 3) or direct `Schema` calls in tests.

## SQL Access Patterns (whole repo search)

- **Only two xqlite entry points**: `XqliteNIF.query/3` (SELECT/PRAGMA) and `XqliteNIF.execute/3` (INSERT/UPDATE/DELETE/DDL). No `Xqlite` module-wrapper helpers (no `q/2`, no `exec/3`). Dep: `{:xqlite, "~> 0.10"}` (`apps/evo_git/mix.exs:35`).
- **All user values are parameterized** with `?N` numbered placeholders + params list. The ONLY interpolated identifiers are table names (`#{table}`), column lists, and PK names — all from closed module-level sets (Codec column lists, hardcoded literals), never user input.
- **No prepared statements**: every call is a one-shot prepare+execute via the NIF; no statement caching/reuse.
- **No transactions**: zero matches for `with_transaction|BEGIN|COMMIT|ROLLBACK` anywhere in `apps/evo_git/lib` (only git-related COMMIT matches). Every `XqliteNIF.execute` is its own autocommit. SQLite WAL mode set at open (`store.ex:340`: `journal_mode: :wal, synchronous: :normal, cache_size: -2000`); `PRAGMA wal_checkpoint(TRUNCATE)` on terminate (`store.ex:346,364-365`).
- **SQLite JSON1 functions — used only by the migration task**: `mix migrate.store` step 4 uses `json_valid`/`json_type`/`json_object`/`json_extract` when the bundled SQLite has JSON1 (verified available at runtime — bundled SQLite 3.53.2), with an Elixir/Jason fallback for hosts without it. Everywhere else (all of `Codec` and the Store), JSON handling is in Elixir via Jason. Consequently: `Queries.build_where/1`'s `:search` filter does `opts LIKE ?N ESCAPE '\'` over the RAW JSON TEXT of the opts column (substring match on the serialized JSON), and the `id`/`project_path` LIKE matches are the only other search surfaces — no JSON-path querying exists.
- **Heavy vs cheap decode**: `decode_task/1` + `decode_result/1` are HEAVY (full struct reconstruction, JSON decode of result/opts/logs/usage/archive); `decode_atom/1`, `decode_datetime/1`, `decode_logs/1`, `decode_archive/1`, `decode_usage/1` are cheap-to-medium scalar decodes that never raise (nil/[] fallbacks). Raise vectors: positional pattern mismatches (row shape/arity) in `decode_task/1`/`decode_project/1`, plus `ArgumentError` from `decode_result/1`/`decode_opts/1` on non-canonical JSON (see "Strict canonical decode") — safe-select and summary callers catch these, skip, and warn. `decode_reason/1` is the only decode-side try/rescue (String.to_existing_atom → ArgumentError → keep string).

## Heavy SELECT handlers offloaded to short-lived Tasks

`select_tasks_summary`, `select_tasks_summary_by_path`, `select_tasks_changed_since`, `select_all_tasks`, `safe_select_all_tasks`, and `safe_select_paginated_tasks` run the query AND the decode inside a short-lived linked `Task.start` that replies via `GenServer.reply/2` (`{:noreply, state}` immediately), so large decoded terms never inflate the Store GenServer heap. Cross-process xqlite use is safe — the connection resource is mutex-guarded inside the NIF (`deps/xqlite/native/xqlitenif/src/connection.rs`, `with_conn`/`with_conn_mut`) with NO owner-process constraint, and NIFs are `DirtyIo`-scheduled. The Task is LINKED to the Store: a decode raise (e.g. the `{:ok, %{rows: rows}}` bad match in `do_select_all_tasks`) still crashes the GenServer exactly like an inline handler — including the skip-and-log boundary (`decode_skipping_bad` runs in the Task process) and the `_ -> []` query-failure arms. The caller's 30s `@call_timeout` is unchanged (a slow Task = caller timeout). Bodies live in `do_*` private helpers (store.ex ~`do_select_all_tasks`/`do_safe_select_paginated_tasks`/`do_safe_select_all_tasks`/`do_select_tasks_summary*`/`do_select_tasks_changed_since`). **Deliberately kept synchronous** (single-row or tiny): `get_task`, `select_task_logs`, `select_task_update_info`, `get_task_status`, `get_project` (single row, no bloat), all id-only projections (`select_task_paths`, `select_finished_task_ids`, `select_task_ids`, `select_running_lease_info`, `select_cleanup_info/1,/3`), `count_tasks`, `count_projects`, `size`, and `select_all_projects`/`safe_select_all_projects` (≤10 rows after trim) — a Task spawn would cost more than the decode.

## Disk-Full Handling

**Contract:** SQLite's disk-full error class on write paths — `SQLITE_FULL` (13), `SQLITE_IOERR` (10), `SQLITE_READONLY` (8) — is detected at the write boundary and converted to `{:error, :disk_full}` instead of crashing the Store GenServer. Reads keep working; subsequent writes can be retried (a full disk is transient, unlike a corrupt DB). Every other write error keeps the same failure shape: an identical `MatchError` (constructed via `raise MatchError, term: error` to avoid a statically-impossible pattern warning) crashes the GenServer and the supervisor restarts it.

### xqlite error surfacing (verified in deps/xqlite, v0.10)

- `XqliteNIF.query/3` and `XqliteNIF.execute/3` **RETURN tuples, never raise**: Rust `Result<_, XqliteError>` encodes as `{:ok, _} | {:error, reason}` (`deps/xqlite/native/xqlitenif/src/nif.rs:99-115`). `query` → `{:ok, %{columns, rows, num_rows}}`; `execute` → `{:ok, affected_count}`.
- Exact disk-full-class shapes (`error.rs` `classify_sqlite_error` + `Encoder` impl):
  - `{:error, {:sqlite_failure, code, extended_code, message | nil}}` — generic fallback arm (error.rs:746-750, encode :664); **SQLITE_FULL (13) and SQLITE_IOERR (10) land here** (only READONLY/INTERRUPT/BUSY/LOCKED/SCHEMA/AUTH/CONSTRAINT + 4 text-prefix classes are special-cased, error.rs:683-751). `message` is `Option<String>` → binary or nil.
  - `{:error, {:read_only_database, extended_code, message}}` — SQLITE_READONLY (8), classified specially (error.rs:688-691, encode :501-504).
- Classifier: `EvoGit.Store.Errors.disk_full_error?/1` (public, pure — testable). Matches `{:sqlite_failure, code, _, _}` with `code in [8, 10, 13]`, `{:read_only_database, _, _}`, PLUS a message-text fallback — `String.contains?(String.downcase(msg), "database or disk is full")` on the `:sqlite_failure` message — catching the canonical SQLITE_FULL text on unidentifiable codes. NOT reachable by trigger RAISEs: SQLite reports them as `SQLITE_CONSTRAINT_TRIGGER` (code 19), which xqlite classifies as `{:error, {:constraint_violation, :constraint_trigger, %{message: ...}}}` — a shape the classifier deliberately does not match. Message reword/localization downgrades to `false` (graceful — crash as before), never a misclassification.

### Write boundary

All 8 write handlers (`put_task`, `delete_task`, `delete_tasks`, `clear_tasks`, `update_lease_expires_at`, `update_task_columns`, `put_project`, `delete_project`) route through the private `execute_write(conn, data_dir, sql, params)` helper (store.ex): `{:ok, _}` → `:ok`; disk-full-class → `log_disk_full/2` (Logger.warning including the DB path from `state.data_dir` + a "free disk space" hint) → `{:error, :disk_full}`; anything else → `raise MatchError, term: error`. No try/rescue anywhere — the boundary is a plain `case` on the NIF return (the NIFs never raise; the only justified try/rescue is `terminate/2`'s WAL checkpoint).

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

- **`start_task` put_task**: log + continue — the task runs in-memory (unpersisted); the next status write retries persistence.
- **`force_kill_task`** (`update_task_columns`): in-memory cleanup still runs (task_refs deleted, cancelling marker cleared); returns `{:error, :disk_full}`.
- **`cancel_task`** pending branch: returns `{:error, :disk_full}` (persisted status stays `:pending`; a retry would work).
- **`append_log` / `delete_task` / `set_review_status` / `set_review_metadata` casts** + **`:heartbeat`** (`update_lease_expires_at`): fire-and-forget — swallow + log (log-loss and stale review/lease state are acceptable degradations on a full disk).
- **`handle_update_status/6`** (all terminal-status casts incl. startup reconciliation) and **`{:task_updated, id, :finalizing, node}`** handler: log; in-memory terminal cleanup still runs (clear marker + delete task_refs).
- **`resolve_recheck_task`**, **`:lease_sweep`** (`put_task`): log + continue (sweep still counts the task as changed).
- **`clear_finished_tasks`** (`delete_tasks`): returns `{:error, :disk_full}` (finished rows remain).
- **`add_recent_project` / `remove_recent_project` / `trim_recent_projects`**: log + continue, reply `:ok`.
- **`Cleanup.cleanup_expired_tasks`** (`delete_tasks`): log + continue; the 5-min `:periodic_cleanup` retries.

### Testability findings

- **No read-only open flag in use**: `Xqlite.open/2` has no `:read_only` option; `Xqlite.open_readonly/1` exists but `Store.init/1` doesn't use it (`journal_mode: :wal, synchronous: :normal, cache_size: -2000` at store.ex:411). Chmod-based triggers are unreliable: chmod 0444 on the DB file after open does NOT block WAL-mode writes (writes go to `-wal`/`-shm`); chmod 555 on the parent DIRECTORY blocks `-wal`/`-shm` creation → READONLY/CANTOPEN — but **root bypasses chmod** (CI often runs as root; a root-guard is needed).
- **Validated test technique — `PRAGMA query_only = ON` on the Store's own connection**: obtain the connection via `:sys.get_state(Store)` (xqlite NIFs are mutex-guarded, so cross-process use is safe) and run `PRAGMA query_only = ON` — every subsequent write fails with genuine `{:error, {:read_only_database, 8, ...}}` (SQLITE_READONLY, a real classified code) → `{:error, :disk_full}` at the write boundary; `PRAGMA query_only = OFF` restores writes (retry test). Deterministic, root-proof, and CI-safe. Why not the alternatives: chmod is unreliable (0444 on the DB file does NOT block WAL-mode writes through the already-open fd; 555 on the parent directory is bypassed by root), and the `RAISE(FAIL, 'database or disk is full')` trigger does NOT work — SQLite reports trigger RAISEs as `SQLITE_CONSTRAINT_TRIGGER` (primary code 19), which xqlite classifies as `{:error, {:constraint_violation, :constraint_trigger, %{message: ...}}}`; the classifier deliberately does not match that shape, so the write crashes with the MatchError instead of `{:error, :disk_full}` (see `test/evo_git/store_disk_full_test.exs`, module `EvoGit.StoreDiskFullTest`).
- **Test coverage** — `apps/evo_git/test/evo_git/store_disk_full_test.exs` (module `EvoGit.StoreDiskFullTest`):
  1. Pure classifier unit tests — feed synthetic shapes to the PUBLIC `EvoGit.Store.Errors.disk_full_error?/1`: `{:error, {:sqlite_failure, 13, 13, msg}}` → true, code 10 → true, code 8 → true, `{:error, {:read_only_database, 8, msg}}` → true, `{:error, {:sqlite_failure, 1, 1, "database or disk is full"}}` → true (message fallback), `{:ok, _}` → false, `{:error, {:sqlite_failure, 19, 19, nil}}` → false (constraint class — incl. trigger RAISEs), unknown code with nil message → false.
  2. Integration (armed via `PRAGMA query_only = ON` on the Store's own connection — the validated technique above): `EvoGit.Store.put_task` returns `{:error, :disk_full}`, the Store process stays alive (`Process.alive?`), a subsequent read (`get_task`/`select_task_ids`) still works, a disk-full warning was logged (`ExUnit.CaptureLog`), and a retried `put_task` succeeds after `query_only = OFF`.
  3. TaskRegistry degradation: with query_only armed, `TaskRegistry.start_task` does not crash the registry (task runs in-memory, unpersisted).
  4. Non-disk-full errors still crash: not integration-tested (no seam to produce a real non-disk-full NIF error — the classifier unit tests cover the mapping; the crash path is `raise MatchError` in `execute_write/4`, unreachable without a real non-disk-full NIF error).

## Known Gaps

- **`type` and `review_status` are unindexed** — the "pending" review filter is driven by the indexed `status = 'completed'` predicate. Indexed columns: `status`, `finished_at`, `lease_expires_at`, `project_path`, `updated_at`, `started_at` (`idx_tasks_started_at` makes the paginated list query's hardcoded `ORDER BY started_at DESC LIMIT ?N OFFSET ?M`, `store.ex:468-471`, O(page) instead of full-scan + sort).
- **Search matches raw JSON text**: the `:search` filter LIKEs against the serialized `opts` JSON, so hits depend on JSON key/string representation (e.g. underscores escaped) — a search for a value stored in `opts` matches only if the JSON text contains it verbatim.

## SQLite Optimization Analysis

Goal context: lower work into SQL instead of Elixir. Much of this is already SQL-side — pagination, filters, DISTINCT, status filtering, and COUNT (`safe_select_paginated_tasks` store.ex:459-489, `select_finished_task_ids` store.ex:517-529, `select_task_paths` store.ex:500-512) — and several lightweight query functions avoid full-struct decode. Current state and remaining opportunities, by area:

1. **Narrow reads in TaskRegistry hot paths.** `append_log` uses `select_task_logs/2` (logs column only), `set_review_status`/`set_review_metadata` use `get_task_status/2` (status column only), `handle_update_status/6` uses `select_task_update_info/2` (status + opts + finished_at + lease_expires_at), and `cancel_task`/`force_kill_task` use `get_task_status/2` — all write back via targeted `update_task_columns` instead of full `task_get` decode + `put_task` re-encode. Remaining full `task_get` decodes: the `{:task_updated, id, :finalizing, node}` handler and `{:recheck_task}`/`resolve_recheck_task` still read-modify-write via `task_get` (a targeted `update_task_columns` + narrow status read would suffice for the status-flip case); the `:DOWN`/result-handler diagnostics and lease_sweep detail reads legitimately need full rows.
2. **`select_running_lease_info`** — status filter pushed into SQL: `SELECT id, status, lease_expires_at FROM tasks WHERE status IN ('running','finalizing','cancelling')` (store.ex:678-695); only `decode_atom` runs per row. `id not in owned_ids` and lease-validity checks stay Elixir-side (in-memory task_refs + wall-clock).
3. **`select_cleanup_info/3`** — both filters in SQL: Q1 age-expired (`finished_at IS NOT NULL AND finished_at < ?cutoff`), Q2 count trim (`finished_at >= ?cutoff ORDER BY finished_at DESC LIMIT -1 OFFSET ?max_tasks`), returning `q1_ids ++ q2_ids` (store.ex:807-829). String comparison is safe on the fixed-precision 24-char ISO format. `select_cleanup_info/1` (legacy `%{id, finished_at}` maps) is kept for backward compat (tests pin it).
4. **`result` dropped from the summary projection.** `select_tasks_summary`/`select_tasks_summary_by_path`/`select_tasks_changed_since` decode only the 15-key `@summary_columns` projection — `result` is deliberately not selected/decoded. Consumers only need `branch_name` from result (`show_review_button?` at evo_dash projects_live/assigns.ex), and `branch_name` is a denormalized column (codec.ex:85,100-106; store.ex:544-548). `opts` decode remains (sidebar task label reads `opts[:objective]/[:prompt]`). The decode runs on the offloaded Task (see "Heavy SELECT handlers offloaded to short-lived Tasks"), so no Store GenServer heap churn.
5. **`started_at` indexed** (`idx_tasks_started_at`, schema.ex). The paginated query hardcodes `ORDER BY started_at DESC` (store.ex:470); the index makes paging O(page). No behavior change.
6. **`trim_recent_projects`/`list_recent_projects` (task_registry.ex:216, 1059)** — full project decode + Elixir sort; the table is capped at 10 rows so impact is nil. If ever pushed to SQL, note SQLite `ORDER BY last_opened_at DESC` puts NULLs LAST (matches the nil-safe Elixir sort); the fixed-precision ISO format sorts chronologically.
7. **Absent functions.** `Cleanup.cleanup_expired_tasks/2` (pre-loaded variant) and `Lease.set_crash_details/1` do not exist (grep-verified zero callers in lib + test). `Lease.lookup_sched_meta_result/1` is used by `resolve_recheck_task/3` (task_registry.ex).

### Blockers specific to full SQL-lowering
- **(g5) Single GenServer connection serializes all SQLite I/O** — SQL pushdown reduces bytes/decode/GC but NOT contention; the 30s `@call_timeout` (store.ex:55) exists for NFS-slow disks, where fewer+smaller statements help directly. No transactions anywhere (each execute is autocommit).
- **(g6) No prepared-statement reuse** — `Xqlite.prepare/2`/`step/1` exist in the dep (deps/xqlite/lib/xqlite.ex:983,1009) but the code uses only one-shot `XqliteNIF.query/3`/`execute/3`. Micro-optimization only; not a blocker for WHERE/LIMIT pushdown.

### Justified vs accidental whole-table reads
- **Justified:** `safe_select_all_tasks` for `list_tasks` dashboard "show all" (API contract, offloaded to Task process); `safe_select_all_projects` (≤10 rows); the remaining `task_get` full decodes in `{:task_updated, id, :finalizing, node}`/`{:recheck_task}`/`:DOWN` diagnostics/lease_sweep detail reads.
- **Avoided via narrow reads + SQL pushdown:** `select_running_lease_info` (status filter in SQL), `select_cleanup_info/3` (age/count filters in SQL), TaskRegistry hot paths (`append_log`/`handle_update_status`/`set_review_*`/`cancel_task`/`force_kill_task` use narrow reads + `update_task_columns`), `delete_tasks` chunked `DELETE ... WHERE id IN (...)` (500/chunk).
- Column order matters — `@task_columns` and `@project_columns` define positional encoding/decoding.
- JSON encoding via Jason; complex fields stored as JSON TEXT in SQLite columns.
- Known-atom whitelists must stay in sync with the application's valid status/review_status/type atoms.
- The main `EvoGit.Store` GenServer follows the crash philosophy: no try/rescue in handle_call/2; only `terminate/2` has a justified try/rescue for graceful connection close. Two deliberate exceptions (see "Disk-Full Handling" and "Heavy SELECT handlers offloaded to short-lived Tasks" above): (1) disk-full-class write errors are converted to `{:error, :disk_full}` at the `execute_write/4` boundary instead of crashing; (2) the 6 heavy full-decode read handlers run on a short-lived linked Task (crash-on-raise behavior preserved via the link).
