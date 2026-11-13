defmodule EvoGit.AgentState.Boot do
  @moduledoc """
  Boot-time Ecto migration runner for the SEPARATE agent-state database.

  Deliberately mirrors `EvoGit.Store.Boot` without calling it: the migration
  SOURCE (a different priv directory), the `:global` lock id and the memoized
  pre-loaded `[{version, module}]` source are all independent of the task
  store, so the two databases never share migration modules, locks or caches.

  ## Usage

      {:ok, pid} = EvoGit.AgentState.Boot.start_dynamic(db_path, pool_size: 2)
      # ... EvoGit.Repo calls with the pid bound via EvoGit.Store.RepoScope ...
      EvoGit.AgentState.Boot.stop(pid)

  Migrations run on a single-connection BOOT instance which is then stopped and
  reopened at the requested pool size — a connection opened against a
  still-schema-less SQLite file keeps an empty schema cached, so the returned
  pool's connections must be created AFTER the schema exists (same rationale as
  `EvoGit.Store.Boot.reopen_pool/3`).

  Boot is FATAL on a broken/unwritable database: `File.mkdir_p!/1` and the
  `{:ok, repo} = ...` matches are allowed to raise out of the caller's `init/1`
  instead of degrading into a silently non-persisting server.
  """

  @repo EvoGit.Repo
  @migrations_subdir "priv/agent_state_repo/migrations"

  # One BEAM-wide memo slot for the pre-loaded `[{version, module}]` source.
  @migration_source_key {__MODULE__, :migration_source}

  @doc """
  Starts an UNNAMED dynamic `EvoGit.Repo` on `database`, runs every pending
  agent-state migration, and returns `{:ok, pid}`.

  ## Options

    * `:pool_size` — connections the returned pool opens (default `2`).
  """
  @spec start_dynamic(Path.t(), keyword()) :: {:ok, pid()}
  def start_dynamic(database, opts \\ []) do
    database = Path.expand(database)
    :ok = File.mkdir_p(Path.dirname(database))
    pool_size = resolve_pool_size(opts)

    {:ok, boot} = @repo.start_link(start_opts(database, 1))
    run_migrations(boot)

    if pool_size == 1 do
      {:ok, boot}
    else
      reopen_pool(database, boot, pool_size)
    end
  end

  @doc """
  Runs every pending migration against `pid`, restoring the caller's dynamic
  repo binding afterwards. Returns the migrated versions.
  """
  @spec run_migrations(pid()) :: [integer()]
  def run_migrations(pid) when is_pid(pid) do
    previous = @repo.put_dynamic_repo(pid)

    try do
      migrate_synchronized!()
    after
      @repo.put_dynamic_repo(previous)
    end
  end

  @doc "Stops a dynamic repo instance cleanly (see `EvoGit.Store.Boot.stop/2`)."
  @spec stop(pid(), timeout()) :: :ok
  def stop(pid, timeout \\ 5_000) when is_pid(pid) do
    Supervisor.stop(pid, :normal, timeout)
  end

  @doc """
  The pre-loaded migration source — `[{version, module}]`, ascending.

  `.exs` files are compiled at most ONCE per BEAM and memoized, so no boot ever
  redefines an already-loaded migration module (which would emit a
  `redefining module` warning on every boot).
  """
  @spec migration_source() :: [{integer(), module()}]
  def migration_source do
    case :persistent_term.get(@migration_source_key, nil) do
      nil -> with_migration_lock(&load_migration_source/0)
      source -> source
    end
  end

  ## Boot internals

  # These MUST be start opts (Ecto's own `@defaults` arrive as start opts and
  # win over a repo's `defaults/0`): the per-instance shape first, then the
  # shared runtime tuning from `EvoGit.Repo.start_opts/0`.
  defp start_opts(database, pool_size) do
    Keyword.merge(EvoGit.Repo.start_opts(),
      database: database,
      name: nil,
      pool_size: pool_size,
      journal_mode: :wal,
      synchronous: :normal
    )
  end

  defp reopen_pool(database, boot, pool_size) do
    :ok = stop(boot)
    @repo.start_link(start_opts(database, pool_size))
  end

  defp resolve_pool_size(opts) do
    case Keyword.get(opts, :pool_size, 2) do
      size when is_integer(size) and size > 0 ->
        size

      other ->
        raise ArgumentError,
              "invalid :pool_size option for EvoGit.AgentState.Boot.start_dynamic/2: " <>
                "expected a positive integer, got: #{inspect(other)}"
    end
  end

  ## Migration source

  defp migrate_synchronized! do
    with_migration_lock(fn ->
      Ecto.Migrator.run(@repo, load_migration_source(), :up, all: true)
    end)
  end

  # A `:global` lock (cluster-safe) whose single constant id protects the
  # migration SOURCE modules; `self()` as the requester id keeps each caller a
  # distinct owner so the lock actually excludes.
  defp with_migration_lock(fun) do
    :global.trans({:evo_git_agent_state_migrations, self()}, fun)
  end

  # MUST be called while holding the migration lock.
  defp load_migration_source do
    case :persistent_term.get(@migration_source_key, nil) do
      nil ->
        source = compile_migration_files()
        :persistent_term.put(@migration_source_key, source)
        source

      source ->
        source
    end
  end

  defp compile_migration_files do
    migrations_dir()
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.flat_map(&migration_entry/1)
    |> Enum.sort()
  end

  defp migrations_dir do
    Application.app_dir(:evo_git, @migrations_subdir)
  end

  # Only files named `<version>_<name>.exs` are migrations.
  defp migration_entry(file) do
    case Integer.parse(Path.rootname(Path.basename(file))) do
      {version, "_" <> _name} -> [{version, compile_migration!(file)}]
      _other -> []
    end
  end

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
end
