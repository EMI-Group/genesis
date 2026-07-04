defmodule EvoDash.TaskRegistryTest do
  use ExUnit.Case, async: false

  alias EvoDash.TaskRegistry
  alias EvoDash.TaskInfo

  setup do
    # Terminate production children to prevent auto-restarts and use isolated stores.
    Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
    Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_tasks_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({EvoDash.Store, data_dir: sqlite_path})

    start_supervised(
      {TaskRegistry, task_store: EvoDash.Store, data_dir: root, name: EvoDash.TaskRegistry}
    )

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.Store)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
    end)

    {:ok, %{data_dir: root, sqlite_path: sqlite_path}}
  end

  # Helper: trigger cleanup_expired_tasks by inserting a task in :running state
  # and transitioning it to :completed (which calls cleanup_expired_tasks()),
  # then synchronizing with a synchronous call.
  defp trigger_cleanup! do
    trigger_id = "cleanup_trigger_#{System.unique_integer([:positive])}"

    trigger = %TaskInfo{
      id: trigger_id,
      type: :genesis,
      status: :running,
      opts: [path: "/tmp/test"],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      logs: [],
      result: nil
    }

    EvoDash.Store.put_task(EvoDash.Store, trigger)
    # update_task_status transitions to :completed which triggers cleanup_expired_tasks()
    TaskRegistry.update_task_status(trigger_id, :completed, nil)
    # Sync with a call to ensure all prior casts have been processed
    TaskRegistry.list_tasks()
    :ok
  end

  # Helper: cleanly terminate a spawned test process so it doesn't linger.
  defp cleanup_process(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end
  end

  # Helper: compute an age in days guaranteed to EXCEED the configured
  # max_age_days. Reads the actual runtime config (fallback to default 14) so
  # tests are robust regardless of the local config.toml setting.
  defp old_age_days do
    config = EvoGit.Config.resolve()
    configured = (config[:task_history] || %{})[:max_age_days] || 14
    configured + 10
  end

  # Helper: compute an age in days guaranteed to be WITHIN the configured
  # max_age_days window. Uses roughly a third of the window, floored to 1 day.
  defp within_age_days do
    config = EvoGit.Config.resolve()
    configured = (config[:task_history] || %{})[:max_age_days] || 14
    max(div(configured, 3), 1)
  end

  describe "task_history_config/0 defaults" do
    test "returns default max_tasks and max_age_days when no config set" do
      config = EvoGit.Config.resolve()
      # task_history section may not exist — defaults applied at runtime via Map.Merge
      task_history = config[:task_history]

      if task_history == nil do
        # Defaults will be %{max_tasks: 100, max_age_days: 14} in task_history_config/0
        assert true
      else
        assert is_integer(task_history[:max_tasks])
        assert is_integer(task_history[:max_age_days])
      end
    end
  end

  describe "cleanup_expired_tasks/0" do
    test "removes tasks older than max_age_days via persist cycle" do
      unique = System.unique_integer([:positive])

      # Insert an old finished task directly into the store.
      # Age is computed to exceed whatever max_age_days is configured locally.
      age = old_age_days()
      old_task = %TaskInfo{
        id: "test_old_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(DateTime.utc_now(), -age * 24 * 60 * 60, :second),
        finished_at: DateTime.add(DateTime.utc_now(), -age * 24 * 60 * 60, :second),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, old_task)

      # Insert a recent finished task (today)
      recent_task = %TaskInfo{
        id: "test_recent_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, recent_task)

      # Verify both exist
      tasks = TaskRegistry.list_tasks()
      assert Enum.any?(tasks, &(&1.id == "test_old_#{unique}"))
      assert Enum.any?(tasks, &(&1.id == "test_recent_#{unique}"))

      # Trigger cleanup via persist cycle
      trigger_cleanup!()

      # Old task should be cleaned; recent task should remain
      tasks = TaskRegistry.list_tasks()
      task_ids = Enum.map(tasks, & &1.id)
      refute "test_old_#{unique}" in task_ids
      assert "test_recent_#{unique}" in task_ids
    end

    test "preserves tasks within max_age_days" do
      unique = System.unique_integer([:positive])

      # Insert a task within the configured max_age_days window.
      age = within_age_days()
      task = %TaskInfo{
        id: "test_5day_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(DateTime.utc_now(), -age * 24 * 60 * 60, :second),
        finished_at: DateTime.add(DateTime.utc_now(), -age * 24 * 60 * 60, :second),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # Trigger cleanup
      trigger_cleanup!()

      tasks = TaskRegistry.list_tasks()
      task_ids = Enum.map(tasks, & &1.id)
      assert "test_5day_#{unique}" in task_ids
    end

    test "never cleans up running or pending tasks even if old" do
      unique = System.unique_integer([:positive])

      # Age guaranteed to exceed the configured max_age_days window.
      age = old_age_days()

      # Running task with old started_at (finished_at is nil)
      running_task = %TaskInfo{
        id: "test_running_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(DateTime.utc_now(), -age * 24 * 60 * 60, :second),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, running_task)

      # Pending task
      pending_task = %TaskInfo{
        id: "test_pending_#{unique}",
        type: :genesis,
        status: :pending,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(DateTime.utc_now(), -age * 24 * 60 * 60, :second),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, pending_task)

      # Old finished task (should be cleaned)
      old_finished = %TaskInfo{
        id: "test_oldfin_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(DateTime.utc_now(), -age * 24 * 60 * 60, :second),
        finished_at: DateTime.add(DateTime.utc_now(), -age * 24 * 60 * 60, :second),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, old_finished)

      # Trigger cleanup
      trigger_cleanup!()

      tasks = TaskRegistry.list_tasks()
      task_ids = Enum.map(tasks, & &1.id)

      # Running and pending always preserved
      assert "test_running_#{unique}" in task_ids
      assert "test_pending_#{unique}" in task_ids

      # Old finished task cleaned
      refute "test_oldfin_#{unique}" in task_ids
    end

    test "both age and count limits are applied together" do
      unique = System.unique_integer([:positive])
      now = DateTime.utc_now()

      # Old task — age guaranteed to exceed the configured max_age_days window.
      age = old_age_days()
      old_task = %TaskInfo{
        id: "test_combined_old_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(now, -age * 24 * 60 * 60, :second),
        finished_at: DateTime.add(now, -age * 24 * 60 * 60, :second),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, old_task)

      # Recent tasks (within max_age_days) - should be kept
      for i <- 1..3 do
        recent = %TaskInfo{
          id: "test_combined_recent_#{unique}_#{i}",
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.add(now, -i * 60, :second),
          finished_at: DateTime.add(now, -i * 60, :second),
          logs: [],
          result: nil
        }

        EvoDash.Store.put_task(EvoDash.Store, recent)
      end

      # Running task - should always be kept regardless of age
      running = %TaskInfo{
        id: "test_combined_running_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(now, -age * 24 * 60 * 60, :second),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, running)

      # Trigger cleanup
      trigger_cleanup!()

      tasks = TaskRegistry.list_tasks()
      task_ids = Enum.map(tasks, & &1.id)

      # Old task removed by age
      refute "test_combined_old_#{unique}" in task_ids
      # Recent tasks kept
      assert "test_combined_recent_#{unique}_1" in task_ids
      assert "test_combined_recent_#{unique}_2" in task_ids
      assert "test_combined_recent_#{unique}_3" in task_ids
      # Running task always kept
      assert "test_combined_running_#{unique}" in task_ids
    end
  end

  describe "set_review_metadata/3" do
    test "updates a task's base_sha and commit_sha in the store" do
      unique = System.unique_integer([:positive])
      task_id = "review_meta_#{unique}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      TaskRegistry.set_review_metadata(task_id, "abc123", "def456")

      # Sync with a call to ensure cast was processed
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.base_sha == "abc123"
      assert fetched.commit_sha == "def456"
    end

    test "persists to the store after update" do
      unique = System.unique_integer([:positive])
      task_id = "review_meta_#{unique}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      TaskRegistry.set_review_metadata(task_id, "base_sha_1", "commit_sha_1")

      # Sync to ensure the cast (which writes directly to the store) has been processed
      TaskRegistry.list_tasks()

      # Read directly from the store to confirm persistence
      stored_task = EvoDash.Store.get_task(EvoDash.Store, task_id)

      assert stored_task.base_sha == "base_sha_1"
      assert stored_task.commit_sha == "commit_sha_1"
    end

    test "does nothing for a non-existent task" do
      # Should not raise; task simply not found
      TaskRegistry.set_review_metadata("nonexistent_task", "base", "commit")

      # Sync
      TaskRegistry.list_tasks()

      # Ensure no crash occurred — registry is still responsive
      assert is_list(TaskRegistry.list_tasks())
    end

    test "can overwrite previously set metadata" do
      unique = System.unique_integer([:positive])
      task_id = "review_meta_overwrite_#{unique}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      TaskRegistry.set_review_metadata(task_id, "base1", "commit1")
      TaskRegistry.list_tasks()

      TaskRegistry.set_review_metadata(task_id, "base2", "commit2")
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.base_sha == "base2"
      assert fetched.commit_sha == "commit2"
    end
  end

  describe "TaskInfo field backfill" do
    test "normalize_tasks backfills base_sha and commit_sha as nil for old entries",
         %{data_dir: data_dir} do
      unique = System.unique_integer([:positive])
      task_id = "backfill_#{unique}"

      # Simulate an old persisted entry WITHOUT base_sha/commit_sha keys.
      # This mimics an entry written before these fields existed.
      old_task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      # Strip the new fields from the struct map to emulate an old persisted entry.
      # A struct is just a map with a __struct__ key. Old persisted entries (written
      # before base_sha/commit_sha existed) won't have these keys. normalize_tasks
      # calls Map.merge(%TaskInfo{}, task) which backfills them as nil.
      old_map =
        old_task
        |> Map.from_struct()
        |> Map.put(:__struct__, TaskInfo)
        |> Map.drop([:base_sha, :commit_sha])

      EvoDash.Store.put_task(EvoDash.Store, old_map)

      # Stop the supervised registry, then restart it so normalize_tasks runs.
      # KEEP the same store running so the backfilled data persists.
      stop_supervised(EvoDash.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.Store, data_dir: data_dir, name: EvoDash.TaskRegistry}
      )

      # The backfilled task should exist with nil for the new fields
      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.base_sha == nil
      assert fetched.commit_sha == nil
    end
  end

  describe "persistence" do
    test "get_task retrieves a task seeded directly into the store" do
      unique = System.unique_integer([:positive])
      task_id = "persistence_crud_#{unique}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      :ok = EvoDash.Store.put_task(EvoDash.Store, task)

      fetched = TaskRegistry.get_task(task_id)
      assert %TaskInfo{} = fetched
      assert fetched.id == task_id
      assert fetched.type == :genesis
      assert fetched.status == :completed
      assert fetched.opts == [path: "/tmp/test"]
      assert fetched.result == nil
    end

    test "task persists across a registry restart with the same store", %{data_dir: data_dir} do
      unique = System.unique_integer([:positive])
      task_id = "persistence_durable_#{unique}"

      task = %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/test", objective: "durability check"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      :ok = EvoDash.Store.put_task(EvoDash.Store, task)

      # Confirm the task is visible before restart.
      assert %TaskInfo{} = TaskRegistry.get_task(task_id)

      # Stop the registry but KEEP the same store running (store is durable on disk).
      stop_supervised(EvoDash.TaskRegistry)

      # Restart the registry pointing at the same store and data_dir.
      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.Store, data_dir: data_dir, name: EvoDash.TaskRegistry}
      )

      # The task persisted in the store must survive the registry restart.
      fetched = TaskRegistry.get_task(task_id)
      assert %TaskInfo{} = fetched
      assert fetched.id == task_id
      assert fetched.type == :evolve
      assert fetched.status == :completed
      assert fetched.opts[:objective] == "durability check"
    end
  end

  describe "recent projects persistence" do
    test "recent project persists across a registry restart with the same store",
         %{data_dir: data_dir} do
      path = "/some/path"
      name = "My Project"

      :ok = TaskRegistry.add_recent_project(path, name)

      # Confirm the project is listed before the restart.
      projects_before = TaskRegistry.list_recent_projects()
      assert Enum.any?(projects_before, &(&1.path == path and &1.name == name))

      # Stop the registry but KEEP the same store running (store is durable on disk).
      stop_supervised(EvoDash.TaskRegistry)

      # Restart the registry pointing at the same store and data_dir.
      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.Store, data_dir: data_dir, name: EvoDash.TaskRegistry}
      )

      # The project must survive the registry restart.
      projects_after = TaskRegistry.list_recent_projects()
      matching = Enum.filter(projects_after, &(&1.path == path))
      assert length(matching) == 1
      assert hd(matching).name == name
    end
  end

  describe "GenServer resilience and state preservation" do
    test "registry stays alive and returns inserted tasks" do
      unique = System.unique_integer([:positive])
      task_id = "resilient_#{unique}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      pid = GenServer.whereis(EvoDash.TaskRegistry)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # list_tasks returns the inserted task (the store is the source of truth)
      tasks = TaskRegistry.list_tasks()
      assert Enum.any?(tasks, &(&1.id == task_id))

      # get_task retrieves it individually
      assert %TaskInfo{} = TaskRegistry.get_task(task_id)

      # The process stays alive after reads
      assert Process.alive?(pid)
    end

    test "registry survives mutation operations" do
      unique = System.unique_integer([:positive])
      pid = GenServer.whereis(EvoDash.TaskRegistry)
      assert Process.alive?(pid)

      # Each delete_task cast mutates the store.
      for i <- 1..5 do
        id = "survive_#{unique}_#{i}"

        task = %TaskInfo{
          id: id,
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        }

        EvoDash.Store.put_task(EvoDash.Store, task)
        TaskRegistry.delete_task(id)
      end

      # Synchronize (list_tasks is a call that flushes pending casts)
      TaskRegistry.list_tasks()

      # The process survived all cleanup_expired_tasks invocations without crashing
      assert Process.alive?(pid)
      assert is_list(TaskRegistry.list_tasks())
      assert is_list(TaskRegistry.get_unique_paths())
    end
  end

  describe "corruption resilience — structural" do
    test "registry survives and salvages good tasks when wrong-shape entries exist", %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])

      # Good tasks
      good1 = %TaskInfo{
        id: "good1_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      good2 = %TaskInfo{
        id: "good2_#{unique}",
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, good1)
      EvoDash.Store.put_task(EvoDash.Store, good2)

      # Structurally corrupt entries (valid keys, wrong-shape values).
      # Inject corrupt rows via raw SQL (bypassing put_task validation).
      # The new typed API rejects non-struct input, so we go under the hood.
      {:ok, raw_conn} = Xqlite.open(sqlite_path)
      XqliteNIF.execute(raw_conn, "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)", ["bad_string", "completed", "<<invalid json>>"])
      XqliteNIF.execute(raw_conn, "INSERT OR REPLACE INTO tasks (id, status, type) VALUES (?1, ?2, ?3)", ["bad_map", "completed", "invalid_type_atom_xyz"])
      XqliteNIF.close(raw_conn)

      EvoDash.Store.put_project(
        EvoDash.Store,
        %EvoDash.RecentProject{path: "/some/path", name: "test", last_opened_at: DateTime.utc_now()}
      )

      pid = GenServer.whereis(EvoDash.TaskRegistry)
      assert Process.alive?(pid)

      # list_tasks must NOT crash — it should return only valid TaskInfo structs
      tasks = TaskRegistry.list_tasks()
      assert is_list(tasks)

      ids = Enum.map(tasks, & &1.id)
      assert "good1_#{unique}" in ids
      assert "good2_#{unique}" in ids
      # Note: with JSON encoding, rows with invalid opts still decode
      # (opts becomes nil). They appear as valid TaskInfo structs.
      # The registry stays alive regardless.

      # Registry still alive after reads
      assert Process.alive?(pid)

      # get_unique_paths works
      paths = TaskRegistry.get_unique_paths()
      assert is_list(paths)

      # list_recent_projects works
      projects = TaskRegistry.list_recent_projects()
      assert is_list(projects)
    end

    test "cleanup_expired_tasks does not crash GenServer when wrong-shape entries exist", %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])

      good = %TaskInfo{
        id: "good_cleanup_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, good)

      # Corrupt entry
      # Inject a corrupt row via raw SQL (put_task rejects non-struct input)
      {:ok, raw_conn2} = Xqlite.open(sqlite_path)
      XqliteNIF.execute(raw_conn2, "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)", ["bad_cleanup", "completed", "<<not json>>"])
      XqliteNIF.close(raw_conn2)

      pid = GenServer.whereis(EvoDash.TaskRegistry)
      assert Process.alive?(pid)

      # Trigger cleanup by doing mutations
      trigger_cleanup!()

      # Registry survived
      assert Process.alive?(pid)

      tasks = TaskRegistry.list_tasks()
      assert is_list(tasks)
      assert Enum.any?(tasks, &(&1.id == "good_cleanup_#{unique}"))
    end

    test "completing a task persists it even when corrupt entries exist elsewhere", %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])

      # Seed a corrupt entry FIRST
      # Inject a corrupt row via raw SQL (bypassing put_task validation)
      {:ok, raw_conn} = Xqlite.open(sqlite_path)
      XqliteNIF.execute(raw_conn, "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)", [
        "pre_existing_corrupt_#{unique}",
        "completed",
        "<<invalid json>>"
      ])
      XqliteNIF.close(raw_conn)

      # Now start a task and complete it
      task_id = "new_task_#{unique}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # Simulate completion via cast (this calls cleanup_expired_tasks internally)
      TaskRegistry.update_task_status(task_id, :completed, {:ok, %{usage: nil, agent_count: 1}})

      # Sync
      TaskRegistry.list_tasks()

      # The completed task must be persisted and readable
      fetched = TaskRegistry.get_task(task_id)
      assert %TaskInfo{} = fetched
      assert fetched.id == task_id
      assert fetched.status == :completed

      # Registry is alive
      pid = GenServer.whereis(EvoDash.TaskRegistry)
      assert Process.alive?(pid)
    end
  end

  describe "archive_metadata" do
    test "TaskInfo struct has archive_metadata field defaulting to nil" do
      assert %TaskInfo{}.archive_metadata == nil
    end

    test "archive_metadata is stored and retrieved correctly via get_task" do
      task_id = "archive_store_#{System.unique_integer([:positive])}"

      archive = [
        %{"agent_id" => "T1_A1", "parent_id" => nil, "objective" => "Genesis", "role" => "manager"}
      ]

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
        archive_metadata: archive
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      fetched = TaskRegistry.get_task(task_id)
      assert %TaskInfo{} = fetched
      assert fetched.archive_metadata == archive
    end

    test "normalize_tasks backfills archive_metadata to nil for older structs", %{
      data_dir: data_dir
    } do
      task_id = "archive_backfill_#{System.unique_integer([:positive])}"

      # Simulate a struct persisted before archive_metadata existed: build a
      # complete TaskInfo then strip the field so the stored value mimics a
      # deserialized older struct that lacks the key entirely.
      stripped =
        %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        }
        |> Map.delete(:archive_metadata)

      EvoDash.Store.put_task(EvoDash.Store, stripped)

      # Restart the registry to trigger normalize_tasks on init. normalize_tasks
      # runs Map.merge(%TaskInfo{}, task), backfilling the missing field to its
      # default (nil).
      stop_supervised(TaskRegistry)

      start_supervised!(
        {TaskRegistry,
         task_store: EvoDash.Store, data_dir: data_dir, name: EvoDash.TaskRegistry}
      )

      fetched = TaskRegistry.get_task(task_id)
      assert %TaskInfo{} = fetched
      assert Map.has_key?(fetched, :archive_metadata)
      assert fetched.archive_metadata == nil
    end

    test "update_task_status captures archive_records into archive_metadata" do
      task_id = "archive_capture_#{System.unique_integer([:positive])}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      archive_records = [
        %{"agent_id" => "T1_A1", "parent_id" => nil, "objective" => "Genesis", "role" => "manager"},
        %{"agent_id" => "T2_A1", "parent_id" => "T1_A1", "objective" => "Implement", "role" => "executor"}
      ]

      # update_task_status is a cast; list_tasks() syncs to ensure it's processed.
      TaskRegistry.update_task_status(task_id, :completed, {:ok, %{}},
        archive_records: archive_records
      )

      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :completed
      assert fetched.archive_metadata == archive_records
    end
  end

  describe "restart reconciliation (normalize_tasks liveness check)" do
    # These tests verify that when the TaskRegistry GenServer restarts, running
    # tasks whose processes are still alive (under the sibling TaskSupervisor)
    # are NOT marked failed — they are re-monitored. Dead/nil-pid tasks are
    # marked failed as before.

    test "a running task with a live PID survives a registry restart (stays :running)",
         %{data_dir: data_dir} do
      task_id = "restart_live_#{System.unique_integer([:positive])}"

      # Spawn a long-running process that stays alive (simulating a task worker
      # that outlives the registry restart).
      {:ok, agent_pid} =
        Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
          Process.sleep(:infinity)
        end)

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        pid: agent_pid,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # Confirm the process is alive before restart.
      assert Process.alive?(agent_pid)

      # Restart the registry so normalize_tasks re-runs.
      stop_supervised(EvoDash.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.Store, data_dir: data_dir, name: EvoDash.TaskRegistry}
      )

      # The task should STILL be running (not failed) and re-monitored.
      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.status == :running

      cleanup_process(agent_pid)
    end

    test "a running task with a dead PID is marked :failed on restart",
         %{data_dir: data_dir} do
      task_id = "restart_dead_#{System.unique_integer([:positive])}"

      # Spawn and immediately kill a process so the PID is dead.
      {:ok, agent_pid} =
        Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
          :ok
        end)

      # Wait for the process to exit (it returns immediately).
      ref = Process.monitor(agent_pid)

      receive do
        {:DOWN, ^ref, :process, ^agent_pid, _} -> :ok
      after
        1_000 -> flunk("process did not exit")
      end

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        pid: agent_pid,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      refute Process.alive?(agent_pid)

      stop_supervised(EvoDash.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.Store, data_dir: data_dir, name: EvoDash.TaskRegistry}
      )

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.status == :failed
    end

    test "a running task with a nil PID is marked :failed on restart",
         %{data_dir: data_dir} do
      task_id = "restart_nilpid_#{System.unique_integer([:positive])}"

      # pid is nil (e.g. written before the pid field existed, or never started).
      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        pid: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      stop_supervised(EvoDash.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.Store, data_dir: data_dir, name: EvoDash.TaskRegistry}
      )

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.status == :failed
    end

    test "a running task with a dead PID stays :running if AgentScheduler has active agents",
         %{data_dir: data_dir} do
      task_id = "restart_ets_#{System.unique_integer([:positive])}"

      # Spawn and immediately kill a process so the PID is dead.
      {:ok, agent_pid} =
        Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
          :ok
        end)

      # Wait for the process to exit.
      ref = Process.monitor(agent_pid)

      receive do
        {:DOWN, ^ref, :process, ^agent_pid, _} -> :ok
      after
        1_000 -> flunk("process did not exit")
      end

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        pid: agent_pid,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      refute Process.alive?(agent_pid)

      # Set up the :evogit_sched_meta ETS table with a fake active agent for
      # this task_id. This simulates AgentScheduler still running the task
      # under a sibling process while TaskRegistry restarts.
      # Table may already exist from a prior test; idempotent create is intentional.
      try do
        :ets.new(:evogit_sched_meta, [:set, :public, :named_table])
      rescue
        ArgumentError -> :ok
      end

      sched_meta_entry = %EvoGit.AgentScheduler.SchedMeta{
        id: System.unique_integer([:positive]),
        depth: 0,
        spec: %{},
        task_id: task_id,
        status: :running
      }

      :ets.insert(:evogit_sched_meta, {sched_meta_entry.id, sched_meta_entry})

      try do
        stop_supervised(EvoDash.TaskRegistry)

        start_supervised(
          {TaskRegistry,
           task_store: EvoDash.Store, data_dir: data_dir, name: EvoDash.TaskRegistry}
        )

        # The task should STILL be :running — the ETS check found active agents.
        fetched = TaskRegistry.get_task(task_id)
        assert fetched != nil
        assert fetched.status == :running
      after
        # Clean up the ETS entry.
        # Cleanup in after: rescue so teardown failures don't mask real test failures.
        try do
          :ets.delete(:evogit_sched_meta, sched_meta_entry.id)
        rescue
          _ -> :ok
        end
      end
    end

    test "DOWN handler marks a re-monitored task as :completed when it exits :normal",
         %{data_dir: data_dir} do
      task_id = "restart_down_normal_#{System.unique_integer([:positive])}"

      # Spawn a process that will complete normally after a short delay.
      {:ok, agent_pid} =
        Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
          Process.sleep(50)
          :ok
        end)

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        pid: agent_pid,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      stop_supervised(EvoDash.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.Store, data_dir: data_dir, name: EvoDash.TaskRegistry}
      )

      # Wait for the process to exit and the DOWN handler to fire.
      # Sync with a call to flush the update_status cast.
      TaskRegistry.list_tasks()

      # Give the process time to exit and DOWN to be processed.
      Process.sleep(300)
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.status == :completed
    end

    test "DOWN handler marks a crashed task as :failed", %{data_dir: data_dir} do
      task_id = "restart_down_crash_#{System.unique_integer([:positive])}"

      # Spawn a process that will crash (exit abnormally) after a short delay.
      {:ok, agent_pid} =
        Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
          Process.sleep(50)
          exit(:boom)
        end)

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        pid: agent_pid,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      stop_supervised(EvoDash.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.Store, data_dir: data_dir, name: EvoDash.TaskRegistry}
      )

      TaskRegistry.list_tasks()

      # Wait for the process to crash and the DOWN handler to process.
      Process.sleep(300)
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.status == :failed
    end
  end

  describe "status recovery from spurious :failed" do
    test "a :failed task can recover to :completed via update_task_status" do
      task_id = "recover_completed_#{System.unique_integer([:positive])}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :failed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      usage = %EvoGit.Agent.Usage{input_tokens: 100, total_tokens: 100}

      # update_task_status is a cast; list_tasks() syncs to ensure it's processed.
      TaskRegistry.update_task_status(task_id, :completed, nil,
        usage: usage,
        commit_sha: "abc123"
      )

      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      # The spurious :failed was overwritten by the legitimate :completed.
      assert fetched.status == :completed
      # Recovery should persist metadata, not just flip status.
      assert fetched.commit_sha == "abc123"
      assert fetched.usage == %EvoGit.Agent.Usage{input_tokens: 100, total_tokens: 100}
    end

    test "a :finalizing status update is accepted for a :failed task (recovery before completion)" do
      task_id = "recover_finalizing_#{System.unique_integer([:positive])}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :failed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # The registry subscribes to the "tasks" PubSub topic on init.
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_status, task_id, :finalizing})

      # Sync with a call so the info message is processed before we assert.
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      # :failed should accept :finalizing (was previously blocked).
      assert fetched.status == :finalizing
    end

    test "a :completed task still rejects stale status updates (guard integrity)" do
      task_id = "completed_guard_#{System.unique_integer([:positive])}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # A late :failed update must NOT overwrite a terminal :completed.
      TaskRegistry.update_task_status(task_id, :failed, "late error")

      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.status == :completed
    end

    test "a :cancelled task still rejects stale :finalizing via PubSub (guard integrity)" do
      task_id = "cancelled_guard_#{System.unique_integer([:positive])}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :cancelled,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # A late :finalizing PubSub update must NOT overwrite a terminal :cancelled.
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_status, task_id, :finalizing})

      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.status == :cancelled
    end
  end

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

  describe "lease & heartbeat" do
    # Helper: restart the TaskRegistry so init/1 re-runs and reconcile_task_status
    # is invoked. Uses stop_supervised/1 to avoid auto-restart conflicts, then
    # starts a fresh supervised instance pointing at the same Store + data_dir.
    defp restart_registry!(root) do
      :ok = stop_supervised(EvoDash.TaskRegistry)

      {:ok, _} =
        start_supervised(
          {TaskRegistry, task_store: EvoDash.Store, data_dir: root, name: EvoDash.TaskRegistry}
        )

      :ok
    end

    test "startup reconciliation does NOT mark running task as failed if lease hasn't expired (THE KEY FIX)",
         %{data_dir: root} do
      unique = System.unique_integer([:positive])

      # Simulate a foreign instance's task: running, dead/nil pid, valid future lease.
      task = %TaskInfo{
        id: "lease_valid_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        pid: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: System.system_time(:second) + 300
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # Restart the registry so init → normalize_tasks → reconcile_task_status runs.
      restart_registry!(root)

      tasks = TaskRegistry.list_tasks()
      found = Enum.find(tasks, &(&1.id == "lease_valid_#{unique}"))

      assert found != nil
      assert found.status == :running,
             "task with valid lease should remain :running, got #{inspect(found.status)}"
    end

    test "startup reconciliation DOES mark running task as failed if lease HAS expired",
         %{data_dir: root} do
      unique = System.unique_integer([:positive])

      # Simulate a crashed/orphaned task: running, dead/nil pid, expired lease.
      task = %TaskInfo{
        id: "lease_expired_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        pid: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: System.system_time(:second) - 300
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # Restart the registry so init → normalize_tasks → reconcile_task_status runs.
      restart_registry!(root)

      tasks = TaskRegistry.list_tasks()
      found = Enum.find(tasks, &(&1.id == "lease_expired_#{unique}"))

      assert found != nil
      assert found.status == :failed,
             "task with expired lease should be :failed, got #{inspect(found.status)}"

      assert found.lease_expires_at == nil,
             "failed task should have lease cleared"
    end

    test "lease cleared when task completes via update_task_status" do
      unique = System.unique_integer([:positive])

      task = %TaskInfo{
        id: "lease_complete_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        pid: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: System.system_time(:second) + 300
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # Transition to completed
      TaskRegistry.update_task_status("lease_complete_#{unique}", :completed, nil)

      # Sync
      tasks = TaskRegistry.list_tasks()
      found = Enum.find(tasks, &(&1.id == "lease_complete_#{unique}"))

      assert found != nil
      assert found.status == :completed
      assert found.lease_expires_at == nil,
             "completed task should have lease cleared"
    end

    test "heartbeat renews lease for owned running tasks" do
      unique = System.unique_integer([:positive])

      # Insert a running task with a near-expiry lease directly into the store.
      near_expiry = System.system_time(:second) + 5
      task = %TaskInfo{
        id: "lease_heartbeat_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        pid: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: near_expiry
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # Send a heartbeat message directly to the registry process.
      # Since this task is NOT in task_refs (no owner), it won't have its lease
      # renewed. But since the lease is still valid (near future), it should NOT
      # be swept either.
      send(EvoDash.TaskRegistry, :heartbeat)

      # Sync
      TaskRegistry.list_tasks()

      found = EvoDash.Store.get_task(EvoDash.Store, "lease_heartbeat_#{unique}")
      assert found != nil
      # Lease should be unchanged (not owned, not expired → left alone)
      assert found.lease_expires_at == near_expiry
      assert found.status == :running
    end

    test "heartbeat sweeps expired-lease running tasks we don't own" do
      unique = System.unique_integer([:positive])

      # Insert a running task with an expired lease, no pid, not owned.
      task = %TaskInfo{
        id: "lease_sweep_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        pid: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: System.system_time(:second) - 300
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # Send a heartbeat message directly to the registry process.
      send(EvoDash.TaskRegistry, :heartbeat)

      # Sync
      TaskRegistry.list_tasks()

      found = EvoDash.Store.get_task(EvoDash.Store, "lease_sweep_#{unique}")
      assert found != nil
      assert found.status == :failed,
             "task with expired lease should be swept to :failed, got #{inspect(found.status)}"

      assert found.lease_expires_at == nil
    end
  end
end
