defmodule EvoGit.TestSupport.StoreBootLock do
  @moduledoc """
  BEAM-global serialization for `EvoGit.Store.Boot.start_dynamic/1` and
  `Boot.run_migrations/1` in tests.

  ## Why this exists

  `Ecto.Migrator.run/4` loads each `.exs` migration with
  `Code.compile_file/1` (`Ecto.Migrator.load_migration!/1`) on EVERY run
  against a database with pending versions — even when the module is already
  loaded in the BEAM. `Code.compile_file/1` is not concurrency-safe for the
  same module: two processes compiling the same migration file simultaneously
  race on the in-progress module definition and one fails with

      cannot compile module EvoGit.Repo.Migrations.BaselineAdoption
      (errors have been logged)

  ExUnit runs tests WITHIN one module sequentially, so a single async module
  hammering `start_dynamic/1` never races with itself. But two `async: true`
  modules that each boot dynamic repos (`repo_test.exs`, `repo_scope_test.exs`,
  and later store-wave units) DO run concurrently — without a lock their
  `start_dynamic/1` calls interleave and the migration compile races.

  ## The lock

  `:global.set_lock/1` with the lock id `{__MODULE__, self()}` — the
  LockRequesterId (`self()`) makes each calling process a DISTINCT owner so the
  lock truly excludes; a constant requester id would make `:global` treat every
  caller as the same owner and re-grant (no exclusion). Default
  `retries: :infinity`, no owning process to start, and the release runs even
  when the wrapped call raises. Only the boot window is serialized (migration
  compile + DDL on a fresh tmp database, ~tens of ms); everything else in the
  tests stays fully parallel.

  Re-runs of `run_migrations/1` against an already-current database find no
  pending versions and never reach `load_migration!/1`, but they are wrapped
  too — one wrapper covers both entry points and stays correct even if a test
  migrates a fresh database directly.
  """

  @doc """
  Runs `fun` while holding the BEAM-global store-boot lock.
  """
  @spec with_boot_lock((-> result)) :: result when result: var
  def with_boot_lock(fun) when is_function(fun, 0) do
    :global.set_lock({__MODULE__, self()})

    try do
      fun.()
    after
      :global.del_lock({__MODULE__, self()})
    end
  end
end
