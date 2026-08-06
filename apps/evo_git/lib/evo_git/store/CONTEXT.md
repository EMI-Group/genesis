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
| `migrate_schema/1` | Idempotent column migration — adds missing columns to existing DBs |
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
- **Result tuples**: `encode_result/1`, `decode_result/1` — round-trips `{:ok, map}`, `{:error, reason}`, `{:exit, reason}` via `__result_tag__` JSON discriminator
- **Usage**: `encode_usage/1`, `decode_usage/1` — `%EvoGit.Agent.Usage{}` struct ↔ JSON string (map); `decode_usage_map/1` rebuilds the struct using precomputed `@usage_field_pairs` (string+atom key fallback lookup, zero-allocation)
- **Archive metadata**: `encode_archive_metadata/1`, `decode_archive_metadata/1`
- **Opts/Logs**: JSON encode/decode via Jason

## Design Principles

1. **TOTAL encode**: Encode functions never raise. All JSON encoding uses non-crashing `Jason.encode/1` with `case`/`with`.
2. **Decode raises on bad data**: Decode functions raise on structurally bad rows; callers skip such rows and log a `Logger.warning` (no quarantine table — see "Removal: quarantine/integrity machinery" below).
3. **Atom safety**: Uses closed whitelists with `Map.get/3` for atom conversion from DB-sourced strings.
4. **Result tuple round-tripping**: `{:ok, %{...}}`, `{:error, _}`, `{:exit, _}` tuples survive JSON encode/decode via the `__result_tag__` discriminator.
5. **One justified `try/rescue`**: `decode_reason/1` — `String.to_existing_atom/1` has no non-crashing variant; unknown reason strings legitimately stay strings.

## Removal: quarantine/integrity machinery (decision + rationale)

The quarantine/integrity subsystem (`EvoGit.Store.Quarantine` — `tasks_quarantine`/`projects_quarantine` tables, `integrity_check`, `scan_and_repair`, `recover_quarantine`) has been **removed**. It was legacy from the DETS era of the store:

- `d6bc9cce` "Refactor TaskRegistry from ETS+DETS to DETS-only" introduced it; `de50b599`/`8ce9c763`/`eba7820e` ("harden DETS against data-loss risks") built it up — it existed to rescue rows from a DETS file that could corrupt on unclean shutdown.
- The DETS-era store was superseded by the SQLite Store (`bdbacde2`). SQLite in WAL mode (`journal_mode: :wal`) is crash-safe and essentially never corrupts, so the whole quarantine safety net is obsolete machinery.

**New semantics:**

- **No quarantine tables are created** (DDL removed from `Schema.create_tables/1`; existing quarantine tables in live DBs are NOT dropped — harmless leftover rows are simply ignored).
- **Undecodable rows are SKIPPED + `Logger.warning`** — decode errors in read paths are caught and logged, with no INSERT-into-quarantine + DELETE-from-live pair.
- **The only startup DB check kept is lease reconciliation**, done with pure SQL (`EvoGit.Store.select_running_lease_info/1` in `TaskRegistry.init/1` — see root CONTEXT.md "Stuck-`:finalizing`-forever bug"). No whole-table integrity scrub at init.

## Fixed-precision timestamps (normalize_timestamps + encode_datetime)

- `Codec.encode_datetime/1` now emits a **constant 24-char `:millisecond` ISO-8601 format** (`%Y-%m-%dT%H:%M:%S.SSSZ`, exactly 3 fractional digits — `.000Z` even for whole seconds) via `DateTime.truncate(dt, :millisecond)` + `DateTime.to_iso8601/1`. This format is **lexicographically sortable** in SQLite, fixing the mixed-precision `:auto` mis-sort (`'Z'` (0x5A) > `'.'` (0x2E)) that broke `ORDER BY started_at DESC` and blocked SQL-side datetime pushdowns (g1).
- `Schema.normalize_timestamps/1` migrates **existing** DB rows (tasks.started_at / tasks.finished_at / projects.last_opened_at) to the same format. It is idempotent (GLOB guard `'*.[0-9][0-9][0-9]Z'` skips already-normalized rows; `%f` round-trips them unchanged) and skips unparseable rows (`julianday(...) IS NOT NULL` guard — never overwritten with NULL). A caller in `Store.init/1` invokes it after `migrate_schema/1`.

## SQL Access Patterns (verified 2025 — whole repo search)

- **Only two xqlite entry points**: `XqliteNIF.query/3` (SELECT/PRAGMA) and `XqliteNIF.execute/3` (INSERT/UPDATE/DELETE/DDL). No `Xqlite` module-wrapper helpers (no `q/2`, no `exec/3`). Dep: `{:xqlite, "~> 0.10"}` (`apps/evo_git/mix.exs:35`).
- **All user values are parameterized** with `?N` numbered placeholders + params list. The ONLY interpolated identifiers are table names (`#{table}`), column lists, and PK names — all from closed module-level sets (Codec column lists, hardcoded literals), never user input.
- **No prepared statements**: every call is a one-shot prepare+execute via the NIF; no statement caching/reuse.
- **No transactions**: zero matches for `with_transaction|BEGIN|COMMIT|ROLLBACK` anywhere in `apps/evo_git/lib` (only git-related COMMIT matches). Every `XqliteNIF.execute` is its own autocommit. SQLite WAL mode set at open (`store.ex:340`: `journal_mode: :wal, synchronous: :normal, cache_size: -2000`); `PRAGMA wal_checkpoint(TRUNCATE)` on terminate (`store.ex:346,364-365`).
- **No SQLite JSON1 functions** (`json_extract`, `json_each`, `json_valid`, `json_array_length`, etc. — zero matches in the whole repo). All JSON handling is in Elixir via Jason in `Codec`. Consequently: `Queries.build_where/1`'s `:search` filter does `opts LIKE ?N ESCAPE '\'` over the RAW JSON TEXT of the opts column (substring match on the serialized JSON), and the `id`/`project_path` LIKE matches are the only other search surfaces — no JSON-path querying exists.
- **Heavy vs cheap decode**: `decode_task/1` + `decode_result/1` are HEAVY (full struct reconstruction, JSON decode of result/opts/logs/usage/archive); `decode_atom/1`, `decode_datetime/1`, `decode_logs/1`, `decode_archive/1`, `decode_usage/1`, `decode_opts/1` are cheap-to-medium scalar decodes that NEVER raise (nil/[]/raw-string fallbacks). The ONLY raise vectors in the whole Codec are positional pattern mismatches (row shape/arity) in `decode_task/1`/`decode_project/1` — callers catch these and skip + warn. `decode_reason/1` is the only decode-side try/rescue (String.to_existing_atom → ArgumentError → keep string).

## Known Gaps

- **`started_at` is NOT indexed**, yet the paginated list query hardcodes `ORDER BY started_at DESC LIMIT ?N OFFSET ?M` (`store.ex:468-471`) — every page read is a full scan + sort. Indexed columns are only `status`, `finished_at`, `lease_expires_at`, `project_path` (`schema.ex:82-85`). `type` and `review_status` are also unindexed (the "pending" review filter is driven by the indexed `status = 'completed'` predicate).
- **Search matches raw JSON text**: the `:search` filter LIKEs against the serialized `opts` JSON, so hits depend on JSON key/string representation (e.g. underscores escaped) — a search for a value stored in `opts` matches only if the JSON text contains it verbatim.

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
5. **Index `started_at`** (schema.ex:82-85 — currently unindexed) — the paginated query hardcodes `ORDER BY started_at DESC` (store.ex:470): every page is a full scan + temp-B-tree sort. Index makes paging O(page). No behavior change.
6. **`trim_recent_projects`/`list_recent_projects` (task_registry.ex:649-675, 424-429)** — full project decode + Elixir sort; table is capped at 10 rows so impact is nil; if ever pushed to SQL, note SQLite `ORDER BY last_opened_at DESC` puts NULLs LAST (matches the nil-safe Elixir sort), but the ISO caveat applies.
7. **Dead code cleanup** (housekeeping, not SQL): `cleanup_expired_tasks/2` pre-loaded variant (cleanup.ex:72-101) has zero callers; `Lease.set_crash_details/1` + `lookup_sched_meta_result/1` are dead (only reachable via the never-scheduled `:recheck_task`).

### Blockers specific to full SQL-lowering
- **(g1) RESOLVED — ISO-8601 strings with mixed precision break lexicographic datetime comparison.** `DateTime.to_iso8601/1` `:auto` precision emits `"…00Z"` for whole seconds but `"…00.123456Z"` with microseconds — `'Z'` (0x5A) > `'.'` (0x2E), so `"…00Z"` sorts BEFORE `"…00.5Z"` lexicographically while being chronologically AFTER. **Fixed** by `Codec.encode_datetime/1` (fixed `:millisecond` precision, constant 24-char `%Y-%m-%dT%H:%M:%S.SSSZ`) + `Schema.normalize_timestamps/1` (migrates existing rows; idempotent via GLOB guard, skips unparseable rows via `julianday` guard). SQL-side datetime filtering/ordering pushdowns (cleanup cutoff, project recency) are now unblocked for normalized rows.
- **(g2) `result` column mixes JSON and raw non-JSON strings** (crash fallbacks like `"Task process exited: …"` are stored verbatim — codec.ex:414,434-436). Any `json_extract` on `result` must be guarded by `json_valid(result)`; JSON1 functions are almost certainly available (rusqlite bundles SQLite ≥3.38 where JSON is core) but unverified at runtime (`SELECT json_valid('{}')`).
- **(g3) `opts` is a positional JSON array of `[key_str, value]` pairs** — JSON-path key lookup requires knowing the array index; fragile. The only opts-based filter (`:search` in queries.ex:152-157) is a substring LIKE over raw JSON text and is fine as-is.
- **(g5) Single GenServer connection serializes all SQLite I/O** — SQL pushdown reduces bytes/decode/GC but NOT contention; the 30s `@call_timeout` (store.ex:55) exists for NFS-slow disks, where fewer+smaller statements help directly. No transactions anywhere (each execute is autocommit).
- **(g6) No prepared-statement reuse** — `Xqlite.prepare/2`/`step/1` exist in the dep (deps/xqlite/lib/xqlite.ex:983,1009) but the code uses only one-shot `XqliteNIF.query/3`/`execute/3`. Micro-optimization only; not a blocker for WHERE/LIMIT pushdown.

### Justified vs accidental whole-table reads
- **Justified:** `safe_select_all_tasks` for `list_tasks` dashboard "show all" (API contract, offloaded to Task process); `safe_select_all_projects` (≤10 rows).
- **Accidental/avoidable:** `select_running_lease_info` (no WHERE; 2 callers both filter status in Elixir), `select_cleanup_info` (no WHERE; Elixir `finished_at != nil` filter), `task_get` full decode in `append_log`/`handle_update_status`/`set_review_*` (1-3 fields needed), `put_task` full re-encode in `cancel_task`/`{:task_status}`/`resolve_recheck_task` (targeted `update_task_columns` suffices), `delete_tasks` N-statement loop.
- Column order matters — `@task_columns` and `@project_columns` define positional encoding/decoding.
- JSON encoding via Jason; complex fields stored as JSON TEXT in SQLite columns.
- Known-atom whitelists must stay in sync with the application's valid status/review_status/type atoms.
- The main `EvoGit.Store` GenServer follows the crash philosophy: no try/rescue in handle_call/2; only `terminate/2` has a justified try/rescue for graceful connection close.
