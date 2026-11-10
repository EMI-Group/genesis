defmodule EvoGit.AgentScheduler.DispatchTest do
  use ExUnit.Case, async: true

  alias EvoGit.AgentSpec
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode

  # A valid `EvoGit.Agent` role. Nothing in THIS module runs it: the tests below
  # exercise registration/model resolution and dispatch's own guard, while the
  # session-start contract lives in `session_dispatch_test.exs` (the session, not
  # the scheduler, runs the agent — `run/2` is no longer called at all).
  defmodule DummyAgent do
    use EvoGit.Agent

    def available_tools, do: []
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
      original_dir = Application.get_env(:evo_git, :self_reflective_source_dir)

      try do
        # Isolate the managed-dir step of the unified chain (point it at a
        # non-existent path) so a real managed clone under the real data dir
        # can never hijack the chain in tests.
        Application.put_env(
          :evo_git,
          :self_reflective_source_dir,
          "/nonexistent/evogit-selfref-source"
        )

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
      after
        case original_dir do
          nil -> Application.delete_env(:evo_git, :self_reflective_source_dir)
          _ -> Application.put_env(:evo_git, :self_reflective_source_dir, original_dir)
        end
      end
    end

    test "prefers the :self_reflective_source_root app env when set" do
      original = Application.get_env(:evo_git, :self_reflective_source_root)
      original_dir = Application.get_env(:evo_git, :self_reflective_source_dir)

      try do
        Application.put_env(:evo_git, :self_reflective_source_root, "/tmp/fake-source")

        Application.put_env(
          :evo_git,
          :self_reflective_source_dir,
          "/nonexistent/evogit-selfref-source"
        )

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

        case original_dir do
          nil -> Application.delete_env(:evo_git, :self_reflective_source_dir)
          _ -> Application.put_env(:evo_git, :self_reflective_source_dir, original_dir)
        end
      end
    end

    test "falls back to the GENESIS_SOURCE_ROOT env var when the app env is absent" do
      original_app_env = Application.get_env(:evo_git, :self_reflective_source_root)
      original_sys_env = System.get_env("GENESIS_SOURCE_ROOT")
      original_dir = Application.get_env(:evo_git, :self_reflective_source_dir)

      try do
        Application.delete_env(:evo_git, :self_reflective_source_root)
        System.put_env("GENESIS_SOURCE_ROOT", "/tmp/from-env")

        Application.put_env(
          :evo_git,
          :self_reflective_source_dir,
          "/nonexistent/evogit-selfref-source"
        )

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

        case original_dir do
          nil -> Application.delete_env(:evo_git, :self_reflective_source_dir)
          _ -> Application.put_env(:evo_git, :self_reflective_source_dir, original_dir)
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

  # --- Context Window Resolution ---

  describe "resolve_context_window/2" do
    test "returns the requested profile's context_window" do
      state =
        State.from_model_profiles([
          %{id: "default", model: "provider:default"},
          %{id: "big", model: "provider:big", context_window: 131_072}
        ])

      assert Dispatch.resolve_context_window(state, "big") == 131_072
    end

    test "resolves each profile's window independently" do
      state =
        State.from_model_profiles([
          %{id: "default", model: "provider:default"},
          %{id: "big", model: "provider:big", context_window: 131_072},
          %{id: "small", model: "provider:small", context_window: 32_768}
        ])

      assert Dispatch.resolve_context_window(state, "big") == 131_072
      assert Dispatch.resolve_context_window(state, "small") == 32_768
      # A profile with no explicit context_window falls back to the 200_000 default.
      assert Dispatch.resolve_context_window(state, "default") == 200_000
    end

    test "nil and empty model_id use the first profile's window" do
      state =
        State.from_model_profiles([
          %{id: "first", model: "provider:first", context_window: 131_072},
          %{id: "second", model: "provider:second", context_window: 32_768}
        ])

      assert Dispatch.resolve_context_window(state, nil) == 131_072
      assert Dispatch.resolve_context_window(state, "") == 131_072
    end

    test "an unknown model_id falls back to the first profile's window with a warning" do
      state =
        State.from_model_profiles([
          %{id: "first", model: "provider:first", context_window: 131_072},
          %{id: "second", model: "provider:second", context_window: 32_768}
        ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Dispatch.resolve_context_window(state, "nonexistent") == 131_072
        end)

      assert log =~ "Model profile 'nonexistent' not found"
    end

    test "returns the 200_000 default when no profiles are configured" do
      # Same shape resolve_model_for_agent/2 reads: empty model_profiles.
      state = %State{model_profiles: []}

      assert Dispatch.resolve_context_window(state, nil) == 200_000
      assert Dispatch.resolve_context_window(state, "") == 200_000

      # An unknown id on a profile-less state also warns and degrades to the
      # default (no profile to fall back TO).
      ExUnit.CaptureLog.capture_log(fn ->
        assert Dispatch.resolve_context_window(state, "nonexistent") == 200_000
      end)

      assert Dispatch.resolve_context_window(state, nil) ==
               EvoGit.Config.Schema.LLM.default_context_window()
    end
  end

  describe "register_agent/7 llm_context_window" do
    test "persists the resolved profile's context window on the AgentState row" do
      state = %{
        State.from_model_profiles([
          %{id: "default", model: "provider:default"},
          %{id: "big", model: "provider:big", context_window: 131_072}
        ])
        | next_agent_id: :erlang.unique_integer([:positive])
      }

      # `model_id_locked: true` skips the user model-selection script, so the
      # resolved profile (and therefore the window) is deterministic even when
      # the developer's own agents.toml defines a `[model_selection]` script.
      spec = %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/home/user/primary"},
        phylo_node: %PhyloGraphNode{
          repo: "/home/user/primary/.genesis/workers/worker_T9_A1",
          base_commit: "abc123",
          current_commit: "abc123"
        },
        agent_module: DummyAgent,
        objective: "test",
        repo_id: "primary",
        model_id: "big",
        opts: [model_id_locked: true]
      }

      task_id = "task-window-#{:erlang.unique_integer([:positive])}"
      {agent_id, _state} = Dispatch.register_agent(state, spec, nil, nil, 0, task_id, 1)

      on_exit(fn ->
        Store.delete_agent_state(agent_id)
        Store.delete_sched_meta(agent_id)
      end)

      {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.model_id == "big"
      assert agent_state.llm_context_window == 131_072
    end

    test "defaults llm_context_window to 200_000 when no profiles are configured" do
      state = %State{
        model_profiles: [],
        next_agent_id: :erlang.unique_integer([:positive])
      }

      spec = %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/home/user/primary"},
        phylo_node: %PhyloGraphNode{
          repo: "/home/user/primary",
          base_commit: "abc123",
          current_commit: "abc123"
        },
        agent_module: DummyAgent,
        objective: "test",
        repo_id: "primary",
        opts: [model_id_locked: true]
      }

      task_id = "task-window-default-#{:erlang.unique_integer([:positive])}"
      {agent_id, _state} = Dispatch.register_agent(state, spec, nil, nil, 0, task_id, 1)

      on_exit(fn ->
        Store.delete_agent_state(agent_id)
        Store.delete_sched_meta(agent_id)
      end)

      {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.llm_context_window == 200_000
    end
  end

  describe "register_agent/7 provider prompt-cache identity" do
    # A legacy OpenAI selection is enough to exercise the injection: the
    # provider-gating itself is covered by
    # `test/evo_git/config/schema/llm_cache_identity_test.exs`.
    defp cache_state do
      %{
        State.from_model_profiles([
          %{id: "openai", model: "openai:gpt-4o", concurrency: 3}
        ])
        | next_agent_id: :erlang.unique_integer([:positive, :monotonic])
      }
    end

    defp cache_spec do
      %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/home/user/primary"},
        phylo_node: %PhyloGraphNode{
          repo: "/home/user/primary",
          base_commit: "abc123",
          current_commit: "abc123"
        },
        agent_module: DummyAgent,
        objective: "cache identity",
        repo_id: "primary",
        model_id: "openai",
        opts: [model_id_locked: true]
      }
    end

    defp register_with_cache(state, task_id, task_number) do
      {agent_id, state} =
        Dispatch.register_agent(state, cache_spec(), nil, nil, 0, task_id, task_number)

      on_exit(fn ->
        Store.delete_agent_state(agent_id)
        Store.delete_sched_meta(agent_id)
      end)

      {:ok, agent_state} = Store.get_agent_state(agent_id)
      {agent_id, state, agent_state}
    end

    test "persists a :prompt_cache_key in the provider options" do
      task_id = "task-cache-#{:erlang.unique_integer([:positive])}"
      {id, _state, agent_state} = register_with_cache(cache_state(), task_id, 1)

      provider_options = Keyword.fetch!(agent_state.llm_generation_params, :provider_options)
      key = Keyword.fetch!(provider_options, :prompt_cache_key)

      # EXACTLY one `genesis-` prefix: the helper owns it, the scope does not.
      assert key == "genesis-#{task_id}-#{id}"
      assert key =~ task_id
      # `session_id` is NOT part of the :openai provider schema.
      refute Keyword.has_key?(provider_options, :session_id)
      # The existing native-OpenAI default survives.
      assert Keyword.fetch!(provider_options, :store) == false
    end

    test "two registered agents of the SAME task get DISTINCT cache keys" do
      task_id = "task-cache-#{:erlang.unique_integer([:positive])}"
      state = cache_state()
      {first_id, state, first} = register_with_cache(state, task_id, 1)
      {second_id, _state, second} = register_with_cache(state, task_id, 2)

      assert first_id != second_id

      first_options = Keyword.fetch!(first.llm_generation_params, :provider_options)
      second_options = Keyword.fetch!(second.llm_generation_params, :provider_options)
      first_key = Keyword.fetch!(first_options, :prompt_cache_key)
      second_key = Keyword.fetch!(second_options, :prompt_cache_key)

      refute first_key == second_key
      assert first_key =~ task_id
      assert second_key =~ task_id
    end
  end

  # --- try_dispatch guard ---
  # The SESSION-START contract of `try_dispatch/2` (registry registration,
  # sched-meta `session_pid`/`phase: :starting`, the ref-keyed `ref_to_agent`
  # entry, the delivery of ONE terminal result, and the bounded crash-retry
  # path when the session supervisor is unavailable) is covered by
  # `session_dispatch_test.exs`, which can park the worktree-creation seam to
  # observe the session before it runs anything.
  # What belongs here is dispatch's own guard, which never reaches a session.
  describe "try_dispatch/2 guards" do
    test "returns the state untouched when the sched-meta entry is missing" do
      state = %State{next_agent_id: :erlang.unique_integer([:positive])}
      missing_id = 9_900_000 + :erlang.unique_integer([:positive])
      # An id with no `:evogit_sched_meta` row (and no agent state row) must bail
      # BEFORE spawning anything: no session, no monitor, no ref_to_agent entry.
      new_state = Dispatch.try_dispatch(state, missing_id)
      assert new_state.ref_to_agent == %{}
      assert new_state.next_agent_id == state.next_agent_id
      assert Registry.lookup(EvoGit.Agent.Session.Registry, missing_id) == []
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
