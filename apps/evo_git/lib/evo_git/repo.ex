defmodule EvoGit.Repo do
  @moduledoc """
  Ecto repository for the EvoGit task store, backed by SQLite via the
  `XqliteEcto3` adapter.

  Not added to the application supervision tree — `EvoGit.Store` instances own
  their repo lifecycles (this wave adds the infrastructure beside the raw-SQL
  store; the canonical instance is started on demand).

  ## Usage shapes

  **Canonical named instance** (application-wide, default database under the
  platform data dir — resolved at runtime by `init/2`):

      {:ok, pid} = EvoGit.Repo.start_link()

  **Per-store UNNAMED dynamic instances** — the design chosen for test
  isolation and per-store ownership: many same-named `EvoGit.Store` instances
  each own an unnamed repo pointed at their own database file, so there are no
  global name collisions:

      {:ok, pid} = EvoGit.Repo.start_link(database: tmp_path)
      EvoGit.Repo.put_dynamic_repo(pid)
      # every subsequent EvoGit.Repo.* call in this process targets pid's DB

  An unnamed instance is passed around BY PID. All repo entry points
  (`Ecto.Migrator.run/3`, `XqliteEcto3.with_xqlite/2`, `Repo.query/3`, ...)
  resolve the caller's target through `EvoGit.Repo.put_dynamic_repo/1` /
  `get_dynamic_repo/0` (process-dictionary based), so a process that never
  called `put_dynamic_repo/1` transparently addresses the canonical named
  instance.

  Stopping an unnamed instance cleanly requires `Supervisor.stop(pid,
  :normal)` — `Repo.stop/0` operates on the CALLER's `get_dynamic_repo()`,
  which is not necessarily the pid you want to stop (see
  `EvoGit.Store.Boot.stop/1`).

  ## Configuration

  `init/2` resolves the runtime configuration: `database:` comes from the
  start opts (keyword passed to `start_link/1`), falling back to
  `Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())`
  joined with `"tasks.sqlite"`. The defaults below are merged with start-opts
  winning. No `:url` support — the database path is always resolved here.
  """

  use Ecto.Repo,
    otp_app: :evo_git,
    adapter: XqliteEcto3

  @doc """
  Runtime configuration callback for `use Ecto.Repo`.

  Resolves `database:` at runtime — `Application` env is read at
  `start_link/1` time (per instance), NOT at compile time — and merges the
  EvoGit SQLite defaults (start opts win on every key):

    * `journal_mode: :wal` — matches the raw `EvoGit.Store` connection setup
    * `synchronous: :normal` — WAL's recommended durability level
    * `busy_timeout: 30_000` — matches the store's 30s call timeout budget
      (the adapter default is only 5s)
    * `pool_size: 2` — SQLite is a single-writer database; 2 connections
      cover one writer + one reader
    * `default_transaction_mode: :immediate` — the adapter's default, kept
      explicitly (BEGIN IMMEDIATE avoids SQLITE_BUSY upgrade deadlocks)
    * `timeout: 30_000` — query timeout
    * `ownership_timeout: 30_000` — sandbox/checkout ownership timeout
  """
  @impl Ecto.Repo
  def init(_type, opts) do
    config =
      opts
      |> Keyword.put_new_lazy(:database, &default_database/0)
      |> Keyword.merge(defaults(), fn _k, start_opt, _default -> start_opt end)

    {:ok, config}
  end

  defp default_database do
    :evo_git
    |> Application.get_env(:data_dir, EvoGit.Platform.data_dir())
    |> Path.join("tasks.sqlite")
  end

  defp defaults do
    [
      journal_mode: :wal,
      synchronous: :normal,
      busy_timeout: 30_000,
      pool_size: 2,
      default_transaction_mode: :immediate,
      timeout: 30_000,
      ownership_timeout: 30_000
    ]
  end
end
