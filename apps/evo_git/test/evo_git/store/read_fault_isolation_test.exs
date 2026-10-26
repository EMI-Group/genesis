defmodule EvoGit.Store.ReadFaultIsolationTest do
  @moduledoc """
  READ FAULT ISOLATION for `EvoGit.Store`: no read failure may kill the store.

  The production crash chain this file pins started with a READ: a 26.5 s
  `select_task_ids/2` scan raised `DBConnection.ConnectionError` inside the
  `EvoGit.Store` GenServer (the offloaded work was a LINKED `Task.start/1`), so
  the store died, then `EvoGit.Store.Writer` (linked), then the in-flight
  `GenServer.call` from `EvoGit.TaskRegistry` exited with the dead-server
  reason, so `TaskRegistry` died and every LiveView blocked on it exited too.

  The contract tested here (documented in `EvoGit.Store`'s `@moduledoc`,
  "Read degradation policy"):

    * every read runs its query + decode in an UNLINKED, monitored worker
      (`offload/5`);
    * a raise, an exit, a kill, a worker-start failure or an internal-deadline
      overrun is LOGGED and answered with that read's own EMPTY value (`nil`,
      `[]`, `0`, `{[], 0}`) — never `{:error, _}`, never a raise, never an exit;
    * the `EvoGit.Store` process stays alive and keeps serving every other
      caller afterwards.

  ## How a fault is forced deterministically

  `EvoGit.Store.__repo_pid__/1` exposes the store's OWN dynamic repo instance
  (a test seam used by the disk-full tests too). `Supervisor.stop/1` on it stops
  the instance with `:normal` — which the linked store IGNORES, so the store
  itself stays up — while every subsequent query through
  `EvoGit.Store.RepoScope.with_repo/2` can no longer find the repo's Ecto meta
  and fails inside the READ WORKER.

  A RAISE inside a healthy store is forced with an input the query builder
  cannot encode (`get_task/2` with a map instead of an id string), which proves
  the worker's exception is caught and degraded too — the store never sees it.

  ## Console hygiene — ONE log line per degraded read

  The read worker's body (`EvoGit.Store.run_offload/2`) re-raises any
  query/decode failure as a `:shutdown`-class exit, and `:shutdown` /
  `{:shutdown, _}` are NORMAL exit classes for the runtime's error logger, so
  NO OTP crash report is emitted for a degraded read. The facade's own
  `Store: read <op> failed — <exception + stacktrace>` line is therefore the
  ONLY trace: it is logged synchronously from the store process while it
  handles the worker's `:DOWN`, so `capture_log/2` alone captures everything —
  no counter handler, no awaiting, and nothing leaking between tests. The
  `refute log =~ "raised an exception"` pins that contract.

  ## Waiting for the async crash-report path (no fixed sleep)

  A crash report — which a `:shutdown`-class exit must NOT produce — travels an
  ASYNCHRONOUS path after the death: exit → `:logger_proxy` (async) → `Logger`
  → the `ExUnit.CaptureServer` handler → the capture device (async `send`).
  `drain_pending_crash_reports!/0` walks every hop that HAS a synchronous hook
  (`:sys.get_state/1` on `:logger_proxy`, `Logger.flush/0`; the capture's own
  teardown drains the handler → device hops) and puts a 25 ms tail on the ONE
  hop that has none (the emulator's own delivery), which is a ~7× margin over
  the worst of 40 measured samples (16 µs – 3.5 ms). That replaces the old
  fixed 250 ms sleep per test.
  """

  # `async: false`: the fault arm stops the store's own repo instance and the
  # raise arm asserts exact log lines — neither should race a sibling test.
  use EvoGit.TaskRegistryCase, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Store

  # The report path's ONE hop without a synchronous hook is the emulator's own
  # delivery to `:logger_proxy`; measured here at 16 µs – 3.5 ms after the death
  # (40 samples of a raising worker), so this tail is a ~7× margin.
  @report_tail_ms 25

  describe "a failing read never kills the store" do
    test "every read degrades to its own empty shape and the store stays alive",
         %{store: store} do
      id = "read_fault_#{System.unique_integer([:positive])}"

      # Seed real data FIRST, so the degraded values below cannot be confused
      # with "the database is simply empty".
      assert :ok = Store.put_task(store, task(id))
      assert length(Store.select_task_ids(store)) == 1
      assert [_] = Store.select_task_ids(store, [:running])

      # Kill the store's dynamic repo instance (`:normal`, so the linked store
      # survives) — from here on every query fails INSIDE the read worker.
      stop_repo!(store)

      store_pid = Process.whereis(store)
      assert is_pid(store_pid)

      log =
        capture_log(fn ->
          # Single-item reads degrade to nil …
          assert Store.get_task(store, id) == nil
          assert Store.get_task_lite(store, id) == nil
          assert Store.get_task_status(store, id) == nil
          assert Store.select_task_update_info(store, id) == nil
          assert Store.get_project(store, "/no/such/project") == nil

          # … list reads to [] …
          assert Store.select_task_ids(store, [:running]) == []
          assert Store.select_finished_task_ids(store) == []
          assert Store.select_running_lease_info(store) == []
          assert Store.select_task_paths(store) == []
          assert Store.select_cleanup_info(store) == []
          assert Store.select_cleanup_info(store, "1970-01-01T00:00:00.000000Z", 10) == []
          assert Store.select_tasks_summary(store) == []
          assert Store.select_tasks_summary_by_path(store, "/no/such/project") == []
          assert Store.select_tasks_changed_since(store, "1970-01-01T00:00:00.000000Z") == []
          assert Store.select_all_projects(store) == []
          assert Store.safe_select_all_tasks(store) == []
          assert Store.safe_select_all_projects(store) == []

          # … a paginated read keeps its {list, count} shape …
          assert Store.safe_select_paginated_tasks(store, limit: 10) == {[], 0}

          # … and counts degrade to 0.
          assert Store.count_projects(store) == 0
          assert Store.size(store) == 0

          # See the moduledoc's "Waiting for the async crash-report path": drain
          # it, so a would-be report for ANY worker above would already be in
          # this capture.
          drain_pending_crash_reports!()
        end)

      # The store process itself survived every one of those reads …
      assert Process.alive?(store_pid)

      # … and every failure was logged with the operation name (never silent),
      # carrying the full exception + stacktrace.
      for op <- [
            "get_task",
            "get_task_lite",
            "get_task_status",
            "select_task_ids",
            "safe_select_paginated_tasks"
          ] do
        assert log =~ "Store: read #{op} failed"
      end

      assert log =~ "** (ArgumentError)"

      # ONE log line per degraded read: the worker's `:shutdown`-class exit
      # produces no second, asynchronous OTP crash report.
      refute log =~ "raised an exception"
    end

    test "a raise inside the read worker is caught — the store survives and keeps reading",
         %{store: store} do
      id = "read_raise_#{System.unique_integer([:positive])}"
      assert :ok = Store.put_task(store, task(id))

      store_pid = Process.whereis(store)

      # `%{}` is not a task id: the Ecto query builder raises inside the worker
      # (the store itself is HEALTHY here — this isolates the raise path, not the
      # dead-repo path).
      log =
        capture_log(fn ->
          assert Store.get_task(store, %{}) == nil
          drain_pending_crash_reports!()
        end)

      # The facade still logs the exception AND its stacktrace in full.
      assert log =~ "Store: read get_task failed"
      assert log =~ "** (Ecto.Query.CastError)"
      assert log =~ "store/operations/tasks.ex"

      # … and the worker's death did NOT also become an OTP crash report.
      refute log =~ "raised an exception"

      assert Process.alive?(store_pid)

      # The healthy store keeps working normally afterwards: the fault was
      # contained in the worker, not in the store's state.
      assert %TaskInfo{id: ^id} = Store.get_task(store, id)
      assert length(Store.select_task_ids(store)) == 1
    end

    test "reads are isolated per call: one failing read does not degrade the next",
         %{store: store} do
      id = "read_isolation_#{System.unique_integer([:positive])}"
      assert :ok = Store.put_task(store, task(id))
      assert Store.get_task(store, id) != nil

      # A raising read …
      capture_log(fn ->
        assert Store.get_task(store, %{}) == nil
        drain_pending_crash_reports!()
      end)

      # … leaves the very next read of the SAME function intact.
      assert %TaskInfo{id: ^id} = Store.get_task(store, id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Walks the async crash-report path up to the capture (see the moduledoc):
  # `:sys.get_state/1` on `:logger_proxy` makes it forward everything already in
  # its mailbox to `Logger`, `Logger.flush/0` makes `Logger` hand it to the
  # capture handler, and the capture's own teardown (`Logger.flush/0` +
  # `ExUnit.CaptureServer.log_capture_off/1` + `StringIO.close/1`, see
  # `ExUnit.CaptureLog.with_log/2`) drains the handler → device hop. The 25 ms
  # tail covers the one hop with no synchronous hook (emulator → proxy).
  # MUST be called INSIDE the `capture_log/2` fun.
  defp drain_pending_crash_reports! do
    case Process.whereis(:logger_proxy) do
      nil -> :ok
      proxy -> _state = :sys.get_state(proxy)
    end

    :ok = Logger.flush()
    Process.sleep(@report_tail_ms)
  end

  defp task(id) do
    %TaskInfo{
      id: id,
      type: :genesis,
      status: :running,
      opts: [path: "/tmp/test"],
      started_at: DateTime.utc_now(),
      logs: []
    }
  end

  # Stops the store's own dynamic repo instance with `:normal`. The store is
  # LINKED to it, but a `:normal` exit signal is ignored by a non-trapping
  # process — exactly the shape needed: the store stays up, its queries fail.
  defp stop_repo!(store) do
    repo = Store.__repo_pid__(store)

    assert is_pid(repo)
    assert :ok = Supervisor.stop(repo)
    refute Process.alive?(repo)
  end
end
