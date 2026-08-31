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
      thought_process: assigns[:thought_process] || []
    }
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
      thought_process: normalize_thought_process(Map.get(state, :thought_process))
    }
  end

  def restore(_state), do: restore(%{})

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
