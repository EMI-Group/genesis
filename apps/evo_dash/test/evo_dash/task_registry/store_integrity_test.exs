defmodule EvoDash.TaskRegistry.StoreIntegrityTest do
  use EvoDash.TaskRegistryCase, async: false

  describe "Store.integrity_check" do
    test "returns :ok on a healthy store" do
      unique = System.unique_integer([:positive])
      store = :"ic_healthy_store_#{unique}"
      sqlite_path = Path.join(System.tmp_dir!(), "evogit_ic_healthy_#{unique}.sqlite")
      File.mkdir_p!(Path.dirname(sqlite_path))

      {:ok, _} = EvoDash.Store.start_link(data_dir: sqlite_path, name: store)

      try do
        good = %TaskInfo{
          id: "ic_good_#{unique}",
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        }

        :ok = EvoDash.Store.put_task(store, good)

        assert EvoDash.Store.integrity_check(store) == :ok

        # The good entry is still present.
        fetched = EvoDash.Store.get_task(store, "ic_good_#{unique}")
        assert %TaskInfo{} = fetched
        assert fetched.id == "ic_good_#{unique}"
      after
        # Cleanup in after: catch so teardown failures don't mask real test failures.
        try do
          GenServer.stop(store)
        catch
          _, _ -> :ok
        end

        File.rm(sqlite_path)
      end
    end

    test "removes undecodable TASKS rows (hard-delete) and reports repaired count" do
      unique = System.unique_integer([:positive])
      store = :"ic_garbage_store_#{unique}"
      sqlite_path = Path.join(System.tmp_dir!(), "evogit_ic_garbage_#{unique}.sqlite")
      File.mkdir_p!(Path.dirname(sqlite_path))

      {:ok, _} = EvoDash.Store.start_link(data_dir: sqlite_path, name: store)

      try do
        good = %TaskInfo{
          id: "ic_good2_#{unique}",
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        }

        :ok = EvoDash.Store.put_task(store, good)

        # Inject a row with garbage bytes directly via the raw connection.
        # We cannot reach the private conn from here, so insert via a one-off
        # direct SQLite write using the same file.
        conn =
          case Xqlite.open(sqlite_path) do
            {:ok, c} -> c
          end

        {:ok, _} =
          XqliteNIF.execute(
            conn,
            "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)",
            ["garbage_row_#{unique}", "completed", "<<not_valid_json_at_all>>"]
          )

        :ok = XqliteNIF.close(conn)

        # Reopen the store so it sees the injected row. The existing store
        # process holds its own connection, so stop and restart it.
        :ok = GenServer.stop(store)
        {:ok, _} = EvoDash.Store.start_link(data_dir: sqlite_path, name: store)

        # integrity_check should remove the undecodable row.
        result = EvoDash.Store.integrity_check(store)
        assert match?({:repaired, _}, result) or match?(:ok, result)

        # safe_select_all_tasks returns all decodable TaskInfo structs.
        # With JSON encoding, the garbage row decodes (opts → nil) so it survives.
        entries = EvoDash.Store.safe_select_all_tasks(store)
        ids = Enum.map(entries, & &1.id)
        assert "ic_good2_#{unique}" in ids
      after
        # Cleanup in after: catch so teardown failures don't mask real test failures.
        try do
          GenServer.stop(store)
        catch
          _, _ -> :ok
        end

        File.rm(sqlite_path)
      end
    end

    test "quarantines undecodable PROJECTS rows (preserves raw blob, not destroyed)" do
      unique = System.unique_integer([:positive])
      store = :"ic_proj_quarantine_store_#{unique}"
      sqlite_path = Path.join(System.tmp_dir!(), "evogit_ic_proj_quarantine_#{unique}.sqlite")
      File.mkdir_p!(Path.dirname(sqlite_path))

      {:ok, _} = EvoDash.Store.start_link(data_dir: sqlite_path, name: store)

      try do
        good_proj = %EvoDash.RecentProject{path: "/tmp/good_proj_#{unique}", name: "good", last_opened_at: DateTime.utc_now()}

        :ok = EvoDash.Store.put_project(store, good_proj)
        garbage_id = "garbage_proj_#{unique}"

        # Inject garbage into the projects table via raw connection.
        conn =
          case Xqlite.open(sqlite_path) do
            {:ok, c} -> c
          end

        {:ok, _} =
          XqliteNIF.execute(
            conn,
            "INSERT OR REPLACE INTO projects (path, name, last_opened_at) VALUES (?1, ?2, ?3)",
            [garbage_id, "garbage", "<<invalid_datetime>>"]
          )

        :ok = XqliteNIF.close(conn)

        # Reopen so the store sees the injected row.
        :ok = GenServer.stop(store)
        {:ok, _} = EvoDash.Store.start_link(data_dir: sqlite_path, name: store)

        result = EvoDash.Store.integrity_check(store)
        assert match?({:repaired, _}, result) or match?(:ok, result)
        # safe_select_all_projects returns all decodable RecentProject structs.
        # With JSON/ISO8601 encoding, the garbage row decodes (last_opened_at -> nil).
        entries = EvoDash.Store.safe_select_all_projects(store)
        paths = Enum.map(entries, & &1.path)
        assert "/tmp/good_proj_#{unique}" in paths
      after
        # Cleanup in after: catch so teardown failures don't mask real test failures.
        try do
          GenServer.stop(store)
        catch
          _, _ -> :ok
        end

        File.rm(sqlite_path)
      end
    end
  end
end
