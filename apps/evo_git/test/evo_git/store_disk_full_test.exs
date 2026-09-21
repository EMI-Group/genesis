defmodule EvoGit.StoreDiskFullTest do
  @moduledoc """
  Disk-full write-error handling in `EvoGit.Store` (and the TaskRegistry
  degradation path).

  ## Arm technique: `PRAGMA query_only` on the store's dynamic repo

  Tests make every Store write fail deterministically by setting
  `PRAGMA query_only = ON` on the Store's OWN SQLite connection. The Store is
  a thin facade over an UNNAMED dynamic `EvoGit.Repo` instance started with
  `pool_size: 1` (see `EvoGit.Store.Boot.start_dynamic/1`), so the single
  pooled connection this pragma flips IS the connection every store write
  uses. SQLite then rejects every INSERT/UPDATE/DELETE (and `BEGIN`) with
  `SQLITE_READONLY` (8) — one of the three disk-full-class codes the Store's
  write boundary converts to `{:error, :disk_full}` (see
  `EvoGit.Store.Errors`). Reads are unaffected, and `PRAGMA query_only = OFF`
  clears the condition so a retried write succeeds — exactly the "full disk
  is transient" recovery the boundary implements.

  The connection is reached through the sanctioned test seam
  `EvoGit.Store.__repo_pid__/1` (the facade's `@doc false` accessor for its
  dynamic repo instance) plus `XqliteEcto3.with_xqlite/2` (the adapter's
  supported raw-connection checkout). Accessing the pooled connection from
  the test process is safe: xqlite NIFs are mutex-guarded, so cross-process
  use is allowed, the pool serializes checkouts, and the Store is idle
  between the test's synchronous calls.

  ## The arm is one-shot for transactional writes — RE-ARM per write

  The `XqliteEcto3` adapter treats a read-only `BEGIN` failure as a
  `:disconnect`: the armed connection is torn down and the next checkout
  gets a FRESH (un-armed) connection. So `put_task` (ONE `:immediate`
  transaction) fails exactly ONCE per arming — the arm helper is re-invoked
  before every write the test wants to fail. Non-transactional writes
  (`Repo.update_all`/`delete_all` — `update_task_columns`, `delete_task`,
  `clear_tasks`, ...) fail as ordinary statement errors and the connection
  STAYS armed, but re-arming before each pinned write keeps every test
  uniform regardless of which failure shape the adapter picks. Each test
  also disarms (`OFF`) after its assertions so nothing armed ever outlives
  the test — belt and braces: the per-test Store from
  `EvoGit.TaskRegistryCase` is stopped by `start_supervised!` anyway.

  Why not the alternatives?

  * **chmod is unreliable.** chmod 0444 on the DB file does NOT block WAL
    writes (SQLite writes the `-wal` sidecar through the already-open fd),
    and chmod 555 on the directory is bypassed when running as root — both
    non-deterministic in CI.
  * **A `RAISE(FAIL, 'database or disk is full')` trigger does NOT reach the
    disk-full classifier.** Empirically, SQLite reports trigger RAISEs as
    `SQLITE_CONSTRAINT_TRIGGER` (primary code 19), which the adapter wraps
    as a constraint violation — a shape `EvoGit.Store.Errors` deliberately
    does NOT match (only `read_only_database` / disk-full-coded
    `sqlite_failure` shapes are classified), so the write crashes instead
    of taking the graceful `{:error, :disk_full}` path.
  """

  # `async: true` is safe: EvoGit.TaskRegistryCase starts UNIQUELY-NAMED isolated
  # `EvoGit.Store`/`EvoGit.TaskRegistry` instances per test, so the `PRAGMA
  # query_only` arm below only ever touches this test's OWN dynamic repo —
  # no BEAM-global is mutated.
  use EvoGit.TaskRegistryCase, async: true

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
      # NIF shape produced by the `PRAGMA query_only` arm technique.
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
         %{store: store, sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      task_id = "disk_full_#{unique}"
      task = disk_full_task(task_id)

      set_query_only(store, "ON")

      # Reads still work WHILE the store's connection is armed — the
      # read-only connection serves SELECTs normally.
      assert Store.get_task(store, task_id) == nil
      assert Store.select_task_ids(store) == []
      assert Store.count_tasks(store) == 0

      log =
        capture_log(fn ->
          assert {:error, :disk_full} = Store.put_task(store, task)
        end)

      # The actionable warning names the DB file so the user knows which
      # volume is full.
      assert log =~ "Store: DISK FULL"
      assert log =~ sqlite_path

      # The GenServer survived the failed write...
      assert Process.alive?(Process.whereis(store))

      # ...and reads keep working (the failed row is simply absent).
      assert Store.get_task(store, task_id) == nil
      assert Store.select_task_ids(store) == []

      set_query_only(store, "OFF")
    end

    test "every protected write fn converts the disk-full class, and the Store stays alive",
         %{store: store} do
      unique = System.unique_integer([:positive])
      task_id = "disk_full_writes_#{unique}"
      :ok = Store.put_task(store, disk_full_task(task_id))

      # Each protected write fn is armed FRESH (the transactional ones tear
      # down the armed connection on failure — see moduledoc) and must
      # return {:error, :disk_full} instead of crashing the GenServer.
      set_query_only(store, "ON")
      assert {:error, :disk_full} = Store.put_task(store, disk_full_task(task_id))

      set_query_only(store, "ON")
      assert {:error, :disk_full} = Store.delete_task(store, task_id)

      set_query_only(store, "ON")
      assert {:error, :disk_full} = Store.delete_tasks(store, [task_id])

      set_query_only(store, "ON")
      assert {:error, :disk_full} = Store.clear_tasks(store)

      set_query_only(store, "ON")
      assert {:error, :disk_full} = Store.update_lease_expires_at(store, task_id, 123)

      set_query_only(store, "ON")
      assert {:error, :disk_full} = Store.update_task_columns(store, task_id, status: :failed)

      set_query_only(store, "ON")
      assert {:error, :disk_full} = Store.delete_project(store, "/no/such/project")

      # put_project protects itself INSIDE Operations.Projects (not wrapped
      # by the facade's write boundary) — same contract, same class.
      set_query_only(store, "ON")

      assert {:error, :disk_full} =
               Store.put_project(store, %EvoGit.RecentProject{
                 path: "/tmp/proj",
                 name: "proj",
                 last_opened_at: DateTime.utc_now()
               })

      # The GenServer survived every failed write...
      assert Process.alive?(Process.whereis(store))

      # ...and reads keep working; nothing was mutated.
      assert %TaskInfo{id: ^task_id} = Store.get_task(store, task_id)
      assert Store.count_tasks(store) == 1

      set_query_only(store, "OFF")
    end

    test "a retried put_task succeeds after the disk-full condition clears", %{store: store} do
      unique = System.unique_integer([:positive])
      task_id = "disk_full_retry_#{unique}"
      task = disk_full_task(task_id)

      set_query_only(store, "ON")

      capture_log(fn ->
        assert {:error, :disk_full} = Store.put_task(store, task)
      end)

      set_query_only(store, "OFF")

      # A full disk is transient — the same write succeeds once the
      # condition clears, without restarting the Store.
      assert :ok = Store.put_task(store, task)
      assert %TaskInfo{id: ^task_id} = Store.get_task(store, task_id)
    end
  end

  describe "TaskRegistry degradation on disk-full" do
    test "start_task continues in-memory when persistence fails",
         %{store: store, registry: registry} do
      unique = System.unique_integer([:positive])
      task_id = "disk_full_registry_#{unique}"

      set_query_only(store, "ON")

      log =
        capture_log(fn ->
          assert {:ok, %TaskInfo{id: ^task_id}} =
                   GenServer.call(
                     registry,
                     {:start_task, task_id, :genesis, [path: "/tmp/test"]}
                   )
        end)

      # Registry-side degradation warning (task runs in-memory, unpersisted).
      assert log =~ "continuing in-memory only"
      # The Store logged its own disk-full warning on the same write.
      assert log =~ "Store: DISK FULL"

      # The registry GenServer did not crash.
      assert Process.alive?(Process.whereis(registry))

      # Reads still work; the unpersisted task is tracked in-memory only
      # (list_tasks is DB-backed, so the task is absent from it).
      assert TaskRegistry.list_tasks() == []

      state = :sys.get_state(registry)
      assert Map.has_key?(state.task_refs, task_id)

      set_query_only(store, "OFF")
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
  # every write on the store's connection fail with SQLITE_READONLY (8), which
  # the Store's write boundary classifies as `{:error, :disk_full}` (see
  # moduledoc for why this beats chmod and RAISE triggers, and why the arm
  # must be re-applied before each transactional write).
  #
  # Seam: the facade's `__repo_pid__/1` test accessor returns the store's
  # UNNAMED dynamic `EvoGit.Repo` instance; `XqliteEcto3.with_xqlite/2` is the
  # adapter's supported raw-connection checkout. The repo's `pool_size: 1`
  # means the flipped connection is THE connection the store writes through.
  defp set_query_only(store, value) do
    repo_pid = Store.__repo_pid__(store)

    :ok =
      XqliteEcto3.with_xqlite(repo_pid, fn conn ->
        {:ok, _} = XqliteNIF.query(conn, "PRAGMA query_only = #{value}", [])
        :ok
      end)
  end
end
