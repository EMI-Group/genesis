defmodule EvoDash.DesktopLifetimeTest do
  # async: true — the EVOGIT_LIFETIME_PORT env var and the :parent_stop_fun
  # app-env seam are written only here and snapshot-restored in on_exit below;
  # no async: true module reads them (the other EvoDash.DesktopLifetime users,
  # live_hooks/desktop_quit_test and live_hooks/update_status_test, are
  # async: false). Tests inside this module always run serially.
  use ExUnit.Case, async: true

  @stop_message :lifetime_stopped
  # Small retry budget for the connect-failure tests.
  @small_opts [connect_retries: 2, connect_retry_delay: 10]

  setup do
    # Snapshot and clear the env var + seam so each test starts clean.
    original_port = System.get_env("EVOGIT_LIFETIME_PORT")
    original_stop = Application.get_env(:evo_dash, :parent_stop_fun)

    System.delete_env("EVOGIT_LIFETIME_PORT")
    Application.delete_env(:evo_dash, :parent_stop_fun)

    on_exit(fn ->
      restore_sys_env("EVOGIT_LIFETIME_PORT", original_port)
      restore_app_env(:parent_stop_fun, original_stop)
    end)

    :ok
  end

  describe "disabled" do
    test "missing env var: no socket, no stop, process stays alive" do
      pid = start_supervised!({EvoDash.DesktopLifetime, @small_opts})

      refute_receive @stop_message, 200
      assert Process.alive?(pid)
    end

    test "empty env var is treated as disabled" do
      System.put_env("EVOGIT_LIFETIME_PORT", "")
      pid = start_supervised!({EvoDash.DesktopLifetime, @small_opts})

      refute_receive @stop_message, 200
      assert Process.alive?(pid)
    end

    test "invalid port value is treated as disabled (no crash, no stop)" do
      System.put_env("EVOGIT_LIFETIME_PORT", "not-a-port")
      pid = start_supervised!({EvoDash.DesktopLifetime, @small_opts})

      refute_receive @stop_message, 200
      assert Process.alive?(pid)
    end
  end

  describe "connect failure" do
    test "exhausted retry budget invokes the stop fun" do
      test_pid = self()
      System.put_env("EVOGIT_LIFETIME_PORT", Integer.to_string(unused_port()))
      Application.put_env(:evo_dash, :parent_stop_fun, fn -> send(test_pid, @stop_message) end)

      pid = start_supervised!({EvoDash.DesktopLifetime, @small_opts})

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
      Application.put_env(:evo_dash, :parent_stop_fun, fn -> send(test_pid, @stop_message) end)

      on_exit(fn ->
        :gen_tcp.close(listener)
      end)

      pid = start_supervised!(EvoDash.DesktopLifetime)

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
      Application.put_env(:evo_dash, :parent_stop_fun, fn -> send(test_pid, @stop_message) end)

      pid = start_supervised!(EvoDash.DesktopLifetime)

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

  describe "classify_recv_result/1" do
    test "a genuine peer close is :closed" do
      assert EvoDash.DesktopLifetime.classify_recv_result({:error, :closed}) == :closed
    end

    test "received data is :data" do
      assert EvoDash.DesktopLifetime.classify_recv_result({:ok, "ping"}) == :data
    end

    test "every other recv error is :ambiguous" do
      for reason <- [:econnreset, :econnaborted, :eacces, :timeout] do
        assert EvoDash.DesktopLifetime.classify_recv_result({:error, reason}) == :ambiguous
      end
    end
  end

  describe "ambiguous recv errors" do
    test "a transient ambiguous error alone does NOT stop; a later peer close does" do
      test_pid = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listener)
      System.put_env("EVOGIT_LIFETIME_PORT", Integer.to_string(port))
      Application.put_env(:evo_dash, :parent_stop_fun, fn -> send(test_pid, @stop_message) end)

      recv_fun = fn _sock ->
        send(test_pid, :recv_called)

        receive do
          :respond_ambiguous -> {:error, :econnreset}
          :respond_closed -> {:error, :closed}
        end
      end

      pid =
        start_supervised!(
          {EvoDash.DesktopLifetime,
           [
             connect_retries: 5,
             connect_retry_delay: 10,
             recv_retries: 5,
             recv_retry_delay: 10,
             recv_fun: recv_fun
           ]}
        )

      {:ok, shell_sock} = :gen_tcp.accept(listener, 2000)
      assert is_port(shell_sock)

      on_exit(fn ->
        :gen_tcp.close(shell_sock)
        :gen_tcp.close(listener)
      end)

      assert_receive :recv_called, 2000
      refute_receive @stop_message, 20

      send(pid, :respond_ambiguous)
      assert_receive :recv_called, 2000
      refute_receive @stop_message, 20

      send(pid, :respond_ambiguous)
      assert_receive :recv_called, 2000
      refute_receive @stop_message, 20

      send(pid, :respond_closed)
      assert_receive @stop_message, 2000

      assert Process.alive?(pid)
      refute_receive @stop_message, 100
    end

    test "an always-ambiguous error does not stop within the retry budget, then stops" do
      test_pid = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listener)
      System.put_env("EVOGIT_LIFETIME_PORT", Integer.to_string(port))
      Application.put_env(:evo_dash, :parent_stop_fun, fn -> send(test_pid, @stop_message) end)

      recv_fun = fn _sock ->
        send(test_pid, :recv_called)
        {:error, :eacces}
      end

      pid =
        start_supervised!(
          {EvoDash.DesktopLifetime,
           [
             connect_retries: 5,
             connect_retry_delay: 10,
             recv_retries: 3,
             recv_retry_delay: 30,
             recv_fun: recv_fun
           ]}
        )

      {:ok, shell_sock} = :gen_tcp.accept(listener, 2000)
      assert is_port(shell_sock)

      on_exit(fn ->
        :gen_tcp.close(shell_sock)
        :gen_tcp.close(listener)
      end)

      assert_receive :recv_called, 2000
      refute_receive @stop_message, 10

      assert_receive :recv_called, 2000
      refute_receive @stop_message, 10

      assert_receive :recv_called, 2000
      refute_receive @stop_message, 10

      assert_receive @stop_message, 2000
      assert Process.alive?(pid)
      refute_receive @stop_message, 100
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

  defp restore_app_env(key, nil), do: Application.delete_env(:evo_dash, key)
  defp restore_app_env(key, value), do: Application.put_env(:evo_dash, key, value)
end
