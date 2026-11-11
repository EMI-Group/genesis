defmodule EvoGit.Agent.Session.Summary do
  @moduledoc """
  The ONE writer/reader helper for the `:evogit_agent_summary` table.

  A session owns its `%EvoGit.Agent.State{}`; the summary table is the
  DASHBOARD-FACING read model (the same rows `EvoGit.AgentScheduler.Store`
  already serves). `publish/3` copies EVERY summary field of a state onto the
  EXISTING row, so nothing here forms a second source of truth and no
  ETS/broadcast logic is re-implemented — every write funnels through
  `EvoGit.AgentScheduler.Store.put_agent_state/2`.

  It NEVER writes `context`: the row carries no conversation, which stays owned
  by the session (served by `EvoGit.Agent.Session.history/2`). Merging onto the
  existing row instead of building a fresh struct keeps the registration-only
  fields (`objective`, model selection, `repo_*`, limits) intact.

  Two bounds shape the published fields:

    * `objective_preview` is the objective truncated to at most 4_096 characters
      with an UTF-8-safe `String.slice/3` (a preview, never the full text);
    * a publish whose merged row is UNCHANGED (compared excluding
      `:last_activity_at`) is a NO-OP — nothing is written and `:ok` is
      returned, so `last_activity_at` only advances on a real change.

  Every function is TOTAL: a missing table, a missing row or a malformed row is
  never an error and never raises.
  """

  alias EvoGit.Agent.State
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store

  @table :evogit_agent_summary

  # The preview never carries more than this many characters of the objective.
  @objective_preview_limit 4_096

  @doc """
  Publishes `state`'s summary fields onto the existing row for `agent_id`.

  Returns `:ok` always: a missing row (or a missing table) is a NO-OP, because
  a session never owns row creation — the scheduler registers the row before a
  session can exist. A row that would not change (ignoring `last_activity_at`)
  is not written either.

  `extra` keys override the derived fields (`:status`, `:current_commit`) and
  then any remaining key is applied as a plain struct update (e.g.
  `mode: :oneshot`); unknown keys are ignored so a future field cannot break a
  shipped caller.
  """
  @spec publish(pos_integer() | non_neg_integer(), State.t(), keyword() | map()) :: :ok
  def publish(agent_id, %State{} = state, extra \\ []) do
    case read(agent_id) do
      nil -> :ok
      %AgentState{} = row -> maybe_persist(agent_id, row, merge(row, state, extra))
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

  # A publish that would not change the row is a NO-OP: `last_activity_at` is
  # excluded from the comparison, so it only advances on a real change.
  defp maybe_persist(agent_id, old_row, new_row) do
    if Map.delete(old_row, :last_activity_at) == Map.delete(new_row, :last_activity_at) do
      :ok
    else
      Store.put_agent_state(agent_id, new_row)
    end
  end

  # Merges the derived summary fields, then the `extra` overrides on top of the
  # EXISTING row. `context` is never read from `state` and never written.
  defp merge(%AgentState{} = row, %State{} = state, extra) do
    extra = Map.new(extra)

    row
    |> Map.merge(%{
      mode: state.mode,
      turn: state.turn,
      message_count: message_count(state),
      usage: state.usage,
      total_tokens: state.total_tokens,
      compression_count: state.compression_count,
      context_window: state.llm_context_window,
      objective_preview: objective_preview(state.objective),
      last_activity_at: DateTime.utc_now(),
      status: Map.get(extra, :status, row.status),
      current_commit: Map.get(extra, :current_commit, state.current_commit)
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

  # `String.slice/3` counts GRAPHEMES, so the truncation can never split a
  # multi-byte codepoint.
  defp objective_preview(objective) when is_binary(objective),
    do: String.slice(objective, 0, @objective_preview_limit)

  defp objective_preview(_objective), do: nil

  defp table?, do: :ets.whereis(@table) != :undefined
end
