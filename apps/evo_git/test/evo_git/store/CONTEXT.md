# evo_git/store — Test Tree

## Intent

Unit tests for the PURE helpers of the SQLite store layer:

- `EvoGit.Store.Queries` — SQL string builders + column encoders (`task_select_sql/0`,
  `project_select_sql/0`, `build_update_set/2`, `encode_column_value/2`, `clamp_limit/1`,
  `clamp_offset/1`, `build_where/1`, `escape_like/1`).
- `EvoGit.Store.Errors` — the disk-full classifier `disk_full_error?/1`.
- `EvoGit.Repo` + the shipped Ecto migrations — infra contracts via REAL unnamed dynamic
  instances (see `repo_test.exs`).
- `EvoGit.Store.RepoScope.with_repo/2` — scoped dynamic-repo binding.

These tests exercise no GenServer, no I/O, no ETS, and no app env — they call pure
functions with literal inputs and assert on their return values (including exact SQL
strings). The stateful Store/TaskRegistry suites live one level up (`../store_test.exs`,
`../store_summary_test.exs`, `../store_disk_full_test.exs`, `../migrate_store_test.exs`).

## Routing Table

- `./queries_test.exs` → `EvoGit.Store.Queries` + `EvoGit.Store.Codec` encode helpers (largest file; `describe` per function).
- `./errors_test.exs` → `EvoGit.Store.Errors.disk_full_error?/1` (all xqlite error shapes + non-error inputs).
- `./repo_test.exs` → Ecto foundations: migrations applied (exactly versions 20260815000001 + 20260815000002), exact 20-column `tasks` shape, 3-column `projects` shape, 6 named indexes + PK autoindexes, `Boot.run_migrations/1` idempotency, durability across `stop`/`start_dynamic`, two-instance coexistence, connection PRAGMAs (`wal`/`1`/`30000`).
- `./repo_scope_test.exs` → `EvoGit.Store.RepoScope.with_repo/2` (happy path, restore-on-raise/throw/exit, nesting, disjoint data across instances).

## API Surface

| File | Module | Notes |
|------|--------|-------|
| `queries_test.exs` | `EvoGit.Store.QueriesTest` | SQL builders, per-column encoders, pagination clamping, WHERE-clause assembly, `escape_like/1`. Uses `Codec.task_columns/0`/`project_columns/0` (compile-time module attributes) so a column-list change surfaces here. |
| `errors_test.exs` | `EvoGit.Store.ErrorsTest` | `{xqlite error shape} -> true/false` table: `:read_only_database`, `:sqlite_failure` codes 8/10/13, message-text fallback (case-insensitive), and negative cases (`{:ok, _}`, nil, atoms, non-tuples, `:constraint_violation`, generic error tuples). |
| `repo_test.exs` | `EvoGit.Store.RepoTest` | `Repo.query!/3` introspection inside `RepoScope.with_repo/2`: `%{columns, rows, num_rows, changes}` result shape; `PRAGMA table_info(tasks)` exact 20 rows `[cid, name, type, notnull, dflt, pk]` (notnull/pk are INTEGERS 0/1, not booleans); `PRAGMA index_list` rows `[seq, name, unique, origin, partial]` in REVERSE-creation order (assert membership, or use `sqlite_master ... ORDER BY name` for determinism); `PRAGMA journal_mode` → `[["wal"]]`, `synchronous` → `[[1]]`, `busy_timeout` → `[[30000]]`. |
| `repo_scope_test.exs` | `EvoGit.Store.RepoScopeTest` | Scoped binding over real dynamic instances; default binding of a fresh test process is the `EvoGit.Repo` module atom. |

## Constraints

- **All four test modules are `async: true` and MUST stay that way.** They touch no
  shared BEAM-global state other than the production migration lock inside
  `EvoGit.Store.Boot` (which exists precisely to make concurrent boots safe).
  Verified by audit — no `Application.put_env`/`delete_env`,
  no `System.put_env`/`delete_env`, no `:persistent_term`, no `:ets`, no GenServer/app-singleton
  access, no real Finch, no sleeps. Do NOT flip them to `async: false` (nothing forces serialization).
- **Concurrent-boot migration compile race is fixed in PRODUCTION**: both clauses of
  `EvoGit.Store.Boot.run_migrations/1` wrap `Ecto.Migrator.run/4` in a cluster-safe
  `:global.trans({{:evo_git_store_migrations, self()}, fun})` lock.
  `Ecto.Migrator.load_migration!/1` recompiles each `.exs` migration via
  `Code.compile_file/1` on EVERY run with pending versions (even when the module is
  already loaded), and concurrent compiles of the same module race with a CompileError
  ("cannot compile module ... because it is currently being defined"). The lock id is a
  single GLOBAL constant (NOT per repo path/instance) because the protected resource is
  the shared set of migration SOURCE modules; the `self()` LockRequesterId is what makes
  it exclude — a CONSTANT requester id is silently re-entrant (no exclusion). Tests call
  `Boot.start_dynamic/1`/`Boot.run_migrations/1` directly (the REAL production path) —
  no test-side lock wrapper is needed or allowed.
- Assertions are intentionally **exact** (full SQL strings / param lists where the output is
  deterministic) — keep them; do not weaken to `contains?`/smoke checks.
- No mocking libraries: inputs are plain literals and `%EvoGit.Agent.Usage{}`/datetime structs.

## Notes for Agents

- Pure-function tests: no `@moduletag :tmp_dir`, no DB, no fixtures — the whole directory runs
  in well under a second (parallel, `async: true`). There is nothing time/seed-sensitive here.
- `repo_test.exs`/`repo_scope_test.exs` DO open real databases — unique tmp `.sqlite` files
  per test process per call (`evogit_r6a_<tag>_<unique>_<pid>.sqlite` under `System.tmp_dir!/0`).
  The dynamic repo is UNLINKED from the test process (`on_exit/1` runs after the process exits)
  and stopped through an alive-guard (`Boot.stop/1` on a dead pid RAISES "no process" — tests
  that stop their instance manually need `if Process.alive?(pid)` in cleanup).
- **No DB anywhere in `queries_test.exs`/`errors_test.exs`**: neither file opens a database — zero
  `:xqlite` calls, no `EvoGit.Store.start_link`, no injected conn, no `setup` blocks.
- **Coverage is complete at the function level**: all 8 public `Queries` functions
  (`task_select_sql/0`, `project_select_sql/0`, `build_update_set/2`, `encode_column_value/2`,
  `clamp_limit/1`, `clamp_offset/1`, `build_where/1`, `escape_like/1` — 77 tests), the single
  public `Errors.disk_full_error?/1` (21 tests), `RepoScope.with_repo/2` (10 tests), and the
  Ecto foundations (19 tests) are pinned.
- **Pinned quirk worth knowing**: `build_where/1` does NOT stringify atom filters — `build_where(status: :pending)`
  asserts `params == [:pending]` (the raw atom rides into the bind params); only `encode_column_value/2`
  routes through `Codec.encode_atom/1`.
- **Concurrent `Boot.start_dynamic/1` is production-safe**: the migration run inside
  `EvoGit.Store.Boot` is serialized by the global `:global` lock (unlocked
  `Code.compile_file` in `Ecto.Migrator` would otherwise race) — any consumer may boot
  per-store dynamic instances concurrently (tests included) without a wrapper.
- The parent `../CONTEXT.md` (and the one above it at `../..`) documents the stateful Store/
  TaskRegistry suites and their async-safety / shared-test-DB cautions — those do NOT apply here.
