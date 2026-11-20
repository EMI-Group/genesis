# evo_git/store — Test Tree

## Intent
Tests for the Ecto persistence layer use real unnamed dynamic `EvoGit.Repo` instances on isolated synthetic SQLite files.
The shipped migration chain contains exactly nine versions, `20260815000001` through `20260815000009`.
Boot runs ordinary pending migrations with `all: true`, with no development-ledger collision reconciliation or abandoned compression repair.
Clean and tagged-release upgrades retain migration 5's archive fan-out, result-duplicate stripping and source-column drop, and migration 7's project import, invalid-path skip, 100-newest cap and source-table drop.
Interrupted preservation objects fail closed before migrations rather than being restored or interpreted.

## Routing Table
- `operations/` → typed-schema operation tests for tasks, lightweight reads, summaries, pages, safety, archives and VCT mounts.
`operations/safety_test.exs` also pins the LOAD-failure fallback of `safe_select_all_tasks/1`: 133 rows with 3 wrong-typed cells (`agent_count` TEXT via a side `Xqlite` connection, straddling both 100-id chunks) return the 130 good rows in insertion order with ONE skip warning per poisoned row plus the single batch-load warning.
- `historical_sources_test.exs` → empty and unknown-shape `__genesis_historical_sources` markers, hidden `tasks.__genesis_preserved_archive_metadata`, hidden `__genesis_preserved_projects`, and combined remnants refuse `Boot.run_migrations/1` before ledger bootstrap or migration.
Repeated attempts preserve exact schema, ledger and source bytes both without a ledger and with versions 1–9 stamped.
- `boot_migration_test.exs` → fresh schema and raw pre-Ecto 15/17/19/20-column adoption, exact physical column order, nullable tail appends, healthy data preservation and final indexes.
- `boot_normalization_test.exs` → raw pre-boot values exercising timestamp, result and opts normalization, backfills and quarantine.
- `boot_migration_source_test.exs` → exactly nine preloaded ascending `{version, module}` pairs matching filenames, memoization, loaded modules and repeated boot without migration-module redefinition warnings.
- `archive_migration_test.exs` → migration 5 creates the 23-column archive table, fans out one row per agent, strips duplicated result archives and drops `archive_metadata`.
It pins partial fan-out idempotency, corrupt-source skip/log/dump behavior and unchanged `updated_at`.
- `vct_mounts_migration_test.exs` → ordinary legacy and tagged v0.14.1 upgrade paths, five-column VCT table, mount naming/deduplication, invalid-path skip, newest-100 cap and projects drop.
Unreadable project sources roll migration 7 back atomically with the source and pending ledger preserved.
- `v0138_upgrade_path_test.exs` → independent raw tagged v0.13.8 fixture stamped 1/2/3, pending migrations 4–9, exact final schema/indexes, archive fan-out/strip/drop, project import/drop, healthy rows and idempotent rerun.
- `canonical_schema_test.exs` → fresh nine-version chain, exact 21-column tasks and 23-column archive schemas, five-column VCT schema, final indexes and executed-SQL proof of no create-then-drop legacy objects.
A second boot emits only the migrator's own schema_migrations bootstrap DDL and changes no persisted schema or rows.
- `composite_index_test.exs` → migration 3 shapes, postconditions, filter/pagination correctness and generated-SQL query plans without temporary sorting.
- `covering_index_test.exs` → migration 4 shapes/postconditions and generated-SQL covering plans, with dropped-index non-vacuity checked on fresh connections.
- `repo_test.exs` → dynamic repo lifecycle, nine-version ledger, exact table/index inventory, idempotency, multi-instance isolation and connection PRAGMAs.
- `repo_scope_test.exs` → dynamic binding, nesting and restore-on-raise/throw/exit.
- `pool_size_test.exs` → default six-reader pool, explicit pool size, invalid-size rejection, checkout concurrency and migrated schema on every pooled connection.
- `task_page_api_test.exs` → facade arities and exact page/lite return shapes on isolated stores.
- `store_invariants_test.exs` → closed status/opt whitelists, atom/string data-plane key shapes, canonical model identity and unknown-status lease handling.
- `types_test.exs` and `errors_test.exs` → database-free codec/type and disk-full classifier matrices.
- `read_fault_isolation_test.exs` → read crash/deadline/spawn-failure documented degraded values, store survival and single facade log without OTP crash reports.
- `store_write_offload_test.exs` → linked per-store writer, reply-after-commit, strict arrival ordering, facade availability and unchanged disk-full/crash contracts.
- `maintenance_test.exs` → effective live connection budgets, one boot optimize, on-demand maintenance and maintenance task behavior.
- `awaiting_input_roundtrip_test.exs` → status and session-mode persistence through full/lite/page/summary/lease reads.
- `VALIDATION.md` → current validation commands and dependency blockers, not a normal-suite success claim.

## API Surface
Tests drive `Boot.start_dynamic/1,2`, `Boot.run_migrations/1`, `RepoScope.with_repo/2`, `Repo.query!/3`, Store facade calls and typed operation modules.
`PRAGMA table_info` assertions pin `[cid, name, type, notnull, default, pk]` exactly.
Summary/page rows have exactly 18 keys including `session_mode` and `pause_kind`, without heavy result blobs.
Archive rows are plain JSON-backed relational records keyed by `(task_id, agent_id)`, with TEXT `repo_id` and roster index `(task_id, depth, agent_id)`.

## Constraints
All modules are `async: true` except `maintenance_test.exs` (global app-env maintenance seams) and `archive_migration_test.exs` (shared platform migration-dump path), whose in-file documentation names their forcing globals.
No mocks or user-database copies are used; historical fixtures are independent raw SQL literals.
Migration/schema suites deliberately boot fresh databases because migration is their subject; ordinary operation/facade suites use immutable checkpointed `EvoGit.TestSupport.StoreTemplate` copies.
Do not introduce test-side migration locks: production owns the global migration-source lock and preloaded source memo.
Assertions stay exact, including raw bytes, schema order, key sets and non-vacuous query plans.
Tmp filenames must be unique across BEAM restarts and cleaned with their WAL/SHM sidecars.
Unlink dynamic repos and guard cleanup with `Process.alive?/1` because `on_exit` runs after the test process exits.
Use events or pool checkout metrics rather than fixed observation windows; construct in-flight writes with an external `BEGIN IMMEDIATE` lock.
Connection-scoped `PRAGMA query_only` fault injection requires an explicitly one-connection pool, never the default six-reader pool.
`insert_all` bypasses Ecto defaults, so VCT fixtures supply `kind: "git"` explicitly.
Captured stderr is shared across async modules, so redefinition refutes must name the suite's migration modules rather than match all compiler warnings.
Normalization fixtures must seed raw before first boot, because already stamped migrations do not rerun.
xqlite 0.16 reports SQL `PRAGMA busy_timeout` as zero; `Xqlite.get_busy_timeout/1` pins the configured wait separately, and stale-driver harness results never justify weakening that assertion.
