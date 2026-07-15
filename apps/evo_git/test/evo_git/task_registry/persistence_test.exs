defmodule EvoGit.TaskRegistry.PersistenceTest do
  use EvoGit.TaskRegistryCase, async: false

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

      EvoGit.Store.put_task(EvoGit.Store, task)

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

      EvoGit.Store.put_task(EvoGit.Store, task)

      TaskRegistry.set_review_metadata(task_id, "base_sha_1", "commit_sha_1")

      # Sync to ensure the cast (which writes directly to the store) has been processed
      TaskRegistry.list_tasks()

      # Read directly from the store to confirm persistence
      stored_task = EvoGit.Store.get_task(EvoGit.Store, task_id)

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

      EvoGit.Store.put_task(EvoGit.Store, task)

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

      # Simulate an old persisted entry. In production, when a new column is
      # added via ALTER TABLE, existing rows get NULL. The decoder always
      # produces a complete struct (nil for NULL columns). normalize_tasks
      # then calls Map.merge(%TaskInfo{}, task) to ensure struct defaults.
      # We write a task with explicit nil values for the newer fields and
      # verify they survive a restart round-trip.
      old_task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil,
        base_sha: nil,
        commit_sha: nil,
        model_id: nil
      }

      EvoGit.Store.put_task(EvoGit.Store, old_task)

      # Stop the supervised registry, then restart it so normalize_tasks runs.
      # KEEP the same store running so the backfilled data persists.
      stop_supervised(EvoGit.TaskRegistry)

      start_supervised(
        {TaskRegistry,
         task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry}
      )

      # The backfilled task should exist with nil for the new fields
      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.base_sha == nil
      assert fetched.commit_sha == nil
      assert fetched.model_id == nil
    end

    test "normalize_tasks backfills model_id to nil for older structs", %{
      data_dir: data_dir
    } do
      task_id = "model_backfill_#{System.unique_integer([:positive])}"

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
          result: nil,
          model_id: nil
        }

      EvoGit.Store.put_task(EvoGit.Store, stripped)

      # Restart the registry to trigger normalize_tasks on init.
      stop_supervised(TaskRegistry)

      start_supervised!(
        {TaskRegistry,
         task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry}
      )

      fetched = TaskRegistry.get_task(task_id)
      assert %TaskInfo{} = fetched
      assert Map.has_key?(fetched, :model_id)
      assert fetched.model_id == nil
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

      :ok = EvoGit.Store.put_task(EvoGit.Store, task)

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

      :ok = EvoGit.Store.put_task(EvoGit.Store, task)

      # Confirm the task is visible before restart.
      assert %TaskInfo{} = TaskRegistry.get_task(task_id)

      # Stop the registry but KEEP the same store running (store is durable on disk).
      stop_supervised(EvoGit.TaskRegistry)

      # Restart the registry pointing at the same store and data_dir.
      start_supervised(
        {TaskRegistry,
         task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry}
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
      stop_supervised(EvoGit.TaskRegistry)

      # Restart the registry pointing at the same store and data_dir.
      start_supervised(
        {TaskRegistry,
         task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry}
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

      EvoGit.Store.put_task(EvoGit.Store, task)

      pid = GenServer.whereis(EvoGit.TaskRegistry)
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
      pid = GenServer.whereis(EvoGit.TaskRegistry)
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

        EvoGit.Store.put_task(EvoGit.Store, task)
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

      EvoGit.Store.put_task(EvoGit.Store, good1)
      EvoGit.Store.put_task(EvoGit.Store, good2)

      # Structurally corrupt entries (valid keys, wrong-shape values).
      # Inject corrupt rows via raw SQL (bypassing put_task validation).
      # The new typed API rejects non-struct input, so we go under the hood.
      {:ok, raw_conn} = Xqlite.open(sqlite_path)
      XqliteNIF.execute(raw_conn, "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)", ["bad_string", "completed", "<<invalid json>>"])
      XqliteNIF.execute(raw_conn, "INSERT OR REPLACE INTO tasks (id, status, type) VALUES (?1, ?2, ?3)", ["bad_map", "completed", "invalid_type_atom_xyz"])
      XqliteNIF.close(raw_conn)

      EvoGit.Store.put_project(
        EvoGit.Store,
        %EvoGit.RecentProject{path: "/some/path", name: "test", last_opened_at: DateTime.utc_now()}
      )

      pid = GenServer.whereis(EvoGit.TaskRegistry)
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

      EvoGit.Store.put_task(EvoGit.Store, good)

      # Corrupt entry
      # Inject a corrupt row via raw SQL (put_task rejects non-struct input)
      {:ok, raw_conn2} = Xqlite.open(sqlite_path)
      XqliteNIF.execute(raw_conn2, "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)", ["bad_cleanup", "completed", "<<not json>>"])
      XqliteNIF.close(raw_conn2)

      pid = GenServer.whereis(EvoGit.TaskRegistry)
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

      EvoGit.Store.put_task(EvoGit.Store, task)

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
      pid = GenServer.whereis(EvoGit.TaskRegistry)
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

      EvoGit.Store.put_task(EvoGit.Store, task)

      fetched = TaskRegistry.get_task(task_id)
      assert %TaskInfo{} = fetched
      assert fetched.archive_metadata == archive
    end

    test "normalize_tasks backfills archive_metadata to nil for older structs", %{
      data_dir: data_dir
    } do
      task_id = "archive_backfill_#{System.unique_integer([:positive])}"

      # Simulate an old persisted entry. In production, when the archive_metadata
      # column was added via ALTER TABLE, existing rows got NULL. The decoder
      # always produces a complete struct (nil for NULL columns). normalize_tasks
      # then calls Map.merge(%TaskInfo{}, task) to ensure struct defaults.
      # We write a task with explicit nil for archive_metadata and verify it
      # survives a restart round-trip.
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
          result: nil,
          archive_metadata: nil
        }

      EvoGit.Store.put_task(EvoGit.Store, stripped)

      # Restart the registry to trigger normalize_tasks on init. normalize_tasks
      # runs Map.merge(%TaskInfo{}, task), backfilling the missing field to its
      # default (nil).
      stop_supervised(TaskRegistry)

      start_supervised!(
        {TaskRegistry,
         task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry}
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

      EvoGit.Store.put_task(EvoGit.Store, task)

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

      EvoGit.Store.put_task(EvoGit.Store, task)

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

      EvoGit.Store.put_task(EvoGit.Store, task)

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

      EvoGit.Store.put_task(EvoGit.Store, task)

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

      EvoGit.Store.put_task(EvoGit.Store, task)

      # A late :finalizing PubSub update must NOT overwrite a terminal :cancelled.
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_status, task_id, :finalizing})

      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.status == :cancelled
    end
  end
end
