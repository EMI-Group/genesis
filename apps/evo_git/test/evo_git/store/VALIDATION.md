# Store migration validation

## Normal Mix validation blockers

`mix test apps/evo_git/test/evo_git/store/boot_migration_source_test.exs` exits 1 before tests because the installed dependencies do not match the lock for `xqlite`, `xqlite_ecto3` (git ref `8f2e632d9e7581e29741d50ef33331705e7424c7`), `llm_db` and `websock_adapter`.
No dependency declarations, lockfiles or installed dependencies were updated.

`mix test --no-deps-check apps/evo_git/test/evo_git/store/historical_sources_test.exs` exits 1 during application compilation because `Dune.Allowlist` is unavailable at `lib/evo_git/agent/tools/elixir_eval/allowlist.ex:3`.
Compilation also warns that `:dune` and `:file_system` are not loaded.
These are environment blockers, not passing normal-suite results.

## Isolated remnant-guard diagnostic

The following invocation passed all **5 tests at seed 42** using real Ecto and synthetic SQLite databases without booting the application.
It compiles the current production Repo, RepoScope, HistoricalSources and Boot modules in memory and uses existing dependency BEAMs.
The loaded dependency versions are Ecto 3.14.2, ecto_sql 3.14.0, xqlite 0.12.2 and xqlite_ecto3 0.1.0-dev, not the locked/current-driver stack.
This establishes remnant refusal and unchanged schema/ledger/source bytes only; it is not validation of the complete migration suites against declared dependencies.

```sh
ERL_LIBS=_build/test/lib elixir -pa _build/dev/lib/evo_git/ebin -e '
Logger.configure(level: :warning)
Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:xqlite_ecto3)
Code.compiler_options(ignore_module_conflict: true)
Enum.each([
  "apps/evo_git/lib/evo_git/repo.ex",
  "apps/evo_git/lib/evo_git/store/repo_scope.ex",
  "apps/evo_git/lib/evo_git/store/historical_sources.ex",
  "apps/evo_git/lib/evo_git/store/boot.ex"
], &Code.compile_file/1)
IO.inspect(Enum.map([:ecto, :ecto_sql, :xqlite, :xqlite_ecto3],
  &{&1, Application.spec(&1, :vsn)}), label: "Harness dependency versions")
ExUnit.start(capture_log: true, seed: 42)
Code.require_file("apps/evo_git/test/evo_git/store/historical_sources_test.exs")
'
```

Changed test files were formatted with standalone `Code.format_file!/1` under Elixir 1.20.5, avoiding Mix dependency checks.
The nine-migration schema/source/upgrade suites require the separately handled migration-10 deletion and a normal scoped Mix run after the environment is repaired.
The xqlite 0.16 busy-timeout assertions remain unchanged; stale-driver diagnostics never justify weakening them.
