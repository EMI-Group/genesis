defmodule EvoGit.AgentScheduler.Store do
  @moduledoc """
  Shared ETS helpers for the AgentScheduler.

  Centralizes read/write/delete operations on the two scheduler-owned ETS
  tables (`:evogit_agent_state` and `:evogit_sched_meta`). Every write/delete
  broadcasts an `:agents_updated` PubSub event so the dashboard stays in sync.
  """

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.PubSub

  @agent_table :evogit_agent_state
  @sched_table :evogit_sched_meta

  # --- Scheduler Metadata Table ---

  @doc """
  Reads the scheduler metadata for the given agent ID.
  Returns `{:ok, %SchedMeta{}}` or `:error` if not found.
  """
  @spec get_sched_meta(pos_integer()) :: {:ok, SchedMeta.t()} | :error
  def get_sched_meta(agent_id) do
    case :ets.lookup(@sched_table, agent_id) do
      [{^agent_id, %SchedMeta{} = meta}] -> {:ok, meta}
      [] -> :error
    end
  end

  @doc """
  Inserts/updates scheduler metadata for the given agent ID, then broadcasts
  an `:agents_updated` event.
  """
  @spec put_sched_meta(pos_integer(), SchedMeta.t()) :: :ok
  def put_sched_meta(agent_id, meta) do
    :ets.insert(@sched_table, {agent_id, meta})
    PubSub.broadcast_agents_updated()
  end

  @doc """
  Deletes scheduler metadata for the given agent ID, then broadcasts
  an `:agents_updated` event.
  """
  @spec delete_sched_meta(pos_integer()) :: :ok
  def delete_sched_meta(agent_id) do
    :ets.delete(@sched_table, agent_id)
    PubSub.broadcast_agents_updated()
  end

  # --- Agent State Table ---

  @doc """
  Reads the live agent state for the given agent ID.
  Returns `{:ok, %AgentState{}}` or `:error` if not found.
  """
  @spec get_agent_state(pos_integer()) :: {:ok, AgentState.t()} | :error
  def get_agent_state(agent_id) do
    case :ets.lookup(@agent_table, agent_id) do
      [{^agent_id, %AgentState{} = agent_state}] -> {:ok, agent_state}
      [] -> :error
    end
  end

  @doc """
  Inserts/updates agent state for the given agent ID, then broadcasts
  an `:agents_updated` event.
  """
  @spec put_agent_state(pos_integer(), AgentState.t()) :: :ok
  def put_agent_state(agent_id, agent_state) do
    :ets.insert(@agent_table, {agent_id, agent_state})
    PubSub.broadcast_agents_updated()
  end

  @doc """
  Deletes agent state for the given agent ID, then broadcasts
  an `:agents_updated` event.
  """
  @spec delete_agent_state(pos_integer()) :: :ok
  def delete_agent_state(agent_id) do
    :ets.delete(@agent_table, agent_id)
    PubSub.broadcast_agents_updated()
  end
end
