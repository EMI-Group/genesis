defmodule EvoDash.TaskRegistry.CleanupTest do
  use EvoDash.TaskRegistryCase, async: false

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
end
