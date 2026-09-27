defmodule EvoGit.Store.StoreWriteOffloadTest do
  @moduledoc """
  The store's WRITE OFFLOAD: `EvoGit.Store` no longer executes writes in its own
  GenServer — it forwards each one to its own dedicated `EvoGit.Store.Writer`
  process and returns `{:noreply, state}` immediately.

  This file pins the invariants the offload must NOT relax (the design itself is
  documented in `EvoGit.Store.Writer` and in `EvoGit.Store`'s moduledoc):

    * the store owns exactly ONE writer, LINKED to it, and the writer follows
      the store down on any exit reason (`:normal` stop included);
    * **reply-after-commit** — once `put_task/2` has returned, the row is
      committed and visible to a DIFFERENT process reading the database
      directly through the store's dynamic repo;
    * **strict serialization in ARRIVAL order** — a write issued while another
      write is genuinely in flight (the writer holds the pooled connection)
      lands AFTER it, so an overwrite/delete queued behind an update wins;
    * the facade GenServer keeps answering INLINE handlers while a
      multi-megabyte write is in flight — with the write executed inline (the
      shape this replaced) those handlers could not be answered until the write
      had finished;
    * the contracts the offload leaves untouched: disk-full-class failures still
      return `{:error, :disk_full}` (logged, store survives, write retryable),
      and any OTHER failing statement still crashes the store with the
      operation's own reason.

  ## Why `async: false`

  A deliberate deviation from the default in this suite's other store tests.
  The in-flight assertions read the store's own pool metrics and assert bounded
  latencies, so they must not compete for CPU with sibling tests; and the
  crash-semantics test deliberately takes the store (and its writer) down, which
  is only sane in isolation.

  ## Why the in-flight probe is `__writer__/1` and not a DB-backed read

  `wait_for_inflight_write/2` waits on the store's pool metrics
  (`ready_conn_count == 0` ⟺ the writer holds the pooled connection), and the
  availability probe is the facade's inline `:__writer__` handler, which answers
  straight from state without touching SQLite. A DB-backed read cannot serve as
  a PROMPTNESS probe on a `pool_size: 1` store (today's shape, see
  `EvoGit.Store.Boot.start_dynamic/1`): it must WAIT for the single pooled
  connection the write holds — measured ~190 ms behind the 12 MB write below —
  which is a property of the single-connection POOL, not of the facade, so it
  cannot discriminate the facade's inbox behaviour. DB-backed reads are asserted
  right after the write completes instead.
  """
  use EvoGit.TaskRegistryCase, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Store
  alias EvoGit.Store.Operations
  alias EvoGit.TaskInfo

  # A payload big enough that ONE `put_task/2` is genuinely slow (≈100 ms+ on a
  # developer machine: the row is JSON-encoded, inserted and WAL-committed), so
  # the in-flight assertions never race a sub-millisecond write.
  @slow_result_bytes 12_000_000

  # ── writer lifecycle ─────────────────────────────────────────────────

  describe "the dedicated writer process" do
    test "is one live process, linked to its store", %{store: store} do
      writer = Store.__writer__(store)
      store_pid = Process.whereis(store)

      assert is_pid(writer)
      assert Process.alive?(writer)
      refute writer == store_pid

      # LINKED: a write that raises kills the writer, and the link kills the
      # store with the very same reason (the crash semantics pinned below).
      assert {:links, links} = Process.info(writer, :links)
      assert store_pid in links
    end

    test "follows the store down when the store stops normally", %{store: store} do
      writer = Store.__writer__(store)
      assert Process.alive?(writer)

      writer_ref = Process.monitor(writer)

      # A `:normal` stop is the path a linked, non-trapping process would
      # otherwise IGNORE — the writer's monitor on the store is what makes it
      # exit instead of leaking.
      :ok = GenServer.stop(store, :normal)

      assert_receive {:DOWN, ^writer_ref, :process, ^writer, :normal}, 5_000
      refute Process.alive?(writer)
    end
  end

  # ── read-after-reply ─────────────────────────────────────────────────

  describe "read-after-commit (the caller's reply implies the write committed)" do
    test "the committed row is visible to another process and to a later read",
         %{store: store} do
      repo = Store.__repo_pid__(store)
      id = "war_visible"

      assert :ok = Store.put_task(store, task(id, {:ok, %{result: "committed"}}))

      # The reply has been received, so the transaction has committed. Prove it
      # from a DIFFERENT process that binds the store's dynamic repo itself
      # (`Operations` does that through `RepoScope.with_repo/2`) and reads the
      # row straight from SQLite — no facade, no cache.
      assert_connection_ready!(repo)

      reader = Task.async(fn -> Operations.Tasks.get_task(repo, id) end)

      assert %TaskInfo{result: {:ok, %{result: "committed"}}} = Task.await(reader)

      # ...and a subsequent facade read sees the same value.
      assert %TaskInfo{result: {:ok, %{result: "committed"}}} = Store.get_task(store, id)
    end
  end

  # ── arrival-order serialization ──────────────────────────────────────

  describe "writes are serialized in arrival order" do
    test "a write issued while another is in flight lands after it", %{store: store} do
      repo = Store.__repo_pid__(store)
      id = "war_order_inflight"

      assert :ok = Store.put_task(store, task(id, {:ok, %{result: "seed"}}))
      assert_connection_ready!(repo)

      # 1. A genuinely slow write (multi-megabyte row) is handed over...
      slow =
        Task.async(fn -> Store.put_task(store, task(id, {:ok, %{result: slow_payload()}})) end)

      # 2. ...and confirmed IN FLIGHT inside the writer (it holds the pooled
      #    connection), so the write below is unambiguously issued WHILE it is
      #    still executing.
      assert :ok = wait_for_inflight_write(repo)

      # 3. Queued behind it. A concurrent/interleaved writer could apply the
      #    slow write LAST (it finishes last) and the marker would lose.
      assert :ok = Store.put_task(store, task(id, {:ok, %{result: "SECOND"}}))

      assert :ok = Task.await(slow)

      # Serialized ⇒ arrival order wins: the marker's row is the final state.
      assert %TaskInfo{result: {:ok, %{result: "SECOND"}}} = Store.get_task(store, id)

      # ...and the pool metric used above tracks reality (the connection is
      # back to idle now), so the earlier `0` really meant "write in flight".
      assert_connection_ready!(repo)
    end

    test "a delete queued behind an update wins", %{store: store} do
      id = "war_order_delete"

      # An update carrying a big payload, then the delete: same arrival order,
      # strictly serialized execution.
      assert :ok = Store.put_task(store, task(id, {:ok, %{result: slow_payload()}}))
      assert :ok = Store.delete_task(store, id)

      assert Store.get_task(store, id) == nil
      assert Store.count_tasks(store) == 0
    end
  end

  # ── facade availability ──────────────────────────────────────────────

  describe "the facade is not blocked by a long-running write" do
    test "inline handlers keep being served while a multi-megabyte write is in flight",
         %{store: store} do
      repo = Store.__repo_pid__(store)

      assert :ok = Store.put_task(store, task("war_seed", {:ok, %{result: "seed"}}))
      assert_connection_ready!(repo)

      slow =
        Task.async(fn ->
          Store.put_task(store, task("war_slow", {:ok, %{result: slow_payload()}}))
        end)

      assert :ok = wait_for_inflight_write(repo)

      writer = Store.__writer__(store)
      probes = 25

      # Inline facade handlers — `:__writer__` answers from state, so its
      # latency measures ONLY this GenServer's availability (no SQL, no pool).
      # With the write running INLINE in the facade (the pre-offload shape)
      # every one of these calls would have waited for the whole write.
      {elapsed_us, last} =
        :timer.tc(fn ->
          Enum.reduce(1..probes, nil, fn _, _ -> Store.__writer__(store) end)
        end)

      assert last == writer

      # The write is STILL in flight after the whole probe loop: every probe
      # was therefore answered by the facade WHILE the writer was busy. (The
      # slow write is ~100 ms+; the loop is a few dozen in-process calls.)
      assert ready_conn_count(repo) == 0,
             "expected the slow write to still be in flight after #{probes} probes"

      # Bounded-time assertion, deliberately generous for slow CI.
      assert elapsed_us < 2_000_000

      assert :ok = Task.await(slow)

      # The pool metric tracks reality in BOTH directions: the connection is
      # idle again now, so the earlier `0` really meant "write in flight".
      assert_connection_ready!(repo)

      # DB-backed reads are served as well, right after the multi-megabyte
      # write landed (they are NOT probed WHILE it is in flight: on a
      # `pool_size: 1` store a read queued behind the write for longer than the
      # pool's CoDel target is DROPPED rather than served — a property of the
      # pool, and the reason a store serving concurrent readers wants more than
      # one connection).
      assert Store.count_tasks(store) == 2
      assert %TaskInfo{result: {:ok, %{result: _}}} = Store.get_task(store, "war_slow")

      # The store AND its writer survived the multi-megabyte write.
      assert Process.alive?(Process.whereis(store))
      assert Process.alive?(writer)
    end
  end

  # ── unchanged contracts ──────────────────────────────────────────────

  describe "disk-full contract, offloaded through the writer" do
    test "still converts to {:error, :disk_full}, logs, and leaves the store serving",
         %{store: store, sqlite_path: sqlite_path} do
      log =
        capture_log(fn ->
          set_query_only(store, "ON")
          assert {:error, :disk_full} = Store.put_task(store, task("war_disk_full", nil))
        end)

      assert log =~ "Store: DISK FULL"
      assert log =~ sqlite_path

      # The store AND the writer survived the failed write...
      assert Process.alive?(Process.whereis(store))
      assert Process.alive?(Store.__writer__(store))

      # ...and a full disk is transient: the same write succeeds once cleared.
      set_query_only(store, "OFF")

      assert :ok = Store.put_task(store, task("war_disk_full", nil))
      assert %TaskInfo{id: "war_disk_full"} = Store.get_task(store, "war_disk_full")
    end
  end

  describe "crash semantics, unchanged by the offload" do
    test "a failing statement still crashes the store with the operation's own reason",
         %{store: store} do
      store_pid = Process.whereis(store)
      writer = Store.__writer__(store)
      ref = Process.monitor(store_pid)
      writer_ref = Process.monitor(writer)

      # An unknown column raises INSIDE the operation (`Operations.Tasks`'
      # SET builder) — not a disk-full-class failure, so `write_call/2`
      # re-raises it, exactly as the old inline handler did.
      log =
        capture_log(fn ->
          catch_exit(Store.update_task_columns(store, "war_crash", bogus_column: 1))
        end)

      # The STORE dies with the operation's own `{exception, stacktrace}` — the
      # same reason a linked writer died with, propagating over the link.
      assert_receive {:DOWN, ^ref, :process, ^store_pid, reason}, 5_000

      assert {%ArgumentError{message: message}, stacktrace} = reason
      assert message =~ "unknown task column"
      assert is_list(stacktrace)
      assert log =~ "unknown task column"

      # The writer died FIRST, with the very same reason, and the link carried
      # it to the store — the old inline raise, reproduced.
      assert_receive {:DOWN, ^writer_ref, :process, ^writer, ^reason}, 5_000
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp task(id, result) do
    %TaskInfo{
      id: id,
      type: :genesis,
      status: :running,
      opts: [path: "/tmp/test"],
      started_at: DateTime.utc_now(),
      logs: [],
      result: result
    }
  end

  defp slow_payload, do: String.duplicate("x", @slow_result_bytes)

  # ── pool metrics ─────────────────────────────────────────────────────

  # Ready (idle, checked-in) connections of the store's pool. `0` means the
  # writer holds the (single) connection mid-write.
  defp ready_conn_count(repo_pid) do
    %{pid: pool} = Ecto.Adapter.lookup_meta(repo_pid)

    pool
    |> DBConnection.get_connection_metrics()
    |> Enum.map(& &1.ready_conn_count)
    |> Enum.sum()
  end

  # The pool starts its connections eagerly but the metric is only meaningful
  # once at least one exists — every test that relies on it seeds a write and
  # waits here first, so a `0` observed later really means "write in flight".
  defp assert_connection_ready!(repo_pid, budget_ms \\ 5_000) do
    assert wait_until(fn -> ready_conn_count(repo_pid) >= 1 end, budget_ms),
           "expected the store's pool to have a ready connection"

    :ok
  end

  defp wait_for_inflight_write(repo_pid, budget_ms \\ 5_000) do
    assert wait_until(fn -> ready_conn_count(repo_pid) == 0 end, budget_ms),
           "expected a write to be in flight (the writer holding the pooled connection)"

    :ok
  end

  defp wait_until(fun, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(1)
        do_wait_until(fun, deadline)
    end
  end

  # ── disk-full arm ────────────────────────────────────────────────────

  # Mirrors the technique documented in `test/evo_git/store_disk_full_test.exs`:
  # `PRAGMA query_only = ON` on the store's OWN connection makes every write
  # fail with SQLITE_READONLY (8), which `EvoGit.Store.Errors` classifies as
  # disk-full. Re-armed before each write there because the transactional writes
  # tear the armed connection down; this test arms exactly once.
  defp set_query_only(store, value) do
    repo_pid = Store.__repo_pid__(store)

    :ok =
      XqliteEcto3.with_xqlite(repo_pid, fn conn ->
        {:ok, _} = XqliteNIF.query(conn, "PRAGMA query_only = #{value}", [])
        :ok
      end)
  end
end
