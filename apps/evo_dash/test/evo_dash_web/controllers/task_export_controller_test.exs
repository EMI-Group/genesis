defmodule EvoDashWeb.TaskExportControllerTest do
  use EvoDashWeb.ConnCase, async: false

  alias EvoDash.TaskRegistry
  alias EvoDash.TaskRegistry.TaskInfo

  describe "GET /tasks/:task_id/export" do
    test "returns 404 when the task does not exist", %{conn: conn} do
      conn = get(conn, ~p"/tasks/nonexistent-task-id/export")

      assert response(conn, 404) =~ "Task not found"
    end

    test "returns 404 when task exists but archive_metadata is nil", %{conn: conn} do
      task_id = seed_completed_task(nil)

      conn = get(conn, ~p"/tasks/#{task_id}/export")

      assert response(conn, 404) =~ "No archive data"

      cleanup_task(task_id)
    end

    test "returns 404 when task exists but archive_metadata is empty", %{conn: conn} do
      task_id = seed_completed_task([])

      conn = get(conn, ~p"/tasks/#{task_id}/export")

      assert response(conn, 404) =~ "No archive data"

      cleanup_task(task_id)
    end

    test "returns downloadable JSON when task has archive_metadata", %{conn: conn} do
      archive_metadata = [
        %{
          agent_id: "T1_A1",
          parent_id: nil,
          objective: "Build the feature",
          role: :manager,
          status: :completed
        },
        %{
          agent_id: "T2_A1",
          parent_id: "T1_A1",
          objective: "Implement module X",
          role: :executor,
          status: :completed
        }
      ]

      task_id = seed_completed_task(archive_metadata)

      conn = get(conn, ~p"/tasks/#{task_id}/export")

      body = response(conn, 200)

      [content_disposition] = get_resp_header(conn, "content-disposition")
      assert content_disposition =~ "attachment"
      assert content_disposition =~ "archive-#{task_id}.json"

      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      decoded = Jason.decode!(body)
      assert is_map(decoded)

      assert MapSet.new(Map.keys(decoded)) ==
               MapSet.new(~w(task_id task_type repo_path status started_at finished_at agent_count usage archive_records))

      assert decoded["task_id"] == task_id
      assert decoded["task_type"] == "genesis"
      assert decoded["repo_path"] == "/tmp/test"
      assert decoded["status"] == "completed"
      assert decoded["started_at"] != nil
      assert decoded["finished_at"] != nil
      assert decoded["agent_count"] == 3
      assert decoded["usage"] == nil

      records = decoded["archive_records"]
      assert is_list(records)
      assert length(records) == 2

      first = Enum.find(records, fn record -> record["agent_id"] == "T1_A1" end)
      assert first["objective"] == "Build the feature"
      assert first["role"] == "manager"
      assert first["parent_id"] == nil

      second = Enum.find(records, fn record -> record["agent_id"] == "T2_A1" end)
      assert second["parent_id"] == "T1_A1"
      assert second["objective"] == "Implement module X"

      cleanup_task(task_id)
    end
  end

  # Seeds a completed task with the given archive_metadata into the production
  # TaskStore, returns the task id. Uses unique ids to avoid collisions.
  defp seed_completed_task(archive_metadata) do
    task_id = "export_test_#{System.unique_integer([:positive])}"

    task = %TaskInfo{
      id: task_id,
      type: :genesis,
      status: :completed,
      opts: [path: "/tmp/test"],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      logs: [],
      result: nil,
      agent_count: 3,
      archive_metadata: archive_metadata
    }

    EvoDash.TaskStore.put_task(EvoDash.TaskStore, task)

    task_id
  end

  defp cleanup_task(task_id) do
    TaskRegistry.delete_task(task_id)
    # Sync the deletion cast to ensure it is processed before the next test.
    TaskRegistry.list_tasks()
  end
end
