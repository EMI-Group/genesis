defmodule EvoGit.AgentScheduler.SubagentsTest do
  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.Subagents
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # Dummy agent modules for testing agent_type dispatch

  defmodule DummyReadOnlyAgent do
    def agent_type, do: :read
  end

  defmodule DummyReadWriteAgent do
    def agent_type, do: :read_write
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
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: :primary)

      spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: :original,
          agent_module: DummyReadOnlyAgent
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec) == :ok
    end

    test "rejects read-write agent when repo ids differ" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: :primary)

      spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: :original,
          agent_module: DummyReadWriteAgent
        )

      assert {:error, {:foreign_repo_read_only, msg}} =
               Subagents.validate_spatial_contract_for_spec(1, parent, spec)

      assert msg =~ "Read-write agents cannot be spawned in foreign repositories"
    end

    test "error message mentions read-only alternatives" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: :primary)

      spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: :original,
          agent_module: DummyReadWriteAgent
        )

      {:error, {:foreign_repo_read_only, msg}} =
        Subagents.validate_spatial_contract_for_spec(1, parent, spec)

      assert msg =~ "subagent_codebase_investigator"
      assert msg =~ "subagent_task_scheduler"
    end

    test "cross-repo rules apply even between two different foreign repos" do
      # Parent is in :original, child targets :reference
      parent = parent_state(path: "./", repo: "/home/user/original", repo_id: :original)

      read_only_spec =
        spec(
          path: "./src",
          repo: "/home/user/reference",
          repo_id: :reference,
          agent_module: DummyReadOnlyAgent
        )

      read_write_spec =
        spec(
          path: "./src",
          repo: "/home/user/reference",
          repo_id: :reference,
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
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: :primary)

      spec =
        spec(
          path: "./src",
          repo: "/home/user/primary",
          repo_id: :primary,
          agent_module: DummyReadWriteAgent
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec) == :ok
    end

    test "rejects read-write child at sibling path" do
      parent = parent_state(path: "./src", repo: "/home/user/primary", repo_id: :primary)

      spec =
        spec(
          path: "./lib",
          repo: "/home/user/primary",
          repo_id: :primary,
          agent_module: DummyReadWriteAgent
        )

      assert {:error, {:spatial_contract_violation, msg}} =
               Subagents.validate_spatial_contract_for_spec(1, parent, spec)

      assert msg =~ "read-write"
    end

    test "allows read-only child at any path regardless of parent" do
      parent = parent_state(path: "./src", repo: "/home/user/primary", repo_id: :primary)

      spec =
        spec(
          path: "./lib",
          repo: "/home/user/primary",
          repo_id: :primary,
          agent_module: DummyReadOnlyAgent
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec) == :ok
    end
  end
end
