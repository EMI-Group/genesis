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
        {TaskRegistry, task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry}
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
        {TaskRegistry, task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry}
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
        {TaskRegistry, task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry}
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
        {TaskRegistry, task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry}
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
    test "registry survives and salvages good tasks when wrong-shape entries exist", %{
      sqlite_path: sqlite_path
    } do
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

      XqliteNIF.execute(
        raw_conn,
        "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)",
        ["bad_string", "completed", "<<invalid json>>"]
      )

      XqliteNIF.execute(
        raw_conn,
        "INSERT OR REPLACE INTO tasks (id, status, type) VALUES (?1, ?2, ?3)",
        ["bad_map", "completed", "invalid_type_atom_xyz"]
      )

      XqliteNIF.close(raw_conn)

      EvoGit.Store.put_project(
        EvoGit.Store,
        %EvoGit.RecentProject{
          path: "/some/path",
          name: "test",
          last_opened_at: DateTime.utc_now()
        }
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

    test "cleanup_expired_tasks does not crash GenServer when wrong-shape entries exist", %{
      sqlite_path: sqlite_path
    } do
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

      XqliteNIF.execute(
        raw_conn2,
        "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)",
        ["bad_cleanup", "completed", "<<not json>>"]
      )

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

    test "completing a task persists it even when corrupt entries exist elsewhere", %{
      sqlite_path: sqlite_path
    } do
      unique = System.unique_integer([:positive])

      # Seed a corrupt entry FIRST
      # Inject a corrupt row via raw SQL (bypassing put_task validation)
      {:ok, raw_conn} = Xqlite.open(sqlite_path)

      XqliteNIF.execute(
        raw_conn,
        "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)",
        [
          "pre_existing_corrupt_#{unique}",
          "completed",
          "<<invalid json>>"
        ]
      )

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
        %{
          "agent_id" => "T1_A1",
          "parent_id" => nil,
          "objective" => "Genesis",
          "role" => "manager"
        }
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
        {TaskRegistry, task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry}
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
        %{
          "agent_id" => "T1_A1",
          "parent_id" => nil,
          "objective" => "Genesis",
          "role" => "manager"
        },
        %{
          "agent_id" => "T2_A1",
          "parent_id" => "T1_A1",
          "objective" => "Implement",
          "role" => "executor"
        }
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

  describe "startup reconciliation of orphaned :finalizing tasks" do
    test "restart marks an orphaned :finalizing row :failed but leaves a :running row untouched",
         %{data_dir: data_dir} do
      unique = System.unique_integer([:positive])
      finalizing_id = "startup_finalizing_#{unique}"
      running_id = "startup_running_#{unique}"
      future_lease = System.system_time(:second) + 300

      # Stop the initial registry FIRST so the seeded rows exist in the Store
      # before the fresh registry boots — literally "fresh registry against a
      # DB containing :finalizing rows". The Store stays running (durable on
      # disk); it is NOT stopped/restarted.
      stop_supervised(EvoGit.TaskRegistry)

      finalizing_task = %TaskInfo{
        id: finalizing_id,
        type: :genesis,
        status: :finalizing,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: future_lease
      }

      running_task = %TaskInfo{
        id: running_id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: future_lease
      }

      :ok = EvoGit.Store.put_task(EvoGit.Store, finalizing_task)
      :ok = EvoGit.Store.put_task(EvoGit.Store, running_task)

      # Restart the registry pointing at the same store and data_dir.
      start_supervised(
        {TaskRegistry, task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry}
      )

      # The Store is the durable source of truth; the registry's init
      # reconciliation must have marked the orphaned :finalizing row :failed.
      finalizing = EvoGit.Store.get_task(EvoGit.Store, finalizing_id)
      assert finalizing != nil
      assert finalizing.status == :failed
      assert finalizing.finished_at != nil
      assert finalizing.lease_expires_at == nil
      # Do not over-pin the exact fix wording — just require a result payload.
      assert is_binary(finalizing.result)

      # Control row: a :running task with a valid (future) lease must NOT be
      # touched at init — sweeping orphaned :running tasks is the :lease_sweep
      # path (covered in lease_heartbeat_test.exs).
      running = EvoGit.Store.get_task(EvoGit.Store, running_id)
      assert running != nil
      assert running.status == :running
      assert running.lease_expires_at == future_lease
    end

    test "restart marks an orphaned :cancelling row :cancelled", %{data_dir: data_dir} do
      unique = System.unique_integer([:positive])
      cancelling_id = "startup_cancelling_#{unique}"
      future_lease = System.system_time(:second) + 300

      stop_supervised(EvoGit.TaskRegistry)

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: cancelling_id,
          type: :genesis,
          status: :cancelling,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: future_lease
        })

      start_supervised(
        {TaskRegistry, task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry}
      )

      # The runtime died mid-cancel — the orphaned :cancelling row must resolve
      # to :cancelled (never stay :cancelling forever).
      fetched = EvoGit.Store.get_task(EvoGit.Store, cancelling_id)
      assert fetched != nil
      assert fetched.status == :cancelled
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil
      assert is_binary(fetched.result)
    end
  end

  describe "list_tasks_summary / by_path / changed_since — since filter semantics" do
    test "list_tasks_summary/2 since returns only strictly-newer rows; boundary-equal excluded; nil since returns all",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      t1 = "summary_since_a_#{unique}"
      t2 = "summary_since_b_#{unique}"
      t3 = "summary_since_c_#{unique}"

      for {id, status} <- [{t1, :completed}, {t2, :running}, {t3, :completed}] do
        :ok =
          EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: "/proj-since"],
            ref: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil
          })
      end

      # Control the store-internal updated_at column directly via raw SQL so
      # the string-comparison semantics of the `since` filter are deterministic.
      set_updated_at(sqlite_path, t1, "2024-01-01T00:00:00.000Z")
      set_updated_at(sqlite_path, t2, "2024-01-02T00:00:00.000Z")
      set_updated_at(sqlite_path, t3, "2024-01-03T00:00:00.000Z")

      # Strictly-newer only: the boundary-equal row (t2) is excluded.
      ids =
        TaskRegistry.list_tasks_summary([], "2024-01-02T00:00:00.000Z")
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids == [t3]

      # nil since → no time filter.
      ids_all =
        TaskRegistry.list_tasks_summary([], nil)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids_all == Enum.sort([t1, t2, t3])

      # statuses + since combined.
      assert TaskRegistry.list_tasks_summary([:completed], "2024-01-01T00:00:00.000Z")
             |> Enum.map(& &1.id)
             |> Enum.sort() == [t3]

      assert TaskRegistry.list_tasks_summary([:running], "2024-01-01T00:00:00.000Z")
             |> Enum.map(& &1.id) == [t2]
    end

    test "list_tasks_summary_by_path/3 combines path + since (+ statuses)", %{
      sqlite_path: sqlite_path
    } do
      unique = System.unique_integer([:positive])
      a1 = "summary_path_a_#{unique}"
      a2 = "summary_path_b_#{unique}"
      b1 = "summary_path_c_#{unique}"

      for {id, path, status} <- [
            {a1, "/proj-a", :completed},
            {a2, "/proj-a", :running},
            {b1, "/proj-b", :completed}
          ] do
        :ok =
          EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: path],
            ref: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil
          })
      end

      set_updated_at(sqlite_path, a1, "2024-01-01T00:00:00.000Z")
      set_updated_at(sqlite_path, a2, "2024-01-02T00:00:00.000Z")
      set_updated_at(sqlite_path, b1, "2024-01-03T00:00:00.000Z")

      assert TaskRegistry.list_tasks_summary_by_path("/proj-a", [], "2024-01-01T00:00:00.000Z")
             |> Enum.map(& &1.id) == [a2]

      assert TaskRegistry.list_tasks_summary_by_path("/proj-a", [], nil)
             |> Enum.map(& &1.id)
             |> Enum.sort() == Enum.sort([a1, a2])

      assert TaskRegistry.list_tasks_summary_by_path("/proj-b", [], "2024-01-01T00:00:00.000Z")
             |> Enum.map(& &1.id) == [b1]

      # path + statuses + since: a2 is :running, so no :completed matches.
      assert TaskRegistry.list_tasks_summary_by_path(
               "/proj-a",
               [:completed],
               "2024-01-01T00:00:00.000Z"
             ) ==
               []

      # path + statuses, no since.
      assert TaskRegistry.list_tasks_summary_by_path("/proj-a", [:completed], nil)
             |> Enum.map(& &1.id) == [a1]
    end

    test "list_tasks_changed_since/1 returns only newer rows with the 15-key projection",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      t1 = "changed_a_#{unique}"
      t2 = "changed_b_#{unique}"
      t3 = "changed_c_#{unique}"

      for {id, status} <- [{t1, :completed}, {t2, :running}, {t3, :pending}] do
        :ok =
          EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: "/proj-changed"],
            ref: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil
          })
      end

      set_updated_at(sqlite_path, t1, "2024-01-01T00:00:00.000Z")
      set_updated_at(sqlite_path, t2, "2024-01-02T00:00:00.000Z")
      set_updated_at(sqlite_path, t3, "2024-01-03T00:00:00.000Z")

      results = TaskRegistry.list_tasks_changed_since("2024-01-02T00:00:00.000Z")
      assert Enum.map(results, & &1.id) |> Enum.sort() == [t3]

      # Future since → nothing.
      assert TaskRegistry.list_tasks_changed_since("2099-01-01T00:00:00.000Z") == []

      # 15-key projection; updated_at passed through as the raw ISO string.
      [row] = TaskRegistry.list_tasks_changed_since("2024-01-02T00:00:00.000Z")

      expected_keys =
        [
          :id,
          :status,
          :review_status,
          :started_at,
          :finished_at,
          :type,
          :project_path,
          :opts,
          :branch_name,
          :model_id,
          :agent_count,
          :base_sha,
          :commit_sha,
          :lease_expires_at,
          :updated_at
        ]
        |> Enum.sort()

      assert Map.keys(row) |> Enum.sort() == expected_keys
      assert row.id == t3
      assert row.status == :pending
      assert row.updated_at == "2024-01-03T00:00:00.000Z"
      assert row.project_path == "/proj-changed"
    end
  end

  describe "list_task_ids/1 — minimal id/status/updated_at projection" do
    test "list_task_ids/0 returns ALL tasks with exactly id/status/updated_at keys",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      t1 = "task_ids_all_a_#{unique}"
      t2 = "task_ids_all_b_#{unique}"
      t3 = "task_ids_all_c_#{unique}"
      t4 = "task_ids_all_d_#{unique}"

      for {id, status} <- [
            {t1, :completed},
            {t2, :running},
            {t3, :pending},
            {t4, :failed}
          ] do
        :ok =
          EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: "/proj-task-ids"],
            ref: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil
          })
      end

      # Control the store-internal updated_at column so the raw string
      # pass-through is deterministic.
      set_updated_at(sqlite_path, t1, "2024-01-01T00:00:00.000Z")
      set_updated_at(sqlite_path, t2, "2024-01-02T00:00:00.000Z")
      set_updated_at(sqlite_path, t3, "2024-01-03T00:00:00.000Z")
      set_updated_at(sqlite_path, t4, "2024-01-04T00:00:00.000Z")

      rows = TaskRegistry.list_task_ids()

      assert Enum.map(rows, & &1.id) |> Enum.sort() == Enum.sort([t1, t2, t3, t4])

      # Every row is a minimal projection — exactly id/status/updated_at, no
      # heavy JSON fields decoded.
      for row <- rows do
        assert Map.keys(row) |> Enum.sort() == [:id, :status, :updated_at]
        assert is_atom(row.status)
        # Raw fixed-precision ISO binary, NOT a decoded DateTime.
        assert is_binary(row.updated_at)
      end

      by_id = Map.new(rows, &{&1.id, &1})
      assert by_id[t1].status == :completed
      assert by_id[t1].updated_at == "2024-01-01T00:00:00.000Z"
      assert by_id[t2].status == :running
      assert by_id[t2].updated_at == "2024-01-02T00:00:00.000Z"
      assert by_id[t3].status == :pending
      assert by_id[t3].updated_at == "2024-01-03T00:00:00.000Z"
      assert by_id[t4].status == :failed
      assert by_id[t4].updated_at == "2024-01-04T00:00:00.000Z"
    end

    test "list_task_ids/1 with a single status returns only matching rows",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      t1 = "task_ids_filter_a_#{unique}"
      t2 = "task_ids_filter_b_#{unique}"
      t3 = "task_ids_filter_c_#{unique}"

      for {id, status} <- [{t1, :completed}, {t2, :running}, {t3, :completed}] do
        :ok =
          EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: "/proj-task-ids"],
            ref: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil
          })
      end

      set_updated_at(sqlite_path, t1, "2024-01-01T00:00:00.000Z")
      set_updated_at(sqlite_path, t2, "2024-01-02T00:00:00.000Z")
      set_updated_at(sqlite_path, t3, "2024-01-03T00:00:00.000Z")

      rows = TaskRegistry.list_task_ids([:completed])

      assert Enum.map(rows, & &1.id) |> Enum.sort() == Enum.sort([t1, t3])
      assert Enum.all?(rows, &(&1.status == :completed))

      # Non-matching statuses are excluded.
      assert TaskRegistry.list_task_ids([:running]) |> Enum.map(& &1.id) == [t2]
    end

    test "list_task_ids/1 with multiple statuses returns the union of matches",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      t1 = "task_ids_multi_a_#{unique}"
      t2 = "task_ids_multi_b_#{unique}"
      t3 = "task_ids_multi_c_#{unique}"
      t4 = "task_ids_multi_d_#{unique}"

      for {id, status} <- [
            {t1, :completed},
            {t2, :failed},
            {t3, :running},
            {t4, :pending}
          ] do
        :ok =
          EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: "/proj-task-ids"],
            ref: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil
          })
      end

      set_updated_at(sqlite_path, t1, "2024-01-01T00:00:00.000Z")
      set_updated_at(sqlite_path, t2, "2024-01-02T00:00:00.000Z")
      set_updated_at(sqlite_path, t3, "2024-01-03T00:00:00.000Z")
      set_updated_at(sqlite_path, t4, "2024-01-04T00:00:00.000Z")

      rows = TaskRegistry.list_task_ids([:completed, :failed])

      assert Enum.map(rows, & &1.id) |> Enum.sort() == Enum.sort([t1, t2])
      assert Enum.all?(rows, &(&1.status in [:completed, :failed]))
    end
  end

  describe "recheck_task resolution" do
    setup do
      # The :evogit_sched_meta table is normally owned by AgentScheduler; in
      # this test env it may or may not be running. Create it if missing and
      # start each test from a clean table (no agents are active in tests).
      if :ets.whereis(:evogit_sched_meta) == :undefined do
        :ets.new(:evogit_sched_meta, [:set, :named_table, :public])
      end

      :ets.delete_all_objects(:evogit_sched_meta)

      on_exit(fn ->
        :ets.delete_all_objects(:evogit_sched_meta)
      end)

      :ok
    end

    test "resolves a :running task to :completed when no sched_meta entries remain" do
      unique = System.unique_integer([:positive])
      task_id = "recheck_resolve_#{unique}"

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      send(EvoGit.TaskRegistry, {:recheck_task, task_id})
      assert_receive {:tasks_updated}, 1_000

      fetched = EvoGit.Store.get_task(EvoGit.Store, task_id)
      assert fetched.status == :completed
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil
      assert fetched.branch_name == nil
    end

    test "does not clobber an existing branch_name when no result is found" do
      unique = System.unique_integer([:positive])
      task_id = "recheck_preserve_#{unique}"

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          branch_name: "evogit/orig"
        })

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      send(EvoGit.TaskRegistry, {:recheck_task, task_id})
      assert_receive {:tasks_updated}, 1_000

      fetched = EvoGit.Store.get_task(EvoGit.Store, task_id)
      assert fetched.status == :completed
      assert fetched.branch_name == "evogit/orig"
    end

    test "reschedules while any sched_meta entry remains; resolves after cleanup" do
      unique = System.unique_integer([:positive])
      task_id = "recheck_active_#{unique}"

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil
        })

      # Seed an entry carrying a tagged-ok result (as the scheduler might leave
      # before recycling the entry). ANY remaining entry for the task means
      # "agents still active" (Lease.sched_meta_has_active_agents?/1) → the
      # recheck must reschedule, not resolve.
      meta = %EvoGit.AgentScheduler.SchedMeta{
        id: 1,
        depth: 0,
        spec: recheck_agent_spec(),
        task_id: task_id,
        parent_id: nil,
        status: :completed,
        sub_agent_results: %{"agent-1" => {:ok, %{branch_name: "feat/x", commit_sha: "abc"}}}
      }

      :ets.insert(:evogit_sched_meta, {1, meta})

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      send(EvoGit.TaskRegistry, {:recheck_task, task_id})
      refute_receive {:tasks_updated}, 200

      fetched = EvoGit.Store.get_task(EvoGit.Store, task_id)
      assert fetched.status == :running
      assert fetched.branch_name == nil

      # Once the entry is recycled (deleted), the next recheck resolves. The
      # result was lost with the entry, so the task is marked :completed with a
      # nil result and no branch_name.
      :ets.delete(:evogit_sched_meta, 1)
      send(EvoGit.TaskRegistry, {:recheck_task, task_id})
      assert_receive {:tasks_updated}, 1_000

      resolved = EvoGit.Store.get_task(EvoGit.Store, task_id)
      assert resolved.status == :completed
      assert resolved.result == nil
      assert resolved.branch_name == nil
    end

    test "branch_name is extracted from {:ok, %{branch_name: _}} results on the cast path" do
      unique = System.unique_integer([:positive])
      task_id = "recheck_cast_#{unique}"

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil
        })

      TaskRegistry.update_task_status(task_id, :completed, {:ok, %{branch_name: "feat/x"}},
        commit_sha: "abc"
      )

      # Sync with a call to ensure the cast was processed.
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :completed
      assert fetched.branch_name == "feat/x"
      assert fetched.commit_sha == "abc"
    end
  end

  describe "recent projects — nil last_opened_at handling" do
    test "nil last_opened_at rows are sorted last and never crash add/list", %{
      sqlite_path: sqlite_path
    } do
      unique = System.unique_integer([:positive])
      insert_project_row(sqlite_path, "/nil-proj-#{unique}", "Nil Proj", nil)

      :ok = TaskRegistry.add_recent_project("/fresh-#{unique}", "Fresh")

      projects = TaskRegistry.list_recent_projects()
      paths = Enum.map(projects, & &1.path)

      assert "/fresh-#{unique}" in paths
      assert "/nil-proj-#{unique}" in paths
      assert hd(projects).path == "/fresh-#{unique}"
      assert List.last(projects).path == "/nil-proj-#{unique}"
    end

    test "trim removes oldest dated rows (and nil rows) first, never crashes on nil",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      now = DateTime.utc_now()

      # @max_recent_projects is 10 (task_registry.ex); seed 10 dated rows plus
      # one nil row, then add one more → 12 rows → trim keeps the 10 newest.
      insert_project_row(sqlite_path, "/nil-proj-#{unique}", "Nil Proj", nil)

      for i <- 1..10 do
        :ok =
          EvoGit.Store.put_project(EvoGit.Store, %EvoGit.RecentProject{
            path: "/dated-#{unique}-#{i}",
            name: "D#{i}",
            last_opened_at: DateTime.add(now, -i * 86_400, :second)
          })
      end

      :ok = TaskRegistry.add_recent_project("/newest-#{unique}", "Newest")

      projects = TaskRegistry.list_recent_projects()
      assert length(projects) == 10

      # Sorted descending: newest first, then /dated-1..9. The oldest dated row
      # (/dated-10) and the nil row (sorts last = oldest) are trimmed.
      assert Enum.map(projects, & &1.path) ==
               ["/newest-#{unique}"] ++ Enum.map(1..9, &"/dated-#{unique}-#{&1}")
    end
  end

  describe "graceful cancel_task / force_kill_task" do
    test "graceful cancel from :running → :cancelling, agents notified, marker registered" do
      unique = System.unique_integer([:positive])
      task_id = "cancel_running_#{unique}"
      agent_id = System.unique_integer([:positive])

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      # Register one live agent for the task (scheduler ETS) so we can verify
      # the cancel notification + cancel_requested flag injection.
      :ets.insert(:evogit_sched_meta, {agent_id, cancel_test_sched_meta(agent_id, task_id)})
      :ets.insert(:evogit_agent_state, {agent_id, cancel_test_agent_state()})

      on_exit(fn ->
        :ets.delete(:evogit_sched_meta, agent_id)
        :ets.delete(:evogit_agent_state, agent_id)
        :ets.delete(:evogit_cancelling_tasks, task_id)
      end)

      assert :ok = TaskRegistry.cancel_task(task_id)

      # Status transitioned to :cancelling — non-terminal (finished_at stays nil).
      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :cancelling
      assert fetched.finished_at == nil

      # Agent received the cancel message + cancel_requested flag.
      [{^agent_id, st}] = :ets.lookup(:evogit_agent_state, agent_id)
      assert st.cancel_requested == true
      assert Enum.any?(st.pending_user_messages, &String.contains?(&1, "being cancelled"))

      # Task registered in the graceful-cancel marker.
      assert :ets.member(:evogit_cancelling_tasks, task_id)
    end

    test "cancel_task is idempotent on :cancelling — no duplicate messages" do
      unique = System.unique_integer([:positive])
      task_id = "cancel_idem_#{unique}"
      agent_id = System.unique_integer([:positive])

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :cancelling,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      :ets.insert(:evogit_sched_meta, {agent_id, cancel_test_sched_meta(agent_id, task_id)})
      :ets.insert(:evogit_agent_state, {agent_id, cancel_test_agent_state()})

      on_exit(fn ->
        :ets.delete(:evogit_sched_meta, agent_id)
        :ets.delete(:evogit_agent_state, agent_id)
        :ets.delete(:evogit_cancelling_tasks, task_id)
      end)

      # First cancel on an already-:cancelling task is a no-op (:ok, no message
      # re-send since the agents already hold the cancel message from the
      # original graceful-cancel request).
      assert :ok = TaskRegistry.cancel_task(task_id)
      assert :ok = TaskRegistry.cancel_task(task_id)

      [{^agent_id, st}] = :ets.lookup(:evogit_agent_state, agent_id)
      assert st.cancel_requested == true

      assert length(st.pending_user_messages) == 0,
             "idempotent cancel must NOT append the cancel message again, got #{inspect(st.pending_user_messages)}"

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :cancelling
    end

    test ":pending task is marked :cancelled immediately and start_task refuses it" do
      unique = System.unique_integer([:positive])
      task_id = "cancel_pending_#{unique}"

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :pending,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      assert :ok = TaskRegistry.cancel_task(task_id)

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :cancelled
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil

      # start_task guard: a :cancelled (or :cancelling) task must never start.
      state = :sys.get_state(EvoGit.TaskRegistry)

      assert {:reply, {:error, :cancelled}, ^state} =
               TaskRegistry.handle_call(
                 {:start_task, task_id, :genesis, [path: "/tmp/test"]},
                 {self(), make_ref()},
                 state
               )

      # Same guard for a :cancelling task.
      cancelling_id = "cancel_start_guard_#{unique}"

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: cancelling_id,
          type: :genesis,
          status: :cancelling,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil
        })

      assert {:reply, {:error, :cancelled}, ^state} =
               TaskRegistry.handle_call(
                 {:start_task, cancelling_id, :genesis, [path: "/tmp/test"]},
                 {self(), make_ref()},
                 state
               )
    end

    test "cancel_task returns {:error, :not_running} for terminal/:finalizing states and {:error, :not_found} for missing" do
      unique = System.unique_integer([:positive])

      for {status, idx} <- Enum.with_index([:completed, :failed, :cancelled, :finalizing]) do
        task_id = "cancel_invalid_#{unique}_#{idx}"

        :ok =
          EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
            id: task_id,
            type: :genesis,
            status: status,
            opts: [path: "/tmp/test"],
            ref: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil
          })

        assert {:error, :not_running} = TaskRegistry.cancel_task(task_id),
               "expected :not_running for #{status}"
      end

      assert {:error, :not_found} = TaskRegistry.cancel_task("cancel_missing_#{unique}")
    end

    test "a completing :cancelling task persists :cancelled with result preserved" do
      unique = System.unique_integer([:positive])
      task_id = "cancel_final_map_#{unique}"

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :cancelling,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      # Simulate the marker being registered by the earlier graceful cancel.
      :ets.insert(:evogit_cancelling_tasks, {task_id})
      on_exit(fn -> :ets.delete(:evogit_cancelling_tasks, task_id) end)

      # The wrapper completes during the grace period with an intermediate
      # result — handle_update_status must force-map :completed → :cancelled
      # while PRESERVING the result.
      TaskRegistry.update_task_status(task_id, :completed, {:ok, %{branch_name: "feat/x"}})

      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)

      assert fetched.status == :cancelled,
             "cancelling task must end :cancelled, got #{inspect(fetched.status)}"

      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil

      assert fetched.result == {:ok, %{branch_name: "feat/x"}},
             "result must be preserved, got #{inspect(fetched.result)}"

      # Terminal state cleaned up the marker.
      refute :ets.member(:evogit_cancelling_tasks, task_id)
    end

    test "a :finalizing broadcast does not clobber :cancelling" do
      unique = System.unique_integer([:positive])
      task_id = "cancel_finalizing_guard_#{unique}"

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :cancelling,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil
        })

      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_status, task_id, :finalizing})

      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)

      assert fetched.status == :cancelling,
             "a cancelling task reaching phase finalization must keep :cancelling, got #{inspect(fetched.status)}"
    end

    test "force_kill_task works from :running" do
      unique = System.unique_integer([:positive])
      task_id = "forcekill_running_#{unique}"
      wrapper = spawn(fn -> Process.sleep(:infinity) end)

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      # Make the task "owned": inject a live wrapper into task_refs.
      :sys.replace_state(EvoGit.TaskRegistry, fn state ->
        %{
          state
          | task_refs: Map.put(state.task_refs, task_id, cancel_test_task(wrapper))
        }
      end)

      assert :ok = TaskRegistry.force_kill_task(task_id)

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :cancelled
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil

      state = :sys.get_state(EvoGit.TaskRegistry)
      refute Map.has_key?(state.task_refs, task_id)
    end

    test "force_kill_task works from :cancelling (escalation path) and clears the marker" do
      unique = System.unique_integer([:positive])
      task_id = "forcekill_cancelling_#{unique}"
      wrapper = spawn(fn -> Process.sleep(:infinity) end)

      :ok =
        EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :cancelling,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      :ets.insert(:evogit_cancelling_tasks, {task_id})
      on_exit(fn -> :ets.delete(:evogit_cancelling_tasks, task_id) end)

      :sys.replace_state(EvoGit.TaskRegistry, fn state ->
        %{
          state
          | task_refs: Map.put(state.task_refs, task_id, cancel_test_task(wrapper))
        }
      end)

      assert :ok = TaskRegistry.force_kill_task(task_id)

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :cancelled
      assert fetched.finished_at != nil

      # The brutal path cleans up the graceful-cancel marker.
      refute :ets.member(:evogit_cancelling_tasks, task_id)

      state = :sys.get_state(EvoGit.TaskRegistry)
      refute Map.has_key?(state.task_refs, task_id)
    end

    test "force_kill_task returns {:error, :not_found} for an unknown task" do
      assert {:error, :not_found} =
               TaskRegistry.force_kill_task(
                 "forcekill_missing_#{System.unique_integer([:positive])}"
               )
    end
  end

  # --- Helpers ---

  # AgentSpec for the graceful-cancel agent-notification tests.
  defp cancel_test_agent_spec do
    %EvoGit.AgentSpec{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "/tmp/test"},
      phylo_node: %EvoGit.Core.PhyloGraphNode{
        repo: "/tmp/test",
        base_commit: "abc",
        current_commit: "abc"
      },
      agent_module: __MODULE__,
      objective: "test"
    }
  end

  # SchedMeta entry for a live agent of the given task.
  defp cancel_test_sched_meta(agent_id, task_id) do
    %EvoGit.AgentScheduler.SchedMeta{
      id: agent_id,
      depth: 0,
      spec: cancel_test_agent_spec(),
      retries: 0,
      task_id: task_id,
      from: {self(), make_ref()}
    }
  end

  # AgentState entry for a live agent.
  defp cancel_test_agent_state do
    %EvoGit.AgentScheduler.AgentState{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "/tmp/test"},
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8
    }
  end

  # A %Task{} wrapper entry for the task_refs map (content beyond pid is
  # irrelevant to the force-kill/heartbeat paths).
  defp cancel_test_task(pid) do
    %Task{
      pid: pid,
      ref: make_ref(),
      owner: self(),
      mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [:genesis, [], "test"]}
    }
  end

  # Overwrites the store-internal updated_at column with a fixed-precision ISO
  # string via a raw connection (the summary `since` filters compare strings).
  defp set_updated_at(sqlite_path, task_id, iso) do
    {:ok, raw_conn} = Xqlite.open(sqlite_path)

    {:ok, _} =
      XqliteNIF.execute(raw_conn, "UPDATE tasks SET updated_at = ?1 WHERE id = ?2", [
        iso,
        task_id
      ])

    XqliteNIF.close(raw_conn)
  end

  defp insert_project_row(sqlite_path, path, name, last_opened_at) do
    {:ok, raw_conn} = Xqlite.open(sqlite_path)

    {:ok, _} =
      XqliteNIF.execute(
        raw_conn,
        "INSERT INTO projects (path, name, last_opened_at) VALUES (?1, ?2, ?3)",
        [path, name, last_opened_at]
      )

    XqliteNIF.close(raw_conn)
  end

  defp recheck_agent_spec do
    %EvoGit.AgentSpec{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "/tmp/test"},
      phylo_node: %EvoGit.Core.PhyloGraphNode{
        repo: "/tmp/test",
        base_commit: "abc",
        current_commit: "abc"
      },
      agent_module: __MODULE__,
      objective: "test"
    }
  end
end
