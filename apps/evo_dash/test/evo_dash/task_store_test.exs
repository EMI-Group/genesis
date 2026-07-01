defmodule EvoDash.TaskStoreTest do
  use ExUnit.Case, async: false

  alias EvoDash.TaskStore
  alias EvoDash.TaskRegistry.TaskInfo

  # Terminate production children (TaskRegistry depends on TaskStore) and start
  # an isolated TaskStore with a unique tmp SQLite path, mirroring the setup
  # pattern in task_registry_test.exs. `async: false` because we mutate the
  # shared production supervision tree.
  setup do
    Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
    Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.TaskStore)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_store_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({TaskStore, data_dir: sqlite_path})

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.TaskStore)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
    end)

    {:ok, %{store: TaskStore, sqlite_path: sqlite_path, root: root}}
  end

  describe "serialization round-trip of structs containing DateTimes" do
    test "DateTime structs survive a put/get round-trip intact" do
      task = %TaskInfo{
        id: "rt-1",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        started_at: ~U[2026-06-26 07:19:44Z],
        finished_at: ~U[2026-06-26 08:00:00Z],
        logs: [],
        result: nil
      }

      :ok = TaskStore.put(TaskStore, {:task, "rt-1"}, task)

      fetched = TaskStore.get(TaskStore, {:task, "rt-1"})

      assert %TaskInfo{} = fetched
      assert fetched.started_at.__struct__ == DateTime
      # The calendar must be a real atom, NOT the stringified
      # "Elixir.Calendar.ISO" that the legacy corruption produced.
      assert fetched.started_at.calendar == Calendar.ISO
      refute fetched.started_at.calendar == "Elixir.Calendar.ISO"

      # The critical acceptance criterion: DateTime functions work without
      # raising (they crash on stringified calendar atoms).
      assert DateTime.compare(fetched.started_at, fetched.finished_at) == :lt
    end
  end

  describe "repair of corrupted (stringified module) data" do
    # This simulates the legacy scrub_db corruption by writing a raw blob
    # DIRECTLY into the SQLite `tasks` table (bypassing the store's clean
    # term_to_binary), then reading it back through the store's normal API to
    # confirm the decode_blob/1 chokepoint repairs the stringified atoms.

    @corrupted_dt %{
      __struct__: "Elixir.DateTime",
      calendar: "Elixir.Calendar.ISO",
      day: 26,
      hour: 7,
      microsecond: {0, 6},
      minute: 19,
      month: 6,
      second: 44,
      std_offset: 0,
      time_zone: "Etc/UTC",
      utc_offset: 0,
      year: 2026,
      zone_abbr: "UTC"
    }

    test "restores stringified calendar and __struct__ to real atoms on read",
         %{sqlite_path: sqlite_path} do
      corrupted_task = %TaskInfo{
        id: "corrupt-1",
        type: :genesis,
        status: :completed,
        started_at: @corrupted_dt,
        finished_at: nil,
        logs: [],
        result: nil
      }

      # Serialize the corrupted term and write it DIRECTLY into the tasks table,
      # bypassing TaskStore.put (which would write clean data). Use the same
      # xqlite NIF the store itself uses, on a second connection to the same db.
      blob = :erlang.term_to_binary(corrupted_task)

      {:ok, conn} = Xqlite.open(sqlite_path)

      {:ok, _} =
        XqliteNIF.execute(conn, "INSERT INTO tasks (id, data) VALUES (?1, ?2)", [
          "corrupt-1",
          blob
        ])

      :ok = XqliteNIF.close(conn)

      # Now read it back through the STORE's normal API — the decode_blob/1
      # chokepoint must repair the stringified atoms.
      task = TaskStore.get(TaskStore, {:task, "corrupt-1"})

      assert %TaskInfo{} = task
      assert %DateTime{} = task.started_at
      assert task.started_at.__struct__ == DateTime
      assert task.started_at.calendar == Calendar.ISO
      refute task.started_at.calendar == "Elixir.Calendar.ISO"

      # The critical acceptance criterion: DateTime functions no longer crash.
      assert DateTime.compare(task.started_at, ~U[2026-06-26 07:19:44Z]) == :eq
    end

    test "repaired task appears in safe_select_all with a proper DateTime",
         %{sqlite_path: sqlite_path} do
      corrupted_dt = %{
        __struct__: "Elixir.DateTime",
        calendar: "Elixir.Calendar.ISO",
        day: 1,
        hour: 0,
        microsecond: {0, 0},
        minute: 0,
        month: 1,
        second: 0,
        std_offset: 0,
        time_zone: "Etc/UTC",
        utc_offset: 0,
        year: 2026,
        zone_abbr: "UTC"
      }

      corrupted_task = %TaskInfo{
        id: "corrupt-2",
        type: :evolve,
        status: :failed,
        started_at: corrupted_dt,
        finished_at: nil,
        logs: [],
        result: nil
      }

      blob = :erlang.term_to_binary(corrupted_task)

      {:ok, conn} = Xqlite.open(sqlite_path)

      {:ok, _} =
        XqliteNIF.execute(conn, "INSERT INTO tasks (id, data) VALUES (?1, ?2)", [
          "corrupt-2",
          blob
        ])

      :ok = XqliteNIF.close(conn)

      entries = TaskStore.safe_select_all(TaskStore)

      {{:task, "corrupt-2"}, repaired} =
        Enum.find(entries, fn {key, _} -> key == {:task, "corrupt-2"} end)

      assert %TaskInfo{} = repaired
      assert %DateTime{} = repaired.started_at
      assert repaired.started_at.calendar == Calendar.ISO
    end
  end

  describe "security — no arbitrary atom creation" do
    test "stringified non-existent module stays a string (no atom created)" do
      # An "Elixir." string that is NOT a real loaded module must NOT be
      # converted to an atom. String.to_existing_atom/1 raises ArgumentError,
      # and the repair leaves the string untouched.
      map_with_fake = %{some_key: "Elixir.Nonexistent.Module.Fake"}
      :ok = TaskStore.put(TaskStore, {:task, "fake-1"}, map_with_fake)

      result = TaskStore.get(TaskStore, {:task, "fake-1"})

      # Must remain a binary string — NOT converted to an atom.
      assert result.some_key == "Elixir.Nonexistent.Module.Fake"
      refute is_atom(result.some_key)
    end

    test "non-Elixir-prefixed strings are never touched" do
      :ok = TaskStore.put(TaskStore, {:task, "str-1"}, %{repo_id: "my_foreign_repo"})

      result = TaskStore.get(TaskStore, {:task, "str-1"})

      assert result.repo_id == "my_foreign_repo"
      refute is_atom(result.repo_id)
    end
  end
end
