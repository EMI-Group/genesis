defmodule EvoGit.AgentScheduler.Store do
  @moduledoc """
  Shared ETS helpers for the AgentScheduler.

  Centralizes read/write/delete operations on the three scheduler-owned ETS
  tables (`:evogit_agent_state`, `:evogit_sched_meta`, and the task archive
  table `:evogit_archive_records`). Every write/delete on the agent-state and
  sched-meta tables broadcasts enriched PubSub delta events so the dashboard
  can apply incremental updates, plus a throttled `:agents_updated` fallback
  for backward compat. Archive-table operations are PubSub-free.
  """

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.PubSub
  alias EvoGit.Agent.Usage
  alias ReqLLM.Context

  @agent_table :evogit_agent_state
  @sched_table :evogit_sched_meta
  @archive_table :evogit_archive_records

  # ---------------------------------------------------------------------------
  # Scheduler Metadata Table
  # ---------------------------------------------------------------------------

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
  Inserts/updates scheduler metadata for the given agent ID.

  Broadcasts an enriched `:agent_registered` event for new agents (status
  `:pending`) or an `:agent_updated` delta for updates.  Always also sends
  the throttled `:agents_updated` fallback for backward compatibility.
  """
  @spec put_sched_meta(pos_integer(), SchedMeta.t()) :: :ok
  def put_sched_meta(agent_id, meta) do
    old_meta =
      case :ets.lookup(@sched_table, agent_id) do
        [{^agent_id, existing}] -> existing
        [] -> nil
      end

    :ets.insert(@sched_table, {agent_id, meta})

    if old_meta do
      changes = sched_meta_changes(old_meta, meta)

      if changes != [] do
        PubSub.broadcast_agent_updated(agent_id, changes)
      end
    else
      PubSub.broadcast_agent_registered(agent_id, %{
        status: meta.status,
        depth: meta.depth,
        parent_id: meta.parent_id,
        task_id: meta.task_id,
        task_number: meta.task_number,
        objective: meta.spec.objective
      })
    end

    PubSub.broadcast_agents_updated()
  end

  @doc """
  Deletes scheduler metadata for the given agent ID.

  Broadcasts an `:agent_removed` event plus the throttled `:agents_updated`
  fallback for backward compatibility.
  """
  @spec delete_sched_meta(pos_integer()) :: :ok
  def delete_sched_meta(agent_id) do
    :ets.delete(@sched_table, agent_id)
    PubSub.broadcast_agent_removed(agent_id)
    PubSub.broadcast_agents_updated()
  end

  # ---------------------------------------------------------------------------
  # Agent State Table
  # ---------------------------------------------------------------------------

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
  Inserts/updates agent state for the given agent ID.

  Broadcasts an `:agent_updated` delta event with the changed fields plus
  the throttled `:agents_updated` fallback for backward compatibility.
  """
  @spec put_agent_state(pos_integer(), AgentState.t()) :: :ok
  def put_agent_state(agent_id, agent_state) do
    old_state =
      case :ets.lookup(@agent_table, agent_id) do
        [{^agent_id, existing}] -> existing
        [] -> nil
      end

    :ets.insert(@agent_table, {agent_id, agent_state})

    changes =
      if old_state do
        agent_state_changes(old_state, agent_state)
      else
        initial_agent_state_fields(agent_state)
      end

    if changes != [] do
      PubSub.broadcast_agent_updated(agent_id, changes)
    end

    PubSub.broadcast_agents_updated()
  end

  @doc """
  Deletes agent state for the given agent ID.

  Broadcasts an `:agent_removed` event plus the throttled `:agents_updated`
  fallback for backward compatibility.
  """
  @spec delete_agent_state(pos_integer()) :: :ok
  def delete_agent_state(agent_id) do
    :ets.delete(@agent_table, agent_id)
    PubSub.broadcast_agent_removed(agent_id)
    PubSub.broadcast_agents_updated()
  end

  @doc """
  Appends a user message to an agent's pending message queue.

  Called through the AgentScheduler GenServer (serialized), so concurrent
  appends are safe. The message will be drained and injected into the agent's
  context at the top of its next turn by `drain_pending_user_messages/1`.
  """
  @spec append_pending_user_message(pos_integer(), String.t()) :: :ok | {:error, :not_found}
  def append_pending_user_message(agent_id, message) when is_binary(message) do
    case get_agent_state(agent_id) do
      {:ok, agent_state} ->
        updated = %{
          agent_state
          | pending_user_messages: agent_state.pending_user_messages ++ [message]
        }

        put_agent_state(agent_id, updated)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Drains and returns the list of pending user messages for an agent.

  Reads the latest agent state from ETS, extracts the pending messages, and
  resets the `pending_user_messages` field to `[]`. Returns the drained list.
  Returns `[]` if the agent doesn't exist or has no pending messages.

  Called by the agent process at the top of its turn loop (before the LLM call).
  The re-read of the full struct ensures we get the latest context/turn/etc.
  from the agent's own writes, minimizing the race window.
  """
  @spec drain_pending_user_messages(pos_integer()) :: [String.t()]
  def drain_pending_user_messages(agent_id) do
    case get_agent_state(agent_id) do
      {:ok, agent_state} ->
        messages = agent_state.pending_user_messages

        if messages != [] do
          put_agent_state(agent_id, %{agent_state | pending_user_messages: []})
        end

        messages

      :error ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Archive Records Table
  # ---------------------------------------------------------------------------

  @doc """
  Writes an archive record for the given task/agent pair.

  The `:evogit_archive_records` table is a `:set` keyed by `{task_id, agent_id}`,
  so re-writing the same pair (e.g., a crash-retry that completes twice) is an
  idempotent overwrite — at most ONE record per agent per task.
  """
  @spec put_archive_record(binary(), pos_integer(), map()) :: :ok | true
  def put_archive_record(task_id, agent_id, record) when is_map(record) do
    case :ets.whereis(@archive_table) do
      :undefined -> :ok
      _tid -> :ets.insert(@archive_table, {{task_id, agent_id}, record})
    end
  end

  @doc """
  Collects all archive records for the given task ID.

  Returns the records (without key tuples) in unspecified order, or `[]` when
  the table is missing.
  """
  @spec collect_archive_records(binary()) :: [map()]
  def collect_archive_records(task_id) do
    case :ets.whereis(@archive_table) do
      :undefined ->
        []

      _tid ->
        :ets.match(@archive_table, {{task_id, :_}, :"$1"})
        |> List.flatten()
    end
  end

  @doc """
  Clears all archive records for the given task ID.

  Returns `:ok` in both branches (also when the table is missing).
  """
  @spec clear_archive_records(binary()) :: :ok
  def clear_archive_records(task_id) do
    case :ets.whereis(@archive_table) do
      :undefined ->
        :ok

      _tid ->
        :ets.match_delete(@archive_table, {{task_id, :_}, :_})
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # ETS Helpers (Agent History Table)
  # ---------------------------------------------------------------------------

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

  Broadcasts an enriched `:agent_updated` delta with the exact changed fields,
  plus the throttled `:agents_updated` fallback for backward compat.
  """
  @spec batch_update_agent(pos_integer(), keyword()) :: :ok
  def batch_update_agent(agent_id, fields) when is_list(fields) do
    {:ok, agent_state} = get_agent_state(agent_id)
    updated_state = Kernel.struct!(agent_state, fields)

    # Write through put_agent_state which does its own enriched broadcast.
    # We also emit the exact fields kwlist as a focused delta — subscribers
    # can use whichever granularity they prefer.
    :ets.insert(@agent_table, {agent_id, updated_state})
    PubSub.broadcast_agent_updated(agent_id, fields)
    PubSub.broadcast_agents_updated()

    :ok
  end

  @doc """
  Updates the conversation context for an agent in the agent state table.

  A dumb pass-through write — per-message `metadata[:timestamp]` stamping
  happens at message-creation time in the agent code (see
  `EvoGit.Agent.ContextBuilder.tag_message_turn/2`), never here. There is no
  read-back: data flows one way, agent → ETS/pubsub → frontend.
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

  # ---------------------------------------------------------------------------
  # Private helpers — field-level diffing
  # ---------------------------------------------------------------------------

  # Fields to compare for sched-meta change detection.
  @sched_meta_tracked_fields [
    :status,
    :depth,
    :worktree,
    :task_ref,
    :from,
    :parent_id,
    :task_id,
    :task_number,
    :retries,
    :result_sent,
    :sub_agent_from,
    :total_sub_specs,
    :pending_sub_agents,
    :sub_agent_results,
    :sub_agent_indices,
    :foreign_repo_commits
  ]

  # Fields to compare for agent-state change detection.
  # `context` is intentionally excluded — it is large, changes every turn, and
  # its progress is tracked via `total_tokens` which is sufficient for the
  # dashboard.
  @agent_state_tracked_fields [
    :turn,
    :usage,
    :total_tokens,
    :compression_count,
    :phylo_node,
    :context_node,
    :objective,
    :llm_model,
    :llm_generation_params,
    :model_id,
    :archive,
    :repo_id,
    :repo_root,
    :foreign_repos,
    :parent_id,
    :max_retries,
    :max_depth,
    :max_turns,
    :task_local_id,
    :pending_user_messages
  ]

  defp sched_meta_changes(old, new) do
    diff_fields(old, new, @sched_meta_tracked_fields)
  end

  defp agent_state_changes(old, new) do
    diff_fields(old, new, @agent_state_tracked_fields)
  end

  defp diff_fields(old, new, fields) do
    Enum.reduce(fields, [], fn field, acc ->
      old_val = Map.get(old, field)
      new_val = Map.get(new, field)

      if old_val != new_val do
        [{field, new_val} | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp initial_agent_state_fields(state) do
    Enum.reduce(@agent_state_tracked_fields, [], fn field, acc ->
      case Map.get(state, field) do
        nil -> acc
        val -> [{field, val} | acc]
      end
    end)
    |> Enum.reverse()
  end
end
