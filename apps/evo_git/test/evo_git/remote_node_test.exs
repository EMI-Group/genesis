defmodule EvoGit.RemoteNodeTest do
  @moduledoc """
  Tests for `EvoGit.RemoteNode` — local/remote branching wrappers for RPC.

  Tests focus on:
    * Remote-node error fallbacks (when the remote node is unreachable, each
      function returns its safe default).
    * Local-node delegation (when `node == node()`, the function calls the
      RemoteAPI function, which delegates to TaskRegistry).

  We cannot easily test the happy-path remote call (it requires a real remote
  BEAM node with the full app started), but the error-fallback tests exercise
  the same `call_remote/4` → `:erpc.call/5` path.

  Note: the evo_git application auto-starts via `mod: {EvoGit.Application, []}`,
  so `EvoGit.TaskRegistry` IS running during tests. The local-path tests verify
  delegation succeeds and returns expected defaults for an empty registry.
  """

  use ExUnit.Case, async: true

  alias EvoGit.RemoteNode

  # A node name that definitely does not exist on this machine.
  # On a non-distributed local node (:nonode@nohost), :erpc.call to any foreign
  # node fails immediately with {:erpc, :noconnection} — no TCP timeout wait.
  @fake_remote :"nonexistent@127.0.0.1"

  describe "list_tasks/1" do
    test "returns [] when the remote node is unreachable" do
      assert RemoteNode.list_tasks(@fake_remote) == []
    end

    test "local path delegates to RemoteAPI → TaskRegistry (returns [])" do
      # On the local node, list_tasks/1 calls RemoteAPI.list_tasks/0 which calls
      # TaskRegistry.list_tasks/0 (GenServer.call). Since the app auto-starts,
      # TaskRegistry is running and returns [] for an empty registry.
      assert RemoteNode.list_tasks(node()) == []
    end
  end

  describe "list_tasks_paginated/2" do
    test "returns {[], 0} when the remote node is unreachable" do
      assert RemoteNode.list_tasks_paginated(@fake_remote) == {[], 0}
    end

    test "accepts opts on the remote path" do
      assert RemoteNode.list_tasks_paginated(@fake_remote, limit: 10, offset: 5) == {[], 0}
    end

    test "local path delegates to RemoteAPI → TaskRegistry (returns {[], 0})" do
      assert RemoteNode.list_tasks_paginated(node()) == {[], 0}
    end
  end

  describe "get_unique_paths/1" do
    test "returns [] when the remote node is unreachable" do
      assert RemoteNode.get_unique_paths(@fake_remote) == []
    end

    test "local path delegates to RemoteAPI → TaskRegistry (returns [])" do
      assert RemoteNode.get_unique_paths(node()) == []
    end
  end

  describe "cancel_task/2" do
    test "returns {:error, _} when the remote node is unreachable" do
      assert {:error, _} = RemoteNode.cancel_task(@fake_remote, "abc123")
    end

    test "local path delegates to RemoteAPI → TaskRegistry (returns {:error, :not_found})" do
      # cancel_task on a non-existent task returns {:error, :not_found}.
      assert RemoteNode.cancel_task(node(), "abc123") == {:error, :not_found}
    end
  end

  describe "delete_task/2" do
    test "returns {:error, _} when the remote node is unreachable" do
      assert {:error, _} = RemoteNode.delete_task(@fake_remote, "abc123")
    end

    test "local path delegates to RemoteAPI → TaskRegistry (cast returns :ok)" do
      # delete_task is a GenServer.cast (fire-and-forget), so it always returns
      # :ok immediately regardless of whether the task exists.
      assert RemoteNode.delete_task(node(), "abc123") == :ok
    end
  end

  describe "clear_finished_tasks/1" do
    test "returns {:error, _} when the remote node is unreachable" do
      assert {:error, _} = RemoteNode.clear_finished_tasks(@fake_remote)
    end

    test "local path delegates to RemoteAPI → TaskRegistry (returns :ok)" do
      assert RemoteNode.clear_finished_tasks(node()) == :ok
    end
  end
end
