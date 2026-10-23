defmodule EvoGit.Agent.Compression.Checkpoint do
  @moduledoc """
  Span replacement for context compression: swap the OLD span of a conversation
  for ONE checkpoint message and keep the head plus the recent tail intact.

  Pure — no I/O, no LLM call, no state. The caller decides WHEN to compact (a
  token threshold) and provides the summary text; this module only decides
  which messages go and how the checkpoint is shaped.

  ## Why span replacement (and not the append-only instruction)

  Appending "summarise the conversation above" to the live history and then
  rebuilding the list from `[system, user, summary]` throws away the recent
  turns the agent is actively working on. Keeping the last
  `Recency.default_keep_recent_turns/0` turns VERBATIM preserves the working
  set, and keeping the first two messages byte-identical preserves the
  provider's cached prefix (the system prompt and the original objective, which
  never changes).

  ## Shape

      [system, first_user | old ... recent ...]
      [system, first_user, checkpoint,        ...recent...]

  `old` is replaced by exactly one `:user` message (the checkpoint), whose text
  carries the summary inside the `<compacted-summary>` delimiters. The retained
  suffix never starts with an orphaned `:tool` message: a candidate boundary
  that lands on one is rewound to the assistant message that produced it.
  """

  alias EvoGit.Agent.Compression.Recency
  alias EvoGit.Agent.Compression.SummaryPrompt
  alias EvoGit.Agent.ContextBuilder
  alias ReqLLM.Message

  # The head is the system message + the original first user message. It is
  # never rewritten and never re-ordered: the provider's prompt cache depends
  # on that prefix staying byte-identical.
  @head_size 2

  @checkpoint_preamble """
  This is an automatically generated checkpoint of the earlier conversation in this task. Everything before this message has been compacted. Continue the task directly from the summary below — do NOT acknowledge this checkpoint, do NOT restate it, and do NOT repeat work it says is already done.
  """

  @doc """
  Splits a conversation into `head` / `old` / `recent`.

    * `head` — the first two messages, byte-identical and in order (the whole
      input when it holds fewer than two messages);
    * `old` — the span a checkpoint may replace;
    * `recent` — the protected suffix (`Recency.boundary/2`), rewound so it
      starts on a non-`:tool` message.

  The three parts always reproduce the input exactly:
  `head ++ old ++ recent == messages`.

  ## Options

    * `:keep_recent_turns` — turns protected verbatim, default
      `Recency.default_keep_recent_turns/0`.
  """
  @spec split([Message.t()], keyword()) :: %{
          head: [Message.t()],
          old: [Message.t()],
          recent: [Message.t()]
        }
  def split(messages, opts \\ []) when is_list(messages) do
    if length(messages) < @head_size do
      %{head: messages, old: [], recent: []}
    else
      split_at = split_index(messages, keep_recent_turns(opts))

      %{
        head: Enum.take(messages, @head_size),
        old: Enum.slice(messages, @head_size, split_at - @head_size),
        recent: Enum.drop(messages, split_at)
      }
    end
  end

  @doc """
  Replaces the `old` span with a checkpoint message carrying `summary`.

  Returns `%{messages: messages, replaced: non_neg_integer(), kept: n}` where
  `replaced` is the number of messages dropped and `kept` the number retained
  verbatim after the checkpoint. `replaced: 0` with the INPUT LIST UNCHANGED
  means nothing was compacted, which is the caller's signal that the LLM call
  is not worth making — that happens when there is nothing old to replace, or
  when `summary` is blank (a blank summary must never fabricate a checkpoint
  that would silently drop the transcript).

  ## Options

    * `:keep_recent_turns` — see `split/2`;
    * `:turn` — integer turn tag for the checkpoint message (via
      `EvoGit.Agent.ContextBuilder.tag_message_turn/2`); absent/nil leaves the
      message untagged.
  """
  @spec build([Message.t()], String.t(), keyword()) :: %{
          messages: [Message.t()],
          replaced: non_neg_integer(),
          kept: non_neg_integer()
        }
  def build(messages, summary, opts \\ []) when is_list(messages) do
    %{head: head, old: old, recent: recent} = split(messages, opts)

    if old == [] or blank?(summary) do
      %{messages: messages, replaced: 0, kept: length(recent)}
    else
      checkpoint = checkpoint_message(summary, Keyword.get(opts, :turn))

      %{
        messages: head ++ [checkpoint] ++ recent,
        replaced: length(old),
        kept: length(recent)
      }
    end
  end

  @doc """
  The checkpoint message for `summary`.

  A `:user` message (never `:system`/`:assistant`: the summary is context the
  agent is expected to act on) whose text is the pinned checkpoint preamble
  followed by the summary wrapped in the `<compacted-summary>` delimiters.
  `turn` (integer or nil) turn-tags it like any other appended message.
  """
  @spec checkpoint_message(String.t(), integer() | nil) :: Message.t()
  def checkpoint_message(summary, turn \\ nil) when is_binary(summary) do
    text =
      @checkpoint_preamble <>
        "\n" <>
        SummaryPrompt.open_tag() <>
        "\n" <>
        String.trim(summary) <>
        "\n" <>
        SummaryPrompt.close_tag() <> "\n"

    message = ReqLLM.Context.user(text)

    case turn do
      turn when is_integer(turn) -> ContextBuilder.tag_message_turn(message, turn)
      _ -> message
    end
  end

  @doc """
  True only for a `:user` message whose text carries BOTH checkpoint
  delimiters. Total — every other shape (other roles, no text, non-messages)
  is `false`.
  """
  @spec checkpoint?(term()) :: boolean()
  def checkpoint?(%Message{role: :user} = message) do
    text = text_of(message)

    String.contains?(text, SummaryPrompt.open_tag()) and
      String.contains?(text, SummaryPrompt.close_tag())
  end

  def checkpoint?(_message), do: false

  @doc """
  The summary carried by the LAST checkpoint message in `messages`, trimmed;
  `nil` when the list holds no checkpoint (or the checkpoint body is blank).

  This is what makes repeated compactions ACCUMULATE: each new checkpoint is
  built from `SummaryPrompt.instruction(prior_summary(messages))`, so detail
  from earlier checkpoints survives instead of being replaced by a summary of a
  summary that forgot it.
  """
  @spec prior_summary([Message.t()]) :: String.t() | nil
  def prior_summary(messages) when is_list(messages) do
    messages
    |> Enum.filter(&checkpoint?/1)
    |> List.last()
    |> case do
      nil -> nil
      message -> message |> text_of() |> inner_summary()
    end
  end

  def prior_summary(_messages), do: nil

  # --- Internals ---

  defp keep_recent_turns(opts) do
    case Keyword.get(opts, :keep_recent_turns) do
      keep when is_integer(keep) and keep > 0 -> keep
      _ -> Recency.default_keep_recent_turns()
    end
  end

  # The recency boundary, floored at the head and then rewound off any `:tool`
  # message. A retained tool result whose producing assistant `tool_calls`
  # message was replaced is an invalid conversation the provider rejects, so the
  # rewind always keeps the assistant message (never below the head).
  defp split_index(messages, keep) do
    index = max(@head_size, Recency.boundary(messages, keep))
    rewind_off_tool(messages, index)
  end

  defp rewind_off_tool(messages, index) when index > @head_size do
    case Enum.at(messages, index) do
      %Message{role: :tool} -> rewind_off_tool(messages, index - 1)
      _ -> index
    end
  end

  defp rewind_off_tool(_messages, index), do: index

  defp inner_summary(text) do
    open = SummaryPrompt.open_tag()
    close = SummaryPrompt.close_tag()

    with [_, after_open] <- String.split(text, open, parts: 2),
         [inner, _] <- String.split(after_open, close, parts: 2) do
      case String.trim(inner) do
        "" -> nil
        summary -> summary
      end
    else
      _ -> nil
    end
  end

  # The response TEXT of a message: the `:text` content parts joined. Reasoning
  # parts (`:thinking`) are deliberately excluded — a checkpoint never contains
  # them.
  defp text_of(%Message{content: content}) when is_list(content) do
    content
    |> Enum.map(&part_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp text_of(_message), do: ""

  defp part_text(part) when is_map(part) do
    case {map_get(part, :type), map_get(part, :text)} do
      {:text, text} when is_binary(text) -> text
      _ -> nil
    end
  end

  defp part_text(_part), do: nil

  # Atom- or string-keyed part tolerance keeps this total for loose map shapes
  # without a rescuing guard.
  defp map_get(part, key) do
    case Map.fetch(part, key) do
      {:ok, value} -> value
      :error -> Map.get(part, Atom.to_string(key))
    end
  end

  # A nil/blank summary must never produce a checkpoint, and a non-binary value
  # is out of contract — either way `build/3` reports `replaced: 0` with the
  # input unchanged, so the caller always sees that nothing was compacted.
  defp blank?(summary) when is_binary(summary), do: String.trim(summary) == ""
  defp blank?(_summary), do: true
end
