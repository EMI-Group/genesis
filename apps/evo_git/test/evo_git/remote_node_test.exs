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
  alias EvoGit.TaskInfo

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

  describe "list_tasks_changed_since/2" do
    test "returns [] when the remote node is unreachable" do
      assert RemoteNode.list_tasks_changed_since(@fake_remote, "2000-01-01T00:00:00.000Z") == []
    end

    test "local path delegates to RemoteAPI → TaskRegistry (returns [])" do
      # On the local node, list_tasks_changed_since/2 calls
      # RemoteAPI.list_tasks_changed_since/1 → TaskRegistry.list_tasks_changed_since/1
      # → Store.select_tasks_changed_since/2. With an empty shared store, no task
      # has updated_at > the given since, so [].
      assert RemoteNode.list_tasks_changed_since(node(), "2000-01-01T00:00:00.000Z") == []
    end

    test "local path returns summaries newer than the since" do
      id = "changed-since-#{System.unique_integer([:positive])}"

      # Insert directly into the shared app store (same pattern as
      # task_registry/cleanup_test.exs). updated_at is store-internal
      # bookkeeping set to DateTime.utc_now() at insert time, so any task is
      # strictly newer than a year-2000 since. Clean up in on_exit so the
      # shared store stays empty for the other async tests.
      task = %TaskInfo{
        id: id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now()
      }

      on_exit(fn ->
        EvoGit.Store.delete_tasks(EvoGit.Store, [id])
      end)

      :ok = EvoGit.Store.put_task(EvoGit.Store, task)

      results = RemoteNode.list_tasks_changed_since(node(), "2000-01-01T00:00:00.000Z")
      summary = Enum.find(results, &(&1.id == id))
      refute is_nil(summary)

      # The summary projection has exactly the 16 lightweight keys.
      summary_keys = [
        :agent_count,
        :base_sha,
        :branch_name,
        :commit_sha,
        :finished_at,
        :id,
        :lease_expires_at,
        :model_id,
        :opts,
        :project_path,
        :result,
        :review_status,
        :started_at,
        :status,
        :type,
        :updated_at
      ]

      assert Enum.sort(Map.keys(summary)) == Enum.sort(summary_keys)
      # updated_at is the raw fixed-precision ISO string.
      assert is_binary(summary.updated_at)

      # A far-future since excludes everything.
      assert RemoteNode.list_tasks_changed_since(node(), "2999-01-01T00:00:00.000Z") == []
    end
  end

  describe "list_tasks_summary/2" do
    test "returns [] when the remote node is unreachable" do
      assert RemoteNode.list_tasks_summary(@fake_remote) == []
    end

    test "local path delegates to RemoteAPI → TaskRegistry (returns [])" do
      assert RemoteNode.list_tasks_summary(node()) == []
    end
  end

  describe "list_path_suggestions/2" do
    test "returns [] when the remote node is unreachable" do
      assert RemoteNode.list_path_suggestions(@fake_remote, "/tmp") == []
    end

    test "local path delegates to EvoGit.PathSuggestions.suggest/1" do
      assert RemoteNode.list_path_suggestions(node(), nil) == []
      assert RemoteNode.list_path_suggestions(node(), "") == []

      # A real temp dir listed via the trailing-separator branch.
      base = Path.join(System.tmp_dir!(), "evogit_rn_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf!(base) end)
      File.write!(Path.join(base, "suggested.txt"), "")

      assert RemoteNode.list_path_suggestions(node(), base <> "/") == [
               Path.join(base, "suggested.txt")
             ]
    end
  end

  describe "dir?/2" do
    test "returns false when the remote node is unreachable" do
      assert RemoteNode.dir?(@fake_remote, "/tmp") == false
    end

    test "local path delegates to File.dir?/1" do
      assert RemoteNode.dir?(node(), System.tmp_dir!()) == true
      assert RemoteNode.dir?(node(), "/definitely/not/a/real/dir") == false
    end
  end

  describe "RemoteAPI direct delegation" do
    test "list_tasks_changed_since/1 delegates to the running TaskRegistry (returns [])" do
      # Direct RemoteAPI call — delegates to TaskRegistry → Store; the shared
      # store is empty at this point, so no task is newer than the since.
      assert EvoGit.AgentScheduler.RemoteAPI.list_tasks_changed_since("2000-01-01T00:00:00.000Z") ==
               []
    end

    test "list_tasks_summary/0 delegates to the running TaskRegistry (returns [])" do
      assert EvoGit.AgentScheduler.RemoteAPI.list_tasks_summary() == []
    end
  end
end
