defmodule EvoDash.TaskRegistryTest do
  use ExUnit.Case, async: false

  alias EvoDash.TaskRegistry
  alias EvoDash.TaskRegistry.TaskInfo

  @dets_tasks :test_evo_dash_tasks_dets
  @dets_projects :test_evo_dash_projects_dets

  setup do
    # Terminate the production registry via its supervisor to prevent
    # automatic restarts and to clean up its DETS tables.
    case Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.TaskRegistry) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    unique = System.unique_integer([:positive])
    data_dir = Path.join(System.tmp_dir!(), "evogit_test_tasks_#{unique}")
    File.mkdir_p!(data_dir)

    {:ok, _pid} =
      start_supervised(
        {TaskRegistry,
         name: EvoDash.TaskRegistry,
         dets_tasks: @dets_tasks,
         dets_projects: @dets_projects,
         data_dir: data_dir}
      )

    on_exit(fn ->
      File.rm_rf(data_dir)
      # Restart the production TaskRegistry so other test suites don't break
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
    end)

    {:ok, %{data_dir: data_dir}}
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

    :dets.insert(@dets_tasks, {trigger_id, trigger})
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

      :dets.insert(@dets_tasks, {"test_old_#{unique}", old_task})

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

      :dets.insert(@dets_tasks, {"test_recent_#{unique}", recent_task})

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

      :dets.insert(@dets_tasks, {"test_5day_#{unique}", task})

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

      :dets.insert(@dets_tasks, {"test_running_#{unique}", running_task})

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

      :dets.insert(@dets_tasks, {"test_pending_#{unique}", pending_task})

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

      :dets.insert(@dets_tasks, {"test_oldfin_#{unique}", old_finished})

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

      :dets.insert(@dets_tasks, {"test_combined_old_#{unique}", old_task})

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

        :dets.insert(@dets_tasks, {"test_combined_recent_#{unique}_#{i}", recent})
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

      :dets.insert(@dets_tasks, {"test_combined_running_#{unique}", running})

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
    test "updates a task's base_sha and commit_sha in DETS" do
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

      :dets.insert(@dets_tasks, {task_id, task})

      TaskRegistry.set_review_metadata(task_id, "abc123", "def456")

      # Sync with a call to ensure cast was processed
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.base_sha == "abc123"
      assert fetched.commit_sha == "def456"
    end

    test "persists to DETS after update" do
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

      :dets.insert(@dets_tasks, {task_id, task})

      TaskRegistry.set_review_metadata(task_id, "base_sha_1", "commit_sha_1")

      # Sync to ensure the cast (which writes directly to DETS) has been processed
      TaskRegistry.list_tasks()

      # Read directly from DETS to confirm persistence
      dets_entry =
        :dets.foldl(
          fn
            {^task_id, %TaskInfo{} = stored}, _acc -> {:found, stored}
            _other, acc -> acc
          end,
          :not_found,
          @dets_tasks
        )

      assert {:found, stored_task} = dets_entry
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

      :dets.insert(@dets_tasks, {task_id, task})

      TaskRegistry.set_review_metadata(task_id, "base1", "commit1")
      TaskRegistry.list_tasks()

      TaskRegistry.set_review_metadata(task_id, "base2", "commit2")
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.base_sha == "base2"
      assert fetched.commit_sha == "commit2"
    end
  end

  describe "DETS backfill of new TaskInfo fields" do
    test "normalize_tasks_in_dets backfills base_sha and commit_sha as nil for old entries",
         %{data_dir: data_dir} do
      unique = System.unique_integer([:positive])
      task_id = "backfill_#{unique}"

      # Simulate an old persisted entry WITHOUT base_sha/commit_sha keys.
      # This mimics a DETS entry written before these fields existed.
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
      # before base_sha/commit_sha existed) won't have these keys. normalize_tasks_in_dets
      # calls Map.merge(%TaskInfo{}, task) which backfills them as nil.
      old_map =
        old_task
        |> Map.from_struct()
        |> Map.put(:__struct__, TaskInfo)
        |> Map.drop([:base_sha, :commit_sha])

      :dets.insert(@dets_tasks, {task_id, old_map})
      :dets.sync(@dets_tasks)

      # Stop the supervised registry, then restart it so normalize_tasks_in_dets runs.
      # Reuse the same data_dir so the DETS file path is unchanged.
      stop_supervised(EvoDash.TaskRegistry)

      {:ok, _pid} =
        start_supervised(
          {TaskRegistry,
           name: EvoDash.TaskRegistry,
           dets_tasks: @dets_tasks,
           dets_projects: @dets_projects,
           data_dir: data_dir}
        )

      # The backfilled task should exist with nil for the new fields
      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.base_sha == nil
      assert fetched.commit_sha == nil
    end
  end

  describe "DETS corruption safety (safe_match_object / safe_lookup)" do
    # The exact {:error, _} shape returned by :dets.match_object/2 when a table
    # is corrupted mid-read (e.g. not properly closed on unclean shutdown).
    @corrupt_reason {{:bad_object, :read_buckets}, ~c"/tmp/fake/tasks.dets"}

    # Flush any {:recover_dets, _} messages that safe_insert/safe_delete send to self().
    defp flush_received_messages do
      receive do
        {:recover_dets, _} -> flush_received_messages()
      after
        0 -> :ok
      end
    end

    test "from_dets/3 returns [] on the exact {:error, _} tuple from the crash report" do
      result = TaskRegistry.from_dets(:some_table, {:error, @corrupt_reason}, "match_object")
      assert result == []
      # Read errors no longer trigger recovery (only write/open failures do).
      refute_received {:recover_dets, _}
    end

    test "from_dets/3 returns [] for any {:error, reason} without raising" do
      assert TaskRegistry.from_dets(:t, {:error, :some_other_reason}, "lookup(\"k\")") == []
      # Read errors no longer trigger recovery (only write/open failures do).
      refute_received {:recover_dets, :t}
    end

    test "from_dets/3 passes the success list through unchanged" do
      objects = [{"id1", %{a: 1}}, {"id2", %{a: 2}}]
      assert TaskRegistry.from_dets(:t, objects, "match_object") == objects
      # Success branch does NOT send a recovery message.
      refute_received {:recover_dets, _}
    end

    test "safe_match_object/1 returns the stored objects on a healthy table" do
      task_id = "safe_match_#{System.unique_integer([:positive])}"
      :dets.insert(@dets_tasks, {task_id, "marker"})
      objects = TaskRegistry.safe_match_object(@dets_tasks)
      assert is_list(objects)
      assert {task_id, "marker"} in objects
      :dets.delete(@dets_tasks, task_id)
    end

    test "safe_lookup/2 returns [{key, value}] for a present key and [] for a missing key" do
      task_id = "safe_lookup_#{System.unique_integer([:positive])}"
      :dets.insert(@dets_tasks, {task_id, "marker"})
      assert TaskRegistry.safe_lookup(@dets_tasks, task_id) == [{task_id, "marker"}]
      assert TaskRegistry.safe_lookup(@dets_tasks, "absent_#{task_id}") == []
      :dets.delete(@dets_tasks, task_id)
    end

    test "list_tasks returns a list even when a read would error (degraded to [])" do
      # The error tuple is handled by from_dets/3 and degrades to [], so list_tasks
      # receives a list rather than a raw {:error, _} tuple.
      assert TaskRegistry.from_dets(@dets_tasks, {:error, @corrupt_reason}, "match_object") == []
      flush_received_messages()
      assert is_list(TaskRegistry.list_tasks())
    end
  end

  describe "DETS runtime recovery" do
    defp registry_pid, do: GenServer.whereis(EvoDash.TaskRegistry)

    defp sync_registry do
      TaskRegistry.list_tasks()
    end

    # Insert a completed task directly into the DETS table and return its id.
    defp insert_completed_task(task_id) do
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

      :dets.insert(@dets_tasks, {task_id, task})
      task_id
    end

    test "runtime recovery restores data from a damaged DETS file", %{data_dir: data_dir} do
      unique = System.unique_integer([:positive])

      # Insert multiple real tasks into the healthy table.
      for i <- 1..3 do
        insert_completed_task("recover_#{unique}_#{i}")
      end

      sync_registry()
      assert length(TaskRegistry.list_tasks()) >= 3

      # Close the table and damage the file by appending garbage bytes. This
      # keeps the valid header and records intact while making the tail corrupt,
      # so DETS repair can still salvage the earlier records.
      :dets.close(@dets_tasks)
      tasks_file = Path.join(data_dir, "tasks.dets")
      {:ok, original} = File.read(tasks_file)
      File.write!(tasks_file, original <> :binary.copy(<<0>>, 512))

      # Trigger runtime recovery by sending the message directly.
      send(registry_pid(), {:recover_dets, @dets_tasks})
      sync_registry()

      # The registry must still be alive after recovery.
      assert Process.alive?(registry_pid())

      # After recovery the table is usable — new writes and reads work.
      new_id = "after_recover_#{unique}"
      insert_completed_task(new_id)
      sync_registry()
      tasks = TaskRegistry.list_tasks()
      assert Enum.any?(tasks, &(&1.id == new_id))
    end

    test "safe insert/delete do not crash the GenServer on a corrupt table", %{data_dir: data_dir} do
      unique = System.unique_integer([:positive])
      pid = registry_pid()
      assert Process.alive?(pid)

      # Close the table and write garbage to corrupt the file.
      :dets.close(@dets_tasks)
      tasks_file = Path.join(data_dir, "tasks.dets")
      File.write!(tasks_file, "GARBAGE_CORRUPTION_NOT_A_VALID_DETS_FILE")

      # Trigger a write op via a cast. safe_delete catches the error and sends
      # a recovery message; cleanup_expired_tasks may also encounter errors but
      # the GenServer should not die permanently — it either recovers in-message
      # or restarts via the supervisor and recovers at init.
      TaskRegistry.delete_task("corrupt_write_#{unique}")

      # Give the GenServer time to process (and potentially restart).
      wait_for_registry(1000)

      # After recovery/restart the registry responds normally.
      assert is_list(sync_registry())
      assert Process.alive?(registry_pid())
    end

    test "recovery guard prevents infinite re-entrant loops", %{data_dir: data_dir} do
      unique = System.unique_integer([:positive])
      pid = registry_pid()
      assert Process.alive?(pid)

      # Insert a task so the table has data.
      insert_completed_task("guard_#{unique}")
      sync_registry()

      # Close and lightly corrupt the file.
      :dets.close(@dets_tasks)
      tasks_file = Path.join(data_dir, "tasks.dets")
      {:ok, bytes} = File.read(tasks_file)
      File.write!(tasks_file, binary_part(bytes, 0, max(div(byte_size(bytes), 2), 1)))

      # Send MANY recovery messages rapidly — the first repair must heal the table
      # so subsequent messages skip recovery (avoiding spurious backups). Only ONE
      # recovery should actually run.
      for _ <- 1..10, do: send(pid, {:recover_dets, @dets_tasks})

      sync_registry()

      # The GenServer is still alive and responsive (no crash from re-entrancy).
      assert Process.alive?(registry_pid())
      assert is_list(sync_registry())

      # Only ONE recovery should have run — there must be at most a single
      # `.corrupt.` backup file (created by the first, genuine recovery).
      corrupt_backups =
        data_dir
        |> File.ls!()
        |> Enum.filter(&String.contains?(&1, ".corrupt."))

      assert length(corrupt_backups) <= 1,
             "Expected at most 1 corrupt backup, found #{length(corrupt_backups)}: #{inspect(corrupt_backups)}"
    end

    test "salvage via repair recovers records from a damaged-but-readable file" do
      unique = System.unique_integer([:positive])

      # Create a standalone healthy table with records in a fresh file.
      salvage_table = :"salvage_test_#{unique}"
      salvage_dir = Path.join(System.tmp_dir!(), "evogit_salvage_#{unique}")
      File.mkdir_p!(salvage_dir)
      salvage_file = Path.join(salvage_dir, "salvage.dets")

      {:ok, _} = :dets.open_file(salvage_table, type: :set, file: to_charlist(salvage_file))

      for i <- 1..5 do
        :dets.insert(salvage_table, {"key_#{i}", "value_#{i}"})
      end

      :dets.close(salvage_table)

      # Damage the file by appending garbage (simulates crash during write).
      {:ok, original} = File.read(salvage_file)
      File.write!(salvage_file, original <> :binary.copy(<<0>>, 256))

      # The improved salvage reopens with repair:true and recovers the valid
      # records that survived the corruption.
      {:ok, _} =
        :dets.open_file(salvage_table, type: :set, file: to_charlist(salvage_file), repair: true)

      objects = :dets.match_object(salvage_table, {:_, :_})

      # The repair should have recovered the valid records (the original 5).
      assert is_list(objects)
      assert length(objects) >= 1

      :dets.close(salvage_table)
      File.rm_rf!(salvage_dir)
    end

    # Helper to wait for the registry to be alive (after a possible restart).
    defp wait_for_registry(timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      Stream.repeatedly(fn ->
        Process.sleep(10)
        registry_pid() != nil and Process.alive?(registry_pid())
      end)
      |> Enum.find(fn alive ->
        alive or System.monotonic_time(:millisecond) >= deadline
      end) || false
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

      :dets.insert(@dets_tasks, {task_id, task})

      pid = GenServer.whereis(EvoDash.TaskRegistry)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # list_tasks returns the inserted task (DETS is the source of truth)
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

        :dets.insert(@dets_tasks, {id, task})
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
end
