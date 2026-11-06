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
end

defmodule EvoGit.Agent.Tools.ElixirEval.Write do
  @moduledoc """
  Fixed local mutations, available only to a write- or sudo-tier broker.
  Self-targeting is forbidden; delete_task acknowledges a queued cast, not a
  persisted deletion. These calls do not roll back effects on evaluator timeout.
  """
  alias EvoGit.Agent.Tools.ElixirEval.Broker

  def start_task(type, options), do: Broker.call(:start_task, [type, options])
  def cancel_task(id), do: Broker.call(:cancel_task, [id])
  def force_kill_task(id), do: Broker.call(:force_kill_task, [id])
  def delete_task(id), do: Broker.call(:delete_task, [id])
  def guide(message), do: guide(message, %{})
  def guide(message, options), do: Broker.call(:guide, [message, options])
end
