defmodule EvoGit.SelfReflectiveToolsTest do
  @moduledoc """
  Pins the assistant's public tool/persona contract without running an agent or
  evaluating code. ConfigDir isolation is per process; no scheduler, approval
  service or application environment is mutated, so these tests are async-safe.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.ElixirEval
  alias EvoGit.Agents.SelfReflective
  alias EvoGit.TestSupport.ConfigDir

  setup do
    ConfigDir.isolate!("self-reflective-tools")
    :ok
  end

  test "the repo-less assistant preserves source read tools and offers only the evaluator for control" do
    names = Enum.map(SelfReflective.available_tools(), & &1.name)
    source_tools = ~w(read rg glob web_fetch list_dir read_context search_context search_history)
    expected = source_tools ++ ["elixir_eval"]

    expected =
      if EvoGit.Config.tools_search_enabled?(), do: expected ++ ["web_search"], else: expected

    assert Enum.sort(names) == Enum.sort(expected)
    assert length(names) == length(Enum.uniq(names))
    refute "run_command" in names
    refute Enum.any?(names, &(&1 in ~w(bash write edit run_git)))
    assert SelfReflective.agent_type() == :read
    assert SelfReflective.delegation_level() == :low
    assert SelfReflective.subagent_modules() == []
  end

  test "the offered evaluator schema advertises explicit read/write/sudo tiers and safe defaults" do
    tool = Enum.find(SelfReflective.available_tools(), &(&1.name == "elixir_eval"))
    assert tool.name == "elixir_eval"
    schema = tool.parameter_schema

    assert schema["required"] == ["code"]
    assert schema["properties"]["code"]["type"] == "string"
    assert schema["properties"]["tier"]["enum"] == ["read", "write", "sudo"]
    assert schema["properties"]["tier"]["default"] == "read"
    assert schema["properties"]["timeout_ms"]["default"] == 2_000
    assert schema["properties"]["max_output_bytes"]["default"] == 16_384
    assert tool.description =~ "Write requires manual approval of the exact code"
    assert tool.description =~ "UNSANDBOXED full VM"
    assert tool.description =~ "Never auto-escalate"
    assert tool.description =~ "side effects cannot be rolled back"
  end

  test "persona remains first-person Genesis with separate read-only source inspection" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "You are Genesis"
    assert prompt =~ "in the first person"
    assert prompt =~ "always in their language"
    assert prompt =~ "repo_path is the Genesis source root, not a runtime execution target"
    assert prompt =~ "Source tools are read-only"
    assert prompt =~ "No OS-shell tool (`bash`) or ordinary file-write tools"
    assert prompt =~ "A reply with no tool calls ends your run"
    refute prompt =~ "run_command"
  end

  test "persona explains all three tiers, exact-code approval and no escalation" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "`tier` (`read`, `write`, or `sudo`; default `read`)"
    assert prompt =~ "**Read tier:** Dune sandbox evaluation"
    assert prompt =~ "redacted Genesis read APIs; no approval"
    assert prompt =~ "**Write tier:** Dune sandbox evaluation"
    assert prompt =~ "real `CommandApproval` approval of the exact code before execution"
    assert prompt =~ "a conversational OK is not approval"
    assert prompt =~ "Guides use the write-tier approval gate"
    assert prompt =~ "Never automatically escalate tiers or retry at a higher tier"

    assert prompt =~
             "If denied or timed out, explain what happened without retrying or escalating"

    assert prompt =~ "current authenticated runtime node"
  end

  test "persona warns that sudo is explicitly confirmed unrestricted VM execution, not OS root" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "**Sudo tier:** unrestricted normal Elixir"
    assert prompt =~ "separate explicit privileges warning and exact-code confirmation"
    assert prompt =~ "sudo does not mean OS root"
    assert prompt =~ "Use only when the user explicitly requests this privileged path"
    assert prompt =~ "never as a workaround for a denied or unsupported read/write call"
    assert prompt =~ "Sudo is UNSANDBOXED full VM Code evaluation"
    assert prompt =~ "timeouts or later cancellation cannot roll back effects"
  end

  test "persona embeds the evaluator's authoritative capability catalog verbatim" do
    prompt = SelfReflective.system_prompt()
    catalog = ElixirEval.help()

    assert prompt =~ catalog
    assert length(:binary.matches(prompt, catalog)) == 1
    assert catalog =~ "EvoGit.Agent.Tools.ElixirEval.Read"
    assert catalog =~ "EvoGit.Agent.Tools.ElixirEval.Write"
    assert catalog =~ "Use fully qualified module names; Dune does not support alias declarations"
    assert catalog =~ "no persistent REPL state"
  end
end
