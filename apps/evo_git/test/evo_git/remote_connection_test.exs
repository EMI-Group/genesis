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
      start_supervised!({DynamicSupervisor, name: EvoGit.RemoteConnection.Supervisor, strategy: :one_for_one})
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
    test "returns {:error, :no_binary_path} when local_binary_path is nil" do
      ensure_registry_and_supervisor()
      target_id = save_test_target()

      assert {:error, :no_binary_path} = EvoGit.RemoteConnection.bootstrap(target_id)

      cleanup_connections()
    end

    test "returns {:error, :binary_not_found} when the file doesn't exist" do
      ensure_registry_and_supervisor()
      target_id = save_test_target(local_binary_path: "/nonexistent/path/to/binary")

      assert {:error, :binary_not_found} = EvoGit.RemoteConnection.bootstrap(target_id)

      cleanup_connections()
    end
  end

  describe "connect/1" do
    test "returns {:error, :local_node_not_distributed} when node is nonode@nohost" do
      ensure_registry_and_supervisor()
      target_id = save_test_target()

      # In the test environment, the BEAM is not distributed.
      assert node() == :nonode@nohost

      assert {:error, :local_node_not_distributed} = EvoGit.RemoteConnection.connect(target_id)

      cleanup_connections()
    end
  end
end
