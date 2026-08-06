defmodule EvoGit.StoreSchemaMigrationTest do
  use ExUnit.Case, async: false

  alias EvoGit.Store
  alias EvoGit.Store.{Codec, Schema}
  alias EvoGit.TaskInfo

  # Tests the fixed-precision timestamp migration (`normalize_timestamps/1`)
  # introduced by the SQLite-optimization refactor. All tests use RAW Xqlite
  # connections against a private temp DB — the migration must be exercised
  # directly (Store.init/1 already runs it, so a GenServer-backed store would
  # never see unnormalized rows), except for the final wiring test which seeds
  # old-format data and then starts a uniquely-named Store to prove init runs
  # the migration before serving reads.
  setup do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_store_schema_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, %{sqlite_path: sqlite_path}}
  end

  # Opens a raw Xqlite connection to a fresh DB with the full store schema.
  defp open_schema!(path) do
    {:ok, conn} = Xqlite.open(path)
    :ok = Schema.create_tables(conn)
    :ok = Schema.migrate_schema(conn)
    conn
  end

  defp insert_task!(conn, id, started_at, finished_at) do
    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "INSERT INTO tasks (id, status, started_at, finished_at) VALUES (?1, ?2, ?3, ?4)",
        [id, "completed", started_at, finished_at]
      )
  end

  defp task_timestamps(conn) do
    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT id, started_at, finished_at FROM tasks ORDER BY id", [])

    Map.new(rows, fn [id, started_at, finished_at] -> {id, {started_at, finished_at}} end)
  end

  describe "normalize_timestamps/1" do
    test "rewrites variable-precision timestamps to fixed millisecond precision", %{
      sqlite_path: path
    } do
      conn = open_schema!(path)

      insert_task!(conn, "six", "2024-01-01T12:00:00.123456Z", "2024-01-01T13:00:00.654321Z")
      insert_task!(conn, "whole", "2024-01-01T12:00:00Z", "2024-01-01T13:00:00Z")
      insert_task!(conn, "normalized", "2024-01-01T12:00:00.123Z", "2024-01-01T13:00:00.456Z")
      insert_task!(conn, "garbage", "not-a-date", "also-not-a-date")
      insert_task!(conn, "null", nil, nil)

      assert :ok = Schema.normalize_timestamps(conn)
      ts = task_timestamps(conn)

      # 6-digit fractional seconds are truncated to 3 digits.
      assert ts["six"] == {"2024-01-01T12:00:00.123Z", "2024-01-01T13:00:00.654Z"}
      # Whole seconds gain an explicit .000Z (24-char sortable form).
      assert ts["whole"] == {"2024-01-01T12:00:00.000Z", "2024-01-01T13:00:00.000Z"}
      # Already-normalized rows are untouched.
      assert ts["normalized"] == {"2024-01-01T12:00:00.123Z", "2024-01-01T13:00:00.456Z"}
      # Unparseable and NULL rows are untouched.
      assert ts["garbage"] == {"not-a-date", "also-not-a-date"}
      assert ts["null"] == {nil, nil}

      :ok = XqliteNIF.close(conn)
    end

    test "is idempotent — a second run changes nothing", %{sqlite_path: path} do
      conn = open_schema!(path)

      insert_task!(conn, "six", "2024-01-01T12:00:00.123456Z", "2024-01-01T13:00:00Z")
      insert_task!(conn, "normalized", "2024-01-01T12:00:00.123Z", nil)
      insert_task!(conn, "garbage", "not-a-date", "also-not-a-date")

      assert :ok = Schema.normalize_timestamps(conn)
      after_first = task_timestamps(conn)
      assert after_first["six"] == {"2024-01-01T12:00:00.123Z", "2024-01-01T13:00:00.000Z"}

      assert :ok = Schema.normalize_timestamps(conn)
      after_second = task_timestamps(conn)

      assert after_second == after_first

      :ok = XqliteNIF.close(conn)
    end

    test "normalizes projects.last_opened_at the same way", %{sqlite_path: path} do
      conn = open_schema!(path)

      rows = [
        ["/p-six", "P1", "2024-01-01T12:00:00.123456Z"],
        ["/p-whole", "P2", "2024-01-01T12:00:00Z"],
        ["/p-normalized", "P3", "2024-01-01T12:00:00.123Z"],
        ["/p-garbage", "P4", "not-a-date"],
        ["/p-null", "P5", nil]
      ]

      Enum.each(rows, fn [project_path, name, last_opened_at] ->
        {:ok, _} =
          XqliteNIF.execute(
            conn,
            "INSERT INTO projects (path, name, last_opened_at) VALUES (?1, ?2, ?3)",
            [project_path, name, last_opened_at]
          )
      end)

      assert :ok = Schema.normalize_timestamps(conn)

      {:ok, %{rows: project_rows}} =
        XqliteNIF.query(conn, "SELECT path, last_opened_at FROM projects ORDER BY path", [])

      by_path =
        Map.new(project_rows, fn [project_path, last_opened_at] ->
          {project_path, last_opened_at}
        end)

      assert by_path["/p-six"] == "2024-01-01T12:00:00.123Z"
      assert by_path["/p-whole"] == "2024-01-01T12:00:00.000Z"
      assert by_path["/p-normalized"] == "2024-01-01T12:00:00.123Z"
      assert by_path["/p-garbage"] == "not-a-date"
      assert by_path["/p-null"] == nil

      :ok = XqliteNIF.close(conn)
    end
  end

  describe "Codec.encode_datetime/1 fixed millisecond precision" do
    test "emits .000Z for whole seconds at millisecond precision" do
      assert Codec.encode_datetime(~U[2024-01-01 12:00:00.000Z]) ==
               "2024-01-01T12:00:00.000Z"
    end

    test "truncates microseconds to milliseconds" do
      assert Codec.encode_datetime(~U[2024-01-01 12:00:00.123456Z]) ==
               "2024-01-01T12:00:00.123Z"
    end

    test "passes second-precision datetimes through unchanged (no fraction)" do
      # DateTime.truncate/2 returns a datetime UNCHANGED when its precision is
      # coarser than the target (:millisecond = 3 > second-precision 0), so
      # to_iso8601/1 emits the 20-char no-fraction form. Production writers
      # all use DateTime.utc_now/0 (microsecond precision), so this only
      # affects sigil/decoded second-precision values; the
      # normalize_timestamps/1 migration repairs any such rows at Store init.
      assert Codec.encode_datetime(~U[2024-01-01 12:00:00Z]) == "2024-01-01T12:00:00Z"
    end

    test "nil stays nil" do
      assert Codec.encode_datetime(nil) == nil
    end
  end

  describe "Store.init/1 migration wiring" do
    test "normalizes pre-existing rows on startup", %{sqlite_path: path} do
      # Seed a DB with old-format timestamps via a raw connection, then start a
      # Store on it: init must run normalize_timestamps before serving reads.
      {:ok, conn} = Xqlite.open(path)
      :ok = Schema.create_tables(conn)
      :ok = Schema.migrate_schema(conn)

      {:ok, _} =
        XqliteNIF.execute(
          conn,
          "INSERT INTO tasks (id, status, started_at, finished_at) VALUES (?1, ?2, ?3, ?4)",
          ["init-1", "completed", "2024-01-01T12:00:00.123456Z", "2024-01-01T13:00:00Z"]
        )

      :ok = XqliteNIF.close(conn)

      # Unique name so the running production EvoGit.Store is untouched.
      name = :"store_schema_init_#{System.unique_integer([:positive])}"
      start_supervised({Store, data_dir: path, name: name})

      assert %TaskInfo{} = task = Store.get_task(name, "init-1")
      # 6-digit input was truncated to millisecond precision (value, precision).
      assert task.started_at.microsecond == {123_000, 3}
      # Whole-second input gained explicit millisecond precision.
      assert task.finished_at.microsecond == {0, 3}
    end
  end
end
