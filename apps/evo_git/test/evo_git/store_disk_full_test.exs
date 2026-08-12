defmodule EvoGit.StoreDiskFullTest do
  @moduledoc """
  Disk-full write-error handling in `EvoGit.Store` (and the TaskRegistry
  degradation path).

  ## Arm technique: `PRAGMA query_only`

  Tests make every Store write fail deterministically by setting
  `PRAGMA query_only = ON` on the Store's own SQLite connection. SQLite then
  rejects every INSERT/UPDATE/DELETE with `SQLITE_READONLY` (8) — one of the
  three disk-full-class codes the Store's write boundary converts to
  `{:error, :disk_full}` (see `EvoGit.Store.Errors`). Reads are unaffected,
  and `PRAGMA query_only = OFF` clears the condition so a retried write
  succeeds — exactly the "full disk is transient" recovery the boundary
  implements.

  Why not the alternatives?

  * **chmod is unreliable.** chmod 0444 on the DB file does NOT block WAL
    writes (SQLite writes the `-wal` sidecar through the already-open fd), and
    chmod 555 on the directory is bypassed when running as root — both
    non-deterministic in CI.
  * **A `RAISE(FAIL, 'database or disk is full')` trigger does NOT reach the
    disk-full classifier.** Empirically, SQLite reports trigger RAISEs as
    `SQLITE_CONSTRAINT_TRIGGER` (primary code 19), which xqlite classifies as
    `{:error, {:constraint_violation, :constraint_trigger, %{message: ...}}}`
    — a shape `EvoGit.Store.Errors.disk_full_error?/1` deliberately does NOT
    match (only `read_only_database` / `sqlite_failure` tuples are
    classified), so the write hits the historical MatchError crash instead of
    the graceful `{:error, :disk_full}` path.

  Accessing the Store's connection from the test process is safe: xqlite NIFs
  are mutex-guarded, so cross-process use is allowed (the Store's own heavy
  read offload relies on the same property), and the Store is idle between
  the test's synchronous calls.
  """

  use EvoGit.TaskRegistryCase, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Store
  alias EvoGit.TaskInfo

  describe "EvoGit.Store.Errors.disk_full_error?/1" do
    test "classifies disk-full-class xqlite error tuples" do
      # SQLITE_FULL (13) / SQLITE_IOERR (10) / SQLITE_READONLY (8) primary codes.
      assert Store.Errors.disk_full_error?({:error, {:sqlite_failure, 13, 13, nil}})
      assert Store.Errors.disk_full_error?({:error, {:sqlite_failure, 10, 10, nil}})
      assert Store.Errors.disk_full_error?({:error, {:sqlite_failure, 8, 8, nil}})

      # xqlite's special-cased read_only_database variant — this is the exact
      # shape produced by the `PRAGMA query_only` arm technique.
      assert Store.Errors.disk_full_error?({:error, {:read_only_database, 8, nil}})

      # Message-text fallback (case-insensitive downcased match) — synthetic
      # errors carry no distinguishing result code.
      assert Store.Errors.disk_full_error?(
               {:error, {:sqlite_failure, 1, 1, "database or disk is full"}}
             )

      assert Store.Errors.disk_full_error?(
               {:error, {:sqlite_failure, 1, 1, "DATABASE OR DISK IS FULL"}}
             )
    end

    test "rejects success and non-disk-full error shapes" do
      refute Store.Errors.disk_full_error?({:ok, %{}})
      # SQLITE_CONSTRAINT (19) — including trigger RAISEs (see moduledoc).
      refute Store.Errors.disk_full_error?({:error, {:sqlite_failure, 19, 19, nil}})
      # Unknown code with nil message — no message fallback available.
      refute Store.Errors.disk_full_error?({:error, {:sqlite_failure, 99, 99, nil}})
      refute Store.Errors.disk_full_error?({:error, :something_else})
      refute Store.Errors.disk_full_error?(:ok)
    end
  end

  describe "Store survives a disk-full-class write" do
    test "put_task returns {:error, :disk_full}, logs the DB path, and the Store keeps serving reads",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      task_id = "disk_full_#{unique}"
      task = disk_full_task(task_id)

      set_query_only(Store, "ON")

      log =
        capture_log(fn ->
          assert {:error, :disk_full} = Store.put_task(Store, task)
        end)

      # The actionable warning names the DB file so the user knows which
      # volume is full.
      assert log =~ "Store: DISK FULL"
      assert log =~ sqlite_path

      # The GenServer survived the failed write...
      assert Process.alive?(Process.whereis(Store))

      # ...and reads keep working (the failed row is simply absent).
      assert Store.get_task(Store, task_id) == nil
      assert Store.select_task_ids(Store) == []
    end

    test "a retried put_task succeeds after the disk-full condition clears" do
      unique = System.unique_integer([:positive])
      task_id = "disk_full_retry_#{unique}"
      task = disk_full_task(task_id)

      set_query_only(Store, "ON")

      capture_log(fn ->
        assert {:error, :disk_full} = Store.put_task(Store, task)
      end)

      set_query_only(Store, "OFF")

      # A full disk is transient — the same write succeeds once the
      # condition clears, without restarting the Store.
      assert :ok = Store.put_task(Store, task)
      assert %TaskInfo{id: ^task_id} = Store.get_task(Store, task_id)
    end
  end

  describe "TaskRegistry degradation on disk-full" do
    test "start_task continues in-memory when persistence fails" do
      unique = System.unique_integer([:positive])
      task_id = "disk_full_registry_#{unique}"

      set_query_only(Store, "ON")

      log =
        capture_log(fn ->
          assert {:ok, %TaskInfo{id: ^task_id}} =
                   GenServer.call(
                     EvoGit.TaskRegistry,
                     {:start_task, task_id, :genesis, [path: "/tmp/test"]}
                   )
        end)

      # Registry-side degradation warning (task runs in-memory, unpersisted).
      assert log =~ "continuing in-memory only"
      # The Store logged its own disk-full warning on the same write.
      assert log =~ "Store: DISK FULL"

      # The registry GenServer did not crash.
      assert Process.alive?(Process.whereis(EvoGit.TaskRegistry))

      # Reads still work; the unpersisted task is tracked in-memory only
      # (list_tasks is DB-backed, so the task is absent from it).
      assert TaskRegistry.list_tasks() == []

      state = :sys.get_state(EvoGit.TaskRegistry)
      assert Map.has_key?(state.task_refs, task_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp disk_full_task(id) do
    %TaskInfo{
      id: id,
      type: :genesis,
      status: :running,
      opts: [path: "/tmp/test"],
      started_at: DateTime.utc_now(),
      logs: []
    }
  end

  # Arms (or clears) the disk-full condition: `PRAGMA query_only = ON` makes
  # every write on the Store's connection fail with SQLITE_READONLY (8), which
  # the Store's write boundary classifies as `{:error, :disk_full}` (see
  # moduledoc for why this beats chmod and RAISE triggers).
  defp set_query_only(store, value) do
    %{conn: conn} = :sys.get_state(store)
    {:ok, _} = XqliteNIF.query(conn, "PRAGMA query_only = #{value}", [])
    :ok
  end
end
