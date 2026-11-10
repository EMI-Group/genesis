defmodule EvoGit.AgentScheduler.Store do
  @moduledoc """
  Shared ETS helpers for the AgentScheduler.

  Centralizes read/write/delete operations on the three scheduler-owned ETS
  tables:
  `:evogit_sched_meta` (scheduler metadata), `:evogit_agent_summary` (the agent
  summary row — the read model of the agent's state) and the CONTROL PLANE —
  `:evogit_agent_inbox` + `:evogit_agent_control`, owned by
  `EvoGit.AgentScheduler.ControlPlane`.

  **One writer per row.** The agent process is the ONLY writer of its
  `:evogit_agent_summary` row. Everything another process writes about a live
  agent (`pending_user_messages`, `cancel_requested`, and the legacy
  control-plane `compression_count`) goes through `ControlPlane` with atomic ETS
  operations, so a cross-process write never read-modify-writes the whole struct
  and never loses the agent's own concurrent context writes. `get_agent_state/1`
  PROJECTS the control-plane values back onto the struct, so every consumer
  still reads one struct. The row itself carries the STATE-OWNED
  `compression_count` (`EvoGit.Agent.Session.Summary.publish/3` copies it from
  the agent's `%EvoGit.Agent.State{}`); a legacy control-plane counter still
  wins on the projection while its row exists.

  Every write/delete on the agent-state and sched-meta tables broadcasts
  enriched PubSub delta events so the dashboard can apply incremental updates,
  plus a throttled `:agents_updated` fallback for backward compat.

  All broadcasts carry a trailing `node` element (the emitting BEAM node), and
  agent-state broadcast kwlists exclude the heavy `:context` field with a
  `message_count` substituted — ETS writes stay verbatim.
  """

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.ControlPlane
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.PubSub
  alias EvoGit.Agent.Usage
  alias EvoGit.Attachments
  alias ReqLLM.Context

  @agent_table :evogit_agent_summary
  @sched_table :evogit_sched_meta

  # The control-plane fields whose live values live in `ControlPlane` (its
  # inbox/control tables), NOT in this row — plus their struct defaults. They
  # are reset to those defaults on every state write, so a projected struct can
  # never be written back and resurrect drained messages or a stale flag.
  #
  # `compression_count` is deliberately ABSENT: it is state-owned on the agent's
  # `%EvoGit.Agent.State{}` and reaches this row through
  # `EvoGit.Agent.Session.Summary.publish/3`, so resetting it here would force
  # every published count back to 0. The LEGACY control-plane counter
  # (`ControlPlane.increment_compression_count/1`) still takes precedence on the
  # read path (`ControlPlane.project/2`) while its control row exists.
  @control_field_defaults %{
    pending_user_messages: [],
    cancel_requested: nil
  }

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

  The returned struct carries the PROJECTED control-plane values
  (`pending_user_messages`, `cancel_requested`) — see
  `EvoGit.AgentScheduler.ControlPlane.project/2` — and the row's own
  state-owned `compression_count`, which the projection overrides only while a
  legacy control row exists.
  """
  @spec get_agent_state(pos_integer()) :: {:ok, AgentState.t() | map()} | :error
  def get_agent_state(agent_id) do
    case :ets.lookup(@agent_table, agent_id) do
      [{^agent_id, %{} = agent_state}] -> {:ok, ControlPlane.project(agent_id, agent_state)}
      [] -> :error
    end
  end

  @doc """
  Inserts/updates agent state for the given agent ID.

  **Invariant — the agent process is the ONLY writer of this row.** Nothing
  else may read-modify-write it: a cross-process write of `pending_user_messages`
  or `cancel_requested` goes through `EvoGit.AgentScheduler.ControlPlane`
  (atomic ETS operations), because a whole-struct write from another process
  races the agent's own context writes and silently loses one of them.

  `pending_user_messages` and `cancel_requested` are therefore RESET to their
  struct defaults before the ETS write: a projected struct (the shape
  `get_agent_state/1` returns) must never be written back, which would
  resurrect drained messages or a stale cancel flag.

  `compression_count` is NOT reset — it is state-owned on the agent's
  `%EvoGit.Agent.State{}` and this row is its read model, so the published
  count survives an ordinary state write. The legacy control-plane counter
  (`ControlPlane.increment_compression_count/1`) stays authoritative on the
  projection while its row exists.

  Broadcasts an `:agent_updated` delta event with the changed fields plus
  the throttled `:agents_updated` fallback for backward compatibility.
  Broadcast kwlists exclude heavy fields (`:context` is stripped — a no-op
  today since it is not tracked by the diff) and carry `message_count` on the
  insert path when the new state has a context; ETS writes stay verbatim.
  """
  @spec put_agent_state(pos_integer(), AgentState.t()) :: :ok
  def put_agent_state(agent_id, agent_state) do
    agent_state = reset_control_fields(agent_state)

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

    # Broadcast kwlists exclude heavy fields — `:context` is stripped here
    # defensively (a no-op today since it is untracked) so the invariant lives
    # in one place. On the INSERT path a `message_count` is prepended when the
    # state carries a context (the diff path never carries `:context`).
    broadcast_fields =
      if old_state do
        strip_heavy_fields(changes)
      else
        case agent_state.context do
          %ReqLLM.Context{messages: messages} ->
            [message_count: length(messages)] ++ strip_heavy_fields(changes)

          _ ->
            strip_heavy_fields(changes)
        end
      end

    if broadcast_fields != [] do
      PubSub.broadcast_agent_updated(agent_id, broadcast_fields)
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

  Broadcasts an enriched `:agent_updated` delta plus the throttled
  `:agents_updated` fallback for backward compat. The broadcast kwlist is the
  delta minus heavy fields — `:context` is stripped (it is the entire
  conversation and changes every turn) and a `message_count` is added when a
  context is among the updated fields — while the ETS write stays verbatim.
  """
  @spec batch_update_agent(pos_integer(), keyword()) :: :ok
  def batch_update_agent(agent_id, fields) when is_list(fields) do
    {:ok, agent_state} = get_agent_state(agent_id)

    # `agent_state` is PROJECTED (see `get_agent_state/1`), so the control
    # fields are reset to their struct defaults before the write — the live
    # values belong to `ControlPlane`, never to this row. `compression_count` is
    # state-owned and is therefore carried through verbatim.
    updated_state = agent_state |> Kernel.struct!(fields) |> reset_control_fields()

    # Direct ETS write (no put_agent_state round-trip) plus a focused delta
    # broadcast — heavy fields stripped (`:context`), `message_count` added
    # when a context is updated. Subscribers can use whichever granularity
    # they prefer.
    :ets.insert(@agent_table, {agent_id, updated_state})

    broadcast_fields =
      case fields[:context] do
        nil ->
          strip_heavy_fields(fields)

        %ReqLLM.Context{messages: messages} ->
          [message_count: length(messages)] ++ strip_heavy_fields(fields)

        _ ->
          [message_count: 0] ++ strip_heavy_fields(fields)
      end

    PubSub.broadcast_agent_updated(agent_id, broadcast_fields)
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
  Increments the LEGACY control-plane compression count for an agent.

  The context-compression path no longer calls this: the counter is state-owned
  on `%EvoGit.Agent.State{}` and reaches the row through
  `EvoGit.Agent.Session.Summary.publish/3`. This helper keeps the old shape for
  callers that still want the control-plane counter: ONE atomic
  `:ets.update_counter/4` on the control row (no read-modify-write of the state
  row), and the resulting count is broadcast as the `:agent_updated` delta.
  """
  @spec increment_compression_count(pos_integer()) :: :ok
  def increment_compression_count(agent_id) do
    # A missing agent still crashes (MatchError) — that is the documented
    # contract this helper has always had.
    {:ok, _agent_state} = get_agent_state(agent_id)
    {:ok, count} = ControlPlane.increment_compression_count(agent_id)

    PubSub.broadcast_agent_updated(agent_id, compression_count: count)
    PubSub.broadcast_agents_updated()

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers — control-plane write hygiene
  # ---------------------------------------------------------------------------

  # Resets the control-plane fields to their struct defaults before a state-row
  # write, so a projected struct (the shape `get_agent_state/1` returns) can
  # never be written back and resurrect drained messages or a stale flag.
  # `compression_count` is intentionally not among them: it is state-owned and
  # this row is its read model.
  # `Map.merge/2` keeps the write safe for the tolerant `map()` rows some tests
  # seed directly.
  defp reset_control_fields(state) when is_map(state) do
    Map.merge(state, @control_field_defaults)
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

  # Heavy fields stripped from agent-state BROADCAST kwlists. `:context` holds
  # the entire conversation (`%ReqLLM.Context{}`) and changes every LLM turn —
  # broadcasting it would copy the conversation to every subscriber. ETS writes
  # keep the full struct verbatim; only the broadcast kwlist is stripped.
  @broadcast_stripped_fields [:context]

  defp strip_heavy_fields(fields) do
    Keyword.drop(fields, @broadcast_stripped_fields)
  end

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
