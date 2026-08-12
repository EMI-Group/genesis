defmodule EvoDashWeb.TaskExportControllerTest do
  use EvoDashWeb.ConnCase, async: false

  alias EvoGit.TaskRegistry
  alias EvoGit.TaskInfo

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
               MapSet.new(
                 ~w(task_id task_type repo_path status started_at finished_at agent_count usage archive_records)
               )

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

  describe "GET /tasks/:task_id/export with ?node= param" do
    # The node-aware export resolves `?node=` through EvoGit.RemoteConnections
    # (a TOML file under the config dir), so XDG_CONFIG_HOME is isolated per
    # test — same pattern as page_controller_test / settings_live_test.
    setup do
      original = System.get_env("XDG_CONFIG_HOME")

      tmp_config =
        Path.join(
          System.tmp_dir!(),
          "evogit_test_config_export_" <> to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(tmp_config)
      System.put_env("XDG_CONFIG_HOME", tmp_config)

      on_exit(fn ->
        File.rm_rf(tmp_config)

        if original do
          System.put_env("XDG_CONFIG_HOME", original)
        else
          System.delete_env("XDG_CONFIG_HOME")
        end
      end)

      :ok
    end

    test "returns 404 for an unknown node param", %{conn: conn} do
      conn = get(conn, "/tasks/nonexistent-task-id/export?node=unknown-target-id")

      assert response(conn, 404) =~ "Task not found"
    end

    test "returns 404 for a known but disconnected target", %{conn: conn} do
      id = "export-test-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: id,
          name: "Export Test Target"
        })

      # No connection manager is registered for the target, so
      # connection_status/1 degrades to :disconnected → the export must 404
      # exactly like the local not-found path.
      conn = get(conn, "/tasks/nonexistent-task-id/export?node=" <> id)

      assert response(conn, 404) =~ "Task not found"
    end

    test "?node=local keeps the local path working", %{conn: conn} do
      task_id = seed_completed_task([%{agent_id: "T1_A1", objective: "Build the feature"}])

      conn = get(conn, "/tasks/#{task_id}/export?node=local")

      assert response(conn, 200)

      cleanup_task(task_id)
    end
  end

  # Seeds a completed task with the given archive_metadata into the production
  # Store, returns the task id. Uses unique ids to avoid collisions.
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

    EvoGit.Store.put_task(EvoGit.Store, task)

    task_id
  end

  defp cleanup_task(task_id) do
    TaskRegistry.delete_task(task_id)
    # Sync the deletion cast to ensure it is processed before the next test.
    TaskRegistry.list_tasks()
  end
end
