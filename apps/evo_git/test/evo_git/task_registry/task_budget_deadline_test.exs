defmodule EvoGit.TaskRegistry.TaskBudgetDeadlineTest do
  use EvoGit.TaskRegistryCase, async: true

  test "budget recovery cannot label a partial result successful" do
    id = "partial-budget"

    error =
      EvoGit.TaskRegistry.Diagnostics.failure_error(
        :timeout,
        :task_budget,
        "Root turn budget exhausted"
      )

    :ok =
      EvoGit.Store.put_task(store(), %TaskInfo{
        id: id,
        type: :evolve,
        status: :running,
        opts: [],
        error: error
      })

    TaskRegistry.update_task_status(
      id,
      :completed,
      {:ok, %{result: "Partial work", branch_name: "genesis/partial"}}
    )

    task = TaskRegistry.get_task(id)
    assert task.status == :failed
    assert task.branch_name == "genesis/partial"
    assert task.error.source == :task_budget
  end

  test "time budget also bounds finalization" do
    id = "finalizing-budget"

    :ok =
      EvoGit.Store.put_task(store(), %TaskInfo{
        id: id,
        type: :evolve,
        status: :finalizing,
        opts: [budget: %{"max_duration_seconds" => 1}],
        started_at: DateTime.utc_now()
      })

    registry = TaskRegistry.server()

    :sys.replace_state(registry, fn state ->
      ref =
        Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, fn -> receive do: (:finish -> :ok) end)

      %{state | task_refs: Map.put(state.task_refs, id, ref)}
    end)

    send(registry, {:task_budget_deadline, id})
    assert TaskRegistry.get_task(id).error.source == :task_budget
    send(registry, {:task_budget_escalate, id})
    assert TaskRegistry.get_task(id).status == :failed
    assert TaskRegistry.get_task(id).error.source == :task_budget
  end

  test "deadline cancels, escalation terminates the wrapper, and terminal timers are harmless" do
    id = "budget-deadline"

    :ok =
      EvoGit.Store.put_task(store(), %TaskInfo{
        id: id,
        type: :evolve,
        status: :running,
        opts: [budget: %{"max_duration_seconds" => 1}],
        started_at: DateTime.utc_now()
      })

    registry = TaskRegistry.server()

    :sys.replace_state(registry, fn state ->
      ref =
        Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, fn -> receive do: (:finish -> :ok) end)

      %{state | task_refs: Map.put(state.task_refs, id, ref)}
    end)

    send(registry, {:task_budget_deadline, id})
    assert TaskRegistry.get_task(id).status == :cancelling
    assert TaskRegistry.get_task(id).error.source == :task_budget
    send(registry, {:task_budget_escalate, id})
    assert TaskRegistry.get_task(id).status == :failed
    assert TaskRegistry.get_task(id).error.source == :task_budget
    {:ok, observed} = EvoGit.TaskControl.get(%{"task_id" => id})
    assert observed.error.source == :task_budget
    send(registry, {:task_budget_deadline, id})
    assert TaskRegistry.get_task(id).status == :failed
  end

  test "duration deadline still schedules escalation after an early graceful cancellation" do
    id = "already-cancelling-budget"

    :ok =
      EvoGit.Store.put_task(store(), %TaskInfo{
        id: id,
        type: :evolve,
        status: :cancelling,
        opts: [budget: %{"max_duration_seconds" => 1}],
        started_at: DateTime.utc_now()
      })

    registry = TaskRegistry.server()

    :sys.replace_state(registry, fn state ->
      ref =
        Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, fn -> receive do: (:finish -> :ok) end)

      %{state | task_refs: Map.put(state.task_refs, id, ref)}
    end)

    send(registry, {:task_budget_deadline, id})
    assert TaskRegistry.get_task(id).error.source == :task_budget
    # Deliver the already scheduled timeout immediately, rather than sleep for 60s.
    send(registry, {:task_budget_escalate, id})
    assert TaskRegistry.get_task(id).status == :failed
    assert TaskRegistry.get_task(id).error.source == :task_budget
    refute Map.has_key?(:sys.get_state(registry).task_refs, id)
  end
end
