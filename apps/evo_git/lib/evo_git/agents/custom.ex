defmodule EvoGit.Agents.Custom do
  @moduledoc """
  A generic runtime agent for user-defined custom agents.

  Custom agents are defined by the user (in `agents.toml` under the Genesis config
  directory) and managed by `EvoGit.CustomAgents`. This module is the single runtime
  agent type that executes ALL custom agent definitions: at run time it resolves its
  own definition by id and derives every `EvoGit.Agent` callback from that definition
  (system prompt, agent type, delegation level, allowed tools, spawnable subagents).

  ## Definition resolution (process-dictionary contract)

  All agent callbacks are zero-arity, so the definition cannot be passed as an
  argument. Instead, the definition id travels in the **process dictionary** under
  `:custom_agent_id`:

  - `EvoGit.Agent.Runner.setup_dispatch_context/1` puts
    `spec.opts[:custom_agent_id]` into the process dictionary before the agent loop
    starts, so the callbacks observe the value in the SAME process that runs the
    agent.
  - `definition!/0` reads `Process.get(:custom_agent_id)` and resolves the
    definition via `EvoGit.CustomAgents.get/1`.

  A missing id or an id that resolves to nil RAISES with a descriptive message.
  Raising is intentional: these callbacks run inside the agent process (never inside
  a GenServer), and a mis-specified custom agent is a configuration error that must
  crash loudly rather than silently run with the wrong definition.

  ## Definition map shape (atom-keyed)

      %{
        id: "my_agent",                          # unique id, used as :custom_agent_id
        name: "My Agent",                        # display name
        prompt: "You are ...",                   # the system prompt
        agent_type: :read | :read_write,         # absent/nil → :read_write (inherited default)
        delegation_level: :high | :low,          # absent/nil → :high (inherited default)
        subagents: ["executor", "investigator"], # absent/nil → [] (no subagents)
        tools: ["read_file", "write_file"] | nil # nil/absent → all standard tools
      }

  ## Tools whitelist

  When `tools` is nil or absent, the agent gets the standard tool set — the same
  base as the `EvoGit.Agent.__using__` default: `EvoGit.Agent.Tools.schemas/0` plus
  the subagent tool schemas generated from this agent's `subagent_modules/0` plus
  `complete_task`. When `tools` is a list, only the schemas whose tool name appears
  in the whitelist survive — including the subagent tool schemas (their tool names
  are the spawned module's `subagent_tool_name/0`, e.g. `"subagent_executor"`) and
  `complete_task`. Filtering `complete_task` out is allowed — that is the user's
  explicit choice (the agent can no longer finish through it). An unknown name in
  the whitelist simply matches nothing.

  ## Subagent name→module mapping

  The `subagents` list contains built-in agent type NAMES (strings), mapped to
  modules as follows:

      "executor"       → EvoGit.Agents.Executor
      "investigator"   → EvoGit.Agents.Investigator
      "manager"        → EvoGit.Agents.Manager
      "architect"      → EvoGit.Agents.Architect
      "task_scheduler" → EvoGit.Agents.TaskScheduler

  Atom entries are accepted too (converted via `Atom.to_string/1`). Unknown names
  are logged with a warning and skipped — a typo in a config file must not crash the
  agent.

  ## Root agents only

  `subagent_tool_name/0` is explicitly `nil`: custom agents are root agents only in
  this version and are NOT spawnable as subagents (subagent spawning resolves
  modules by matching `subagent_tool_name/0`, and a nil tool name can never match).
  """

  use EvoGit.Agent

  require Logger

  @custom_agent_id_key :custom_agent_id

  # Built-in agent type name → module mapping for the `subagents` list.
  @subagent_type_modules %{
    "executor" => EvoGit.Agents.Executor,
    "investigator" => EvoGit.Agents.Investigator,
    "manager" => EvoGit.Agents.Manager,
    "architect" => EvoGit.Agents.Architect,
    "task_scheduler" => EvoGit.Agents.TaskScheduler
  }

  def agent_type, do: field(definition!(), :agent_type) || :read_write

  def delegation_level, do: field(definition!(), :delegation_level) || :high

  def subagent_tool_name, do: nil

  def subagent_modules do
    definition!()
    |> field(:subagents)
    |> normalize_subagent_names()
    |> Enum.flat_map(&module_for_subagent_name/1)
  end

  def available_tools do
    base =
      EvoGit.Agent.Tools.schemas() ++
        EvoGit.Agent.SubagentSchemas.schemas(__MODULE__) ++
        [EvoGit.Agent.Tools.CompleteTask.schema()]

    case field(definition!(), :tools) do
      nil ->
        base

      tools when is_list(tools) ->
        Enum.filter(base, fn schema -> EvoGit.Agent.tool_name(schema) in tools end)

      other ->
        Logger.warning(
          "EvoGit.Agents.Custom: tools must be a list of tool names or absent, " <>
            "got #{inspect(other)}; using the full tool set " <>
            "(check the custom agent definition in agents.toml)"
        )

        base
    end
  end

  def system_prompt, do: field(definition!(), :prompt) || ""

  # --- Definition resolution ---

  # Resolves the custom agent definition for the CURRENT process. The definition id
  # is read from the process dictionary (`:custom_agent_id`), which
  # `EvoGit.Agent.Runner.setup_dispatch_context/1` populates from
  # `spec.opts[:custom_agent_id]`. Missing id / unknown definition raise loudly:
  # this code runs in the agent process, and a broken spec must not run silently
  # with a wrong (or absent) definition.
  defp definition! do
    id = Process.get(@custom_agent_id_key)

    if is_nil(id) do
      raise """
      EvoGit.Agents.Custom requires spec.opts[:custom_agent_id] \
      (process dictionary key #{inspect(@custom_agent_id_key)}): the custom agent \
      definition id was not set by the runner. This module must only be run as a \
      root agent with a custom_agent_id in the spec — \
      EvoGit.Agent.Runner.setup_dispatch_context/1 propagates \
      spec.opts[:custom_agent_id] into the process dictionary. \
      Check the task/agent configuration (custom agent definitions live in agents.toml).
      """
    end

    case EvoGit.CustomAgents.get(id) do
      nil ->
        raise "Unknown custom agent id: #{inspect(id)}. " <>
                "EvoGit.CustomAgents.get/1 returned nil — the definition may have " <>
                "been deleted or the id may be misspelled. Check the custom agent " <>
                "definitions in agents.toml."

      definition when is_map(definition) ->
        definition
    end
  end

  # Reads a field from the definition map, accepting both atom keys (the contract)
  # and string keys defensively; absent key → nil.
  defp field(definition, key) do
    case definition do
      %{^key => value} -> value
      _ -> Map.get(definition, Atom.to_string(key))
    end
  end

  defp normalize_subagent_names(nil), do: []

  defp normalize_subagent_names(names) when is_list(names), do: names

  defp normalize_subagent_names(other) do
    Logger.warning(
      "EvoGit.Agents.Custom: subagents must be a list of agent type names or " <>
        "absent, got #{inspect(other)}; ignoring " <>
        "(check the custom agent definition in agents.toml)"
    )

    []
  end

  defp module_for_subagent_name(name) when is_binary(name) do
    case Map.fetch(@subagent_type_modules, name) do
      {:ok, module} ->
        [module]

      :error ->
        Logger.warning(
          "EvoGit.Agents.Custom: unknown subagent type #{inspect(name)}; skipping " <>
            "(check the custom agent definition in agents.toml)"
        )

        []
    end
  end

  defp module_for_subagent_name(name) when is_atom(name),
    do: module_for_subagent_name(Atom.to_string(name))

  defp module_for_subagent_name(other) do
    Logger.warning("EvoGit.Agents.Custom: invalid subagent entry #{inspect(other)}; skipping")

    []
  end
end
