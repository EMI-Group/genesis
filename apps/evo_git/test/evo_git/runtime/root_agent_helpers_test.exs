defmodule EvoGit.Runtime.RootAgentHelpersTest do
  use ExUnit.Case, async: false

  # Tests mutate the XDG_CONFIG_HOME env var so that CustomAgents never
  # touches the real ~/.config/genesis/ directory (same pattern as
  # test/evo_git/custom_agents_test.exs).
  setup do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-test-xdg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    :ok
  end

  alias EvoGit.Runtime.Helpers

  defmodule DefaultRoot do
  end

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
end
