defmodule EvoGit.TaskRegistryCase do
  @moduledoc """
  Shared test case for `EvoGit.TaskRegistry` tests.

  Each test gets its OWN, fully isolated `EvoGit.Store` + `EvoGit.TaskRegistry`
  pair, both started under the test's supervisor with UNIQUE registered names, so
  the app-global singletons are never touched and tests may run concurrently
  (`async: true`).

  Isolation works through the runtime seam on `EvoGit.TaskRegistry.server/0`:

    * `EvoGit.TaskRegistry` resolves its target instance from the process
      dictionary key `:evogit_task_registry_server` at CALL time (falling back
      to the registered `EvoGit.TaskRegistry` singleton). `setup/1` runs in the
      test process, so it stores the isolated registry name there — every
      `EvoGit.TaskRegistry.*` call made from the test resolves to the isolated
      instance. The registry's own process (and any task wrapper it spawns)
      carries the same key, so in-wrapper callbacks resolve back to this
      instance too.
    * `EvoGit.Store` needs no seam: every client function takes the store name
      as its first argument. The isolated store name is stored in the test
      process under `:evogit_test_store` and exposed via `store/0`.

  Nothing global is mutated: the temporary data directory is removed on exit and
  the per-test processes are stopped by `start_supervised!/1`.

  Usage (both async settings are supported — the case does not force one):

      defmodule EvoGit.TaskRegistry.XxxTest do
        use EvoGit.TaskRegistryCase, async: true
        # ... context: %{data_dir: root, sqlite_path: path, store: name, registry: name}
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
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_tasks_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    store_name = :"evogit_test_store_#{unique}"
    registry_name = :"evogit_test_registry_#{unique}"

    # Explicit `id` overrides are required because both modules hardcode
    # `id: __MODULE__` in their `child_spec/1`.
    start_supervised!(
      Supervisor.child_spec({EvoGit.Store, data_dir: sqlite_path, name: store_name},
        id: store_name
      )
    )

    start_supervised!(
      Supervisor.child_spec(
        {TaskRegistry, task_store: store_name, data_dir: root, name: registry_name},
        id: registry_name
      )
    )

    # `setup/1` runs in the test process: point every in-test call at the
    # isolated instances.
    Process.put(:evogit_task_registry_server, registry_name)
    Process.put(:evogit_test_store, store_name)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, %{data_dir: root, sqlite_path: sqlite_path, store: store_name, registry: registry_name}}
  end

  @doc """
  The isolated `EvoGit.Store` name for the current test, falling back to the
  global singleton when called outside a test process (or after `setup/1`).
  """
  def store do
    Process.get(:evogit_test_store) || EvoGit.Store
  end

  @doc """
  Trigger `cleanup_expired_tasks/1` against the isolated store.

  Cleanup is periodic (no longer run on every status transition), so tests call
  this directly. Must be invoked from the test process so the isolated store
  name is available via the process dictionary.
  """
  def trigger_cleanup! do
    EvoGit.TaskRegistry.Cleanup.cleanup_expired_tasks(store())
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
end
