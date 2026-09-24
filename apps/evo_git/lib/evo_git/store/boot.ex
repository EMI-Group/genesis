defmodule EvoGit.Store.Boot do
  @moduledoc """
  Boot-time Ecto migration runner for the EvoGit task store.

  Runs the Ecto migrations in `priv/repo/migrations/` (baseline adoption +
  data normalization) against a repo — either the canonical named
  `EvoGit.Repo` instance or a per-store UNNAMED dynamic instance — before
  any store read/write, mirroring the always-migrate-at-boot contract of the
  raw-SQL `EvoGit.Store.init/1` pipeline. `Ecto.Migrator.run/4` with
  `all: true` is a no-op when the database is current.

  The migrations are handed to the migrator as a PRE-LOADED
  `[{version, module}]` source (`migration_source/0`): the `.exs` files are
  compiled at most ONCE per BEAM and memoized, so every later boot reuses the
  already-loaded modules. A migrations DIRECTORY source is deliberately never
  used — it makes `Ecto.Migrator.load_migration!/1` `Code.compile_file/1`
  every pending migration file on every run, redefining an already-loaded
  module into the BEAM and printing a `redefining module` warning per boot.
  The remaining `:global` lock serializes that one-time compile plus each run
  (see `migrate_synchronized!/0`).

  ## Usage

  Canonical instance (must already be started):

      EvoGit.Repo.start_link()
      EvoGit.Store.Boot.run_migrations()

  Per-store dynamic instance — start, migrate, use, stop:

      {:ok, pid} = EvoGit.Store.Boot.start_dynamic(db_path)
      EvoGit.Repo.put_dynamic_repo(pid)
      # ... repo usage ...
      EvoGit.Store.Boot.stop(pid)

  No GenServer: `run_migrations/1` sets the caller's dynamic repo (restoring
  the previous binding afterwards), so migrations run against the intended
  instance even when several coexist. The migration run itself is serialized
  by a transient `:global` lock (see `migration_source/0`) — concurrent boots
  of ANY instances never race on migration module compilation. The only
  BEAM-wide state is the memoized pre-loaded migration source.
  """

  @repo EvoGit.Repo

  # One BEAM-wide memo slot for the pre-loaded `[{version, module}]` source.
  @migration_source_key {__MODULE__, :migration_source}

  @doc """
  Runs all pending migrations (`:up`, `all: true` — no-op when current).

  Accepts either:

    * `opts :: keyword()` — runs against the caller's CURRENT repo binding
      (`EvoGit.Repo.get_dynamic_repo/0`, the canonical named instance when
      unset). The parent dir of the configured database is created if
      missing.
    * `pid :: pid()` — an already-started UNNAMED dynamic repo instance; the
      caller's dynamic binding is set to it for the duration of the run and
      restored afterwards.

  Returns the list of migrated versions (empty when current).
  """
  @spec run_migrations(keyword() | pid()) :: [integer()]
  def run_migrations(pid) when is_pid(pid) do
    ensure_database_dir!(pid)

    # The pdict save/restore stays OUTSIDE the global lock: the dynamic-repo
    # binding is PER-PROCESS state, so only this caller's own dictionary is
    # mutated and there is nothing to serialize against other booting
    # processes. The lock below is exclusively about the one-time migration
    # MODULE compilation plus the run (see `migrate_synchronized!/0`).
    previous = @repo.put_dynamic_repo(pid)

    try do
      migrate_synchronized!()
    after
      @repo.put_dynamic_repo(previous)
    end
  end

  def run_migrations(opts) when is_list(opts) do
    ensure_database_dir!(@repo.get_dynamic_repo())
    migrate_synchronized!()
  end

  @doc """
  Starts an UNNAMED dynamic `EvoGit.Repo` on `database`, runs all migrations,
  and returns `{:ok, pid}`.

  The instance is unregistered (no name) — address it BY PID through
  `EvoGit.Repo.put_dynamic_repo/1`, and stop it with `stop/1`. The parent
  dir of `database` is created if missing.
  """
  @spec start_dynamic(Path.t()) :: {:ok, pid()}
  def start_dynamic(database) do
    database = Path.expand(database)
    :ok = File.mkdir_p(Path.dirname(database))

    with {:ok, pid} <- @repo.start_link(database: database, name: nil, pool_size: 1) do
      run_migrations(pid)
      {:ok, pid}
    end
  end

  @doc """
  Stops a dynamic repo instance cleanly.

  `Repo.stop/0` is unusable here: it operates on the CALLER's
  `get_dynamic_repo()`, which may be a different instance (or the canonical
  one). `Supervisor.stop(pid, :normal, timeout)` is the supported way to
  stop a specific unnamed instance.
  """
  @spec stop(pid(), timeout()) :: :ok
  def stop(pid, timeout \\ 5_000) when is_pid(pid) do
    Supervisor.stop(pid, :normal, timeout)
  end

  @doc """
  Returns the pre-loaded migration source for `priv/repo/migrations/` —
  `[{version, module}]`, ascending by version.

  The `.exs` files are compiled at most ONCE per BEAM (inside the migration
  lock described in `migrate_synchronized!/0`) and memoized, so later calls
  and later boots reuse the modules already loaded in the BEAM instead of
  recompiling them.
  """
  @spec migration_source() :: [{integer(), module()}]
  def migration_source do
    case cached_migration_source() do
      nil -> with_migration_lock(&load_migration_source/0)
      source -> source
    end
  end

  ## Shared

  # The migrator is fed the PRE-LOADED `[{version, module}]` source
  # (`migration_source/0`) instead of the migrations DIRECTORY. With a
  # directory source `Ecto.Migrator.load_migration!/1` calls
  # `Code.compile_file/1` for every pending file on EVERY run, so each fresh
  # test-store boot redefines the already-loaded migration module in the BEAM
  # and prints `warning: redefining module
  # EvoGit.Repo.Migrations.<name>` — the warning flood the test suite used to
  # emit. Pre-loaded modules are used as-is, so the files are compiled once
  # per BEAM and never again.
  #
  # The lock below therefore serializes (a) that one-time migration-module
  # compile and (b) the migration run. `Code.compile_file/1` is not
  # concurrency-safe for the same module: two concurrent boots racing on the
  # in-progress module definition blow up with a CompileError ("cannot compile
  # module EvoGit.Repo.Migrations.BaselineAdoption"). Boot is not exclusive in
  # production: per-store dynamic instances can start in parallel (e.g. a
  # dashboard restarting stores alongside another booting consumer), so the
  # run — not just the compile — must be serialized.
  #
  # The lock is `:global` (cluster-safe across the whole BEAM — including a
  # distributed dashboard/daemon pair once connected) and its id is a single
  # GLOBAL constant, NOT derived from the repo path or instance: the shared
  # resource being protected is the set of migration SOURCE modules, which
  # every database path loads from the same `priv/repo/migrations` files.
  # A per-path lock would still let two different databases race on
  # redefining the same migration module. `:global.trans/2` (lock id, fun)
  # blocks until the lock is free, runs the fun, and releases even on raise;
  # the `self()` LockRequesterId keeps each caller a DISTINCT owner so the
  # lock actually excludes (a constant requester id would be treated as
  # re-entry by the same owner and re-grant). Only the boot window is
  # serialized, and the compile it guards is a one-time per-BEAM cost.
  defp migrate_synchronized! do
    with_migration_lock(fn ->
      Ecto.Migrator.run(@repo, load_migration_source(), :up, all: true)
    end)
  end

  defp with_migration_lock(fun) do
    :global.trans({:evo_git_store_migrations, self()}, fun)
  end

  # MUST be called while holding the migration lock — the compile below races
  # otherwise (see `migrate_synchronized!/0`).
  defp load_migration_source do
    case cached_migration_source() do
      nil ->
        source = compile_migration_files()
        :persistent_term.put(@migration_source_key, source)
        source

      source ->
        source
    end
  end

  defp cached_migration_source do
    :persistent_term.get(@migration_source_key, nil)
  end

  # `Ecto.Migrator.migrations_path/1` resolves `priv/repo/migrations` through
  # `Application.app_dir/2`, so the canonical repo and every per-store dynamic
  # instance resolve the SAME directory — no absolute priv path is hardcoded.
  defp compile_migration_files do
    @repo
    |> Ecto.Migrator.migrations_path()
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.flat_map(&migration_entry/1)
    |> Enum.sort()
  end

  # Mirrors `Ecto.Migrator.extract_migration_info/1`: only files named
  # `<version>_<name>.exs` are migrations, anything else in the directory is
  # ignored (exactly as a directory source would).
  defp migration_entry(file) do
    case Integer.parse(Path.rootname(Path.basename(file))) do
      {version, "_" <> _name} -> [{version, compile_migration!(file)}]
      _other -> []
    end
  end

  # Mirrors `Ecto.Migrator.load_migration!/1` for a file source.
  defp compile_migration!(file) do
    modules = file |> Code.compile_file() |> Enum.map(&elem(&1, 0))

    case Enum.find(modules, &migration?/1) do
      nil ->
        raise Ecto.MigrationError,
              "file #{Path.relative_to_cwd(file)} does not define an Ecto.Migration"

      module ->
        module
    end
  end

  defp migration?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__migration__, 0)
  end

  # The adapter's SQLite driver creates the parent dir itself, but only for
  # the primary database file of ITS connection — keep the guarantee
  # identical to the raw store boot (mkdir_p before anything touches the
  # file), which also covers exotic parent paths the driver may refuse.
  defp ensure_database_dir!(repo) do
    case repo_config_database(repo) do
      {:ok, database} -> :ok = File.mkdir_p(Path.dirname(Path.expand(database)))
      :error -> :ok
    end
  end

  defp repo_config_database(repo) when is_atom(repo) or is_pid(repo) do
    try do
      config = @repo.config()
      Keyword.fetch(config, :database)
    rescue
      _e in _ -> :error
    end
  end
end
