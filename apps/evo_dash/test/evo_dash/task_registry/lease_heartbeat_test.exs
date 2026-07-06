defmodule EvoDash.TaskRegistry.LeaseHeartbeatTest do
  use EvoDash.TaskRegistryCase, async: false

  describe "lease & heartbeat" do
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

    test "heartbeat does NOT sweep expired-lease unowned tasks (renewal only)" do
      unique = System.unique_integer([:positive])

      # Insert a running task with an EXPIRED lease, no pid, not owned.
      expired = System.system_time(:second) - 300
      task = %TaskInfo{
        id: "lease_heartbeat_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: expired
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # Send a heartbeat message directly to the registry process.
      # After the refactor, heartbeat ONLY renews owned leases — it does NOT
      # sweep. So even an expired-lease unowned task must remain :running.
      send(EvoDash.TaskRegistry, :heartbeat)

      # Sync
      TaskRegistry.list_tasks()

      found = EvoDash.Store.get_task(EvoDash.Store, "lease_heartbeat_#{unique}")
      assert found != nil
      # Lease unchanged and task still :running (no sweep on heartbeat).
      assert found.status == :running,
             "heartbeat should NOT sweep expired-lease tasks (sweep is now :lease_sweep), got #{inspect(found.status)}"

      assert found.lease_expires_at == expired,
             "heartbeat should not modify unowned task's lease"
    end

    test "lease_sweep sweeps expired-lease running tasks we don't own" do
      unique = System.unique_integer([:positive])

      # Insert a running task with an expired lease, no pid, not owned.
      task = %TaskInfo{
        id: "lease_sweep_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: System.system_time(:second) - 300
      }

      EvoDash.Store.put_task(EvoDash.Store, task)

      # Send a lease_sweep message directly to the registry process (one-shot).
      send(EvoDash.TaskRegistry, :lease_sweep)

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
