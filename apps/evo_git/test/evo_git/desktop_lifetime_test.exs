defmodule EvoGit.DesktopLifetimeTest do
  # async: false — the EVOGIT_LIFETIME_PORT env var and the application-env
  # test seam are global; tests must not race each other.
  use ExUnit.Case, async: false

  @stop_message :lifetime_stopped
  # Small retry budget for the connect-failure tests.
  @small_opts [connect_retries: 2, connect_retry_delay: 10]

  setup do
    # Snapshot and clear the env var + seam so each test starts clean.
    original_port = System.get_env("EVOGIT_LIFETIME_PORT")
    original_stop = Application.get_env(:evo_git, :parent_stop_fun)

    System.delete_env("EVOGIT_LIFETIME_PORT")
    Application.delete_env(:evo_git, :parent_stop_fun)

    on_exit(fn ->
      restore_sys_env("EVOGIT_LIFETIME_PORT", original_port)
      restore_app_env(:parent_stop_fun, original_stop)
    end)

    :ok
  end

  describe "disabled" do
    test "missing env var: no socket, no stop, process stays alive" do
      pid = start_supervised!({EvoGit.DesktopLifetime, @small_opts})

      refute_receive @stop_message, 200
      assert Process.alive?(pid)
    end

    test "empty env var is treated as disabled" do
      System.put_env("EVOGIT_LIFETIME_PORT", "")
      pid = start_supervised!({EvoGit.DesktopLifetime, @small_opts})

      refute_receive @stop_message, 200
      assert Process.alive?(pid)
    end

    test "invalid port value is treated as disabled (no crash, no stop)" do
      System.put_env("EVOGIT_LIFETIME_PORT", "not-a-port")
      pid = start_supervised!({EvoGit.DesktopLifetime, @small_opts})

      refute_receive @stop_message, 200
      assert Process.alive?(pid)
    end
  end

  describe "connect failure" do
    test "exhausted retry budget invokes the stop fun" do
      test_pid = self()
      System.put_env("EVOGIT_LIFETIME_PORT", Integer.to_string(unused_port()))
      Application.put_env(:evo_git, :parent_stop_fun, fn -> send(test_pid, @stop_message) end)

      pid = start_supervised!({EvoGit.DesktopLifetime, @small_opts})

      assert_receive @stop_message, 1000
      # The process idles in the stopped state — no restart loop, no repeat stop.
      assert Process.alive?(pid)
      refute_receive @stop_message, 100
    end
  end

  describe "lifetime pipe" do
    test "watcher connects to the shell listener and stops when the shell's end closes" do
      test_pid = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listener)
      System.put_env("EVOGIT_LIFETIME_PORT", Integer.to_string(port))
      Application.put_env(:evo_git, :parent_stop_fun, fn -> send(test_pid, @stop_message) end)

      on_exit(fn ->
        :gen_tcp.close(listener)
      end)

      pid = start_supervised!(EvoGit.DesktopLifetime)

      # The watcher must actually connect to the shell's listener.
      {:ok, shell_sock} = :gen_tcp.accept(listener, 2000)
      assert is_port(shell_sock)

      # No stop while the pipe is open.
      refute_receive @stop_message, 200
      assert Process.alive?(pid)

      # Shell dies → its end of the pipe closes → the watcher stops the VM.
      :ok = :gen_tcp.close(shell_sock)
      :ok = :gen_tcp.close(listener)

      assert_receive @stop_message, 1000
      assert Process.alive?(pid)
    end

    test "connection stays silent: no stop while the stream is held open" do
      test_pid = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listener)
      System.put_env("EVOGIT_LIFETIME_PORT", Integer.to_string(port))
      Application.put_env(:evo_git, :parent_stop_fun, fn -> send(test_pid, @stop_message) end)

      pid = start_supervised!(EvoGit.DesktopLifetime)

      {:ok, shell_sock} = :gen_tcp.accept(listener, 2000)
      assert is_port(shell_sock)

      on_exit(fn ->
        :gen_tcp.close(shell_sock)
        :gen_tcp.close(listener)
      end)

      refute_receive @stop_message, 200
      assert Process.alive?(pid)
    end
  end

  # --- Helpers ---

  defp unused_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :ok = :gen_tcp.close(sock)
    port
  end

  defp restore_sys_env(key, nil), do: System.delete_env(key)
  defp restore_sys_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_app_env(key, value), do: Application.put_env(:evo_git, key, value)
end
