# EvoGit.Store — SQLite Persistence Layer

## Intent

Contains the `EvoGit.Store` GenServer and its support modules for the SQLite persistence layer. The main store module (`store.ex`) was migrated from `evo_dash` (formerly `EvoDash.Store`) to `evo_git` as part of the domain persistence layer migration, and was later split into focused sub-modules.

## Routing Table

- `../store.ex` → Main GenServer module (`EvoGit.Store`) — public API, GenServer callbacks, private helpers
- `./codec.ex` → `EvoGit.Store.Codec` — pure serialization/deserialization functions (no I/O)
- `./schema.ex` → `EvoGit.Store.Schema` — table creation and idempotent column migration
- `./queries.ex` → `EvoGit.Store.Queries` — SQL builder helpers (WHERE, SET, clamping, column encoding)
- `./quarantine.ex` → `EvoGit.Store.Quarantine` — safe row decoding, integrity checks, quarantine recovery

## API Surface

### `EvoGit.Store` (`../store.ex`)

GenServer wrapping a single xqlite (SQLite) connection. Public API for task and project CRUD, lightweight queries, and safety/integrity operations.

### `EvoGit.Store.Codec` (`codec.ex`)

| Function | Description |
|----------|-------------|
| `task_columns/0` | Returns the ordered list of task table column names |
| `project_columns/0` | Returns the ordered list of project table column names |
| `encode_task/1` | TOTAL encode (never raises) — serializes a `%TaskInfo{}` struct into a list of column values |
| `decode_task/1` | Deserializes a list of column values back into a `%TaskInfo{}` struct. Raises on bad data (quarantine handles recovery). |
| `encode_project/1` | TOTAL encode for `%RecentProject{}` structs |
| `decode_project/1` | Deserializes column values into `%RecentProject{}` |
| `validate_task/1` | Validates a task list for structural correctness |
| `validate_project/1` | Validates a project list for structural correctness |

### `EvoGit.Store.Schema` (`schema.ex`)

| Function | Description |
|----------|-------------|
| `create_tables/1` | Creates tables (tasks, projects, quarantine) and indexes |
| `migrate_schema/1` | Idempotent column migration — adds missing columns to existing DBs |
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

### `EvoGit.Store.Quarantine` (`quarantine.ex`)

| Function | Description |
|----------|-------------|
| `safe_decode_rows/4` | Decode+quarantine loop — quarantines bad rows rather than crashing |
| `do_integrity_check/1` | PRAGMA integrity_check + row-level scan-and-repair |
| `do_recover_quarantine/1` | Recovers previously quarantined rows back into live tables |
| `table_columns/1` | Maps table name to its Codec column list |
| `pk_column/1` | Maps table name to its primary key column |

### Field-level encoders/decoders (Codec)
- **Atoms**: `encode_atom/1` (accepts nil/atoms/strings), `decode_atom/1` (uses `String.to_atom/1` guarded by a closed whitelist `@known_atoms` — safe because the set is bounded and application-controlled; `String.to_existing_atom/1` is only used in `decode_reason/1`, the one justified try/rescue)
- **DateTime**: `encode_datetime/1`, `decode_datetime/1`
- **Result tuples**: `encode_result/1`, `decode_result/1` — round-trips `{:ok, map}`, `{:error, reason}`, `{:exit, reason}` via `__result_tag__` JSON discriminator
- **Usage**: `encode_usage/1`, `decode_usage/1` — `%EvoGit.Agent.Usage{}` struct ↔ JSON string (map); `decode_usage_map/1` rebuilds the struct using precomputed `@usage_field_pairs` (string+atom key fallback lookup, zero-allocation)
- **Archive metadata**: `encode_archive_metadata/1`, `decode_archive_metadata/1`
- **Opts/Logs**: JSON encode/decode via Jason

## Design Principles

1. **TOTAL encode**: Encode functions never raise. All JSON encoding uses non-crashing `Jason.encode/1` with `case`/`with`.
2. **Decode raises on bad data**: The Store's quarantine logic (in `EvoGit.Store.Quarantine`) handles crash recovery by moving undecodable rows to a quarantine table.
3. **Atom safety**: Uses closed whitelists with `Map.get/3` for atom conversion from DB-sourced strings.
4. **Result tuple round-tripping**: `{:ok, %{...}}`, `{:error, _}`, `{:exit, _}` tuples survive JSON encode/decode via the `__result_tag__` discriminator.
5. **One justified `try/rescue`**: `decode_reason/1` — `String.to_existing_atom/1` has no non-crashing variant; unknown reason strings legitimately stay strings.

## SQL Access Patterns (verified 2025 — whole repo search)

- **Only two xqlite entry points**: `XqliteNIF.query/3` (SELECT/PRAGMA) and `XqliteNIF.execute/3` (INSERT/UPDATE/DELETE/DDL). No `Xqlite` module-wrapper helpers (no `q/2`, no `exec/3`). Dep: `{:xqlite, "~> 0.10"}` (`apps/evo_git/mix.exs:35`).
- **All user values are parameterized** with `?N` numbered placeholders + params list. The ONLY interpolated identifiers are table names (`#{table}`, `#{quarantine_table}`), column lists, and PK names — all from closed module-level sets (Codec column lists, hardcoded literals), never user input.
- **No prepared statements**: every call is a one-shot prepare+execute via the NIF; no statement caching/reuse.
- **No transactions**: zero matches for `with_transaction|BEGIN|COMMIT|ROLLBACK` anywhere in `apps/evo_git/lib` (only git-related COMMIT matches). Every `XqliteNIF.execute` is its own autocommit. The multi-statement quarantine flows (`quarantine.ex:270-280` INSERT-into-quarantine + DELETE-from-live; `quarantine.ex:179-191` INSERT OR REPLACE + DELETE in recovery) are NOT wrapped in a transaction — a crash between the two statements leaves the row in both tables (INSERT OR REPLACE makes recovery idempotent; the DELETE is by id). SQLite WAL mode set at open (`store.ex:340`: `journal_mode: :wal, synchronous: :normal, cache_size: -2000`); `PRAGMA wal_checkpoint(TRUNCATE)` on terminate (`store.ex:346,364-365`).
- **No SQLite JSON1 functions** (`json_extract`, `json_each`, `json_valid`, `json_array_length`, etc. — zero matches in the whole repo). All JSON handling is in Elixir via Jason in `Codec`. Consequently: `Queries.build_where/1`'s `:search` filter does `opts LIKE ?N ESCAPE '\'` over the RAW JSON TEXT of the opts column (substring match on the serialized JSON), and the `id`/`project_path` LIKE matches are the only other search surfaces — no JSON-path querying exists.
- **Heavy vs cheap decode**: `decode_task/1` + `decode_result/1` are HEAVY (full struct reconstruction, JSON decode of result/opts/logs/usage/archive); `decode_atom/1`, `decode_datetime/1`, `decode_logs/1`, `decode_archive/1`, `decode_usage/1`, `decode_opts/1` are cheap-to-medium scalar decodes that NEVER raise (nil/[]/raw-string fallbacks). The ONLY raise vectors in the whole Codec are positional pattern mismatches (row shape/arity) in `decode_task/1`/`decode_project/1` — that is what the quarantine try/rescue catches. `decode_reason/1` is the only decode-side try/rescue (String.to_existing_atom → ArgumentError → keep string).

## Known Gaps

- **`started_at` is NOT indexed**, yet the paginated list query hardcodes `ORDER BY started_at DESC LIMIT ?N OFFSET ?M` (`store.ex:468-471`) — every page read is a full scan + sort. Indexed columns are only `status`, `finished_at`, `lease_expires_at`, `project_path` (`schema.ex:82-85`). `type` and `review_status` are also unindexed (the "pending" review filter is driven by the indexed `status = 'completed'` predicate).
- **Quarantine-on-init whole-table scrub**: `TaskRegistry.init/1` → `do_integrity_check/1` → `scan_and_repair/3` runs `SELECT <all columns> FROM tasks` AND `FROM projects` (no WHERE) and decodes EVERY row of both tables at every app start (`quarantine.ex:100-107,227-253`). Any row that raises is quarantined + deleted (see root CONTEXT.md "Quarantine-on-init data-loss vector"). This is a per-start O(table) cost, and `safe_decode_rows/4` similarly decodes every row of any fetched batch.
- **Recovery rebuilds rows positionally from the JSON map** (`quarantine.ex:160-164`): `Enum.map(columns, &Map.get(map, &1))` — a quarantined row stored with missing keys re-inserts with nil values; recovery checks only that the decoder doesn't raise, NOT `validate_task/1` (a nil-`id` row would still INSERT OR REPLACE — SQLite allows NULL in a TEXT PRIMARY KEY).
- **Search matches raw JSON text**: the `:search` filter LIKEs against the serialized `opts` JSON, so hits depend on JSON key/string representation (e.g. underscores escaped) — a search for a value stored in `opts` matches only if the JSON text contains it verbatim.

- Pure functional — no GenServer, no I/O, no process calls (Codec, Schema, Queries, Quarantine are all pure-function modules).
- Column order matters — `@task_columns` and `@project_columns` define positional encoding/decoding.
- JSON encoding via Jason; complex fields stored as JSON TEXT in SQLite columns.
- Known-atom whitelists must stay in sync with the application's valid status/review_status/type atoms.
- The main `EvoGit.Store` GenServer follows the crash philosophy: no try/rescue in handle_call/2; only `terminate/2` has a justified try/rescue for graceful connection close.
