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

  # Connections opened by each per-store dynamic repo pool.
  #
  # >1 is SAFE here. The journal is WAL, so readers and the writer run
  # concurrently instead of blocking each other; and this store has exactly ONE
  # writer path — every write goes through the `EvoGit.Store` GenServer (no
  # module outside `lib/evo_git/store/` calls `EvoGit.Repo.*`), which already
  # serializes them — so extra connections cannot introduce write-write
  # contention. The 30 s `busy_timeout` (repo.ex) covers any transient lock
  # window (e.g. a checkpoint). What the extra connections buy is READ
  # parallelism: with a single connection every offloaded read Task, inline
  # handler, write and migration queued on the SAME connection, so all store
  # SQL serialized at the connection level, not just at the GenServer. Measured
  # head-of-line blocking with one connection: a plain page load 1.4 ms quiet
  # vs 11.8 ms while a 20 ms sidebar summary was in flight; p99 207 ms with 10
  # queued search loads.
  #
  # 4 is the chosen size: the Store GenServer can hold at most ONE connection
  # for a write at a time (writes are serialized there), so 4 leaves 3 for
  # concurrent reads — the measured head-of-line pair (a page load + the
  # sidebar summary) plus the third read a dashboard page mount issues
  # (paginated list + summary + changed-since), without queueing behind each
  # other. Deliberately kept in the low single digits: every connection is a
  # REAL SQLite handle with its own file descriptor and its own page-cache
  # budget (`cache_size: -64_000`, i.e. 64 MiB, from the adapter defaults), and
  # EVERY dynamic store opens this many — including the hundreds of per-test
  # stores the suite boots.
  #
  # Overridable per store via `start_dynamic/2`'s `:pool_size` option (and
  # `EvoGit.Store.start_link/1`'s, which forwards it). A single-connection
  # store is one option away: the disk-full tests pass `pool_size: 1`, because
  # `PRAGMA query_only` is CONNECTION-scoped and only an exactly-one-connection
  # pool guarantees the armed connection is the one every write is handed.
  @default_pool_size 4

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

  ## Options

    * `:pool_size` — connections the instance's DBConnection pool opens.
      Defaults to `default_pool_size/0`. Values `> 1` let this store's reads
      run CONCURRENTLY (see the `@default_pool_size` rationale): WAL separates
      readers from the writer, and the single writer (the `EvoGit.Store`
      GenServer) is already serialized. Pass `1` for a single-connection
      store. Anything but a positive integer raises an `ArgumentError`.

  Migrations run on a single-connection BOOT instance, which a `pool_size: 1`
  store keeps and which is released (and reopened at the requested size) for
  any larger pool — see `reopen_pool/3` for why the returned pool's
  connections must be created AFTER the schema exists.
  """
  @spec start_dynamic(Path.t(), keyword()) :: {:ok, pid()}
  def start_dynamic(database, opts \\ []) do
    database = Path.expand(database)
    :ok = File.mkdir_p(Path.dirname(database))
    pool_size = resolve_pool_size(opts)

    with {:ok, boot} <- @repo.start_link(database: database, name: nil, pool_size: 1) do
      run_migrations(boot)

      if pool_size == 1 do
        {:ok, boot}
      else
        reopen_pool(database, boot, pool_size)
      end
    end
  end

  # Migrations are deliberately run on the single-connection BOOT instance
  # above, which is then released before the returned pool opens — so every
  # connection of the returned instance opens a database file that ALREADY
  # carries the migrated schema. (A `pool_size: 1` store keeps the boot
  # instance instead: one connection is exactly the shape it asked for, and it
  # is the connection that ran the migrations — the boot it has always had.)
  #
  # Why that matters: SQLite loads a connection's schema LAZILY, and a
  # connection that opened a still-schema-less file keeps that empty schema
  # cached. The schema-introspection pragmas (`PRAGMA index_list/1` and its
  # kin) are answered from that cache WITHOUT triggering the load, so such a
  # connection reports an EMPTY index list until some other statement loads the
  # schema (a plain query or `EXPLAIN QUERY PLAN` does — measured on a
  # `default_pool_size/0` pool: the first `PRAGMA index_list(tasks)` of a
  # pre-migration connection returns 0 rows, a later one returns all 7). With
  # one connection this is invisible, because that connection executed the DDL
  # itself; with several it is not — the pool would hand out an
  # introspection-inconsistent connection alongside correct ones,
  # non-deterministically. Reopening the pool is the supported way to get
  # fresh connections: the boot instance has released the file (closing the
  # last connection to a WAL database also checkpoints it), and the new pool's
  # connections are all created against the migrated schema.
  defp reopen_pool(database, boot, pool_size) do
    :ok = stop(boot)
    @repo.start_link(database: database, name: nil, pool_size: pool_size)
  end

  @doc """
  The pool size a store uses when it does not pass `:pool_size` explicitly —
  the `@default_pool_size` constant (#{@default_pool_size}).
  """
  @spec default_pool_size() :: pos_integer()
  def default_pool_size, do: @default_pool_size

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

  # The `:pool_size` option is validated HERE, before the repo start: the
  # DBConnection pool raises its own ArgumentError on a size < 1 from inside
  # the pool supervisor's init/1, which surfaces as an opaque
  # `{:error, {:shutdown, {:failed_to_start_child, ...}}}` (and a bogus
  # non-integer would only blow up later, once a connection is attempted).
  # A descriptive raise at the call site keeps a misconfigured store obvious.
  defp resolve_pool_size(opts) do
    case Keyword.get(opts, :pool_size) do
      nil ->
        default_pool_size()

      size when is_integer(size) and size > 0 ->
        size

      other ->
        raise ArgumentError, invalid_pool_size_message(other, "EvoGit.Store.Boot.start_dynamic/2")
    end
  end

  defp invalid_pool_size_message(value, where) do
    "invalid :pool_size option for #{where}: expected a positive integer, got: #{inspect(value)}"
  end

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
