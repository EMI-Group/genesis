defmodule EvoGit.AgentScheduler.SubagentsTest do
  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Subagents
  alias EvoGit.Agent.Result
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # Dummy agent modules for testing agent_type dispatch

  defmodule DummyReadOnlyAgent do
    def agent_type, do: :read
    def delegation_level, do: :high
  end

  defmodule DummyReadWriteAgent do
    def agent_type, do: :read_write
    def delegation_level, do: :high
  end

  # --- Helpers ---

  defp parent_state(path: path, repo: repo, repo_id: repo_id) do
    %{
      context_node: %ContextNode{path: path, repo: repo},
      repo_id: repo_id
    }
  end

  defp spec(path: path, repo: repo, repo_id: repo_id, agent_module: agent_module) do
    %AgentSpec{
      context_node: %ContextNode{path: path, repo: repo},
      phylo_node: %PhyloGraphNode{repo: repo, base_commit: "abc123", current_commit: "abc123"},
      agent_module: agent_module,
      objective: "test objective",
      repo_id: repo_id
    }
  end

  # --- Cross-repo delegation ---

  describe "validate_spatial_contract_for_spec/3 — cross-repo delegation" do
    test "allows read-only agent when repo ids differ" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadOnlyAgent
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec) == :ok
    end

    test "rejects read-write agent when repo ids differ" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadWriteAgent
        )

      assert {:error, {:foreign_repo_read_only, msg}} =
               Subagents.validate_spatial_contract_for_spec(1, parent, spec)

      assert msg =~ "Read-write agents cannot be spawned in foreign repositories"
    end

    test "error message mentions read-only alternatives" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadWriteAgent
        )

      {:error, {:foreign_repo_read_only, msg}} =
        Subagents.validate_spatial_contract_for_spec(1, parent, spec)

      assert msg =~ "subagent_codebase_investigator"
      assert msg =~ "subagent_task_scheduler"
    end

    test "cross-repo rules apply even between two different foreign repos" do
      # Parent is in :original, child targets :reference
      parent = parent_state(path: "./", repo: "/home/user/original", repo_id: "original")

      read_only_spec =
        spec(
          path: "./src",
          repo: "/home/user/reference",
          repo_id: "reference",
          agent_module: DummyReadOnlyAgent
        )

      read_write_spec =
        spec(
          path: "./src",
          repo: "/home/user/reference",
          repo_id: "reference",
          agent_module: DummyReadWriteAgent
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, read_only_spec) == :ok

      assert {:error, {:foreign_repo_read_only, _}} =
               Subagents.validate_spatial_contract_for_spec(1, parent, read_write_spec)
    end
  end

  # --- Same-repo delegation ---

  describe "validate_spatial_contract_for_spec/3 — same-repo delegation" do
    test "allows read-write child at descendant path" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./src",
          repo: "/home/user/primary",
          repo_id: "primary",
          agent_module: DummyReadWriteAgent
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec) == :ok
    end

    test "rejects read-write child at sibling path" do
      parent = parent_state(path: "./src", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./lib",
          repo: "/home/user/primary",
          repo_id: "primary",
          agent_module: DummyReadWriteAgent
        )

      assert {:error, {:spatial_contract_violation, msg}} =
               Subagents.validate_spatial_contract_for_spec(1, parent, spec)

      assert msg =~ "read-write"
    end

    test "allows read-only child at any path regardless of parent" do
      parent = parent_state(path: "./src", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./lib",
          repo: "/home/user/primary",
          repo_id: "primary",
          agent_module: DummyReadOnlyAgent
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec) == :ok
    end
  end

  # --- Foreign repo commit tracking ---

  describe "store_sub_result/3 — foreign repo commit tracking" do
    setup do
      # Ensure ETS tables exist (app may already create them)
      ensure_ets_table(:evogit_sched_meta)
      ensure_ets_table(:evogit_agent_state)

      on_exit(fn ->
        # Clean up test entries (don't delete the tables themselves)
        :ets.delete(:evogit_sched_meta, 1)
      end)

      :ok
    end

    defp ensure_ets_table(name) do
      if :ets.whereis(name) == :undefined do
        :ets.new(name, [:set, :public, :named_table])
      end
    end

    defp base_sched_meta(parent_id, sub_indices) do
      %SchedMeta{
        id: parent_id,
        depth: 0,
        spec: %AgentSpec{
          context_node: %ContextNode{path: "./", repo: "/test"},
          phylo_node: %PhyloGraphNode{repo: "/test", base_commit: "abc", current_commit: "abc"},
          agent_module: nil,
          objective: "test",
          repo_id: "primary"
        },
        sub_agent_indices: sub_indices,
        sub_agent_results: %{},
        foreign_repo_commits: %{}
      }
    end

    test "tracks foreign repo commit SHA when subagent result has repo_id" do
      parent_id = 1
      sub_id = 2

      parent_meta = base_sched_meta(parent_id, %{sub_id => 0})
      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      result = {:ok, %Result{result: "done", commit_sha: "def456", repo_id: "original"}}

      Subagents.store_sub_result(parent_id, sub_id, result)

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      assert updated.foreign_repo_commits == %{"original" => "def456"}
      assert updated.sub_agent_results == %{0 => result}
    end

    test "accumulates commits from multiple foreign repos" do
      parent_id = 1

      parent_meta = base_sched_meta(parent_id, %{10 => 0, 11 => 1})
      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      result1 = {:ok, %Result{result: "done1", commit_sha: "sha1", repo_id: "original"}}
      result2 = {:ok, %Result{result: "done2", commit_sha: "sha2", repo_id: "reference"}}

      Subagents.store_sub_result(parent_id, 10, result1)
      Subagents.store_sub_result(parent_id, 11, result2)

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      assert updated.foreign_repo_commits == %{"original" => "sha1", "reference" => "sha2"}
    end

    test "does not track primary repo commits" do
      parent_id = 1
      sub_id = 2

      parent_meta = base_sched_meta(parent_id, %{sub_id => 0})
      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      result = {:ok, %Result{result: "done", commit_sha: "abc123", repo_id: "primary"}}

      Subagents.store_sub_result(parent_id, sub_id, result)

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      assert updated.foreign_repo_commits == %{}
    end

    test "does not track error results" do
      parent_id = 1
      sub_id = 2

      parent_meta = %SchedMeta{
        base_sched_meta(parent_id, %{sub_id => 0})
        | foreign_repo_commits: %{"original" => "existing_sha"}
      }

      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      Subagents.store_sub_result(parent_id, sub_id, {:error, :some_error})

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      # Existing commits preserved, no new entry added
      assert updated.foreign_repo_commits == %{"original" => "existing_sha"}
    end

    test "updates existing foreign repo commit to latest SHA" do
      parent_id = 1

      parent_meta = base_sched_meta(parent_id, %{10 => 0, 11 => 1})
      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      result1 = {:ok, %Result{result: "first", commit_sha: "sha_v1", repo_id: "original"}}
      result2 = {:ok, %Result{result: "second", commit_sha: "sha_v2", repo_id: "original"}}

      Subagents.store_sub_result(parent_id, 10, result1)
      Subagents.store_sub_result(parent_id, 11, result2)

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      # Second result overwrites first for same repo
      assert updated.foreign_repo_commits == %{"original" => "sha_v2"}
    end
  end
end
