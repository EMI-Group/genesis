# evo_git/store — Test Tree

## Intent

Unit tests for the PURE helpers of the SQLite store layer:

- `EvoGit.Store.Queries` — SQL string builders + column encoders (`task_select_sql/0`,
  `project_select_sql/0`, `build_update_set/2`, `encode_column_value/2`, `clamp_limit/1`,
  `clamp_offset/1`, `build_where/1`, `escape_like/1`).
- `EvoGit.Store.Errors` — the disk-full classifier `disk_full_error?/1`.

These tests exercise no GenServer, no I/O, no ETS, and no app env — they call pure
functions with literal inputs and assert on their return values (including exact SQL
strings). The stateful Store/TaskRegistry suites live one level up (`../store_test.exs`,
`../store_summary_test.exs`, `../store_disk_full_test.exs`, `../migrate_store_test.exs`).

## Routing Table

- `./queries_test.exs` → `EvoGit.Store.Queries` + `EvoGit.Store.Codec` encode helpers (largest file; `describe` per function).
- `./errors_test.exs` → `EvoGit.Store.Errors.disk_full_error?/1` (all xqlite error shapes + non-error inputs).

## API Surface

| File | Module | Notes |
|------|--------|-------|
| `queries_test.exs` | `EvoGit.Store.QueriesTest` | SQL builders, per-column encoders, pagination clamping, WHERE-clause assembly, `escape_like/1`. Uses `Codec.task_columns/0`/`project_columns/0` (compile-time module attributes) so a column-list change surfaces here. |
| `errors_test.exs` | `EvoGit.Store.ErrorsTest` | `{xqlite error shape} -> true/false` table: `:read_only_database`, `:sqlite_failure` codes 8/10/13, message-text fallback (case-insensitive), and negative cases (`{:ok, _}`, nil, atoms, non-tuples, `:constraint_violation`, generic error tuples). |

## Constraints

- **Both modules are `async: true` and MUST stay that way.** They touch no shared BEAM-global
  state: every assertion is on the deterministic return value of a pure function. Verified by
  audit — no `Application.put_env`/`delete_env`, no `System.put_env`/`delete_env`, no
  `:persistent_term`, no `:ets`, no GenServer/app-singleton access, no real Finch, no sleeps.
  Do NOT flip them to `async: false` (nothing forces serialization).
- Assertions are intentionally **exact** (full SQL strings / param lists where the output is
  deterministic) — keep them; do not weaken to `contains?`/smoke checks.
- No mocking libraries: inputs are plain literals and `%EvoGit.Agent.Usage{}`/datetime structs.

## Notes for Agents

- Pure-function tests: no `@moduletag :tmp_dir`, no DB, no fixtures — the whole directory runs
  in well under a second (parallel, `async: true`). There is nothing time/seed-sensitive here.
- **No DB anywhere**: neither file opens a database — zero `:xqlite` calls, no `EvoGit.Store.start_link`,
  no injected conn, no `setup` blocks. The GenServer name question is moot; inputs are literals,
  `%EvoGit.Agent.Usage{}`, `~U[...]` sigils, and `Jason.decode!` round-trip checks. No app-env /
  pdict / named-process seams exist in either module.
- **Coverage is complete at the function level**: all 8 public `Queries` functions
  (`task_select_sql/0`, `project_select_sql/0`, `build_update_set/2`, `encode_column_value/2`,
  `clamp_limit/1`, `clamp_offset/1`, `build_where/1`, `escape_like/1` — 77 tests) and the single
  public `Errors.disk_full_error?/1` (21 tests) are pinned. Minor residual gaps:
  `build_update_set/2` never exercises the `:error`/`:usage` columns directly (only via
  `encode_column_value/2`), `encode_column_value(:error, ...)` pins only `stacktrace: nil`, and
  the message-text fallback has no near-miss negative (e.g. `"disk is full"` without the full
  canonical "database or disk is full" text).
- **Pinned quirk worth knowing**: `build_where/1` does NOT stringify atom filters — `build_where(status: :pending)`
  asserts `params == [:pending]` (the raw atom rides into the bind params); only `encode_column_value/2`
  routes through `Codec.encode_atom/1`.
- The parent `../CONTEXT.md` (and the one above it at `../..`) documents the stateful Store/
  TaskRegistry suites and their async-safety / shared-test-DB cautions — those do NOT apply here.
