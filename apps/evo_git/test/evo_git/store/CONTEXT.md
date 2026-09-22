# evo_git/store — Test Tree

## Intent

Unit tests for the Ecto persistence layer of the SQLite store — the pure
Operation modules, the Ecto.Type wire formats, the boot/migration machinery, the
dynamic-repo plumbing, and the error classifier. Every test drives REAL unnamed
dynamic `EvoGit.Repo` instances (`EvoGit.Store.Boot.start_dynamic/1`) on unique
tmp SQLite files (or, for the pure modules, no database at all), so the whole
directory is `async: true`.

The stateful Store/TaskRegistry suites live one level up (`../store_test.exs`,
`../store_summary_test.exs`, `../store_disk_full_test.exs`,
`../migrate_store_test.exs`).

## Routing Table

- `./operations/` → one file per Operation module (`tasks_test.exs`,
  `lightweight_test.exs`, `summaries_test.exs`, `projects_test.exs`,
  `safety_test.exs`) — real dynamic repos, rows seeded through the TYPED
  schemas, return shapes pinned to the public-API contract.
- `./types_test.exs` → `EvoGit.Store.TypesTest` — Codec-oracle equivalence for
  every Ecto.Type (`dump/1` byte-identical to `Codec.encode_*/1`, `load/1`
  equal to `Codec.decode_*/1` incl. raising paths).
- `./boot_migration_test.exs` → `EvoGit.Store.BootMigrationTest` — SCHEMA
  adoption coverage of `20260815000001_baseline_adoption` (fresh DB, current
  20-col table, 15/17-col legacy prefixes, the real 19-column v0.9.0–v0.12.5
  shape incl. the accepted `…,updated_at,error` adopted tail, and the
  old-pipeline-repaired shape).
- `./boot_normalization_test.exs` → `EvoGit.Store.BootNormalizationTest` —
  DATA-normalization coverage of `20260815000002_data_normalization`
  (timestamps, results, opts, backfills, quarantine drops), seeded RAW via
  xqlite BEFORE boot so the rewrite runs during it.
- `./repo_test.exs` → `EvoGit.Store.RepoTest` — infra contracts: applied
  versions, exact 20-column `tasks` / 3-column `projects` shape, 6 named
  indexes + PK autoindexes, `Boot.run_migrations/1` idempotency, durability
  across `stop`/`start_dynamic`, two-instance coexistence, connection PRAGMAs.
- `./repo_scope_test.exs` → `EvoGit.Store.RepoScopeTest` — `with_repo/2` happy
  path, restore-on-raise/throw/exit, nesting, disjoint data across instances.
- `./errors_test.exs` → `EvoGit.Store.ErrorsTest` — both classifier families
  (`disk_full_error?/1` over xqlite NIF tuples, `disk_full_exception?/1` over
  `%XqliteEcto3.Error{}` shapes) + non-error inputs.

## API Surface

| File | Module | Notes |
|------|--------|-------|
| `operations/tasks_test.exs` | `EvoGit.Store.Operations.TasksTest` | Writes/core/pagination/narrow reads; raw-column assertions through `TaskRowRaw`; REPLACE semantics (re-put NULLs omitted columns); 500-id chunked deletes. |
| `operations/lightweight_test.exs` | `EvoGit.Store.Operations.LightweightTest` | id/lease/cleanup projections — exact shapes, literal status pushdowns, raw `updated_at`/unix-ms lease values. |
| `operations/summaries_test.exs` | `EvoGit.Store.Operations.SummariesTest` | EXACT 16-key map shape, raw-string `updated_at`, `result` never selected, statuses/since/path filters, skip-and-log. |
| `operations/projects_test.exs` | `EvoGit.Store.Operations.ProjectsTest` | Project CRUD return shapes, REPLACE via delete+insert transaction, NULL-path no-match, disk-full tuple from `put_project`. |
| `operations/safety_test.exs` | `EvoGit.Store.Operations.SafetyTest` | Safe selects (skip+log incl. the wrong-typed-cell one-at-a-time PK fallback), `size` row-count math. |
| `types_test.exs` | `EvoGit.Store.TypesTest` | Deterministic matrices + seeded `:rand` loops; closed atom sets mirror the Codec's `@known_atoms` union. |
| `boot_migration_test.exs` | `EvoGit.Store.BootMigrationTest` | Legacy fixtures crafted RAW (never through the repo) exactly as a pre-Ecto release left them: historical DDL, no `schema_migrations`; adoption never rewrites healthy data (pre-boot raw SELECT == post-boot `TaskRowRaw` load). |
| `boot_normalization_test.exs` | `EvoGit.Store.BootNormalizationTest` | Tables created with the CURRENT-shape DDL so baseline adoption is a pure no-op and every byte change is attributable to the data migration alone. |
| `repo_test.exs` | `EvoGit.Store.RepoTest` | `Repo.query!/3` introspection inside `RepoScope.with_repo/2`; `PRAGMA table_info` rows `[cid, name, type, notnull, dflt, pk]` with INTEGER 0/1 flags; journal_mode `wal`, synchronous `1`, busy_timeout `30000`. |
| `repo_scope_test.exs` | `EvoGit.Store.RepoScopeTest` | Default binding of a fresh test process is the `EvoGit.Repo` module atom. |
| `errors_test.exs` | `EvoGit.Store.ErrorsTest` | `{shape} -> true/false` tables for both families: codes 8/10/13, `:read_only_database`, message-text fallback (case-insensitive), negatives (`{:ok, _}`, code 19 / constraint shapes, NIF tuples under `disk_full_exception?/1`, non-exception values). |

## Constraints

- **All test modules here are `async: true` and MUST stay that way.** They touch
  no shared BEAM-global state other than the PRODUCTION migration lock inside
  `EvoGit.Store.Boot` (which exists precisely to make concurrent boots safe).
  Verified by audit — no `Application.put_env`/`delete_env`, no
  `System.put_env`/`delete_env`, no `:persistent_term`, no `:ets`, no
  GenServer/app-singleton access, no sleeps. Do NOT flip to `async: false`.
- **Concurrent-boot migration compile race is fixed in PRODUCTION, not in
  tests**: both clauses of `EvoGit.Store.Boot.run_migrations/1` wrap
  `Ecto.Migrator.run/4` in a cluster-safe
  `:global.trans({{:evo_git_store_migrations, self()}, fun})` lock.
  `Ecto.Migrator.load_migration!/1` recompiles each `.exs` migration via
  `Code.compile_file/1` on EVERY run with pending versions (even when the
  module is already loaded), and concurrent compiles of the same module race
  with a CompileError. The lock id is a single GLOBAL constant (NOT per repo
  path/instance) because the protected resource is the shared set of migration
  SOURCE modules; the `self()` LockRequesterId is what makes it exclude — a
  CONSTANT requester id is silently re-entrant (no exclusion). Tests call
  `Boot.start_dynamic/1`/`Boot.run_migrations/1` directly (the REAL production
  path) — no test-side lock wrapper is needed or allowed.
- Assertions are intentionally **exact** (full return shapes, key sets, raw
  bytes where the output is deterministic) — keep them; do not weaken to
  `contains?`/smoke checks.
- No mocking libraries: inputs are plain literals and
  `%EvoGit.Agent.Usage{}`/`%TaskInfo{}`/datetime structs; legacy fixtures are
  raw SQL through xqlite.

## Notes for Agents

- Tmp DB filenames must be unique ACROSS BEAM restarts too — embed the
  wall-clock ms (`System.system_time(:millisecond)`) alongside
  `System.unique_integer` + `inspect(self())`; a counter+pid alone collides
  with a previous run's leftover file and silently reopens its stale rows.
- The dynamic repo is UNLINKED from the test process (`on_exit/1` runs after
  the process exits) and stopped through an alive-guard (`Boot.stop/1` on a
  dead pid RAISES "no process" — tests that stop their instance manually need
  `if Process.alive?(pid)` in cleanup).
- `types_test.exs`/`errors_test.exs` open NO database — pure function tests
  (zero xqlite calls, no `setup` blocks); the boot/operations/repo suites open
  real databases under `System.tmp_dir!/0`.
- Normalization runs DURING boot, so pre-normalization data CANNOT be seeded
  through a booted repo (a second boot finds no pending migrations and never
  re-runs the rewrite) — `boot_normalization_test.exs` seeds RAW and only then
  calls `Boot.start_dynamic/1`.
- The parent `../CONTEXT.md` (and the one above it at `../..`) documents the
  stateful Store/TaskRegistry suites and their async-safety /
  shared-test-DB cautions — those do NOT apply here.
