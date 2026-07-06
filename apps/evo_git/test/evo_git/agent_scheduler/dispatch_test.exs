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
    test "strips .genesis/workers suffix from worktree path" do
      spec = %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/home/user/primary"},
        phylo_node: %PhyloGraphNode{
          repo: "/home/user/primary/.genesis/workers/worker_T1_A1",
          base_commit: "abc123",
          current_commit: "abc123"
        },
        agent_module: DummyAgent,
        objective: "test",
        repo_id: "primary"
      }

      state = %State{}

      assert Dispatch.resolve_agent_repo_root(spec, state) == "/home/user/primary"
    end

    test "strips .genesis/workers suffix with different worker id" do
      spec = %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/home/user/myproject"},
        phylo_node: %PhyloGraphNode{
          repo: "/home/user/myproject/.genesis/workers/worker_T5_A3",
          base_commit: "def456",
          current_commit: "def456"
        },
        agent_module: DummyAgent,
        objective: "test",
        repo_id: "primary"
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
        repo_id: "primary"
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
        repo_id: "original",
        foreign_repos: [
          ForeignRepo.new("original", "/home/user/original-proj"),
          ForeignRepo.new("reference", "/home/user/reference-proj")
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
        repo_id: "unknown_repo",
        foreign_repos: [
          ForeignRepo.new("original", "/home/user/original-proj")
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
        repo_id: "original",
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
        repo_id: "reference",
        foreign_repos: [
          ForeignRepo.new("original", "/home/user/original-proj"),
          ForeignRepo.new("reference", "/home/user/reference-proj")
        ]
      }

      state = %State{}

      assert Dispatch.resolve_agent_repo_root(spec, state) == reference_root
    end
  end

  # --- Model Profile Resolution ---

  describe "resolve_model_for_agent/2" do
    test "returns default profile when model_id is nil" do
      state =
        State.from_model_profiles([
          %{id: "default", model: "provider:default", temperature: 0.7},
          %{id: "fast", model: "provider:fast", temperature: 0.5}
        ])

      {model_id, model, params} = Dispatch.resolve_model_for_agent(state, nil)

      assert model_id == "default"
      assert model == "provider:default"
      assert Keyword.get(params, :temperature) == 0.7
    end

    test "returns the requested profile when model_id is specified" do
      state =
        State.from_model_profiles([
          %{id: "default", model: "provider:default", temperature: 0.7},
          %{id: "fast", model: "provider:fast", temperature: 0.5}
        ])

      {model_id, model, params} = Dispatch.resolve_model_for_agent(state, "fast")

      assert model_id == "fast"
      assert model == "provider:fast"
      assert Keyword.get(params, :temperature) == 0.5
    end

    test "falls back to default when requested model_id is not found" do
      state =
        State.from_model_profiles([
          %{id: "default", model: "provider:default"}
        ])

      {model_id, model, _params} = Dispatch.resolve_model_for_agent(state, "nonexistent")

      assert model_id == "default"
      assert model == "provider:default"
    end

    test "returns state defaults when no profiles configured" do
      state = %State{
        model_profiles: [],
        llm_model: "legacy:model",
        llm_generation_params: [temperature: 0.9]
      }

      {model_id, model, params} = Dispatch.resolve_model_for_agent(state, nil)

      assert model_id == "default"
      assert model == "legacy:model"
      assert Keyword.get(params, :temperature) == 0.9
    end
  end

  # --- AgentSpec model_id extraction ---

  describe "AgentSpec.new/5 model_id extraction" do
    test "extracts model_id from opts" do
      spec =
        AgentSpec.new(
          %ContextNode{path: "./", repo: "/tmp"},
          %PhyloGraphNode{repo: "/tmp", base_commit: "a", current_commit: "a"},
          DummyAgent,
          "test",
          model_id: "fast"
        )

      assert spec.model_id == "fast"
    end

    test "defaults model_id to nil when not in opts" do
      spec =
        AgentSpec.new(
          %ContextNode{path: "./", repo: "/tmp"},
          %PhyloGraphNode{repo: "/tmp", base_commit: "a", current_commit: "a"},
          DummyAgent,
          "test"
        )

      assert spec.model_id == nil
    end
  end
end
