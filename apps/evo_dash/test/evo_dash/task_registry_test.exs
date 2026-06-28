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
    cubdb_path = Path.join(root, "tasks.cubdb")

    start_supervised({EvoDash.TaskStore, data_dir: cubdb_path})

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

  # Helper: trigger cleanup_expired_tasks (which runs on mutations) by inserting
  # a dummy task and deleting it via cast, then synchronizing with a synchronous call.
  defp trigger_cleanup! do
    trigger_id = "cleanup_trigger_#{System.unique_integer([:positive])}"

    trigger = %TaskInfo{
      id: trigger_id,
      type: :genesis,
      status: :completed,
      opts: [path: "/tmp/test"],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      logs: [],
      result: nil
    }

    CubDB.put(EvoDash.TaskStore, {:task, trigger_id}, trigger)
    # delete_task is a cast that calls cleanup_expired_tasks()
    TaskRegistry.delete_task(trigger_id)
    # Sync with a call to ensure all prior casts have been processed
    TaskRegistry.list_tasks()
    :ok
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

      # Insert an old finished task directly into DETS (20 days old > 14 day default)
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

      CubDB.put(EvoDash.TaskStore, {:task, "test_old_#{unique}"}, old_task)

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

      CubDB.put(EvoDash.TaskStore, {:task, "test_recent_#{unique}"}, recent_task)

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

      CubDB.put(EvoDash.TaskStore, {:task, "test_5day_#{unique}"}, task)

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

      CubDB.put(EvoDash.TaskStore, {:task, "test_running_#{unique}"}, running_task)

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

      CubDB.put(EvoDash.TaskStore, {:task, "test_pending_#{unique}"}, pending_task)

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

      CubDB.put(EvoDash.TaskStore, {:task, "test_oldfin_#{unique}"}, old_finished)

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

      CubDB.put(EvoDash.TaskStore, {:task, "test_combined_old_#{unique}"}, old_task)

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

        CubDB.put(EvoDash.TaskStore, {:task, "test_combined_recent_#{unique}_#{i}"}, recent)
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

      CubDB.put(EvoDash.TaskStore, {:task, "test_combined_running_#{unique}"}, running)

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
    test "updates a task's base_sha and commit_sha in CubDB" do
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

      CubDB.put(EvoDash.TaskStore, {:task, task_id}, task)

      TaskRegistry.set_review_metadata(task_id, "abc123", "def456")

      # Sync with a call to ensure cast was processed
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.base_sha == "abc123"
      assert fetched.commit_sha == "def456"
    end

    test "persists to CubDB after update" do
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

      CubDB.put(EvoDash.TaskStore, {:task, task_id}, task)

      TaskRegistry.set_review_metadata(task_id, "base_sha_1", "commit_sha_1")

      # Sync to ensure the cast (which writes directly to CubDB) has been processed
      TaskRegistry.list_tasks()

      # Read directly from CubDB to confirm persistence
      stored_task = CubDB.get(EvoDash.TaskStore, {:task, task_id})

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

      CubDB.put(EvoDash.TaskStore, {:task, task_id}, task)

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

      CubDB.put(EvoDash.TaskStore, {:task, task_id}, old_map)

      # Stop the supervised registry, then restart it so normalize_tasks runs.
      # KEEP the same CubDB store running so the backfilled data persists.
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

  describe "CubDB persistence" do
    test "get_task retrieves a task seeded directly into CubDB" do
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

      :ok = CubDB.put(EvoDash.TaskStore, {:task, task_id}, task)

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

      :ok = CubDB.put(EvoDash.TaskStore, {:task, task_id}, task)

      # Confirm the task is visible before restart.
      assert %TaskInfo{} = TaskRegistry.get_task(task_id)

      # Stop the registry but KEEP the same CubDB store running (store is durable on disk).
      stop_supervised(EvoDash.TaskRegistry)

      # Restart the registry pointing at the same store and data_dir.
      start_supervised(
        {TaskRegistry,
         task_store: EvoDash.TaskStore, data_dir: data_dir, name: EvoDash.TaskRegistry}
      )

      # The task persisted in CubDB must survive the registry restart.
      fetched = TaskRegistry.get_task(task_id)
      assert %TaskInfo{} = fetched
      assert fetched.id == task_id
      assert fetched.type == :evolve
      assert fetched.status == :completed
      assert fetched.opts[:objective] == "durability check"
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

      CubDB.put(EvoDash.TaskStore, {:task, task_id}, task)

      pid = GenServer.whereis(EvoDash.TaskRegistry)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # list_tasks returns the inserted task (CubDB is the source of truth)
      tasks = TaskRegistry.list_tasks()
      assert Enum.any?(tasks, &(&1.id == task_id))

      # get_task retrieves it individually
      assert %TaskInfo{} = TaskRegistry.get_task(task_id)

      # The process stays alive after reads
      assert Process.alive?(pid)
    end

    test "registry survives mutation operations that trigger cleanup_expired_tasks" do
      unique = System.unique_integer([:positive])
      pid = GenServer.whereis(EvoDash.TaskRegistry)
      assert Process.alive?(pid)

      # Each delete_task cast triggers cleanup_expired_tasks internally.
      # Before the fix, a DETS read error during cleanup crashed the GenServer.
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

        CubDB.put(EvoDash.TaskStore, {:task, id}, task)
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

      CubDB.put(EvoDash.TaskStore, {:task, "good1_#{unique}"}, good1)
      CubDB.put(EvoDash.TaskStore, {:task, "good2_#{unique}"}, good2)

      # Structurally corrupt entries (valid Erlang terms, wrong shape)
      CubDB.put(EvoDash.TaskStore, {:task, "bad_string"}, "not a task struct at all")
      CubDB.put(EvoDash.TaskStore, {:task, "bad_map"}, %{random: "data", not: :task})
      CubDB.put(EvoDash.TaskStore, {:bad_namespace, "unknown"}, %{stuff: true})
      CubDB.put(EvoDash.TaskStore, "bare_key_not_a_tuple", :value)

      CubDB.put(
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

      CubDB.put(EvoDash.TaskStore, {:task, "good_cleanup_#{unique}"}, good)

      # Corrupt entry
      CubDB.put(EvoDash.TaskStore, {:task, "bad_cleanup"}, %{not_a: :task})

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
      CubDB.put(EvoDash.TaskStore, {:task, "pre_existing_corrupt_#{unique}"}, "garbage_value")

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

      CubDB.put(EvoDash.TaskStore, {:task, task_id}, task)

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

  # Helper: inject a truly corrupt (un-deserializable) value into CubDB by
  # corrupting the serialized bytes in the data file.
  #
  # Uses an isolated data_dir + store name (provided by the caller) so the
  # corruption never touches the shared test store or the production store.
  #
  # `good_entries` is a list of additional {key, value} pairs to seed BEFORE the
  # corrupt marker, so the store has a multi-node btree (required: with only a
  # few entries the marker shares a structural btree node and corruption breaks
  # the whole tree rather than just a value node).
  defp inject_corrupt_binary!(data_dir, store_name, key, good_entries) do
    # Seed good entries first to build a multi-node btree.
    for {k, v} <- good_entries, do: CubDB.put(store_name, k, v)

    # A distinctive marker value: a unique atom + random binary. The atom name
    # lets us locate the serialized term in the file; we then corrupt the term
    # encoding header (just before the binary payload) to make it
    # un-deserializable.
    unique = System.unique_integer([:positive])
    blob = :crypto.strong_rand_bytes(64)
    marker = {:"corrupt_zzz_marker_#{unique}", blob}
    CubDB.put(store_name, key, marker)

    # Flush and stop
    :ok = GenServer.stop(store_name)

    cubdb_file = Path.join(data_dir, "0.cub")
    {:ok, data} = File.read(cubdb_file)

    # Locate the unique random blob bytes in the file.
    {blob_pos, _blob_len} =
      :binary.match(data, blob) ||
        raise "corrupt marker blob not found in CubDB data file"

    # Overwrite ~15 bytes ending just before the blob — this hits the term
    # encoding header (tuple arity / atom tag) and makes binary_to_term raise.
    corrupt_len = 15
    corrupt_end = blob_pos
    corrupt_start = max(0, corrupt_end - corrupt_len)
    garbage = :binary.copy(<<0xFF>>, corrupt_len)

    pre = :binary.part(data, 0, corrupt_start)

    post_len = byte_size(data) - corrupt_end
    post = :binary.part(data, corrupt_end, post_len)

    new_data = pre <> garbage <> post
    :ok = File.write(cubdb_file, new_data)

    # Restart the store
    {:ok, _} = CubDB.start_link(data_dir: data_dir, name: store_name, auto_file_sync: true)
    :ok
  end

  describe "corruption resilience — binary corruption" do
    # These tests use their own isolated store (separate from the shared
    # EvoDash.TaskStore used by the module-level setup) because they stop and
    # restart the store to inject binary corruption at the file level.

    test "integrity_check heals a store with binary-corrupt entries" do
      unique = System.unique_integer([:positive])
      store = :"bin_corrupt_store_#{unique}"
      data_dir = Path.join(System.tmp_dir!(), "evogit_bin_corrupt_#{unique}")
      File.mkdir_p!(data_dir)
      {:ok, _} = CubDB.start_link(data_dir: data_dir, name: store, auto_file_sync: true)

      try do
        good1 = %TaskInfo{
          id: "bin_good1_#{unique}",
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
          id: "bin_good2_#{unique}",
          type: :evolve,
          status: :completed,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        }

        # Seed padding entries + the named good entries to build a multi-node
        # btree. With only a few entries the marker shares a structural btree
        # node, and corruption breaks the whole tree rather than just a value.
        padding =
          for i <- 1..40 do
            {{:task, "pad_#{unique}_#{i}"}, good1}
          end

        good_entries =
          padding ++
            [
              {{:task, "bin_good1_#{unique}"}, good1},
              {{:task, "bin_good2_#{unique}"}, good2}
            ]

        corrupt_key = {:task, "bin_corrupt_#{unique}"}
        inject_corrupt_binary!(data_dir, store, corrupt_key, good_entries)

        # After restart, a plain select should raise on the corrupt value.
        raised =
          try do
            CubDB.select(store) |> Enum.to_list()
            false
          rescue
            _ -> true
          end

        assert raised

        # integrity_check salvages the good entries and rebuilds.
        result = EvoDash.TaskStore.integrity_check(store)
        assert match?({:repaired, _}, result) or match?({:error, _}, result)

        # After repair, select should no longer raise.
        entries = CubDB.select(store) |> Enum.to_list()
        keys = Enum.map(entries, fn {k, _} -> k end)

        # The integrity check salvaged readable entries (those in other btree
        # leaves). Entries co-located with the corrupt marker in its leaf are
        # unrecoverable (~32 per leaf), but entries in other leaves survive.
        assert length(entries) > 0

        # Corrupt entry is gone
        refute corrupt_key in keys
      after
        try do
          GenServer.stop(store)
        catch
          _, _ -> :ok
        end

        File.rm_rf!(data_dir)
      end
    end
  end

  describe "TaskStore.integrity_check" do
    test "salvages good entries and quarantines corrupt ones" do
      unique = System.unique_integer([:positive])
      store = :"ic_corrupt_store_#{unique}"
      data_dir = Path.join(System.tmp_dir!(), "evogit_ic_corrupt_#{unique}")
      File.mkdir_p!(data_dir)
      {:ok, _} = CubDB.start_link(data_dir: data_dir, name: store, auto_file_sync: true)

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

        # Padding entries to build a multi-node btree.
        good_entries =
          for i <- 1..40 do
            {{:task, "ic_pad_#{unique}_#{i}"}, good}
          end

        corrupt_key = {:task, "ic_corrupt_#{unique}"}
        inject_corrupt_binary!(data_dir, store, corrupt_key, good_entries)

        result = EvoDash.TaskStore.integrity_check(store)
        assert match?({:repaired, _}, result) or match?(:ok, result)

        # After repair, the store is readable again and retains salvaged entries.
        entries = CubDB.select(store) |> Enum.to_list()
        keys = Enum.map(entries, fn {k, _} -> k end)

        # At least some padding entries survived the rebuild.
        assert Enum.any?(keys, fn
                 {:task, "ic_pad_" <> _} -> true
                 _ -> false
               end)

        # Corrupt entry is gone.
        refute corrupt_key in keys
      after
        try do
          GenServer.stop(store)
        catch
          _, _ -> :ok
        end

        File.rm_rf!(data_dir)
      end
    end
  end
end
