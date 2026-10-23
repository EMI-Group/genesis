defmodule EvoGit.Agents.PromptSubagentNamesTest do
  @moduledoc """
  Guards one class of prompt defect: a role PROMPT naming a `subagent_*` tool the
  role does not actually have.

  Subagent tool schemas are generated from `subagent_modules/0`
  (`EvoGit.Agent.SubagentSchemas`, resolved by `subagent_tool_name/0`), so a name
  mentioned in prompt text but absent from that list is an uncallable tool — an
  agent following the prompt gets an unknown-tool error instead of a subagent.
  This is a text/enumeration consistency invariant, not a behaviour: fix a failure
  here by correcting the PROMPT (low risk) or, if the role genuinely needs the
  capability, by adding the module to `subagent_modules/0` and stating why.
  """

  use ExUnit.Case, async: true

  # Every role module whose `system_prompt/0` is audited. `EvoGit.Agents.Custom`
  # is deliberately absent: its prompt is USER-AUTHORED (`agents.toml`) and its
  # spawnable set comes from the definition's `subagents` list, so neither side of
  # this invariant is knowable at compile/test time.
  @roles [
    EvoGit.Agents.Manager,
    EvoGit.Agents.Executor,
    EvoGit.Agents.Investigator,
    EvoGit.Agents.TaskScheduler,
    EvoGit.Agents.Architect,
    EvoGit.Agents.ContextExtractor,
    EvoGit.Agents.SkillExtractor,
    EvoGit.Agents.GenesisPlanner,
    EvoGit.Agents.SelfReflective
  ]

  # Prompt mentions that are PLAN REFERENCES rather than capability claims: the
  # GenesisPlanner is a read-only planning agent whose OUTPUT tells an Architect
  # which agents to spawn ("Reference only these agents in the plan"). It cannot
  # spawn them itself, and its prompt never claims it can.
  @plan_references %{
    EvoGit.Agents.GenesisPlanner => ~w(subagent_architect subagent_manager)
  }

  defp spawnable_names(module) do
    module.subagent_modules()
    |> Enum.map(& &1.subagent_tool_name())
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp prompt_names(module) do
    ~r/subagent_[a-z_]+/
    |> Regex.scan(module.system_prompt())
    |> List.flatten()
    |> MapSet.new()
  end

  test "every subagent_* name in a role's prompt is a tool that role actually has" do
    for module <- @roles do
      allowed =
        MapSet.union(
          spawnable_names(module),
          MapSet.new(Map.get(@plan_references, module, []))
        )

      missing = MapSet.difference(prompt_names(module), allowed)

      assert MapSet.size(missing) == 0,
             "#{inspect(module)}'s prompt names subagent tool(s) it cannot spawn: " <>
               "#{inspect(Enum.sort(MapSet.to_list(missing)))} — its subagent_modules/0 is " <>
               "#{inspect(module.subagent_modules())}. Remove the name from the prompt, or add " <>
               "the module to subagent_modules/0 (a behaviour change) and say why."
    end
  end

  test "the audit covers every role module exposing system_prompt/0" do
    role_modules =
      :evo_git
      |> Application.spec(:modules)
      |> Enum.filter(fn module ->
        String.starts_with?(Atom.to_string(module), "Elixir.EvoGit.Agents.") and
          Code.ensure_loaded?(module) and function_exported?(module, :system_prompt, 0)
      end)
      |> Enum.reject(&(&1 == EvoGit.Agents.Custom))

    assert Enum.sort(role_modules) == Enum.sort(@roles),
           "a role module was added or removed — update @roles in this test so the " <>
             "prompt/subagent_modules invariant keeps covering it. Missing from @roles: " <>
             "#{inspect(Enum.sort(role_modules -- @roles))}; stale in @roles: " <>
             "#{inspect(Enum.sort(@roles -- role_modules))}"
  end

  test "a SHARED prompt fragment names no concrete subagent tool" do
    # `writable_foreign_repo_clause/0` is included by Architect AND ContextExtractor,
    # whose spawnable sets differ — so any concrete tool name in it is a false
    # capability claim for at least one reader.
    refute Regex.match?(
             ~r/subagent_[a-z_]+/,
             EvoGit.Agents.PromptFragments.writable_foreign_repo_clause()
           ),
           "PromptFragments.writable_foreign_repo_clause/0 must stay generic: it is shared by " <>
             "roles with different subagent_modules/0, so it cannot name a concrete " <>
             "subagent_* tool."
  end

  describe "the Manager regression (subagent_context_extractor)" do
    test "the Manager cannot spawn a context extractor, and its prompt no longer says it can" do
      refute EvoGit.Agents.ContextExtractor in EvoGit.Agents.Manager.subagent_modules()

      refute "subagent_context_extractor" in EvoGit.Agent.SubagentSchemas.tools(
               EvoGit.Agents.Manager
             )

      refute EvoGit.Agents.Manager.system_prompt() =~ "subagent_context_extractor"
    end

    test "the tool names the Manager prompt does use are all real Manager tools" do
      tools = EvoGit.Agent.SubagentSchemas.tools(EvoGit.Agents.Manager)

      assert "subagent_manager" in tools
      assert "subagent_executor" in tools
      assert "subagent_task_scheduler" in tools
      assert "subagent_investigator" in tools
    end
  end
end
