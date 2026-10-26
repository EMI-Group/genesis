defmodule EvoGit.Store.MaintenanceTest do
  @moduledoc """
  Tests for the store's connection/pool tuning and its SQLite maintenance:

    * the EFFECTIVE DBConnection budget — asserted on the LIVE pool, not on
      `EvoGit.Repo.config/0` (which re-runs `init/2` with NO start opts and
      therefore reports Ecto's own `@defaults`, the exact trap that made the
      old `timeout: 30_000` in `defaults/0` dead). `connection_opts!/1` reads
      the real `DBConnection.Connection` state of a pooled connection;
    * the ONE boot-time `PRAGMA optimize` (through the
      `:store_boot_optimize_fun` seam) and that a raised seam cannot fail boot;
    * `EvoGit.Store.Maintenance` — no tick at boot, an on-demand tick, and a
      tick against an absent/restarting store being harmless;
    * `mix store.maintenance` — size reporting, `--vacuum`,
      `--no-optimize`, and the database staying readable.

  `async: false`: the boot-optimize tests swap a global app env, and the
  maintenance GenServer tests are message/timer based.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  require Ecto.Query

  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Maintenance
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.ProjectRow

  @moduletag :tmp_dir

  @db_filename "tasks.sqlite"

  # Every shipped store migration (the rejected compression migration 004 no
  # longer ships, so `schema_migrations` stops at 7 rows).
  @migration_count 7

  # ── Fake store (the maintenance GenServer's `__repo_pid__` peer) ──────────
  #
  # Answers the ONE call `EvoGit.Store.Maintenance` makes, and reports it to the
  # test process — that is how "no tick at boot" is observable without waiting
  # for the 60-minute timer.
  defmodule FakeStore do
    use GenServer

    def start_link({parent, repo}), do: GenServer.start_link(__MODULE__, {parent, repo})

    @impl true
    def init({parent, repo}), do: {:ok, {parent, repo}}

    @impl true
    def handle_call(:__repo_pid__, _from, {parent, repo} = state) do
      send(parent, {:repo_pid_called, repo})
      {:reply, repo, state}
    end
  end

  # ── Connection tuning (the exact values `EvoGit.Repo.start_opts/0` sets) ──

  describe "connection and pool tuning" do
    test "EvoGit.Repo.start_opts/0 is the single source of the DB budget" do
      opts = Repo.start_opts()

      assert opts[:timeout] == 60_000
      assert opts[:queue_target] == 500
      assert opts[:queue_interval] == 5_000
      assert opts[:cache_size] == -8_000
      assert opts[:temp_store] == :memory
      # Per instance, resolved by the caller — never baked into the shared list.
      refute Keyword.has_key?(opts, :pool_size)
      refute Keyword.has_key?(opts, :database)
    end

    test "the production pool default is 6 connections" do
      # An infra constant (README/CONTEXT numbers depend on it), deliberately
      # pinned here so a silent change is caught: 6 = the single writer slot
      # plus 5 concurrent readers, at 8 MiB of page cache each.
      assert Boot.default_pool_size() == 6
    end

    test "a booted store's real connections run with the tuned budget", %{tmp_dir: dir} do
      pid = start_repo!(dir, "conn_opts")
      opts = connection_opts!(pid)

      # The 15 s Ecto default / 30 s dead default must NOT win any more.
      assert opts[:timeout] == 60_000
      assert opts[:queue_target] == 500
      assert opts[:queue_interval] == 5_000

      # The per-store pool size reaches the pool itself — asserted through the
      # pool's own idle-connection count, not just the config.
      assert opts[:pool_size] == Boot.default_pool_size()
      assert await_ready_connections(pid, Boot.default_pool_size()) == 6

      # The remaining DBConnection pool opt is untouched.
      assert opts[:ownership_timeout] == 30_000

      # And the LIVE pool state carries the same queue bounds.
      %{pid: pool} = Ecto.Adapter.lookup_meta(pid)
      {_status, _queue, %{target: target, interval: interval}, _} = :sys.get_state(pool)
      assert target == 500
      assert interval == 5_000
    end

    test "the page cache and temp store pragmas are applied per connection", %{tmp_dir: dir} do
      pid = start_repo!(dir, "conn_pragmas")

      # `-8_000` KiB = 8 MiB per connection (6 × 8 MiB ≈ 47 MiB per store),
      # down from the adapter default `-64_000` (64 MiB per connection).
      assert RepoScope.with_repo(pid, fn -> Repo.query!("PRAGMA cache_size").rows end) == [
               [-8_000]
             ]

      # temp_store = 2 is SQLite's numeric value for `:memory`.
      assert RepoScope.with_repo(pid, fn -> Repo.query!("PRAGMA temp_store").rows end) == [[2]]
    end

    test "a per-store :pool_size still overrides the default", %{tmp_dir: dir} do
      pid = start_repo!(dir, "conn_opts_one", pool_size: 1)
      opts = connection_opts!(pid)

      assert opts[:pool_size] == 1
      assert await_ready_connections(pid, 1) == 1
      # The rest of the tuning is shared by every instance.
      assert opts[:timeout] == 60_000

      assert RepoScope.with_repo(pid, fn -> Repo.query!("PRAGMA cache_size").rows end) == [
               [-8_000]
             ]
    end
  end

  # ── Boot-time PRAGMA optimize ────────────────────────────────────────────

  describe "boot-time PRAGMA optimize" do
    test "runs exactly once, after the migrations, on the boot connection", %{tmp_dir: dir} do
      parent = self()

      Application.put_env(:evo_git, :store_boot_optimize_fun, fn pid ->
        send(parent, {:boot_optimize, pid})
        :ok
      end)

      on_exit(fn -> Application.delete_env(:evo_git, :store_boot_optimize_fun) end)

      pid = start_repo!(dir, "boot_optimize")

      assert_receive {:boot_optimize, boot_pid}, 2_000
      assert is_pid(boot_pid)
      # Exactly ONCE per boot (the reopened pool must not re-run it).
      refute_receive {:boot_optimize, _other}, 200

      # The returned instance is usable and migrated.
      assert migration_count(pid) == @migration_count
    end

    test "a raising optimize seam cannot fail boot", %{tmp_dir: dir} do
      Application.put_env(:evo_git, :store_boot_optimize_fun, fn _pid -> raise "boom" end)
      on_exit(fn -> Application.delete_env(:evo_git, :store_boot_optimize_fun) end)

      log =
        capture_log(fn ->
          pid = start_repo!(dir, "boot_optimize_raise")
          assert Process.alive?(pid)
          assert RepoScope.with_repo(pid, fn -> Repo.query!("SELECT 1").rows end) == [[1]]
        end)

      assert log =~ "PRAGMA optimize after migrations failed (ignored)"
    end

    test "the default seam really runs PRAGMA optimize against the migrated schema",
         %{tmp_dir: dir} do
      # No seam override here: Boot calls `EvoGit.Store.Maintenance.optimize/1`.
      # `PRAGMA optimize` is idempotent and schema-aware — assert the booted
      # database accepts it and keeps working, then that a second explicit call
      # is a no-op rather than an error.
      pid = start_repo!(dir, "boot_optimize_default")

      assert Maintenance.optimize(pid) == :ok
      assert migration_count(pid) == @migration_count
    end
  end

  # ── EvoGit.Store.Maintenance ─────────────────────────────────────────────

  describe "EvoGit.Store.Maintenance.optimize/1" do
    test "returns :ok on a live repo and the database stays readable", %{tmp_dir: dir} do
      pid = start_repo!(dir, "optimize_live")

      assert Maintenance.optimize(pid) == :ok

      assert RepoScope.with_repo(pid, fn -> Repo.query!("SELECT 1").rows end) == [[1]]
      assert migration_count(pid) == @migration_count
    end

    test "never raises when the repo is gone — returns {:error, _}" do
      log =
        capture_log(fn ->
          dead =
            spawn(fn ->
              receive do
                :never -> :ok
              end
            end)

          ref = Process.monitor(dead)
          Process.exit(dead, :kill)
          assert_receive {:DOWN, ^ref, :process, ^dead, :killed}, 2_000

          assert {:error, _reason} = Maintenance.optimize(dead)
        end)

      assert log =~ "PRAGMA optimize failed (ignored)"
    end
  end

  describe "EvoGit.Store.Maintenance.run/1" do
    test "optimizes an isolated store's own repo", %{tmp_dir: dir} do
      path = db_path(dir, "run_isolated")
      store = unique_name(:evogit_maint_store)

      {:ok, store_pid} = Store.start_link(data_dir: path, name: store)
      Process.unlink(store_pid)

      on_exit(fn ->
        if Process.alive?(store_pid), do: GenServer.stop(store_pid)
        remove_db(path)
      end)

      assert Maintenance.run(store) == :ok
      # The store is untouched and still serving.
      assert Store.count_tasks(store) == 0
    end

    test "an absent store is an {:error, _}, not a crash" do
      log = capture_log(fn -> assert {:error, _reason} = Maintenance.run(:absent_store_name) end)

      assert log =~ "unavailable, skipping maintenance"
    end
  end

  describe "EvoGit.Store.Maintenance GenServer" do
    test "no tick at boot; an explicit tick runs one pass", %{tmp_dir: dir} do
      repo = start_repo!(dir, "maint_server")
      parent = self()

      fake_store = start_supervised!({FakeStore, {parent, repo}})

      server =
        start_supervised!({Maintenance, name: unique_name(:evogit_maint), store: fake_store})

      # Nothing at boot — the boot path already optimized.
      refute_receive {:repo_pid_called, _repo}, 200

      assert Maintenance.tick(server) == :ok
      assert_receive {:repo_pid_called, ^repo}, 2_000
      assert Process.alive?(server)
    end

    test "a tick against an absent store is harmless and the timer survives" do
      log =
        capture_log(fn ->
          server =
            start_supervised!(
              {Maintenance, name: unique_name(:evogit_maint_absent), store: :absent_store_name}
            )

          assert {:error, _reason} = Maintenance.tick(server)
          assert Process.alive?(server)
          # Still the same process after the failed pass: the periodic loop
          # reschedules regardless of the outcome.
          assert {:error, _reason} = Maintenance.tick(server)
          assert Process.alive?(server)
        end)

      assert log =~ "unavailable, skipping maintenance"
    end

    test "the interval is a 60-minute constant" do
      assert Maintenance.interval_ms() == 60 * 60 * 1_000
    end
  end

  # ── mix store.maintenance ────────────────────────────────────────────────

  describe "mix store.maintenance" do
    test "reports the file size before/after and leaves the database readable",
         %{tmp_dir: dir} do
      path = Path.join(dir, @db_filename)
      seed_db!(path, 3)

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Store.Maintenance.run(["--data-dir", dir])
        end)

      assert output =~ "==> Task database: #{path}"
      assert output =~ "Before: main file"
      assert output =~ "After:  main file"
      assert output =~ "freelist"
      assert output =~ "auto_vacuum none"
      assert output =~ "PRAGMA optimize: ok"
      assert output =~ "VACUUM:          skipped (pass --vacuum to reclaim space)"
      assert output =~ "Done —"
      # Sizes really are numbers, not "unknown".
      refute output =~ "main file unknown"

      assert row_count(path) == 3
      assert migration_count_on_file(path) == @migration_count
    end

    test "--no-optimize skips the optimizer and still reports", %{tmp_dir: dir} do
      path = Path.join(dir, @db_filename)
      seed_db!(path, 1)

      output =
        capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Store.Maintenance.run(["--data-dir", dir, "--no-optimize"])
        end)

      assert output =~ "PRAGMA optimize: skipped (--no-optimize)"
      assert output =~ "Before: main file"
      assert output =~ "After:  main file"
      assert row_count(path) == 1
    end

    test "--vacuum switches auto_vacuum to incremental and keeps the DB readable",
         %{tmp_dir: dir} do
      path = Path.join(dir, @db_filename)
      seed_db!(path, 2)

      assert auto_vacuum(path) == 0

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Store.Maintenance.run(["--data-dir", dir, "--vacuum"])
        end)

      assert output =~ "VACUUMed (auto_vacuum none before)"
      assert output =~ "auto_vacuum switched to incremental"
      assert output =~ "Done —"
      assert auto_vacuum(path) == 2
      assert row_count(path) == 2
    end

    test "a missing database is a clear Mix error", %{tmp_dir: dir} do
      error =
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Store.Maintenance.run(["--data-dir", dir])
        end

      assert error.message =~ "No task database found at #{Path.join(dir, @db_filename)}"
    end

    test "an unknown option is rejected before any repo work", %{tmp_dir: dir} do
      error =
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Store.Maintenance.run(["--data-dir", dir, "--nope"])
        end

      assert error.message =~ "Unknown or invalid option(s)"
      assert error.message =~ "Usage: mix store.maintenance"

      error =
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Store.Maintenance.run(["--data-dir", dir, "stray-arg"])
        end

      assert error.message =~ "Unexpected argument(s)"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_repo!(dir, tag, opts \\ []) do
    path = db_path(dir, tag)
    {:ok, pid} = Boot.start_dynamic(path, opts)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: :ok = Boot.stop(pid)
      remove_db(path)
    end)

    pid
  end

  defp db_path(dir, tag) do
    unique = System.unique_integer([:positive, :monotonic])
    Path.join(dir, "evogit_#{tag}_#{unique}.sqlite")
  end

  defp remove_db(path) do
    File.rm(path)
    File.rm(path <> "-wal")
    File.rm(path <> "-shm")
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  # The EFFECTIVE pool/DBConnection start opts of an instance. Ecto's adapter
  # meta keeps `Keyword.take(config, @pool_opts)` of the config the connection
  # child was actually started with — i.e. AFTER `EvoGit.Repo.init/2` merged the
  # start opts. `EvoGit.Repo.config/0` is NOT usable for this: it re-runs
  # `init/2` without the start opts, so it reports Ecto's `@defaults`
  # (15 s / pool 10) regardless of what the pool actually runs with.
  defp connection_opts!(repo_pid) do
    %{opts: opts} = Ecto.Adapter.lookup_meta(repo_pid)
    opts
  end

  # The pool's idle-connection count, polled because connections connect
  # asynchronously (same seam as `pool_size_test.exs`).
  defp await_ready_connections(repo_pid, expected, attempts \\ 200) do
    %{pid: pool} = Ecto.Adapter.lookup_meta(repo_pid)
    [%{ready_conn_count: ready} | _] = DBConnection.get_connection_metrics(pool)

    cond do
      ready == expected ->
        ready

      attempts > 1 ->
        Process.sleep(10)
        await_ready_connections(repo_pid, expected, attempts - 1)

      true ->
        flunk("expected #{expected} pooled connections, got #{ready}")
    end
  end

  defp migration_count(repo_pid) do
    RepoScope.with_repo(repo_pid, fn ->
      Repo.aggregate(Ecto.Query.from(m in "schema_migrations"), :count)
    end)
  end

  # Inserts `count` project rows through the migrated repo, then closes it — a
  # small, realistic database for the mix task.
  defp seed_db!(path, count) do
    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)

    RepoScope.with_repo(pid, fn ->
      Repo.insert_all(
        ProjectRow,
        for i <- 1..count do
          [
            path: "/seed/#{i}",
            name: "Seed #{i}",
            last_opened_at: ~U[2024-05-05 05:05:05.555Z]
          ]
        end
      )
    end)

    :ok = Boot.stop(pid)
    :ok
  end

  ## Raw-file readers (never a live repo — the task under test has closed its own)

  defp raw_query(path, sql) do
    {:ok, conn} = Xqlite.open(path)

    try do
      {:ok, %{rows: rows}} = Xqlite.query(conn, sql, [])
      rows
    after
      XqliteNIF.close(conn)
    end
  end

  defp row_count(path) do
    [[count]] = raw_query(path, "SELECT COUNT(*) FROM projects")
    count
  end

  defp migration_count_on_file(path) do
    [[count]] = raw_query(path, "SELECT COUNT(*) FROM schema_migrations")
    count
  end

  defp auto_vacuum(path) do
    [[mode]] = raw_query(path, "PRAGMA auto_vacuum")
    mode
  end
end
