# EvoGit.Store — Ecto/SQLite Persistence Layer

## Intent

The task/project persistence layer of `:evo_git` (so the headless `genesis_remote` daemon has full task history). `EvoGit.Store` (`../store.ex`) is a THIN GenServer facade over a pure-Operations Ecto layer; the on-disk bytes are owned exclusively by `EvoGit.Store.Codec` (the wire oracle). The public client API — names, arities, defaults, 30s `@call_timeout`, return shapes — is the frozen contract; `lib/evo_git/task_registry.ex` and the `evo_dash` RPC surface call it untouched.

## Architecture (facade → Operations → Repo → schemas → Types → Codec)

```
EvoGit.Store (GenServer facade, store.ex)
  └─ EvoGit.Store.Operations.* (pure modules; repo pid FIRST arg)
       └─ EvoGit.Store.RepoScope.with_repo(pid, fun)   — scoped dynamic-repo binding
            └─ EvoGit.Repo.* + Ecto.Query              — unnamed dynamic instance (XqliteEcto3)
                 └─ Schemas.TaskRow/ProjectRow (typed, WRITE) / TaskRowRaw/ProjectRowRaw (raw, READ)
                      └─ EvoGit.Store.Types.*           — Ecto.Type, THIN delegation
                           └─ EvoGit.Store.Codec        — the single encode/decode oracle
```

- **Facade (`store.ex`)** owns ONLY: the client API, the one-line-per-handler `handle_call` dispatch, the heavy-read offload (`offload/3`), the disk-full write choke point (`write_call/2`), the `__repo_pid__/1` test seam, and `init/1`/`terminate/2` (boot/stop the dynamic repo). No SQL lives here.
- **Operations** (`./operations/`) own every `EvoGit.Repo.*` + `Ecto.Query` call: `Tasks` (write/core/pagination/narrow reads), `Lightweight` (id/lease/cleanup projections), `Summaries` (16-key summary projections), `Projects` (project CRUD + its own disk-full rescue), `Safety` (safe selects + `size`). Every public function takes the repo PID first and runs its whole body inside `RepoScope.with_repo/2`, so calls target THAT store's instance regardless of the calling process (the offloaded read Tasks included).
- **Wire format**: the typed schemas dump/load through `Types.*`, which delegate verbatim to `Codec` — stored bytes are byte-identical to what the Codec defines, never re-implemented.

## Dynamic-Repo Design

- **Per-store UNNAMED instances**: `init/1` boots the repo via `EvoGit.Store.Boot.start_dynamic/1` — `EvoGit.Repo.start_link(database: path, name: nil, pool_size: 1)`. No name ⇒ no global collision ⇒ many same-named `EvoGit.Store` GenServers (test isolation, multi-store) each own their own DB. `state = %{repo: pid, name: name, data_dir: path}` (`:data_dir` is the SQLite FILE path; its parent dir is `mkdir_p`'d).
- **PID addressing via the process dictionary**: unnamed instances are addressed BY PID through `EvoGit.Repo.put_dynamic_repo/1` / `get_dynamic_repo/0`; a process that never set the binding transparently addresses the canonical named instance. `RepoScope.with_repo(pid, fun)` binds for `fun`'s duration and ALWAYS restores the previous binding (raise/throw/exit safe; nesting composes — the inner restores the outer's).
- **`pool_size: 1`**: one pooled connection = the connection every store write uses (also what the disk-full tests arm via `PRAGMA query_only`). Repo defaults (`repo.ex`): `journal_mode: :wal`, `synchronous: :normal`, `busy_timeout: 30_000`, `default_transaction_mode: :immediate`, `timeout: 30_000`; stop an unnamed instance with `Boot.stop/1` (`Supervisor.stop(pid, :normal)`) — `Repo.stop/0` follows the caller's binding instead.
- **Test seam**: `EvoGit.Store.__repo_pid__/1` (`@doc false`) exposes the facade's dynamic repo instance — the sanctioned way for tests to reach the store's own connection (e.g. `XqliteEcto3.with_xqlite/2`).

## Boot & Migrations

`init/1` → `Boot.start_dynamic(data_dir)` runs the Ecto migrations in `../../priv/repo/migrations/` BEFORE any read/write (`Ecto.Migrator.run(repo, Boot.migration_source(), :up, all: true)` — a no-op on a current DB), so an existing user DB upgrades automatically on first start; a manual `mix migrate.store` is never required to boot. Boot failure → `{:stop, {:failed_to_open_sqlite, reason}}` (historical stop tuple) — that tuple covers ONLY the repo-OPEN path (`start_dynamic/1`'s `{:error, reason}` from `EvoGit.Repo.start_link/1`); a MIGRATION raise (e.g. the baseline post-condition rejecting a non-canonical `tasks` shape) propagates out of `init/1` and crashes the Store child (supervisor restart, then app-boot failure) instead of stopping with that tuple. `terminate/2` → `Boot.stop(repo)` inside the module's one justified try/rescue (GenServer terminate must never raise).

### Migration 1 — `20260815000001_baseline_adoption`

Baseline schema ADOPTION: works on a fresh DB (tables via `CREATE TABLE IF NOT EXISTS` — 20-column `tasks`, 3-column `projects`) AND adopts ANY pre-Ecto legacy DB (no `schema_migrations` table ⇒ migrator sees version 0 ⇒ this migration runs):

- per-column NULLABLE `ALTER TABLE tasks ADD COLUMN` for the six columns a legacy table may lack (`lease_expires_at, model_id, project_path, branch_name, error, updated_at`), THEN the 6 baseline indexes (`CREATE INDEX IF NOT EXISTS` — `idx_tasks_updated_at` references a column the ALTERs may have just added).
- Post-condition: `tasks` carries EXACTLY the 20 canonical columns (names/types/notnull/pk). Physical order is canonical (fresh creates, 15/17-col prefix adoptions) OR the ACCEPTED adopted tail `…, branch_name, updated_at, error` — SQLite ALTERs can only APPEND, and the real v0.9.0–v0.12.5 table already ended in `updated_at`, so the appended `error` lands after it. Column order is functionally irrelevant in SQLite (every query in this system is name-based).
- Every statement runs via `repo().query!/3` (NOT `Ecto.Migration.execute/1` — string commands are queued until `flush/0`, so an in-body `PRAGMA table_info` probe would see the pre-migration state). `up/0` only — rolling back an adoption would drop user data.

### Migration 2 — `20260815000002_data_normalization`

Idempotent DATA rewrites (every guard leaves normalized rows alone):

- **Timestamps**: `strftime('%Y-%m-%dT%H:%M:%fZ', col)` where `col NOT GLOB '*.[0-9][0-9][0-9]Z' AND julianday(col) IS NOT NULL` — for `tasks.started_at`, `tasks.finished_at`, `projects.last_opened_at` (NOT `tasks.updated_at`: only backfilled, never re-formatted). Unparseable/NULL rows skipped.
- **Results**: JSON literal `null` text → SQL NULL; every other untagged value (raw non-JSON strings AND untagged JSON objects/arrays/scalars) wrapped verbatim as `{"__result_tag__":"string","value":…}` via `json_object`. Already-tagged rows untouched.
- **Opts**: legacy positional `[key, value]` pair arrays → JSON objects, rewritten in ELIXIR (Jason) so JSON booleans survive (never `json_group_object`, which collapses them to SQLite integers); malformed rows left untouched.
- **Backfills**: `branch_name` ← `json_extract(result, '$.data.branch_name')` only where NULL AND the result tag is `ok`; `updated_at` ← `COALESCE(finished_at, started_at, now)` where NULL (runs AFTER timestamp normalization). Drops the DETS-era `tasks_quarantine`/`projects_quarantine` tables.

### Migration 3 — `20260815000003_composite_indexes`

Additive DDL only (no table rebuild, no data rewrite; `up/0` only). Creates the two composite `(equality column, started_at)` indexes that make the paginated read index-served: `idx_tasks_status_started_at` on `(status, started_at)` and `idx_tasks_project_path_started_at` on `(project_path, started_at)`. Post-condition: `PRAGMA index_info(<name>)` must report EXACTLY the declared columns in order (`IF NOT EXISTS` alone would silently keep a same-named index of a different shape). Deliberately NOT added: `(status, project_path, started_at)` (never chosen over the two, and it cannot serve a status-only query — incomparable middle column), `type`/`review_status`/`branch_name` (no paginated query leads with them), and no `ANALYZE` (the planner picks both composites with no statistics; `ANALYZE` would scan a large user DB inside the boot-time migration). Full rationale + measurements: the migration's moduledoc.

### Migration source & concurrent-boot serialization

The migrator is fed a PRE-LOADED source — `Boot.migration_source/0` returns `[{version, module}]` ascending by version — never the migrations DIRECTORY.
`migration_source/0` enumerates `Ecto.Migrator.migrations_path(@repo)` + `Path.join("*.exs")` + `Path.wildcard()` (the path resolves `priv/repo/migrations` through `Application.app_dir/2`, so the canonical repo and every per-store dynamic instance resolve the same directory; no absolute priv path is hardcoded), parses each basename's integer version the way `Ecto.Migrator.extract_migration_info/1` does (the `"NNN_name.exs"` shape, anything else ignored), compiles the file with `Code.compile_file/1`, and picks the module exporting `__migration__/0` (mirroring `Ecto.Migrator.load_migration!/1` + `migration?/1`; no migration module in the file → `Ecto.MigrationError`).
The resulting source is memoized in `:persistent_term` under `{EvoGit.Store.Boot, :migration_source}`, so the `.exs` files are compiled at most ONCE per BEAM — later boots (and every test Store boot) reuse the already-loaded modules, and nothing redefines them (with a directory source `Ecto.Migrator.load_migration!/1` would `Code.compile_file/1` every pending file on every run, redefining an already-loaded module in the BEAM and printing a `redefining module` warning per boot).
`Boot.run_migrations/1` wraps the run (and the one-time compile it may trigger) in `:global.trans({{:evo_git_store_migrations, self()}, fun})` — a cluster-safe PRODUCTION lock (no test-side wrapper), since `Code.compile_file/1` of the same module is not concurrency-safe (a CompileError would otherwise surface) and boot is not exclusive (per-store dynamic instances can start in parallel).
The lock id is ONE global constant (not per DB path) because the protected resource is the shared migration source modules; the `self()` LockRequesterId makes it actually exclude (a constant id would be treated as re-entry).
The pdict save/restore stays OUTSIDE the lock (per-process state).

### `mix migrate.store`

`Mix.Tasks.Migrate.Store` (`lib/mix/tasks/migrate.store.ex`) is a thin wrapper: boots a private unnamed dynamic repo on the target DB (default `<data_dir>/tasks.sqlite`), runs `Boot.run_migrations/1` (the exact call boot uses), reports applied versions, stops the instance. Never starts `:evo_git`. Normally a NO-OP — exists for manual verification / interrupted upgrades.

## API Surface

### `EvoGit.Store` (`../store.ex`) — facade

Public API (all `GenServer.call`, 30s timeout; `store \\ __MODULE__`): `put_task`, `get_task`, `delete_task`, `delete_tasks` (500-id chunked), `clear_tasks`, `select_all_tasks`, `count_tasks`, `safe_select_paginated_tasks` (filters `status`/`project_path`/`review_status`/`search`, clamped limit 50/offset 0), `update_lease_expires_at` (never bumps `updated_at`), `update_task_columns` (ALWAYS bumps `updated_at`), `get_task_status`, `select_task_logs`, `select_task_update_info`, `select_task_paths`, `select_finished_task_ids`, `select_task_ids`, `select_running_lease_info`, `select_cleanup_info/1,3`, `select_tasks_summary/3`, `select_tasks_summary_by_path/4`, `select_tasks_changed_since/1`, project CRUD (`put_project`, `get_project`, `delete_project`, `select_all_projects`, `count_projects`), safety (`safe_select_all_tasks`, `safe_select_all_projects`, `size`), `__repo_pid__/1`. Plus `start_link(data_dir:, name: \\ __MODULE__)`.

### `EvoGit.Store.Operations.*` (`./operations/`)

| Module | Owns |
|---|---|
| `Tasks` | `put_task` (validate → ONE `:immediate` transaction: `delete_all` by id + `insert_all` of the FULL 20-key row — re-putting NULLs every column the new struct omits, parity with `INSERT OR REPLACE`; a changeset upsert would keep stale values and is deliberately NOT used), deletes, `clear_tasks`, `get_task`, `select_all_tasks`, `count_tasks`, `safe_select_paginated_tasks` (pagination filters incl. the ONE `fragment` — see Constraints), `update_lease_expires_at`, `update_task_columns`, narrow reads (`get_task_status`, `select_task_logs`, `select_task_update_info`). Denormalizations ported verbatim from `Codec.encode_task/1`: `project_path` ← `opts[:path]`, `branch_name` ← an `{:ok, data}` result's `branch_name` (each only when the struct field is nil), `updated_at` ← now. |
| `Lightweight` | id/lease/cleanup projections through `TaskRowRaw`: `select_task_paths` (DISTINCT non-nil), `select_finished_task_ids` (literal `status NOT IN ('running','pending','cancelling')`), `select_task_ids/2` (statuses → TEXT pushdown; `updated_at` raw; `status` decoded per row via `Codec.decode_atom/1`), `select_running_lease_info` (literal `IN ('running','finalizing','cancelling')`; raw unix-ms lease), `select_cleanup_info/1` (`%{id, finished_at}` maps) and `/3` (SQL-pushdown: Q1 age-expired `finished_at < cutoff`, Q2 count trim `ORDER BY finished_at DESC OFFSET n`). No JSON blob column is ever selected. |
| `Summaries` | the three 16-key summary projections (below). `statuses` atoms → TEXT pushdown (`[]` = all); `since` strict raw-string `updated_at >` compare; `project_path` exact equality; NO ORDER BY / NO LIMIT. Per-row lenient decode (skip + log). |
| `Projects` | project CRUD. `put_project` = DELETE + INSERT in one `:immediate` transaction (REPLACE semantics, keyed on the `path` TEXT PK); owns its OWN disk-full rescue (returns `{:error, :disk_full}` directly — NOT double-wrapped by the facade). NULL path never matches a row (`get_project` → nil, `delete_project` → `:ok` without touching the DB). |
| `Safety` | `safe_select_all_tasks/projects` (skip-and-log per-row decode through the RAW twins; on a wrong-typed cell Ecto's loader raises inside `Repo.all/1` BEFORE the per-row boundary, so both safe selects fall back to reading rows one-at-a-time by PK — a corrupt row is skipped + logged, never crashes the read) and `size` (SUM of both tables' row counts, never PRAGMA byte math). |

### `EvoGit.Repo` (`../repo.ex`) / `Boot` / `RepoScope`

| Module | Purpose |
|---|---|
| `EvoGit.Repo` | `use Ecto.Repo, otp_app: :evo_git, adapter: XqliteEcto3` — NOT in the supervision tree; instances are owned by stores. Runtime `init/2` resolves `database:` from start opts, falling back to `<data_dir>/tasks.sqlite`. |
| `EvoGit.Store.Boot` (`./boot.ex`) | `start_dynamic/1` (mkdir_p + unnamed repo + migrations), `run_migrations/1` (keyword = caller's binding, pid = scoped binding; global lock inside), `stop/1`, `migration_source/0` (the memoized pre-loaded `[{version, module}]` migrator source). |
| `EvoGit.Store.RepoScope` (`./repo_scope.ex`) | `with_repo(pid, fun)` — the scoped-addressing primitive for every read/write against an unnamed instance. Pure, no I/O. |

### `EvoGit.Store.Codec` (`./codec.ex`) — the oracle

| Function | Description |
|----------|-------------|
| `task_columns/0` / `project_columns/0` | Ordered column-name lists (19 task cols — `updated_at` deliberately NOT among them; 3 project cols) |
| `encode_task/1` / `decode_task/1` | TOTAL encode (never raises) / struct decode (raises on bad data) |
| `encode_project/1` / `decode_project/1` | Same for `%RecentProject{}` |
| `validate_task/1` / `validate_project/1` | Structural validation used by the write paths |
| field-level | `encode_atom/1`/`decode_atom/1` (closed `@known_atoms` whitelist), `encode_datetime/1`/`decode_datetime/1`, `encode_result/1`/`decode_result/1`, `encode_usage/1`/`decode_usage/1`/`decode_usage_map/1`, `encode_archive_metadata/1`/`decode_archive_metadata/1`, `encode_error/1`/`decode_error/1` (lenient), `encode_opts/1`/`decode_opts/1` |

### `EvoGit.Store.Errors` (`./errors.ex`)

Pure classifier, two shape families mapping to the same disk-full class: `disk_full_exception?/1` for RAISED `%XqliteEcto3.Error{}` (the adapter's failure mode — what the write boundary uses) and `disk_full_error?/1` for xqlite NIF error TUPLES (the legacy raw-SQL shape; kept for the classifier tests and documentation of the underlying codes).

### Schemas & Types

| Module | Purpose |
|---|---|
| `Schemas.TaskRow` / `ProjectRow` (`./schemas/`) | TYPED persistence-row schemas — the WRITE path. `TaskRow`: 20 fields (PK `id` TEXT, no autogenerate, NO `timestamps()` — `updated_at` is a plain field the Operations manage), column→type mapping via `Types.*`. Loading corrupt `opts`/`result` text raises `ArgumentError` (Codec's strictly-canonical contract) inside Ecto's loader — before any per-row rescue could run. |
| `Schemas.TaskRowRaw` / `ProjectRowRaw` | RAW wire-value READ-PROJECTION twins — plain `:string`/`:integer` fields, same field list/order/PK. Two reasons: (a) per-row safe decode (load raw, decode each row via `Codec` individually, skip+log the raising ones); (b) byte-identical `updated_at` (summary/changed-since read it as the raw ISO string, never a round-tripped DateTime). Writes NEVER go through the raw twins. |
| `Types.TaskTimestamp` | `%DateTime{}` ↔ fixed-ms ISO TEXT (dump == `Codec.encode_datetime/1`, load == `decode_datetime/1`). |
| `Types.TaskTimestampRaw` | Same DUMP, load passes the stored string through untouched — used for `updated_at`; freely swappable with `TaskTimestamp` without data migration. |
| `Types.UnixMs` | unix-ms INTEGER (`lease_expires_at`). |
| `Types.AtomColumn` + `Status`/`TaskType`/`ReviewStatus` | atom ↔ TEXT over the Codec's ONE closed `@known_atoms` union (the wrappers are readability aliases, NOT narrower validators). Unknown values decode to `nil` (exactly `Codec.decode_atom/1`). |
| `Types.OptsJson`/`ResultJson`/`LogsJson`/`UsageJson`/`ArchiveJson`/`ErrorJson` (`./types/json_columns.ex`) | JSON TEXT columns, thin Codec delegation; glue clauses return `:error` (Ecto contract) where the Codec would raise `FunctionClauseError`. |

## Disk-Full Handling

**Contract:** disk-full-class write errors — `SQLITE_FULL` (13), `SQLITE_IOERR` (10), `SQLITE_READONLY` (8) — are converted at the write boundary to `{:error, :disk_full}` instead of crashing the GenServer. Reads keep working; writes can be retried (a full disk is transient, unlike a corrupt DB). Every other write error re-raises and crashes the GenServer; the supervisor restarts it with a fresh repo instance.

- **Where**: the facade's `write_call/2` choke point wraps `put_task`, `delete_task`, `delete_tasks`, `clear_tasks`, `update_lease_expires_at`, `update_task_columns`, `delete_project`. `Operations.Projects.put_project` protects itself (returns the tuple directly — never double-wrapped). `put_task`/`put_project` also return `{:error, :missing_task_id | :missing_task_status | :invalid_project_struct}`-style validation tuples before any write.
- **Classification** (`Errors.disk_full_exception?/1`): the `XqliteEcto3` adapter RAISES `%XqliteEcto3.Error{message, statement, type, details}` — matched are `type: :sqlite_failure` with `details.code` in 8/10/13, `type: :read_only_database`, and a message-text fallback (details/top-level message, downcased, containing "database or disk is full"). Trigger `RAISE`s are NOT matched (SQLite reports them as `SQLITE_CONSTRAINT_TRIGGER` code 19 → constraint-violation shape → crash, never a misclassification).
- **Caller degradation** (TaskRegistry + Cleanup): `start_task` put → log + continue in-memory; `force_kill_task`/`cancel_task` pending/`clear_finished_tasks` → `{:error, :disk_full}`; casts (`append_log`, review-status/metadata, heartbeat) → fire-and-forget log; terminal-status writes → log, in-memory cleanup still runs. Full table: `task_registry/CONTEXT.md`.

## Heavy-Read Offload

`select_all_tasks`, `safe_select_paginated_tasks`, `select_tasks_summary`, `select_tasks_summary_by_path`, `select_tasks_changed_since`, `safe_select_all_tasks` run query AND decode inside a short-lived LINKED `Task.start` via the private `offload/3` (replies via `GenServer.reply/2`, `{:noreply, state}` immediately) — large decoded terms never inflate the GenServer heap. Every Operations function binds the repo through `RepoScope.with_repo/2` in the CALLING process, so the offloaded work addresses the correct instance from the Task's own process. The link preserves crash-on-raise. **Offload isolates the HEAP, not concurrency**: every offloaded read still borrows the store's single `pool_size: 1` connection, so it serializes at the connection level with all other store SQL (inline handlers, the TaskRegistry heartbeat's lease writes, other queries) — the offload never adds read parallelism. `select_task_paths` (`../store.ex` :530) is NOT offloaded — it runs inline in the facade, blocking the facade GenServer for the query's duration. Single-row/tiny handlers (`get_task`, `select_task_logs`, `select_task_update_info`, `get_task_status`, `get_project`, id-only projections, counts, `size`, projects ≤10 rows) stay synchronous. Caller's 30s `@call_timeout` unchanged.

## Measured Performance Profile

Measured read-only against a COPY of the live `tasks.sqlite` (854 rows, 29.7 MB, 751 of them `:completed`; `result` avg 17.6 KB / max 3.5 MB, `archive_metadata` avg 14.5 KB / max 3.5 MB, `opts` avg 2.1 KB / max 209 KB, `logs` always `[]`) through the real `EvoGit.Store`/`EvoGit.TaskRegistry` stack, warm cache, median of repeated runs.

| Operation | median |
|---|---|
| unfiltered page SQL `SELECT * … ORDER BY started_at DESC LIMIT 25` | 0.30 ms |
| `Codec.decode_task/1` × 25 (current page, ≈4 KB blobs/row) | 0.92 ms |
| `list_tasks_paginated` page 1 with the dashboard's default filters | 1.4 ms |
| `SELECT count(*)` (no WHERE) | 0.005 ms |
| `SELECT DISTINCT project_path` (`get_unique_paths`) | 0.12 ms |
| sidebar `list_tasks_summary([:running, :pending, :finalizing, :cancelling, :completed])` (752 rows) | 20 ms |
| page with `status: "completed"` (751 rows match) | **156 ms** (302 ms with `temp_store: :file`) |
| page with `search:` matching few rows (4-column OR-LIKE) | 17–28 ms |
| page at `offset: 829` (oldest 25 rows — the multi-MB blobs) | 37 ms |
| page `status: "failed"` (71 rows) / `review_status: "merged"` (440) / `review_status: "pending"` (0) | 2.0 / 2.2 / 0.56 ms |
| `Codec.decode_task/1` × 25 widest rows (3.5 MB blobs/row) | 160 ms |
| `put_task` small row / row carrying a 3.5 MB `result` | 0.31 / 137 ms |
| `update_lease_expires_at` (heartbeat) / `update_task_columns` small | 0.05 / 0.08 ms |

- **The former dominant read cost — any `status = <value matching most rows>` filter — is index-served since migration 3** (`20260815000003_composite_indexes`). Baseline `idx_tasks_status` led with `status` but did not carry `started_at`, so the planner used `SEARCH tasks USING INDEX idx_tasks_status (status=?)` + `USE TEMP B-TREE FOR ORDER BY` and the sorter materialized the FULL 20-column projection of EVERY matching row (≈25 MB of blobs for `"completed"`) before `LIMIT 25` applied → the 156 ms row in the table above (cost scales with matching-rows × bytes-of-selected-columns: only `id, started_at` = 0.42 ms, 12 columns incl. `opts` = 5.7 ms, all 20 = 300 ms). `idx_tasks_status_started_at` `(status, started_at)` now seeks the status bucket and reads the page straight out of the index in `started_at DESC` order — no temp B-tree, early exit at `LIMIT + OFFSET`; `idx_tasks_project_path_started_at` does the same for the `project_path` filter (dashboard project filter + `list_tasks_by_path/1`) and is the index the planner picks for the combined `status + project_path` shape. Measured on a 900-row synthetic copy of the live shape (800 `completed`, ~15 KB avg / 2 MB max `result`): status page 1229 µs → 372 µs, path page 742 µs → 357 µs, status page at `OFFSET 700` 58 ms → 3.6 ms, the `review_status: "pending"` composite predicate 1184 µs → 366 µs — all four with no `USE TEMP B-TREE FOR ORDER BY`; the unfiltered page keeps riding `idx_tasks_started_at`. The one read cost a `status`/`project_path` index cannot fix remains the `:search` filter (4-column OR-LIKE → full `SCAN tasks` for both statements), and the unsolved `select:` projection: the paginated path still loads and decodes all 20 columns.
- **The largest recurring dashboard cost is the sidebar active-task summary**: the dashboard's `@active_statuses` (`apps/evo_dash/.../live_hooks/node_aware.ex`) includes `:completed`, so 752/854 rows match → 20 ms per fetch (~5.5 ms SQL + ~11 ms Elixir decode, 8.75 ms of which is `Jason.decode` of `opts`). It fires on every connected page mount (async, but on the same single DB connection) and on every 300 ms-debounced `"tasks"` PubSub event.
- **ONE connection for everything**: `Boot.start_dynamic/1` (`./boot.ex` :100) always passes `pool_size: 1`, so `repo.ex`'s `pool_size: 2` fallback never applies in production — every query (inline handlers, offloaded read Tasks, writes, migrations) borrows the SAME pooled SQLite connection and serializes at the connection level, not just at the GenServer; WAL buys no reader/writer parallelism with one connection. Measured head-of-line blocking: a plain page load is 1.4 ms quiet, 11.8 ms while the 20 ms sidebar summary is in flight, p99 207 ms with 10 queued search loads; under a 2 000-iteration heartbeat-writer loop p50 1.6 ms / max 13.7 ms.
- **`queue_target`/`queue_interval` are NOT configured** anywhere (`repo.ex`, `config/*.exs`); DBConnection defaults apply (`queue_target: 50` ms, `queue_interval: 2_000` ms — `deps/db_connection/lib/db_connection.ex:476-490`). With one connection, a checkout wait beyond the (adaptive) target makes the pool DROP the request with `DBConnection.ConnectionError` ("connection not available and request was dropped from queue after Nms") rather than waiting for the caller's 30 s store timeout.
- Connection PRAGMAs/config: `repo.ex` `defaults/0` (:85-95) = `journal_mode: :wal`, `synchronous: :normal`, `busy_timeout: 30_000` (adapter default 5_000), `pool_size: 2`, `default_transaction_mode: :immediate`, `timeout: 30_000`, `ownership_timeout: 30_000`; adapter defaults add `cache_size: -64_000` (64 MiB page cache) + `temp_store: :memory` (`deps/xqlite_ecto3/lib/xqlite_ecto3/connection.ex:26-31`) — `temp_store: :memory` roughly halves the filtered-page sort cost (156 vs 302 ms). No `wal_autocheckpoint`, `mmap_size`, `ANALYZE` or `PRAGMA optimize` tuning exists anywhere in the app, so there is no `sqlite_stat1` for the planner.
- **The paginated path loads and decodes FULL rows**: `Operations.Tasks.safe_select_paginated_tasks/2` (`./operations/tasks.ex` :241-265) builds `from(t in TaskRowRaw)` with NO `select:` projection, so all 20 columns (incl. `result`, `logs`, `usage`, `archive_metadata`) are read for every row of the page, then each row runs `Codec.decode_task/1` (:536-558) = up to six `Jason.decode` calls per row (`opts`, `logs`, `result` + nested usage, `usage`, `archive_metadata`, `error`); undecodable rows are skipped + logged. `Summaries.summary_query/0` (the 16-key projection that deliberately omits `result`/`logs`/`usage`/`archive_metadata`) is used ONLY by `select_tasks_summary*` — the paginated path never uses it.
- **TWO SQL statements per page apply, and no per-row N+1**: the page SELECT `ORDER BY started_at DESC LIMIT ? OFFSET ?` (:247-256) plus a SEPARATE `COUNT(*)` re-applying the same filters (:258-261); a page-clamp refetch doubles both, and any page size costs exactly 2 statements. The COUNT itself is a covering-index scan (`SCAN tasks USING COVERING INDEX idx_tasks_lease_expires_at`) = 5 µs — never a bottleneck.
- **Filters**: the dashboard's `build_filters_from_assigns/1` always supplies `status: "all"`, `project_path: "all"`, `review_status: "all"`, `search: ""`, and `where_filters/2` (:443-449) drops every "all"/`""` clause. `review_status: "pending"` expands to the composite `status = 'completed' AND review_status IS NULL AND branch_name IS NOT NULL` (:463-475 — 0 matching rows on the live DB); a non-empty `:search` adds the ONE `fragment/1`, a 4-column OR-LIKE over `id`/`opts`/`project_path`/`result` with the escape char pinned as a parameter (:476-503) → `SCAN tasks` for BOTH statements, and the COUNT cannot early-exit so it scans every blob row.
- **`get_unique_paths`** = `SELECT DISTINCT project_path FROM tasks WHERE project_path IS NOT NULL` (`lightweight.ex:76-86`; `idx_tasks_project_path` lets SQLite dedupe by index scan) — 0.12 ms, but it runs on EVERY page apply and is NOT offloaded (`store.ex:530-532`), so it blocks the Store GenServer for the query's duration.
- Facade handlers that are NOT offloaded (block the Store GenServer for the whole query): `select_task_paths`, `select_finished_task_ids`, `select_task_ids`, `select_running_lease_info`, `select_cleanup_info/1,3`, `count_tasks`, `size`, every single-row read, and every write.
- **Writes are NOT offloaded either** — `put_task`, `delete_tasks`, `clear_tasks`, `update_task_columns`, `update_lease_expires_at` execute inline in the Store GenServer via `write_call/2` (`store.ex:476-478`, `722-732`), on the same process whose offloaded read Tasks are queued in its mailbox. Largest write bursts: `clear_finished_tasks` (all finished ids in 500-id chunks, `@delete_chunk_size`, `tasks.ex:82/154-164`) followed by `Cleanup.cleanup_expired_tasks/1` (5-min `:periodic_cleanup`: `select_cleanup_info/3` + chunked deletes, each chunk its own commit); `put_task` is a delete + full 20-column insert in one `:immediate` transaction (`tasks.ex:97-128`) and costs 137 ms when the row carries a 3.5 MB `result`. The 60 s heartbeat runs a `get_task_status` + `update_lease_expires_at` PAIR per owned task (`../task_registry.ex` :1575-1607).
- **Serialization chain (3 single-process layers, ONE DB connection)**: TaskRegistry GenServer (`list_tasks_paginated` is submitted there first → offload `Task` → `Store` GenServer → offload `Task` → repo) → Store GenServer → `XqliteEcto3` DBConnection with `pool_size: 1`. A page read can therefore wait behind any in-flight or queued write (heartbeat pair, status transitions, big `put_task` row replaces, delete/cleanup batches).
- **Offload isolates the HEAP, not concurrency** — see "Heavy-Read Offload".
- `tasks` indexes: the baseline six (`../../priv/repo/migrations/20260815000001_baseline_adoption.exs` :63-70) — `status`, `finished_at`, `lease_expires_at`, `project_path`, `updated_at`, `started_at` — plus the two composites from migration 3 (`20260815000003_composite_indexes`): `(status, started_at)` and `(project_path, started_at)`. NOTHING on `type`, `review_status`, or `branch_name` (no paginated query leads with them — see the migration's moduledoc for each exclusion), and no `(status, project_path, started_at)` (the planner reads the combined shape off the path composite instead).
- **Single DB access path**: no `EvoGit.Repo.*` caller exists outside this directory (`store.ex` + `Operations`) — confirmed by grep — so every statement in the app funnels through the Store GenServer (and, for dashboard/task reads, an extra TaskRegistry GenServer hop) onto that one connection.
- No read path in this directory shells out (no `System.cmd`/`Port.open`/`File.stat`): all `Suspicious` I/O is confined to the SQL/blob decode above.
- **Dead writer note**: `EvoGit.TaskRegistry.append_log/2` (`task_registry.ex:153`, handler `:764-788`, the read-modify-write of the whole `logs` column) has NO production caller (repo-wide grep) — no log-append write storm occurs; `logs` is only written as `[]` at task creation.

## Summary Projection Contract (16 keys)

`select_tasks_summary` / `select_tasks_summary_by_path` / `select_tasks_changed_since` return plain maps with EXACTLY: `id, status, review_status, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at, error`. `result` is deliberately never selected/decoded (heaviest per-row blob); `error` is the lenient 16th key (`Codec.decode_error/1` — `nil` for non-failed rows, never a crash); `updated_at` is the RAW fixed-precision ISO string. Undecodable rows (raising `opts` decode) are skipped + `Logger.warning`'d. No ORDER BY / LIMIT — consumers sort client-side.

## Constraints

- **Codec is the wire oracle**: `Types.*` and the Operations must DELEGATE, never re-implement, encode/decode logic — the `types_test.exs` oracle-equivalence tests pin byte-identity so drift fails loudly.
- **No `?N` SQL in store code**: all runtime access is `EvoGit.Repo.*` + `Ecto.Query`. Raw SQL exists ONLY inside the two migrations (via `repo().query!/3`, where in-body `PRAGMA` probing requires immediate execution). The ONE runtime `fragment/1` is `Operations.Tasks`' 4-column OR-LIKE search filter (`id/opts/project_path/result LIKE ? ESCAPE ?`) — LIKE-escaping cannot be expressed in Ecto.Query syntax; the escape char is pinned as a PARAMETER (a SQL literal `'\'` is doubled by the adapter and rejected by SQLite).
- **Crash philosophy**: no blanket try/rescue in `handle_call` — a failed statement raises out of the `EvoGit.Repo.*` call and crashes the GenServer. Deliberate boundaries: (1) the disk-full choke point; (2) the offloaded linked Task (crash-on-raise preserved via the link); (3) the per-row skip-and-log decode boundary inside the Operations (safe selects, summaries, paginated). Justified try/rescue: `terminate/2` and `write_call/2` only.
- **Writes through the TYPED schemas** (or `Codec.encode_*` directly); the raw twins are read-projection only.
- **Atom safety**: closed whitelists (`@known_atoms`, `@known_opt_keys`) — never `String.to_atom` on DB-sourced strings; unknown values stay strings / decode to nil.
- **Known-atom whitelists must stay in sync** with the application's valid status/review_status/type atoms.
- **Quarantine-free design**: no recovery tables, no per-start repair — undecodable rows are skipped + logged; SQLite WAL mode does not corrupt rows. The only startup integrity check is lease reconciliation (`select_running_lease_info` in `TaskRegistry.init/1`).
- **`store.ex` stays cohesive** — do not split the facade without a plan; new handlers dispatch to an Operations module in one line.

## Fixed-precision timestamps & canonical encodings (Codec wire rules)

- `encode_datetime/1` emits the constant 24-char fixed-ms ISO form (`%Y-%m-%dT%H:%M:%S.SSSZ` via `DateTime.truncate(:millisecond)`) — lexicographically sortable in SQLite, which is what makes SQL-side `ORDER BY started_at DESC` and `updated_at > ?` string comparisons correct. Legacy variable-precision rows are rewritten by the data-normalization migration at boot.
- **Result tuples** round-trip via the `__result_tag__` JSON discriminator (`ok`/`error`/`exit`/`string`); plain strings are always JSON-wrapped as the `"string"`-tag form so every `result` value is valid JSON. `decode_result/1` is STRICTLY canonical — nil + the 4 tagged forms only; raw strings, untagged JSON, invalid JSON, JSON null raise `ArgumentError`. Pre-canonical rows are rewritten at boot by the data-normalization migration.
- **Opts** encode as a JSON OBJECT with string keys (JSON-path addressable); `decode_opts/1` atomizes ONLY `@known_opt_keys` (`path mode prompt objective foreign_repos node_path starting_commit archive task_id repo_path concurrency tool_concurrency resume_from attachments`) — every other key stays a string. Non-object JSON raises. Legacy positional pair-array rows are rewritten at boot. Silent-drop risk: a non-Jason-encodable opt value falls back to the 4 essential keys ONLY.
- **`:foreign_repos` values** round-trip as STRING-keyed maps — normalize via `EvoGit.Core.ForeignRepo.normalize/1` before dot-access. The result `repos` map is deliberately NOT atomized by `decode_result` (read via `Map.get(decoded, "repos")`).
- **`error` payloads**: `decode_error/1` is lenient by design (nil/invalid/non-object → nil); known keys atomized via whitelist, closed-set values restored to atoms. Single producer: `TaskRegistry.Diagnostics.failure_error/3,4`.
- **`review_status`** is ONE flat task-level column (`:open | :merged | :rejected | :continued | :ignored | :no_changes` via the shared whitelist); no per-repo review state exists anywhere — writes go through the generic `update_task_columns(store, id, review_status: atom)`.
- **`updated_at`** is store-internal bookkeeping — deliberately NOT in `Codec.task_columns/0`/`%TaskInfo{}`; written by `put_task` and every `update_task_columns`, never by the lease heartbeat.

## Known Gaps

- **A data dir on a network/UNC path is accepted but unusable (Windows)**: `EvoGit.Platform.data_dir/0`'s `[data] dir` override validation (`absolute_path?/1`) accepts `\\server\share\...`, yet `Store.init/1` opens with `journal_mode: :wal` — SQLite's WAL needs the `-shm`/`-wal` shared-memory files, which network filesystems do not provide, so the open can fail and `init/1` returns `{:stop, {:failed_to_open_sqlite, reason}}` → the app never boots cleanly.
- **Store boot failure is fatal, not degraded**: `init/1` calls `File.mkdir_p!(dir)` (bang → raises on an unwritable `[data] dir`) and `{:stop, ...}` on a failed `Xqlite.open/2`, so a bad/unwritable/UNC data dir crash-loops the application instead of falling back to a default location.
- **`type` and `review_status` are unindexed, and there is no composite `(status, started_at)`** — indexed columns: `status`, `finished_at`, `lease_expires_at`, `project_path`, `updated_at`, `started_at`. `idx_tasks_started_at` makes the paginated list query's `ORDER BY started_at DESC` + `LIMIT`/`OFFSET` (the Ecto `order_by`/`limit`/`offset` in `Operations.Tasks.safe_select_paginated_tasks/2`, `./operations/tasks.ex` :247-256) O(page) ONLY for an unfiltered page (or a `review_status =` filter, which also resolves to `idx_tasks_started_at`); a `status = <value matching most rows>` filter instead forces `SEARCH … USING INDEX idx_tasks_status` + `USE TEMP B-TREE FOR ORDER BY`, materializing all 20 columns of every matching row — the measured dominant read cost (see "Measured Performance Profile"). The `:search` filter defeats every index (full `SCAN tasks`).
- **Search matches raw JSON text**: the `:search` filter is a 4-column OR-LIKE (`id`/`opts`/`project_path`/`result`, the ONE Ecto `fragment`), so hits depend on JSON key/string representation (e.g. underscores escaped) — a search matches only if the JSON text contains the value verbatim. The `result` column's JSON carries the final agent report under its `"result"` data key, making response-text fragments searchable.

## Routing Table

- `../store.ex` → `EvoGit.Store` — the GenServer facade (client API, dispatch, offload, disk-full choke point, `__repo_pid__` seam)
- `../repo.ex` → `EvoGit.Repo` — the Ecto repo (XqliteEcto3; unnamed dynamic instances; runtime `database:` resolution)
- `./codec.ex` → `EvoGit.Store.Codec` — the pure encode/decode oracle (no I/O)
- `./operations/` → `Tasks`, `Lightweight`, `Summaries`, `Projects`, `Safety` — all repo access, repo-pid-first
- `./schemas/` → `TaskRow`/`ProjectRow` (typed write) + `TaskRowRaw`/`ProjectRowRaw` (raw read projections)
- `./types/` → `task_timestamp.ex` (`TaskTimestamp`/`TaskTimestampRaw`/`UnixMs`), `atom_column.ex` (`AtomColumn` + named wrappers), `json_columns.ex` (`OptsJson`/`ResultJson`/`LogsJson`/`UsageJson`/`ArchiveJson`/`ErrorJson`)
- `./boot.ex` → `EvoGit.Store.Boot` — dynamic-repo boot + migration runner + `:global` lock
- `./repo_scope.ex` → `EvoGit.Store.RepoScope` — `with_repo/2` scoped binding
- `./errors.ex` → `EvoGit.Store.Errors` — disk-full classifiers (exception + NIF-tuple families)
- `../../priv/repo/migrations/` → the two Ecto migrations (baseline adoption + data normalization)
- `../../../test/evo_git/store/` → unit tests: `operations/` (one file per Operation), `types_test.exs` (Codec-oracle equivalence), `boot_migration_test.exs` (legacy-shape adoption), `boot_normalization_test.exs` (data rewrites), `repo_test.exs` (infra contracts), `repo_scope_test.exs`, `errors_test.exs`; stateful suites one level up: `store_test.exs`, `store_summary_test.exs`, `store_disk_full_test.exs`, `migrate_store_test.exs`
- `../task_registry/` → the consumer: lifecycle semantics, lease/heartbeat, disk-full caller degradation
