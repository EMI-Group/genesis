defmodule EvoGit.AgentScheduler.DispatchCustomAgentsTest do
  use ExUnit.Case, async: false

  alias EvoGit.AgentSpec
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  defmodule DummyAgent do
    def run(_objective, _ctx), do: {:ok, :done}
  end

  # Tests mutate the XDG_CONFIG_HOME env var so that CustomAgents /
  # ModelSelector never touch the real ~/.config/genesis/ directory.
  setup do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-test-xdg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    # The ModelSelector cache key embeds the agents.toml path (which follows
    # XDG_CONFIG_HOME), so stale entries from other tests could leak through.
    EvoGit.CustomAgents.ModelSelector.invalidate()

    on_exit(fn ->
      EvoGit.CustomAgents.ModelSelector.invalidate()

      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    :ok
  end

  defp build_state(overrides \\ []) do
    base =
      State.from_model_profiles([
        %{id: "default", model: "provider:default"},
        %{id: "fast", model: "provider:fast"}
      ])

    struct(base, Keyword.merge([next_agent_id: :erlang.unique_integer([:positive])], overrides))
  end

  defp build_spec(opts \\ []) do
    %AgentSpec{
      context_node: %ContextNode{path: "./", repo: "/tmp/test"},
      phylo_node: %PhyloGraphNode{
        repo: "/tmp/test",
        base_commit: "abc123",
        current_commit: "abc123"
      },
      agent_module: DummyAgent,
      objective: "test objective",
      repo_id: "primary",
      model_id: Keyword.get(opts, :model_id),
      opts: opts
    }
  end

  defp register(state, spec, opts \\ []) do
    parent_id = Keyword.get(opts, :parent_id)
    depth = Keyword.get(opts, :depth, 0)
    task_id = Keyword.get(opts, :task_id, "task-#{:erlang.unique_integer([:positive])}")

    {agent_id, _state} = Dispatch.register_agent(state, spec, nil, parent_id, depth, task_id, 1)

    on_exit(fn ->
      Store.delete_agent_state(agent_id)
      Store.delete_sched_meta(agent_id)
    end)

    agent_id
  end

  defp write_script(script) do
    EvoGit.CustomAgents.save_model_selection_script(script)
    EvoGit.CustomAgents.ModelSelector.invalidate()
  end

  defp save_agent!(attrs) do
    {:ok, definition} = EvoGit.CustomAgents.save(attrs)
    definition
  end

  describe "model selection via the user script" do
    test "script-selected model overrides nil spec.model_id" do
      write_script(~s("fast"))

      spec = build_spec()
      agent_id = register(build_state(), spec)

      assert {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.model_id == "fast"
    end

    test "script can branch on custom_agent_id" do
      save_agent!(%{id: "reviewer", name: "Reviewer", prompt: "You review code"})
      write_script(~s(if agent.custom_agent_id == "reviewer", do: "fast", else: "default"))

      spec = build_spec(custom_agent_id: "reviewer")
      agent_id = register(build_state(), spec)

      assert {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.model_id == "fast"

      # A different custom id hits the else branch.
      other_spec = build_spec(custom_agent_id: "other_agent")
      other_agent_id = register(build_state(), other_spec)

      assert {:ok, other_agent_state} = Store.get_agent_state(other_agent_id)
      assert other_agent_state.model_id == "default"
    end

    test "script returning nil keeps spec.model_id" do
      write_script("nil")

      spec = build_spec(model_id: "fast")
      agent_id = register(build_state(), spec)

      assert {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.model_id == "fast"
    end

    test "model_id_locked skips the script" do
      write_script(~s("fast"))

      spec = build_spec(model_id: "default", model_id_locked: true)
      agent_id = register(build_state(), spec)

      assert {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.model_id == "default"
    end

    test "inherited spec.model_id is not locked — script still wins" do
      write_script(~s("fast"))

      spec = build_spec(model_id: "default")
      agent_id = register(build_state(), spec)

      assert {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.model_id == "fast"
    end

    test "custom definition model_id is used when spec.model_id is nil and no script is configured" do
      save_agent!(%{
        id: "reviewer",
        name: "Reviewer",
        prompt: "You review code",
        model_id: "fast"
      })

      spec = build_spec(custom_agent_id: "reviewer")
      agent_id = register(build_state(), spec)

      assert {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.model_id == "fast"
    end

    test "script raising falls back to the default profile without crashing" do
      write_script(~s(raise "boom"))

      spec = build_spec()
      agent_id = register(build_state(), spec)

      assert {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.model_id == "default"
    end

    test "unknown custom_agent_id does not raise and falls back to defaults" do
      import ExUnit.CaptureLog

      state = build_state()
      spec = build_spec(custom_agent_id: "nope")

      log =
        capture_log(fn ->
          agent_id = register(state, spec)

          assert {:ok, agent_state} = Store.get_agent_state(agent_id)
          assert agent_state.model_id == "default"
          assert agent_state.max_turns == state.max_turns_root
        end)

      assert log =~ "custom agent id"
    end
  end

  describe "custom agent max_turns override" do
    test "definition max_turns overrides state.max_turns_root for a root custom agent" do
      save_agent!(%{id: "reviewer", name: "Reviewer", prompt: "You review code", max_turns: 40})

      state = build_state(max_turns_root: 128)
      spec = build_spec(custom_agent_id: "reviewer")
      agent_id = register(state, spec)

      assert {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.max_turns == 40
    end

    test "root custom agent without definition max_turns uses state.max_turns_root" do
      save_agent!(%{id: "reviewer", name: "Reviewer", prompt: "You review code"})

      state = build_state(max_turns_root: 64)
      spec = build_spec(custom_agent_id: "reviewer")
      agent_id = register(state, spec)

      assert {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.max_turns == 64
    end

    test "subagents always use state.max_turns even with a custom_agent_id" do
      save_agent!(%{id: "reviewer", name: "Reviewer", prompt: "You review code", max_turns: 40})

      state = build_state(max_turns: 77, max_turns_root: 128)
      spec = build_spec(custom_agent_id: "reviewer")
      agent_id = register(state, spec, parent_id: 1, depth: 1)

      assert {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.max_turns == 77
    end
  end
end
