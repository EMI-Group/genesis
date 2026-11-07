defmodule EvoDashWeb.HomeLive.ChatState do
  @moduledoc """
  Owns the persisted chat-state shape for `EvoDashWeb.HomeLive`.

  The state is ONE plain map stored per-chat via
  `EvoDash.ChatHistory.put_state/2` (an in-memory, shape-agnostic store — no
  JSON round-trip, so atoms/terms survive):

      %{
        transcript: [EvoDashWeb.HomeLive.Transcript entry],
        chat_draft: String.t(),
        chat_status: :idle | :running | :cancelling,
        chat_task_id: String.t() | nil,
        chat_agent_id: term() | nil,
        agent_message_count: non_neg_integer() | nil,
        chat_task_status: nil | :pending | :running | :finalizing | :cancelling
                          | :completed | :failed | :cancelled,
        chat_node: node() | nil,
        model_spec: map() | nil,
        selected_model_id: String.t() | nil, # migration input only
        model_selection_scope: {String.t() | nil, node()} | nil,
        model_selection_error: nil | :invalid_model_spec,
        thought_process: [Messages.to_entries/1 entry]
      }

  `build/1` derives the map from LiveView assigns (persist direction);
  `restore/1` normalizes a stored map back into assign values (mount
  direction). Both are total — persisted garbage degrades to safe defaults,
  never raises.
  """

  alias EvoDashWeb.HomeLive.Transcript

  @task_statuses [:pending, :running, :finalizing, :cancelling, :completed, :failed, :cancelled]
  @chat_statuses [:idle, :running, :cancelling]

  @doc "Builds the persisted state map from the LiveView's assigns."
  @spec build(map()) :: map()
  def build(assigns) do
    %{
      transcript: assigns[:transcript] || [],
      chat_draft: assigns[:chat_draft] || "",
      chat_status: assigns[:chat_status] || :idle,
      chat_task_id: assigns[:chat_task_id],
      chat_agent_id: assigns[:chat_agent_id],
      agent_message_count: assigns[:agent_message_count],
      chat_task_status: assigns[:chat_task_status],
      chat_node: assigns[:chat_node],
      # Legacy migration input only; new submissions never emit :model_id.
      selected_model_id: assigns[:selected_model_id],
      thought_process: assigns[:thought_process] || []
    }
    |> persist_selection(assigns)
  end

  @doc """
  Normalizes a stored state map into assign values (mount direction). Total:
  non-maps restore as the empty default; malformed fields degrade per key.
  """
  @spec restore(term()) :: map()
  def restore(state) when is_map(state) do
    %{
      transcript: Transcript.normalize(Map.get(state, :transcript)),
      chat_draft: normalize_draft(Map.get(state, :chat_draft)),
      chat_status: normalize_chat_status(Map.get(state, :chat_status)),
      chat_task_id: normalize_task_id(Map.get(state, :chat_task_id)),
      chat_agent_id: Map.get(state, :chat_agent_id),
      agent_message_count: normalize_message_count(Map.get(state, :agent_message_count)),
      chat_task_status: normalize_task_status(Map.get(state, :chat_task_status)),
      chat_node: normalize_chat_node(Map.get(state, :chat_node)),
      selected_model_id: normalize_model_id(Map.get(state, :selected_model_id)),
      thought_process: normalize_thought_process(Map.get(state, :thought_process))
    }
    |> persist_selection(state)
  end

  def restore(_state), do: restore(%{})

  @doc """
  Restores ONLY the LLM choice after the page has resolved its node context.

  Scope is `{current_node_id, current_node || node()}`; a remote target id is
  retained even while disconnected so it never borrows the local node's pin.
  A different scope clears the choice to an uninitialized nil spec, which the
  shared helper reconciles to that node's configured default. An empty map is
  explicit Auto; false is malformed, never Auto. New chat on the same scope may
  retain this result; node switches must run it before sending or persisting.

  Old chats have only selected_model_id and were persisted locally: keep that
  id as migration input on the local scope only. The shared selection helper
  must resolve it against the freshly loaded config before it becomes a spec;
  an invalid/stale id is NOT Auto. A malformed explicit spec is similarly
  retained as an error, never silently reinterpreted as Auto.
  """
  @spec restore_selection(term(), {String.t() | nil, node()}) :: map()
  def restore_selection(state, scope) when is_map(state) do
    saved_scope = normalize_scope(Map.get(state, :model_selection_scope))

    legacy_local? =
      not Map.has_key?(state, :model_spec) and
        not Map.has_key?(state, :model_selection_scope) and scope == {nil, node()}

    if valid_scope?(scope) and (saved_scope == scope or legacy_local?) do
      state
      |> selection_fields()
      |> Map.put(:model_selection_scope, scope)
    else
      empty_selection(scope)
    end
  end

  def restore_selection(_state, scope), do: empty_selection(scope)

  defp persist_selection(state, source) do
    # Keep pre-redesign ChatHistory maps readable without inventing a scope.
    # The parent opts in by seeding model_spec and model_selection_scope.
    if Map.has_key?(source, :model_spec) or Map.has_key?(source, :model_selection_scope) do
      Map.merge(state, selection_fields(source))
    else
      state
    end
  end

  defp selection_fields(source) do
    {spec, error} = persisted_spec(Map.get(source, :model_spec))

    %{
      model_spec: spec,
      model_selection_scope: normalize_scope(Map.get(source, :model_selection_scope)),
      model_selection_error:
        if(Map.get(source, :model_selection_error) == :invalid_model_spec,
          do: :invalid_model_spec,
          else: error
        ),
      selected_model_id:
        if(is_nil(spec) and is_nil(error),
          do: normalize_model_id(Map.get(source, :selected_model_id))
        )
    }
  end

  # Persistence validates shape only, never catalog membership/defaults. Those
  # depend on the node's current config and belong in the shared helper.
  defp persisted_spec(nil), do: {nil, nil}

  defp persisted_spec(spec) when is_map(spec) do
    keys = ["provider_profile_id", "model", "reasoning_effort"]
    known = Map.take(spec, keys)

    if map_size(known) == map_size(spec) and Enum.all?(known, fn {_k, v} -> is_binary(v) end) do
      {known, nil}
    else
      {nil, :invalid_model_spec}
    end
  end

  defp persisted_spec(_spec), do: {nil, :invalid_model_spec}

  defp empty_selection(scope) do
    %{
      model_spec: nil,
      selected_model_id: nil,
      model_selection_scope: normalize_scope(scope),
      model_selection_error: nil
    }
  end

  defp valid_scope?({id, target_node}) do
    (is_nil(id) or (is_binary(id) and id != "")) and
      is_atom(target_node) and target_node not in [nil, true, false]
  end

  defp valid_scope?(_scope), do: false
  defp normalize_scope(scope), do: if(valid_scope?(scope), do: scope)

  defp normalize_draft(draft) when is_binary(draft), do: draft
  defp normalize_draft(_draft), do: ""

  defp normalize_chat_status(status) when status in @chat_statuses, do: status
  defp normalize_chat_status(_status), do: :idle

  defp normalize_task_id(id) when is_binary(id) and id != "", do: id
  defp normalize_task_id(_id), do: nil

  defp normalize_message_count(count) when is_integer(count) and count >= 0, do: count
  defp normalize_message_count(_count), do: nil

  defp normalize_task_status(status) when status in @task_statuses, do: status
  defp normalize_task_status(_status), do: nil

  defp normalize_chat_node(node) when is_atom(node), do: node
  defp normalize_chat_node(_node), do: nil

  @doc """
  Preserves a legacy profile id as migration input; blank/nil becomes nil
  (uninitialized, reconciled to the configured default by the shared helper).
  This is shape normalization only, not membership validation. Before sending,
  the shared helper must resolve every retained id against the node's current
  config and reject unknown ids; it must never emit a legacy :model_id pin.
  """
  @spec normalize_model_id(term()) :: String.t() | nil
  def normalize_model_id(id) when is_binary(id) and id != "", do: id
  def normalize_model_id(_id), do: nil

  defp normalize_thought_process(entries) when is_list(entries) do
    entries
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn entry ->
      %{
        turn: normalize_turn(Map.get(entry, :turn)),
        timestamp: Map.get(entry, :timestamp),
        type: normalize_type(Map.get(entry, :type)),
        data:
          case Map.get(entry, :data) do
            data when is_map(data) -> data
            _ -> %{}
          end
      }
    end)
  end

  defp normalize_thought_process(_entries), do: []

  defp normalize_turn(turn) when is_integer(turn), do: turn
  defp normalize_turn(_turn), do: 0

  defp normalize_type(type) when is_binary(type), do: type
  defp normalize_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_type(_type), do: ""
end
