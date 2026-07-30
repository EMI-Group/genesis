defmodule EvoGit.TaskRegistry.Cleanup do
  @moduledoc """
  Cleanup logic for `EvoGit.TaskRegistry`.

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

  Accepts a `task_store` name/pid (e.g. `EvoGit.Store`) and scans all tasks
  via `EvoGit.Store.select_cleanup_info/1` — a lightweight query that reads
  only `id` and `finished_at`, avoiding a full struct decode. Age-expired
  finished tasks and over-limit finished tasks (keeping only the newest
  `max_tasks`) are batched and deleted.

  This is the runtime entry point used by `TaskRegistry` after task-completion
  transitions and explicit `clear_finished_tasks`. It performs its own store
  read (lightweight columns only).
  """
  def cleanup_expired_tasks(task_store) do
    config = task_history_config()
    max_age_days = config.max_age_days
    max_tasks = config.max_tasks
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_days * 24 * 60 * 60, :second)

    rows = EvoGit.Store.select_cleanup_info(task_store)

    # Partition: age-expired finished tasks vs everything else
    {age_expired, remaining} =
      Enum.split_with(rows, fn %{finished_at: finished_at} ->
        finished_at != nil and DateTime.compare(finished_at, cutoff) == :lt
      end)

    age_expired_keys = Enum.map(age_expired, fn %{id: id} -> id end)

    # From remaining finished tasks, enforce max_tasks limit (keep newest)
    over_limit_keys =
      remaining
      |> Enum.filter(&(&1.finished_at != nil))
      |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
      |> Enum.drop(max_tasks)
      |> Enum.map(fn %{id: id} -> id end)

    all_keys = age_expired_keys ++ over_limit_keys

    if all_keys != [] do
      EvoGit.Store.delete_tasks(task_store, all_keys)
    end

    :ok
  end

  @doc """
  Removes finished tasks that exceed the configured age or count limits,
  operating on a **pre-loaded task list** instead of reading from the store.

  This variant avoids a redundant full-table scan at init time, where the task
  list has already been loaded (and normalized) by the caller. `tasks` should be
  a list of `%EvoGit.TaskInfo{}` structs in their final (post-reconcile) state.
  """
  def cleanup_expired_tasks(tasks, task_store) do
    config = task_history_config()
    max_age_days = config.max_age_days
    max_tasks = config.max_tasks
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_days * 24 * 60 * 60, :second)

    # Partition: age-expired finished tasks vs everything else
    {age_expired, remaining} =
      Enum.split_with(tasks, fn task ->
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
      EvoGit.Store.delete_tasks(task_store, all_keys)
    end

    :ok
  end
end
