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

  Boot is NEVER fatal: `start_dynamic/2` contains the directory creation, the
  repo start and the migration run, stops any partially started repo instance
  and answers `{:error, reason}` instead of raising. The caller
  (`EvoGit.AgentState.Server`) degrades to a store-less server and retries with
  bounded backoff, so a broken or unwritable database can never take down the
  application.
  """

  @repo EvoGit.Repo
  @migrations_subdir "priv/agent_state_repo/migrations"

  # One BEAM-wide memo slot for the pre-loaded `[{version, module}]` source.
  @migration_source_key {__MODULE__, :migration_source}

  @doc """
  Starts an UNNAMED dynamic `EvoGit.Repo` on `database`, runs every pending
  agent-state migration, and returns `{:ok, pid}`.

  TOTAL: a directory that cannot be created, a repo that will not start and a
  failing migration all answer `{:error, reason}` (the partially started repo
  instance is stopped first) — this function never raises and never exits.

  ## Options

    * `:pool_size` — connections the returned pool opens (default `2`).
  """
  @spec start_dynamic(Path.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_dynamic(database, opts \\ []) do
    do_start_dynamic(database, opts)
  rescue
    error -> {:error, {:boot_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:boot_failed, {kind, reason}}}
  end

  defp do_start_dynamic(database, opts) do
    database = Path.expand(database)
    pool_size = resolve_pool_size(opts)

    with :ok <- ensure_dir(database),
         {:ok, boot} <- start_boot_repo(database) do
      complete_boot(boot, database, pool_size)
    end
  end

  defp ensure_dir(database) do
    case File.mkdir_p(Path.dirname(database)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp start_boot_repo(database) do
    case @repo.start_link(start_opts(database, 1)) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  rescue
    error -> {:error, {:repo_start_failed, Exception.message(error)}}
  end

  # The migration run is the one step that must stop its own boot repo before
  # answering: leaving a migrated-then-failed instance linked would keep a
  # connection on the broken file alive for the whole backoff window.
  defp complete_boot(boot, database, pool_size) do
    case run_migrations(boot) do
      {:ok, _versions} ->
        reopen(boot, database, pool_size)

      {:error, reason} ->
        # A failed migration run is a FAILED boot, never a schema-less one: the
        # caller degrades to a store-less writer and retries with backoff
        # instead of writing checkpoints into a database with no tables.
        stop_quietly(boot)
        {:error, reason}
    end
  rescue
    error ->
      stop_quietly(boot)
      {:error, {:migration_failed, Exception.message(error)}}
  catch
    kind, reason ->
      stop_quietly(boot)
      {:error, {:migration_failed, {kind, reason}}}
  end

  defp reopen(boot, _database, 1), do: {:ok, boot}

  defp reopen(boot, database, pool_size) do
    stop_quietly(boot)

    case @repo.start_link(start_opts(database, pool_size)) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  rescue
    error -> {:error, {:repo_start_failed, Exception.message(error)}}
  end

  # A stopped/failed boot repo must never turn a boot error into a raise.
  defp stop_quietly(boot) do
    _ = stop(boot)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Runs every pending migration against `pid`, restoring the caller's dynamic
  repo binding afterwards.

  Answers `{:ok, versions}` with the migrated versions, or
  `{:error, :migration_lock_unavailable}` when the migration lock could not be
  acquired — the migration run then did NOT happen, so a caller must never
  treat this as a booted schema.
  """
  @spec run_migrations(pid()) ::
          {:ok, [integer()]} | {:error, :migration_lock_unavailable}
  def run_migrations(pid) when is_pid(pid) do
    previous = @repo.put_dynamic_repo(pid)

    try do
      migrate_synchronized()
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

  Answers `{:error, :migration_lock_unavailable}` when the source is not
  memoized yet AND the migration lock could not be acquired: a compile may only
  happen under that lock, and an empty list would silently turn a real
  migration set into a no-op.
  """
  @spec migration_source() ::
          [{integer(), module()}] | {:error, :migration_lock_unavailable}
  def migration_source do
    case :persistent_term.get(@migration_source_key, nil) do
      nil -> acquire_migration_source()
      source -> source
    end
  end

  defp acquire_migration_source do
    case with_migration_lock(&load_migration_source/0) do
      :aborted -> {:error, :migration_lock_unavailable}
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

  # `:global.trans/2` answers the ATOM `:aborted` when the lock cannot be
  # acquired, and that value must never be mistaken for a migration run: a
  # discarded `:aborted` used to answer `start_dynamic/2` with `{:ok, pid}` for
  # a database where NO migration ran, which left the writer (the documented
  # degraded path never triggered) failing every checkpoint forever against a
  # schema-less file. The lock's `:aborted` is therefore mapped to an honest
  # error instead of an empty/absent result.
  defp migrate_synchronized do
    result =
      with_migration_lock(fn ->
        Ecto.Migrator.run(@repo, load_migration_source(), :up, all: true)
      end)

    case result do
      :aborted -> {:error, :migration_lock_unavailable}
      versions when is_list(versions) -> {:ok, versions}
    end
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
