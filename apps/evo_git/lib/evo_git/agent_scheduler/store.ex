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
  alias EvoGit.Agent.Usage
  alias ReqLLM.Context

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

  # --- ETS Helpers (Agent History Table) ---

  @doc """
  Gets the conversation context for an agent from the agent state table.
  Returns the context or nil if not set.
  """
  @spec get_agent_context(pos_integer()) :: ReqLLM.Context.t() | nil
  def get_agent_context(agent_id) do
    case get_agent_state(agent_id) do
      {:ok, %{context: context}} -> context
      _ -> nil
    end
  end

  @doc """
  Updates multiple fields for an agent in a single ETS get+put cycle.
  Accepts a keyword list of field-value pairs (e.g., `[context: ctx, turn: 5, usage: usage, total_tokens: 100]`).
  This avoids redundant `:ets.lookup` + `:ets.insert` round-trips when syncing
  multiple fields per agent turn.
  """
  @spec batch_update_agent(pos_integer(), keyword()) :: :ok
  def batch_update_agent(agent_id, fields) when is_list(fields) do
    {:ok, agent_state} = get_agent_state(agent_id)
    updated_state = Kernel.struct!(agent_state, fields)
    put_agent_state(agent_id, updated_state)
    :ok
  end

  @doc """
  Updates the conversation context for an agent in the agent state table.
  """
  @spec update_agent_context(pos_integer(), ReqLLM.Context.t()) :: :ok
  def update_agent_context(agent_id, %Context{} = context) do
    batch_update_agent(agent_id, context: context)
  end

  @doc """
  Updates the cumulative usage for an agent in the agent state table.
  """
  @spec update_agent_usage(pos_integer(), EvoGit.Agent.Usage.t()) :: :ok
  def update_agent_usage(agent_id, %Usage{} = usage) do
    batch_update_agent(agent_id, usage: usage)
  end

  @doc """
  Updates the current turn for an agent in the agent state table.
  """
  @spec update_agent_turn(pos_integer(), non_neg_integer()) :: :ok
  def update_agent_turn(agent_id, turn) when is_integer(turn) do
    batch_update_agent(agent_id, turn: turn)
  end

  @doc """
  Updates the cumulative token count for an agent in the agent state table.

  This mirrors `LoopState.total_tokens` so the dashboard can display context
  progress. Reset to 0 on each context compression.
  """
  @spec update_total_tokens(pos_integer(), non_neg_integer()) :: :ok
  def update_total_tokens(agent_id, total_tokens) when is_integer(total_tokens) do
    batch_update_agent(agent_id, total_tokens: total_tokens)
  end

  @doc """
  Increments the compression count for an agent in the agent state table.

  Called once per successful context-compression event to track how many times
  an agent's context has been compressed.
  """
  @spec increment_compression_count(pos_integer()) :: :ok
  def increment_compression_count(agent_id) do
    {:ok, agent_state} = get_agent_state(agent_id)

    updated_state = %{
      agent_state
      | compression_count: agent_state.compression_count + 1
    }

    put_agent_state(agent_id, updated_state)

    :ok
  end
end
