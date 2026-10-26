defmodule EvoGit.TaskRegistry.LightweightReadMirrorTest do
  @moduledoc """
  Mirror coverage for the LIGHTWEIGHT task read API
  (`EvoGit.Store.select_tasks_page/2`, `get_task_lite/2`, `get_task_archive/2`)
  through its reporting layers:

    * `EvoGit.TaskRegistry` — `list_tasks_page/1`, `get_task_lite/1`,
      `get_task_archive/1` (offloaded through `Task.start` + `StoreGuard.read/3`);
    * `EvoGit.AgentScheduler.RemoteAPI` — `select_tasks_page/1`,
      `get_task_lite/1`, `get_task_archive/1` (pure delegates);
    * `EvoGit.RemoteNode` — `list_tasks_page/2`, `get_task_lite/2`,
      `get_task_archive/2` (local-direct / remote-`:erpc`).

  Each test runs against its OWN isolated store + registry
  (`EvoGit.TaskRegistryCase`), so nothing global is touched.
  """

  use EvoGit.TaskRegistryCase, async: true

  import ExUnit.CaptureLog

  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.RemoteNode
  alias EvoGit.TaskInfo

  @archive_a [%{"role" => "user", "content" => "archived a"}]
  @archive_b [%{"role" => "user", "content" => "archived b"}]

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
      for row <- rows, absent <- [:result, :archive_metadata, :logs, :usage] do
        refute Map.has_key?(row, absent)
      end

      assert hd(rows).status == :running
    end

    test "get_task_lite/1 drops the archive but decodes everything else" do
      assert %TaskInfo{id: "mirror-a-old"} = lite = TaskRegistry.get_task_lite("mirror-a-old")
      assert lite.archive_metadata == nil
      assert lite.branch_name == "genesis/agent_alpha"

      assert {:ok, data} = lite.result
      refute Map.has_key?(data, :archive_records)
      assert data.commit_sha == "sha-a"

      # Missing rows keep the read's documented empty shape.
      assert TaskRegistry.get_task_lite("no-such-task") == nil
    end

    test "get_task_archive/1 returns the archive records on demand" do
      assert TaskRegistry.get_task_archive("mirror-a-old") == @archive_a
      assert TaskRegistry.get_task_archive("mirror-b-new") == @archive_b
      assert TaskRegistry.get_task_archive("mirror-c-run") == []
      assert TaskRegistry.get_task_archive("no-such-task") == []
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
      assert TaskRegistry.get_task_archive("mirror-a-old") == @archive_a

      stop_store!(store)

      log =
        capture_log(fn ->
          assert TaskRegistry.list_tasks_page(limit: 10) == %{rows: [], total: 0}
          assert TaskRegistry.get_task_lite("mirror-a-old") == nil
          assert TaskRegistry.get_task_archive("mirror-a-old") == []
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

      assert RemoteAPI.get_task_archive("mirror-a-old") ==
               EvoGit.Store.get_task_archive(store, "mirror-a-old")
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

      assert RemoteNode.get_task_archive(node(), "mirror-a-old") ==
               EvoGit.Store.get_task_archive(store, "mirror-a-old")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Seeds three tasks into the isolated store: a completed row with a large
  # result + archive, a second completed row with its own archive, and a running
  # row with neither. `started_at` ascends so the list order is deterministic.
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
               archive_records: [%{"role" => "assistant", "content" => "big archive"}],
               payload: String.duplicate("x", 150_000)
             }},
          archive_metadata: @archive_a
        )
      )

    :ok =
      EvoGit.Store.put_task(
        store,
        task("mirror-b-new", DateTime.add(base, 10, :second),
          opts: [path: "/mirror/b", objective: "beta objective"],
          branch_name: "genesis/agent_beta",
          result: {:ok, %{commit_sha: "sha-b", branch_name: "genesis/agent_beta"}},
          archive_metadata: @archive_b
        )
      )

    :ok =
      EvoGit.Store.put_task(
        store,
        task("mirror-c-run", DateTime.add(base, 20, :second),
          status: :running,
          opts: [path: "/mirror/a", objective: "gamma objective"],
          result: nil,
          archive_metadata: nil
        )
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
