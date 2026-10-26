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
- **Version-stamped, not per-boot**: only versions absent from `schema_migrations` run, so a release shipping no new migration is a pure no-op (`ensure_schema_migrations_table!` + one `schema_migrations` version read, and no per-migration output when nothing is pending).
- A fresh DB pays no scan cost; later boots pay only the `schema_migrations` check. `Ecto.Migrator` runs each migration AND its version stamp in ONE transaction (`XqliteEcto3.supports_ddl_transaction?` is `true`), so a SIGKILLed migration rolls back atomically.
- A DB locked by another process can stall a boot connection up to `busy_timeout: 30_000`; there are NO sleeps on the store/application boot path.

### Migration 1 — `20260815000001_baseline_adoption`

Baseline schema ADOPTION, on a fresh DB (tables via `CREATE TABLE IF NOT EXISTS`) and on ANY pre-Ecto legacy DB (no `schema_migrations` ⇒ version 0 ⇒ it runs):

- Per-column NULLABLE `ALTER TABLE tasks ADD COLUMN` for the six columns a legacy table may lack (`lease_expires_at, model_id, project_path, branch_name, error, updated_at`).
- The FINAL six `tasks` indexes (`CREATE INDEX IF NOT EXISTS`, AFTER the column ALTERs, since `idx_tasks_updated_at`/`idx_tasks_status_updated_at_id`/`idx_tasks_project_path_started_at` may reference just-added columns); migrations 3/4 re-state two of them each, deliberately idempotently.
- Post-condition: `tasks` carries EXACTLY the 19 canonical columns (names/types/notnull/pk) — `archive_metadata` is NOT part of the canonical shape — with physical order canonical OR the ACCEPTED adopted tail `…, branch_name, updated_at, error` (SQLite ALTERs only APPEND, and the legacy table ended in `updated_at`; order is functionally irrelevant — all queries are name-based).
- A pre-Ecto legacy DB may still carry the legacy `archive_metadata` column (the 19-column v0.9.0–v0.12.5 shape and the 20-column v0.13.8 shape both have it): the post-condition TOLERATES it (asserted to be a nullable TEXT non-key column, then removed from the observed spec set before the canonical comparison), and migration 5 fans it out and DROPs it.
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

### Migration 4 — `20260815000004_covering_indexes`

Additive DDL only: `idx_tasks_status_updated_at_id` on `(status, updated_at, id)` makes `select_task_ids/2` FULLY COVERING (a seek per `IN` value — no table access, blob pages or row decode) and turns the `select_task_ids([])`/`select_finished_task_ids/1` scans into covering-index scans; `idx_tasks_finished_at_id` on `(finished_at, id)` serves both `select_cleanup_info/1,3` legs (the age cutoff a covering seek, the count trim's `ORDER BY finished_at DESC` index-served — no temp B-tree, no per-row lookup).
Post-condition: `PRAGMA index_info` must report exactly the declared columns in order.
Not added: `(status, lease_expires_at, id)` (lease reads are tiny) and `type`/`review_status`/`branch_name`.

### Migration 5 — `20260815000005_task_agent_archives`

The ONE table created outside migration 1, plus its guarded legacy fan-out and the removal of the column it replaces.

- **The table**: the RELATIONAL per-agent archive `task_agent_archives` with `PRIMARY KEY (task_id, agent_id)` (the composite key makes a re-put an idempotent REPLACE) plus `task_agent_archives_task_depth_idx` on `(task_id, depth, agent_id)`.
  `task_id` (TEXT) / `agent_id` (INTEGER) are the PK parts; `depth` and `compression_count` are `NOT NULL DEFAULT 0`; `parent_id` is `INTEGER` while `repo_id` is `TEXT` (a repo ID STRING — `"primary"` or a foreign repo id — NEVER an index); `usage`/`llm_settings`/`agent_settings`/`foreign_repos` are plain JSON `TEXT`; `started_at`/`completed_at` are ISO-8601 `TEXT` stored as-is.
- **Post-conditions**: `PRAGMA table_info` must report exactly the 23 declared columns in order and `PRAGMA index_info` exactly the declared index columns (so an `IF NOT EXISTS` never silently keeps a same-named table/index of a different shape); `EXPLAIN QUERY PLAN` verifies the roster read (`WHERE task_id = ? ORDER BY depth, agent_id LIMIT/OFFSET`) and the per-task `count(*)` as a covering-index search with no temp B-tree, and the `DELETE … WHERE task_id = ?` uses the same index prefix.
- **Legacy fan-out (guarded by a `PRAGMA table_info(tasks)` probe)**: only when a pre-release database still carries `tasks.archive_metadata`, each task row with a non-empty archive is moved over — decode LENIENTLY (`Jason.decode/1`; a corrupt or non-list value is logged with the task id and SKIPPED, so one unreadable archive never wedges an upgrade), `INSERT OR REPLACE` exactly ONE row per record (`task_id` from the row, `agent_id` from the record, `depth`/`compression_count` defaulting to 0, the four JSON columns re-encoded with `Jason.encode!` — plain JSON, SQL NULL for a missing value, every other value copied VERBATIM and `repo_id` never cast), strip `data.archive_records` from `result` ONLY when present (an archive-free result stays byte-identical), then NULL that task's archive column. `updated_at` is NEVER touched.
- **Column drop**: `ALTER TABLE tasks DROP COLUMN archive_metadata` at the end, guarded by the same probe — nothing references it, so it is an O(1) schema-header edit. The post-condition asserts no non-skipped task still holds an archive value.
- **Idempotent / resumable**: DDL is `IF NOT EXISTS`, the composite-PK upsert can never duplicate an agent, each task clears its own archive only after its records are in the table, and both the fan-out and the drop short-circuit on the probe — a boot that crashed in between simply finishes.

### Migration 6 — `20260815000006_prune_redundant_indexes`

Drops the four `tasks` indexes no plan uses — `DROP INDEX IF EXISTS` for `idx_tasks_status`, `idx_tasks_finished_at`, `idx_tasks_project_path` (exact PREFIXES of the migration 3/4 composites) and `idx_tasks_lease_expires_at` (no statement filters or orders on that column) — then asserts the four are GONE and the six final `idx_tasks_*` are PRESENT.
A pure schema-header edit (no rebuild, no data rewrite) and a NO-OP on a fresh DB, which migration 1 created with only the final six.
Shapes of the six are pinned by the migrations that create them; this one only checks presence.

### Migration versions & ordering

The shipped versions are 1..6, CONTIGUOUS.
Version 1 is the ONE schema-creating step (both tables + the final six indexes); 3, 4 and 6 are pure no-ops on a fresh database (idempotent re-statements, then drops of indexes that were never created); version 5 is the ONLY table created outside version 1.
Version 5 must stay ABOVE 1 (its fan-out probes the `tasks` table version 1 creates) and version 6 must stay LAST, since it asserts the final six indexes exist and only then are all index-creating migrations guaranteed to have run.
Any future migration takes a version above `20260815000006`.

### Migration source & concurrent-boot serialization

The migrator is fed a PRE-LOADED source — `Boot.migration_source/0` returns `[{version, module}]` ascending — never the migrations DIRECTORY: it enumerates `Ecto.Migrator.migrations_path(@repo)` + `Path.wildcard("*.exs")` (via `Application.app_dir/2`, so every per-store instance reads the same directory), parses each `"NNN_name.exs"` basename like `Ecto.Migrator.extract_migration_info/1`, compiles it with `Code.compile_file/1` and picks the module exporting `__migration__/0` (none → `Ecto.MigrationError`).
The source is memoized in `:persistent_term`, so the `.exs` files compile at most ONCE per BEAM (a directory source would redefine the module and log `redefining module` on every run).
`Boot.run_migrations/1` wraps the run and the one-time compile in `:global.trans({{:evo_git_store_migrations, self()}, fun})` — a cluster-safe PRODUCTION lock (no test-side wrapper), since compiling the same module is not concurrency-safe and boots are not exclusive; the `self()` LockRequesterId makes it exclusive and the per-process pdict save/restore stays OUTSIDE the lock.

### `mix migrate.store` / `mix store.maintenance`
`Mix.Tasks.Migrate.Store` boots a private unnamed dynamic repo on the target DB (default `<data_dir>/tasks.sqlite`), runs `Boot.run_migrations/1` (the exact boot call), reports applied versions and stops the instance — normally a NO-OP, for manual verification of interrupted upgrades.
`mix store.maintenance [--data-dir PATH] [--vacuum] [--no-optimize]` boots a private `pool_size: 1` unnamed dynamic repo (never starting `:evo_git`), optionally switches `PRAGMA auto_vacuum = INCREMENTAL` (the header change takes effect only after the `VACUUM` the same flag runs), `VACUUM`s, and prints file size plus `page_size`/`page_count`/`freelist_count`/`auto_vacuum` before and after with a one-line reclaimed summary (`--optimize` ON by default). `VACUUM` never runs at boot.

## API Surface

### `EvoGit.Store` (`../store.ex`) — facade

Public API (all `GenServer.call`, 30 s timeout; `store \\ __MODULE__`): `put_task`, `get_task` (full `%TaskInfo{}` incl. `result`/`logs`), `get_task_lite`, `put_task_archive`, `list_task_archives/3`, `get_agent_archive/3`, `delete_task_archives/2`, `delete_task`, `delete_tasks` (500-id chunked), `clear_tasks`, `safe_select_paginated_tasks` (filters `status`/`project_path`/`review_status`/`search`, clamped limit 50/offset 0), `select_tasks_page` (same filters + last-page refetch, 16-key rows + `total`, limit default 25/max 50), `update_lease_expires_at` (never bumps `updated_at`), `update_task_columns` (ALWAYS bumps `updated_at`), `get_task_status`, `select_task_update_info`, `select_task_paths`, `select_finished_task_ids`, `select_task_ids`, `select_running_lease_info`, `select_cleanup_info/1,3`, `select_tasks_summary/3`, `select_tasks_summary_by_path/4`, `select_tasks_changed_since/1`, project CRUD (`put_project`, `get_project`, `delete_project`, `select_all_projects`, `count_projects`), safety (`safe_select_all_tasks`, `safe_select_all_projects`, `size`), and the `__repo_pid__/1` / `__writer__/1` seams.
`select_all_tasks/1`, `count_tasks/1` and `select_task_logs/2` are GONE at every layer (facade handler + `Operations.Tasks`); `safe_select_all_tasks/1` (skip-and-log, the only full-table task read) REMAINS. `start_link(data_dir:, name: \\ __MODULE__, pool_size: nil)`.

The LIGHTWEIGHT read API is ADD-ONLY (every pre-existing name/arity/default/timeout/shape untouched):

- `select_tasks_page(store \\ __MODULE__, opts)` → `%{rows: [16-key summary map], total: non_neg_integer}`; `opts` accepts `status:`, `project_path:`, `review_status:`, `search:`, `limit:` (clamped ≤ 50, default 25) and `offset:` (≥ 0), applies the same last-page refetch as `safe_select_paginated_tasks/2`, and never selects `result`/`logs`/`usage`.
- `get_task_lite(store \\ __MODULE__, task_id)` → `%EvoGit.TaskInfo{} | nil`, field-identical to `get_task/2` (the same `Codec.decode_task/1` over an 18-column projection), differing only in cost.

The PER-AGENT ARCHIVE API (`task_agent_archives`, see "Per-Agent Archive"):

- `put_task_archive(store \\ __MODULE__, entry)` → `:ok`; `{:error, :disk_full}`, or `{:error, :missing_task_id | :missing_agent_id | :invalid_entry}` before any write. WRITE offload.
- `list_task_archives(store \\ __MODULE__, task_id, opts \\ [])` → `%{entries: [STRING-KEYED map], total: non_neg_integer | nil}`, `ORDER BY depth ASC, agent_id ASC`; `:limit` default 100 clamped 1..1000, `:offset` ≥ 0 (past the end = EMPTY page, no last-page refetch); three projection opt-ins, each ABSENT (never `nil`) when off:
  `:include_results` (default `false` — the `result` column is NOT SELECTED and `"result"` is ABSENT from every entry), `:include_settings` (default `false` — the three export-only JSON columns `"llm_settings"`/`"agent_settings"`/`"foreign_repos"` are NOT SELECTED and their keys are ABSENT; the CSV/JSON export passes `true`), `:include_total` (default `true` — `false` skips the `count(*)` aggregate and answers `total: nil`, for a paged reader that already holds the first page's total).
  `"usage"` is NEVER withheld (every roster view shows token/cost figures), and a lean entry is a strict SUBSET of `get/3`'s full row. READ offload.
- `get_agent_archive(store \\ __MODULE__, task_id, agent_id)` → the FULL entry map (result included) or `nil`. READ offload.
- `delete_task_archives(store \\ __MODULE__, task_id)` → `:ok` (also for a task with no rows). WRITE offload.

The shared filter builder `Operations.Filters` (`where_filters/2` + the clamps) backs BOTH `safe_select_paginated_tasks/2` and `Operations.Pages`, so the two paged reads can never match different rows.

**Search contract**: the ONE runtime `fragment/1` LIKEs `id`, `opts`, `project_path`, `branch_name` only — `result` is deliberately NOT searched (a full-blob scan). A phrase that exists only in a task's final response text never matches; phrases in the objective (`opts`), the id, the project path and the branch name do.

### `EvoGit.Store.Operations.*` (`./operations/`)

| Module | Owns |
|---|---|
| `Tasks` | `put_task` (validate → ONE `:immediate` transaction: `delete_all` by id + `insert_all` of the FULL 19-key row — replace semantics, so every column the struct omits is NULLed; a changeset upsert would keep stale values), deletes, `clear_tasks`, `get_task`, `safe_select_paginated_tasks` (filters/clamps delegated to `Filters`), `update_lease_expires_at`, `update_task_columns`, narrow reads (`get_task_status` via `Codec.decode_status/1`, `select_task_update_info`); `delete_task/2`, `delete_tasks/2` and `clear_tasks/1` also delete the affected archive rows. Denormalizations ported verbatim from `Codec.encode_task/1`: `project_path` ← `opts[:path]`, `branch_name` ← an `{:ok, data}` result's `branch_name` (each only when the struct field is nil), `updated_at` ← now. `select_task_update_info/2` costs TWO round trips (typed `status`/`opts`/`finished_at` projection + a separate `TaskRowRaw` read of `lease_expires_at`) on the hot per-status-update path, not one. A `:failed` write also issues one extra `SELECT status` (`log_failed_write_if_transition/1`, only when the new status is `:failed`). |
| `Lightweight` | id/lease/cleanup projections through `TaskRowRaw`: `select_task_paths` (DISTINCT non-nil), `select_finished_task_ids` (literal `status NOT IN ('running','pending','cancelling')`), `select_task_ids/2` (statuses → TEXT pushdown, raw `updated_at`, `status` decoded via `Codec.decode_atom/1`, served by the covering `idx_tasks_status_updated_at_id`), `select_running_lease_info` (literal `IN ('running','finalizing','cancelling')`, raw unix-ms lease), `select_cleanup_info/1` (`%{id, finished_at}` maps) and `/3` (SQL pushdown: Q1 age-expired `finished_at < cutoff`, Q2 count trim `ORDER BY finished_at DESC OFFSET n`). No JSON blob column is ever selected. |
| `Summaries` | the three 16-key summary projections. `statuses` atoms → TEXT pushdown (`[]` = all); `since` a strict raw-string `updated_at >` compare; `project_path` exact equality; NO ORDER BY / LIMIT; per-row lenient decode (skip + log). `summary_query/0` + `decode_skipping_bad/1` are shared with `Pages`. |
| `Pages` | `select_tasks_page/2` (COUNT then the page SELECT over `Summaries.summary_query/0` + `Filters.where_filters/2` + `Summaries.where_renderable/1` on BOTH statements, `ORDER BY started_at DESC LIMIT/OFFSET`, last-page refetch) and `get_task_lite/2` (`%TaskInfo{}` via the same `Codec.decode_task/1` from the 18 decode-relevant columns). The page never selects `result`/`logs`/`usage`. |
| `Archives` | the relational per-agent archive: `put/2` (full-row idempotent `ON CONFLICT (task_id, agent_id) DO UPDATE` — replace semantics, omitted columns NULLed/reset — accepting both key spellings and validating the composite key first), `list/3` (limit default 100 clamped 1..1000, `:offset` ≥ 0, `:include_results`/`:include_settings` false ⇒ those columns never SELECTED and their keys ABSENT, `:include_total` false ⇒ `total: nil`), `get/3` (always the FULL row), and the cascade deletes `delete_by_task/2` / `delete_by_tasks/2` (500-id chunks) / `delete_all/1`. Row → entry translation lives in ONE place and yields STRING-KEYED maps; JSON columns decode through plain `Types.ArchiveColumns.*` (no Codec). |
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

The archived conversation is a RELATIONAL table, one row per `(task_id, agent_id)` — not a JSON blob on the task row; migration 5 creates the table, composite key and index.

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
**Index inventory (6 `idx_tasks_*` + 1 archive index)**: `idx_tasks_updated_at`, `idx_tasks_started_at`, `idx_tasks_status_started_at` `(status, started_at)`, `idx_tasks_project_path_started_at` `(project_path, started_at)`, `idx_tasks_status_updated_at_id` `(status, updated_at, id)` and `idx_tasks_finished_at_id` `(finished_at, id)`, plus `task_agent_archives_task_depth_idx` on `(task_id, depth, agent_id)` — nothing on `type`, `review_status`, `branch_name` or `lease_expires_at`, and no `(status, project_path, started_at)`.
Four redundant `tasks` indexes are never created and are DROPPED by migration 6 on an adopted legacy DB (they serve no current plan): `idx_tasks_lease_expires_at` (no statement filters on `lease_expires_at` — the lease sweep reads `status IN (…)` rows and compares in Elixir) and `idx_tasks_status` / `idx_tasks_finished_at` / `idx_tasks_project_path`, which are exact word-for-word PREFIXES of the composites.
Because `put_task` is delete + full-row insert, every task write maintains SIX index entries for six distinct access paths.
**Measured effect of the prune — a WAL/page-churn and plan-shape win, NOT a space win**: the index footprint goes ~96 KiB → 72 KiB at 200 MiB of data (indexes are a rounding error beside the payload), and `put_task` is PAYLOAD-dominated — ≈5–6 ms per write at 1 MiB, ≈58 ms at 8 MiB on bcachefs/NVMe, with the index count making NO measurable difference. The prune pays off in fewer WAL pages per write and in a smaller set of plans to keep honest; `mix store.maintenance --vacuum` is what reclaims the freed pages of an already-migrated DB.
**Maintenance**: `PRAGMA optimize` once per boot after the migrations (boot connection, best-effort, seam `:store_boot_optimize_fun`) and hourly via `EvoGit.Store.Maintenance` (best-effort, never raises when the store is restarting/absent), so `sqlite_stat1` tracks schema and data; `VACUUM` is never automatic.

## Summary Projection Contract (16 keys)

`select_tasks_summary` / `select_tasks_summary_by_path` / `select_tasks_changed_since` / `select_tasks_page` return plain maps with EXACTLY `id, status, review_status, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at, error`.
`result` is never selected/decoded (the heaviest per-row blob); `error` is the lenient 16th key (`Codec.decode_error/1` — `nil` for non-failed rows, never a crash); `updated_at` is the RAW fixed-precision ISO string; undecodable rows are skipped + `Logger.warning`'d. The three `select_tasks_summary*` reads have no ORDER BY/LIMIT (consumers sort client-side); `select_tasks_page` adds `ORDER BY started_at DESC` plus the clamped LIMIT/OFFSET.
**Count/page agreement (`Summaries.where_renderable/1`)**: the page read is only meaningful for rows a consumer can render, so `where_renderable/1` (`opts IS NULL OR (json_valid(opts) AND json_type(opts) = 'object')`) is appended to BOTH the `count(*)` and the page SELECT — `total` counts exactly the rows the pages can yield, and a page never reports a total larger than the rows it can walk. The predicate is the exact SQL twin of the Elixir skip rule: `decode_skipping_bad/1` skips a row only when `Codec.decode_opts/1` raises, and `decode_opts/1` raises for every non-object JSON value (array, scalar, invalid text) while accepting SQL NULL — hence `json_valid` AND `json_type = 'object'`, not the object test alone.

## Constraints

- **Codec is the wire oracle**: `Types.*` and the Operations must DELEGATE, never re-implement, encode/decode logic — the `types_test.exs` oracle-equivalence tests pin byte-identity so drift fails loudly.
- **No `?N` SQL in store code**: all runtime access is `EvoGit.Repo.*` + `Ecto.Query`; raw SQL exists only inside the six migrations (via `repo().query!/3`, where in-body `PRAGMA` probing needs immediate execution). The ONE runtime `fragment/1` is `Filters`' 4-column OR-LIKE search (`id`/`opts`/`project_path`/`branch_name` LIKE ? ESCAPE ?), with the escape char pinned as a PARAMETER (a SQL literal `'\'` is doubled by the adapter and rejected by SQLite).
- **Crash philosophy**: no blanket try/rescue on the write path — a failed write raises out of the `EvoGit.Repo.*` call and crashes the process running it (the writer), then the store. Deliberate boundaries: `write_call/2`, the failure-isolated read worker, the writer LINKED to the store, the per-row skip-and-log decode boundaries in the Operations, and `TaskRegistry.StoreGuard` at every synchronous registry→store call. Justified try/rescue: `terminate/2`, `write_call/2`, `start_offload_worker/2`.
- **A READ never takes down the store or its callers**: reads degrade to their own empty shape and `StoreGuard` catches the remaining store-process failures.
- **Writes go through the TYPED schemas** (or `Codec.encode_*` directly); the raw twins are read-projection only.
- **Atom safety**: closed whitelists (`@known_atoms`, `@known_opt_keys`) — never `String.to_atom` on DB-sourced strings; unknown values stay strings or decode to nil, and the whitelists must track the valid status/review_status/type atoms. Statuses additionally have a TOTAL decoder, `Codec.decode_status/1` (`nil` for absent | known atom | `{:unknown, raw}` + `Logger.warning`), and `store_invariants_test.exs` pins the whitelists against the persisted set.
- **Quarantine-free design**: no recovery tables, no per-start repair — undecodable rows are skipped + logged; the only startup integrity check is lease reconciliation (`select_running_lease_info` in `TaskRegistry.init/1`).
- **`store.ex` stays cohesive** — do not split the facade without a plan; new handlers dispatch to an Operations module in one line.

## Fixed-precision timestamps & canonical encodings (Codec wire rules)

- `encode_datetime/1` emits the constant 24-char fixed-ms ISO form (`%Y-%m-%dT%H:%M:%S.SSSZ` via `DateTime.truncate(:millisecond)`) — lexicographically sortable in SQLite, which makes SQL-side `ORDER BY started_at DESC` and `updated_at > ?` string comparisons correct; legacy variable-precision rows are rewritten by migration 2 at boot.
- **Result tuples** round-trip via the `__result_tag__` JSON discriminator (`ok`/`error`/`exit`/`string`); plain strings always become the `"string"` form, so every `result` is valid JSON. `decode_result/1` is STRICTLY canonical — nil plus the 4 tagged forms only; raw strings, untagged JSON, invalid JSON and JSON null raise `ArgumentError`.
- **Opts** encode as a JSON OBJECT with string keys (JSON-path addressable); `decode_opts/1` atomizes ONLY `@known_opt_keys` (`path mode prompt objective foreign_repos node_path starting_commit archive task_id repo_path concurrency tool_concurrency resume_from attachments quality_level model_id model_id_locked agent build_system merge_from merge_target`), every other key stays a string, non-object JSON raises, and a non-Jason-encodable opt value falls back to the 4 essential keys only.
- **`:foreign_repos` values** round-trip as STRING-keyed maps — normalize via `EvoGit.Core.ForeignRepo.normalize/1` before dot-access; the result `repos` map is deliberately NOT atomized by `decode_result` (read via `Map.get(decoded, "repos")`).
- **`error` payloads**: `decode_error/1` is lenient by design (nil/invalid/non-object → nil), known keys atomized via whitelist and closed-set values restored to atoms; the single producer is `TaskRegistry.Diagnostics.failure_error/3,4`.
- **`review_status`** is ONE flat task-level column (`:open | :merged | :rejected | :continued | :ignored | :no_changes` via the shared whitelist) and no per-repo review state exists anywhere — writes go through `update_task_columns(store, id, review_status: atom)`.
- **`updated_at`** is store-internal bookkeeping — NOT in `Codec.task_columns/0`/`%TaskInfo{}`; written by `put_task` and every `update_task_columns`, never by the lease heartbeat or a migration's maintenance rewrite.

## Known Issues

- **`tasks.id` and `projects.path` are NULLABLE TEXT primary keys**: `PRAGMA table_info` reports `notnull = 0` for both (SQLite only implies NOT NULL for INTEGER primary keys), so the DDL allows a NULL id that every read would then miss (all of them compare ids). Only hand-edited/adopted rows can produce one — `Codec.validate_task/1` and `Operations.Archives.validate_entry/1` reject a missing id before any write.
- **The same `%EvoGit.Agent.Usage{}` is stored TWICE per task**: embedded in an `{:ok, …}` result's `data.usage` and again in the `usage` column, so one `get_task/2` pays two JSON decodes of the same numbers and one `put_task/2` two encodes (the summary/page projections avoid it by never selecting either).
- **`put_task/2` rewrites the whole row by design** (delete + full 19-key insert): a single status change through the full-row path re-writes every column and all six index entries; the targeted `update_task_columns/3` path exists to avoid that.
- **The one-time data migrations cost O(rows)**: migration 5 decodes each archived task's array on a cold page cache (migration 2 rewrites every legacy opts/status form) — the slowest boots in the product, within the desktop shell's 90 s backend-readiness budget; freed pages return only via `mix store.maintenance --vacuum`.
- **The legacy full-row page read has no consumer in `apps/`**: `safe_select_paginated_tasks/2` is reachable only through the frozen RPC wrappers `TaskRegistry.list_tasks_paginated/1` / `list_tasks_by_path/1` (and their `RemoteAPI`/`RemoteNode`/`NodeContext` mirrors), which no `evo_dash` code calls — the dashboard reads `select_tasks_page/2` + `get_task_lite/2`. Same for the zero-caller facade reads `safe_select_all_tasks/1`, `clear_tasks/1`, `get_project/2`, `select_all_projects/1`, `count_projects/1` and `size/1` (tests are their only consumers).
- **A status value missing from `Codec.@known_atoms` is TOTALLED, not silently lost**: `Codec.decode_status/1` answers `{:unknown, raw}` plus a `Logger.warning` (and `nil` for an absent value), so `get_task_status/2` distinguishes "no such row" from "row holds a status this build does not know", while the typed `get_task/2` path still maps it to `:pending` (`decode_task`'s `|| :pending`) and the summary projections report `status: nil`.
The lease classifiers are CONSERVATIVE about it — `Lease.lease_renewable?/1` answers `true` and `Lease.leaked?/3` answers `false` for `{:unknown, _}`, so the 60 s heartbeat keeps renewing and the sweep never marks such a task `:failed` — pinned by `test/evo_git/store/store_invariants_test.exs`. Extend the whitelist in the same commit as any new status atom.
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
- `./types/` → `task_timestamp.ex`, `atom_column.ex`, `json_columns.ex` (`OptsJson`/`ResultJson`/`LogsJson`/`UsageJson`/`ErrorJson`), `archive_columns.ex` (plain-Jason `ArchiveUsageJson`/`ArchiveLlmSettingsJson`/`ArchiveAgentSettingsJson`/`ArchiveForeignReposJson`)
- `./boot.ex` → `EvoGit.Store.Boot` — dynamic-repo boot, migration runner, boot-time `PRAGMA optimize`, `:global` lock
- `./repo_scope.ex` → `EvoGit.Store.RepoScope` — `with_repo/2` scoped binding
- `./errors.ex` → `EvoGit.Store.Errors` — disk-full classifiers (exception + NIF-tuple families)
- `../../priv/repo/migrations/` → the six Ecto migrations: 1 baseline adoption (the ONE schema-creating step: both tables + the final six indexes), 2 data normalization, 3 composite indexes, 4 covering indexes, 5 `task_agent_archives` + its `(task_id, depth, agent_id)` index + guarded legacy archive fan-out + `archive_metadata` drop, 6 redundant-index prune
- `../../../lib/mix/tasks/` → `mix migrate.store` (migrator report) + `mix store.maintenance` (on-demand optimize/vacuum)
- `../task_registry/` → the consumer: lifecycle, lease/heartbeat, disk-full caller degradation, `StoreGuard`, the `put_task_archive/1` mirror
- `../../../test/evo_git/store/` → unit tests (`operations/` one file per Operation, `types_test.exs` Codec-oracle equivalence, `store_invariants_test.exs` (status/opt-key whitelists vs the persisted set, `{:unknown, raw}` end-to-end + lease conservatism), `boot_*_test.exs`, `archive_migration_test.exs`, `composite_index_test.exs`, `covering_index_test.exs`, `repo_test.exs`, `pool_size_test.exs`, `repo_scope_test.exs`, `errors_test.exs`, `task_page_api_test.exs` (page/roster `total` agreement), `read_fault_isolation_test.exs`, `store_write_offload_test.exs`, `maintenance_test.exs`) + stateful suites one level up (`store_test.exs`, `store_summary_test.exs`, `store_disk_full_test.exs`, `migrate_store_test.exs`)
