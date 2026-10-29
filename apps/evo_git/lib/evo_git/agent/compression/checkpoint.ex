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

  ## A checkpoint is synthetic — never a recency anchor

  The checkpoint is NOT turn-tagged: it is inserted at index 2 while the real
  conversation's turn numbers keep growing, so a turn tag on it would pin the
  recency boundary (`Recency.boundary/3` reads `max_turn - keep`) to the
  checkpoint's own position and every later compression would find nothing old
  to replace. Instead the message carries `metadata[:checkpoint] = true`, which
  `Recency.synthetic?/1` treats as "inserted by the compressor" and excludes
  from recency math. `build/3` also drops every checkpoint from the retained
  tail and forces the split to land PAST the last prior checkpoint, so the
  rebuilt list holds exactly ONE checkpoint, always in the replaced span.

  ## The size-budgeted tail and the forward-progress guard

  The retained tail is bounded by `Recency.tail_budget/1` (`0.2 * context window`
  capped at 40k tokens), so a transcript of huge messages cannot pin an
  unbounded suffix.

  `build/3` additionally guarantees forward progress: when the transcript
  cannot fit its intended tail (`pre_estimate > budget`), the rebuilt list must
  estimate at `<= 0.9 * pre`, otherwise the leading messages of the retained
  tail are dropped (advancing past any leading `:tool` results, so tool pairing
  and the contiguous suffix survive) until it does — down to an empty tail. For
  a small, legitimate transcript (`pre <= budget`) the guard is a no-op and the
  full default tail is kept verbatim.
  """

  alias EvoGit.Agent.Compression.Recency
  alias EvoGit.Agent.Compression.SummaryPrompt
  alias ReqLLM.Message

  # The head is the system message + the original first user message. It is
  # never rewritten and never re-ordered: the provider's prompt cache depends
  # on that prefix staying byte-identical.
  @head_size 2

  # The rebuilt list must estimate at or below this fraction of the original
  # transcript before the progress guard stops trimming the retained tail.
  @progress_target_fraction 0.9

  @checkpoint_preamble """
  This is an automatically generated checkpoint of the earlier conversation in this task. Everything before this message has been compacted. Continue the task directly from the summary below — do NOT acknowledge this checkpoint, do NOT restate it, and do NOT repeat work it says is already done.
  """

  @doc """
  Splits a conversation into `head` / `old` / `recent`.

    * `head` — the first two messages, byte-identical and in order (the whole
      input when it holds fewer than two messages);
    * `old` — the span a checkpoint may replace, always containing every prior
      checkpoint message;
    * `recent` — the protected suffix (`Recency.boundary/3`), rewound so it
      starts on a non-`:tool` message and forced past the LAST prior checkpoint
      (then advanced off any `:tool` message that force exposed).

  The three parts always reproduce the input exactly:
  `head ++ old ++ recent == messages`.

  ## Options

    * `:keep_recent_turns` — turns protected verbatim, default
      `Recency.default_keep_recent_turns/0`;
    * `:context_window`, `:tail_budget_fraction`, `:tail_budget_tokens` — the
      protected tail's size budget, forwarded to `Recency.boundary/3` /
      `Recency.tail_budget/1`.
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
      split_at = split_index(messages, opts)

      %{
        head: Enum.take(messages, @head_size),
        old: Enum.slice(messages, @head_size, split_at - @head_size),
        recent: Enum.drop(messages, split_at)
      }
    end
  end

  @doc """
  Replaces the `old` span with a checkpoint message carrying `summary`.

  Returns `%{messages: messages, replaced: n, kept: k, estimated_tokens: t,
  pre_estimate: pre, budget: b, shrunk: boolean}` where `replaced` is the
  number of messages dropped, `kept` the number retained verbatim after the
  checkpoint, `estimated_tokens` the estimate of the RETURNED list,
  `pre_estimate` the estimate of the input, `budget` the tail budget in tokens
  and `shrunk` whether the progress guard trimmed the retained tail.

  `replaced: 0` with the INPUT LIST UNCHANGED means nothing was compacted,
  which is the caller's signal that the LLM call is not worth making — that
  happens when there is nothing old to replace, or when `summary` is blank (a
  blank summary must never fabricate a checkpoint that would silently drop the
  transcript).

  The returned list holds exactly ONE checkpoint: every checkpoint message is
  dropped from the retained tail. When the transcript cannot fit its intended
  tail (`pre_estimate > budget`) the retained tail is trimmed until the rebuilt
  list estimates at `<= 0.9 * pre`, so compression always makes room; a
  transcript that fits its budget keeps its full default tail verbatim.

  ## Options

    * `:keep_recent_turns` — see `split/2`;
    * `:context_window`, `:tail_budget_fraction`, `:tail_budget_tokens` — see
      `split/2`.

  The former `:turn` option is IGNORED: a checkpoint is never turn-tagged (see
  the moduledoc).
  """
  @spec build([Message.t()], String.t(), keyword()) :: %{
          messages: [Message.t()],
          replaced: non_neg_integer(),
          kept: non_neg_integer(),
          estimated_tokens: non_neg_integer(),
          pre_estimate: non_neg_integer(),
          budget: pos_integer(),
          shrunk: boolean()
        }
  def build(messages, summary, opts \\ []) when is_list(messages) do
    budget_opts = budget_opts(opts)
    pre_estimate = Recency.estimate_tokens(messages)
    budget = Recency.tail_budget(budget_opts)

    %{head: head, old: old, recent: recent} = split(messages, opts)

    if old == [] or blank?(summary) do
      %{
        messages: messages,
        replaced: 0,
        kept: length(recent),
        estimated_tokens: pre_estimate,
        pre_estimate: pre_estimate,
        budget: budget,
        shrunk: false
      }
    else
      checkpoint = checkpoint_message(summary)
      tail = Enum.reject(recent, &Recency.synthetic?/1)
      {tail, shrunk?} = enforce_progress(head, checkpoint, tail, pre_estimate, budget)
      rebuilt = head ++ [checkpoint] ++ tail

      %{
        messages: rebuilt,
        replaced: length(old),
        kept: length(tail),
        estimated_tokens: Recency.estimate_tokens(rebuilt),
        pre_estimate: pre_estimate,
        budget: budget,
        shrunk: shrunk?
      }
    end
  end

  @doc """
  The checkpoint message for `summary`.

  A `:user` message (never `:system`/`:assistant`: the summary is context the
  agent is expected to act on) whose text is the pinned checkpoint preamble
  followed by the summary wrapped in the `<compacted-summary>` delimiters, and
  which carries `metadata[:checkpoint] = true` so `Recency.synthetic?/1`
  recognises it as compressor-inserted.

  The second argument is accepted for BACKWARDS COMPATIBILITY and IGNORED — a
  checkpoint is never turn-tagged (see the moduledoc).
  """
  @spec checkpoint_message(String.t(), term()) :: Message.t()
  def checkpoint_message(summary, _turn \\ nil) when is_binary(summary) do
    text =
      @checkpoint_preamble <>
        "\n" <>
        SummaryPrompt.open_tag() <>
        "\n" <>
        String.trim(summary) <>
        "\n" <>
        SummaryPrompt.close_tag() <> "\n"

    text
    |> ReqLLM.Context.user()
    |> mark_checkpoint()
  end

  @doc """
  True only for a message the compressor inserted (a checkpoint). Delegates to
  `Recency.synthetic?/1` so there is ONE detection rule: `metadata[:checkpoint]
  == true`, or a `:user` message whose text carries BOTH checkpoint delimiters.
  Total — every other shape (other roles, no text, non-messages) is `false`.
  """
  @spec checkpoint?(term()) :: boolean()
  def checkpoint?(message), do: Recency.synthetic?(message)

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

  defp budget_opts(opts) do
    Keyword.take(opts, [:context_window, :tail_budget_fraction, :tail_budget_tokens])
  end

  # The recency boundary, floored at the head, rewound off any `:tool` message,
  # then FORCED past the last prior checkpoint so a previous checkpoint can
  # never sit inside the protected tail (it would then never be replaced).
  # A retained tool result whose producing assistant `tool_calls` message was
  # replaced is an invalid conversation the provider rejects, so the rewind
  # always keeps the assistant message (never below the head) — and the force,
  # which moves the index the other way, advances off any `:tool` it exposes.
  defp split_index(messages, opts) do
    count = length(messages)

    index =
      max(@head_size, Recency.boundary(messages, keep_recent_turns(opts), budget_opts(opts)))

    messages
    |> rewind_off_tool(index)
    |> force_past_last_checkpoint(messages)
    |> advance_off_tool(messages, count)
  end

  defp rewind_off_tool(messages, index) when index > @head_size do
    case Enum.at(messages, index) do
      %Message{role: :tool} -> rewind_off_tool(messages, index - 1)
      _ -> index
    end
  end

  defp rewind_off_tool(_messages, index), do: index

  defp force_past_last_checkpoint(index, messages) do
    case last_checkpoint_index(messages) do
      nil -> index
      last -> max(index, last + 1)
    end
  end

  defp last_checkpoint_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {message, index}, acc ->
      if Recency.synthetic?(message), do: index, else: acc
    end)
  end

  defp advance_off_tool(index, messages, count) when index < count do
    case Enum.at(messages, index) do
      %Message{role: :tool} -> advance_off_tool(index + 1, messages, count)
      _ -> index
    end
  end

  defp advance_off_tool(index, _messages, _count), do: index

  defp mark_checkpoint(%Message{} = message) do
    metadata =
      case message.metadata do
        metadata when is_map(metadata) -> metadata
        _ -> %{}
      end

    %{message | metadata: Map.put(metadata, :checkpoint, true)}
  end

  # Forward progress: only a transcript that CANNOT fit its intended tail (pre
  # estimate above the budget) is trimmed, so a small legitimate conversation
  # keeps its full default tail verbatim.
  defp enforce_progress(head, checkpoint, tail, pre_estimate, budget)
       when pre_estimate > budget do
    limit = round(pre_estimate * @progress_target_fraction)
    shrink_tail(head, checkpoint, tail, limit, false)
  end

  defp enforce_progress(_head, _checkpoint, tail, _pre_estimate, _budget), do: {tail, false}

  defp shrink_tail(head, checkpoint, tail, limit, shrunk?) do
    if Recency.estimate_tokens(head ++ [checkpoint] ++ tail) <= limit do
      {tail, shrunk?}
    else
      case drop_leading_tail(tail) do
        ^tail -> {tail, shrunk?}
        next -> shrink_tail(head, checkpoint, next, limit, true)
      end
    end
  end

  # Drops the FIRST retained message and any `:tool` messages it uncovers, so
  # the tail stays a contiguous suffix that never starts on an orphaned tool
  # result. An empty tail stays empty (the caller's stop condition).
  defp drop_leading_tail([]), do: []

  defp drop_leading_tail(tail) do
    tail
    |> Enum.drop(1)
    |> Enum.drop_while(&tool_message?/1)
  end

  defp tool_message?(%Message{role: :tool}), do: true
  defp tool_message?(_message), do: false

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
