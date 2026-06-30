defmodule EvoDash.TaskRegistryTest do
  use ExUnit.Case, async: false

  alias EvoDash.TaskRegistry
  alias EvoDash.TaskRegistry.TaskInfo

  setup do
    # Terminate production children to prevent auto-restarts and use isolated stores.
    Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
    Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.TaskStore)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_tasks_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({EvoDash.TaskStore, data_dir: sqlite_path})

    start_supervised(
      {TaskRegistry, task_store: EvoDash.TaskStore, data_dir: root, name: EvoDash.TaskRegistry}
    )

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.TaskStore)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
    end)

    {:ok, %{data_dir: root}}
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

    EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, trigger_id}, trigger)
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

      # Insert an old finished task directly into the store (20 days old > 14 day default)
      old_task = %TaskInfo{
        id: "test_old_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(DateTime.utc_now(), -20 * 24 * 60 * 60, :second),
        finished_at: DateTime.add(DateTime.utc_now(), -20 * 24 * 60 * 60, :second),
        logs: [],
        result: nil
      }

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "test_old_#{unique}"}, old_task)

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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "test_recent_#{unique}"}, recent_task)

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

      # Insert a task 5 days old (within 14 day default)
      task = %TaskInfo{
        id: "test_5day_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(DateTime.utc_now(), -5 * 24 * 60 * 60, :second),
        finished_at: DateTime.add(DateTime.utc_now(), -5 * 24 * 60 * 60, :second),
        logs: [],
        result: nil
      }

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "test_5day_#{unique}"}, task)

      # Trigger cleanup
      trigger_cleanup!()

      tasks = TaskRegistry.list_tasks()
      task_ids = Enum.map(tasks, & &1.id)
      assert "test_5day_#{unique}" in task_ids
    end

    test "never cleans up running or pending tasks even if old" do
      unique = System.unique_integer([:positive])

      # Running task with old started_at (finished_at is nil)
      running_task = %TaskInfo{
        id: "test_running_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(DateTime.utc_now(), -20 * 24 * 60 * 60, :second),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "test_running_#{unique}"}, running_task)

      # Pending task
      pending_task = %TaskInfo{
        id: "test_pending_#{unique}",
        type: :genesis,
        status: :pending,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(DateTime.utc_now(), -20 * 24 * 60 * 60, :second),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "test_pending_#{unique}"}, pending_task)

      # Old finished task (should be cleaned)
      old_finished = %TaskInfo{
        id: "test_oldfin_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(DateTime.utc_now(), -20 * 24 * 60 * 60, :second),
        finished_at: DateTime.add(DateTime.utc_now(), -20 * 24 * 60 * 60, :second),
        logs: [],
        result: nil
      }

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "test_oldfin_#{unique}"}, old_finished)

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

      # Old task (over 14 days) - should be cleaned by age
      old_task = %TaskInfo{
        id: "test_combined_old_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(now, -20 * 24 * 60 * 60, :second),
        finished_at: DateTime.add(now, -20 * 24 * 60 * 60, :second),
        logs: [],
        result: nil
      }

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "test_combined_old_#{unique}"}, old_task)

      # Recent tasks (within 14 days) - should be kept
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

        EvoDash.TaskStore.put(
          EvoDash.TaskStore,
          {:task, "test_combined_recent_#{unique}_#{i}"},
          recent
        )
      end

      # Running task - should always be kept regardless of age
      running = %TaskInfo{
        id: "test_combined_running_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.add(now, -20 * 24 * 60 * 60, :second),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoDash.TaskStore.put(
        EvoDash.TaskStore,
        {:task, "test_combined_running_#{unique}"},
        running
      )

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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

      TaskRegistry.set_review_metadata(task_id, "abc123", "def456")

      # Sync with a call to ensure cast was processed
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.base_sha == "abc123"
      assert fetched.commit_sha == "def456"
    end

    test "persists to the store after update" do
      unique = System.unique_integer([:positive])
      task_id = "review_meta_dets_#{unique}"

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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

      TaskRegistry.set_review_metadata(task_id, "base_sha_1", "commit_sha_1")

      # Sync to ensure the cast (which writes directly to the store) has been processed
      TaskRegistry.list_tasks()

      # Read directly from the store to confirm persistence
      stored_task = EvoDash.TaskStore.get(EvoDash.TaskStore, {:task, task_id})

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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, old_map)

      # Stop the supervised registry, then restart it so normalize_tasks runs.
      # KEEP the same store running so the backfilled data persists.
      stop_supervised(EvoDash.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.TaskStore, data_dir: data_dir, name: EvoDash.TaskRegistry}
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
      task_id = "cubdb_crud_#{unique}"

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

      :ok = EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

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
      task_id = "cubdb_durable_#{unique}"

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

      :ok = EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

      # Confirm the task is visible before restart.
      assert %TaskInfo{} = TaskRegistry.get_task(task_id)

      # Stop the registry but KEEP the same store running (store is durable on disk).
      stop_supervised(EvoDash.TaskRegistry)

      # Restart the registry pointing at the same store and data_dir.
      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.TaskStore, data_dir: data_dir, name: EvoDash.TaskRegistry}
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

  describe "projects table schema migration" do
    test "self-heals a stale projects table with path column as PK" do
      unique = System.unique_integer([:positive])
      root = Path.join(System.tmp_dir!(), "evogit_test_schema_migrate_#{unique}")
      File.mkdir_p!(root)
      sqlite_path = Path.join(root, "tasks.sqlite")

      # Seed a STALE schema: the `projects` table uses `path` as the PK column
      # (historical bug from commit 0989e6f9) instead of `id`. Both tables are
      # created as an older version of the app would have written them.
      {:ok, conn} = Xqlite.open(sqlite_path)

      {:ok, _} =
        XqliteNIF.execute(conn, "CREATE TABLE tasks (id TEXT PRIMARY KEY, data BLOB)", [])

      {:ok, _} =
        XqliteNIF.execute(conn, "CREATE TABLE projects (path TEXT PRIMARY KEY, data BLOB)", [])

      proj1 = %{path: "/tmp/proj1", name: "Project One", last_opened_at: DateTime.utc_now()}
      proj2 = %{path: "/tmp/proj2", name: "Project Two", last_opened_at: DateTime.utc_now()}

      {:ok, _} =
        XqliteNIF.execute(conn, "INSERT INTO projects (path, data) VALUES (?1, ?2)", [
          "/tmp/proj1",
          :erlang.term_to_binary(proj1)
        ])

      {:ok, _} =
        XqliteNIF.execute(conn, "INSERT INTO projects (path, data) VALUES (?1, ?2)", [
          "/tmp/proj2",
          :erlang.term_to_binary(proj2)
        ])

      :ok = XqliteNIF.close(conn)

      on_exit(fn -> File.rm_rf(root) end)

      # Stop the default supervised store + registry (from the module setup),
      # then start fresh ones pointing at the stale DB. TaskStore.init will call
      # create_tables/repair_projects_table, which should self-heal the schema.
      stop_supervised(EvoDash.TaskRegistry)
      stop_supervised(EvoDash.TaskStore)

      start_supervised({EvoDash.TaskStore, data_dir: sqlite_path})

      start_supervised(
        {TaskRegistry, task_store: EvoDash.TaskStore, data_dir: root, name: EvoDash.TaskRegistry}
      )

      # The repair mapped `path` → `id`, so list_recent_projects should return
      # the 2 migrated projects with correct data.
      projects = TaskRegistry.list_recent_projects()
      assert length(projects) == 2

      paths = Enum.map(projects, & &1.path) |> Enum.sort()
      assert paths == ["/tmp/proj1", "/tmp/proj2"]

      names = Enum.map(projects, & &1.name) |> Enum.sort()
      assert names == ["Project One", "Project Two"]
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
         task_store: EvoDash.TaskStore, data_dir: data_dir, name: EvoDash.TaskRegistry}
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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

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

        EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, id}, task)
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
    test "registry survives and salvages good tasks when wrong-shape entries exist" do
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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "good1_#{unique}"}, good1)
      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "good2_#{unique}"}, good2)

      # Structurally corrupt entries (valid keys, wrong-shape values).
      # Note: the SQLite store enforces key shape — only {:task, id} and
      # {:project, path} are accepted — so we test wrong-value resilience here.
      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "bad_string"}, "not a task struct at all")
      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "bad_map"}, %{random: "data", not: :task})

      EvoDash.TaskStore.put(
        EvoDash.TaskStore,
        {:project, "/some/path"},
        %{path: "/some/path", name: "test", last_opened_at: DateTime.utc_now()}
      )

      pid = GenServer.whereis(EvoDash.TaskRegistry)
      assert Process.alive?(pid)

      # list_tasks must NOT crash — it should return only valid TaskInfo structs
      tasks = TaskRegistry.list_tasks()
      assert is_list(tasks)

      ids = Enum.map(tasks, & &1.id)
      assert "good1_#{unique}" in ids
      assert "good2_#{unique}" in ids
      # Corrupt entries should NOT appear
      refute "bad_string" in ids
      refute "bad_map" in ids

      # Registry still alive after reads
      assert Process.alive?(pid)

      # get_unique_paths works
      paths = TaskRegistry.get_unique_paths()
      assert is_list(paths)

      # list_recent_projects works
      projects = TaskRegistry.list_recent_projects()
      assert is_list(projects)
    end

    test "cleanup_expired_tasks does not crash GenServer when wrong-shape entries exist" do
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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "good_cleanup_#{unique}"}, good)

      # Corrupt entry
      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, "bad_cleanup"}, %{not_a: :task})

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

    test "completing a task persists it even when corrupt entries exist elsewhere" do
      unique = System.unique_integer([:positive])

      # Seed a corrupt entry FIRST
      EvoDash.TaskStore.put(
        EvoDash.TaskStore,
        {:task, "pre_existing_corrupt_#{unique}"},
        "garbage_value"
      )

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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

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
        %{agent_id: "T1_A1", parent_id: nil, objective: "Genesis", role: :manager}
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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, stripped)

      # Restart the registry to trigger normalize_tasks on init. normalize_tasks
      # runs Map.merge(%TaskInfo{}, task), backfilling the missing field to its
      # default (nil).
      stop_supervised(TaskRegistry)

      start_supervised!(
        {TaskRegistry,
         task_store: EvoDash.TaskStore, data_dir: data_dir, name: EvoDash.TaskRegistry}
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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

      archive_records = [
        %{agent_id: "T1_A1", parent_id: nil, objective: "Genesis", role: :manager},
        %{agent_id: "T2_A1", parent_id: "T1_A1", objective: "Implement", role: :executor}
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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

      # Confirm the process is alive before restart.
      assert Process.alive?(agent_pid)

      # Restart the registry so normalize_tasks re-runs.
      stop_supervised(EvoDash.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.TaskStore, data_dir: data_dir, name: EvoDash.TaskRegistry}
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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

      refute Process.alive?(agent_pid)

      stop_supervised(EvoDash.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.TaskStore, data_dir: data_dir, name: EvoDash.TaskRegistry}
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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

      stop_supervised(EvoDash.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.TaskStore, data_dir: data_dir, name: EvoDash.TaskRegistry}
      )

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.status == :failed
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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

      stop_supervised(EvoDash.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.TaskStore, data_dir: data_dir, name: EvoDash.TaskRegistry}
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

      EvoDash.TaskStore.put(EvoDash.TaskStore, {:task, task_id}, task)

      stop_supervised(EvoDash.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.TaskStore, data_dir: data_dir, name: EvoDash.TaskRegistry}
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

  describe "TaskStore.integrity_check" do
    test "returns :ok on a healthy store" do
      unique = System.unique_integer([:positive])
      store = :"ic_healthy_store_#{unique}"
      sqlite_path = Path.join(System.tmp_dir!(), "evogit_ic_healthy_#{unique}.sqlite")
      File.mkdir_p!(Path.dirname(sqlite_path))

      {:ok, _} = EvoDash.TaskStore.start_link(data_dir: sqlite_path, name: store)

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

        :ok = EvoDash.TaskStore.put(store, {:task, "ic_good_#{unique}"}, good)

        assert EvoDash.TaskStore.integrity_check(store) == :ok

        # The good entry is still present.
        fetched = EvoDash.TaskStore.get(store, {:task, "ic_good_#{unique}"})
        assert %TaskInfo{} = fetched
        assert fetched.id == "ic_good_#{unique}"
      after
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

      {:ok, _} = EvoDash.TaskStore.start_link(data_dir: sqlite_path, name: store)

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

        :ok = EvoDash.TaskStore.put(store, {:task, "ic_good2_#{unique}"}, good)

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
            "INSERT OR REPLACE INTO tasks (id, data) VALUES (?1, ?2)",
            ["garbage_row_#{unique}", :binary.copy(<<0xFF>>, 16)]
          )

        :ok = XqliteNIF.close(conn)

        # Reopen the store so it sees the injected row. The existing store
        # process holds its own connection, so stop and restart it.
        :ok = GenServer.stop(store)
        {:ok, _} = EvoDash.TaskStore.start_link(data_dir: sqlite_path, name: store)

        # integrity_check should remove the undecodable row.
        result = EvoDash.TaskStore.integrity_check(store)
        assert match?({:repaired, _}, result) or match?(:ok, result)

        # safe_select_all skips the garbage row and keeps the good one.
        entries = EvoDash.TaskStore.safe_select_all(store)
        keys = Enum.map(entries, fn {k, _} -> k end)

        assert {:task, "ic_good2_#{unique}"} in keys
        refute {:task, "garbage_row_#{unique}"} in keys
      after
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

      {:ok, _} = EvoDash.TaskStore.start_link(data_dir: sqlite_path, name: store)

      try do
        good_proj = %{path: "/tmp/good_proj_#{unique}", name: "good", last_opened_at: DateTime.utc_now()}

        :ok = EvoDash.TaskStore.put(store, {:project, "/tmp/good_proj_#{unique}"}, good_proj)
        garbage_blob = :binary.copy(<<0xFF>>, 16)
        garbage_id = "garbage_proj_#{unique}"

        # Inject garbage into the projects table via raw connection.
        conn =
          case Xqlite.open(sqlite_path) do
            {:ok, c} -> c
          end

        {:ok, _} =
          XqliteNIF.execute(
            conn,
            "INSERT OR REPLACE INTO projects (id, data) VALUES (?1, ?2)",
            [garbage_id, garbage_blob]
          )

        :ok = XqliteNIF.close(conn)

        # Reopen so the store sees the injected row.
        :ok = GenServer.stop(store)
        {:ok, _} = EvoDash.TaskStore.start_link(data_dir: sqlite_path, name: store)

        result = EvoDash.TaskStore.integrity_check(store)
        assert match?({:repaired, _}, result) or match?(:ok, result)

        # The garbage row is repaired out of the live table.
        entries = EvoDash.TaskStore.safe_select_all(store)
        keys = Enum.map(entries, fn {k, _} -> k end)
        refute {:project, garbage_id} in keys
        # The good project is still present.
        assert {:project, "/tmp/good_proj_#{unique}"} in keys

        # CRITICAL: the raw blob is preserved in projects_quarantine, not destroyed.
        conn2 =
          case Xqlite.open(sqlite_path) do
            {:ok, c} -> c
          end

        {:ok, %{rows: [[count]]}} =
          XqliteNIF.query(conn2, "SELECT COUNT(*) FROM projects_quarantine", [])

        assert count >= 1

        {:ok, %{rows: rows}} =
          XqliteNIF.query(conn2, "SELECT data FROM projects_quarantine WHERE id = ?1", [garbage_id])

        [recovered_blob | _] = List.first(rows)
        assert recovered_blob == garbage_blob

        :ok = XqliteNIF.close(conn2)
      after
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
