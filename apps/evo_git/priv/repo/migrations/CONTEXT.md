# Task-Store Ecto Migrations

## Intent
The complete Ecto migration chain for `tasks.sqlite`, run before any store read/write by `EvoGit.Store.Boot.run_migrations/1` (preloaded `[{version, module}]` source, `Ecto.Migrator.run(repo, source, :up, all: true)`, `:global` lock) — detail: `../../../../lib/evo_git/store/CONTEXT.md`.
Six contiguous versions (1..6); the chain is optimized for a NEW user's FIRST boot, so ALL schema-creating DDL lives in version 1 and every later version is a guarded no-op on a fresh database.

## Inventory at HEAD (6 files, versions 1,2,3,4,5,6)

| Version / file | Effect |
|---|---|
| `…000001_baseline_adoption` | The ONE schema-creating step: `CREATE TABLE IF NOT EXISTS tasks` with the FINAL 19 columns (no `archive_metadata`) + `projects`; per-column nullable `ALTER TABLE tasks ADD COLUMN` for the six legacy-missing columns (`lease_expires_at`, `model_id`, `project_path`, `branch_name`, `error`, `updated_at`); then the final six `idx_tasks_*` indexes; post-condition pins the 19 canonical columns (canonical order OR the adopted tail `…, branch_name, updated_at, error`), tolerating a legacy `archive_metadata` column (nullable TEXT, non-key) by removing it from the observed set first. |
| `…000002_data_normalization` | Data rewrites only: timestamp normalization, `result` → tagged JSON, legacy pair-array `opts` → objects (in Elixir), `branch_name`/`updated_at` backfills, drops `tasks_quarantine`/`projects_quarantine`. |
| `…000003_composite_indexes` | SHIPPED (v0.13.8, never renumbered): the two `(equality column, started_at)` composites `idx_tasks_status_started_at` / `idx_tasks_project_path_started_at` + a `PRAGMA index_info` post-condition; idempotent, so on a fresh database version 1 already created both and this is a no-op. |
| `…000004_covering_indexes` | The two covering indexes `idx_tasks_status_updated_at_id` `(status, updated_at, id)` and `idx_tasks_finished_at_id` `(finished_at, id)` + a `PRAGMA index_info` post-condition; idempotent, so on a fresh database version 1 already created both and this is a no-op. |
| `…000005_task_agent_archives` | Creates `task_agent_archives` (23 columns, `repo_id` TEXT, `PRIMARY KEY (task_id, agent_id)`) + `task_agent_archives_task_depth_idx` + both shape post-conditions — the ONLY create site of that table; then, ONLY if `PRAGMA table_info(tasks)` still reports `archive_metadata`, fans each task's JSON array out into one row per agent (`INSERT OR REPLACE`), strips `data.archive_records` from `result` when that key is present, NULLs the column, checks convergence and drops the column (19-column `tasks` afterwards). |
| `…000006_prune_redundant_indexes` | Drops the four dead `tasks` indexes (`DROP INDEX IF EXISTS`) and asserts they are gone while all six final indexes exist, so an upgraded database provably converges; a pure no-op on a fresh database, which never created the four. |

## Version numbering

- The `2026081500000N` prefix is a SYNTHETIC fixed epoch, not a date: only the numeric order matters, because `Ecto.Migrator` sorts by the integer version.
- A shipped version number is an identity — NEVER renumber it (versions 1, 2 and 3 shipped in v0.13.8).
- A new migration MUST use a version above `202608150000003` and a module name no other file uses (`Ecto.Migrator.ensure_no_duplication!/1` keys on the module for a preloaded source).
- Migrations landing on top of a release are additive: add a new version, never fold new DDL into an already-shipped one.

## Rules for editing this directory

- Every migration is `up/0`-only (`down/0` never defined, because the data/schema changes are irreversible).
- No migration declares `disable_ddl_transaction`: each runs in its own Ecto transaction (`XqliteEcto3.supports_ddl_transaction?/0` is true, transaction timeout `:infinity`), so a crash leaves earlier versions committed and the chain resumes from the next one.
- Statements run through `repo().query!/3` in body order, never `Ecto.Migration.execute/1` (string commands queue until `flush/0`, so an in-body `PRAGMA` probe or `ALTER` would see the pre-migration state).
- Idempotency is per migration: `CREATE … IF NOT EXISTS` / `DROP INDEX IF EXISTS` + column-existence probes + post-conditions that raise `Ecto.MigrationError` (boot-fatal, and the only way a silent shape drift is caught).
- The per-statement timeout is the repo's 60 s, except payload-moving statements (the archive fan-out's reads/writes/drop), which pass `timeout: 600_000` because an archived agent's `result` can be tens of MiB.
- Load-bearing order: version 1 creates `tasks`/`projects` and the indexes AFTER the nullable `ALTER`s (several indexes reference just-added columns), and version 5 fans the legacy archive out BEFORE it drops the column (the fan-out reads `result`/`archive_metadata` of the same row).
- Only `task_agent_archives` is created outside version 1, and it is created in exactly ONE place (version 5) — never duplicate its DDL into the baseline.
- Data repairs for formats no release ever wrote are deliberately NOT part of the chain; see "Pre-release dev databases" below.

## The final `tasks` index set (six)

- `idx_tasks_updated_at` on `(updated_at)` — the `updated_at > ?` range read of `select_tasks_changed_since` and its summary siblings.
- `idx_tasks_started_at` on `(started_at)` — the UNFILTERED paginated page, `ORDER BY started_at DESC LIMIT/OFFSET`.
- `idx_tasks_status_started_at` on `(status, started_at)` — the status-filtered (and status + `review_status`) paginated page, served in `started_at` order with no temp B-tree.
- `idx_tasks_project_path_started_at` on `(project_path, started_at)` — the project-filtered page AND the `SELECT DISTINCT project_path` read, which scans it as a covering index.
- `idx_tasks_status_updated_at_id` on `(status, updated_at, id)` — `select_task_ids`/`select_finished_task_ids` answered entirely from the index (no row fetch into the blob-carrying row tail).
- `idx_tasks_finished_at_id` on `(finished_at, id)` — both `select_cleanup_info` legs (age cutoff + `ORDER BY finished_at DESC` count trim) as covering reads.
- `task_agent_archives_task_depth_idx` on `(task_id, depth, agent_id)` is the archive table's own index (untouched by the prune): the per-task roster seek + ordered scan and the `DELETE … WHERE task_id = ?` cascade.

## Dropped indexes (four)

- `idx_tasks_status` on `(status)` — an exact column prefix of `idx_tasks_status_started_at`, which is strictly more useful, so it can never win a plan.
- `idx_tasks_finished_at` on `(finished_at)` — an exact prefix of the covering `idx_tasks_finished_at_id`, which also answers the cleanup reads without a row fetch.
- `idx_tasks_project_path` on `(project_path)` — an exact prefix of `idx_tasks_project_path_started_at`, which covers the same reads plus the page order.
- `idx_tasks_lease_expires_at` on `(lease_expires_at)` — no statement filters or orders on that column (the lease reads constrain `status` or the primary key and compare expiry in Elixir), so it was pure write cost.

## Pre-release dev databases

- Pre-release dev databases are expected to be RESET rather than migrated, because a pre-release build stamped versions 5–9 with different meanings than this chain does (and their repair migrations are gone).
- A database stamped by a pre-release build that wrote `"z1:"` = `Base64(zlib(json))` rows keeps those payloads PACKED and unreadable (the unpack migration is gone, and `z1:` appears NOWHERE in `apps/evo_git/lib/`) — delete the file, because no released build ever wrote that format.
- A database whose `task_agent_archives` table was created by a pre-release build with an INTEGER `repo_id` keeps that shape (the rebuild migration is gone), and the INTEGER affinity coerces numeric-looking repo ids so the archive reads degrade — delete the file.

## Test fixtures (`apps/evo_git/test/evo_git/store/`)

- `v0138_upgrade_path_test.exs` — the released-v0.13.8 upgrade path through the real `Boot.run_migrations/1` on a raw pre-upgrade file.
- `boot_migration_test.exs` — pre-Ecto legacy files (no `schema_migrations`) booted through the real chain.
- `boot_migration_source_test.exs` — the preloaded `[{version, module}]` source (file discovery, ordering, module selection).
- `boot_normalization_test.exs` — version 2's rewrites on adopted legacy data.
- `archive_migration_test.exs` — version 5's archive table, fan-out, `archive_records` strip and column drop.
- `composite_index_test.exs` — version 3's two composites (emitted-SQL plans, DDL shape, post-condition).
- `covering_index_test.exs` — version 4's two covering indexes (emitted-SQL plans, DDL shape, post-condition).
- `test/evo_git/migrate_store_test.exs` — the whole chain on fresh and legacy files through `mix migrate.store`.
- `test/evo_git/store/repo_test.exs` — infra contracts (applied versions, the `tasks`/`projects`/archive shapes, the six `idx_tasks_*` indexes, `run_migrations/1` idempotency).
