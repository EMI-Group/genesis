defmodule EvoDash.TaskRegistry.ReconciliationTest do
  use EvoDash.TaskRegistryCase, async: false

  describe "restart reconciliation (normalize_tasks liveness check)" do
    # These tests verify that when the TaskRegistry GenServer restarts, running
    # tasks whose processes are still alive (registered in the ProcessRegistry
    # and under the sibling TaskSupervisor) are NOT marked failed — they are
    # re-monitored. Tasks with no live process and an expired lease are marked
    # failed. Tasks with no live process but active sched_meta agents stay
    # :running (same-VM recovery).

    test "a running task with a live PID survives a registry restart (stays :running)",
         %{data_dir: data_dir} do
      task_id = "restart_live_#{System.unique_integer([:positive])}"

      # Spawn a long-running process that stays alive (simulating a task worker
      # that outlives the registry restart). It registers itself in the Registry
      # so that reconcile_task_status finds it via Registry.lookup.
      {:ok, agent_pid} =
        Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
          Registry.register(EvoDash.TaskRegistry.ProcessRegistry, task_id, :task)
          Process.sleep(:infinity)
        end)

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

      # No process is spawned — there is no live process registered in the
      # Registry. The expired lease ensures that after Registry.lookup returns
      # [], the lease check fails and the task is marked :failed.
      task = %TaskInfo{
        id: task_id,
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

      # No live process is registered in the Registry. The expired lease
      # ensures the task is marked :failed after Registry.lookup returns [].
      task = %TaskInfo{
        id: task_id,
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

      # No process is spawned — there is no live process registered in the
      # Registry. The expired lease makes the lease check fail, but the ETS
      # sched_meta check below keeps the task :running (same-VM recovery).
      task = %TaskInfo{
        id: task_id,
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
      # It registers itself in the Registry so that reconcile_task_status finds
      # it via Registry.lookup and re-monitors it.
      {:ok, _agent_pid} =
        Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
          Registry.register(EvoDash.TaskRegistry.ProcessRegistry, task_id, :task)
          Process.sleep(50)
          :ok
        end)

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
      # It registers itself in the Registry so that reconcile_task_status finds
      # it via Registry.lookup and re-monitors it.
      {:ok, _agent_pid} =
        Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
          Registry.register(EvoDash.TaskRegistry.ProcessRegistry, task_id, :task)
          Process.sleep(50)
          exit(:boom)
        end)

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
end
