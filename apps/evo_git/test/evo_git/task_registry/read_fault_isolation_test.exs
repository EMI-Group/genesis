defmodule EvoGit.TaskRegistry.ReadFaultIsolationTest do
  @moduledoc """
  WRITE/READ FAULT CONTAINMENT for `EvoGit.TaskRegistry`: the registry must
  never exit from an `EvoGit.Store` call.

  `EvoGit.Store` isolates its own reads (a failed read answers with the empty
  value of its own shape) and converts disk-full writes to
  `{:error, :disk_full}`. What remained fatal — and caused the production
  incident — is the CALLER-side failure class: when the store process is dead
  or restarting, `GenServer.call/3` EXITS (`:noproc` / `:normal` /
  `:shutdown`), and `TaskRegistry` (the GenServer every dashboard LiveView
  subscribes to) died with it.

  Every synchronous store call in the registry now goes through
  `EvoGit.TaskRegistry.StoreGuard`:

    * `safe_store_read/3` returns the read's documented empty value;
    * `safe_store_write/2` returns `{:error, :store_unavailable}`, handled
      exactly like `{:error, :disk_full}` (log + in-memory behavior).

  ## How a fault is forced deterministically

  The isolated store from `EvoGit.TaskRegistryCase` is STOPPED through the
  test supervisor (`stop_supervised/1`), which both terminates it and REMOVES
  its child spec — so the registered name is gone for good and every subsequent
  `GenServer.call/3` to it exits with `:noproc`, precisely the shape of the
  production crash chain's dead-server exit.
  """

  # `async: true`: nothing global forces serialization — the fault is forced on
  # THIS test's own isolated store/registry pair (it stops its own store), and
  # the log assertion is a POSITIVE match (`assert log =~ …`), which a
  # concurrent module's output in the window-based capture cannot flip.
  use EvoGit.TaskRegistryCase, async: true

  import ExUnit.CaptureLog

  alias EvoGit.Store

  describe "the registry survives a dead store" do
    test "reads degrade to their empty values and the registry stays alive",
         %{store: store, registry: registry} do
      id = "registry_read_fault_#{System.unique_integer([:positive])}"
      assert :ok = Store.put_task(store, task(id))

      # Sanity: the live store really does answer these reads.
      assert [%{id: ^id}] = TaskRegistry.list_task_ids([:running])
      assert %TaskInfo{id: ^id} = TaskRegistry.get_task(id)

      stop_store!(store)

      log =
        capture_log(fn ->
          assert TaskRegistry.list_task_ids([:running]) == []
          assert TaskRegistry.get_task(id) == nil
          assert TaskRegistry.get_unique_paths() == []
          assert TaskRegistry.list_tasks() == []
          assert TaskRegistry.list_recent_projects() == []
        end)

      # The fault is observable (never silent) …
      assert log =~ "TaskRegistry: store operation"
      # … and the registry — the process every LiveView is blocked on — is alive.
      assert Process.alive?(Process.whereis(registry))
    end

    test "a failing write degrades exactly like disk-full and the registry stays alive",
         %{store: store, registry: registry} do
      stop_store!(store)

      capture_log(fn ->
        # The delete path reports the degraded error atom (like disk-full).
        assert TaskRegistry.clear_finished_tasks() == {:error, :store_unavailable}

        # Convenience writes swallow the fault and continue in-memory.
        assert TaskRegistry.add_recent_project("/tmp/read_fault_project", "fault") == :ok
        assert TaskRegistry.remove_recent_project("/tmp/read_fault_project") == :ok
      end)

      assert Process.alive?(Process.whereis(registry))
    end

    test "a registry can boot against a store that is already gone", %{data_dir: data_dir} do
      unique = System.unique_integer([:positive])
      registry_name = :"evogit_test_registry_dead_store_#{unique}"

      # `:no_such_store_<n>` is never registered → every Store call exits
      # `:noproc`. `init/1`'s startup reconciliation (select_running_lease_info)
      # must therefore degrade instead of crashing the new registry.
      capture_log(fn ->
        start_supervised!(
          Supervisor.child_spec(
            {TaskRegistry,
             task_store: :"no_such_store_#{unique}", data_dir: data_dir, name: registry_name},
            id: registry_name
          )
        )
      end)

      assert Process.alive?(Process.whereis(registry_name))
      assert :sys.get_state(registry_name).task_refs == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp task(id) do
    %TaskInfo{
      id: id,
      type: :genesis,
      status: :running,
      opts: [path: "/tmp/test"],
      started_at: DateTime.utc_now(),
      logs: []
    }
  end

  # Stops the isolated store AND removes its child spec, so nothing restarts it
  # and its registered name resolves to no process — every later
  # `GenServer.call/3` to it exits `:noproc` (the production crash chain's
  # dead-server exit).
  defp stop_store!(store) do
    store_pid = Process.whereis(store)
    assert is_pid(store_pid)
    assert :ok = stop_supervised(store)
    refute Process.alive?(store_pid)
    assert Process.whereis(store) == nil
  end
end
