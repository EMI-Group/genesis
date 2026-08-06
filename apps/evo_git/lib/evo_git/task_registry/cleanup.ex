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

  Accepts a `task_store` name/pid (e.g. `EvoGit.Store`) and reads only the task
  **ids** to delete via `EvoGit.Store.select_cleanup_info/3` — the age cutoff
  (`finished_at < cutoff`) and count trim (newest `max_tasks` kept) are both
  pushed down to SQL. No rows are decoded and no Elixir-side sort/filter runs.
  The returned ids are deleted in batches via `EvoGit.Store.delete_tasks/2`.

  This is the runtime entry point used by `TaskRegistry` after task-completion
  transitions and explicit `clear_finished_tasks`.
  """
  def cleanup_expired_tasks(task_store) do
    config = task_history_config()
    cutoff = DateTime.add(DateTime.utc_now(), -config.max_age_days * 24 * 60 * 60, :second)
    cutoff_iso = EvoGit.Store.Codec.encode_datetime(cutoff)
    ids = EvoGit.Store.select_cleanup_info(task_store, cutoff_iso, config.max_tasks)

    if ids != [] do
      EvoGit.Store.delete_tasks(task_store, ids)
    end

    :ok
  end
end
