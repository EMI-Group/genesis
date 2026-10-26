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

  ## Where the EFFECTIVE DBConnection budget lives (`start_opts/0`, not `defaults/0`)

  Precedence, innermost first:

    1. `Ecto.Repo.Supervisor.init_config/4` merges its OWN `@defaults`
       (`timeout: 15_000, pool_size: 10`) into the config and then merges the
       `start_link/1` opts over them — so those values ARRIVE HERE AS START
       OPTS on every start, including a bare `EvoGit.Repo.start_link()`.
    2. `init/2` merges `defaults/0` UNDER the incoming config (start opts win).

  A key present in BOTH `defaults/0` and the incoming start opts is therefore
  DEAD in `defaults/0` — the start opts always win. That is exactly why the
  old `timeout: 30_000` here never took effect: Ecto's 15 s arrived as a
  start opt and the repo really ran with a 15 s DBConnection budget (the 15 s
  in production `DBConnection.ConnectionError`s), not the 30 s the code read
  as.

  The effective values are now stated ONCE, in `start_opts/0`, and passed as
  START OPTS by `EvoGit.Store.Boot.start_dynamic/2` (every per-store dynamic
  instance, i.e. every production store boot) and by `mix store.maintenance`.
  `defaults/0` keeps only the keys that are not overridden by Ecto's
  `@defaults`: the connection PRAGMAs, the transaction mode, the ownership
  timeout and a fallback pool size (`pool_size` from `@defaults` would
  otherwise silently become 10 for a direct `start_link/1` that passes none).
  """

  use Ecto.Repo,
    otp_app: :evo_git,
    adapter: XqliteEcto3

  # ── DBConnection tuning (the EFFECTIVE values — see the moduledoc) ───────
  #
  # `@db_timeout` is the per-statement/checkout budget DBConnection enforces.
  # 60 s: the store's own facade timeout is 30 s per call, and a large
  # `put_task` (multi-megabyte rows) or a cleanup burst on high-latency
  # storage (NFS-mounted home dir) can exceed the old 15 s budget — which
  # DBConnection reports by DROPPING the request with
  # `DBConnection.ConnectionError: query timed out` and disconnecting the
  # connection, not by failing the statement. The DB budget is deliberately
  # the OUTER, more forgiving bound: the caller-visible cap stays the store's
  # 30 s `@call_timeout`.
  @db_timeout 60_000

  # The pool's adaptive queue bounds. DBConnection's defaults are
  # `queue_target: 50` ms / `queue_interval: 2_000` ms: when checkouts wait
  # longer than the target on average across an interval, DBConnection starts
  # DROPPING queued requests (`DBConnection.ConnectionError`) instead of
  # waiting for the caller's budget. 50 ms is far below a legitimately slow
  # read on a cold 400 MB database, so a page load could be dropped while a
  # sibling read was still in flight. 500 ms / 5 s keeps backpressure (a
  # genuinely saturated pool still sheds load) without turning a normal cold
  # read into a dropped request.
  @queue_target 500
  @queue_interval 5_000

  # SQLite page cache PER CONNECTION, in KiB (`-N` = N KiB, positive = pages).
  # The adapter default is `-64_000` (64 MiB) — at the store's 6-connection
  # pool that is ~375 MiB of page cache for ONE store, per BEAM process, and
  # every per-store dynamic instance (including the hundreds the test suite
  # boots) pays it. `-8_000` = 8 MiB per connection → 6 × 8 MiB ≈ 47 MiB total
  # for the production pool: the dashboard's hot working set is the recent
  # task rows/index pages, not the whole file (442 MB live), so the smaller
  # cache costs a few extra page reads on a cold scan while bounding resident
  # memory on a laptop/CI box with many stores. `temp_store: :memory` is kept
  # (and passed explicitly so it cannot drift with an adapter default change):
  # big sorts and temp b-trees stay in RAM instead of spilling temp files, at
  # a size bounded by SQLite's own temp-store limits.
  @cache_size -8_000
  @temp_store :memory

  @doc """
  The runtime tuning every store boot passes as START OPTS (see the moduledoc
  for why these cannot live in `defaults/0`).

    * `:timeout` — `#{@db_timeout}` ms DBConnection budget
    * `:queue_target` / `:queue_interval` — `#{@queue_target}` / `#{@queue_interval}` ms
    * `:cache_size` — `#{@cache_size}` KiB (8 MiB) SQLite page cache per connection
    * `:temp_store` — `#{inspect(@temp_store)}`

  Deliberately does NOT include `:pool_size` or `:database`: both are per
  instance, resolved by the caller and merged AFTER these (see
  `EvoGit.Store.Boot.start_dynamic/2`).
  """
  @spec start_opts() :: keyword()
  def start_opts do
    [
      timeout: @db_timeout,
      queue_target: @queue_target,
      queue_interval: @queue_interval,
      cache_size: @cache_size,
      temp_store: @temp_store
    ]
  end

  @doc """
  Runtime configuration callback for `use Ecto.Repo`.

  Resolves `database:` at runtime — `Application` env is read at
  `start_link/1` time (per instance), NOT at compile time — and merges the
  EvoGit SQLite defaults UNDER the incoming config (start opts win on every
  key):

    * `journal_mode: :wal` — matches the raw `EvoGit.Store` connection setup
    * `synchronous: :normal` — WAL's recommended durability level
    * `busy_timeout: 30_000` — matches the store's 30 s call timeout budget
      (the adapter default is only 5 s)
    * `pool_size: 2` — FALLBACK only: every store boot passes its own size
      (`EvoGit.Store.Boot.default_pool_size/0`), and without this key Ecto's
      `@defaults` `pool_size: 10` would apply to a bare `start_link/1`
    * `default_transaction_mode: :immediate` — the adapter's default, kept
      explicitly (BEGIN IMMEDIATE avoids SQLITE_BUSY upgrade deadlocks)
    * `ownership_timeout: 30_000` — sandbox/checkout ownership timeout

  `:timeout`, `:queue_target`/`:queue_interval` and `:cache_size` are NOT
  here — they are start opts (`start_opts/0`); see the moduledoc.
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
      ownership_timeout: 30_000
    ]
  end
end
