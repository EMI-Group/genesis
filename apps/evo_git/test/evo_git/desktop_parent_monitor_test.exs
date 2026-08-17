defmodule EvoGit.DesktopParentMonitorTest do
  # async: false — the EVOGIT_PARENT_PID env var and the application-env test
  # seams are global; tests must not race each other.
  use ExUnit.Case, async: false

  @long_interval 86_400_000

  setup do
    # Snapshot and clear the env var + seams so each test starts clean.
    original_pid = System.get_env("EVOGIT_PARENT_PID")
    original_alive = Application.get_env(:evo_git, :parent_alive_check)
    original_stop = Application.get_env(:evo_git, :parent_stop_fun)
    original_interval = Application.get_env(:evo_git, :parent_monitor_interval_ms)

    System.delete_env("EVOGIT_PARENT_PID")
    Application.delete_env(:evo_git, :parent_alive_check)
    Application.delete_env(:evo_git, :parent_stop_fun)
    Application.delete_env(:evo_git, :parent_monitor_interval_ms)

    on_exit(fn ->
      restore_sys_env("EVOGIT_PARENT_PID", original_pid)
      restore_app_env(:parent_alive_check, original_alive)
      restore_app_env(:parent_stop_fun, original_stop)
      restore_app_env(:parent_monitor_interval_ms, original_interval)
    end)

    :ok
  end

  describe "disabled (no EVOGIT_PARENT_PID)" do
    test "missing env var: :check_parent is a safe no-op and the process stays alive" do
      pid = start_supervised!({EvoGit.DesktopParentMonitor, interval_ms: @long_interval})

      send(pid, :check_parent)
      send(pid, :check_parent)

      # Give any (wrongly scheduled) timer a chance to fire; nothing may stop.
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "empty env var is treated as disabled" do
      System.put_env("EVOGIT_PARENT_PID", "")
      pid = start_supervised!({EvoGit.DesktopParentMonitor, interval_ms: @long_interval})

      send(pid, :check_parent)
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "enabled" do
    test "stops exactly once when the parent is dead" do
      test_pid = self()
      System.put_env("EVOGIT_PARENT_PID", "424242")
      Application.put_env(:evo_git, :parent_alive_check, fn _pid -> false end)
      Application.put_env(:evo_git, :parent_stop_fun, fn -> send(test_pid, :monitor_stopped) end)

      pid = start_supervised!({EvoGit.DesktopParentMonitor, interval_ms: @long_interval})

      # init schedules an immediate first check; drive the logic deterministically.
      send(pid, :check_parent)

      assert_receive :monitor_stopped, 1000

      # Idempotent: after the stop fun has been invoked once, further checks
      # (e.g. a straggler from the immediate first check) must not invoke it
      # again.
      send(pid, :check_parent)
      refute_receive :monitor_stopped, 200
    end

    test "does not stop while the parent is alive" do
      System.put_env("EVOGIT_PARENT_PID", "424242")
      Application.put_env(:evo_git, :parent_alive_check, fn _pid -> true end)
      Application.put_env(:evo_git, :parent_stop_fun, fn -> send(self(), :monitor_stopped) end)

      pid = start_supervised!({EvoGit.DesktopParentMonitor, interval_ms: @long_interval})

      # State continues across checks: repeated checks keep rescheduling.
      send(pid, :check_parent)
      send(pid, :check_parent)

      refute_receive :monitor_stopped, 200
      assert Process.alive?(pid)

      # Still functioning after the checks above.
      send(pid, :check_parent)
      refute_receive :monitor_stopped, 200
      assert Process.alive?(pid)
    end
  end

  describe "default_alive?/1" do
    test "returns true for the test VM's own OS pid on the host platform" do
      own_pid = :os.getpid() |> List.to_string()

      # kill -0 on self (Unix) / tasklist filtering self (Windows) is safe on
      # all three supported OSes.
      assert EvoGit.DesktopParentMonitor.default_alive?(own_pid)
    end
  end

  # --- Helpers ---

  defp restore_sys_env(key, nil), do: System.delete_env(key)
  defp restore_sys_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_app_env(key, value), do: Application.put_env(:evo_git, key, value)
end
