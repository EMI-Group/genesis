defmodule EvoGit.TaskBudget do
  @moduledoc "Task-scoped execution bounds, inherited by descendants and enforced before registration."
  @defaults %{
    "max_agents" => 6,
    "max_depth" => 2,
    "max_turns_root" => 96,
    "max_turns" => 64,
    "max_duration_seconds" => 2700
  }
  @ceilings %{
    "max_agents" => 1000,
    "max_depth" => 8,
    "max_turns_root" => 1000,
    "max_turns" => 1000,
    "max_duration_seconds" => 86400
  }
  def exhausted(agent_id, reason) do
    with {:ok, %{parent_id: nil, task_id: task_id}} <-
           EvoGit.AgentScheduler.Store.get_sched_meta(agent_id),
         {:ok, %{budget: budget}} when is_map(budget) <-
           EvoGit.AgentScheduler.Store.get_agent_state(agent_id) do
      mark_task_exhausted(task_id, reason)
    else
      _ -> :ok
    end
  end

  def mark_task_exhausted(task_id, reason) do
    EvoGit.TaskRegistry.StoreGuard.write("task_budget_exhausted", fn ->
      EvoGit.Store.update_task_columns(EvoGit.TaskRegistry.task_store(), task_id,
        error: EvoGit.TaskRegistry.Diagnostics.failure_error(:timeout, :task_budget, reason)
      )
    end)
  end

  def defaults, do: @defaults
  def normalize(nil), do: {:ok, @defaults}

  def normalize(values) when is_map(values) do
    values = Map.new(values, fn {k, v} -> {to_string(k), v} end)

    if Enum.all?(values, fn {k, v} ->
         is_integer(v) and v > 0 and Map.has_key?(@ceilings, k) and v <= @ceilings[k]
       end), do: {:ok, Map.merge(@defaults, values)}, else: {:error, :invalid_budget}
  end

  def normalize(_), do: {:error, :invalid_budget}

  def admit(opts) do
    if Keyword.has_key?(opts, :budget) do
      with {:ok, budget} <- normalize(opts[:budget]),
           do: {:ok, Keyword.put(opts, :budget, budget)}
    else
      {:ok, opts}
    end
  end

  def inherited(spec, nil), do: Keyword.get(spec.opts, :budget)

  def inherited(_spec, parent_id) do
    case EvoGit.AgentScheduler.Store.get_agent_state(parent_id) do
      {:ok, parent} -> Map.get(parent, :budget)
      _ -> nil
    end
  end

  def check(nil, _count, _depth), do: :ok

  def check(budget, count, depth) do
    cond do
      count >= budget["max_agents"] -> {:error, :task_agent_budget_exhausted}
      depth > budget["max_depth"] -> {:error, :task_depth_budget_exhausted}
      true -> :ok
    end
  end

  def cap(nil, _key, existing), do: existing
  def cap(budget, key, existing), do: min(budget[key], existing)
end
