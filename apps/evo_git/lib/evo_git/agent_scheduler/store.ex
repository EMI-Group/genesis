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
  @spec get_sched_meta(pos_integer()) :: {:ok, SchedMeta.t() | map()} | :error
  def get_sched_meta(agent_id) do
    case :ets.lookup(@sched_table, agent_id) do
      [{^agent_id, %{} = meta}] -> {:ok, meta}
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
  @spec get_agent_state(pos_integer()) :: {:ok, AgentState.t() | map()} | :error
  def get_agent_state(agent_id) do
    case :ets.lookup(@agent_table, agent_id) do
      [{^agent_id, %{} = agent_state}] -> {:ok, agent_state}
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
  Returns all entries from the scheduler metadata table as a list of
  `{agent_id, %SchedMeta{}}` tuples.
  """
  @spec list_sched_meta() :: [{pos_integer(), SchedMeta.t()}]
  def list_sched_meta, do: :ets.tab2list(@sched_table)

  @doc """
  Looks up task identification info for an agent from both ETS tables.
  Returns `{:ok, task_id, task_number, task_local_id}` or `{:error, :not_found}`.
  """
  @spec get_task_info(pos_integer()) ::
          {:ok, binary(), pos_integer() | nil, pos_integer()} | {:error, :not_found}
  def get_task_info(agent_id) do
    with {:ok, meta} <- get_sched_meta(agent_id),
         {:ok, agent_state} <- get_agent_state(agent_id) do
      {:ok, meta.task_id, meta.task_number, agent_state.task_local_id}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Reads the model_id from the agent state table for the given agent.
  Returns the model_id string or `nil` if the agent is not found.
  """
  @spec get_model_id(pos_integer()) :: String.t() | nil
  def get_model_id(agent_id) do
    case :ets.lookup_element(@agent_table, agent_id, 2, nil) do
      nil -> nil
      agent_state -> Map.get(agent_state, :model_id)
    end
  end

  @doc """
  Looks up the recursion depth for the given agent from the scheduler metadata table.
  Returns the depth integer or `nil` if the agent is not found.
  """
  @spec depth_of(pos_integer()) :: non_neg_integer() | nil
  def depth_of(agent_id) do
    case :ets.lookup_element(@sched_table, agent_id, 2, nil) do
      nil -> nil
      meta -> meta.depth
    end
  end

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
