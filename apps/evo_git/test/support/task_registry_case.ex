defmodule EvoGit.TaskRegistryCase do
  @moduledoc """
  Shared test case for TaskRegistry tests. Provides an isolated TaskRegistry +
  Store on a temporary SQLite database, plus common helper functions.

  Usage:

      defmodule EvoGit.TaskRegistry.XxxTest do
        use EvoGit.TaskRegistryCase, async: false
        # ...
      end
  """

  use ExUnit.CaseTemplate

  alias EvoGit.TaskRegistry

  using do
    quote do
      alias EvoGit.TaskRegistry
      alias EvoGit.TaskInfo
      import EvoGit.TaskRegistryCase
    end
  end

  setup do
    # Terminate production children to prevent auto-restarts and use isolated stores.
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_tasks_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({EvoGit.Store, data_dir: sqlite_path})

    start_supervised(
      {TaskRegistry, task_store: EvoGit.Store, data_dir: root, name: EvoGit.TaskRegistry}
    )

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.Store)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    end)

    {:ok, %{data_dir: root, sqlite_path: sqlite_path}}
  end

  # Helper: trigger cleanup_expired_tasks directly (cleanup is now periodic,
  # not on every status transition).
  def trigger_cleanup! do
    EvoGit.TaskRegistry.Cleanup.cleanup_expired_tasks(EvoGit.Store)
    :ok
  end

  # Helper: cleanly terminate a spawned test process so it doesn't linger.
  def cleanup_process(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end
  end

  # Helper: compute an age in days guaranteed to EXCEED the configured
  # max_age_days. Reads the actual runtime config (fallback to default 14) so
  # tests are robust regardless of the local config.toml setting.
  def old_age_days do
    config = EvoGit.Config.resolve()
    configured = (config[:task_history] || %{})[:max_age_days] || 14
    configured + 10
  end

  # Helper: compute an age in days guaranteed to be WITHIN the configured
  # max_age_days window. Uses roughly a third of the window, floored to 1 day.
  def within_age_days do
    config = EvoGit.Config.resolve()
    configured = (config[:task_history] || %{})[:max_age_days] || 14
    max(div(configured, 3), 1)
  end

  # Helper: restart the TaskRegistry so init/1 re-runs and reconcile_task_status
  # is invoked. Uses stop_supervised/1 to avoid auto-restart conflicts, then
  # starts a fresh supervised instance pointing at the same Store + data_dir.
  def restart_registry!(root) do
    :ok = stop_supervised(EvoGit.TaskRegistry)

    {:ok, _} =
      start_supervised(
        {TaskRegistry, task_store: EvoGit.Store, data_dir: root, name: EvoGit.TaskRegistry}
      )

    :ok
  end
end
