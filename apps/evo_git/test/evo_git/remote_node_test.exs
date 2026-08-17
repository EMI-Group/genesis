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

  alias EvoGit.Adapters.Git
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
      # Graceful cancel_task on a non-existent task returns {:error, :not_found}.
      assert RemoteNode.cancel_task(node(), "abc123") == {:error, :not_found}
    end
  end

  describe "force_kill_task/2" do
    test "returns {:error, _} when the remote node is unreachable" do
      assert {:error, _} = RemoteNode.force_kill_task(@fake_remote, "abc123")
    end

    test "local path delegates to RemoteAPI → TaskRegistry (returns {:error, :not_found})" do
      # force_kill_task on a non-existent task returns {:error, :not_found}.
      assert RemoteNode.force_kill_task(node(), "abc123") == {:error, :not_found}
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

      # The summary projection has exactly the 15 lightweight keys (`result` is
      # deliberately excluded from the summary projection).
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

  describe "get_task/2" do
    test "returns nil when the remote node is unreachable" do
      assert RemoteNode.get_task(@fake_remote, "abc123") == nil
    end

    test "local path returns nil for a missing task" do
      assert RemoteNode.get_task(node(), "missing-task") == nil
    end

    test "local path returns the %TaskInfo{} for a persisted task" do
      id = "rn-get-task-#{System.unique_integer([:positive])}"

      task = %TaskInfo{
        id: id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now()
      }

      on_exit(fn ->
        EvoGit.Store.delete_tasks(EvoGit.Store, [id])
      end)

      :ok = EvoGit.Store.put_task(EvoGit.Store, task)

      assert %TaskInfo{} = result = RemoteNode.get_task(node(), id)
      assert result.id == id
      assert result.status == :running
      assert result.type == :genesis
    end
  end

  describe "set_review_status/3" do
    test "returns {:error, _} when the remote node is unreachable" do
      assert {:error, _} = RemoteNode.set_review_status(@fake_remote, "abc123", :merged)
    end

    test "local path returns :ok and persists review_status" do
      id = "rn-review-status-#{System.unique_integer([:positive])}"

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

      assert :ok = RemoteNode.set_review_status(node(), id, :merged)

      assert %TaskInfo{} = result = RemoteNode.get_task(node(), id)
      assert result.review_status == :merged
    end
  end

  describe "set_review_metadata/4" do
    test "returns {:error, _} when the remote node is unreachable" do
      assert {:error, _} =
               RemoteNode.set_review_metadata(@fake_remote, "abc123", "base123", "commit456")
    end

    test "local path returns :ok and persists base_sha/commit_sha" do
      id = "rn-review-meta-#{System.unique_integer([:positive])}"

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

      assert :ok = RemoteNode.set_review_metadata(node(), id, "base123", "commit456")

      assert %TaskInfo{} = result = RemoteNode.get_task(node(), id)
      assert result.base_sha == "base123"
      assert result.commit_sha == "commit456"
    end
  end

  describe "review wrappers (local-direct)" do
    # Replicates review_test.exs's repo-building helpers (private to that
    # module): init + identity config, commit_file, rename_current_branch.
    # Local-direct wrappers call RemoteAPI → Review, so the Review return
    # envelopes pass through verbatim.
    defp review_repo do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "evo_git_remote_node_review_" <> to_string(System.unique_integer())
        )

      File.mkdir_p!(tmp_dir)
      {:ok, _} = Git.init(tmp_dir)

      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      tmp_dir
    end

    defp commit_file(tmp_dir, path, content, message) do
      full_path = Path.join(tmp_dir, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, content)
      {:ok, _} = Git.add(tmp_dir, path)
      {:ok, _} = Git.commit(tmp_dir, message)
      Git.rev_parse(tmp_dir, "HEAD")
    end

    defp rename_current_branch(tmp_dir, new_name) do
      case Git.current_branch(tmp_dir) do
        {:ok, ^new_name} -> :ok
        {:ok, _other} -> System.cmd("git", ["branch", "-m", new_name], cd: tmp_dir)
      end
    end

    test "list_branches/2, branch_exists?/3, and default_merge_target/2 delegate through RemoteAPI" do
      tmp_dir = review_repo()
      {:ok, _base_sha} = commit_file(tmp_dir, "file.txt", "x\n", "Initial commit")
      rename_current_branch(tmp_dir, "main")
      System.cmd("git", ["branch", "alpha"], cd: tmp_dir)

      assert {:ok, branches} = RemoteNode.list_branches(node(), tmp_dir)
      assert "alpha" in branches

      # branch_exists? is a boolean predicate (mirrors Review/Git), not a
      # {:ok, bool} tuple — the envelope passes through verbatim.
      assert RemoteNode.branch_exists?(node(), tmp_dir, "alpha") == true
      assert RemoteNode.branch_exists?(node(), tmp_dir, "nope") == false

      assert {:ok, "main"} = RemoteNode.default_merge_target(node(), tmp_dir)
    end

    test "merge_branch/4 returns {:ok, sha} and deletes the branch" do
      tmp_dir = review_repo()
      {:ok, base_sha} = commit_file(tmp_dir, "base.txt", "base\n", "Initial commit")
      rename_current_branch(tmp_dir, "main")

      Git.create_branch(tmp_dir, "agent_branch", base_sha)
      Git.checkout(tmp_dir, "agent_branch")
      {:ok, feature_sha} = commit_file(tmp_dir, "feature.txt", "feature\n", "Feature commit")
      Git.checkout(tmp_dir, "main")

      assert {:ok, ^feature_sha} =
               RemoteNode.merge_branch(node(), tmp_dir, "agent_branch", "main")

      assert RemoteNode.branch_exists?(node(), tmp_dir, "agent_branch") == false
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

  describe "rpc_timeout/0 — :remote_rpc_timeout env override" do
    # The RPC timeout is read from app env at CALL time (call_remote/4 →
    # rpc_timeout/0), so tests can pin it without recompiling. The env key is
    # new and read by no other code, but we restore it in on_exit anyway.
    defp restore_rpc_timeout_env(previous) do
      if previous == nil do
        Application.delete_env(:evo_git, :remote_rpc_timeout)
      else
        Application.put_env(:evo_git, :remote_rpc_timeout, previous)
      end
    end

    test "defaults to 30_000 ms when the env key is unset" do
      previous = Application.get_env(:evo_git, :remote_rpc_timeout)
      on_exit(fn -> restore_rpc_timeout_env(previous) end)
      Application.delete_env(:evo_git, :remote_rpc_timeout)

      assert RemoteNode.rpc_timeout() == 30_000
    end

    test "honors the env override at call time" do
      previous = Application.get_env(:evo_git, :remote_rpc_timeout)
      on_exit(fn -> restore_rpc_timeout_env(previous) end)
      Application.put_env(:evo_git, :remote_rpc_timeout, 1)

      assert RemoteNode.rpc_timeout() == 1

      # The env-derived value is what call_remote/4 passes to :erpc.call/5:
      # with the tiny override in effect, the remote path still runs and
      # normalizes the (immediate) noconnection failure into {:error, _}.
      assert {:error, _} = RemoteNode.call_remote(@fake_remote, :erlang, :node, [])
    end

    test "a tiny timeout makes a slow :erpc.call fail with :timeout" do
      # Mechanism test (no second BEAM node needed): :erpc.call/5 respects the
      # timeout even when the target is the local node, so a sleeping function
      # plus a tiny timeout must fail fast with {:erpc, :timeout} — the exact
      # failure call_remote/4 normalizes into {:error, ...}. The same call
      # succeeds when given enough time, proving the timeout value is what
      # differentiates. This mirrors the production shape: a remote function
      # that sleeps longer than the RPC timeout.
      started = System.monotonic_time(:millisecond)

      caught =
        try do
          :erpc.call(node(), :timer, :sleep, [500], 100)
          nil
        catch
          kind, reason -> {kind, reason}
        end

      elapsed = System.monotonic_time(:millisecond) - started
      assert caught == {:error, {:erpc, :timeout}}
      assert elapsed < 400

      # Control: a generous timeout lets the same call complete.
      assert :ok = :erpc.call(node(), :timer, :sleep, [10], 5_000)
    end
  end
end
