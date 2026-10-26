defmodule EvoGit.Store.Maintenance do
  @moduledoc """
  Periodic, best-effort SQLite maintenance for the task store.

  A supervised `GenServer` (child of `EvoGit.App`'s tree, AFTER `EvoGit.Store`)
  that runs `PRAGMA optimize` against the store's OWN dynamic repo once every
  60 minutes (`interval_ms/0`) so the query planner's statistics track the
  schema and data that accumulate over a task database's life. Nothing else in
  the codebase ever ran `PRAGMA optimize`/`ANALYZE`, so `sqlite_stat1` never
  existed and the composite `(equality column, started_at)` indexes were
  chosen without statistics.

  ## Design constraints

    * **No tick at boot.** `EvoGit.Store.Boot.start_dynamic/2` already runs
      `PRAGMA optimize` ONCE on the connection that applied the migrations
      (`optimize/1` is that same call — one implementation). The first
      periodic tick is the full interval after start.
    * **Never crashes the application.** Every tick is total: the store's repo
      pid is resolved defensively (the store may be absent at boot order
      edges, restarting after a crash, or stopped in a short-lived script) and
      `PRAGMA optimize` is wrapped in `try/rescue` + `catch` with a
      `Logger.warning`. A failed maintenance pass is logged and skipped; the
      timer is always rescheduled.
    * **Never interferes with writes.** `PRAGMA optimize` is issued on the
      pool (via `EvoGit.Store.RepoScope.with_repo/2`, so it targets the store's
      own instance from this process) — the store's writes stay serialized
      through `EvoGit.Store.Writer`, and SQLite's `busy_timeout` (30 s)
      absorbs a transient lock.
    * **No `VACUUM` here, ever.** Vacuuming rewrites the whole file and needs
      exclusive access; it is an on-demand operation (`mix store.maintenance
      --vacuum`), never an automatic one.

  ## Test seams

  `tick/1` triggers one pass through the GenServer (the exact code path the
  timer takes) and `run/1` is the underlying resolve-and-optimize pass for an
  explicitly named store; `optimize/1` runs `PRAGMA optimize` against a repo
  pid. All three are `@doc false`.
  """

  use GenServer

  require Logger

  alias EvoGit.Store.RepoScope

  @repo EvoGit.Repo

  # One hour between maintenance passes. A constant, not user config: the
  # planner statistics only need to track gradual schema/data drift, and a
  # more frequent pass would spend I/O for no benefit.
  @interval_ms 60 * 60 * 1_000

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: @interval_ms

  @doc false
  @spec tick(GenServer.server()) :: :ok | {:error, term()}
  def tick(server \\ __MODULE__) do
    GenServer.call(server, :tick)
  end

  # Resolves `store`'s own dynamic repo pid and runs one `PRAGMA optimize` pass.
  # Best-effort by contract: returns `:ok` or `{:error, reason}` and never
  # raises (an absent/restarting store is an `{:error, _}`, not a crash).
  @doc false
  @spec run(GenServer.server()) :: :ok | {:error, term()}
  def run(store \\ EvoGit.Store) do
    case resolve_repo(store) do
      {:ok, repo} -> optimize(repo)
      {:error, reason} -> {:error, reason}
    end
  end

  # Runs `PRAGMA optimize` against `repo` (a dynamic `EvoGit.Repo` pid).
  #
  # TOTAL BY CONSTRUCTION — it is what makes both the boot-time call
  # (`EvoGit.Store.Boot.start_dynamic/2`) and every periodic tick safe: any
  # failure (locked database, an adapter/SQLite that rejects the pragma, a repo
  # shutting down mid-call) is logged at `:warning` and returned as
  # `{:error, reason}`; nothing is raised or reraised.
  @doc false
  @spec optimize(pid()) :: :ok | {:error, term()}
  def optimize(repo) when is_pid(repo) do
    RepoScope.with_repo(repo, fn -> @repo.query!("PRAGMA optimize") end)
    :ok
  rescue
    error ->
      Logger.warning(
        "[Store.Maintenance] PRAGMA optimize failed (ignored): " <> Exception.message(error)
      )

      {:error, error}
  catch
    kind, reason ->
      Logger.warning(
        "[Store.Maintenance] PRAGMA optimize failed (ignored): " <> inspect({kind, reason})
      )

      {:error, {kind, reason}}
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    store = Keyword.get(opts, :store, EvoGit.Store)

    # Deliberately NO immediate tick: the boot path already optimized on the
    # migrated connection (see the moduledoc). `send_after` (not `:timer`)
    # keeps the timer in this process's mailbox.
    schedule_next()

    {:ok, %{store: store}}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    {:reply, run(state.store), state}
  end

  @impl true
  def handle_info(:maintain, state) do
    # `run/1` never raises; the reschedule below therefore always happens.
    _ = run(state.store)
    schedule_next()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Helpers

  defp schedule_next do
    Process.send_after(self(), :maintain, @interval_ms)
    :ok
  end

  # The store GenServer may be absent (boot-order edge), restarting after a
  # crash, or unreachable — `EvoGit.Store.__repo_pid__/1` is a `GenServer.call`
  # that EXITS in those cases (`:noproc`, a restart-time `:timeout`, or the
  # store's own exit). All of them mean "skip this pass", never "crash the
  # maintenance process".
  defp resolve_repo(store) do
    {:ok, EvoGit.Store.__repo_pid__(store)}
  rescue
    error ->
      Logger.warning(
        "[Store.Maintenance] store #{inspect(store)} unavailable, skipping maintenance: " <>
          Exception.message(error)
      )

      {:error, error}
  catch
    kind, reason ->
      Logger.warning(
        "[Store.Maintenance] store #{inspect(store)} unavailable, skipping maintenance: " <>
          inspect({kind, reason})
      )

      {:error, {kind, reason}}
  end
end
