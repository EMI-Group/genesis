defmodule EvoGit.SandboxProcessRegistryTest do
  @moduledoc """
  Tests for `EvoGit.SandboxProcessRegistry`.

  Uses `async: false` because the tests start/stop the globally named
  `EvoGit.SandboxProcessRegistry` GenServer (the app-level singleton registered
  in `EvoGit.Supervisor`'s supervision tree by `EvoGit.Application.start/2` on
  Linux) and inspect its process-wide state with `:sys.get_state/1`.

  This module is, in principle, flippable to `async: true`: nothing else in
  `apps/evo_git/test` or `apps/evo_dash/test` consumes that registry (the only
  production consumer is `EvoGit.Sandbox.Linux`, whose call sites sit behind
  `Linux.enabled?/0`, short-circuited to the disabled path when
  `@mix_env == :test`). It is nevertheless deliberately kept serialized here:
  the ~6ms it would save does not justify diverging from the documented grouping
  in `test/evo_git/CONTEXT.md` ("Shared app singletons").
  """

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

  # release/1's cast is asynchronous, but the registry observes a monitored
  # process's death via a runtime-delivered :DOWN message that is NOT sent by
  # this test process — so there is no per-sender ordering guarantee against a
  # later :sys.get_state/1. Poll (bounded) until the entry is gone instead of
  # sleeping a fixed amount.
  defp wait_until_entry_gone(unit, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until_entry_gone(unit, deadline, timeout)
  end

  defp do_wait_until_entry_gone(unit, deadline, timeout) do
    state = :sys.get_state(SandboxProcessRegistry)

    cond do
      not Map.has_key?(state, unit) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("registry still holds #{inspect(unit)} after #{timeout}ms")

      true ->
        Process.sleep(5)
        do_wait_until_entry_gone(unit, deadline, timeout)
    end
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

      # release/1 is a cast, but :sys.get_state/1 is a synchronous call issued
      # from this same process — per-sender ordering guarantees the cast is
      # processed before the get_state reply, so no settle-sleep is needed.
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

      # Wait (bounded) for SandboxProcessRegistry to process the runtime-
      # delivered DOWN message before inspecting its state.
      wait_until_entry_gone(unit)

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

      # Wait (bounded) for the DOWN message to be processed
      wait_until_entry_gone(unit)

      # Registry should still be responsive — register/0 returns immediately
      new_unit = SandboxProcessRegistry.register()
      assert String.starts_with?(new_unit, "evogit-run-")

      # Cleanup
      SandboxProcessRegistry.unregister(new_unit)
      SandboxProcessRegistry.unregister(unit)
    end
  end
end
