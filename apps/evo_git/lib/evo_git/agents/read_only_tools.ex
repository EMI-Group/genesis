defmodule EvoGit.Agents.ReadOnlyTools do
  @moduledoc """
  Shared builder for the full `available_tools/0` list of read-only agent
  types (Investigator, ContextExtractor): `EvoGit.Agent.Tools.read_only_schemas/0`
  plus the agent's own subagent tool schemas (`EvoGit.Agent.SubagentSchemas.schemas/1`)
  plus `complete_task`.

  Both agents previously inlined the identical expression; this module is the
  single source of truth for that composition. Each agent passes `__MODULE__`
  so its own `subagent_modules/0` drive the subagent-schema portion.
  """

  @doc false
  def available_tools(agent_module) do
    EvoGit.Agent.Tools.read_only_schemas() ++
      EvoGit.Agent.SubagentSchemas.schemas(agent_module) ++
      [EvoGit.Agent.Tools.CompleteTask.schema()]
  end
end
