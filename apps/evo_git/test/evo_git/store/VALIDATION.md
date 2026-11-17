# Store migration validation follow-up

This report records the integrated tests-only preservation follow-up and an isolated diagnostic run, not a normal Mix-suite pass.
No production source, dependency declarations, lockfiles or user databases were changed.

## Results and classification

The exact invocation below ran **131 tests at seed 42: 130 passed / 1 failed**, exit status **2**, in 10.6 seconds (1.3s load, 9.0s async, 0.3s sync).
All 14 behavior-related integrated failures are resolved, and all ten `LedgerReconciliationTest` cases passed.
The only remaining failure is `repo_test.exs:582`: `PRAGMA busy_timeout` returns `[[30000]]` with loaded xqlite **0.12.2**, while the declared 0.16-driver contract correctly requires `[[0]]`.
That assertion and the `Xqlite.get_busy_timeout/1` check remain unchanged.

The integrated migration suites require exact retained-source schemas, byte-identical archive sources (including duplicated result archives), complete relational archive fan-out, and every legacy project retained and imported without the live project cap.
Malformed archive sources and invalid/unreadable project sources fail closed, retain their source bytes, leave migration 10 unstamped, and preserve repeat-attempt snapshots rather than silently skipping data.
Rollback assertions distinguish the committed frozen stage from the migration-10 repair transaction.
Separate direct frozen-version-7 cases continue to pin skip/drop/cap behavior and atomic rollback; the integrated tests do not erase those historical contracts.
All changes are isolated synthetic-fixture tests; async conventions remain unchanged.

Normal validation against the declared driver remains necessary.
The final manager-level `mix format --check-formatted` attempt was blocked by dev dependency lock mismatches (xqlite, xqlite_ecto3, llm_db and websock_adapter); individual file agents reported successful formatting checks.
`git diff --check` passes.

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

Actual diagnostic exit status is 2 solely because of the stale-driver busy-timeout mismatch described above.
