defmodule EvoGit.TaskRegistry.StoreSkipAndLogTest do
  use EvoGit.TaskRegistryCase, async: false

  import ExUnit.CaptureLog

  describe "safe_select_all_tasks/1 skip-and-log semantics" do
    test "skips an undecodable task row, logs a warning, and leaves the row untouched" do
      unique = System.unique_integer([:positive])
      {store, sqlite_path} = start_store(unique, "tasks")

      try do
        good = %TaskInfo{
          id: "good_task_#{unique}",
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        }

        :ok = EvoGit.Store.put_task(store, good)

        garbage_id = "garbage_task_#{unique}"

        # Inject a row whose `opts` is a JSON array of non-pair elements —
        # decode_opts/1 pattern-matches each element as [key, value], so this
        # raises FunctionClauseError and the row must be skipped. (String
        # garbage in a JSON column decodes to nil instead, so it would NOT
        # exercise the skip path.)
        conn = raw_conn(sqlite_path)

        {:ok, _} =
          XqliteNIF.execute(
            conn,
            "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)",
            [garbage_id, "completed", "[1,2,3]"]
          )

        :ok = XqliteNIF.close(conn)

        # WAL mode: the store's own connection sees the raw-injected row on
        # its next read — no restart needed.
        {entries, log} = with_log(fn -> EvoGit.Store.safe_select_all_tasks(store) end)

        ids = Enum.map(entries, & &1.id)
        assert "good_task_#{unique}" in ids
        refute garbage_id in ids

        assert log =~ "Store: skipping undecodable row in tasks (id: #{inspect(garbage_id)})"

        # No extra tables were created (the only tables are tasks/projects),
        # and the bad row is untouched.
        conn = raw_conn(sqlite_path)

        {:ok, %{rows: unexpected_tables}} =
          XqliteNIF.query(
            conn,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT IN ('tasks', 'projects')",
            []
          )

        assert unexpected_tables == []

        {:ok, %{rows: bad_rows}} =
          XqliteNIF.query(conn, "SELECT COUNT(*) FROM tasks WHERE id = ?", [garbage_id])

        assert bad_rows == [[1]]
        :ok = XqliteNIF.close(conn)
      after
        cleanup_store(store, sqlite_path)
      end
    end

    test "logs nothing and returns all rows when every row decodes" do
      unique = System.unique_integer([:positive])
      {store, sqlite_path} = start_store(unique, "clean")

      try do
        good = %TaskInfo{
          id: "clean_good_#{unique}",
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        }

        :ok = EvoGit.Store.put_task(store, good)

        {entries, log} = with_log(fn -> EvoGit.Store.safe_select_all_tasks(store) end)

        assert Enum.map(entries, & &1.id) == ["clean_good_#{unique}"]
        refute log =~ "skipping undecodable row"
      after
        cleanup_store(store, sqlite_path)
      end
    end
  end

  describe "safe_select_all_projects/1 skip-and-log semantics" do
    test "skips an undecodable project row, logs a warning, and leaves the row untouched" do
      unique = System.unique_integer([:positive])
      sqlite_path = Path.join(System.tmp_dir!(), "evogit_skip_log_projects_#{unique}.sqlite")
      File.mkdir_p!(Path.dirname(sqlite_path))

      # Pre-create ONLY the projects table with INTEGER-affinity last_opened_at
      # (a legacy-schema scenario). A TEXT-affinity column would coerce the
      # injected integer to text, so this is required for the value to survive
      # storage as an integer. The Store's create_tables uses IF NOT EXISTS,
      # so it keeps this table untouched.
      conn = raw_conn(sqlite_path)

      {:ok, _} =
        XqliteNIF.execute(
          conn,
          "CREATE TABLE projects (path TEXT PRIMARY KEY, name TEXT, last_opened_at INTEGER)",
          []
        )

      :ok = XqliteNIF.close(conn)

      store = :"skip_log_projects_#{unique}"
      {:ok, _} = EvoGit.Store.start_link(data_dir: sqlite_path, name: store)

      try do
        good_proj = %EvoGit.RecentProject{
          path: "/tmp/good_proj_#{unique}",
          name: "good",
          last_opened_at: DateTime.utc_now()
        }

        :ok = EvoGit.Store.put_project(store, good_proj)

        garbage_path = "garbage_proj_#{unique}"

        # The injected INTEGER survives storage in the INTEGER-affinity column
        # — decode_datetime/1 has no clause for non-binary values, so
        # decode_project/1 raises and the row must be skipped.
        conn = raw_conn(sqlite_path)

        {:ok, _} =
          XqliteNIF.execute(
            conn,
            "INSERT OR REPLACE INTO projects (path, name, last_opened_at) VALUES (?1, ?2, ?3)",
            [garbage_path, "garbage", 12345]
          )

        :ok = XqliteNIF.close(conn)

        # WAL mode: the store's own connection sees the raw-injected row on
        # its next read — no restart needed.
        {entries, log} = with_log(fn -> EvoGit.Store.safe_select_all_projects(store) end)

        paths = Enum.map(entries, & &1.path)
        assert "/tmp/good_proj_#{unique}" in paths
        refute garbage_path in paths

        assert log =~ "Store: skipping undecodable row in projects (id: #{inspect(garbage_path)})"

        # No extra tables were created (the only tables are tasks/projects),
        # and the bad row is untouched.
        conn = raw_conn(sqlite_path)

        {:ok, %{rows: unexpected_tables}} =
          XqliteNIF.query(
            conn,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT IN ('tasks', 'projects')",
            []
          )

        assert unexpected_tables == []

        {:ok, %{rows: bad_rows}} =
          XqliteNIF.query(conn, "SELECT COUNT(*) FROM projects WHERE path = ?", [garbage_path])

        assert bad_rows == [[1]]
        :ok = XqliteNIF.close(conn)
      after
        cleanup_store(store, sqlite_path)
      end
    end
  end

  describe "safe_select_paginated_tasks/2 skip-and-log semantics" do
    test "skips an undecodable task row, logs a warning, and keeps the SQL-level total" do
      unique = System.unique_integer([:positive])
      {store, sqlite_path} = start_store(unique, "paginated")

      try do
        good = %TaskInfo{
          id: "good_pag_#{unique}",
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        }

        :ok = EvoGit.Store.put_task(store, good)

        garbage_id = "garbage_pag_#{unique}"

        conn = raw_conn(sqlite_path)

        {:ok, _} =
          XqliteNIF.execute(
            conn,
            "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)",
            [garbage_id, "completed", "[1,2,3]"]
          )

        :ok = XqliteNIF.close(conn)

        {{tasks, total_count}, log} =
          with_log(fn ->
            EvoGit.Store.safe_select_paginated_tasks(store, limit: 50, offset: 0)
          end)

        ids = Enum.map(tasks, & &1.id)
        assert "good_pag_#{unique}" in ids
        refute garbage_id in ids
        # total_count is the SQL-level row count — the bad row is counted even
        # though it is skipped at decode time.
        assert total_count == 2

        assert log =~ "Store: skipping undecodable row in tasks (id: #{inspect(garbage_id)})"
      after
        cleanup_store(store, sqlite_path)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Starts a uniquely-named Store GenServer against a temp sqlite file.
  defp start_store(unique, label) do
    store = :"skip_log_#{label}_#{unique}"
    sqlite_path = Path.join(System.tmp_dir!(), "evogit_skip_log_#{label}_#{unique}.sqlite")
    File.mkdir_p!(Path.dirname(sqlite_path))
    {:ok, _} = EvoGit.Store.start_link(data_dir: sqlite_path, name: store)
    {store, sqlite_path}
  end

  # Opens a one-off raw SQLite connection for garbage injection / inspection.
  defp raw_conn(sqlite_path) do
    case Xqlite.open(sqlite_path) do
      {:ok, conn} -> conn
    end
  end

  # Cleanup in after: catch so teardown failures don't mask real test failures.
  defp cleanup_store(store, sqlite_path) do
    try do
      GenServer.stop(store)
    catch
      _, _ -> :ok
    end

    File.rm(sqlite_path)
  end
end
