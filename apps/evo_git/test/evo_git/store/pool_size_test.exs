defmodule EvoGit.Store.PoolSizeTest do
  @moduledoc """
  The store's DBConnection pool size: the default (> 1), the per-store
  `:pool_size` override (threaded `EvoGit.Store.start_link/1` →
  `EvoGit.Store.Boot.start_dynamic/2`), and the behaviour that motivates the
  default — reads are served on SEPARATE pooled connections instead of every
  query queueing on one.

  Why > 1 is safe (nothing here relies on hope): the journal is WAL, so readers
  and the writer run concurrently; and the store has exactly ONE writer path —
  every write goes through the `EvoGit.Store` GenServer, which already
  serializes them — so extra connections cannot introduce write-write
  contention (the 30 s `busy_timeout` covers a transient lock window). The
  pool size is therefore purely a READ-parallelism knob.

  Measurements run through `DBConnection.get_connection_metrics/1` (the pool's
  own idle-connection count — Ecto exposes no pool-size API) and through REAL
  checkouts: a connection held open in a second process must not stop the test
  process's own query, and at `pool_size: 1` the same query must be stuck.
  Both directions are asserted, so neither assertion can silently stop
  testing anything.
  """

  # NOT async: the timing-sensitive concurrency assertions below deserve a
  # quiet machine (a queue wait has only a sub-millisecond margin to be
  # observably fast), and these tests stop/start their own repos.
  use ExUnit.Case, async: false

  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.Boot
  alias EvoGit.Store.RepoScope

  describe "EvoGit.Store.Boot.start_dynamic/2 pool size" do
    test "the default is > 1 connection — reads are not limited to one connection" do
      assert Boot.default_pool_size() > 1

      pid = start_repo!(:default_pool)

      assert {:ok, ready} = await_pool_size(pid, Boot.default_pool_size())
      assert ready == Boot.default_pool_size()
    end

    test "an explicit :pool_size is honored" do
      pid = start_repo!(:explicit_two, pool_size: 2)

      assert {:ok, 2} = await_pool_size(pid, 2)
    end

    test "pool_size: 1 is honored (the single-connection store the disk-full tests need)" do
      pid = start_repo!(:explicit_one, pool_size: 1)

      assert {:ok, 1} = await_pool_size(pid, 1)

      # A one-connection pool really is one connection: a second checkout is
      # not served while the first is held (see the serialization test below).
      holder = hold_connection!(pid)

      try do
        task = Task.async(fn -> RepoScope.with_repo(pid, fn -> Repo.query!("SELECT 1") end) end)
        assert Task.yield(task, 500) == nil
        Task.shutdown(task, :brutal_kill)
      after
        release_connection(holder)
      end
    end

    test "an invalid :pool_size raises a descriptive ArgumentError before the repo starts" do
      for bad <- [0, -1, "3", 2.5, :three] do
        assert_raise ArgumentError, ~r/invalid :pool_size option/, fn ->
          Boot.start_dynamic(db_path(:invalid), pool_size: bad)
        end
      end

      # No database file was created for the rejected starts: the raise happens
      # before the repo process is started.
      refute File.exists?(db_path(:invalid))
    end
  end

  describe "EvoGit.Store.start_link/1 pool plumbing" do
    test "the store's :pool_size opt reaches its own dynamic repo" do
      store = :"evogit_pool_store_#{System.unique_integer([:positive])}"
      path = db_path(:store_one)

      {:ok, store_pid} = Store.start_link(data_dir: path, name: store, pool_size: 1)
      Process.unlink(store_pid)
      on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)

      assert Store.count_tasks(store) == 0

      # The facade's repo instance is the one started with the requested size.
      assert {:ok, 1} = await_pool_size(Store.__repo_pid__(store), 1)
    end
  end

  describe "concurrent reads" do
    test "a second connection serves a read while the first is held (the default pool)" do
      pid = start_repo!(:concurrent)
      holder = hold_connection!(pid)

      try do
        # With a single pooled connection this query would sit in the pool's
        # checkout queue behind the held connection — exactly the head-of-line
        # blocking the default pool size removes.
        task =
          Task.async(fn ->
            RepoScope.with_repo(pid, fn -> Repo.query!("SELECT 1").rows end)
          end)

        assert Task.await(task, 5_000) == [[1]]
      after
        release_connection(holder)
      end
    end

    test "with pool_size: 1 the held connection blocks every other reader" do
      pid = start_repo!(:serial, pool_size: 1)
      holder = hold_connection!(pid)

      try do
        task = Task.async(fn -> RepoScope.with_repo(pid, fn -> Repo.query!("SELECT 1") end) end)

        # Still queued behind the only connection — the contrast that makes the
        # assertion above meaningful.
        assert Task.yield(task, 500) == nil
        Task.shutdown(task, :brutal_kill)
      after
        release_connection(holder)
      end
    end
  end

  # ── Schema consistency across the pool ───────────────────────────────────

  describe "schema consistency across the pool" do
    # SQLite loads a connection's schema LAZILY, and a connection that opened a
    # still-schema-less file keeps that empty schema cached; the
    # schema-introspection pragmas are answered from the cache WITHOUT loading
    # it, so such a connection reports an EMPTY index list until some other
    # statement loads the schema. `Boot.start_dynamic/2` therefore migrates on a
    # single-connection boot instance and REOPENS the pool for any larger size,
    # so that every connection of the returned instance opens an
    # already-migrated file. This asserts exactly that, on EVERY pooled
    # connection (all held at once, so the pool cannot hand the same one out
    # twice), against the ground truth in `sqlite_master`.
    test "EVERY pooled connection reports the migrated index inventory on its first introspection" do
      pid = start_repo!(:schema_consistency)
      size = Boot.default_pool_size()

      assert size > 1
      assert {:ok, ^size} = await_pool_size(pid, size)

      expected = RepoScope.with_repo(pid, fn -> index_names_by_table(pid) end)

      results =
        on_every_connection(pid, size, fn conn ->
          Enum.sort(raw_rows!(conn, "PRAGMA index_list(tasks)") |> Enum.map(&Enum.at(&1, 1)))
        end)

      assert results == List.duplicate(expected["tasks"], size)

      projects =
        on_every_connection(pid, size, fn conn ->
          Enum.sort(raw_rows!(conn, "PRAGMA index_list(projects)") |> Enum.map(&Enum.at(&1, 1)))
        end)

      assert projects == List.duplicate(expected["projects"], size)
      assert expected["tasks"] != [] and expected["projects"] != []
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────
  # Starts an unnamed dynamic repo on a UNIQUE tmp database file (per test
  # process, per call) and stops it on test exit. The repo is UNLINKED:
  # `Boot.start_dynamic/2` links it to this test process and the `on_exit/1`
  # callback runs after that process is gone.
  defp start_repo!(tag, opts \\ []) do
    {:ok, pid} = Boot.start_dynamic(db_path(tag), opts)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)
    pid
  end

  defp db_path(tag) do
    unique = System.unique_integer([:positive, :monotonic])

    Path.join(
      System.tmp_dir!(),
      "evogit_pool_#{tag}_#{:os.getpid()}_#{System.system_time(:millisecond)}_" <>
        "#{unique}_#{inspect(self())}.sqlite"
    )
  end

  # The pool's idle-connection count, polled because connections connect
  # asynchronously: the pool starts in its `:busy` state and reports every
  # connection only once it has connected AND checked in.
  defp await_pool_size(repo_pid, expected, attempts \\ 200) do
    ready = ready_connections(repo_pid)

    cond do
      ready == expected ->
        {:ok, ready}

      attempts > 1 ->
        Process.sleep(10)
        await_pool_size(repo_pid, expected, attempts - 1)

      true ->
        {:error, ready}
    end
  end

  defp ready_connections(repo_pid) do
    %{pid: pool} = Ecto.Adapter.lookup_meta(repo_pid)
    [%{ready_conn_count: ready} | _] = DBConnection.get_connection_metrics(pool)
    ready
  end

  # Holds ONE pooled connection open in a separate process until released.
  # `XqliteEcto3.with_xqlite/2` takes a repo PID directly (no dynamic-repo
  # binding needed), which is also the seam the disk-full tests use.
  defp hold_connection!(repo_pid) do
    parent = self()

    holder =
      spawn_link(fn ->
        XqliteEcto3.with_xqlite(repo_pid, fn _conn ->
          send(parent, {:held, self()})

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive {:held, ^holder}, 2_000
    holder
  end

  defp release_connection(holder) do
    ref = Process.monitor(holder)
    send(holder, :release)
    assert_receive {:DOWN, ^ref, :process, ^holder, _reason}, 5_000
  end

  # Runs `fun.(conn)` on EVERY pooled connection at once: the holders all
  # acquire before any of them queries, and a held connection cannot be handed
  # to a second caller, so `count` simultaneous holders are necessarily
  # `count` DISTINCT connections. Returns the fun's results in completion
  # order (callers sort when order matters).
  defp on_every_connection(repo_pid, count, fun) do
    parent = self()

    holders =
      for _ <- 1..count do
        spawn_link(fn ->
          XqliteEcto3.with_xqlite(repo_pid, fn conn ->
            send(parent, {:held, self()})

            receive do
              :go -> :ok
            end

            send(parent, {:result, fun.(conn)})

            receive do
              :release -> :ok
            end
          end)
        end)
      end

    for holder <- holders, do: assert_receive({:held, ^holder}, 5_000)
    for holder <- holders, do: send(holder, :go)

    results =
      for _ <- 1..count do
        assert_receive {:result, result}, 5_000
        result
      end

    for holder <- holders, do: send(holder, :release)
    results
  end

  defp raw_rows!(conn, sql) do
    {:ok, %{rows: rows}} = Xqlite.query(conn, sql, [], [])
    rows
  end

  # Ground truth (the FILE, not a pragma): index names per table, from
  # `sqlite_master`.
  defp index_names_by_table(repo_pid) do
    rows =
      RepoScope.with_repo(repo_pid, fn ->
        Repo.query!("SELECT name, tbl_name FROM sqlite_master WHERE type = 'index'").rows
      end)

    Enum.group_by(rows, &Enum.at(&1, 1), &Enum.at(&1, 0))
    |> Map.new(fn {t, names} -> {t, Enum.sort(names)} end)
  end
end
