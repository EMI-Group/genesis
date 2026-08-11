defmodule EvoGit.TaskRegistry.LeaseHeartbeatTest do
  use EvoGit.TaskRegistryCase, async: false

  describe "lease & heartbeat" do
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

      EvoGit.Store.put_task(EvoGit.Store, task)

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

      EvoGit.Store.put_task(EvoGit.Store, task)

      # Send a heartbeat message directly to the registry process.
      # After the refactor, heartbeat ONLY renews owned leases — it does NOT
      # sweep. So even an expired-lease unowned task must remain :running.
      send(EvoGit.TaskRegistry, :heartbeat)

      # Sync
      TaskRegistry.list_tasks()

      found = EvoGit.Store.get_task(EvoGit.Store, "lease_heartbeat_#{unique}")
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

      EvoGit.Store.put_task(EvoGit.Store, task)

      # Send a lease_sweep message directly to the registry process (one-shot).
      send(EvoGit.TaskRegistry, :lease_sweep)

      # Sync
      TaskRegistry.list_tasks()

      found = EvoGit.Store.get_task(EvoGit.Store, "lease_sweep_#{unique}")
      assert found != nil

      assert found.status == :failed,
             "task with expired lease should be swept to :failed, got #{inspect(found.status)}"

      assert found.lease_expires_at == nil
    end

    test "heartbeat renews the lease of an owned :cancelling task" do
      unique = System.unique_integer([:positive])
      task_id = "heartbeat_cancelling_#{unique}"
      expired = System.system_time(:second) - 300

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :cancelling,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: expired
      }

      EvoGit.Store.put_task(EvoGit.Store, task)

      # Make the task "owned" (in task_refs) so heartbeat renews its lease —
      # a long graceful cancel must keep its lease valid while the wrapper
      # is still alive. The %Task{} content is irrelevant to the heartbeat.
      :sys.replace_state(EvoGit.TaskRegistry, fn state ->
        %{
          state
          | task_refs:
              Map.put(
                state.task_refs,
                task_id,
                %Task{
                  pid: self(),
                  ref: make_ref(),
                  owner: self(),
                  mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [:genesis, [], task_id]}
                }
              )
        }
      end)

      send(EvoGit.TaskRegistry, :heartbeat)

      # Sync
      TaskRegistry.list_tasks()

      found = EvoGit.Store.get_task(EvoGit.Store, task_id)
      assert found != nil

      assert found.status == :cancelling,
             "heartbeat must not change the :cancelling status, got #{inspect(found.status)}"

      assert found.lease_expires_at > expired,
             "heartbeat should renew the lease of an owned :cancelling task, got #{inspect(found.lease_expires_at)}"
    end
  end
end
