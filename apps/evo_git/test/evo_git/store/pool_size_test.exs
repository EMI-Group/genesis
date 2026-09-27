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
end
