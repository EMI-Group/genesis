defmodule EvoGit.SandboxProcessRegistryTest do
  use ExUnit.Case, async: false

  alias EvoGit.SandboxProcessRegistry

  setup do
    # Ensure the GenServer is running (Application may not have started it on non-Linux CI)
    case GenServer.whereis(SandboxProcessRegistry) do
      nil ->
        {:ok, _pid} = SandboxProcessRegistry.start_link([])
        on_exit(fn -> GenServer.stop(SandboxProcessRegistry, :normal) end)

      pid when is_pid(pid) ->
        :ok
    end

    :ok
  end

  describe "register/0" do
    test "returns a unique unit name matching evogit-run-* pattern" do
      unit = SandboxProcessRegistry.register()

      assert String.starts_with?(unit, "evogit-run-")

      # Cleanup
      SandboxProcessRegistry.unregister(unit)
    end

    test "called twice returns different names" do
      unit1 = SandboxProcessRegistry.register()
      unit2 = SandboxProcessRegistry.register()

      assert unit1 != unit2
      assert String.starts_with?(unit1, "evogit-run-")
      assert String.starts_with?(unit2, "evogit-run-")

      # Cleanup
      SandboxProcessRegistry.unregister(unit1)
      SandboxProcessRegistry.unregister(unit2)
    end
  end

  describe "unregister/1" do
    test "removes the entry cleanly on normal completion" do
      unit = SandboxProcessRegistry.register()
      assert SandboxProcessRegistry.unregister(unit) == :ok

      # Verify state is empty (this entry was the only one from this test process)
      state = :sys.get_state(SandboxProcessRegistry)
      refute Map.has_key?(state, unit)
    end

    test "is safe for non-existent units (no-op, returns :ok)" do
      assert SandboxProcessRegistry.unregister(
               "nonexistent-unit-#{System.unique_integer([:positive])}"
             ) ==
               :ok
    end
  end

  describe "release/1" do
    test "is safe for non-existent units (no-op, returns :ok)" do
      assert SandboxProcessRegistry.release(
               "nonexistent-unit-#{System.unique_integer([:positive])}"
             ) ==
               :ok
    end

    test "removes the entry" do
      unit = SandboxProcessRegistry.register()
      assert SandboxProcessRegistry.release(unit) == :ok

      # Cast is async, give it a moment to be processed
      Process.sleep(50)

      state = :sys.get_state(SandboxProcessRegistry)
      refute Map.has_key?(state, unit)
    end
  end

  describe "DOWN handler" do
    test "fires when monitored process dies and removes the entry" do
      parent = self()

      # Spawn a process that registers and sends the unit_name back to the test
      {pid, ref} =
        spawn_monitor(fn ->
          unit = SandboxProcessRegistry.register()
          send(parent, {:unit, unit})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:unit, unit}, 1000
      assert String.starts_with?(unit, "evogit-run-")

      # Kill the spawned process
      Process.exit(pid, :kill)

      # Wait for the process to actually die
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

      # Give SandboxProcessRegistry time to process the DOWN message
      Process.sleep(50)

      state = :sys.get_state(SandboxProcessRegistry)
      refute Map.has_key?(state, unit)
    end

    test "does not block — registry remains responsive after DOWN" do
      parent = self()

      # Spawn a process that registers and sends the unit_name back
      {pid, ref} =
        spawn_monitor(fn ->
          unit = SandboxProcessRegistry.register()
          send(parent, {:unit, unit})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:unit, unit}, 1000

      # Kill the spawned process
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

      # Give the DOWN message time to be processed
      Process.sleep(50)

      # Registry should still be responsive — register/0 returns immediately
      new_unit = SandboxProcessRegistry.register()
      assert String.starts_with?(new_unit, "evogit-run-")

      # Cleanup
      SandboxProcessRegistry.unregister(new_unit)
      SandboxProcessRegistry.unregister(unit)
    end
  end
end
