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
  """

  # `async: false`: the fault arm stops the store's own repo instance and the
  # raise arm asserts exact log lines; neither should compete with sibling tests.
  use EvoGit.TaskRegistryCase, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Store

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
        end)

      assert log =~ "Store: read get_task failed"
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
      capture_log(fn -> assert Store.get_task(store, %{}) == nil end)

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
end
