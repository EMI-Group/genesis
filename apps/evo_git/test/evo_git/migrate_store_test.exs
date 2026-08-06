defmodule EvoGit.MigrateStoreTest do
  @moduledoc """
  Tests for the one-time `mix migrate.store` task (`Mix.Tasks.Migrate.Store`),
  which upgrades an existing legacy `tasks.sqlite` database to the current
  schema.

  The task is invoked DIRECTLY (`Mix.Tasks.Migrate.Store.run([db_path])`) and
  opens its own raw Xqlite connection — it never touches the running
  `EvoGit.Store`. All assertions here go through raw Xqlite connections (or
  `Codec.decode_*` round-trips) against the private temp DB, so the task's own
  connection semantics are what is exercised.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias EvoGit.Store.Codec

  ## Setup

  setup %{tmp_dir: tmp_dir} do
    {:ok, %{db_path: Path.join(tmp_dir, "tasks.sqlite")}}
  end

  ## Tests

  describe "legacy database full upgrade" do
    test "brings an old-format database up to the current schema", %{db_path: path} do
      build_legacy_db!(path)

      # Pre-migration sanity: the legacy table has no updated_at column and
      # none of the new indexes; the DETS-era quarantine tables are present.
      refute "updated_at" in columns(path)
      refute "idx_tasks_updated_at" in indexes(path)
      refute "idx_tasks_started_at" in indexes(path)
      assert quarantine_tables(path) == ["projects_quarantine", "tasks_quarantine"]

      run_task!(path)

      # --- Steps 1/2: schema (tables, indexes, missing columns) ---
      cols = columns(path)
      assert length(cols) == 19
      assert "updated_at" in cols

      idxs = indexes(path)

      for idx <-
            ~w(idx_tasks_status idx_tasks_finished_at idx_tasks_lease_expires_at idx_tasks_project_path idx_tasks_updated_at idx_tasks_started_at) do
        assert idx in idxs
      end

      # --- Step 3: timestamp normalization (variable → fixed precision) ---
      rows = tasks_by_id(path)
      assert rows["plain"].started_at == "2024-01-01T12:00:00.123Z"
      assert rows["plain"].finished_at == nil
      assert rows["scalar-int"].started_at == "2024-01-01T12:00:00.000Z"
      assert rows["scalar-true"].finished_at == "2024-01-01T13:00:00.654Z"
      assert rows["tagged-ok"].started_at == "2024-01-01T14:00:00.000Z"

      # --- Step 4: result rewrite → canonical tagged JSON ---
      assert rows["plain"].result == ~s({"__result_tag__":"string","value":"Task crashed: boom"})
      assert Codec.decode_result(rows["plain"].result) == "Task crashed: boom"

      # JSON scalars are wrapped too — content preserved verbatim.
      assert rows["scalar-int"].result == ~s({"__result_tag__":"string","value":"42"})
      assert Codec.decode_result(rows["scalar-int"].result) == "42"

      assert rows["scalar-true"].result == ~s({"__result_tag__":"string","value":"true"})
      assert Codec.decode_result(rows["scalar-true"].result) == "true"

      assert rows["scalar-str"].result == ~S({"__result_tag__":"string","value":"\"hello\""})
      assert Codec.decode_result(rows["scalar-str"].result) == ~s("hello")

      # Tagged rows stay byte-identical; untagged JSON rows are wrapped as
      # string-tagged JSON with content preserved verbatim; the JSON literal
      # `null` is converted to SQL NULL.
      assert rows["tagged-ok"].result ==
               ~s({"__result_tag__":"ok","data":{"branch_name":"feat/x","commit_sha":"abc"}})

      assert rows["tagged-error"].result == ~s({"__result_tag__":"error","reason":"boom"})
      assert rows["untagged-obj"].result == ~S({"__result_tag__":"string","value":"{\"x\":1}"})
      assert Codec.decode_result(rows["untagged-obj"].result) == ~s({"x":1})
      assert rows["untagged-arr"].result == ~s({"__result_tag__":"string","value":"[1,2]"})
      assert Codec.decode_result(rows["untagged-arr"].result) == "[1,2]"
      assert rows["null-result"].result == nil
      assert rows["json-null"].result == nil

      # Plain-string results on the opts rows are wrapped the same way.
      assert Codec.decode_result(rows["legacy-path"].result) == "legacy path crash"

      # --- Step 5: opts rewrite (legacy pair arrays → JSON objects) ---
      assert rows["legacy-path"].opts == ~s({"path":"/tmp/p"})
      assert Codec.decode_opts(rows["legacy-path"].opts) == [path: "/tmp/p"]

      assert rows["legacy-archive"].opts == ~s({"archive":true})
      assert Codec.decode_opts(rows["legacy-archive"].opts) == [archive: true]

      # Malformed opts rows are skipped without crashing and left as-is.
      assert rows["malformed-flat"].opts == ~s(["path","/tmp/p"])
      assert rows["malformed-pairs"].opts == "[1,2]"
      assert rows["malformed-json"].opts == "{oops"

      # --- Step 6: branch_name backfill (only the tagged-ok row) ---
      assert rows["tagged-ok"].branch_name == "feat/x"

      for id <-
            ~w(plain scalar-int scalar-true scalar-str tagged-error untagged-obj untagged-arr null-result legacy-path legacy-archive malformed-flat malformed-pairs malformed-json) do
        assert rows[id].branch_name == nil
      end

      # --- Step 7: updated_at backfill (finished_at → started_at → now) ---
      assert rows["plain"].updated_at == "2024-01-01T12:00:00.123Z"
      assert rows["scalar-int"].updated_at == "2024-01-01T12:00:00.000Z"
      assert rows["scalar-true"].updated_at == "2024-01-01T13:00:00.654Z"
      assert rows["tagged-ok"].updated_at == "2024-01-01T14:00:00.000Z"

      # Row with both timestamps NULL gets a parseable "now" string.
      assert {:ok, dt, 0} = DateTime.from_iso8601(rows["scalar-str"].updated_at)
      assert DateTime.diff(DateTime.utc_now(), dt, :second) < 120

      # --- Step 8: quarantine tables dropped ---
      assert quarantine_tables(path) == []
      assert Enum.sort(table_names(path)) == ["projects", "tasks"]
    end
  end

  describe "idempotency" do
    test "running the task a second time changes nothing", %{db_path: path} do
      build_legacy_db!(path)
      run_task!(path)

      before_rows = task_rows(path)
      before_cols = columns(path)

      msgs = with_process_shell(fn -> run_task!(path) end)

      # All guarded steps print 0 on the second run.
      assert "[4/8] Result rewrite → canonical JSON — ok (rows rewritten: 0)" in msgs
      assert "[5/8] Opts rewrite → JSON object — ok (rows rewritten to JSON object: 0)" in msgs
      assert "[6/8] branch_name backfill — ok (rows backfilled: 0)" in msgs
      assert "[7/8] updated_at backfill — ok (rows backfilled: 0)" in msgs

      # DB state is byte-identical after the second run.
      assert task_rows(path) == before_rows
      assert columns(path) == before_cols
    end
  end

  describe "fresh database" do
    test "creates the full schema and no-ops on every step", %{db_path: path} do
      refute File.exists?(path)

      run_task!(path)

      assert File.exists?(path)

      cols = columns(path)
      assert length(cols) == 19
      assert "updated_at" in cols

      idxs = indexes(path)
      assert "idx_tasks_updated_at" in idxs
      assert "idx_tasks_started_at" in idxs

      assert Enum.sort(table_names(path)) == ["projects", "tasks"]
      assert task_rows(path) == []

      # A second run is equally harmless.
      run_task!(path)
      assert length(columns(path)) == 19
    end
  end

  ## Helpers

  # --- raw Xqlite helpers (never touch the running EvoGit.Store) ---

  defp open_conn!(path) do
    {:ok, conn} = Xqlite.open(path)
    conn
  end

  defp close_conn!(conn), do: :ok = XqliteNIF.close(conn)

  defp run_task!(path) do
    assert :ok = Mix.Tasks.Migrate.Store.run([path])
  end

  defp columns(path) do
    conn = open_conn!(path)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "PRAGMA table_info(tasks)", [])

    close_conn!(conn)
    Enum.map(rows, fn [_cid, name | _] -> name end)
  end

  defp indexes(path) do
    conn = open_conn!(path)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "PRAGMA index_list(tasks)", [])

    close_conn!(conn)
    Enum.map(rows, fn [_seq, name | _] -> name end)
  end

  defp table_names(path) do
    conn = open_conn!(path)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT name FROM sqlite_master WHERE type = 'table'", [])

    close_conn!(conn)
    Enum.map(rows, fn [name] -> name end)
  end

  defp quarantine_tables(path) do
    conn = open_conn!(path)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(
        conn,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('tasks_quarantine', 'projects_quarantine') ORDER BY name",
        []
      )

    close_conn!(conn)
    Enum.map(rows, fn [name] -> name end)
  end

  # --- legacy DB builder ---

  # The 18-column tasks table as written by older builds (current
  # `EvoGit.Store.Codec.task_columns/0`, WITHOUT the store-internal
  # `updated_at` column), plus the DETS-era quarantine tables.
  defp build_legacy_db!(path) do
    conn = open_conn!(path)

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        """
        CREATE TABLE tasks (
          id TEXT PRIMARY KEY,
          type TEXT,
          status TEXT NOT NULL,
          opts TEXT,
          started_at TEXT,
          finished_at TEXT,
          logs TEXT,
          result TEXT,
          review_status TEXT,
          usage TEXT,
          agent_count INTEGER,
          base_sha TEXT,
          commit_sha TEXT,
          archive_metadata TEXT,
          lease_expires_at INTEGER,
          model_id TEXT,
          project_path TEXT,
          branch_name TEXT
        )
        """,
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE TABLE projects (path TEXT PRIMARY KEY, name TEXT, last_opened_at TEXT)",
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE TABLE tasks_quarantine (id TEXT PRIMARY KEY, data TEXT)",
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE TABLE projects_quarantine (id TEXT PRIMARY KEY, data TEXT)",
        []
      )

    Enum.each(legacy_rows(), &insert_task!(conn, &1))
    close_conn!(conn)
  end

  defp insert_task!(conn, row) do
    {:ok, _} =
      XqliteNIF.execute(
        conn,
        """
        INSERT INTO tasks (id, type, status, opts, started_at, finished_at, result)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        """,
        [
          row.id,
          "genesis",
          "completed",
          Map.get(row, :opts),
          Map.get(row, :started_at),
          Map.get(row, :finished_at),
          Map.get(row, :result)
        ]
      )
  end

  # Rows covering every result shape, opts shape, and timestamp precision the
  # migration must handle.
  defp legacy_rows do
    [
      # --- result shapes ---
      %{id: "plain", started_at: "2024-01-01T12:00:00.123456Z", result: "Task crashed: boom"},
      %{id: "scalar-int", started_at: "2024-01-01T12:00:00Z", result: "42"},
      %{id: "scalar-true", finished_at: "2024-01-01T13:00:00.654321Z", result: "true"},
      %{id: "scalar-str", result: ~s("hello")},
      %{
        id: "tagged-ok",
        started_at: "2024-01-01T14:00:00Z",
        result: ~s({"__result_tag__":"ok","data":{"branch_name":"feat/x","commit_sha":"abc"}})
      },
      %{id: "tagged-error", result: ~s({"__result_tag__":"error","reason":"boom"})},
      %{id: "untagged-obj", result: ~s({"x":1})},
      %{id: "untagged-arr", result: "[1,2]"},
      %{id: "null-result"},
      %{id: "json-null", result: "null"},
      # --- opts shapes ---
      %{id: "legacy-path", result: "legacy path crash", opts: ~s([["path","/tmp/p"]])},
      %{id: "legacy-archive", result: "legacy archive crash", opts: ~s([["archive",true]])},
      %{id: "malformed-flat", result: "malformed flat opts", opts: ~s(["path","/tmp/p"])},
      %{id: "malformed-pairs", result: "malformed pair opts", opts: "[1,2]"},
      %{id: "malformed-json", result: "malformed json opts", opts: "{oops"}
    ]
  end

  defp tasks_by_id(path) do
    conn = open_conn!(path)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(
        conn,
        """
        SELECT id, type, status, opts, started_at, finished_at, result, branch_name, updated_at
        FROM tasks ORDER BY id
        """,
        []
      )

    close_conn!(conn)

    Map.new(rows, fn [
                       id,
                       type,
                       status,
                       opts,
                       started_at,
                       finished_at,
                       result,
                       branch_name,
                       updated_at
                     ] ->
      {id,
       %{
         type: type,
         status: status,
         opts: opts,
         started_at: started_at,
         finished_at: finished_at,
         result: result,
         branch_name: branch_name,
         updated_at: updated_at
       }}
    end)
  end

  # Full-row snapshot used to prove the second run leaves DB content untouched.
  defp task_rows(path) do
    conn = open_conn!(path)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(
        conn,
        """
        SELECT id, type, status, opts, started_at, finished_at, logs, result,
               review_status, usage, agent_count, base_sha, commit_sha,
               archive_metadata, lease_expires_at, model_id, project_path,
               branch_name, updated_at
        FROM tasks ORDER BY id
        """,
        []
      )

    close_conn!(conn)
    rows
  end

  # --- Mix shell capture ---

  # Swaps the Mix shell for Mix.Shell.Process, runs `fun`, and returns all
  # `:info` messages the task printed. The previous shell is restored via
  # on_exit — Mix.shell/1 writes to the project stack, which outlives the
  # test process.
  defp with_process_shell(fun) do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    fun.()
    collect_info_messages()
  end

  defp collect_info_messages(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> collect_info_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
