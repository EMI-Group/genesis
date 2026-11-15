defmodule EvoGit.SelfReflectiveToolsTest do
  @moduledoc """
  Pins the assistant's public tool/persona contract without running an agent or
  evaluating code: the tool set, the evaluator schema, and the rewritten
  Genesis-operator system prompt (role, capability inventory, tier authority,
  operator recipes, page map and finish contract). ConfigDir isolation is per
  process; no scheduler, approval service or application environment is
  mutated, so these tests are async-safe.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.ElixirEval
  alias EvoGit.Agents.SelfReflective
  alias EvoGit.TestSupport.ConfigDir

  setup do
    ConfigDir.isolate!("self-reflective-tools")
    :ok
  end

  # The operator recipes live after the verbatim evaluator catalog, so asserting
  # on this suffix proves the PROMPT teaches each call instead of merely
  # inheriting the tool's own help text.
  defp recipe_section(prompt) do
    assert [_catalog_side, recipes] = String.split(prompt, "# Recipes", parts: 2)
    recipes
  end

  test "the repo-less assistant preserves optional source tools and evaluator with structured task controls" do
    names = Enum.map(SelfReflective.available_tools(), & &1.name)
    source_tools = ~w(read rg glob web_fetch list_dir read_context search_context search_history)

    expected =
      source_tools ++
        ["elixir_eval", "genesis_source"] ++
        Enum.map(EvoGit.Agent.Tools.GenesisTools.schemas(), & &1.name)

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
    assert tool.description =~ "Inspect source with read/glob/rg, then call"

    assert tool.description =~
             "explicitly admitted real APIs in Dune at read (default) or write tier"

    assert tool.description =~ "facades are optional conveniences"
    assert tool.description =~ "Write requires manual approval of the exact code"
    assert tool.description =~ "UNSANDBOXED full VM"
    assert tool.description =~ "Never auto-escalate"
    assert tool.description =~ "side effects cannot be rolled back"
  end

  test "the persona IS Genesis in the first person: an operator of the running system" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "You are Genesis"
    assert prompt =~ "you speak AS Genesis"
    assert prompt =~ "in the first person, directly to the user, never as an outside narrator"
    assert prompt =~ "You exist to explain Genesis and to operate it for them"
    assert prompt =~ "its context tree, its tasks and agents, its scheduler, its models"
    assert prompt =~ "You answer, advise and act on their behalf, always in their language"
  end

  test "the persona states the repo-less situation and the reference-checkout boundary" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "this conversation has no repository or worktree"
    assert prompt =~ "Genesis source is optional read-only reference"
    assert prompt =~ "Source is never an execution target"
    assert prompt =~ "Do not load launch-directory CONTEXT or project skills"
    assert prompt =~ "optional selected project scopes task operations"
  end

  test "the persona keeps source inspection read-only and uses structured operations first" do
    prompt = SelfReflective.system_prompt()
    assert prompt =~ "You cannot edit files or run a shell"
    assert prompt =~ "Prefer the structured Genesis tools"
    assert prompt =~ "A conversational “yes” does not approve"
    assert prompt =~ "never automatically resubmit a task"
    assert prompt =~ "Retain `elixir_eval` for scheduler controls"
  end

  test "the persona answers a greeting or capability question with no tool calls, inventory included" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~
             ~s(On a greeting, on "what can you do?", or on any question about your own abilities, answer immediately — first person, no tool calls:)

    assert prompt =~
             "Read the Genesis source, its CONTEXT.md tree and its git history, and explain how something actually works from the real code"

    assert prompt =~
             "Read a pasted or external URL as Markdown; search the web when the search tool is available"

    assert prompt =~ "Inspect the running system through `elixir_eval`"

    assert prompt =~
             "task history and single tasks, live agents, scheduler state, per-model LLM capacity, resolved and live configuration"

    assert prompt =~
             "Drive it: start genesis, evolve and reflect tasks; cancel, force-kill or delete tasks; pause and resume the scheduler"

    assert prompt =~
             "Discover settings and project mounts; change runtime scheduler settings or patch persisted configuration for the user"

    assert prompt =~ "Guide the user to the right dashboard page with the guide overlay"
  end

  test "the persona explains all three tiers, exact-code approval and no escalation" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "Retain `elixir_eval` for scheduler controls"
    assert prompt =~ "`tier` (`read`, `write`, or `sudo`; default `read`)"
    assert prompt =~ "`timeout_ms` and `max_output_bytes`"
    assert prompt =~ "**Read tier:** Dune sandbox evaluation"
    assert prompt =~ "explicit whitelist of Genesis read APIs; no approval"
    assert prompt =~ "Reads return real, unredacted values: inspect only what you need"
    refute prompt =~ "redacted Genesis read APIs; no approval"
    assert prompt =~ "**Write tier:** Dune sandbox evaluation"
    assert prompt =~ "real `CommandApproval` approval of the exact code before execution"
    assert prompt =~ "a conversational OK is not approval"
    assert prompt =~ "Guides use the write-tier approval gate"
    assert prompt =~ "Approval is per call"
    assert prompt =~ "Never automatically escalate tiers or retry at a higher tier"

    assert prompt =~
             "If denied or timed out, explain what happened without retrying or escalating"

    assert prompt =~ "Evaluation targets only the current authenticated runtime node"
    assert prompt =~ "Remote evaluation is not available"
  end

  test "the persona recommends source inspection followed by admitted actual APIs, not facade translation" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "**Source then API:**"

    assert prompt =~
             "read the raw implementation with `read`/`rg`, then call the explicitly admitted actual module/function through `elixir_eval`"

    assert prompt =~ "apps/evo_git/lib/evo_git/task_registry.ex"
    assert prompt =~ ~s|code: "EvoGit.TaskRegistry.list_tasks_page()"|
    assert prompt =~ ~s(tier: "read")
    assert prompt =~ "Use fully qualified module names — Dune has no alias declarations"
    assert prompt =~ "Convenience `Read`/`Write` facades in the embedded help are optional"
    assert prompt =~ "do not translate every actual API call into a facade call"
  end

  test "the persona limits source-discovered APIs to exact tier-specific MFAs without namespace grants" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "Only the exact module/function/arity entries admitted for the chosen tier"

    assert prompt =~
             "A public function found in source, another arity, or another function in an admitted module is not automatically authorized"

    assert prompt =~ "Use the embedded help as the authoritative catalog"

    assert prompt =~
             "source inspection does not expand the allowlist or bypass exact-code approval for writes"

    assert prompt =~
             "The catalog below is authoritative: it lists exactly what is callable per tier"
  end

  test "the persona warns that sudo is explicitly confirmed unrestricted VM execution, not OS root" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "**Sudo tier:** unrestricted normal Elixir"
    assert prompt =~ "separate explicit privileges warning and exact-code confirmation"
    assert prompt =~ "sudo does not mean OS root"
    assert prompt =~ "Use only when the user explicitly requests this privileged path"
    assert prompt =~ "never as a workaround for a denied or unsupported read/write call"
    assert prompt =~ "Sudo is UNSANDBOXED full VM Code evaluation"
    assert prompt =~ "timeouts or later cancellation cannot roll back effects"
  end

  test "the persona warns that evaluation reads are real values, and output caps are not redaction" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "These reads are not redacted"
    assert prompt =~ "output caps are not redaction"
    assert prompt =~ "never echo credentials or tokens"

    assert prompt =~
             "A timeout or a lost call does not roll back an effect that was already committed"
  end

  test "the persona embeds the evaluator's authoritative capability catalog verbatim exactly once" do
    prompt = SelfReflective.system_prompt()
    catalog = ElixirEval.help()

    assert prompt =~ catalog
    assert length(:binary.matches(prompt, catalog)) == 1
    assert catalog =~ "EvoGit.Agent.Tools.ElixirEval.Read"
    assert catalog =~ "EvoGit.Agent.Tools.ElixirEval.Write"
    assert catalog =~ "Read/Write facades are optional convenience APIs, not the sole path"
    assert catalog =~ "Direct local APIs (fully qualified calls, no alias declarations)"

    assert catalog =~
             "EvoGit.TaskRegistry.list_tasks_page/0, EvoGit.TaskRegistry.list_tasks_page/1"

    assert catalog =~ "EvoGit.AgentScheduler.get_config/1"
    assert catalog =~ "Write (exact-code approval required): EvoGit.TaskRegistry.start_task/2"

    assert [_, read_mfas, write_mfas] =
             Regex.run(
               ~r/Read: ([^\n]+)\nWrite \(exact-code approval required\): ([^\n]+)/,
               catalog
             )

    for signature <- ~w(
          EvoGit.Config.list_settings/0 EvoGit.Config.show/0 EvoGit.Config.show/1
          EvoGit.Config.user_config/0 EvoGit.Config.config_path/0
          EvoGit.VCT.projects/0 EvoGit.VCT.projects/1 EvoGit.VCT.search/1 EvoGit.VCT.search/2
        ) do
      assert read_mfas =~ signature
      refute write_mfas =~ signature
    end

    assert write_mfas =~ "EvoGit.Config.update/1"
    refute read_mfas =~ "EvoGit.Config.update/1"
    refute write_mfas =~ "EvoGit.VCT."
    assert catalog =~ "No VCT mutation is admitted."
    assert catalog =~ "A refusal does not auto-escalate."

    assert catalog =~
             "only these exact MFAs are admitted, never an entire module or another arity"

    assert catalog =~ "unchanged arguments and return values, not projected facade substitutes"
    assert catalog =~ "These reads are not facade-row-bounded or secret-redacted"
    assert catalog =~ "output caps are not redaction"

    assert catalog =~
             "Write and sudo require manual approval of the EXACT submitted code every call"

    assert catalog =~ "Use fully qualified module names; Dune does not support alias declarations"
    assert catalog =~ "no persistent REPL state"
  end

  test "the operator recipes teach the exact admitted MFAs for inspection and control" do
    recipes = recipe_section(SelfReflective.system_prompt())

    # Read tier.
    assert recipes =~ "EvoGit.TaskRegistry.list_tasks_page(limit: 10, status: \"running\")"
    assert recipes =~ ~s|EvoGit.TaskRegistry.get_task_lite("5d0c9a1e7b3f4c28")|
    assert recipes =~ "EvoGit.AgentScheduler.RemoteAPI.list_agents()"
    assert recipes =~ "EvoGit.AgentScheduler.paused?()"
    assert recipes =~ "EvoGit.AgentScheduler.get_llm_slot_status()"
    assert recipes =~ "EvoGit.AgentScheduler.get_config(:max_turns)"

    for snippet <- [
          "tier: \"read\"\nEvoGit.Config.list_settings()",
          ~s|tier: "read"\nEvoGit.Config.show("scheduler.max_tool_concurrency")|,
          "tier: \"read\"\nEvoGit.VCT.projects(limit: 10)",
          ~s|tier: "read"\nEvoGit.VCT.search("proj", limit: 10)|
        ] do
      assert length(:binary.matches(recipes, snippet)) == 1
    end

    # Write tier.
    assert recipes =~ "EvoGit.TaskRegistry.start_task(:evolve"
    assert recipes =~ ~s|EvoGit.TaskRegistry.cancel_task("9f2c...")|
    assert recipes =~ ~s|EvoGit.TaskRegistry.force_kill_task("9f2c...")|
    assert recipes =~ ~s|EvoGit.TaskRegistry.delete_task("9f2c...")|
    assert recipes =~ "EvoGit.AgentScheduler.pause()"
    assert recipes =~ "EvoGit.AgentScheduler.resume()"
    assert recipes =~ "EvoGit.AgentScheduler.update_config(max_tool_concurrency: 8)"

    persisted_recipe = """
    tier: "write"
    case EvoGit.Config.update(%{"scheduler.max_tool_concurrency" => 8}) do
      :ok -> EvoGit.AgentScheduler.RemoteAPI.reload_config()
      error -> error
    end
    """

    assert length(:binary.matches(recipes, persisted_recipe)) == 1
    refute recipes =~ "EvoGit.Config.save_user_config(updated)"

    assert recipes =~
             ~s|EvoGit.Agent.Tools.ElixirEval.Write.guide("Open the Tasks page"|
  end

  test "the recipes pin the semantics that make those calls safe to use" do
    recipes = recipe_section(SelfReflective.system_prompt())

    assert recipes =~
             "Enqueue is not execution: `{:ok, %EvoGit.TaskInfo{}}` proves the task was registered and started, not that it will succeed"

    assert recipes =~
             "`delete_task/1` applies to terminal tasks only and is a queued cast: `:ok` acknowledges the request, it does not prove the row is gone"

    assert recipes =~
             "the task then ends `:cancelled` with its result and usage preserved, so it stays reviewable"

    assert recipes =~
             "persists the task as `:failed` with its result discarded"

    assert recipes =~ "save success does not guarantee reload success"

    assert recipes =~
             "`get_config/1` reads the LIVE scheduler value (runtime overrides included"

    assert recipes =~
             "`Config.show/0` returns the resolved defaults-plus-persisted snapshot, NOT live scheduler state"

    assert recipes =~ "malformed and unknown paths return explicit errors"
    assert recipes =~ "{:error, :invalid_path}"
    assert recipes =~ "{:error, {:unknown_setting, path}}"

    assert recipes =~
             "`Config.user_config/0` reads only persisted user configuration, without materializing defaults"

    assert recipes =~ "`Config.config_path/0` locates config.toml on this runtime node"
    assert recipes =~ "These reads are unredacted"

    assert recipes =~
             "Both omit reserved mounts such as `vct:///genesis-source` and retain mounts whose OS paths are missing"

    assert recipes =~
             "use the absolute `path`, not the virtual `point`, for task execution"

    assert recipes =~ "Do not cancel or delete your own task"
  end

  test "the persona maps every dashboard page the guide facade can target" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "| Projects (open or create) | `/projects` (also `/`) |"
    assert prompt =~ "| Assistant chat (this page) | `/assistant` |"
    assert prompt =~ "| Tasks (all tasks, status filters) | `/tasks` |"
    assert prompt =~ "| Agents (agent tree inspector) | `/agents` |"
    assert prompt =~ "| Settings (config, models, agents) | `/settings` |"
    assert prompt =~ "| System (software update, stop) | `/system` |"
    assert prompt =~ "| Review page for a task | `/review/<task_id>` |"

    assert prompt =~
             "| Review page for one task commit | `/review/<task_id>/commit/<commit_sha>` |"

    assert prompt =~
             "The guide facade accepts only the fixed pages above (`nil`, `/`, `/assistant`, `/help`, `/projects`, `/tasks`, `/agents`, `/settings`, `/system`)"

    assert prompt =~
             "`/assistant` is the canonical Assistant chat page, and the legacy `/help` path redirects to it"
  end

  test "public guidance distinguishes partial persistence and snapshot refresh from runtime reload" do
    prompt = SelfReflective.system_prompt()
    catalog = ElixirEval.help()

    assert prompt =~ "`EvoGit.AgentScheduler.update_config/1` changes runtime settings only"
    assert prompt =~ "it does not persist config.toml"

    assert prompt =~
             "Do not describe it as a saved configuration change or promise it survives a restart"

    assert prompt =~ "`Config.update/1` accepts a nested or path-keyed partial map"

    assert prompt =~
             "It preserves unrelated persisted configuration and unknown existing settings, validates and saves without materializing defaults"

    assert prompt =~
             "It does NOT reload the scheduler; for save-only requests call just `Config.update/1`"

    assert prompt =~ "reload explicitly only after a successful patch"
    assert prompt =~ "The combined recipe needs exact-code write approval"

    assert prompt =~
             "Verify saved values with `Config.show/1` and runtime values with `AgentScheduler.get_config/1`"

    assert catalog =~ "EvoGit.Config.update/1"
    assert catalog =~ "EvoGit.Config.save_user_config/1"
    assert catalog =~ "EvoGit.AgentScheduler.RemoteAPI.reload_config/0"
    assert catalog =~ "update/1 merges a nested partial patch into persisted user configuration"
    assert catalog =~ "returning :ok or {:error, reason}, but does NOT reload runtime state"
    assert catalog =~ "save_user_config/1 remains a whole-file REPLACEMENT, not a patch"
    assert catalog =~ "preserve unrelated user settings when using it"

    assert catalog =~
             "Saves refresh the persisted-config read snapshot, not scheduler runtime state"

    assert catalog =~ "RemoteAPI.reload_config/0 explicitly applies reloadable scheduler settings"
    assert catalog =~ "Persistence success does not guarantee reload success"
    assert catalog =~ "reload is not a restart"
  end

  test "the persona mirrors the language of the user's latest message" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~
             "Reply in the language of the user's LATEST message: mirror it, follow a switch mid-conversation, and answer a Chinese question in Chinese — never in English merely because this prompt is written in English"

    assert prompt =~ "Never narrate in the third person"
  end

  test "the persona states its operating principles: verify, report, least tier" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "Inspect before asserting"

    assert prompt =~
             "Enqueue is not execution, a queued cast is not a persisted effect, a runtime update is not a saved setting"

    assert prompt =~ "Never claim an action succeeded without a tool result that shows it"
    assert prompt =~ "Use the least powerful tier that does the job"
  end

  test "the persona never volunteers CLI usage and ends the run with a plain reply" do
    prompt = SelfReflective.system_prompt()

    assert prompt =~ "Never suggest terminal commands or CLI flags by default"
    assert prompt =~ "no terminal commands or CLI flags"
    refute prompt =~ "mix run"

    assert prompt =~
             "Answer command-line questions only when the user explicitly asks about the command line, and never volunteer them"

    assert prompt =~ "A reply with no tool calls ends your run"
    assert prompt =~ "There is no completion tool to call — answering is the only way to finish"
    assert prompt =~ "it must not read as a third-person activity log"
    refute prompt =~ "run_command"
  end
end
