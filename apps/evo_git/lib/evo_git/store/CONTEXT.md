# EvoGit.Store — Ecto/SQLite Persistence Layer

## Intent

The task/project persistence layer of `:evo_git`, so the headless `genesis_remote` daemon carries full task history.
`EvoGit.Store` (`../store.ex`) is a THIN GenServer facade over a pure-Operations Ecto layer; the on-disk bytes are owned exclusively by `EvoGit.Store.Codec` (the wire oracle).
The public client API — names, arities, defaults, 30 s `@call_timeout`, return shapes — is a frozen contract extended ADD-ONLY; `lib/evo_git/task_registry.ex` and the `evo_dash` RPC surface call it untouched.

## Architecture (facade → Operations → Repo → schemas → Types → Codec)

`EvoGit.Store` (facade) → `Store.Operations.*` (repo pid FIRST arg) → `Store.RepoScope.with_repo/2` → `EvoGit.Repo.*` + `Ecto.Query` on an unnamed dynamic instance (XqliteEcto3) → `Schemas.TaskRow`/`ProjectRow` (typed, WRITE) or `TaskRowRaw`/`ProjectRowRaw` (raw, READ) → `Store.Types.*` (Ecto.Type, THIN delegation) → `Store.Codec` (the single encode/decode oracle).
- **Facade (`store.ex`)** owns only: the client API, one-line-per-handler `handle_call` dispatch, the read offload (`offload/5`), the WRITE offload (`offload_write/3`/`offload_raw_write/3`), the disk-full choke point (`write_call/2`), the `__repo_pid__/1` + `__writer__/1` test seams and `init/1`/`terminate/2`. No SQL lives here.
- **Writer (`writer.ex`)** — `EvoGit.Store.Writer`, LINKED to the store: writes stay strictly serialized in ARRIVAL order, replies arrive only AFTER the commit (read-after-write), each Operation binds the dynamic repo inside the writer's process (`RepoScope.with_repo/2`), and a failing statement kills the writer and — over the link — the store with the operation's own reason (the disk-full conversion stays in `write_call/2`, which runs in the writer). With writes serialized here, the connection pool is purely a READ-parallelism knob.
- **Operations** (`./operations/`) own every `EvoGit.Repo.*` + `Ecto.Query` call (see the Operations table): each public function takes the repo PID first and runs its body inside `RepoScope.with_repo/2`, so calls target THAT store's instance regardless of the calling process (offloaded read worker included).
- **Wire format**: the typed schemas dump/load through `Types.*`, which delegate verbatim to `Codec` — stored bytes are exactly what the Codec defines, never re-implemented.

## Dynamic-Repo Design

- **Per-store UNNAMED instances**: `init/1` boots via `Boot.start_dynamic(data_dir, pool_size: <opt>)`, an UNNAMED (`name: nil`) `EvoGit.Repo` instance, so many same-named `EvoGit.Store` GenServers (test isolation, multi-store) each own their own DB. `state = %{repo: pid, name: name, data_dir: path, writer: pid, offloads: %{}}` (`:data_dir` is the SQLite FILE path, parent `mkdir_p`'d; `:offloads` tracks in-flight read workers by monitor ref).
- **PID addressing via the process dictionary**: unnamed instances are addressed BY PID through `EvoGit.Repo.put_dynamic_repo/1` / `get_dynamic_repo/0`; a process with no binding addresses the canonical named instance. `RepoScope.with_repo(pid, fun)` binds for `fun`'s duration and ALWAYS restores the previous binding (raise/throw/exit safe, nesting composes).
- **Pool size — `Boot.default_pool_size/0` = 6**, overridable per store via `start_link(pool_size: n)` → `Boot.start_dynamic/2` (non-positive/non-integer raises `ArgumentError`). One connection belongs to the writer, so 6 gives five concurrent readers — enough for a dashboard page mount (paginated list + summary + changed-since + project count + a review diff read) without one cold read stalling the rest.
- **Connection tuning lives in `EvoGit.Repo.start_opts/0`**, passed as START OPTS by `Boot.start_dynamic/2` and by `mix store.maintenance`: `timeout: 60_000` (per-statement/checkout budget), `queue_target: 500`, `queue_interval: 5_000`, `cache_size: -8_000` (8 MiB page cache PER connection → ~47 MiB at pool 6), `temp_store: :memory`.
- **`EvoGit.Repo.config/0` does NOT report the effective tuning** — it re-runs `init/2` without the start opts and shows Ecto's `@defaults` (`timeout: 15_000`, `pool_size: 10`); the effective values are `start_opts/0`'s, while `defaults/0` keeps only keys Ecto does not override (`journal_mode: :wal`, `synchronous: :normal`, `busy_timeout: 30_000`, fallback `pool_size: 2`, `default_transaction_mode: :immediate`, `ownership_timeout: 30_000`).
- **Migrations run on a single-connection BOOT instance**: `start_dynamic/2` opens at `pool_size: 1`, migrates (plus one best-effort `PRAGMA optimize`), then — for `pool_size > 1` — releases that instance and reopens at the requested size (`reopen_pool/3`), so every pooled connection sees an already-migrated file; SQLite loads a connection's schema LAZILY and answers `PRAGMA index_list/…` from its cached (possibly empty) schema, so a pre-migration connection would report an EMPTY index list non-deterministically. A `pool_size: 1` store keeps the boot instance (`store_disk_full_test.exs` pins it — its `PRAGMA query_only` arm is CONNECTION-scoped).
- **Test seam**: `__repo_pid__/1` (`@doc false`) exposes the facade's dynamic repo instance — the sanctioned way for tests to reach the store's own connection (e.g. `XqliteEcto3.with_xqlite/2`).

## Boot & Migrations

`init/1` → `Boot.start_dynamic(data_dir, pool_size: <opt>)` runs the Ecto migrations in `../../priv/repo/migrations/` BEFORE any read/write (`Ecto.Migrator.run(repo, Boot.migration_source(), :up, all: true)` — a no-op on a current DB), so an existing user DB upgrades automatically on first start.
A repo-OPEN failure stops with `{:stop, {:failed_to_open_sqlite, reason}}`; a MIGRATION raise (e.g. the baseline post-condition rejecting a non-canonical `tasks` shape) propagates out of `init/1` and crashes the Store child (supervisor restart, then app-boot failure).
`terminate/2` reaps in-flight read workers, drains the writer and calls `Boot.stop(repo)` inside a justified try/rescue (terminate must never raise).

### Boot blocking profile (startup latency)

- `Boot.start_dynamic/2` and the migration run are SYNCHRONOUS inside `init/1` (boot repo → migrator → `PRAGMA optimize` → stop → reopen the pool → start the writer); no `handle_continue`/Task deferral, so the supervisor's child start BLOCKS until it returns.
- That blocks `EvoGit.Application.start/2` and — via the OTP dependency order — `EvoDashWeb.Endpoint`'s Bandit bind: **Store boot precedes the HTTP listener**, so a slow first-boot migration delays HTTP readiness (desktop probe budget: `desktop/src-tauri/CONTEXT.md` → "Backend Readiness Budgets & Launch Diagnostics").
- **Version-stamped, not per-boot**: only versions absent from `schema_migrations` run, so a release shipping no new migration is a pure no-op (`ensure_schema_migrations_table!` + a version read + one `Migrations already up` line).
- A fresh DB pays no scan cost; later boots pay only the `schema_migrations` check. `Ecto.Migrator` runs each migration AND its version stamp in ONE transaction (`XqliteEcto3.supports_ddl_transaction?` is `true`), so a SIGKILLed migration rolls back atomically.
- A DB locked by another process can stall a boot connection up to `busy_timeout: 30_000`; there are NO sleeps on the store/application boot path.

### Migration 1 — `20260815000001_baseline_adoption`

Baseline schema ADOPTION, on a fresh DB (tables via `CREATE TABLE IF NOT EXISTS`) and on ANY pre-Ecto legacy DB (no `schema_migrations` ⇒ version 0 ⇒ it runs):

- Per-column NULLABLE `ALTER TABLE tasks ADD COLUMN` for the six columns a legacy table may lack (`lease_expires_at, model_id, project_path, branch_name, error, updated_at`), then the 6 baseline indexes (`CREATE INDEX IF NOT EXISTS`; `idx_tasks_updated_at` references a just-added column).
- Post-condition: `tasks` carries EXACTLY the 20 canonical columns (names/types/notnull/pk); physical order is canonical OR the ACCEPTED adopted tail `…, branch_name, updated_at, error` (SQLite ALTERs only APPEND, and the legacy table ended in `updated_at`; order is functionally irrelevant — all queries are name-based).
- Every statement runs via `repo().query!/3`, never `Ecto.Migration.execute/1` (its string commands queue until `flush/0`, so an in-body `PRAGMA table_info` probe would see the pre-migration state). `up/0` only — rolling back an adoption would drop user data.

### Migration 2 — `20260815000002_data_normalization`

Idempotent DATA rewrites (guards leave normalized rows alone):

- **Timestamps**: `strftime('%Y-%m-%dT%H:%M:%fZ', col)` where `col NOT GLOB '*.[0-9][0-9][0-9]Z' AND julianday(col) IS NOT NULL` for `tasks.started_at`, `tasks.finished_at`, `projects.last_opened_at` (`tasks.updated_at` is only backfilled); unparseable/NULL rows skipped.
- **Results**: JSON literal `null` → SQL NULL; every other untagged value (raw non-JSON strings and untagged objects/arrays/scalars) wrapped verbatim as `{"__result_tag__":"string","value":…}` via `json_object`; already-tagged rows untouched.
- **Opts**: legacy positional `[key, value]` pair arrays → JSON objects, rewritten in ELIXIR (Jason) so JSON booleans survive (never `json_group_object`, which collapses them to SQLite integers); malformed rows untouched.
- **Backfills**: `branch_name` ← `json_extract(result, '$.data.branch_name')` only where NULL and the result tag is `ok`; `updated_at` ← `COALESCE(finished_at, started_at, now)` where NULL. Drops the DETS-era `tasks_quarantine`/`projects_quarantine` tables.

### Migration 3 — `20260815000003_composite_indexes`

Additive DDL only (`up/0`, no rebuild, no rewrite): the two `(equality column, started_at)` composites that make the paginated read index-served — `idx_tasks_status_started_at` on `(status, started_at)` and `idx_tasks_project_path_started_at` on `(project_path, started_at)`.
Post-condition: `PRAGMA index_info(<name>)` must report EXACTLY the declared columns in order (otherwise `IF NOT EXISTS` would silently keep a same-named index of a different shape).
Deliberately absent: `(status, project_path, started_at)` (never chosen; its middle column cannot serve a status-only query), `type`/`review_status`/`branch_name` (no paginated query leads with them), and `ANALYZE` (boot runs `PRAGMA optimize`).

### Migration 5 — `20260815000005_covering_indexes`

Additive DDL only: `idx_tasks_status_updated_at_id` on `(status, updated_at, id)` makes `select_task_ids/2` FULLY COVERING (a seek per `IN` value — no table access, blob pages or row decode) and turns the `select_task_ids([])`/`select_finished_task_ids/1` scans into covering-index scans; `idx_tasks_finished_at_id` on `(finished_at, id)` serves both `select_cleanup_info/1,3` legs (the age cutoff a covering seek, the count trim's `ORDER BY finished_at DESC` index-served — no temp B-tree, no per-row lookup).
Post-condition: `PRAGMA index_info` must report exactly the declared columns in order.
Not added: `(status, lease_expires_at, id)` (lease reads are tiny) and `type`/`review_status`/`branch_name`.

### Migration 6 — `20260815000006_unpack_abandoned_compressed_rows`

One-shot REPAIR (idempotent, `up/0`) for rows stored as a tagged `Base64(zlib(json))` envelope: it inflates every such value back into plain JSON text — for `result`, `logs` and the legacy archive column independently (the archive column is unpacked BEFORE migration 8 decodes it).
Per column it sweeps the ids whose value starts with the tag (`substr(col, 1, 3)`), reads ONE value at a time (a `result` can be tens of MiB, `timeout: 600_000` per statement) and `UPDATE`s exactly that column of that row — never `updated_at`; the base64/zlib helpers are LOCAL to the migration, with no `Codec` function involved.
Lenient: an undecodable payload is left EXACTLY as it was and logged (`Logger.warning`, task id + column, never the payload) and excluded from the post-condition, which asserts no value in those columns starts with the prefix.

### Migration 7 — `20260815000007_create_task_agent_archives`

Additive DDL only: the RELATIONAL per-agent archive `task_agent_archives` with `PRIMARY KEY (task_id, agent_id)` (the composite key makes a re-put an idempotent REPLACE) plus `task_agent_archives_task_depth_idx` on `(task_id, depth, agent_id)`.
`task_id`/`agent_id` are `NOT NULL`; `depth` and `compression_count` are `NOT NULL DEFAULT 0`; `parent_id` is `INTEGER` while `repo_id` is `TEXT` (a repo ID STRING — `"primary"` or a foreign repo id — NEVER an index); `usage`/`llm_settings`/`agent_settings`/`foreign_repos` are plain JSON `TEXT`; `started_at`/`completed_at` are ISO-8601 `TEXT` stored as-is.
Post-conditions: `PRAGMA table_info` must report exactly the 23 declared columns in order and `PRAGMA index_info` exactly the declared index columns.
`EXPLAIN QUERY PLAN` verifies the roster read (`WHERE task_id = ? ORDER BY depth, agent_id LIMIT/OFFSET`) and the per-task `count(*)` as `SEARCH … USING COVERING INDEX task_agent_archives_task_depth_idx (task_id=?)` with no temp B-tree, and the `DELETE … WHERE task_id = ?` uses the same index prefix.

### Migration 8 — `20260815000008_move_archives_to_table`

Fans the legacy archive JSON array out of the task row into the relational archive, then DROPs that column.
Per task row with a non-empty archive: decode LENIENTLY (`Jason.decode/1`; a corrupt or non-list value is logged with the task id and SKIPPED, so one unreadable archive never wedges an upgrade), `INSERT OR REPLACE` exactly ONE `task_agent_archives` row per record (`task_id` from the row, `agent_id` from the record, `depth`/`compression_count` defaulting to 0, the four JSON columns re-encoded with `Jason.encode!` — plain JSON, SQL NULL for a missing value, `repo_id` copied VERBATIM and never cast), strip the duplicated archive list from `result` ONLY when present (an archive-free result stays byte-identical), then NULL that task's archive column.
The column is then dropped (`ALTER TABLE tasks DROP COLUMN`, guarded by a `PRAGMA table_info` probe) — nothing references it, so it is an O(1) schema-header edit; `updated_at` is NEVER touched. Idempotent/resumable: the composite-PK upsert cannot duplicate an agent and each step converges on a re-run.

### Migration 9 — `20260815000009_normalize_task_agent_archives`

Canonical-SHAPE repair of `task_agent_archives` for databases whose table was created by a pre-release variant of migration 7 that declared `repo_id INTEGER`: INTEGER affinity coerces a numeric-looking TEXT value (`"123"`) to an integer, so the Ecto `:string` field fails to load and every archive read degrades to its empty shape.
Probe `PRAGMA table_info(task_agent_archives)`; the table absent → NO-OP, `repo_id` already `TEXT` (case-insensitive) → NO-OP, table present without a `repo_id` column → `Ecto.MigrationError`.
Otherwise ONE rebuild inside the migrator's per-migration transaction: `CREATE TABLE task_agent_archives_canonical` (the exact 23-column canonical DDL of migration 7), `INSERT … SELECT` every row with `CAST(repo_id AS TEXT)`, compare row counts (mismatch raises BEFORE the drop), `DROP TABLE`, `ALTER TABLE … RENAME`, recreate `task_agent_archives_task_depth_idx`; a `Logger.warning` names the rebuild and its row count.
Post-condition: `repo_id` is TEXT and the roster index reports exactly `(task_id, depth, agent_id)`; a re-run short-circuits on the first probe, so it is idempotent and can never lose a row.

### Migration versions & ordering

The shipped versions are 1, 2, 3, 5, 6, 7, 8 and 9; there is no version 4, so a FRESH database never carries a 004 `schema_migrations` row while an upgraded one may still list it (harmless — already applied).
Migration 6 MUST stay ABOVE migration 5: an index build WALKS the table, and on rows still carrying compressed blobs the `updated_at`/`id` columns sit after the overflow chains, so the walk crawls those pages.
Give any future index migration a version ABOVE `20260815000009`.
Migration 9 MUST stay ABOVE migration 8: it rebuilds the table migration 7 creates and migration 8 fills, so it must run after both.

### Migration source & concurrent-boot serialization

The migrator is fed a PRE-LOADED source — `Boot.migration_source/0` returns `[{version, module}]` ascending — never the migrations DIRECTORY: it enumerates `Ecto.Migrator.migrations_path(@repo)` + `Path.wildcard("*.exs")` (via `Application.app_dir/2`, so every per-store instance reads the same directory), parses each `"NNN_name.exs"` basename like `Ecto.Migrator.extract_migration_info/1`, compiles it with `Code.compile_file/1` and picks the module exporting `__migration__/0` (none → `Ecto.MigrationError`).
The source is memoized in `:persistent_term`, so the `.exs` files compile at most ONCE per BEAM (a directory source would redefine the module and log `redefining module` on every run).
`Boot.run_migrations/1` wraps the run and the one-time compile in `:global.trans({{:evo_git_store_migrations, self()}, fun})` — a cluster-safe PRODUCTION lock (no test-side wrapper), since compiling the same module is not concurrency-safe and boots are not exclusive; the `self()` LockRequesterId makes it exclusive and the per-process pdict save/restore stays OUTSIDE the lock.

### `mix migrate.store` / `mix store.maintenance`
`Mix.Tasks.Migrate.Store` boots a private unnamed dynamic repo on the target DB (default `<data_dir>/tasks.sqlite`), runs `Boot.run_migrations/1` (the exact boot call), reports applied versions and stops the instance — normally a NO-OP, for manual verification of interrupted upgrades.
`mix store.maintenance [--data-dir PATH] [--vacuum] [--no-optimize]` boots a private `pool_size: 1` unnamed dynamic repo (never starting `:evo_git`), optionally switches `PRAGMA auto_vacuum = INCREMENTAL` (the header change takes effect only after the `VACUUM` the same flag runs), `VACUUM`s, and prints file size plus `page_size`/`page_count`/`freelist_count`/`auto_vacuum` before and after with a one-line reclaimed summary (`--optimize` ON by default). `VACUUM` never runs at boot.

## API Surface

### `EvoGit.Store` (`../store.ex`) — facade

Public API (all `GenServer.call`, 30 s timeout; `store \\ __MODULE__`): `put_task`, `get_task` (full `%TaskInfo{}` incl. `result`/`logs`), `get_task_lite`, `put_task_archive`, `list_task_archives/3`, `get_agent_archive/3`, `delete_task_archives/2`, `delete_task`, `delete_tasks` (500-id chunked), `clear_tasks`, `select_all_tasks`, `count_tasks`, `safe_select_paginated_tasks` (filters `status`/`project_path`/`review_status`/`search`, clamped limit 50/offset 0), `select_tasks_page` (same filters + last-page refetch, 16-key rows + `total`, limit default 25/max 50), `update_lease_expires_at` (never bumps `updated_at`), `update_task_columns` (ALWAYS bumps `updated_at`), `get_task_status`, `select_task_logs`, `select_task_update_info`, `select_task_paths`, `select_finished_task_ids`, `select_task_ids`, `select_running_lease_info`, `select_cleanup_info/1,3`, `select_tasks_summary/3`, `select_tasks_summary_by_path/4`, `select_tasks_changed_since/1`, project CRUD (`put_project`, `get_project`, `delete_project`, `select_all_projects`, `count_projects`), safety (`safe_select_all_tasks`, `safe_select_all_projects`, `size`), and the `__repo_pid__/1` / `__writer__/1` seams. `start_link(data_dir:, name: \\ __MODULE__, pool_size: nil)`.

The LIGHTWEIGHT read API is ADD-ONLY (every pre-existing name/arity/default/timeout/shape untouched):

- `select_tasks_page(store \\ __MODULE__, opts)` → `%{rows: [16-key summary map], total: non_neg_integer}`; `opts` accepts `status:`, `project_path:`, `review_status:`, `search:`, `limit:` (clamped ≤ 50, default 25) and `offset:` (≥ 0), applies the same last-page refetch as `safe_select_paginated_tasks/2`, and never selects `result`/`logs`/`usage`.
- `get_task_lite(store \\ __MODULE__, task_id)` → `%EvoGit.TaskInfo{} | nil`, field-identical to `get_task/2` (the same `Codec.decode_task/1` over an 18-column projection), differing only in cost.

The PER-AGENT ARCHIVE API (`task_agent_archives`, see "Per-Agent Archive"):

- `put_task_archive(store \\ __MODULE__, entry)` → `:ok`; `{:error, :disk_full}`, or `{:error, :missing_task_id | :missing_agent_id | :invalid_entry}` before any write. WRITE offload.
- `list_task_archives(store \\ __MODULE__, task_id, opts \\ [])` → `%{entries: [STRING-KEYED map], total: non_neg_integer}`, `ORDER BY depth ASC, agent_id ASC`; `:limit` default 100 clamped 1..1000, `:offset` ≥ 0 (past the end = EMPTY page, no last-page refetch), `:include_results` default `false` ⇒ the `result` column is NOT SELECTED and `"result"` is ABSENT from every entry (not `nil`); `total` counts every row of the task. READ offload.
- `get_agent_archive(store \\ __MODULE__, task_id, agent_id)` → the FULL entry map (result included) or `nil`. READ offload.
- `delete_task_archives(store \\ __MODULE__, task_id)` → `:ok` (also for a task with no rows). WRITE offload.

The shared filter builder `Operations.Filters` (`where_filters/2` + the clamps) backs BOTH `safe_select_paginated_tasks/2` and `Operations.Pages`, so the two paged reads can never match different rows.

**Search contract**: the ONE runtime `fragment/1` LIKEs `id`, `opts`, `project_path`, `branch_name` only — `result` is deliberately NOT searched (a full-blob scan). A phrase that exists only in a task's final response text never matches; phrases in the objective (`opts`), the id, the project path and the branch name do.

### `EvoGit.Store.Operations.*` (`./operations/`)

| Module | Owns |
|---|---|
| `Tasks` | `put_task` (validate → ONE `:immediate` transaction: `delete_all` by id + `insert_all` of the FULL 19-key row — replace semantics, so every column the struct omits is NULLed; a changeset upsert would keep stale values), deletes, `clear_tasks`, `get_task`, `select_all_tasks`, `count_tasks`, `safe_select_paginated_tasks` (filters/clamps delegated to `Filters`), `update_lease_expires_at`, `update_task_columns`, narrow reads (`get_task_status`, `select_task_logs`, `select_task_update_info`); `delete_task/2`, `delete_tasks/2` and `clear_tasks/1` also delete the affected archive rows. Denormalizations ported verbatim from `Codec.encode_task/1`: `project_path` ← `opts[:path]`, `branch_name` ← an `{:ok, data}` result's `branch_name` (each only when the struct field is nil), `updated_at` ← now. `select_task_update_info/2` costs TWO round trips (typed `status`/`opts`/`finished_at` projection + a separate `TaskRowRaw` read of `lease_expires_at`) on the hot per-status-update path, not one. A `:failed` write also issues one extra `SELECT status` (`log_failed_write_if_transition/1`, only when the new status is `:failed`). |
| `Lightweight` | id/lease/cleanup projections through `TaskRowRaw`: `select_task_paths` (DISTINCT non-nil), `select_finished_task_ids` (literal `status NOT IN ('running','pending','cancelling')`), `select_task_ids/2` (statuses → TEXT pushdown, raw `updated_at`, `status` decoded via `Codec.decode_atom/1`, served by the covering `idx_tasks_status_updated_at_id`), `select_running_lease_info` (literal `IN ('running','finalizing','cancelling')`, raw unix-ms lease), `select_cleanup_info/1` (`%{id, finished_at}` maps) and `/3` (SQL pushdown: Q1 age-expired `finished_at < cutoff`, Q2 count trim `ORDER BY finished_at DESC OFFSET n`). No JSON blob column is ever selected. |
| `Summaries` | the three 16-key summary projections. `statuses` atoms → TEXT pushdown (`[]` = all); `since` a strict raw-string `updated_at >` compare; `project_path` exact equality; NO ORDER BY / LIMIT; per-row lenient decode (skip + log). `summary_query/0` + `decode_skipping_bad/1` are shared with `Pages`. |
| `Pages` | `select_tasks_page/2` (COUNT then the page SELECT over `Summaries.summary_query/0` + `Filters.where_filters/2`, `ORDER BY started_at DESC LIMIT/OFFSET`, last-page refetch) and `get_task_lite/2` (`%TaskInfo{}` via the same `Codec.decode_task/1` from the 18 decode-relevant columns). The page never selects `result`/`logs`/`usage`. |
| `Archives` | the relational per-agent archive: `put/2` (full-row idempotent `ON CONFLICT (task_id, agent_id) DO UPDATE` — replace semantics, omitted columns NULLed/reset — accepting both key spellings and validating the composite key first), `list/3` (limit default 100 clamped 1..1000, `:offset` ≥ 0, `:include_results` false ⇒ `result` never SELECTED), `get/3`, and the cascade deletes `delete_by_task/2` / `delete_by_tasks/2` (500-id chunks) / `delete_all/1`. Row → entry translation lives in ONE place and yields STRING-KEYED maps; JSON columns decode through plain `Types.ArchiveColumns.*` (no Codec). |
| `Filters` | the ONE pagination WHERE builder + clamps: `where_filters/2` (`status`/`project_path`/`review_status` incl. the `"pending"` composite, plus `search` — the ONE Ecto `fragment`, escape char pinned as a parameter), `clamp_limit/1` (legacy default 50), `clamp_page_limit/1` (default 25, max 50) and `clamp_offset/1`. |
| `Projects` | project CRUD. `put_project` = DELETE + INSERT in one `:immediate` transaction (REPLACE semantics on the `path` TEXT PK) and owns its OWN disk-full rescue (returns `{:error, :disk_full}` directly, never double-wrapped). A NULL path never matches a row (`get_project` → nil, `delete_project` → `:ok` without DB access). |
| `Safety` | `safe_select_all_tasks/projects` (skip-and-log per-row decode through the RAW twins; a wrong-typed cell makes Ecto's loader raise inside `Repo.all/1` BEFORE the per-row boundary, so both fall back to reading rows one-at-a-time by PK — a corrupt row is skipped + logged, never a failed read) and `size` (SUM of both tables' row counts). |

### `EvoGit.Repo` / `Boot` / `RepoScope` / `Maintenance`

| Module | Purpose |
|---|---|
| `EvoGit.Repo` (`../repo.ex`) | `use Ecto.Repo, otp_app: :evo_git, adapter: XqliteEcto3` — NOT in the supervision tree; instances are owned by stores. `start_opts/0` states the effective tuning; runtime `init/2` resolves `database:` from start opts, falling back to `<data_dir>/tasks.sqlite`. |
| `EvoGit.Store.Boot` (`./boot.ex`) | `start_dynamic/2` (mkdir_p + unnamed repo + migrations on a single-connection boot instance + one best-effort `PRAGMA optimize`, then reopen at the requested `:pool_size`), `default_pool_size/0` (6), `run_migrations/1` (keyword = caller's binding, pid = scoped binding; global lock inside), `stop/1`, `migration_source/0` (the memoized pre-loaded `[{version, module}]` source, built by local helpers mirroring `Ecto.Migrator.load_migration!/1` — `load_migration_source/0` + `migration?/1`). |
| `EvoGit.Store.RepoScope` (`./repo_scope.ex`) | `with_repo(pid, fun)` — the scoped-addressing primitive for every read/write against an unnamed instance; pure, no I/O. |
| `EvoGit.Store.Maintenance` (`./maintenance.ex`) | Supervised periodic maintenance GenServer (app tree, right AFTER `EvoGit.Store`): `PRAGMA optimize` every 60 minutes, total by construction (defensive repo-pid resolution, `try/rescue` + `catch`, `Logger.warning`, timer always rescheduled), never `VACUUM`; `optimize/1` is shared with the boot-time call; test seams `tick/1` / `run/1` / `interval_ms/0`. |

### `EvoGit.Store.Codec` (`./codec.ex`) — the oracle

| Function | Description |
|----------|-------------|
| `task_columns/0` / `project_columns/0` | Ordered column-name lists (19 task cols — `updated_at` deliberately NOT among them; 3 project cols) |
| `encode_task/1` / `decode_task/1` | TOTAL encode (never raises) / struct decode (raises on bad data) |
| `encode_project/1` / `decode_project/1` | Same for `%RecentProject{}` |
| `validate_task/1` / `validate_project/1` | Structural validation used by the write paths |
| field-level | `encode_atom/1`/`decode_atom/1` (closed `@known_atoms` whitelist), `encode_datetime/1`/`decode_datetime/1`, `encode_result/1`/`decode_result/1`, `encode_usage/1`/`decode_usage/1`/`decode_usage_map/1`, `encode_logs/1`/`decode_logs/1`, `encode_error/1`/`decode_error/1` (lenient), `encode_opts/1`/`decode_opts/1` |
| no compression | every JSON column is plain UTF-8 JSON TEXT — no prefix-tagged payload, no zlib, no `try/rescue` |

## Storage Model — plain JSON text columns
`result`, `logs`, `opts`, `usage` and `error` are plain UTF-8 JSON TEXT — exactly what the encoder produced: no compression layer, no prefix-tagged payload, so a stored value is uniformly readable as JSON by plain SQL (`json_valid`, `json_extract`, `LIKE`).
`opts` is a plain JSON object so search can `LIKE` its raw text and SQL paths can `json_extract(opts, '$.path')`.
Decode strictness is unchanged: `decode_result/1` raises `ArgumentError` on anything but the 4 tagged forms, while lenient `decode_logs/1` → `[]` and `decode_error/1` → `nil` keep callers safe; `Types.*` stay thin delegations so the Codec remains the single wire oracle.

## Per-Agent Archive (`task_agent_archives`)

The archived conversation is a RELATIONAL table, one row per `(task_id, agent_id)` — not a JSON blob on the task row; migration 7 creates the table, composite key and index.

- **23 columns**, in order: `task_id` (TEXT PK), `agent_id` (INTEGER PK), `parent_id` (INTEGER), `depth` (INTEGER NOT NULL DEFAULT 0), `agent_type`, `context_node_path`, `objective`, `result`, `base_commit`, `final_commit`, `branch_name`, `archive_ref_start`, `archive_ref_final`, `repo_id` (TEXT — a repo ID STRING such as `"primary"`, never an index), `repo_root`, `repo_path`, `usage`, `llm_settings`, `agent_settings`, `foreign_repos`, `compression_count` (INTEGER NOT NULL DEFAULT 0), `started_at`, `completed_at` (ISO-8601 TEXT stored as-is).
- **Schema module** (`Schemas.TaskAgentArchiveRow`): `@primary_key false`, `primary_key: true` on `task_id`/`agent_id`, plain `:string`/`:integer` fields elsewhere, NO `timestamps()`.
- **Wire format** (`Types.ArchiveColumns.*`): `ArchiveUsageJson`, `ArchiveLlmSettingsJson`, `ArchiveAgentSettingsJson`, `ArchiveForeignReposJson` are PLAIN Jason — `Jason.encode/1` on dump (`nil` ⇔ SQL NULL, never the string `"null"`) and `Jason.decode/1` on load, where corrupt/non-JSON text loads as `nil` (one unreadable column never fails a read). Deliberately NOT the Codec: no `%EvoGit.Agent.Usage{}` struct, no magic prefixes.
- **Entry maps**: STRING-KEYED with the same 23 keys (minus `"result"` unless the read includes results), produced by ONE row → entry translation in `Operations.Archives`; writers accept atom- OR string-keyed maps (an atom key wins when both exist), so a read-modify-write round trip needs no reshaping.
- **Read split** (why the table exists): the dashboard pages the roster with `list_task_archives/3` (no `result` column) and lazily fetches the opened agent with `get_agent_archive/3`.
- **Write**: `put/2` is `ON CONFLICT (task_id, agent_id) DO UPDATE` over the FULL 23-column row — replace semantics (a re-put NULLs/resets what the entry omits) and idempotent (a retried or crash-recovered write can never duplicate an agent).
- **Producer / lifecycle**: the row is written STREAMING at AGENT COMPLETION by `EvoGit.Agent.Tools.CompleteTask.write_archive_refs/7` → `EvoGit.TaskRegistry.put_task_archive/1` → `EvoGit.Store.put_task_archive/2` — no in-memory buffer, no collection at task end, no archive anywhere in a task's `result`; a task start clears leftover rows for that task id (the scheduler's guarded `delete_task_archives/1`), so one run owns exactly one canonical archive set.
- **Deletes**: `Operations.Archives.delete_by_task/2` backs `delete_task_archives/2`, while `delete_by_tasks/2` (500-id chunks) and `delete_all/1` are the bulk primitives called by the task deletes — `Operations.Tasks.delete_task/2`, `delete_tasks/2` and `clear_tasks/1` delete their archive rows in the same transaction.
- **Fault isolation**: every read and write goes through the same facade offload/`write_call` path as the task reads (degraded `%{entries: [], total: 0}` / `nil`; writes `:ok` / `{:error, :disk_full}` / crash).
- **Tests**: `../test/evo_git/store/operations/archives_test.exs` pins every column's round trip (`repo_id` as the repo id STRING `"primary"`/`"cowboy"` — an integer-shaped input stored as decimal TEXT, a non-string/non-integer one rejected), nil-JSON/timestamp preservation, idempotent replaces, both key spellings, depth-then-agent ordering, limit/offset + total, the 100/1/1000 clamps, the absent `"result"` key and the deletes (operations AND facade).

## Disk-Full Handling

**Contract:** disk-full-class write errors — `SQLITE_FULL` (13), `SQLITE_IOERR` (10), `SQLITE_READONLY` (8) — are converted at the write boundary to `{:error, :disk_full}` instead of crashing the GenServer (a full disk is transient, unlike a corrupt DB): reads keep working and writes can be retried. Every other write error re-raises and crashes the GenServer (the supervisor restarts it with a fresh repo instance).

- **Where**: `write_call/2` wraps `put_task`, `delete_task`, `delete_tasks`, `clear_tasks`, `update_lease_expires_at`, `update_task_columns`, `delete_project`, `put_task_archive` and `delete_task_archives`; its closure runs in the writer, so the adapter raise and the conversion both happen where the write runs. `Operations.Projects.put_project` protects itself (returns the tuple directly, never double-wrapped). `put_task`/`put_project` also return `{:error, :missing_task_id | :missing_task_status | :invalid_project_struct}`-style validation tuples before any write.
- **Classification** (`Errors.disk_full_exception?/1`): the `XqliteEcto3` adapter RAISES `%XqliteEcto3.Error{message, statement, type, details}`; matched are `type: :sqlite_failure` with `details.code` in 8/10/13, `type: :read_only_database`, and a message-text fallback (details/top-level message, downcased, containing "database or disk is full"). Trigger `RAISE`s are NOT matched (`SQLITE_CONSTRAINT_TRIGGER` 19 → constraint shape → crash).
- **Caller degradation** (TaskRegistry + Cleanup): a failing `start_task` put logs and continues in-memory; `force_kill_task`/`cancel_task` (pending)/`clear_finished_tasks` return `{:error, :disk_full}`; casts (`append_log`, review-status/metadata, heartbeat) fire-and-forget; terminal-status writes log while in-memory cleanup still runs. Full table: `task_registry/CONTEXT.md`.

## Read Fault Isolation & Write Offload

**Every READ goes through `offload(from, state, op_name, degraded_value, fun)`** — one failure-isolated `spawn_monitor` worker per read (UNLINKED, tracked in `state.offloads`) that runs the query AND the decode and replies via `GenServer.reply/2`, so large decoded terms live and die on the worker's heap: a raise/exit/kill arrives as `:DOWN`, a spawn failure converts identically, and a worker wedged past the **25 s internal deadline** (`@offload_timeout`, below the caller's 30 s `@call_timeout`) is killed and answered with the degraded value — each logged at `:error` with the operation name + reason.
The FULL policy table lives in `store.ex`'s moduledoc ("Read degradation policy"); in one line, reads NEVER raise/exit/return `{:error, _}` — they return the empty value of their own shape: `nil` (single-row reads, incl. `get_agent_archive/3`), `[]` (list reads), `{[], 0}` (`safe_select_paginated_tasks`), `%{rows: [], total: 0}` (`select_tasks_page`), `%{entries: [], total: 0}` (`list_task_archives/3`), `0` (counts/`size`). The degraded value is passed EXPLICITLY per call site so table and handlers cannot drift, and `terminate/2` reaps any running worker (kill + cancel timer).

**Writer offload (writes)** — each write handler forwards its operation closure plus the ORIGINAL caller's `from` to `EvoGit.Store.Writer` and replies `{:noreply, state}` immediately, so a slow write (multi-megabyte `put_task`, chunked cleanup burst) cannot stall the facade mailbox while reads, counts and the 60 s lease heartbeat are served; the writer replies after the commit in strict arrival order. `put_task`/`put_task_archive`/`delete_task`/`delete_tasks`/`delete_task_archives`/`clear_tasks`/`update_lease_expires_at`/`update_task_columns`/`delete_project` use `offload_write/3`; `put_project` uses `offload_raw_write/3` (unwrapped — `Operations.Projects` owns its disk-full rescue). The writer is LINKED to the store, so a raising statement takes both down with the operation's reason; writes keep their contract (`:ok` / `{:error, :disk_full}` / crash).

**Caller-side containment (`EvoGit.TaskRegistry.StoreGuard`)** — the registry wraps every SYNCHRONOUS store call in `StoreGuard.read(op, degraded, fun)` / `StoreGuard.write(op, fun)`, catching `:exit`/raise/throw, logging at `:error` and degrading: reads to their documented empty value, writes to `{:error, :store_unavailable}`, which every call site handles exactly like `{:error, :disk_full}` — a Store crash (or an absent store at `TaskRegistry.init/1`) never kills the registry.

**Not offloaded**: the two test seams `__repo_pid__/1` / `__writer__/1` (plain replies, no repo access); everything else that reads a DB column goes through `offload/5`.

## Read-path profile & index inventory
**Query plans**: `select_task_ids` → `SEARCH … USING COVERING INDEX idx_tasks_status_updated_at_id`; the page `COUNT(*)` → a covering-index scan; the page SELECT → `idx_tasks_started_at` index-ordered, no temp B-tree, NOT covering; the archive roster read (`WHERE task_id = ? ORDER BY depth, agent_id LIMIT/OFFSET`), its per-task `count(*)` and `DELETE … WHERE task_id = ?` → `task_agent_archives_task_depth_idx`.
**What dominates reads**: the per-row `opts` JSON decode of a summary row, the legacy full-row page's `Codec.decode_task/1` of every blob column, and `select_tasks_summary/2` with `[]` (all statuses — a full table scan).
**Index inventory (10 `idx_tasks_*` + 1 archive index)**: baseline (`status`, `finished_at`, `lease_expires_at`, `project_path`, `updated_at`, `started_at`), migration 3's `(status, started_at)` + `(project_path, started_at)`, migration 5's `(status, updated_at, id)` + `(finished_at, id)`, and `task_agent_archives_task_depth_idx` on `(task_id, depth, agent_id)` — nothing on `type`, `review_status` or `branch_name`, and no `(status, project_path, started_at)`.
Four of the ten `tasks` indexes serve no current plan: `idx_tasks_lease_expires_at` (no statement filters on `lease_expires_at` — the lease sweep reads `status IN (…)` rows and compares in Elixir) and `idx_tasks_status` / `idx_tasks_finished_at` / `idx_tasks_project_path`, which are exact word-for-word PREFIXES of migration 3/5's composites.
Because `put_task` is delete + full-row insert, every task write maintains all ten entries for six distinct access paths — the one place a dropped index would directly cut write cost.
**Maintenance**: `PRAGMA optimize` once per boot after the migrations (boot connection, best-effort, seam `:store_boot_optimize_fun`) and hourly via `EvoGit.Store.Maintenance` (best-effort, never raises when the store is restarting/absent), so `sqlite_stat1` tracks schema and data; `VACUUM` is never automatic.

## Summary Projection Contract (16 keys)

`select_tasks_summary` / `select_tasks_summary_by_path` / `select_tasks_changed_since` / `select_tasks_page` return plain maps with EXACTLY `id, status, review_status, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at, error`.
`result` is never selected/decoded (the heaviest per-row blob); `error` is the lenient 16th key (`Codec.decode_error/1` — `nil` for non-failed rows, never a crash); `updated_at` is the RAW fixed-precision ISO string; undecodable rows are skipped + `Logger.warning`'d. The three `select_tasks_summary*` reads have no ORDER BY/LIMIT (consumers sort client-side); `select_tasks_page` adds `ORDER BY started_at DESC` plus the clamped LIMIT/OFFSET.

## Constraints

- **Codec is the wire oracle**: `Types.*` and the Operations must DELEGATE, never re-implement, encode/decode logic — the `types_test.exs` oracle-equivalence tests pin byte-identity so drift fails loudly.
- **No `?N` SQL in store code**: all runtime access is `EvoGit.Repo.*` + `Ecto.Query`; raw SQL exists only inside the eight migrations (via `repo().query!/3`, where in-body `PRAGMA` probing needs immediate execution). The ONE runtime `fragment/1` is `Filters`' 4-column OR-LIKE search (`id`/`opts`/`project_path`/`branch_name` LIKE ? ESCAPE ?), with the escape char pinned as a PARAMETER (a SQL literal `'\'` is doubled by the adapter and rejected by SQLite).
- **Crash philosophy**: no blanket try/rescue on the write path — a failed write raises out of the `EvoGit.Repo.*` call and crashes the process running it (the writer), then the store. Deliberate boundaries: `write_call/2`, the failure-isolated read worker, the writer LINKED to the store, the per-row skip-and-log decode boundaries in the Operations, and `TaskRegistry.StoreGuard` at every synchronous registry→store call. Justified try/rescue: `terminate/2`, `write_call/2`, `start_offload_worker/2`.
- **A READ never takes down the store or its callers**: reads degrade to their own empty shape and `StoreGuard` catches the remaining store-process failures.
- **Writes go through the TYPED schemas** (or `Codec.encode_*` directly); the raw twins are read-projection only.
- **Atom safety**: closed whitelists (`@known_atoms`, `@known_opt_keys`) — never `String.to_atom` on DB-sourced strings; unknown values stay strings or decode to nil, and the whitelists must track the valid status/review_status/type atoms.
- **Quarantine-free design**: no recovery tables, no per-start repair — undecodable rows are skipped + logged; the only startup integrity check is lease reconciliation (`select_running_lease_info` in `TaskRegistry.init/1`).
- **`store.ex` stays cohesive** — do not split the facade without a plan; new handlers dispatch to an Operations module in one line.

## Fixed-precision timestamps & canonical encodings (Codec wire rules)

- `encode_datetime/1` emits the constant 24-char fixed-ms ISO form (`%Y-%m-%dT%H:%M:%S.SSSZ` via `DateTime.truncate(:millisecond)`) — lexicographically sortable in SQLite, which makes SQL-side `ORDER BY started_at DESC` and `updated_at > ?` string comparisons correct; legacy variable-precision rows are rewritten by migration 2 at boot.
- **Result tuples** round-trip via the `__result_tag__` JSON discriminator (`ok`/`error`/`exit`/`string`); plain strings always become the `"string"` form, so every `result` is valid JSON. `decode_result/1` is STRICTLY canonical — nil plus the 4 tagged forms only; raw strings, untagged JSON, invalid JSON and JSON null raise `ArgumentError`.
- **Opts** encode as a JSON OBJECT with string keys (JSON-path addressable); `decode_opts/1` atomizes ONLY `@known_opt_keys` (`path mode prompt objective foreign_repos node_path starting_commit archive task_id repo_path concurrency tool_concurrency resume_from attachments quality_level`), every other key stays a string, non-object JSON raises, and a non-Jason-encodable opt value falls back to the 4 essential keys only.
- **`:foreign_repos` values** round-trip as STRING-keyed maps — normalize via `EvoGit.Core.ForeignRepo.normalize/1` before dot-access; the result `repos` map is deliberately NOT atomized by `decode_result` (read via `Map.get(decoded, "repos")`).
- **`error` payloads**: `decode_error/1` is lenient by design (nil/invalid/non-object → nil), known keys atomized via whitelist and closed-set values restored to atoms; the single producer is `TaskRegistry.Diagnostics.failure_error/3,4`.
- **`review_status`** is ONE flat task-level column (`:open | :merged | :rejected | :continued | :ignored | :no_changes` via the shared whitelist) and no per-repo review state exists anywhere — writes go through `update_task_columns(store, id, review_status: atom)`.
- **`updated_at`** is store-internal bookkeeping — NOT in `Codec.task_columns/0`/`%TaskInfo{}`; written by `put_task` and every `update_task_columns`, never by the lease heartbeat or a migration's maintenance rewrite.

## Known Issues

- **The one-time data migrations cost O(rows)**: migration 6 rewrites every legacy oversized value and migration 8 decodes each archived task's array on a cold page cache — the slowest boots in the product, within the desktop shell's 90 s backend-readiness budget; freed pages return only via `mix store.maintenance --vacuum`.
- **`evo_dash` still calls the legacy full-row page read** (`safe_select_paginated_tasks/2`); wiring it to `select_tasks_page/2` + `get_task_lite/2` is a later round, and one dashboard test (`apps/evo_dash/test/evo_dash_web/live/tasks_live_test.exs`, "search_tasks handler filters tasks by agent response message") still searches result text.
- **A multi-megabyte `result` row is decoded IN FULL by `get_task/2`**: nothing bounds the decoded term and `Codec.validate_task/1` checks only `id`/`status`, so a huge `result` is read whole (one `Repo.one/1` fetch, one `Jason.decode`, the `decode_result_data/1` rebuild); use `select_tasks_page/2`/`get_task_lite/2` when blobs are not needed.
- **No single-column index on `type`/`review_status`, and `:search` is unindexable**: no paginated query filters `type` (the dashboard drops `:reflect` rows CLIENT-side), `review_status: "pending"` is the composite `status = 'completed' AND review_status IS NULL AND branch_name IS NOT NULL` (no leading equality column; already served by `(status, started_at)`), an exact `review_status = <value>` filter rides `idx_tasks_started_at` with early exit, and the OR-LIKE forces a full `SCAN tasks` for BOTH statements.
- **Search hits depend on JSON text representation**: the OR-LIKE runs over `id`/`opts`/`project_path`/`branch_name`, so an `opts` hit needs its JSON key/string spelling (e.g. escaped underscores) — the JSON text must contain the value verbatim, and `result` is never searched.
- **Store boot failure is fatal, not degraded**: `init/1` calls `File.mkdir_p!/1` (bang → raises on an unwritable `[data] dir`) and `{:stop, {:failed_to_open_sqlite, reason}}` on a failed `Xqlite.open/2`, so a bad/unwritable data dir crash-loops the application instead of falling back.
- **A network/UNC data dir is accepted but unusable (Windows)**: `Platform.data_dir/0`'s `[data] dir` validation (`absolute_path?/1`) accepts `\\server\share\...`, yet `journal_mode: :wal` needs `-shm`/`-wal` shared-memory files a network filesystem does not provide, so the open can fail and hit the fatal boot path above.

## Routing Table

- `../store.ex` → `EvoGit.Store` — facade (client API, dispatch, read/write offload, disk-full choke point, test seams)
- `./writer.ex` → `EvoGit.Store.Writer` — dedicated writer process (arrival-order serialization, reply-after-commit, link crash propagation)
- `./maintenance.ex` → `EvoGit.Store.Maintenance` — hourly `PRAGMA optimize` (never `VACUUM`)
- `../repo.ex` → `EvoGit.Repo` — the Ecto repo (XqliteEcto3, unnamed dynamic instances, effective tuning in `start_opts/0`, runtime `database:` resolution)
- `./codec.ex` → `EvoGit.Store.Codec` — the pure encode/decode oracle (plain JSON TEXT, no compression)
- `./operations/` → `Tasks`, `Lightweight`, `Summaries`, `Pages`, `Archives`, `Filters`, `Projects`, `Safety` — all repo access
- `./schemas/` → `TaskRow`/`ProjectRow` (typed write) + `TaskRowRaw`/`ProjectRowRaw` (raw read projections) + `TaskAgentArchiveRow` (composite `(task_id, agent_id)` PK, no `timestamps()`)
- `./types/` → `task_timestamp.ex`, `atom_column.ex`, `json_columns.ex` (`OptsJson`/`ResultJson`/`LogsJson`/`UsageJson`/`ArchiveJson`/`ErrorJson`), `archive_columns.ex` (plain-Jason `ArchiveUsageJson`/`ArchiveLlmSettingsJson`/`ArchiveAgentSettingsJson`/`ArchiveForeignReposJson`)
- `./boot.ex` → `EvoGit.Store.Boot` — dynamic-repo boot, migration runner, boot-time `PRAGMA optimize`, `:global` lock
- `./repo_scope.ex` → `EvoGit.Store.RepoScope` — `with_repo/2` scoped binding
- `./errors.ex` → `EvoGit.Store.Errors` — disk-full classifiers (exception + NIF-tuple families)
- `../../priv/repo/migrations/` → the eight Ecto migrations: 1 baseline adoption, 2 data normalization, 3 composite indexes, 5 covering indexes, 6 legacy-format repair, 7 `task_agent_archives` + its `(task_id, depth, agent_id)` index, 8 archive fan-out + legacy archive column drop, 9 canonical-shape repair of `task_agent_archives` (TEXT `repo_id`)
- `../../../lib/mix/tasks/` → `mix migrate.store` (migrator report) + `mix store.maintenance` (on-demand optimize/vacuum)
- `../task_registry/` → the consumer: lifecycle, lease/heartbeat, disk-full caller degradation, `StoreGuard`, the `put_task_archive/1` mirror
- `../../../test/evo_git/store/` → unit tests (`operations/` one file per Operation, `types_test.exs` Codec-oracle equivalence, `boot_*_test.exs`, `archive_migration_test.exs` (migrations 6/8), `composite_index_test.exs`, `covering_index_test.exs`, `repo_test.exs`, `pool_size_test.exs`, `repo_scope_test.exs`, `errors_test.exs`, `task_page_api_test.exs`, `read_fault_isolation_test.exs`, `store_write_offload_test.exs`, `maintenance_test.exs`) + stateful suites one level up (`store_test.exs`, `store_summary_test.exs`, `store_disk_full_test.exs`, `migrate_store_test.exs`)
