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
  (see `with_migration_lock/1`), and a lock that cannot be taken is a FAILED
  boot, never a schema-less one.

  `HistoricalSources` rejects reserved objects left by an interrupted prior
  preservation attempt before running the ordinary ordered migration source.
  No source is hidden or restored, and no reconciliation migration is required;
  interrupted preservation state fails boot rather than risking hidden data.

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

  require Logger

  # One BEAM-wide memo slot for the pre-loaded `[{version, module}]` source.
  @migration_source_key {__MODULE__, :migration_source}

  # The ONE message `run_migrations/1` raises with when the migration lock
  # cannot be taken. `start_dynamic/2` matches the SAME attribute (it must never
  # re-derive the text), so the lock-unavailable outcome becomes an error tuple
  # while every other migration failure keeps its raise.
  @migration_lock_unavailable "task-store migration lock unavailable; refusing to report a successful boot"

  # Connections opened by each per-store dynamic repo pool.
  #
  # >1 is SAFE here. The journal is WAL, so readers and the writer run
  # concurrently instead of blocking each other; and this store has exactly ONE
  # writer path — every write goes through the `EvoGit.Store` GenServer (no
  # module outside `lib/evo_git/store/` calls `EvoGit.Repo.*`), which already
  # serializes them (and hands each write to the single `EvoGit.Store.Writer`
  # process) — so extra connections cannot introduce write-write contention.
  # The 30 s `busy_timeout` (repo.ex) covers any transient lock window (e.g. a
  # checkpoint): a statement that meets another connection's lock waits up to
  # 30 s in its OWN calling process (the boot here), with no VM thread parked
  # while it does. What the extra connections buy is READ parallelism: with a
  # single connection every offloaded read Task, inline handler, write and
  # migration queued on the SAME connection, so all store SQL serialized at the
  # connection level, not just at the GenServer. Measured head-of-line blocking
  # with one connection: a plain page load 1.4 ms quiet vs 11.8 ms while a
  # 20 ms sidebar summary was in flight; p99 207 ms with 10 queued search loads.
  #
  # 6 is the chosen size. Writes are serialized through `EvoGit.Store.Writer`,
  # so this is purely a READ-parallelism knob, and a dashboard page mount
  # issues several concurrent reads on top of the once-per-load sidebar
  # summary: the paginated list + the summary + `changed-since` + the project
  # count and a review-page diff read can all overlap, and pushing a cold read
  # (a 400 MB database whose pages are not in cache, ~24 s measured on a cold
  # copy for a status-filtered id scan) must not stall every other reader. 6
  # gives 5 concurrent readers beside the single writer slot.
  #
  # Memory is bounded by the PAGE CACHE, not the connection count: every
  # connection is a REAL SQLite handle with its own file descriptor and its own
  # page-cache budget, so the per-connection `cache_size` from
  # `EvoGit.Repo.start_opts/0` is `-8_000` (8 MiB, down from the adapter's
  # 64 MiB default) → 6 × 8 MiB ≈ 47 MiB of page cache per store, instead of
  # the 375 MiB a 6-connection pool on the adapter default would cost. EVERY
  # dynamic store opens this many, including the hundreds of per-test stores
  # the suite boots.
  #
  # Overridable per store via `start_dynamic/2`'s `:pool_size` option (and
  # `EvoGit.Store.start_link/1`'s, which forwards it). A single-connection
  # store is one option away: the disk-full tests pass `pool_size: 1`, because
  # `PRAGMA query_only` is CONNECTION-scoped and only an exactly-one-connection
  # pool guarantees the armed connection is the one every write is handed.
  @default_pool_size 6

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

  RAISES a descriptive `RuntimeError` when the migration lock
  (`:global.trans/2`, behind the default-inert `:store_boot_lock_fun` seam —
  see `with_migration_lock/1`) cannot be taken: the migration run then did NOT
  happen, so a caller must never treat that as a booted schema.
  `start_dynamic/2` converts exactly that failure into
  `{:error, :migration_lock_unavailable}`.
  """
  @spec run_migrations(keyword() | pid()) :: [integer()]
  def run_migrations(pid) when is_pid(pid) do
    ensure_database_dir!()

    # The pdict save/restore stays OUTSIDE the global lock: the dynamic-repo
    # binding is PER-PROCESS state, so only this caller's own dictionary is
    # mutated and there is nothing to serialize against other booting
    # processes. The lock below is exclusively about the one-time migration
    # MODULE compilation plus the run (see `migrate_synchronized!/0`).
    previous = @repo.put_dynamic_repo(pid)

    try do
      reject_lock_unavailable(migrate_synchronized!())
    after
      @repo.put_dynamic_repo(previous)
    end
  end

  def run_migrations(opts) when is_list(opts) do
    ensure_database_dir!()
    reject_lock_unavailable(migrate_synchronized!())
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

  Finally, ONE best-effort `PRAGMA optimize` runs on that boot connection once
  the migrations have completed (see `optimize_after_migrations/1`) so the
  query planner gets statistics for the migrated schema; it can never fail the
  boot.

  Answers `{:error, :migration_lock_unavailable}` when the migration lock could
  not be taken: the boot instance is stopped first, so the caller never gets a
  pid for a database where NO migration ran. Every other boot failure is the
  repo start's own `{:error, reason}`.
  """
  @spec start_dynamic(Path.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_dynamic(database, opts \\ []) do
    database = Path.expand(database)
    # ONE dir-creation implementation (`ensure_dir!/1`), shared with
    # `run_migrations/1`'s configured-database probe: `EvoGit.Repo.config/0`
    # never reports a DYNAMIC instance's `database:` start opt, so the path
    # handed to THIS function still needs its parent created here.
    ensure_dir!(Path.dirname(database))
    pool_size = resolve_pool_size(opts)

    with {:ok, boot} <- @repo.start_link(start_opts(database, 1)) do
      complete_boot(boot, database, pool_size)
    end
  end

  # Migrate, optimize, then hand back the boot instance (pool 1) or reopen at
  # the requested size.
  #
  # A migration run that could not take the lock is a FAILED boot, never a
  # schema-less one: the boot instance is stopped and the caller answers
  # `{:error, :migration_lock_unavailable}`. Every OTHER migration failure
  # keeps its historical raise (an operator must see a broken migration).
  defp complete_boot(boot, database, pool_size) do
    run_migrations(boot)
    optimize_after_migrations(boot)

    if pool_size == 1 do
      {:ok, boot}
    else
      reopen_pool(database, boot, pool_size)
    end
  rescue
    error ->
      if lock_unavailable?(error) do
        stop_boot_repo(boot)
        {:error, :migration_lock_unavailable}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp lock_unavailable?(%RuntimeError{message: @migration_lock_unavailable}), do: true
  defp lock_unavailable?(_error), do: false

  # A stopped/failed boot repo must never turn a boot error into a raise.
  defp stop_boot_repo(boot) do
    _ = stop(boot)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # Start opts for a dynamic instance: the per-instance shape FIRST, then the
  # shared runtime tuning from `EvoGit.Repo.start_opts/0` (timeout, queue
  # bounds, page cache, temp store) — merged so a future tuning key can never
  # silently overwrite `:database`/`:name`/`:pool_size`.
  #
  # These MUST be start opts, not `EvoGit.Repo.defaults/0`: Ecto's own
  # `@defaults` (`timeout: 15_000, pool_size: 10`) arrive as start opts and win
  # over `defaults/0` — see the `EvoGit.Repo` moduledoc.
  defp start_opts(database, pool_size) do
    Keyword.merge(@repo.start_opts(), database: database, name: nil, pool_size: pool_size)
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
    @repo.start_link(start_opts(database, pool_size))
  end

  # Planner statistics, ONCE per boot: `PRAGMA optimize` asks SQLite to
  # ANALYZE whatever it thinks needs it (a no-op on a database whose
  # statistics are current — SQLite keeps the decision internal, bounded by
  # its own heuristics). Nothing else in the codebase ever runs it
  # (`sqlite_stat1` did not exist), so the query planner picked the composite
  # indexes without statistics.
  #
  # WHERE: on the BOOT connection, right after the migration run — that is the
  # connection which just applied the DDL, so it is the one that definitely
  # has the migrated schema loaded (a fresh pool connection loads the schema
  # lazily; see `reopen_pool/3`). For any pool size > 1 the call happens
  # before the reopen, i.e. before the returned pool exists.
  #
  # SAFETY: statistics are an optimization, never a boot requirement —
  # `EvoGit.Store.Maintenance.optimize/1` is total (try/rescue + catch,
  # `:warning` log, returns `:ok | {:error, term}`), and this wrapper is
  # belt-and-braces so even a raise from the seam below cannot fail a boot.
  # Test seam: the `:store_boot_optimize_fun` app env (defaults to
  # `&EvoGit.Store.Maintenance.optimize/1`).
  defp optimize_after_migrations(pid) do
    fun =
      Application.get_env(
        :evo_git,
        :store_boot_optimize_fun,
        &EvoGit.Store.Maintenance.optimize/1
      )

    _ = fun.(pid)
    :ok
  rescue
    error ->
      Logger.warning(
        "[Store.Boot] PRAGMA optimize after migrations failed (ignored): " <>
          Exception.message(error)
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "[Store.Boot] PRAGMA optimize after migrations failed (ignored): " <>
          inspect({kind, reason})
      )

      :ok
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

  The compile path takes the SAME migration lock as the migration run, so a
  lock that cannot be taken fails here EXACTLY as it does in
  `run_migrations/1`: this function raises the same
  `RuntimeError` (`"task-store migration lock unavailable; refusing to report
  a successful boot"`) instead of returning the bare `:aborted` atom, which
  would contradict the documented `[{integer(), module()}]` result. A memoized
  source needs no lock and is always returned as-is.
  """
  @spec migration_source() :: [{integer(), module()}]
  def migration_source do
    case cached_migration_source() do
      nil ->
        reject_lock_unavailable(with_migration_lock(&load_migration_source/0))

      source ->
        source
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
    with_migration_lock(fn -> EvoGit.Store.HistoricalSources.run(load_migration_source()) end)
  end

  # The PUBLIC contract keeps its version list (`mix migrate.store` and many
  # tests pin `run_migrations/1 == []` / `== [version]`); only the lock failure
  # becomes a raise, because returning a list for it would be a lie.
  defp reject_lock_unavailable({:error, :migration_lock_unavailable}) do
    raise RuntimeError, @migration_lock_unavailable
  end

  defp reject_lock_unavailable(versions) when is_list(versions), do: versions

  # THE one lock-taking point, shared by `migrate_synchronized!/0` and
  # `migration_source/0` — so the lock-failure outcome is decided ONCE and the
  # two paths can never diverge.
  #
  # `:global.trans/2` answers the BARE ATOM `:aborted` when the lock cannot be
  # taken (the fun never ran). That atom must NEVER be discarded or handed back
  # as a result: every caller treats the return value as "the migration versions
  # applied", so a discarded `:aborted` reported a SUCCESSFUL boot for a database
  # where NO migration ran — a schema-less task store that then serves reads and
  # writes. Normalizing it HERE keeps that ONE mapping, and
  # `reject_lock_unavailable/1` turns it into the ONE
  # `@migration_lock_unavailable` raise for both callers.
  #
  # The lock FUNCTION is a default-inert call-time seam (`:store_boot_lock_fun`,
  # read HERE at the call site — the same pattern as `:store_boot_optimize_fun`
  # and `EvoGit.Platform.config_dir/1`'s `:config_dir_fun`): on OTP 29
  # `:global.trans/2` retries until it is granted, so the `:aborted` arm below
  # would otherwise be unreachable and untestable. An absent pin answers
  # `&:global.trans/2`, i.e. behaviour byte-identical to the pre-seam code.
  defp with_migration_lock(fun) do
    case migration_lock_fun().({:evo_git_store_migrations, self()}, fun) do
      :aborted -> {:error, :migration_lock_unavailable}
      result -> result
    end
  end

  defp migration_lock_fun do
    Application.get_env(:evo_git, :store_boot_lock_fun, &:global.trans/2)
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
  #
  # The path comes from the repo's RUNTIME CONFIG (`EvoGit.Repo.config/0`, the
  # app-config database): Ecto does not expose a dynamic instance's start-opts
  # `database:` as config, which is why `start_dynamic/2` ensures the parent dir
  # of the database IT was given through the same `ensure_dir!/1`.
  defp ensure_database_dir! do
    case repo_config_database() do
      {:ok, database} -> ensure_dir!(Path.dirname(Path.expand(database)))
      :error -> :ok
    end
  end

  # `File.mkdir_p/1` answers `{:error, posix}` — matching only `:ok` turned a
  # POSIX failure into an opaque `MatchError` that never named the directory.
  # Name the path and the cause instead (still a raise: no store can boot
  # without its parent dir).
  defp ensure_dir!(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "make directory (with -p)", path: dir
    end
  end

  # Best-effort config probe: `EvoGit.Repo.config/0` can raise for an
  # unstarted/broken repo (`init_config/4` fails), and the parent-dir
  # pre-creation is a nicety whose absence must never fail a boot — the
  # adapter still resolves/creates its own database file.
  defp repo_config_database do
    config = @repo.config()
    Keyword.fetch(config, :database)
  rescue
    _e in _ -> :error
  end
end
