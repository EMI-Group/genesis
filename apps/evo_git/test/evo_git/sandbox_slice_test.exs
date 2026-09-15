defmodule EvoGit.SandboxSliceTest do
  use ExUnit.Case, async: false

  alias EvoGit.SandboxSlice

  # Fixture reference for the bounded-runner timeout test: the slow runner
  # outlives the timeout by a wide margin. It is KILLED by
  # run_systemctl_bounded/4 the moment the bound fires, so the test never
  # actually waits this long — the value only sets the "would have taken"
  # reference the promptness assertion is measured against.
  @slow_runner_ms 1_000

  setup do
    # Ensure the GenServer is running (Application may not have started it on non-Linux CI)
    case GenServer.whereis(SandboxSlice) do
      nil ->
        {:ok, _pid} = SandboxSlice.start_link([])

        on_exit(fn ->
          # Guarded: individual tests may stop/restart the slice mid-test, so
          # only stop what is actually registered — a noproc exit here would
          # mask the real test result.
          if pid = GenServer.whereis(SandboxSlice), do: GenServer.stop(pid, :normal)
        end)

      pid when is_pid(pid) ->
        :ok
    end

    :ok
  end

  # --- Slice-process helpers ---
  #
  # The registered slice may be (a) the app-level child of EvoGit.Supervisor
  # (Linux test env — EvoGit.Application.start/2 appends it), or (b) a
  # standalone instance started by setup above (non-Linux CI fallback). These
  # helpers manage both shapes without leaking state across tests.

  # Temporarily stops the registered slice so tests can exercise the
  # not-running path, registering an on_exit that brings it back.
  defp pause_slice do
    case GenServer.whereis(SandboxSlice) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        case Process.whereis(EvoGit.Supervisor) do
          nil ->
            # No supervisor running — standalone instance started by setup.
            GenServer.stop(pid, :normal)
            on_exit(fn -> start_standalone_slice() end)

          _sup ->
            case Supervisor.terminate_child(EvoGit.Supervisor, SandboxSlice) do
              :ok ->
                # terminate_child alone leaves the child in the supervisor's
                # :undefined state (no auto-restart on this Elixir version),
                # so the test controls when it comes back.
                on_exit(fn -> restore_slice() end)

              {:error, :not_found} ->
                # Not a supervisor child (non-Linux CI standalone instance).
                GenServer.stop(pid, :normal)
                on_exit(fn -> start_standalone_slice() end)
            end
        end
    end

    assert GenServer.whereis(SandboxSlice) == nil
    :ok
  end

  # Restores a stopped slice to a running state: the app child via
  # restart_child, otherwise a standalone registered instance.
  defp restore_slice do
    case Process.whereis(EvoGit.Supervisor) do
      nil ->
        start_standalone_slice()

      _sup ->
        case Supervisor.restart_child(EvoGit.Supervisor, SandboxSlice) do
          {:ok, _pid} -> :ok
          {:error, :not_found} -> start_standalone_slice()
          {:error, {:already_started, _pid}} -> :ok
        end
    end
  end

  defp start_standalone_slice do
    case GenServer.whereis(SandboxSlice) do
      nil -> assert {:ok, _pid} = SandboxSlice.start_link([])
      _pid -> :ok
    end
  end

  # Polls until `pid` is dead — the :kill signal from a bounded-runner timeout
  # is delivered asynchronously, so a single Process.alive? check can race.
  defp wait_until_dead(pid, attempts \\ 100) do
    if Process.alive?(pid) do
      if attempts > 0 do
        Process.sleep(5)
        wait_until_dead(pid, attempts - 1)
      else
        flunk("process #{inspect(pid)} still alive after expected termination")
      end
    else
      :ok
    end
  end

  describe "ensure_slice/0" do
    test "returns :ok in test environment (sandbox disabled)" do
      assert SandboxSlice.ensure_slice() == :ok
    end
  end

  describe "update_resources_async/1" do
    test "returns :ok when the slice GenServer is not running" do
      pause_slice()

      # The nil-process path: a fire-and-forget update must be a silent :ok,
      # never a noproc crash. Regression guard: AgentScheduler config updates
      # call this from inside a handle_call and must never block or crash on
      # slice state (production crash fixed by the bounded async update).
      assert SandboxSlice.update_resources_async(%{cpu_weight: 100}) == :ok
    end

    test "returns :ok when the slice GenServer is running and the process stays alive" do
      pid = GenServer.whereis(SandboxSlice)
      assert is_pid(pid)

      original = SandboxSlice.get_resources()
      on_exit(fn -> SandboxSlice.update_resources_async(original) end)

      assert SandboxSlice.update_resources_async(%{cpu_weight: 42}) == :ok

      assert Process.whereis(SandboxSlice) == pid
      assert Process.alive?(pid)

      # The cast was processed, not dropped: the resources are observable via
      # get_resources/0 (the slice is inactive in test env — slice_active is
      # false — so no systemctl is ever invoked).
      assert SandboxSlice.get_resources() == %{cpu_weight: 42}
    end
  end

  describe "run_systemctl_bounded/4" do
    test "returns the runner's {:ok, output} result" do
      runner = fn _cmd, _args -> {:ok, "out"} end

      assert SandboxSlice.run_systemctl_bounded(
               "systemctl",
               ["--user", "set-property", "evogit.slice", "CPUWeight=30"],
               1_000,
               runner
             ) == {:ok, "out"}
    end

    test "passes through the runner's {:error, output} result" do
      runner = fn _cmd, _args -> {:error, "boom"} end

      assert SandboxSlice.run_systemctl_bounded(
               "systemctl",
               ["--user", "set-property", "evogit.slice", "CPUWeight=30"],
               1_000,
               runner
             ) == {:error, "boom"}
    end

    test "returns {:error, :timeout} promptly and kills the runner process" do
      test_pid = self()

      runner = fn _cmd, _args ->
        send(test_pid, {:runner_started, self()})
        Process.sleep(@slow_runner_ms)
        {:ok, "slow"}
      end

      {elapsed_us, result} =
        :timer.tc(fn ->
          SandboxSlice.run_systemctl_bounded(
            "systemctl",
            ["--user", "set-property", "evogit.slice", "CPUWeight=30"],
            50,
            runner
          )
        end)

      # The 50ms bound fires while the runner is still sleeping, so the result
      # proves the timeout — not the runner's completion — won.
      assert result == {:error, :timeout}

      # Returned promptly: half the runner's own sleep, i.e. well under it even
      # on a heavily loaded machine (a non-bounded implementation would have
      # blocked for @slow_runner_ms and returned {:ok, "slow"} instead).
      assert elapsed_us < div(@slow_runner_ms, 2) * 1_000

      assert_receive {:runner_started, runner_pid}
      # The runner process was killed by the timeout, not left to sleep on.
      wait_until_dead(runner_pid)
    end

    test "returns {:error, {:runner_crashed, error}} when the runner raises" do
      test_pid = self()

      runner = fn _cmd, _args ->
        send(test_pid, {:runner_started, self()})
        raise "boom"
      end

      assert {:error, {:runner_crashed, %RuntimeError{message: "boom"}}} =
               SandboxSlice.run_systemctl_bounded(
                 "systemctl",
                 ["--user", "set-property", "evogit.slice", "CPUWeight=30"],
                 1_000,
                 runner
               )

      assert_receive {:runner_started, runner_pid}
      # The rescued raise becomes a normal result and the runner process
      # terminates on its own — no stray process is left behind.
      wait_until_dead(runner_pid)
    end
  end
end
