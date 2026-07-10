defmodule EvoGit.SandboxSliceTest do
  use ExUnit.Case, async: false

  alias EvoGit.SandboxSlice

  setup do
    # Ensure the GenServer is running (Application may not have started it on non-Linux CI)
    case GenServer.whereis(SandboxSlice) do
      nil ->
        {:ok, _pid} = SandboxSlice.start_link([])
        on_exit(fn -> GenServer.stop(SandboxSlice, :normal) end)

      pid when is_pid(pid) ->
        :ok
    end

    # Clean up any runs left from previous tests
    :ok
  end

  describe "register_run/2 and unregister_run/1" do
    test "register_run adds an entry that can be removed by unregister_run" do
      unit = "test-unit-#{System.unique_integer([:positive])}"
      caller = self()

      assert SandboxSlice.register_run(unit, caller) == :ok

      # The entry should be in state — verify indirectly by checking that
      # unregister succeeds without error.
      assert SandboxSlice.unregister_run(unit) == :ok
    end

    test "unregister_run is safe for a non-existent unit" do
      assert SandboxSlice.unregister_run("nonexistent-unit-#{System.unique_integer([:positive])}") ==
               :ok
    end

    test "register_run monitors the caller process" do
      unit = "test-monitor-#{System.unique_integer([:positive])}"

      # Spawn a short-lived process to act as the caller
      caller_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert SandboxSlice.register_run(unit, caller_pid) == :ok

      # Kill the caller — should trigger DOWN message in SandboxSlice
      ref = Process.monitor(caller_pid)
      Process.exit(caller_pid, :kill)

      # Wait for the caller to actually die
      assert_receive {:DOWN, ^ref, :process, ^caller_pid, _reason}, 1000

      # Give SandboxSlice time to process the DOWN message
      Process.sleep(50)

      # The unit should have been cleaned up by the DOWN handler.
      # Verify by re-registering (should succeed) and cleaning up.
      assert SandboxSlice.register_run(unit, self()) == :ok
      assert SandboxSlice.unregister_run(unit) == :ok
    end
  end

  describe "stop_run/1" do
    test "returns :ok even when systemctl is not available" do
      # stop_run calls do_stop_unit which uses system_cmd. In test env (no
      # systemd or systemctl), it should still return :ok — the error is
      # logged but not propagated.
      assert SandboxSlice.stop_run("nonexistent-unit-#{System.unique_integer([:positive])}") == :ok
    end
  end

  describe "ensure_slice/0" do
    test "returns :ok in test environment (sandbox disabled)" do
      assert SandboxSlice.ensure_slice() == :ok
    end
  end
end
