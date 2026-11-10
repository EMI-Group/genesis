defmodule EvoDashWeb.AgentsLive.OptimisticMessages do
  @moduledoc """
  Pure helpers for the optimistic display of user-sent messages in the agent
  chat history viewer.

  Messages sent via the "Send Message" modal are appended to the agent's
  `pending_user_messages` queue and are only injected into the agent's LLM
  context at the top of its NEXT turn. To give the user immediate feedback, the
  LiveView keeps an `@optimistic_messages` assign (agent_id => list of
  `%{content, sent_at}` maps) and merges it into the displayed history at render
  time.

  `prune/4` makes that bookkeeping TERMINAL: whenever fresh state about an agent
  arrives (a fetched history, or a `pending_user_messages` broadcast from the
  core's queue), entries that are provably no longer pending are REMOVED from the
  assign. A consumed entry can therefore never be resurrected — not even by the
  core's context compression, which legitimately folds older turns (including
  injected user messages) into a summary and thus removes the real `"user"`
  history entry the naive render-time dedupe used to rely on. `merge/2` remains
  as a stateless render-time dedupe safety net on top of the pruned assign.
  """

  @typedoc "An optimistic (not-yet-drained) user message."
  @type optimistic_entry :: %{content: String.t(), sent_at: DateTime.t()}

  @typedoc "Optimistic message list keyed by agent id."
  @type t :: %{optional(pos_integer()) => [optimistic_entry()]}

  @typedoc """
  The core's `pending_user_messages` queue for ONE agent.

  `nil` means UNKNOWN (never observed, e.g. no broadcast seen yet). A list means
  the queue is known — entries are either plain binary contents (legacy shape) or
  canonical multimodal `%{text: binary}` maps.
  """
  @type pending_queue :: [term()] | nil

  @doc """
  Appends a message to the optimistic list for `agent_id`, preserving existing
  entries; the new message goes at the END.
  """
  @spec append(t() | nil, pos_integer(), String.t()) :: t()
  def append(optimistic_messages, agent_id, content) do
    entry = %{content: content, sent_at: DateTime.utc_now()}

    Map.update(safe_map(optimistic_messages), agent_id, [entry], fn existing ->
      list_value(existing) ++ [entry]
    end)
  end

  @doc """
  Merges the real agent history entries with the pending optimistic entries,
  producing the full list of entries to render.

  Optimistic entries are appended AFTER the real history (never interleaved),
  so indices into the base history are unchanged. An optimistic entry is
  dropped once a real `"user"` history entry with the same content appears
  (first-match consumption: each real user entry reflects at most one
  optimistic entry, so sending the same text twice works correctly).

  This is the RENDER-time safety net: it never mutates the assign. Terminal
  removal of consumed entries is `prune/4`'s job — because a compressed context
  can lose the real user entry again, matching against history alone can neither
  confirm nor remember a drain.
  """
  @spec merge([map()] | nil, [optimistic_entry()] | nil) :: [map()]
  def merge(history, optimistic_entries) do
    entries = safe_list(history)
    latest = latest_turn(entries)

    user_contents =
      entries
      |> Enum.filter(&user_entry?/1)
      |> Enum.map(&history_content/1)

    {pending, _remaining} =
      Enum.reduce(safe_list(optimistic_entries), {[], user_contents}, fn entry,
                                                                         {acc, remaining} ->
        case match_and_consume(remaining, optimistic_content(entry)) do
          {:matched, rest} -> {acc, rest}
          :no_match -> {[to_history_entry(entry, latest) | acc], remaining}
        end
      end)

    entries ++ Enum.reverse(pending)
  end

  @doc """
  Returns the latest turn number present in the history, or `0` when empty.
  """
  @spec latest_turn([map()] | nil) :: non_neg_integer()
  def latest_turn(history) do
    history
    |> safe_list()
    |> Enum.reduce(0, fn entry, acc -> max(entry_turn(entry), acc) end)
  end

  @doc """
  Terminally prunes the optimistic entries of ONE agent against the freshest
  known state of the core's pending queue and the agent's fetched history.

  `pending_queue` is the core's `pending_user_messages` value for the agent:
  `nil` (or any non-list) means UNKNOWN, a list means KNOWN (possibly empty —
  an empty list is a drained queue). Queue entries are normalized to their
  content: a binary is its own content, a `%{text: ...}` / `%{"text" => ...}`
  map contributes its text, anything else is ignored.

  Entries are walked IN ORDER while tracking the not-yet-consumed real
  `"user"`/`"USER"` history contents (same first-match consumption as
  `merge/2`). Each optimistic entry is decided independently:

    * still present in a KNOWN queue → KEEP (still waiting to be drained); no
      history entry is consumed for it;
    * otherwise reflected by an unconsumed user history entry → DROP
      (confirmed drained) and consume that history content;
    * otherwise, with a KNOWN queue → DROP (no longer queued and absent from
      the fetched history — it was drained);
    * otherwise (queue UNKNOWN) → KEEP (nothing proves it was drained).

  The `agent_id` key is dropped entirely once its kept list becomes empty. The
  function is TOTAL: it never raises on `nil`/garbage inputs (nil map, absent
  key, non-list values, entries without `:content`).
  """
  @spec prune(t() | nil, pos_integer(), [map()] | nil, pending_queue()) :: t()
  def prune(optimistic_messages, agent_id, history, pending_queue) do
    messages = safe_map(optimistic_messages)
    entries = list_value(Map.get(messages, agent_id))

    queue = queue_state(pending_queue)

    remaining =
      history
      |> safe_list()
      |> Enum.filter(&user_entry?/1)
      |> Enum.map(&history_content/1)

    {kept, _remaining} =
      Enum.reduce(entries, {[], remaining}, fn entry, {kept, remaining} ->
        case classify(entry, queue, remaining) do
          {:keep, remaining} -> {[entry | kept], remaining}
          {:drop, remaining} -> {kept, remaining}
        end
      end)

    case Enum.reverse(kept) do
      [] -> Map.delete(messages, agent_id)
      kept -> Map.put(messages, agent_id, kept)
    end
  end

  # -- pruning internals -------------------------------------------------------

  # `{:known, contents}` = the queue was observed (a list, possibly empty);
  # `:unknown` = no list was ever observed (nil / garbage).
  defp queue_state(pending_queue) when is_list(pending_queue) do
    {:known, pending_queue |> Enum.map(&queue_content/1) |> Enum.reject(&is_nil/1)}
  end

  defp queue_state(_pending_queue), do: :unknown

  defp queue_content(entry) when is_binary(entry), do: entry

  defp queue_content(entry) when is_map(entry) do
    case Map.get(entry, :text) do
      nil -> Map.get(entry, "text")
      text -> text
    end
  end

  defp queue_content(_entry), do: nil

  # Queue KNOWN: a still-queued entry is kept; anything else is drained (either
  # reflected by the fetched history, or simply gone from both the queue and the
  # history because the context was compressed after the drain).
  defp classify(entry, {:known, queue}, remaining) do
    content = optimistic_content(entry)

    if content in queue do
      {:keep, remaining}
    else
      case match_and_consume(remaining, content) do
        {:matched, rest} -> {:drop, rest}
        :no_match -> {:drop, remaining}
      end
    end
  end

  # Queue UNKNOWN: only a real user history entry can prove a drain.
  defp classify(entry, :unknown, remaining) do
    case match_and_consume(remaining, optimistic_content(entry)) do
      {:matched, rest} -> {:drop, rest}
      :no_match -> {:keep, remaining}
    end
  end

  # A real history entry counts as "reflected" content only if it is a user
  # role entry. Legacy uppercase "USER" is tolerated alongside the current
  # lowercase "user" produced by messages_to_history_entries/1.
  defp user_entry?(entry) when is_map(entry), do: Map.get(entry, :type) in ["user", "USER"]
  defp user_entry?(_entry), do: false

  # The display content of a real history entry — nested `Map.get` so an entry
  # without `:data`/`:data.content` yields nil instead of raising.
  defp history_content(entry) when is_map(entry) do
    case Map.get(entry, :data) do
      data when is_map(data) -> Map.get(data, :content)
      _ -> nil
    end
  end

  defp history_content(_entry), do: nil

  # The content of an optimistic entry (nil for a malformed/garbage entry).
  defp optimistic_content(entry) when is_map(entry), do: Map.get(entry, :content)
  defp optimistic_content(_entry), do: nil

  defp optimistic_sent_at(entry) when is_map(entry), do: Map.get(entry, :sent_at)
  defp optimistic_sent_at(_entry), do: nil

  defp entry_turn(entry) when is_map(entry) do
    case Map.get(entry, :turn) do
      turn when is_integer(turn) -> turn
      _ -> 0
    end
  end

  defp entry_turn(_entry), do: 0

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
  defp to_history_entry(entry, latest_turn) do
    %{
      turn: latest_turn,
      timestamp: optimistic_sent_at(entry),
      type: "user",
      data: %{content: optimistic_content(entry)},
      optimistic: true
    }
  end

  # -- totality -----------------------------------------------------------------

  defp safe_list(list) when is_list(list), do: list
  defp safe_list(_other), do: []

  defp safe_map(map) when is_map(map), do: map
  defp safe_map(_other), do: %{}

  defp list_value(list) when is_list(list), do: list
  defp list_value(_other), do: []
end
