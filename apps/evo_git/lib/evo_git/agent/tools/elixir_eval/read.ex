defmodule EvoGit.Agent.Tools.ElixirEval.Read do
  @moduledoc """
  Credential-free, local runtime projections available to sandboxed code.
  Every function requires an attached per-evaluation broker capability.
  """
  alias EvoGit.Agent.Tools.ElixirEval.Broker

  def help, do: Broker.call(:help, [])
  def system_info, do: Broker.call(:system_info, [])
  def list_tasks, do: list_tasks(%{})
  def list_tasks(options), do: Broker.call(:list_tasks, [options])
  def get_task(id), do: Broker.call(:get_task, [id])
  def list_agents, do: Broker.call(:list_agents, [])
  def scheduler_status, do: Broker.call(:scheduler_status, [])
  def model_profiles, do: Broker.call(:model_profiles, [])

  @doc "Returns only allowlisted live scheduler settings, never persisted config or credentials."
  def configuration_status, do: Broker.call(:configuration_status, [])
end

defmodule EvoGit.Agent.Tools.ElixirEval.Write do
  @moduledoc """
  Fixed local mutations, available only to a write- or sudo-tier broker.
  Self-targeting is forbidden; delete_task acknowledges a queued cast, not a
  persisted deletion. These calls do not roll back effects on evaluator timeout.
  """
  alias EvoGit.Agent.Tools.ElixirEval.Broker

  @doc """
  Updates runtime-only scheduler settings; nothing is saved to disk.
  Accepts a nonempty map of default_llm_max_concurrency/max_tool_concurrency
  (integers 1..256) and max_turns/max_turns_root (integers 1..10000), or a
  standalone boolean paused option. Atom and string keys are accepted.
  Turn caps apply to future agent registrations; concurrency retains scheduler
  floor/peak-pause semantics. Effects are not rolled back on timeout.
  """
  def update_scheduler_config(options), do: Broker.call(:update_scheduler_config, [options])

  def start_task(type, options), do: Broker.call(:start_task, [type, options])
  def cancel_task(id), do: Broker.call(:cancel_task, [id])
  def force_kill_task(id), do: Broker.call(:force_kill_task, [id])
  def delete_task(id), do: Broker.call(:delete_task, [id])
  def guide(message), do: guide(message, %{})
  def guide(message, options), do: Broker.call(:guide, [message, options])
end
