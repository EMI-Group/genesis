defmodule EvoGit.Agent.Session.Summary do
  @moduledoc """
  The ONE writer/reader helper for the `:evogit_agent_summary` table.

  A session owns its `%EvoGit.Agent.State{}`; the summary table is the
  DASHBOARD-FACING read model (the same rows `EvoGit.AgentScheduler.Store`
  already serves today). `publish/3` copies only the summary-relevant fields of
  a state onto the EXISTING row, so nothing here forms a second source of truth
  and no ETS/broadcast logic is re-implemented — every write funnels through
  `EvoGit.AgentScheduler.Store.put_agent_state/2`.

  Notably `context` is deliberately NOT touched: it is still on the row today
  (the turn loop reads it), and a later checkpoint deletes that field. Merging
  onto the existing row instead of building a fresh struct is what keeps that
  transition forward-compatible.

  Every function is TOTAL: a missing table, a missing row or a malformed row is
  never an error and never raises.
  """

  alias EvoGit.Agent.State
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store

  @table :evogit_agent_summary

  @doc """
  Publishes `state`'s summary fields onto the existing row for `agent_id`.

  Returns `:ok` always: a missing row (or a missing table) is a NO-OP, because
  a session never owns row creation — the scheduler registers the row before a
  session can exist.

  `extra` keys override the derived fields (`:status`, `:current_commit`) and
  then any remaining key is applied as a plain struct update (e.g.
  `mode: :oneshot`); unknown keys are ignored so a future field cannot break a
  shipped caller.
  """
  @spec publish(pos_integer() | non_neg_integer(), State.t(), keyword() | map()) :: :ok
  def publish(agent_id, %State{} = state, extra \\ []) do
    case read(agent_id) do
      nil -> :ok
      %AgentState{} = row -> persist(agent_id, merge(row, state, extra))
    end
  end

  @doc """
  Reads the summary row for `agent_id`, or `nil` when there is no row (or no
  table yet).
  """
  @spec read(term()) :: AgentState.t() | nil
  def read(agent_id) do
    if table?() do
      case :ets.lookup(@table, agent_id) do
        [{^agent_id, %AgentState{} = row}] -> row
        _ -> nil
      end
    else
      nil
    end
  end

  @doc """
  Returns every summary row.

  Uses a value-returning match spec (`:ets.select/2`) rather than
  `:tab2list/1`, so the caller receives the row structs and nothing else.
  """
  @spec select_all() :: [AgentState.t()]
  def select_all do
    if table?() do
      :ets.select(@table, [{{:"$1", :"$2"}, [], [:"$2"]}])
    else
      []
    end
  end

  defp persist(agent_id, %AgentState{} = row) do
    # `put_agent_state/2` broadcasts the delta and resets the control-plane
    # fields; it returns `:ok` for every write.
    Store.put_agent_state(agent_id, row)
  end

  # Merges the derived summary fields, then the `extra` overrides on top of the
  # EXISTING row. `context` is never read from `state` and never written.
  defp merge(%AgentState{} = row, %State{} = state, extra) do
    extra = Map.new(extra)

    row
    |> Map.merge(%{
      turn: state.turn,
      message_count: message_count(state),
      usage: state.usage,
      total_tokens: state.total_tokens,
      compression_count: state.compression_count,
      last_activity_at: DateTime.utc_now(),
      status: Map.get(extra, :status, row.status),
      current_commit: Map.get(extra, :current_commit, row.current_commit)
    })
    |> apply_updates(Map.drop(extra, [:status, :current_commit]))
  end

  defp apply_updates(%AgentState{} = row, updates) do
    Enum.reduce(updates, row, fn
      {key, value}, acc -> if Map.has_key?(acc, key), do: Map.put(acc, key, value), else: acc
    end)
  end

  defp message_count(%State{context: %{messages: messages}}) when is_list(messages),
    do: length(messages)

  defp message_count(_state), do: 0

  defp table?, do: :ets.whereis(@table) != :undefined
end
