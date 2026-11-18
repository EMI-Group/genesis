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

  defp root_agent_spec(opts) do
    Helpers.build_root_agent_spec(
      context_node(),
      phylo_node(),
      DefaultRoot,
      "do the thing",
      opts,
      [],
      nil
    )
  end

  # The five durable facts a pause resume carries (`RuntimeOpts.resume_fact_keys/0`).
  @resume_facts [
    pause_commit: "pause_sha",
    resume_agent_id: 4,
    resume_current_commit: "cur_sha",
    resume_branch: "evogit-agent_resume",
    resume_anchor_ref: "refs/genesis/agent-state/task-resume/4"
  ]

  defp assert_resume_facts(opts) do
    for {key, value} <- @resume_facts do
      assert Keyword.has_key?(opts, key), "expected #{inspect(key)} in spec.opts"
      assert Keyword.get(opts, key) == value
    end
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

  describe "build_root_agent_spec/7 — :persistent_state threading" do
    test "an absent :persistent_state defaults to true and the key is PRESENT" do
      spec = root_agent_spec([])

      assert spec.agent_module == DefaultRoot
      assert spec.opts[:persistent_state] == true
      assert Keyword.fetch(spec.opts, :persistent_state) == {:ok, true}
    end

    test ":persistent_state nil defaults to true" do
      spec = root_agent_spec(persistent_state: nil)

      assert spec.agent_module == DefaultRoot
      assert spec.opts[:persistent_state] == true
      assert Keyword.fetch(spec.opts, :persistent_state) == {:ok, true}
    end

    test ":persistent_state true yields true" do
      spec = root_agent_spec(persistent_state: true)

      assert spec.agent_module == DefaultRoot
      assert spec.opts[:persistent_state] == true
    end

    test ":persistent_state false yields false" do
      spec = root_agent_spec(persistent_state: false)

      assert spec.agent_module == DefaultRoot
      assert spec.opts[:persistent_state] == false
    end
  end

  describe "build_root_agent_spec/7 — pause-resume facts" do
    test "the default (simple-evolve) root carries all five facts" do
      spec = root_agent_spec(@resume_facts)

      assert spec.agent_module == DefaultRoot
      assert_resume_facts(spec.opts)
    end

    test "the custom root path carries all five facts too" do
      {:ok, saved} = EvoGit.CustomAgents.save(%{name: "Resume Reviewer", prompt: "You review."})

      spec = root_agent_spec([agent: saved.id] ++ @resume_facts)

      assert spec.agent_module == EvoGit.Agents.Custom
      assert Keyword.get(spec.opts, :custom_agent_id) == saved.id
      assert_resume_facts(spec.opts)
    end

    test "a fact resolved to nil is still PRESENT (nothing stored ≠ never resolved)" do
      spec = root_agent_spec(pause_commit: nil, resume_agent_id: 2)

      assert Keyword.fetch(spec.opts, :pause_commit) == {:ok, nil}
      assert Keyword.get(spec.opts, :resume_agent_id) == 2
      refute Keyword.has_key?(spec.opts, :resume_branch)
    end

    test "a spec built WITHOUT the facts has NONE of them (a normal run is unchanged)" do
      spec = root_agent_spec([])

      for key <- EvoGit.TaskRegistry.RuntimeOpts.resume_fact_keys() do
        refute Keyword.has_key?(spec.opts, key),
               "expected #{inspect(key)} to be ABSENT from a normal run's spec.opts"
      end
    end
  end
end
