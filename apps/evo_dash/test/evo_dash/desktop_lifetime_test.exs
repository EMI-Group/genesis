defmodule EvoDash.DesktopLifetimeTest do
  # async: true — the EVOGIT_LIFETIME_PORT env var and the :parent_stop_fun
  # app-env seam are written only here and snapshot-restored in on_exit below;
  # no async: true module reads them (the other EvoDash.DesktopLifetime users,
  # live_hooks/desktop_quit_test and live_hooks/update_status_test, are
  # async: false). Tests inside this module always run serially.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

      # The watcher logs from its OWN process; capture the line here so it can
      # never leak to the console in the between-test gap. The stop window is
      # generous (bounded) so a busy CPU can still schedule the watcher's
      # connect-retry loop.
      {pid, log} =
        with_log(fn ->
          pid = start_supervised!({EvoDash.DesktopLifetime, @small_opts})
          assert_receive @stop_message, 5000
          pid
        end)

      assert log =~
               "[desktop] Tauri shell is gone (lifetime connection could not be established)"

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

      # Bounded, event-driven waits (never a fixed sleep): the accept window and
      # the stop window are generous so a busy CPU can still schedule the
      # watcher. The close + stop actions are wrapped in a log capture because
      # the watcher logs from its OWN process — capturing here keeps that line
      # off the console in the between-test gap.
      log =
        capture_log(fn ->
          # The watcher must actually connect to the shell's listener.
          {:ok, shell_sock} = :gen_tcp.accept(listener, 5000)
          assert is_port(shell_sock)

          # No stop while the pipe is open.
          refute_receive @stop_message, 200
          assert Process.alive?(pid)

          # Shell dies → its end of the pipe closes → the watcher stops the VM.
          :ok = :gen_tcp.close(shell_sock)
          :ok = :gen_tcp.close(listener)

          assert_receive @stop_message, 5000
        end)

      assert log =~ "[desktop] Tauri shell is gone (lifetime connection closed)"
      assert Process.alive?(pid)
    end

    test "connection stays silent: no stop while the stream is held open" do
      test_pid = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listener)
      System.put_env("EVOGIT_LIFETIME_PORT", Integer.to_string(port))
      Application.put_env(:evo_dash, :parent_stop_fun, fn -> send(test_pid, @stop_message) end)

      pid = start_supervised!(EvoDash.DesktopLifetime)

      {:ok, shell_sock} = :gen_tcp.accept(listener, 5000)
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

      {:ok, shell_sock} = :gen_tcp.accept(listener, 5000)
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

      # The watcher logs from its OWN process; capture the genuine-close line.
      log =
        capture_log(fn ->
          send(pid, :respond_closed)
          assert_receive @stop_message, 2000
        end)

      assert log =~ "[desktop] Tauri shell is gone (lifetime connection closed)"
      assert Process.alive?(pid)
      refute_receive @stop_message, 100
    end

    test "an always-ambiguous error does not stop within the retry budget, then stops" do
      test_pid = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listener)
      System.put_env("EVOGIT_LIFETIME_PORT", Integer.to_string(port))
      Application.put_env(:evo_dash, :parent_stop_fun, fn -> send(test_pid, @stop_message) end)

      # Blocking handshake (same pattern as the transient-error test above): the
      # seam sends :recv_called and then WAITS for this process to respond, so
      # the watcher is parked inside recv_fun between assertions and literally
      # cannot call the stop fun early — no scheduling race against
      # recv_retry_delay.
      recv_fun = fn _sock ->
        send(test_pid, :recv_called)

        receive do
          :respond_ambiguous -> {:error, :eacces}
        end
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

      {:ok, shell_sock} = :gen_tcp.accept(listener, 5000)
      assert is_port(shell_sock)

      on_exit(fn ->
        :gen_tcp.close(shell_sock)
        :gen_tcp.close(listener)
      end)

      # Every recv blocks in the seam until this process responds, so these
      # assertions are event-driven: the watcher is parked inside recv_fun and
      # cannot fire the stop fun while a recv is outstanding.
      log =
        capture_log(fn ->
          assert_receive :recv_called, 2000
          refute_receive @stop_message, 10

          send(pid, :respond_ambiguous)
          assert_receive :recv_called, 2000
          refute_receive @stop_message, 10

          send(pid, :respond_ambiguous)
          assert_receive :recv_called, 2000
          refute_receive @stop_message, 10

          # The 4th recv call exhausts the 3-retry budget: answer it too and the
          # watcher finally gives up (the budget semantics — 4 recvs, stop only
          # once the budget is exhausted — are unchanged).
          send(pid, :respond_ambiguous)
          assert_receive :recv_called, 2000
          send(pid, :respond_ambiguous)
          assert_receive @stop_message, 2000
        end)

      assert log =~ "[desktop] lifetime recv kept failing"
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
