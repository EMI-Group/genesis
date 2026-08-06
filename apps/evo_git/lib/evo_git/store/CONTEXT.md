# EvoGit.Store — SQLite Persistence Layer

## Intent

Contains the `EvoGit.Store` GenServer and its support modules for the SQLite persistence layer. The main store module (`store.ex`) was migrated from `evo_dash` (formerly `EvoDash.Store`) to `evo_git` as part of the domain persistence layer migration, and was later split into focused sub-modules.

## Routing Table

- `../store.ex` → Main GenServer module (`EvoGit.Store`) — public API, GenServer callbacks, private helpers
- `./codec.ex` → `EvoGit.Store.Codec` — pure serialization/deserialization functions (no I/O)
- `./schema.ex` → `EvoGit.Store.Schema` — table creation, idempotent column migration, timestamp normalization
- `./queries.ex` → `EvoGit.Store.Queries` — SQL builder helpers (WHERE, SET, clamping, column encoding)

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
| `migrate_schema/1` | Idempotent column migration — adds missing columns to existing DBs (incl. `updated_at`); invoked by the `mix migrate.store` task to upgrade OLD databases since `Store.init/1` no longer auto-migrates |
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
- **Opts/Logs**: JSON encode/decode via Jason. `encode_opts/1` writes a **JSON OBJECT with string keys** (`{"path": "...", "mode": "..."}` — values are JSON-path addressable for future SQL pushdowns); `decode_opts/1` decodes the object into a keyword list (atomizing keys via the `@known_opt_keys` whitelist); non-object JSON (legacy pair-array rows, scalars, invalid JSON) raises `ArgumentError` — no legacy decode path remains. Essential-keys fallback (`[:path, :mode, :prompt, :objective]`) + nil-on-failure semantics unchanged.

## Design Principles

1. **TOTAL encode**: Encode functions never raise. All JSON encoding uses non-crashing `Jason.encode/1` with `case`/`with`.
2. **Decode raises on bad data**: Decode functions raise on structurally bad rows (incl. non-canonical JSON shapes via `ArgumentError` in `decode_result/1`/`decode_opts/1`). The safe-select helpers and the summary reads (`select_tasks_summary`, `select_tasks_summary_by_path`, `select_tasks_changed_since`) catch these, skip the row, and log a `Logger.warning` (no quarantine table — see "Removal: quarantine/integrity machinery" below). Inline narrow reads that decode `opts` (e.g. `select_task_update_info`) deliberately do NOT catch — they crash loudly so corrupt rows surface; run `mix migrate.store` first.
3. **Atom safety**: Uses closed whitelists with `Map.get/3` for atom conversion from DB-sourced strings.
4. **Result tuple round-tripping**: `{:ok, %{...}}`, `{:error, _}`, `{:exit, _}` tuples survive JSON encode/decode via the `__result_tag__` discriminator; plain strings survive via the `"string"` tag (new code) or verbatim raw-string branch (legacy rows).
5. **One justified `try/rescue`**: `decode_reason/1` — `String.to_existing_atom/1` has no non-crashing variant; unknown reason strings legitimately stay strings.

## Removal: quarantine/integrity machinery (decision + rationale)

The quarantine/integrity subsystem (`EvoGit.Store.Quarantine` — `tasks_quarantine`/`projects_quarantine` tables, `integrity_check`, `scan_and_repair`, `recover_quarantine`) has been **removed**. It was legacy from the DETS era of the store:

- `d6bc9cce` "Refactor TaskRegistry from ETS+DETS to DETS-only" introduced it; `de50b599`/`8ce9c763`/`eba7820e` ("harden DETS against data-loss risks") built it up — it existed to rescue rows from a DETS file that could corrupt on unclean shutdown.
- The DETS-era store was superseded by the SQLite Store (`bdbacde2`). SQLite in WAL mode (`journal_mode: :wal`) is crash-safe and essentially never corrupts, so the whole quarantine safety net is obsolete machinery.

**New semantics:**

- **No quarantine tables are created** (DDL removed from `Schema.create_tables/1`; existing quarantine tables in live DBs are NOT dropped — harmless leftover rows are simply ignored).
- **Undecodable rows are SKIPPED + `Logger.warning`** — decode errors in read paths are caught and logged, with no INSERT-into-quarantine + DELETE-from-live pair.
- **The only startup DB check kept is lease reconciliation**, done with pure SQL (`EvoGit.Store.select_running_lease_info/1` in `TaskRegistry.init/1` — see root CONTEXT.md "Stuck-`:finalizing`-forever bug"). No whole-table integrity scrub at init.

## Schema: `updated_at` column (store-internal bookkeeping)

- `tasks` gains a 19th column `updated_at TEXT` (after `branch_name`), written via targeted `update_task_columns` calls with `Queries.encode_column_value(:updated_at, dt)` → `Codec.encode_datetime/1` (fixed-precision ISO-8601, same as `started_at`/`finished_at`).
- **`updated_at` is deliberately NOT in `Codec.@task_columns`** and NOT in `%TaskInfo{}` — it is store-internal bookkeeping (changed-since poll tracking). Positional `encode_task`/`decode_task` are untouched; `Queries.task_select_sql/0` therefore never selects it.
- **New indexes** (`Schema.create_tables/1`, idempotent `IF NOT EXISTS`): `idx_tasks_updated_at ON tasks(updated_at)` (backs the changed-since poll query) and `idx_tasks_started_at ON tasks(started_at)` (backs `safe_select_paginated_tasks`'s `ORDER BY started_at DESC` — closes the old "started_at unindexed" gap, see Known Gaps).
- **Migration**: `Schema.migrate_schema/1` has a new clause — `if "updated_at" not in columns do ALTER TABLE tasks ADD COLUMN updated_at TEXT end` (same pattern as the lease_expires_at/model_id/project_path/branch_name clauses). Since `Store.init/1` **no longer auto-migrates** (see parent workstream), old databases are upgraded by the new **`mix migrate.store`** task, which invokes `migrate_schema/1` (fresh DBs get the column from `create_tables/1` DDL directly).

## Canonical result encoding (result column is uniformly valid JSON)

`encode_result/1` used to store plain strings (crash fallbacks like `"Task process exited: …"`) verbatim, making the `result` column a mix of JSON and raw non-JSON strings (blocker g2). **Now**: plain strings are ALWAYS JSON-wrapped with the existing `__result_tag__` discriminator scheme:

```json
{"__result_tag__":"string","value":"Task process exited: ..."}
```

- Encode: `Jason.encode!/1` of a binary can never fail (TOTAL-encode philosophy preserved).
- Decode: `decode_result/1` is STRICTLY canonical — nil passthrough + the 4 tagged forms only (`ok` with map data, `error`, `exit`, `string` with binary value). Raw strings, untagged JSON (objects/arrays/scalars), invalid JSON, and JSON null all raise `ArgumentError`.
- This enables future `json_valid`-guarded `json_extract` SQL filters over the whole column. ⚠️ DBs that have NOT run `mix migrate.store` may still contain legacy rows — they will RAISE on decode, so run the migration first (its canonical-result rewrite, step 4, converts JSON `null` text → SQL NULL and wraps every other untagged value — raw strings AND untagged JSON objects/arrays/scalars — verbatim in a `"string"`-tag).

## Opts object encoding (JSON-path addressable)

`encode_opts/1` used to store a positional JSON **array** of `[key_string, value]` pairs, which made JSON-path key lookup fragile (blocker g3). **Now**: a JSON **object** with string keys:

```json
{"path":"/tmp/repo","mode":"simple","prompt":"..."}
```

- Encode: `Map.new/2` over the keyword list (atom keys → strings), keeping the existing essential-keys fallback (`[:path, :mode, :prompt, :objective]`) and nil-on-failure semantics.
- Decode: `decode_opts/1` decodes the object and rebuilds a keyword list, atomizing known keys via the existing `decode_opt_key/1` whitelist (`@known_opt_keys`). Non-object JSON (legacy pair-array rows, scalars, JSON null) and invalid JSON raise `ArgumentError` — no legacy decode path remains; the `mix migrate.store` opts-object rewrite must run before reading old DBs.
- `Queries.build_where/1`'s `:search` filter (`opts LIKE ?N ESCAPE '\'`) is UNAFFECTED: values remain JSON text, so substring matches over the serialized JSON still work (matches `"path"` / `"mode"` key names and string values alike).

## Strict canonical decode (no legacy branches)

`decode_result/1` and `decode_opts/1` are strictly canonical — legacy shapes no longer decode:

- `decode_result/1`: nil passthrough; only the 4 tagged forms (`ok` with map data, `error`, `exit`, `string` with binary value). Raw strings, untagged JSON (objects/arrays/scalars), invalid JSON, and JSON null all raise `ArgumentError` (`"Codec: undecodable result value in DB (missing canonical __result_tag__): ..."`).
- `decode_opts/1`: nil passthrough; only JSON objects decode to a keyword list (known keys atomized via `decode_opt_key/1`). Non-object JSON (legacy pair-array rows, scalars, JSON null) and invalid JSON raise `ArgumentError`.

**Skip-and-log boundary**: the safe-select helpers (`safe_select_all_tasks`, `safe_select_all_projects`, `safe_select_paginated_tasks`) and the summary reads (`select_tasks_summary`, `select_tasks_summary_by_path`, `select_tasks_changed_since`) catch these raises, skip the row, and log a `Logger.warning`. Inline narrow reads that decode `opts` (e.g. `select_task_update_info`) do NOT catch — a corrupt row crashes loudly, signalling that `mix migrate.store` must be run first.

## Store.init no longer auto-migrates

`EvoGit.Store.init/1` no longer calls `migrate_schema/1` (see parent workstream — `store.ex`). Schema upgrades for existing databases go through the new **`mix migrate.store`** Mix task (`apps/evo_git/lib/mix/tasks/migrate.store.ex`), which opens the DB directly and invokes `Schema.migrate_schema/1` (+ `normalize_timestamps/1` where applicable). The task is **standalone — it never starts the `:evo_git` application**, so it can safely rewrite rows without booting the OTP runtime. Its canonical-result rewrite (step 4) converts legacy result rows: 4a JSON literal `null` text → SQL NULL, 4b raw strings AND untagged JSON (objects/arrays/scalars) → `"string"`-tag wrap (content preserved verbatim as the string value). Tagged rows are untouched. Fresh databases are created with the full current DDL by `create_tables/1`.

## Fixed-precision timestamps (normalize_timestamps + encode_datetime)

- `Codec.encode_datetime/1` now emits a **constant 24-char `:millisecond` ISO-8601 format** (`%Y-%m-%dT%H:%M:%S.SSSZ`, exactly 3 fractional digits — `.000Z` even for whole seconds) via `DateTime.truncate(dt, :millisecond)` + `DateTime.to_iso8601/1`. This format is **lexicographically sortable** in SQLite, fixing the mixed-precision `:auto` mis-sort (`'Z'` (0x5A) > `'.'` (0x2E)) that broke `ORDER BY started_at DESC` and blocked SQL-side datetime pushdowns (g1).
- `Schema.normalize_timestamps/1` migrates **existing** DB rows (tasks.started_at / tasks.finished_at / projects.last_opened_at) to the same format. It is idempotent (GLOB guard `'*.[0-9][0-9][0-9]Z'` skips already-normalized rows; `%f` round-trips them unchanged) and skips unparseable rows (`julianday(...) IS NOT NULL` guard — never overwritten with NULL). A caller in `Store.init/1` used to invoke it after `migrate_schema/1`; since the no-auto-migration change it runs only via the one-time `mix migrate.store` task (step 3) or direct `Schema` calls in tests.

## SQL Access Patterns (verified 2025 — whole repo search)

- **Only two xqlite entry points**: `XqliteNIF.query/3` (SELECT/PRAGMA) and `XqliteNIF.execute/3` (INSERT/UPDATE/DELETE/DDL). No `Xqlite` module-wrapper helpers (no `q/2`, no `exec/3`). Dep: `{:xqlite, "~> 0.10"}` (`apps/evo_git/mix.exs:35`).
- **All user values are parameterized** with `?N` numbered placeholders + params list. The ONLY interpolated identifiers are table names (`#{table}`), column lists, and PK names — all from closed module-level sets (Codec column lists, hardcoded literals), never user input.
- **No prepared statements**: every call is a one-shot prepare+execute via the NIF; no statement caching/reuse.
- **No transactions**: zero matches for `with_transaction|BEGIN|COMMIT|ROLLBACK` anywhere in `apps/evo_git/lib` (only git-related COMMIT matches). Every `XqliteNIF.execute` is its own autocommit. SQLite WAL mode set at open (`store.ex:340`: `journal_mode: :wal, synchronous: :normal, cache_size: -2000`); `PRAGMA wal_checkpoint(TRUNCATE)` on terminate (`store.ex:346,364-365`).
- **SQLite JSON1 functions — used only by the migration task**: `mix migrate.store` step 4 uses `json_valid`/`json_type`/`json_object`/`json_extract` when the bundled SQLite has JSON1 (verified available at runtime — bundled SQLite 3.53.2), with an Elixir/Jason fallback for hosts without it. Everywhere else (all of `Codec` and the Store), JSON handling is in Elixir via Jason. Consequently: `Queries.build_where/1`'s `:search` filter does `opts LIKE ?N ESCAPE '\'` over the RAW JSON TEXT of the opts column (substring match on the serialized JSON), and the `id`/`project_path` LIKE matches are the only other search surfaces — no JSON-path querying exists.
- **Heavy vs cheap decode**: `decode_task/1` + `decode_result/1` are HEAVY (full struct reconstruction, JSON decode of result/opts/logs/usage/archive); `decode_atom/1`, `decode_datetime/1`, `decode_logs/1`, `decode_archive/1`, `decode_usage/1` are cheap-to-medium scalar decodes that never raise (nil/[] fallbacks). Raise vectors: positional pattern mismatches (row shape/arity) in `decode_task/1`/`decode_project/1`, plus `ArgumentError` from `decode_result/1`/`decode_opts/1` on non-canonical JSON (see "Strict canonical decode") — safe-select and summary callers catch these, skip, and warn. `decode_reason/1` is the only decode-side try/rescue (String.to_existing_atom → ArgumentError → keep string).

## Known Issues

- **⚠️ Summary queries are the memory-scaling hot spot (dashboard-driven).** `select_tasks_summary` / `select_tasks_summary_by_path` / `select_tasks_changed_since` (store.ex:755-803) full-table-scan ALL rows and decode the heavy `result` JSON per row INLINE in this GenServer: `@summary_columns` (store.ex:58) includes `result`, and `decode_summary_row` (store.ex:987-1023) → `Codec.decode_result` (codec.ex:455-487) parses the full result blob (embeds `archive_records` + usage — the largest data in the DB, and duplicated in `archive_metadata`). The decoded list is retained in this process's heap until the next major GC, so Store heap ≈ O(rows × result-blob size) while the dashboard polls (every task broadcast triggers a re-fetch with a 300 ms debounce; TaskRegistry's summary handlers at task_registry.ex:403-418 are NOT Task-offloaded either). Correlates with `tasks.sqlite` file size. **Fix:** drop `result`/`opts` from `@summary_columns` (consumers only need the denormalized `branch_name`) and/or move decode off this GenServer's heap (raw-rows API + decode in caller's Task process). See task_registry/CONTEXT.md "Known Issues" for the full chain.

## Known Gaps

- **✅ RESOLVED — `started_at` is now indexed** (`idx_tasks_started_at`, created in `Schema.create_tables/1`). The paginated list query hardcodes `ORDER BY started_at DESC LIMIT ?N OFFSET ?M` (`store.ex:468-471`); the index makes paging O(page) instead of full-scan + sort. Indexed columns are now `status`, `finished_at`, `lease_expires_at`, `project_path`, `updated_at`, `started_at`. `type` and `review_status` remain unindexed (the "pending" review filter is driven by the indexed `status = 'completed'` predicate).
- **Search matches raw JSON text**: the `:search` filter LIKEs against the serialized `opts` JSON, so hits depend on JSON key/string representation (e.g. underscores escaped) — a search for a value stored in `opts` matches only if the JSON text contains it verbatim. (Unchanged by the opts object-encoding switch — values are still JSON text.)

## SQLite Optimization Analysis (read-only review — ranked by impact)

Goal context: lower work into SQL instead of Elixir. The codebase is already well along this path — pagination, filters, DISTINCT, status filtering, and COUNT are SQL-side (`safe_select_paginated_tasks` store.ex:459-489, `select_finished_task_ids` store.ex:517-529, `select_task_paths` store.ex:500-512), and 5 lightweight query functions avoid full-struct decode. The remaining opportunities are **column-width narrowing** (bigger win than row filtering) and a few row-filter pushdowns:

1. **Narrow `task_get` reads in TaskRegistry handlers (highest frequency).** `task_get` (task_registry.ex:585-587) decodes ALL 19 columns (incl. logs JSON up to 500 entries, result, usage, archive_metadata) for operations that use 1-3 fields:
   - `handle_update_status/6` (task_registry.ex:506-581, per status cast) needs only `status` (stale-guard), `lease_expires_at` (kept for non-terminal), and `opts` (for `project_path` extraction, :542). A `SELECT status, lease_expires_at, opts FROM tasks WHERE id=?1` would skip the heavy JSON decodes.
   - `append_log` (task_registry.ex:450-461, per log line — VERY frequent during runs) needs only `logs`; currently decodes the whole row incl. a 500-entry logs array + result/usage/archive_metadata, then re-encodes logs. A `SELECT logs FROM tasks WHERE id=?1` narrow read is the single best hot-path win.
   - `set_review_status`/`set_review_metadata` (task_registry.ex:472-499) need only existence → reuse `get_task_status`-style `SELECT status`.
   - `cancel_task` (:299) + `handle_info({:task_status,...})` (:683) + `resolve_recheck_task` (:599) full-decode then `put_task` full-re-encode → could be `update_task_columns` + narrow status read (put_task writes all 18 columns; only status/finished_at/lease_expires_at/result change).
   - Blockers: none hard — new lightweight Store functions (mirroring `select_running_lease_info` pattern) needed; `opts` still needs `Codec.decode_opts` (JSON) for project_path, but skips the other 3 heavy JSON columns.
2. **`select_running_lease_info` (store.ex:534-547) reads ALL rows with no WHERE.** Both callers filter status in Elixir: init reconcile `== :finalizing` (task_registry.ex:196), `lease_sweep` `== :running` (task_registry.ex:905-909). Adding `WHERE status IN ('running','finalizing')` is trivially safe (status is a plain TEXT column, codec.ex:192 — no decode skipped that matters since only `decode_atom` runs). `id not in owned_ids` and lease-validity checks must stay Elixir-side (in-memory task_refs + wall-clock).
3. **`select_cleanup_info` (store.ex:588-601) reads ALL rows; `Cleanup` (cleanup.ex:39-53) filters/sorts in Elixir.** `WHERE finished_at IS NOT NULL` is trivially safe (cleanup only ever deletes `finished_at != nil` rows). Age-cutoff and count-trim pushdown (`finished_at < ?cutoff`, `ORDER BY finished_at DESC LIMIT -1 OFFSET ?max_tasks`) were BLOCKED by the ISO-8601 mixed-precision string caveat — **now unblocked** for normalized rows (g1 resolved: `encode_datetime/1` fixed precision + `normalize_timestamps/1` migration). Also `delete_tasks/2` (store.ex:434-439) issues N individual DELETEs — batch as `DELETE ... WHERE id IN (...)` with chunking (SQLite max variables ~32766; rusqlite default).
4. **`select_tasks_summary` (store.ex:607-630) decodes `result` for every row on every dashboard poll.** Consumers only need `branch_name` from result (`show_review_button?` at evo_dash dashboard_live/assigns.ex:52), and `branch_name` is ALREADY a denormalized column (codec.ex:85,100-106; store.ex:544-548). Adding `branch_name` to the summary SELECT + dropping `result` from it (dashboard change) skips `decode_result` per row per poll — result JSON can be huge (embeds archive_records). Note decode runs INLINE in the Store GenServer (Task-offload exists only for the two `safe_select_*` calls at task_registry.ex:273-291), so narrower columns also cut Store GenServer heap churn.
5. **✅ DONE — `started_at` indexed** (schema.ex — `idx_tasks_started_at`). The paginated query hardcodes `ORDER BY started_at DESC` (store.ex:470): the index makes paging O(page). No behavior change.
6. **`trim_recent_projects`/`list_recent_projects` (task_registry.ex:649-675, 424-429)** — full project decode + Elixir sort; table is capped at 10 rows so impact is nil; if ever pushed to SQL, note SQLite `ORDER BY last_opened_at DESC` puts NULLs LAST (matches the nil-safe Elixir sort), but the ISO caveat applies.
7. **✅ DONE — dead code removed**: `Cleanup.cleanup_expired_tasks/2` (pre-loaded variant) and `Lease.set_crash_details/1` were deleted (rg-verified zero callers). `Lease.lookup_sched_meta_result/1` is KEPT — used by `resolve_recheck_task/3` (task_registry.ex).

### Blockers specific to full SQL-lowering
- **(g1) RESOLVED — ISO-8601 strings with mixed precision break lexicographic datetime comparison.** `DateTime.to_iso8601/1` `:auto` precision emits `"…00Z"` for whole seconds but `"…00.123456Z"` with microseconds — `'Z'` (0x5A) > `'.'` (0x2E), so `"…00Z"` sorts BEFORE `"…00.5Z"` lexicographically while being chronologically AFTER. **Fixed** by `Codec.encode_datetime/1` (fixed `:millisecond` precision, constant 24-char `%Y-%m-%dT%H:%M:%S.SSSZ`) + `Schema.normalize_timestamps/1` (migrates existing rows; idempotent via GLOB guard, skips unparseable rows via `julianday` guard). SQL-side datetime filtering/ordering pushdowns (cleanup cutoff, project recency) are now unblocked for normalized rows.
- **(g2) RESOLVED — `result` column is uniformly valid JSON after `mix migrate.store`.** `encode_result/1` always wraps plain strings (crash fallbacks) with a `"string"` `__result_tag__`; the migration task's canonical-result rewrite (step 4) converts legacy rows: 4a JSON `null` text → SQL NULL, 4b raw strings and untagged JSON (objects/arrays/scalars) → `"string"`-tag wrap (content preserved verbatim). `decode_result/1` is strict — only the 4 tagged forms decode; anything else raises `ArgumentError`. ⚠️ DBs that have NOT run `mix migrate.store` still contain legacy rows and will RAISE on decode — run the migration before reading. Any SQL-side `json_extract` on `result` must remain `json_valid`-guarded (non-migrated raw strings). JSON1 verified available at runtime (bundled SQLite 3.53.2).
- **(g3) RESOLVED — `opts` is now a JSON object** (string keys) instead of a positional array of `[key_str, value]` pairs — values are addressable via JSON paths (e.g. `json_extract(opts, '$.path')`). ⚠️ Legacy array rows still exist in old DBs; `decode_opts/1` raises `ArgumentError` on non-object JSON, so the `mix migrate.store` opts-object rewrite must run before reading old DBs (and any SQL-side JSON-path querying must tolerate both shapes until migrated). The `:search` filter (`opts LIKE` over raw JSON text) is fine as-is.
- **(g5) Single GenServer connection serializes all SQLite I/O** — SQL pushdown reduces bytes/decode/GC but NOT contention; the 30s `@call_timeout` (store.ex:55) exists for NFS-slow disks, where fewer+smaller statements help directly. No transactions anywhere (each execute is autocommit).
- **(g6) No prepared-statement reuse** — `Xqlite.prepare/2`/`step/1` exist in the dep (deps/xqlite/lib/xqlite.ex:983,1009) but the code uses only one-shot `XqliteNIF.query/3`/`execute/3`. Micro-optimization only; not a blocker for WHERE/LIMIT pushdown.

### Justified vs accidental whole-table reads
- **Justified:** `safe_select_all_tasks` for `list_tasks` dashboard "show all" (API contract, offloaded to Task process); `safe_select_all_projects` (≤10 rows).
- **Accidental/avoidable:** `select_running_lease_info` (no WHERE; 2 callers both filter status in Elixir), `select_cleanup_info` (no WHERE; Elixir `finished_at != nil` filter), `task_get` full decode in `append_log`/`handle_update_status`/`set_review_*` (1-3 fields needed), `put_task` full re-encode in `cancel_task`/`{:task_status}`/`resolve_recheck_task` (targeted `update_task_columns` suffices), `delete_tasks` N-statement loop.
- Column order matters — `@task_columns` and `@project_columns` define positional encoding/decoding.
- JSON encoding via Jason; complex fields stored as JSON TEXT in SQLite columns.
- Known-atom whitelists must stay in sync with the application's valid status/review_status/type atoms.
- The main `EvoGit.Store` GenServer follows the crash philosophy: no try/rescue in handle_call/2; only `terminate/2` has a justified try/rescue for graceful connection close.
