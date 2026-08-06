defmodule EvoGit.RemoteConnectionTest do
  @moduledoc """
  Tests for `EvoGit.RemoteConnection` — the GenServer managing a single SSH
  remote connection's lifecycle.

  Uses `async: false` because the tests interact with the Registry /
  DynamicSupervisor that are part of the application supervision tree.
  """

  use ExUnit.Case, async: false

  # --- Setup: isolate config dir ---

  setup do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-test-xdg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      # Disconnect any connection managers started during this test so they
      # don't leak into sibling tests (the DynamicSupervisor is app-level).
      for {target_id, _status} <- EvoGit.RemoteConnection.list_connections() do
        EvoGit.RemoteConnection.disconnect(target_id)
      end

      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    :ok
  end

  # Ensure the Registry + DynamicSupervisor are running (they are started by
  # EvoGit.Application, but other serial tests may have interfered).
  defp ensure_registry_and_supervisor do
    if Process.whereis(EvoGit.RemoteConnection.Registry) == nil do
      start_supervised!({Registry, keys: :unique, name: EvoGit.RemoteConnection.Registry})
    end

    if Process.whereis(EvoGit.RemoteConnection.Supervisor) == nil do
      start_supervised!(
        {DynamicSupervisor, name: EvoGit.RemoteConnection.Supervisor, strategy: :one_for_one}
      )
    end
  end

  # Saves a test target and returns its id.
  # Uses a unique ssh_target so each test gets a distinct target_id, avoiding
  # stale GenServer lookups from prior tests sharing the same id.
  defp save_test_target(opts \\ []) do
    unique = System.unique_integer([:positive])
    base = %{ssh_target: "test#{unique}@example.com", dist_port: 9999}
    {:ok, target} = EvoGit.RemoteConnections.save(Map.merge(base, Map.new(opts)))
    target.id
  end

  # Cleanly stops any connection managers we started during a test.
  defp cleanup_connections do
    connections = EvoGit.RemoteConnection.list_connections()

    for {target_id, _status} <- connections do
      EvoGit.RemoteConnection.disconnect(target_id)
    end
  end

  describe "list_connections/0" do
    test "returns %{} with no active connections" do
      ensure_registry_and_supervisor()
      cleanup_connections()

      assert EvoGit.RemoteConnection.list_connections() == %{}
    end
  end

  describe "status/1" do
    test "returns disconnected default for a non-existent target_id" do
      ensure_registry_and_supervisor()

      assert EvoGit.RemoteConnection.status("does-not-exist") == %{
               phase: :disconnected,
               node: nil,
               last_error: nil,
               target: nil
             }
    end
  end

  describe "connected?/1" do
    test "returns false for a non-existent target_id" do
      ensure_registry_and_supervisor()

      assert EvoGit.RemoteConnection.connected?("does-not-exist") == false
    end
  end

  describe "disconnect/1" do
    test "returns :ok for a non-existent target_id (graceful no-op)" do
      ensure_registry_and_supervisor()

      assert EvoGit.RemoteConnection.disconnect("does-not-exist") == :ok
    end
  end

  describe "bootstrap/1" do
    test "auto-download path: no local_binary_path probes the remote (fails on unreachable host)" do
      ensure_registry_and_supervisor()
      target_id = save_test_target()

      assert {:error, {:probe_failed, _}} = EvoGit.RemoteConnection.bootstrap(target_id)

      cleanup_connections()
    end

    test "set-but-missing local_binary_path falls back to auto-download (probe fails)" do
      ensure_registry_and_supervisor()
      target_id = save_test_target(local_binary_path: "/nonexistent/path/to/tarball.tar.gz")

      assert {:error, {:probe_failed, _}} = EvoGit.RemoteConnection.bootstrap(target_id)

      cleanup_connections()
    end

    test "platform override skips the probe and fails at download" do
      ensure_registry_and_supervisor()
      target_id = save_test_target(platform: "linux_x64")

      # download_url/1 queries the live GitHub API. With network it resolves
      # then the remote curl fails at the ssh level ({:download_failed,
      # {:exit_status, _}}); with no network Req fails fast and the local curl
      # fallback also fails ({:download_failed, {:local, _}}). Keep the
      # assertion broad.
      assert {:error, {:download_failed, _}} = EvoGit.RemoteConnection.bootstrap(target_id)

      cleanup_connections()
    end

    test "invalid platform override fails fast" do
      ensure_registry_and_supervisor()
      target_id = save_test_target(platform: "bogus")

      assert {:error, {:invalid_platform, "bogus"}} = EvoGit.RemoteConnection.bootstrap(target_id)

      cleanup_connections()
    end

    test "unsupported platform override (windows) fails fast" do
      ensure_registry_and_supervisor()
      target_id = save_test_target(platform: "windows_x64")

      assert {:error, :unsupported_platform} = EvoGit.RemoteConnection.bootstrap(target_id)

      cleanup_connections()
    end

    test "local_binary_path that exists still uploads (scp fails on unreachable host)" do
      ensure_registry_and_supervisor()

      tmp =
        Path.join(
          System.tmp_dir!(),
          "evogit-test-tarball-#{System.unique_integer([:positive])}.tar.gz"
        )

      File.write!(tmp, "fake tarball")
      target_id = save_test_target(local_binary_path: tmp)

      assert {:error, {:scp_failed, _}} = EvoGit.RemoteConnection.bootstrap(target_id)

      File.rm!(tmp)
      cleanup_connections()
    end
  end

  describe "connect/1" do
    test "does not return :local_node_not_distributed (auto-enables distribution)" do
      ensure_registry_and_supervisor()
      target_id = save_test_target()

      # With the fix, do_connect auto-enables distribution instead of
      # returning :local_node_not_distributed. The actual SSH connection
      # will fail (no real remote), but the error should be something else
      # (e.g. :distribution_failed or :node_connect_failed).
      result = EvoGit.RemoteConnection.connect(target_id)
      refute match?({:error, :local_node_not_distributed}, result)

      cleanup_connections()
    end
  end

  describe "find_free_port/0" do
    test "returns a valid port number on loopback" do
      assert {:ok, port} = EvoGit.RemoteConnection.find_free_port()
      assert is_integer(port)
      assert port > 0
      assert port <= 65535
    end

    test "returns a different port when called twice in sequence" do
      {:ok, port1} = EvoGit.RemoteConnection.find_free_port()
      {:ok, port2} = EvoGit.RemoteConnection.find_free_port()
      # Ports should differ since we close the socket between calls
      assert port1 != port2
    end
  end

  describe "build_tunnel_command/1 — internal behavior" do
    # The function is private, but we can test the port-separation logic
    # by verifying the GenServer's connection flow doesn't produce port conflicts.
    # For now, verify that find_free_port is used and tested independently.
  end
end
