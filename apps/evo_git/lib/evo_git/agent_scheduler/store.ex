defmodule EvoGit.AgentScheduler.Store do
  @moduledoc """
  Shared ETS helpers for the AgentScheduler.

  Centralizes read/write/delete operations on the three scheduler-owned ETS
  tables:
  `:evogit_sched_meta` (scheduler metadata), `:evogit_agent_summary` (the agent
  SUMMARY row — the read model of the agent's state) and the CONTROL PLANE —
  `:evogit_agent_inbox` + `:evogit_agent_control`, owned by
  `EvoGit.AgentScheduler.ControlPlane`.

  **One writer per row.** The owning `EvoGit.Agent.Session` is the only RUNTIME
  writer of its `:evogit_agent_summary` row (through
  `EvoGit.Agent.Session.Summary.publish/3`); the other writes are registration
  writes (`Dispatch` creates the row, `Worktrees`/`Lifecycle` update its commit
  and retry fields). The row is a SUMMARY: it carries no conversation, so every
  reader treats it as a possibly-stale snapshot.

  Everything another process writes about a live agent (the injected message
  queue and the graceful-cancel flag) goes through `ControlPlane` with atomic
  ETS operations, so a cross-process write never read-modify-writes the agent's
  row at all.

  Every write/delete on the agent-state and sched-meta tables broadcasts
  enriched PubSub delta events so the dashboard can apply incremental updates,
  plus a throttled `:agents_updated` fallback for backward compat.

  All broadcasts carry a trailing `node` element (the emitting BEAM node).
  """

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.ControlPlane
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.PubSub
  alias EvoGit.Attachments

  @agent_table :evogit_agent_summary
  @sched_table :evogit_sched_meta

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
  # Agent Summary Table
  # ---------------------------------------------------------------------------

  @doc """
  Reads the agent summary row for the given agent ID.
  Returns `{:ok, %AgentState{}}` or `:error` if not found.

  The RAW row is returned verbatim: it carries no conversation and no
  cross-process control state, so no projection is applied (the injected queue
  and the cancel flag live in `EvoGit.AgentScheduler.ControlPlane`).
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

  **Invariant — the agent's session is the only RUNTIME writer of this row.**
  Cross-process state (the injected message queue, the graceful-cancel flag)
  goes through `EvoGit.AgentScheduler.ControlPlane` (atomic ETS operations on
  its own tables), so it is never written here and never read-modify-written by
  another process.

  `message_count` is an ORDINARY tracked field: it is published by the session
  like every other summary field.

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

  Also drops the agent's control-plane rows (inbox + control), so a finished
  agent never leaks them.

  Broadcasts an `:agent_removed` event plus the throttled `:agents_updated`
  fallback for backward compatibility.
  """
  @spec delete_agent_state(pos_integer()) :: :ok
  def delete_agent_state(agent_id) do
    :ets.delete(@agent_table, agent_id)
    ControlPlane.delete(agent_id)
    PubSub.broadcast_agent_removed(agent_id)
    PubSub.broadcast_agents_updated()
  end

  @doc """
  Appends a user message to an agent's pending message queue.

  Accepts BOTH shapes the queue must tolerate:

    * a legacy plain `String.t()` — stored VERBATIM, so a legacy binary stays
      byte-identical end-to-end (the pre-change behavior is unchanged);
    * a `%{text:, attachments:}` map (atom- or string-keyed) — CANONICALIZED
      through `EvoGit.Attachments.message/1` before storing, so the queue holds
      the canonical `%{text: String.t(), attachments: [map] | nil}` form.

  A malformed map (unknown attachment type, blank name/media_type, non-base64
  or oversized `data`, non-string `text`) raises the descriptive
  `ArgumentError` from `EvoGit.Attachments.message/1` (spec-error style — never
  silently dropped), and nothing is queued.

  The message is appended to the agent's inbox
  (`EvoGit.AgentScheduler.ControlPlane.append_message/2`) with ONE atomic ETS
  insert — a single atomic op with no read, so concurrent appends and drains can
  never lose a message. The message will be drained and injected into the
  agent's context at the top of its next turn by
  `drain_pending_user_messages/1`.
  """
  @spec append_pending_user_message(pos_integer(), String.t() | Attachments.message()) ::
          :ok | {:error, :not_found}
  def append_pending_user_message(agent_id, message) when is_binary(message) or is_map(message) do
    stored = canonical_pending_message(message)

    case ControlPlane.append_message(agent_id, stored) do
      :ok ->
        PubSub.broadcast_agent_updated(agent_id,
          pending_user_messages: ControlPlane.pending_messages(agent_id)
        )

        PubSub.broadcast_agents_updated()
        :ok

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Drains and returns the list of pending user messages for an agent.

  `:ets.take/2` in the control plane removes and returns every queued message in
  ONE atomic BIF, so an append landing mid-drain is either fully included or
  fully left for the next drain — never lost and never delivered twice. Returns
  the messages in append order, or `[]` when the agent has nothing pending (or
  doesn't exist).

  Every returned entry has the same shape that was appended (see
  `append_pending_user_message/2`): a legacy binary verbatim, or the canonical
  multimodal message map `%{text: String.t(), attachments: [map] | nil}`.

  Called by the agent process at the top of its turn loop (before the LLM call).
  The state row is NOT read or written here, so the agent's own concurrent
  context/turn writes are untouched.
  """
  @spec drain_pending_user_messages(pos_integer()) :: [String.t() | Attachments.message()]
  def drain_pending_user_messages(agent_id) do
    case ControlPlane.drain_messages(agent_id) do
      [] ->
        []

      messages ->
        PubSub.broadcast_agent_updated(agent_id, pending_user_messages: [])
        PubSub.broadcast_agents_updated()
        messages
    end
  end

  # Shape tolerance for a pending user message (the write half of the queue's
  # `String.t() | %{text:, attachments:}` contract):
  #
  #   * a legacy binary is stored VERBATIM — the pre-change behavior, so a
  #     legacy message stays byte-identical end-to-end;
  #   * a map is canonicalized (and validated — a malformed payload raises the
  #     descriptive `ArgumentError`) through `EvoGit.Attachments.message/1`.
  #
  # Both the map/validate seam and this verbatim binary clause live here so the
  # queue holds exactly what its callers appended, shape-for-shape.
  defp canonical_pending_message(message) when is_binary(message), do: message
  defp canonical_pending_message(message) when is_map(message), do: Attachments.message(message)

  @doc """
  Sets the `cancel_requested` flag to `true` on an agent's control row.

  Called by the scheduler when a graceful cancel is requested for the agent's
  task; the runner checks the flag at the top of each turn and clears it when
  it enters cancel-grace. The agent's state row is never written here (one
  atomic `:ets.update_element/3` on the control row instead).
  """
  @spec set_cancel_requested(pos_integer()) :: :ok | {:error, :not_found}
  def set_cancel_requested(agent_id) do
    set_cancel_requested(agent_id, true)
  end

  @doc """
  Sets the `cancel_requested` flag on an agent's control row to the given value
  (`true` to request graceful cancellation, `false`/`nil` to clear it).

  Returns `:ok` when the agent exists, `{:error, :not_found}` otherwise.
  """
  @spec set_cancel_requested(pos_integer(), boolean() | nil) :: :ok | {:error, :not_found}
  def set_cancel_requested(agent_id, value) do
    case ControlPlane.set_cancel(agent_id, value) do
      :ok ->
        PubSub.broadcast_agents_updated()
        :ok

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Returns whether a graceful cancel has been requested for the agent.

  Reads the control row (never the state row); returns `false` when the agent
  is missing or the flag is `nil`/`false`.
  """
  @spec cancel_requested?(pos_integer()) :: boolean()
  def cancel_requested?(agent_id), do: ControlPlane.cancel_requested?(agent_id)

  @doc """
  Clears the `cancel_requested` flag on an agent's control row (sets it back to
  `nil`).

  Returns `:ok` when the agent exists, `{:error, :not_found}` otherwise.
  """
  @spec clear_cancel_requested(pos_integer()) :: :ok | {:error, :not_found}
  def clear_cancel_requested(agent_id) do
    case ControlPlane.set_cancel(agent_id, nil) do
      :ok ->
        PubSub.broadcast_agents_updated()
        :ok

      {:error, :not_found} = error ->
        error
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

  @doc "Reads the immutable provider/account pool id assigned at registration."
  @spec get_provider_profile_id(pos_integer()) :: String.t() | nil
  def get_provider_profile_id(agent_id) do
    case :ets.lookup_element(@agent_table, agent_id, 2, nil) do
      nil -> nil
      agent_state -> Map.get(agent_state, :provider_profile_id)
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

  # ---------------------------------------------------------------------------
  # Private helpers — field-level diffing
  # ---------------------------------------------------------------------------

  # Fields to compare for sched-meta change detection.
  @sched_meta_tracked_fields [
    :status,
    :depth,
    :worktree,
    :session_pid,
    :mode,
    :phase,
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

  # Fields to compare for agent-state change detection (the summary field set).
  @agent_state_tracked_fields [
    :turn,
    :usage,
    :total_tokens,
    :compression_count,
    :context_node,
    :objective,
    :llm_model,
    :llm_generation_params,
    :model_id,
    :provider_profile_id,
    :model_spec,
    :model_id_locked,
    :archive,
    :repo_id,
    :repo_root,
    :foreign_repos,
    :parent_id,
    :max_retries,
    :max_depth,
    :max_turns,
    :task_local_id,
    :status,
    :mode,
    :objective_preview,
    :message_count,
    :context_window,
    :current_commit,
    :last_activity_at
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
