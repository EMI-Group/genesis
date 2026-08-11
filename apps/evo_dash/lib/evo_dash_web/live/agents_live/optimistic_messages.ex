defmodule EvoDashWeb.AgentsLive.OptimisticMessages do
  @moduledoc """
  Pure helpers for the optimistic display of user-sent messages in the agent
  chat history viewer.

  Messages sent via the "Send Message" modal are appended to the agent's
  `pending_user_messages` queue and are only injected into the agent's LLM
  context at the top of its NEXT turn. To give the user immediate feedback, the
  LiveView keeps an `@optimistic_messages` assign (agent_id => list of
  `%{content, sent_at}` maps) and merges it into the displayed history at render
  time. Once the agent drains the queue, the real `"user"` history entry appears
  and the matching optimistic copy is dropped.
  """

  @typedoc "An optimistic (not-yet-drained) user message."
  @type optimistic_entry :: %{content: String.t(), sent_at: DateTime.t()}

  @typedoc "Optimistic message list keyed by agent id."
  @type t :: %{optional(pos_integer()) => [optimistic_entry()]}

  @doc """
  Appends a message to the optimistic list for `agent_id`, preserving existing
  entries; the new message goes at the END.
  """
  @spec append(t() | nil, pos_integer(), String.t()) :: t()
  def append(optimistic_messages, agent_id, content) do
    entry = %{content: content, sent_at: DateTime.utc_now()}
    Map.update(optimistic_messages || %{}, agent_id, [entry], &(&1 ++ [entry]))
  end

  @doc """
  Merges the real agent history entries with the pending optimistic entries,
  producing the full list of entries to render.

  Optimistic entries are appended AFTER the real history (never interleaved),
  so indices into the base history are unchanged. An optimistic entry is
  dropped once a real `"user"` history entry with the same content appears
  (first-match consumption: each real user entry reflects at most one
  optimistic entry, so sending the same text twice works correctly).
  """
  @spec merge([map()], [optimistic_entry()] | nil) :: [map()]
  def merge(history, optimistic_entries) do
    latest = latest_turn(history)

    user_contents =
      history
      |> Enum.filter(&user_entry?/1)
      |> Enum.map(& &1.data.content)

    {pending, _remaining} =
      Enum.reduce(optimistic_entries || [], {[], user_contents}, fn entry, {acc, remaining} ->
        case match_and_consume(remaining, entry.content) do
          {:matched, rest} -> {acc, rest}
          :no_match -> {[to_history_entry(entry, latest) | acc], remaining}
        end
      end)

    history ++ Enum.reverse(pending)
  end

  @doc """
  Returns the latest turn number present in the history, or `0` when empty.
  """
  @spec latest_turn([map()]) :: non_neg_integer()
  def latest_turn(history) do
    Enum.reduce(history, 0, fn entry, acc -> max(entry.turn || 0, acc) end)
  end

  # A real history entry counts as "reflected" content only if it is a user
  # role entry. Legacy uppercase "USER" is tolerated alongside the current
  # lowercase "user" produced by messages_to_history_entries/1.
  defp user_entry?(entry), do: entry.type == "user" or entry.type == "USER"

  # First-match consumption: splits the remaining unconsumed user contents at
  # the first occurrence of `content`. A match means the optimistic entry has
  # been reflected by a real history entry and should be dropped; the consumed
  # content is removed so it cannot reflect a second optimistic entry.
  defp match_and_consume(list, content) do
    case Enum.split_while(list, &(&1 != content)) do
      {_prefix, [^content | rest]} -> {:matched, rest}
      _ -> :no_match
    end
  end

  # Renders an optimistic entry in the same shape the template consumes for a
  # real "user" history entry, plus the `optimistic: true` marker used to show
  # the pending hint.
  defp to_history_entry(%{content: content, sent_at: sent_at}, latest_turn) do
    %{
      turn: latest_turn,
      timestamp: sent_at,
      type: "user",
      data: %{content: content},
      optimistic: true
    }
  end
end
