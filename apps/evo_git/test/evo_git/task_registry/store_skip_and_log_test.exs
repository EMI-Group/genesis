defmodule EvoGit.TaskRegistry.StoreSkipAndLogTest do
  @moduledoc """
  Runs `async: true`: every test starts its OWN uniquely-named `EvoGit.Store`
  against a private temporary SQLite file (`start_store/2` / `EvoGit.Store.start_link`)
  and mutates it only through raw `Xqlite` connections to that same file — no
  BEAM-global state (no app-env key, no `:evogit_*` ETS table, no global
  scheduler config), and the `EvoGit.TaskRegistryCase` fixture it still `use`s
  provides an isolated Store + registry that this file never touches.
  """

  use EvoGit.TaskRegistryCase, async: true

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
        # decode_opts/1 is a strict canonical codec that raises an explicit
        # ArgumentError on ANY non-object JSON (only JSON objects with string
        # keys are canonical), so this non-canonical array raises and the row
        # must be skipped.
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

        # No extra tables were created (the tables are tasks/vct_mounts plus
        # the per-agent archive table), and the bad row is untouched.
        conn = raw_conn(sqlite_path)

        {:ok, %{rows: unexpected_tables}} =
          XqliteNIF.query(
            conn,
            # `schema_migrations` is the Ecto migrator's own bookkeeping
            # table and `task_agent_archives` the per-agent archive table —
            # both are created by Boot's migrations at store start; the
            # assertion's intent is that skip-and-log performs NO
            # data-movement DDL of its own.
            "SELECT name FROM sqlite_master WHERE type = 'table' " <>
              "AND name NOT IN ('tasks', 'vct_mounts', 'schema_migrations', 'task_agent_archives', 'task_progress')",
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

        # The refute is SCOPED to this store's only row id on purpose:
        # `with_log/2` captures GLOBALLY (its logger handler is level-filtered
        # only — no process/test scoping), so a concurrent `async: true` module
        # (store/operations/safety_test.exs) logging its own
        # `... in tasks (id: "bad")` skip under load would falsify an unscoped
        # refute. This store holds exactly one row — `clean_good_<unique>`,
        # which decodes fine — so the only skip it could ever emit names that
        # id (shape pinned by the positive test above).
        refute log =~
                 "skipping undecodable row in tasks (id: #{inspect("clean_good_#{unique}")})"
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
    sqlite_path = db_path(label, unique)
    File.mkdir_p!(Path.dirname(sqlite_path))
    {:ok, _} = EvoGit.Store.start_link(data_dir: sqlite_path, name: store)
    {store, sqlite_path}
  end

  # A private tmp SQLite path for one test. The name embeds the OS pid +
  # wall-clock ms on top of the per-BEAM unique integer: `System.unique_integer/1`
  # restarts in every BEAM, so without those a PREVIOUS test run's leftover file
  # would be silently reopened — a fresh-looking DB already holding stale rows.
  defp db_path(label, unique) do
    id = "#{label}_#{:os.getpid()}_#{System.system_time(:millisecond)}_#{unique}"
    Path.join(System.tmp_dir!(), "evogit_skip_log_#{id}.sqlite")
  end

  # Opens a one-off raw SQLite connection for garbage injection / inspection.
  defp raw_conn(sqlite_path) do
    case Xqlite.open(sqlite_path) do
      {:ok, conn} -> conn
    end
  end

  # Cleanup in after: catch so teardown failures don't mask real test failures.
  # The DB file AND its WAL sidecars are removed (`File.rm/1` is a no-op for an
  # already-absent path), so nothing this test created is left in the tmpdir.
  defp cleanup_store(store, sqlite_path) do
    try do
      GenServer.stop(store)
    catch
      _, _ -> :ok
    end

    File.rm(sqlite_path)
    File.rm(sqlite_path <> "-wal")
    File.rm(sqlite_path <> "-shm")
  end
end
