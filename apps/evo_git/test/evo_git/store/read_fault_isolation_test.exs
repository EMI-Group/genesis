defmodule EvoGit.Store.ReadFaultIsolationTest.CrashCounter do
  @moduledoc false
  # `:logger` handler installed for the duration of ONE read-fault test, so the
  # test process can OBSERVE the runtime's asynchronous crash reports.
  #
  # Two counters live in a shared `:counters` array (`%{counters: ref}` in the
  # handler config):
  #
  #   1. the facade's own `Store: read <op> failed` error line — logged
  #      SYNCHRONOUSLY by `EvoGit.Store` (one per degraded read), and
  #   2. the crash report of the offload worker that died behind that read —
  #      emitted by the runtime, asynchronously, one per degraded read.
  #
  # A plain process's crash report is NOT written inline by that process (unlike
  # an explicit `Logger.error/1`, whose handler call runs in the caller's own
  # process): the emulator hands it to OTP's `:logger_proxy`, which calls the
  # handlers in ITS process. Counting the delivered reports is therefore the
  # only reliable "they are all captured now" signal — no mailbox barrier and no
  # `Logger.flush/0` can wait for a report the runtime has not delivered yet.
  #
  # The handler never raises and never writes (a crashing handler is dropped by
  # `:logger`), and it only matches the two shapes above; every other event is
  # ignored.

  # A crash report carries the documented `crash_reason` metadata; the stack
  # trace identifies OUR workers (an `EvoGit.Store` frame is the worker body).
  def log(%{meta: %{crash_reason: {_reason, stacktrace}}}, %{counters: counters})
      when is_list(stacktrace) do
    if Enum.any?(stacktrace, &match?({EvoGit.Store, _fun, _arity, _location}, &1)) do
      :counters.add(counters, 2, 1)
    end

    :ok
  end

  def log(%{msg: {:string, chardata}}, %{counters: counters}) do
    if String.contains?(text(chardata), "Store: read ") do
      :counters.add(counters, 1, 1)
    end

    :ok
  end

  def log(_event, _config), do: :ok

  # Chardata → binary; an unmappable payload is simply not one of our lines.
  defp text(chardata) do
    case :unicode.characters_to_binary(chardata) do
      binary when is_binary(binary) -> binary
      _ -> ""
    end
  end
end

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

  ## Console hygiene — the crash REPORTS must be AWAITED, not just captured

  Every forced fault above kills an offload worker, and a killed process's crash
  REPORT does not reach the Logger handlers inline: the emulator hands it to
  OTP's `:logger_proxy` process, which calls the handlers from ITS OWN process,
  tens of milliseconds later (measured: a report typically lands 10-200 ms after
  the death, and `Logger.flush/0` / a `:sys` barrier on the proxy only order
  what was ALREADY delivered — verified: 12 of 20 reports had arrived at a
  barrier placed right after the reads). A `capture_log/2` window therefore
  closes while reports are still in flight, and `:default` prints them between
  tests as a stray `[error] Process #PID<...> raised an exception`.

  `with_crash_report_counter/1` + `await_crash_reports!/1` close that hole: the
  counters (`EvoGit.Store.ReadFaultIsolationTest.CrashCounter`) count the
  facade's synchronous `Store: read <op> failed` lines and the workers' crash
  reports, which are 1:1 by construction, so waiting until they are EQUAL (and
  non-zero) inside the capture window guarantees the last report reached the
  capture handler before the window closed. `assert log =~ "raised an
  exception"` then pins that the reports really were captured here — the exact
  text that used to leak between tests.
  """

  # `async: false`: the fault arm stops the store's own repo instance, the raise
  # arm asserts exact log lines, and the counter handler below is installed on
  # the VM-global `:logger` — none of that should race a sibling test.
  use EvoGit.TaskRegistryCase, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Store

  @counter_handler_id :read_fault_crash_counter

  # Generous: the awaited events are guaranteed to arrive (the runtime always
  # emits one report per dead worker); the budget only absorbs host load.
  @await_deadline_ms 15_000

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
        with_crash_report_counter(fn counters ->
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

            # Await the crash reports INSIDE the window (see the moduledoc's
            # "Console hygiene"): every worker above died, and its report is
            # delivered through `:logger_proxy` asynchronously.
            await_crash_reports!(counters)
          end)
        end)

      # The store process itself survived every one of those reads …
      assert Process.alive?(store_pid)

      # … and every failure was logged with the operation name (never silent).
      for op <- [
            "get_task",
            "get_task_lite",
            "get_task_status",
            "select_task_ids",
            "safe_select_paginated_tasks"
          ] do
        assert log =~ "Store: read #{op} failed"
      end

      # The workers' crash REPORTS were delivered to THIS window — the pin that
      # `await_crash_reports!/1` keeps doing its job (this is the text that used
      # to leak between tests).
      assert log =~ "raised an exception"
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
        with_crash_report_counter(fn counters ->
          capture_log(fn ->
            assert Store.get_task(store, %{}) == nil
            await_crash_reports!(counters)
          end)
        end)

      assert log =~ "Store: read get_task failed"
      assert log =~ "raised an exception"
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
      with_crash_report_counter(fn counters ->
        capture_log(fn ->
          assert Store.get_task(store, %{}) == nil
          await_crash_reports!(counters)
        end)
      end)

      # … leaves the very next read of the SAME function intact.
      assert %TaskInfo{id: ^id} = Store.get_task(store, id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

  # Installs the counting handler (see `CrashCounter`) around `fun`, so the test
  # can await the runtime's asynchronous crash reports inside its own capture
  # window. The handler is removed afterwards even when the test fails; all log
  # lines printed in the meantime are still handled by `:default` / the capture
  # handler as usual — this one only COUNTS.
  defp with_crash_report_counter(fun) do
    counters = :counters.new(2, [:atomics])

    Code.ensure_loaded?(__MODULE__.CrashCounter)
    :ok = :logger.add_handler(@counter_handler_id, __MODULE__.CrashCounter, %{counters: counters})

    try do
      fun.(counters)
    after
      :logger.remove_handler(@counter_handler_id)
    end
  end

  # Blocks until every degraded read in the window has produced BOTH of its
  # traces: the facade's `Store: read <op> failed` line (synchronous, one per
  # read) and the worker's crash report (asynchronous, one per read). The two
  # counts are 1:1 by construction, so equality means nothing about this test is
  # still in flight — the capture window then closes without leaking a stray
  # `[error] Process #PID<...> raised an exception` between tests.
  defp await_crash_reports!(counters, deadline_ms \\ @await_deadline_ms) do
    deadline_at = System.monotonic_time(:millisecond) + deadline_ms
    await(counters, deadline_at)
  end

  defp await(counters, deadline_at) do
    failed_reads = :counters.get(counters, 1)
    crash_reports = :counters.get(counters, 2)

    cond do
      failed_reads > 0 and crash_reports >= failed_reads ->
        # The LAST report's dispatch may still be running the capture handler in
        # that same proxy process; a synchronous call is handled after the
        # current dispatch completes, so the capture buffer is complete here.
        flush_logger_proxy()
        :ok

      System.monotonic_time(:millisecond) >= deadline_at ->
        flunk("""
        timed out waiting for the offload workers' crash reports:
        #{crash_reports} report(s) for #{failed_reads} failed read(s)
        """)

      true ->
        Process.sleep(5)
        await(counters, deadline_at)
    end
  end

  # Barrier on OTP's crash-report dispatch path (see the moduledoc). Reports are
  # delivered by `:logger_proxy` (`logger_olp`), so a synchronous `:sys` call is
  # handled only after every event queued before it was fully dispatched to all
  # handlers. `Process.whereis/1` keeps it total on a release without the proxy
  # (where the leak cannot exist).
  defp flush_logger_proxy do
    case Process.whereis(:logger_proxy) do
      nil -> :ok
      pid -> :sys.get_state(pid, 30_000)
    end

    :ok
  end
end
