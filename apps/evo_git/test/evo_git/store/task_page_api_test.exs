defmodule EvoGit.Store.TaskPageApiTest do
  @moduledoc """
  Facade-level coverage for the LIGHTWEIGHT task read API added to
  `EvoGit.Store` (`select_tasks_page/2`, `get_task_lite/2`) plus the
  per-agent archive surface (`put_task_archive/2`, `list_task_archives/3`,
  `get_agent_archive/3`, `delete_task_archives/2`).

  The pages_test.exs suite pins the operations' semantics; this file pins the
  FACADE: the public client functions exist with the documented arities
  (including the `select_tasks_page(opts)` single-argument form that targets the
  default store), dispatch through the store GenServer, and keep their return
  shapes. Each test starts its OWN uniquely-named store GenServer so it never
  touches the shared application store.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Store
  alias EvoGit.TaskInfo

  defp start_store! do
    unique =
      "#{System.pid()}_#{System.system_time(:millisecond)}_" <>
        "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}"

    data_dir = Path.join(System.tmp_dir!(), "evogit_page_api_#{unique}.sqlite")
    name = :"page_api_store_#{unique}"

    {:ok, pid} = Store.start_link(data_dir: data_dir, name: name, pool_size: 1)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000), else: :ok

      File.rm(data_dir)
      File.rm(data_dir <> "-wal")
      File.rm(data_dir <> "-shm")
    end)

    name
  end

  defp task(id, started_at, overrides \\ []) do
    struct!(
      TaskInfo,
      Keyword.merge(
        [
          id: id,
          type: :evolve,
          status: :completed,
          opts: [path: "/facade/proj", objective: "facade #{id}"],
          started_at: started_at,
          finished_at: started_at,
          logs: ["line"],
          result: {:ok, %{commit_sha: "sha-#{id}", branch_name: "genesis/agent_#{id}"}},
          agent_count: 1
        ],
        overrides
      )
    )
  end

  test "select_tasks_page/2 dispatches to the store and keeps its shape" do
    store = start_store!()
    base = ~U[2026-02-01 00:00:00.000Z]

    :ok = Store.put_task(store, task("t-old", base))
    :ok = Store.put_task(store, task("t-new", DateTime.add(base, 10, :second)))

    assert %{rows: rows, total: 2} = Store.select_tasks_page(store, limit: 10)
    assert Enum.map(rows, & &1.id) == ["t-new", "t-old"]

    # A summary row never carries a blob key (and there is no archive column
    # on the task row any more — it lives in `task_agent_archives`).
    for absent <- [:result, :logs, :usage] do
      refute Map.has_key?(hd(rows), absent)
    end

    # Filters + the last-page refetch go through the facade unchanged.
    assert %{rows: [only], total: 1} = Store.select_tasks_page(store, search: "t-old")
    assert only.id == "t-old"

    assert %{rows: [last], total: 2} = Store.select_tasks_page(store, limit: 1, offset: 9999)
    assert last.id == "t-old"
  end

  test "get_task_lite/2 is field-identical to get_task/2 (the archive lives in its own table)" do
    store = start_store!()
    :ok = Store.put_task(store, task("t-detail", ~U[2026-02-01 00:00:00.000Z]))
    :ok = Store.put_task_archive(store, %{task_id: "t-detail", agent_id: 1, objective: "detail"})

    lite = Store.get_task_lite(store, "t-detail")
    assert %TaskInfo{id: "t-detail"} = lite
    # Nothing is dropped from the task row: the lite read equals the full read.
    assert lite == Store.get_task(store, "t-detail")
    assert {:ok, data} = lite.result
    assert data.commit_sha == "sha-t-detail"

    # The task struct has NO archive field at all; a task's archived agents are
    # reachable only through the relational `task_agent_archives` reads.
    refute Map.has_key?(%TaskInfo{}, :archive_metadata)

    assert %{entries: [%{"agent_id" => 1}], total: 1} =
             Store.list_task_archives(store, "t-detail")

    assert %{"agent_id" => 1} = Store.get_agent_archive(store, "t-detail", 1)

    # Missing rows keep each read's documented empty shape.
    assert Store.get_task_lite(store, "nope") == nil
  end

  # The `store \\ __MODULE__` defaults generate arity-1 forms, so a caller can
  # write `Store.select_tasks_page(opts)` / `Store.get_task_lite(id)` against the
  # default store exactly like the neighbouring reads.
  test "the documented default-store arities exist" do
    assert function_exported?(Store, :select_tasks_page, 1)
    assert function_exported?(Store, :select_tasks_page, 2)
    assert function_exported?(Store, :get_task_lite, 1)
    assert function_exported?(Store, :get_task_lite, 2)
    assert function_exported?(Store, :put_task_archive, 1)
    assert function_exported?(Store, :put_task_archive, 2)
    assert function_exported?(Store, :list_task_archives, 1)
    assert function_exported?(Store, :list_task_archives, 2)
    assert function_exported?(Store, :list_task_archives, 3)
    assert function_exported?(Store, :get_agent_archive, 2)
    assert function_exported?(Store, :get_agent_archive, 3)
    assert function_exported?(Store, :delete_task_archives, 1)
    assert function_exported?(Store, :delete_task_archives, 2)
  end
end
