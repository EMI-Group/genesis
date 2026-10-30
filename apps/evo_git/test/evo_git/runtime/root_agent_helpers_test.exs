defmodule EvoGit.Runtime.RootAgentHelpersTest do
  @moduledoc """
  `async: true` — `EvoGit.CustomAgents` reads its config dir PER PROCESS through
  the `EvoGit.TestSupport.ConfigDir` seam (`EvoGit.Platform.config_dir/1`), so
  no BEAM-global state (no `XDG_CONFIG_HOME` env var, no app-env key) is
  mutated and the real `~/.config/genesis/` is never touched.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Runtime.Helpers
  alias EvoGit.TestSupport.ConfigDir

  # Point this process' config dir at a fresh temp dir so CustomAgents never
  # touches the real ~/.config/genesis/ directory.
  setup do
    ConfigDir.isolate!("evogit-root-agent-helpers")
    :ok
  end

  defmodule DefaultRoot do
  end

  defp context_node, do: %EvoGit.Core.ContextNode{path: ".", repo: "/tmp/repo"}
  defp phylo_node, do: %EvoGit.Core.PhyloGraphNode{repo: "/tmp/repo"}

  describe "resolve_root_agent/2" do
    test "returns the default module with [] opts when :agent is absent" do
      assert Helpers.resolve_root_agent([], DefaultRoot) == {DefaultRoot, []}
    end

    test "returns the default module with [] opts when :agent is an empty string" do
      assert Helpers.resolve_root_agent([agent: ""], DefaultRoot) == {DefaultRoot, []}
    end

    test "raises ArgumentError with a descriptive message for an unknown id" do
      assert_raise ArgumentError, ~r/Unknown custom agent id 'ghost_agent'/, fn ->
        Helpers.resolve_root_agent([agent: "ghost_agent"], DefaultRoot)
      end
    end

    test "returns EvoGit.Agents.Custom + custom_agent_id for a known id" do
      {:ok, saved} =
        EvoGit.CustomAgents.save(%{name: "Code Reviewer", prompt: "You review code."})

      assert {EvoGit.Agents.Custom, [custom_agent_id: id]} =
               Helpers.resolve_root_agent([agent: saved.id], DefaultRoot)

      assert id == saved.id
    end
  end

  describe "model_id_locked?/1" do
    test "returns false for []" do
      refute Helpers.model_id_locked?([])
    end

    test "returns false for [model_id: nil]" do
      refute Helpers.model_id_locked?(model_id: nil)
    end

    test "returns true for [model_id: \"fast\"]" do
      assert Helpers.model_id_locked?(model_id: "fast")
    end

    test "returns true for [model_id_locked: true]" do
      assert Helpers.model_id_locked?(model_id_locked: true)
    end

    test "returns true for [model_id: \"x\"]" do
      assert Helpers.model_id_locked?(model_id: "x")
    end

    test "returns false for [model_id_locked: false, model_id: nil]" do
      refute Helpers.model_id_locked?(model_id_locked: false, model_id: nil)
    end
  end

  describe "build_root_agent_spec/7 — :quality_level threading" do
    test "threads :quality_level from the runtime opts into spec.opts" do
      spec =
        Helpers.build_root_agent_spec(
          context_node(),
          phylo_node(),
          DefaultRoot,
          "do the thing",
          [quality_level: "fast"],
          [],
          nil
        )

      assert spec.agent_module == DefaultRoot
      assert Keyword.get(spec.opts, :quality_level) == "fast"
    end

    test "an absent :quality_level yields nil in spec.opts" do
      spec =
        Helpers.build_root_agent_spec(
          context_node(),
          phylo_node(),
          DefaultRoot,
          "do the thing",
          [],
          [],
          nil
        )

      assert Keyword.get(spec.opts, :quality_level) == nil
    end
  end
end
