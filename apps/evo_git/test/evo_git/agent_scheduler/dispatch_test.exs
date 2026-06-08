defmodule EvoGit.AgentScheduler.DispatchTest do
  use ExUnit.Case, async: true

  alias EvoGit.AgentSpec
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.State
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode

  defmodule DummyAgent do
  end

  describe "resolve_agent_repo_root/2 with primary repo" do
    test "strips .evogit/workers suffix from worktree path" do
      spec = %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/home/user/primary"},
        phylo_node: %PhyloGraphNode{
          repo: "/home/user/primary/.evogit/workers/worker_T1_A1",
          base_commit: "abc123",
          current_commit: "abc123"
        },
        agent_module: DummyAgent,
        objective: "test",
        repo_id: :primary
      }

      state = %State{}

      assert Dispatch.resolve_agent_repo_root(spec, state) == "/home/user/primary"
    end

    test "strips .evogit/workers suffix with different worker id" do
      spec = %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/home/user/myproject"},
        phylo_node: %PhyloGraphNode{
          repo: "/home/user/myproject/.evogit/workers/worker_T5_A3",
          base_commit: "def456",
          current_commit: "def456"
        },
        agent_module: DummyAgent,
        objective: "test",
        repo_id: :primary
      }

      state = %State{}

      assert Dispatch.resolve_agent_repo_root(spec, state) == "/home/user/myproject"
    end

    test "returns repo root as-is when no worktree suffix" do
      spec = %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/home/user/primary"},
        phylo_node: %PhyloGraphNode{
          repo: "/home/user/primary",
          base_commit: "abc123",
          current_commit: "abc123"
        },
        agent_module: DummyAgent,
        objective: "test",
        repo_id: :primary
      }

      state = %State{}

      assert Dispatch.resolve_agent_repo_root(spec, state) == "/home/user/primary"
    end
  end

  describe "resolve_agent_repo_root/2 with foreign repo" do
    test "returns foreign repo root when repo exists in spec" do
      original_root = Path.expand("/home/user/original-proj")

      spec = %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/home/user/primary"},
        phylo_node: %PhyloGraphNode{
          repo: "/home/user/primary",
          base_commit: "abc123",
          current_commit: "abc123"
        },
        agent_module: DummyAgent,
        objective: "test",
        repo_id: :original,
        foreign_repos: [
          ForeignRepo.new(:original, "/home/user/original-proj"),
          ForeignRepo.new(:reference, "/home/user/reference-proj")
        ]
      }

      state = %State{}

      assert Dispatch.resolve_agent_repo_root(spec, state) == original_root
    end

    test "returns nil when foreign repo does not exist in spec" do
      spec = %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/home/user/primary"},
        phylo_node: %PhyloGraphNode{
          repo: "/home/user/primary",
          base_commit: "abc123",
          current_commit: "abc123"
        },
        agent_module: DummyAgent,
        objective: "test",
        repo_id: :unknown_repo,
        foreign_repos: [
          ForeignRepo.new(:original, "/home/user/original-proj")
        ]
      }

      state = %State{}

      assert Dispatch.resolve_agent_repo_root(spec, state) == nil
    end

    test "returns nil when foreign_repos list is empty" do
      spec = %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/home/user/primary"},
        phylo_node: %PhyloGraphNode{
          repo: "/home/user/primary",
          base_commit: "abc123",
          current_commit: "abc123"
        },
        agent_module: DummyAgent,
        objective: "test",
        repo_id: :original,
        foreign_repos: []
      }

      state = %State{}

      assert Dispatch.resolve_agent_repo_root(spec, state) == nil
    end

    test "resolves correct repo among multiple foreign repos" do
      reference_root = Path.expand("/home/user/reference-proj")

      spec = %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/home/user/primary"},
        phylo_node: %PhyloGraphNode{
          repo: "/home/user/primary",
          base_commit: "abc123",
          current_commit: "abc123"
        },
        agent_module: DummyAgent,
        objective: "test",
        repo_id: :reference,
        foreign_repos: [
          ForeignRepo.new(:original, "/home/user/original-proj"),
          ForeignRepo.new(:reference, "/home/user/reference-proj")
        ]
      }

      state = %State{}

      assert Dispatch.resolve_agent_repo_root(spec, state) == reference_root
    end
  end
end
