defmodule EvoDash.TaskRegistryCase do
  @moduledoc """
  Shared test case for TaskRegistry tests. Provides an isolated TaskRegistry +
  Store on a temporary SQLite database, plus common helper functions.

  Usage:

      defmodule EvoDash.TaskRegistry.XxxTest do
        use EvoDash.TaskRegistryCase, async: false
        # ...
      end
  """

  use ExUnit.CaseTemplate

  alias EvoDash.TaskRegistry
  alias EvoDash.TaskInfo

  using do
    quote do
      alias EvoDash.TaskRegistry
      alias EvoDash.TaskInfo
      import EvoDash.TaskRegistryCase
    end
  end

  setup do
    # Terminate production children to prevent auto-restarts and use isolated stores.
    Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
    Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_tasks_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({EvoDash.Store, data_dir: sqlite_path})

    start_supervised(
      {TaskRegistry, task_store: EvoDash.Store, data_dir: root, name: EvoDash.TaskRegistry}
    )

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.Store)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
    end)

    {:ok, %{data_dir: root, sqlite_path: sqlite_path}}
  end

  # Helper: trigger cleanup_expired_tasks by inserting a task in :running state
  # and transitioning it to :completed (which calls cleanup_expired_tasks()),
  # then synchronizing with a synchronous call.
  def trigger_cleanup! do
    trigger_id = "cleanup_trigger_#{System.unique_integer([:positive])}"

    trigger = %TaskInfo{
      id: trigger_id,
      type: :genesis,
      status: :running,
      opts: [path: "/tmp/test"],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      logs: [],
      result: nil
    }

    EvoDash.Store.put_task(EvoDash.Store, trigger)
    # update_task_status transitions to :completed which triggers cleanup_expired_tasks()
    TaskRegistry.update_task_status(trigger_id, :completed, nil)
    # Sync with a call to ensure all prior casts have been processed
    TaskRegistry.list_tasks()
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
    :ok = stop_supervised(EvoDash.TaskRegistry)

    {:ok, _} =
      start_supervised(
        {TaskRegistry, task_store: EvoDash.Store, data_dir: root, name: EvoDash.TaskRegistry}
      )

    :ok
  end
end
