defmodule EvoGit.TaskRegistry.LightweightReadMirrorTest do
  @moduledoc """
  Mirror coverage for the LIGHTWEIGHT task read API
  (`EvoGit.Store.select_tasks_page/2`, `get_task_lite/2`,
  `list_task_archives/3`, `get_agent_archive/3`) through its reporting layers:

    * `EvoGit.TaskRegistry` — `list_tasks_page/1`, `get_task_lite/1`,
      `list_task_archives/2`, `get_agent_archive/2` (offloaded through
      `Task.start` + `StoreGuard.read/3`);
    * `EvoGit.AgentScheduler.RemoteAPI` — `select_tasks_page/1`,
      `get_task_lite/1`, `list_task_archives/2`, `get_agent_archive/2` (pure
      delegates);
    * `EvoGit.RemoteNode` — `list_tasks_page/2`, `get_task_lite/2`,
      `list_task_archives/3`, `get_agent_archive/3` (local-direct /
      remote-`:erpc`, degraded on failure).

  Each test runs against its OWN isolated store + registry
  (`EvoGit.TaskRegistryCase`), so nothing global is touched.
  """

  use EvoGit.TaskRegistryCase, async: true

  import ExUnit.CaptureLog

  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.RemoteNode
  alias EvoGit.TaskInfo

  @empty_page %{entries: [], total: 0}

  describe "EvoGit.TaskRegistry mirrors" do
    setup %{store: store} do
      seed!(store)
      :ok
    end

    test "list_tasks_page/1 returns summary-only rows + the filtered total" do
      assert %{rows: rows, total: 3} = TaskRegistry.list_tasks_page(limit: 10)

      # ORDER BY started_at DESC.
      assert Enum.map(rows, & &1.id) == ["mirror-c-run", "mirror-b-new", "mirror-a-old"]

      # The heavy blobs are never part of a page row.
      for row <- rows, absent <- [:result, :logs, :usage] do
        refute Map.has_key?(row, absent)
      end

      assert hd(rows).status == :running
    end

    test "get_task_lite/1 decodes the task without touching the archive table" do
      assert %TaskInfo{id: "mirror-a-old"} = lite = TaskRegistry.get_task_lite("mirror-a-old")
      assert lite.branch_name == "genesis/agent_alpha"

      assert {:ok, data} = lite.result
      assert data.commit_sha == "sha-a"

      # Missing rows keep the read's documented empty shape.
      assert TaskRegistry.get_task_lite("no-such-task") == nil
    end

    test "list_task_archives/2 pages the roster and counts the task's whole archive" do
      # Roster order is depth ASC, agent_id ASC — root first.
      assert %{entries: [root, child], total: 2} =
               TaskRegistry.list_task_archives("mirror-a-old")

      assert root["agent_id"] == 1
      assert root["depth"] == 0
      assert child["agent_id"] == 2
      assert child["depth"] == 1

      # `include_results: false` (default) never selects the heavy column: the
      # `"result"` key is ABSENT, not nil.
      refute Map.has_key?(root, "result")
      refute Map.has_key?(child, "result")

      # Opting in carries each agent's own result text.
      assert %{entries: [with_result], total: 2} =
               TaskRegistry.list_task_archives("mirror-a-old",
                 limit: 1,
                 include_results: true
               )

      assert with_result["result"] == "archived a root"

      # `total` is the task's whole archive count, independent of the page.
      assert %{entries: [only], total: 1} =
               TaskRegistry.list_task_archives("mirror-b-new", limit: 1)

      assert only["agent_id"] == 1

      # A task with no archive rows (and an unknown task) keep the empty page.
      assert TaskRegistry.list_task_archives("mirror-c-run") == @empty_page
      assert TaskRegistry.list_task_archives("no-such-task") == @empty_page
    end

    test "get_agent_archive/2 returns ONE agent's full entry (with its result)" do
      assert %{"agent_id" => 2, "depth" => 1} =
               child =
               TaskRegistry.get_agent_archive("mirror-a-old", 2)

      assert child["result"] == "archived a child"
      assert child["objective"] == "beta objective"

      # Absent agent / absent task keep the "no such row" shape.
      assert TaskRegistry.get_agent_archive("mirror-a-old", 99) == nil
      assert TaskRegistry.get_agent_archive("no-such-task", 1) == nil
    end

    test "filters and pagination pass straight through to the store read" do
      # `:status` — the dashboard's string spelling.
      assert %{rows: [only], total: 1} = TaskRegistry.list_tasks_page(status: "running")
      assert only.id == "mirror-c-run"

      # `:project_path` — exact match on the denormalized column.
      assert %{rows: rows, total: 2} = TaskRegistry.list_tasks_page(project_path: "/mirror/a")
      assert Enum.map(rows, & &1.id) == ["mirror-c-run", "mirror-a-old"]

      # `:search` — matches the branch_name column.
      assert %{rows: [found], total: 1} = TaskRegistry.list_tasks_page(search: "agent_beta")
      assert found.id == "mirror-b-new"

      # `:limit` / `:offset`, including the last-page refetch.
      assert %{rows: [first], total: 3} = TaskRegistry.list_tasks_page(limit: 1)
      assert first.id == "mirror-c-run"

      assert %{rows: [second], total: 3} = TaskRegistry.list_tasks_page(limit: 1, offset: 1)
      assert second.id == "mirror-b-new"

      assert %{rows: [last], total: 3} = TaskRegistry.list_tasks_page(limit: 2, offset: 9999)
      assert last.id == "mirror-a-old"
    end

    test "a dead store degrades to the documented values and the registry stays alive",
         %{store: store, registry: registry} do
      # Sanity: the live store answers these reads.
      assert %{rows: [_, _, _], total: 3} = TaskRegistry.list_tasks_page(limit: 10)
      assert %TaskInfo{id: "mirror-a-old"} = TaskRegistry.get_task_lite("mirror-a-old")

      assert %{entries: [_, _], total: 2} = TaskRegistry.list_task_archives("mirror-a-old")

      assert %{"agent_id" => 1} = TaskRegistry.get_agent_archive("mirror-a-old", 1)

      stop_store!(store)

      log =
        capture_log(fn ->
          assert TaskRegistry.list_tasks_page(limit: 10) == %{rows: [], total: 0}
          assert TaskRegistry.get_task_lite("mirror-a-old") == nil
          assert TaskRegistry.list_task_archives("mirror-a-old") == @empty_page
          assert TaskRegistry.get_agent_archive("mirror-a-old", 1) == nil
        end)

      assert log =~ "TaskRegistry: store operation"
      assert Process.alive?(Process.whereis(registry))
    end
  end

  describe "RemoteAPI delegates" do
    setup %{store: store} do
      seed!(store)
      :ok
    end

    test "return exactly what the Store call returns", %{store: store} do
      assert RemoteAPI.select_tasks_page(limit: 10) ==
               EvoGit.Store.select_tasks_page(store, limit: 10)

      assert RemoteAPI.get_task_lite("mirror-a-old") ==
               EvoGit.Store.get_task_lite(store, "mirror-a-old")

      assert RemoteAPI.list_task_archives("mirror-a-old") ==
               EvoGit.Store.list_task_archives(store, "mirror-a-old")

      assert RemoteAPI.list_task_archives("mirror-a-old", include_results: true) ==
               EvoGit.Store.list_task_archives(store, "mirror-a-old", include_results: true)

      assert RemoteAPI.get_agent_archive("mirror-a-old", 2) ==
               EvoGit.Store.get_agent_archive(store, "mirror-a-old", 2)
    end
  end

  describe "RemoteNode wrappers" do
    setup %{store: store} do
      seed!(store)
      :ok
    end

    test "the local-node path delegates and returns the Store values", %{store: store} do
      assert RemoteNode.list_tasks_page(node(), limit: 10) ==
               EvoGit.Store.select_tasks_page(store, limit: 10)

      assert RemoteNode.get_task_lite(node(), "mirror-a-old") ==
               EvoGit.Store.get_task_lite(store, "mirror-a-old")

      assert RemoteNode.list_task_archives(node(), "mirror-a-old") ==
               EvoGit.Store.list_task_archives(store, "mirror-a-old")

      assert RemoteNode.list_task_archives(node(), "mirror-a-old", include_results: true) ==
               EvoGit.Store.list_task_archives(store, "mirror-a-old", include_results: true)

      assert RemoteNode.get_agent_archive(node(), "mirror-a-old", 2) ==
               EvoGit.Store.get_agent_archive(store, "mirror-a-old", 2)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Seeds three tasks into the isolated store: a completed row with a large
  # result, a second completed row, and a running row. `started_at` ascends so
  # the list order is deterministic. The per-agent archive lives in its OWN
  # table (`task_agent_archives`), seeded separately below: `mirror-a-old` gets
  # a two-agent tree, `mirror-b-new` one agent, `mirror-c-run` none.
  defp seed!(store) do
    base = ~U[2026-03-01 00:00:00.000Z]

    :ok =
      EvoGit.Store.put_task(
        store,
        task("mirror-a-old", base,
          opts: [path: "/mirror/a", objective: "alpha objective"],
          branch_name: "genesis/agent_alpha",
          result:
            {:ok,
             %{
               commit_sha: "sha-a",
               branch_name: "genesis/agent_alpha",
               payload: String.duplicate("x", 150_000)
             }}
        )
      )

    :ok =
      EvoGit.Store.put_task(
        store,
        task("mirror-b-new", DateTime.add(base, 10, :second),
          opts: [path: "/mirror/b", objective: "beta objective"],
          branch_name: "genesis/agent_beta",
          result: {:ok, %{commit_sha: "sha-b", branch_name: "genesis/agent_beta"}}
        )
      )

    :ok =
      EvoGit.Store.put_task(
        store,
        task("mirror-c-run", DateTime.add(base, 20, :second),
          status: :running,
          opts: [path: "/mirror/a", objective: "gamma objective"],
          result: nil
        )
      )

    :ok =
      EvoGit.Store.put_task_archive(
        store,
        archive_entry("mirror-a-old", 1, 0, "archived a root", "alpha objective")
      )

    :ok =
      EvoGit.Store.put_task_archive(
        store,
        archive_entry("mirror-a-old", 2, 1, "archived a child", "beta objective")
      )

    :ok =
      EvoGit.Store.put_task_archive(
        store,
        archive_entry("mirror-b-new", 1, 0, "archived b root", "beta objective")
      )
  end

  defp task(id, started_at, overrides) do
    struct!(
      TaskInfo,
      Keyword.merge(
        [
          id: id,
          type: :evolve,
          status: :completed,
          opts: [path: "/mirror/a"],
          started_at: started_at,
          finished_at: started_at,
          logs: [],
          agent_count: 1
        ],
        overrides
      )
    )
  end

  defp archive_entry(task_id, agent_id, depth, result, objective) do
    %{
      task_id: task_id,
      agent_id: agent_id,
      depth: depth,
      objective: objective,
      result: result,
      completed_at: "2026-03-01T00:00:00Z"
    }
  end

  # Stops the isolated store AND removes its child spec, so its registered name
  # resolves to no process and every later `GenServer.call/3` exits `:noproc`
  # (the production crash chain's dead-server exit).
  defp stop_store!(store) do
    store_pid = Process.whereis(store)
    assert is_pid(store_pid)
    assert :ok = stop_supervised(store)
    refute Process.alive?(store_pid)
    assert Process.whereis(store) == nil
  end
end
