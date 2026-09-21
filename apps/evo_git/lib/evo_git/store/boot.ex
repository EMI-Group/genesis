defmodule EvoGit.Store.Boot do
  @moduledoc """
  Boot-time Ecto migration runner for the EvoGit task store.

  Runs the Ecto migrations in `priv/repo/migrations/` (baseline adoption +
  data normalization) against a repo — either the canonical named
  `EvoGit.Repo` instance or a per-store UNNAMED dynamic instance — before
  any store read/write, mirroring the always-migrate-at-boot contract of the
  raw-SQL `EvoGit.Store.init/1` pipeline. `Ecto.Migrator.run/3` with
  `all: true` is a no-op when the database is current.

  ## Usage

  Canonical instance (must already be started):

      EvoGit.Repo.start_link()
      EvoGit.Store.Boot.run_migrations()

  Per-store dynamic instance — start, migrate, use, stop:

      {:ok, pid} = EvoGit.Store.Boot.start_dynamic(db_path)
      EvoGit.Repo.put_dynamic_repo(pid)
      # ... repo usage ...
      EvoGit.Store.Boot.stop(pid)

  No GenServer, no global state: `run_migrations/1` sets the caller's
  dynamic repo (restoring the previous binding afterwards), so migrations
  run against the intended instance even when several coexist.
  """

  @repo EvoGit.Repo

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

    previous = @repo.put_dynamic_repo(pid)

    try do
      Ecto.Migrator.run(@repo, :up, all: true)
    after
      @repo.put_dynamic_repo(previous)
    end
  end

  def run_migrations(opts) when is_list(opts) do
    ensure_database_dir!(@repo.get_dynamic_repo())
    Ecto.Migrator.run(@repo, :up, all: true)
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

  ## Shared

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
