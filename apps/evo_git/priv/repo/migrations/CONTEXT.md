# Task-Store Ecto Migrations

## Intent
The complete Ecto migration chain for `tasks.sqlite`, run before any store read/write by `EvoGit.Store.Boot.run_migrations/1` (preloaded `[{version, module}]` source, `Ecto.Migrator.run(repo, source, :up, all: true)`, `:global` lock) — detail: `../../../../lib/evo_git/store/CONTEXT.md` ("Boot blocking profile" + per-migration sections).

## Inventory at HEAD (8 files, versions 1,2,3,5,6,7,8,9)

| Version / file | Effect |
|---|---|
| `…000001_baseline_adoption` | `CREATE TABLE IF NOT EXISTS tasks` (20 cols incl. `archive_metadata`) + `projects`; per-column nullable `ALTER TABLE tasks ADD COLUMN` for the 6 legacy-missing columns; 6 baseline single-column indexes; post-condition pins exactly the 20 canonical columns (or the accepted tail `…, branch_name, updated_at, error`). |
| `…000002_data_normalization` | Data rewrites only: timestamp normalization, `result` → tagged JSON, legacy pair-array `opts` → objects (in Elixir), `branch_name`/`updated_at` backfills, drops `tasks_quarantine`/`projects_quarantine`. |
| `…000003_composite_indexes` | Adds `idx_tasks_status_started_at`, `idx_tasks_project_path_started_at`; `PRAGMA index_info` post-condition. |
| `…000005_covering_indexes` | Adds `idx_tasks_status_updated_at_id`, `idx_tasks_finished_at_id`; `PRAGMA index_info` post-condition. |
| `…000006_unpack_abandoned_compressed_rows` | One-shot repair of the abandoned `"z1:"` = `Base64(zlib(json))` format in `result`/`logs`/`archive_metadata`: sweep ids by `substr(col,1,3)`, read+inflate+write ONE row/column at a time, never `updated_at`; undecodable payloads logged and left as-is. |
| `…000007_create_task_agent_archives` | Creates `task_agent_archives` (23 columns, `PRIMARY KEY (task_id, agent_id)`, `repo_id` TEXT) + `task_agent_archives_task_depth_idx`; `PRAGMA table_info`/`index_info` post-conditions. |
| `…000008_move_archives_to_table` | Fans each `tasks.archive_metadata` JSON array into one `task_agent_archives` row per agent (`INSERT OR REPLACE`), strips `data.archive_records` from `result` only when present, NULLs the column, then `ALTER TABLE tasks DROP COLUMN archive_metadata` (probe-guarded) — 19 live `tasks` columns afterwards. |
| `…000009_normalize_task_agent_archives` | Probes `repo_id` affinity; rebuilds the archive table only when it is not `TEXT` (pre-release INTEGER variant) via create-copy-rowcount-check-drop-rename + index recreate; NO-OP on canonical/absent tables. |

## Rules for editing this directory

- Every migration is `up/0`-only (`down/0` never defined: the data/schema changes are irreversible), declares no `disable_ddl_transaction`, and runs in its own Ecto transaction (`XqliteEcto3.supports_ddl_transaction?/0` is true; transaction timeout `:infinity`), so a crash leaves earlier versions committed and the chain resumes.
- Statements run through `repo().query!/3` in body order, never `Ecto.Migration.execute/1` (string commands queue until `flush/0`, so in-body `PRAGMA` probes would see the pre-migration state).
- Idempotency is per migration: `IF NOT EXISTS` + probe guards + post-conditions that raise `Ecto.MigrationError` (boot-fatal). Per-statement timeout is the repo's 60 s; migrations 6, 8, 9 pass `timeout: 600_000` for multi-MiB payloads.
- Versions are data, not dates: the shipped set is 1,2,3,5,6,7,8,9 (no 4 — a dev DB may still hold a `20260815000004` row, which boot ignores). Any new migration MUST use a version above `20260815000009` and a module name not already used (`Ecto.Migrator.ensure_no_duplication!/1` keys on the module for a preloaded source).
- Load-bearing order: 6 before 8 (8's `Jason.decode` of `archive_metadata` fails on a still-packed value and would drop that task's archive with the column), 7 before 8, 8 before 9. 5 runs BEFORE 6, so the covering-index build walks rows still carrying the big/compressed blobs — there is no blob-shrinking step ahead of it any more.
- `000001` hard-codes 20 columns including `archive_metadata` while `000008` drops it: re-running 00001 on an already-migrated DB raises the post-condition. On a fresh DB the chain creates `archive_metadata` and drops it in the same boot (net-zero column).
- 3 baseline indexes (`idx_tasks_status`, `idx_tasks_finished_at`, `idx_tasks_project_path`) are column-prefixes of indexes added by 3/5 and are never dropped.

## Test fixtures (`../../../test/evo_git/store/`)
`boot_migration_test.exs` crafts pre-Ecto legacy files (15/17/19-column, no `schema_migrations`); `migrate_store_test.exs` runs the whole chain on fresh + legacy files; `archive_migration_test.exs` builds a 20-column pre-drop DB with `schema_migrations` stamped for every version EXCEPT the one under test; the index suites (`composite_index_test.exs`, `covering_index_test.exs`) boot HEAD-fresh template DBs and seed synthetic rows. No fixture reproduces a real v0.13.8 file (stamps 1,2,3 only) with the whole 5→9 set pending.
