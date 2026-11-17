# Store migration validation follow-up

This report follows commit `6ba8b5658` and records an isolated diagnostic run, not a normal Mix-suite pass.
No production source, dependency declarations, lockfiles or user databases were changed.

## Results and classification

The selected suites ran 126 tests at seed 42: initially **109 passed / 17 failed**, then **111 passed / 15 failed** after the exact expectation updates below.
This selection is broader than the earlier reported 81-test harness, whose invocation was not included in the commit's `refs/notes/evogit` report.
All ten `LedgerReconciliationTest` cases passed, including preservation failure/retry and rollback cases.

Corrected obsolete expectations:
- Two remaining `[[9]]` ledger-count assertions now require `[[10]]`, alongside the existing exact version-list assertions.
- Fresh-boot SQL now requires exactly the two migration-10 compression probes, rather than mistaking them for archive fan-out; the no-archive-INSERT/no-ALTER assertions remain unchanged.
- A no-op boot now requires exactly two identical migrator bookkeeping CREATEs (frozen stage and additive reconciliation), still rejecting any other DDL.

Remaining failures (test declaration line numbers):

| File and lines | Observed behavior | Classification / follow-up |
|---|---|---|
| `repo_test.exs:582` | `PRAGMA busy_timeout` returns `30000`, expected `0`. | Harness artifact: loaded xqlite is **0.12.2**, not the declared 0.16 series; do not change the current-driver assertion. |
| `boot_migration_test.exs:637,708,735,803` | Full PRAGMA equality differs because `archive_metadata` survives (22 columns rather than 21). | Old destructive-upgrade expectations conflict with deliberate source preservation. Keep exact schema assertions pending an explicit integrated-upgrade contract update. |
| `boot_migration_test.exs:857` | Legacy `projects` survives. | Same intentional preservation versus old drop expectation. |
| `boot_migration_test.exs:590` | Migration 10 rejects `archive_metadata` containing a JSON object rather than an array. | Fail-closed repair versus old skip/drop fixture policy; do not weaken source-byte preservation assertions or silently discard the invalid payload. |
| `v0138_upgrade_path_test.exs:160,181,267` | Legacy projects, archive column and duplicated `data.archive_records` survive respectively. | Old destructive-upgrade expectations; pending version-list checks already pass. |
| `vct_mounts_migration_test.exs:249,308` | Invalid legacy paths abort repair 10 rather than being skipped. | Explicit policy conflict with the frozen migration-7 skip contract, not evidence that source data was lost. Requires deciding whether to test frozen migration 7 directly or integrated fail-closed repair separately. |
| `vct_mounts_migration_test.exs:270` | All 120 source projects imported rather than capped at 100. | Deliberate non-destructive integrated boot conflicts with frozen migration-7 cap expectation. |
| `vct_mounts_migration_test.exs:359` | Empty legacy projects table retained. | Preservation versus old drop expectation. |
| `vct_mounts_migration_test.exs:383` | Unreadable projects still abort with source retained, but `vct_mounts` already exists. | Failure now occurs at repair 10 after frozen 7/8/9 commit, not atomically at 7; the old rollback-boundary expectation does not describe staged boot. |

No production regression is established by these failures.
The 14 non-driver failures concern deliberate preservation/staging or stricter malformed-source policy, but the frozen migration tests should not simply have their behavioral assertions removed to make integrated boot green.
Normal validation against the declared driver and a deliberate separation of frozen-migration versus integrated-upgrade contracts remain necessary.

## Harness provenance and limitations

Normal `mix test ... --no-deps-check` attempts whole-app compilation and fails because `Dune.Allowlist` is unavailable.
The diagnostic harness instead compiles current store/repo/data-struct source **in memory** and starts only dependency applications, never `:evo_git` or the dashboard.
It uses existing `_build/test/lib` dependency beams and `_build/dev/lib/evo_git/ebin` as a fallback for unrelated runtime helpers such as Config.
The `priv` symlinks were verified to resolve to this worktree's `apps/evo_git/priv`, so the migration sources are current.
Loaded dependency versions were Ecto 3.14.2, ecto_sql 3.14.0, xqlite 0.12.2 and xqlite_ecto3 0.1.0-dev.
These do **not** constitute validation against `mix.lock`; stale fallback BEAM signatures also produce compiler diagnostics during the in-memory reload.
All test databases are synthetic per-test fixtures; the harness redirects both data and XDG config to a unique scratch path and removes that path at exit.

Exact final invocation, from the repository root (Elixir 1.20.5):

```sh
ERL_LIBS=_build/test/lib elixir -pa _build/dev/lib/evo_git/ebin -e '
Logger.configure(level: :warning)
Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:xqlite_ecto3)
root = Path.join(System.tmp_dir!(), "store-harness-#{:os.getpid()}")
Application.put_env(:evo_git, :data_dir, root)
System.put_env("XDG_CONFIG_HOME", root)
System.at_exit(fn _ -> File.rm_rf(root) end)
Code.compiler_options(ignore_module_conflict: true)
Enum.each([
  "apps/evo_git/lib/evo_git/agent/usage.ex",
  "apps/evo_git/lib/evo_git/task_info.ex",
  "apps/evo_git/lib/evo_git/platform.ex",
  "apps/evo_git/lib/evo_git/store/codec.ex"
], &Code.compile_file/1)
for pattern <- [
  "apps/evo_git/lib/evo_git/store/types/*.ex",
  "apps/evo_git/lib/evo_git/store/schemas/*.ex"
] do
  Enum.each(Path.wildcard(pattern), &Code.compile_file/1)
end
files = [
  "apps/evo_git/lib/evo_git/repo.ex",
  "apps/evo_git/lib/evo_git/store.ex"
] ++ (Path.wildcard("apps/evo_git/lib/evo_git/store/**/*.ex") --
  (Path.wildcard("apps/evo_git/lib/evo_git/store/types/*.ex") ++
   Path.wildcard("apps/evo_git/lib/evo_git/store/schemas/*.ex")))
{:ok, _, _} = Kernel.ParallelCompiler.compile(files)
IO.inspect(Enum.map([:ecto, :ecto_sql, :xqlite, :xqlite_ecto3],
  &{&1, Application.spec(&1, :vsn)}), label: "Harness dependency versions")
ExUnit.start(capture_log: true, seed: 42)
Path.wildcard("apps/evo_git/test/evo_git/store/{boot*test,canonical_schema_test,repo_test,v0138_upgrade_path_test,vct_mounts_migration_test,archive_migration_test,composite_index_test,covering_index_test,ledger_reconciliation_test}.exs")
|> Enum.each(&Code.require_file/1)
' > "$TMPDIR/store-followup-final.log" 2>&1
```

Expected diagnostic exit status is 2 while the 15 failures above remain.
