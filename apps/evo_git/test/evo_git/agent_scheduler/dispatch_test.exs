defmodule EvoGit.AgentScheduler.DispatchTest do
  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentSpec
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode

  defmodule DummyAgent do
    def run(_objective, _ctx), do: {:ok, :done}
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

  describe "resolve_agent_repo_root/2 with repo-less agent" do
    test "returns a binary for a repo-less agent without crashing on nil phylo_node" do
      spec =
        AgentSpec.new(
          %ContextNode{path: "./", repo: "/tmp"},
          nil,
          EvoGit.Agents.SelfReflective,
          "reflect on the codebase",
          repo_less: true
        )

      result = Dispatch.resolve_agent_repo_root(spec, %State{})

      # Never a KeyError on the nil phylo_node — a plain binary root instead
      # (in the test env this is typically File.cwd!(); do not hardcode it).
      assert is_binary(result)
      assert result != ""
    end

    test "prefers the :self_reflective_source_root app env when set" do
      original = Application.get_env(:evo_git, :self_reflective_source_root)

      try do
        Application.put_env(:evo_git, :self_reflective_source_root, "/tmp/fake-source")

        spec =
          AgentSpec.new(
            %ContextNode{path: "./", repo: "/tmp"},
            nil,
            EvoGit.Agents.SelfReflective,
            "x",
            repo_less: true
          )

        assert Dispatch.resolve_agent_repo_root(spec, %State{}) == "/tmp/fake-source"
      after
        case original do
          nil -> Application.delete_env(:evo_git, :self_reflective_source_root)
          _ -> Application.put_env(:evo_git, :self_reflective_source_root, original)
        end
      end
    end

    test "falls back to the GENESIS_SOURCE_ROOT env var when the app env is absent" do
      original_app_env = Application.get_env(:evo_git, :self_reflective_source_root)
      original_sys_env = System.get_env("GENESIS_SOURCE_ROOT")

      try do
        Application.delete_env(:evo_git, :self_reflective_source_root)
        System.put_env("GENESIS_SOURCE_ROOT", "/tmp/from-env")

        spec =
          AgentSpec.new(
            %ContextNode{path: "./", repo: "/tmp"},
            nil,
            EvoGit.Agents.SelfReflective,
            "x",
            repo_less: true
          )

        assert Dispatch.resolve_agent_repo_root(spec, %State{}) == "/tmp/from-env"
      after
        case original_app_env do
          nil -> Application.delete_env(:evo_git, :self_reflective_source_root)
          _ -> Application.put_env(:evo_git, :self_reflective_source_root, original_app_env)
        end

        case original_sys_env do
          nil -> System.delete_env("GENESIS_SOURCE_ROOT")
          _ -> System.put_env("GENESIS_SOURCE_ROOT", original_sys_env)
        end
      end
    end
  end

  describe "commit_pending_in_worktree/0 with repo-less agent" do
    test "returns :ok without touching git when repo_less is set" do
      Process.put(:repo_path, "/nonexistent")
      Process.put(:repo_less, true)

      try do
        # No git is attempted (the repo path is deliberately bogus) — the
        # repo_less branch short-circuits before any adapter call.
        assert Dispatch.commit_pending_in_worktree() == :ok
      after
        Process.delete(:repo_less)
        Process.delete(:repo_path)
      end
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

  # --- try_dispatch: no worktree I/O ---

  describe "try_dispatch/2 performs no worktree I/O" do
    test "computes the worktree path, spawns the agent task, and never creates the workers dir" do
      repo_root =
        Path.join(System.tmp_dir!(), "dispatch_io_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(repo_root)
      {:ok, _} = Git.init(repo_root)
      File.write!(Path.join(repo_root, "README.md"), "initial")
      {:ok, _} = Git.add(repo_root)
      {:ok, _} = Git.commit(repo_root, "initial")
      {:ok, sha} = Git.rev_parse(repo_root)
      on_exit(fn -> File.rm_rf!(repo_root) end)

      spec = %AgentSpec{
        context_node: %ContextNode{path: "./", repo: repo_root},
        phylo_node: %PhyloGraphNode{repo: repo_root, base_commit: sha, current_commit: sha},
        agent_module: DummyAgent,
        objective: "test",
        repo_id: "primary"
      }

      # Unique next_agent_id so the ETS key cannot collide with other async test files.
      state = %State{next_agent_id: :erlang.unique_integer([:positive])}
      task_id = "task-io-#{:erlang.unique_integer([:positive])}"

      {agent_id, state} = Dispatch.register_agent(state, spec, nil, nil, 0, task_id, 1)
      new_state = Dispatch.try_dispatch(state, agent_id)

      on_exit(fn ->
        Store.delete_agent_state(agent_id)
        Store.delete_sched_meta(agent_id)
      end)

      # The strongest observable: try_dispatch performs NO filesystem I/O —
      # no .genesis/workers directory is ever created.
      refute File.dir?(Path.join(repo_root, ".genesis/workers"))

      # The computed worktree path is stored in sched_meta so cancel_agent can
      # find the worktree even before the agent's Runner creates it.
      {:ok, meta} = Store.get_sched_meta(agent_id)
      assert meta.worktree == Path.join([repo_root, ".genesis/workers", "worker_T1_A1"])

      # The agent task was spawned and tracked in ref_to_agent; its result
      # message is delivered to the caller (this test process).
      assert map_size(new_state.ref_to_agent) == 1
      [ref] = Map.keys(new_state.ref_to_agent)
      assert Map.get(new_state.ref_to_agent, ref) == agent_id
      assert_receive {^ref, {:ok, :done}}
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
