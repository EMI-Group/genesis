defmodule EvoDash.NodeContextTest do
  use EvoDashWeb.ConnCase, async: false

  alias EvoGit.TaskInfo
  alias EvoGit.TaskRegistry

  setup do
    # Terminate production children to prevent auto-restarts and use isolated stores.
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_node_context_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({EvoGit.Store, data_dir: sqlite_path})

    start_supervised(
      {TaskRegistry, task_store: EvoGit.Store, data_dir: root, name: EvoGit.TaskRegistry}
    )

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.Store)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    end)

    :ok
  end

  # Inserts a task directly into the SQLite store (bypasses the async
  # task spawn that `start_task/2` triggers). Deterministic fixture for
  # the cancellation round-trip.
  defp insert_fixture!(overrides) do
    id = "fixture_#{System.unique_integer([:positive])}"

    task =
      %TaskInfo{
        id: id,
        type: :genesis,
        status: :pending,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      }
      |> Map.merge(Enum.into(overrides, %{}))

    EvoGit.Store.put_task(EvoGit.Store, task)
    id
  end

  describe "task-cancellation RPC delegates (local node, real paths)" do
    test "cancel_task/2 returns {:error, :not_found} for a missing task" do
      assert EvoDash.NodeContext.cancel_task(node(), "missing-id") == {:error, :not_found}
    end

    test "force_kill_task/2 returns {:error, :not_found} for a missing task" do
      assert EvoDash.NodeContext.force_kill_task(node(), "missing-id") == {:error, :not_found}
    end

    test "cancel_task/2 on a :pending task marks it :cancelled immediately" do
      id = insert_fixture!(status: :pending)

      assert EvoDash.NodeContext.cancel_task(node(), id) == :ok
      assert EvoGit.Store.get_task_status(EvoGit.Store, id) == :cancelled
    end
  end
end
