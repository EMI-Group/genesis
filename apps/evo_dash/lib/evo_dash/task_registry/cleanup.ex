defmodule EvoDash.TaskRegistry.Cleanup do
  @moduledoc """
  Cleanup logic for `EvoDash.TaskRegistry`.

  Handles expiry of finished tasks based on configurable age and count limits.
  """

  @doc """
  Reads the task history configuration from `EvoGit.Config`, merging with
  defaults: `max_tasks: 100`, `max_age_days: 14`.
  """
  def task_history_config do
    defaults = %{max_tasks: 100, max_age_days: 14}
    config = EvoGit.Config.resolve()[:task_history] || %{}
    Map.merge(defaults, config)
  end

  @doc """
  Removes finished tasks that exceed the configured age or count limits.

  Accepts a `task_store` name/pid (e.g. `EvoDash.Store`) and scans all tasks
  via `EvoDash.Store.safe_select_all_tasks/1`. Age-expired finished tasks and
  over-limit finished tasks (keeping only the newest `max_tasks`) are batched
  and deleted.
  """
  def cleanup_expired_tasks(task_store) do
    config = task_history_config()
    max_age_days = config.max_age_days
    max_tasks = config.max_tasks
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_days * 24 * 60 * 60, :second)

    all_tasks = EvoDash.Store.safe_select_all_tasks(task_store)

    # Partition: age-expired finished tasks vs everything else
    {age_expired, remaining} =
      Enum.split_with(all_tasks, fn task ->
        task.finished_at != nil and DateTime.compare(task.finished_at, cutoff) == :lt
      end)

    age_expired_keys = Enum.map(age_expired, fn task -> task.id end)

    # From remaining finished tasks, enforce max_tasks limit (keep newest)
    over_limit_keys =
      remaining
      |> Enum.filter(&(&1.finished_at != nil))
      |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
      |> Enum.drop(max_tasks)
      |> Enum.map(fn task -> task.id end)

    all_keys = age_expired_keys ++ over_limit_keys

    if all_keys != [] do
      EvoDash.Store.delete_tasks(task_store, all_keys)
    end

    :ok
  end
end
