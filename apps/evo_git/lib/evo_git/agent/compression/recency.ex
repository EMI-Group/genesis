defmodule EvoGit.Agent.Compression.Recency do
  @moduledoc """
  Single source of truth for "which messages belong to the last K turns" and
  for how big the protected suffix may grow.

  Both compression stages need the SAME recency boundary — the model-free
  tool-result pruner (`EvoGit.Agent.Compression.ToolResultPruner`) may only
  touch messages OLDER than it, and the LLM checkpoint
  (`EvoGit.Agent.Compression.Checkpoint`) may only replace the span OLDER than
  it. Keeping the rule in one module guarantees the two stages can never
  disagree about what "recent work" means.

  ## The rule

  Messages carry their turn number in `metadata[:turn]` (stamped by
  `EvoGit.Agent.ContextBuilder.tag_message_turn/2`). The last `keep` DISTINCT
  turns are protected: every message whose turn is greater than
  `max_turn - keep` is recent.

  Because some messages legitimately carry no turn tag (tool results appended
  mid-turn, timestamp-only nudges), the turn-based boundary is combined with a
  positional floor of the last `2 * keep` messages: `boundary/3` always returns
  the SMALLER (earlier) of the two indexes, i.e. it protects MORE, never less.
  When no message carries a turn tag at all, the positional floor alone
  applies.

  ## Synthetic messages never influence recency

  A message the compressor INSERTED (`synthetic?/1`: a checkpoint carrying
  `metadata[:checkpoint]`, or a `:user` message holding a
  `SummaryPrompt` block) is not real conversation. Such messages are excluded
  from BOTH the collected turn list and the index scan, so a checkpoint can
  never pin the boundary (the checkpoint sits at index 2 while the transcript's
  real turns keep growing).

  ## The tail size budget

  Recency alone can protect an unbounded amount of text when individual
  messages are huge, so the protected suffix is additionally capped by a token
  budget — `0.2 * context_window`, capped at 40_000 tokens (`tail_budget/1`).
  `estimate_tokens/1` is the ONE chars -> tokens estimator for the whole
  compression subsystem; every other module delegates here instead of
  re-deriving the ratio.

  The budget may only SHRINK the protected suffix: the returned index only ever
  increases (protecting LESS), never decreases, and it stops at the last
  message so a single message is always retained. After fitting, a boundary
  that would land on a `:tool` result is rewound onto the producing assistant
  message, so a tool result is never orphaned and the protected region stays
  ONE contiguous suffix.
  """

  alias ReqLLM.Message

  alias EvoGit.Agent.Compression.SummaryPrompt

  @default_keep_recent_turns 4
  @default_tail_budget_fraction 0.2
  @default_tail_budget_tokens 40_000

  @doc """
  The default recency window (in turns) kept intact by both stages.
  """
  @spec default_keep_recent_turns() :: pos_integer()
  def default_keep_recent_turns, do: @default_keep_recent_turns

  @doc """
  The default fraction of the context window the protected tail may occupy.
  """
  @spec default_tail_budget_fraction() :: float()
  def default_tail_budget_fraction, do: @default_tail_budget_fraction

  @doc """
  The default fixed cap (in tokens) of the protected tail.
  """
  @spec default_tail_budget_tokens() :: pos_integer()
  def default_tail_budget_tokens, do: @default_tail_budget_tokens

  @doc """
  The token budget of the protected tail: `min(fraction * window, cap)`,
  floored at 1.

  Options:

    * `:context_window` — a positive integer; anything else falls back to
      `EvoGit.Config.Schema.LLM.default_context_window/0`
    * `:tail_budget_fraction` — a positive number overriding the app-env seam
      `:compression_tail_budget_fraction` (default `0.2`)
    * `:tail_budget_tokens` — a positive integer overriding the app-env seam
      `:compression_tail_budget_tokens` (default `40_000`)

  Both seams are read at CALL time; unusable values fall back to the defaults.
  Total — never raises.
  """
  @spec tail_budget(keyword()) :: pos_integer()
  def tail_budget(opts \\ [])

  def tail_budget(opts) when is_list(opts) do
    window =
      case Keyword.get(opts, :context_window) do
        window when is_integer(window) and window > 0 -> window
        _ -> EvoGit.Config.Schema.LLM.default_context_window()
      end

    fraction = usable_fraction(Keyword.get(opts, :tail_budget_fraction))
    cap = usable_tokens(Keyword.get(opts, :tail_budget_tokens))

    max(min(round(fraction * window), cap), 1)
  end

  def tail_budget(_opts), do: tail_budget([])

  defp usable_fraction(fraction) when is_number(fraction) and fraction > 0, do: fraction

  defp usable_fraction(_fraction),
    do: usable_env_value(:compression_tail_budget_fraction, @default_tail_budget_fraction)

  defp usable_tokens(tokens) when is_integer(tokens) and tokens > 0, do: tokens

  defp usable_tokens(_tokens),
    do: usable_env_value(:compression_tail_budget_tokens, @default_tail_budget_tokens)

  defp usable_env_value(key, default) do
    case Application.get_env(:evo_git, key, default) do
      value when is_number(value) and value > 0 -> value
      _ -> default
    end
  end

  @doc """
  Total number of characters a message list carries: `:text`/`:thinking` parts
  count their byte size, media parts count their payload (`data`/`url`/
  `file_id`) bytes, a legacy binary content counts its byte size and anything
  else counts 0. A non-list yields 0. Total — never raises.
  """
  @spec char_count(term()) :: non_neg_integer()
  def char_count(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn message, total -> total + message_chars(message) end)
  end

  def char_count(_messages), do: 0

  @doc """
  Estimated token count of a message list: the ceiling of `char_count / 4`.

  This is the ONE chars -> tokens estimator of the compression subsystem.
  """
  @spec estimate_tokens(term()) :: non_neg_integer()
  def estimate_tokens(messages), do: tokens_for(char_count(messages))

  @doc """
  True when a message was INSERTED by the compressor instead of being part of
  the real conversation: a message carrying `metadata[:checkpoint] == true`, or
  a `:user` message whose text contains BOTH the `SummaryPrompt` open and close
  tags. Total over any term — never raises.
  """
  @spec synthetic?(term()) :: boolean()
  def synthetic?(%Message{metadata: metadata} = message) when is_map(metadata) do
    Map.get(metadata, :checkpoint) == true or summary_message?(message)
  end

  def synthetic?(%Message{} = message), do: summary_message?(message)
  def synthetic?(_message), do: false

  defp summary_message?(%Message{role: :user} = message) do
    text = text_of(message)

    String.contains?(text, SummaryPrompt.open_tag()) and
      String.contains?(text, SummaryPrompt.close_tag())
  end

  defp summary_message?(_message), do: false

  @doc """
  The turn number stamped into a message's metadata, or `nil` when the message
  carries no usable integer turn tag. Total — never raises.
  """
  @spec turn_of(term()) :: non_neg_integer() | nil
  def turn_of(%Message{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :turn) do
      turn when is_integer(turn) and turn >= 0 -> turn
      _ -> nil
    end
  end

  def turn_of(%Message{}), do: nil
  def turn_of(_), do: nil

  @doc """
  Index of the FIRST message in the protected (recent) suffix.

  Everything at an index `>= boundary/3` is recent and must be left untouched;
  everything below it is "old" and fair game for pruning/span replacement.
  Returns the list length when the whole list is recent (nothing is old).

  The boundary is, in order: the turn-based index (excluding synthetic
  messages) or the positional floor, whichever is smaller; then the tail size
  budget may push it LATER (protecting less, never more, never past the last
  message); then a boundary landing on a `:tool` result is rewound onto the
  producing assistant message so no tool result is orphaned.
  """
  @spec boundary([Message.t()] | list(), pos_integer(), keyword()) :: non_neg_integer()
  def boundary(messages, keep \\ @default_keep_recent_turns, opts \\ [])

  def boundary(messages, keep, opts) when is_list(messages) and is_integer(keep) and keep > 0 do
    count = length(messages)
    tuple = List.to_tuple(messages)

    by_turn = turn_boundary(tuple, count, keep)
    positional = max(count - 2 * keep, 0)
    base = min(by_turn, positional)

    tuple
    |> fit_budget(base, tail_budget(opts))
    |> rewind_off_tool(tuple)
  end

  def boundary(_messages, _keep, _opts), do: 0

  # --- turn / positional boundary -------------------------------------------

  defp turn_boundary(tuple, count, keep) do
    turns =
      tuple
      |> tuple_messages()
      |> Enum.reject(&synthetic?/1)
      |> Enum.map(&turn_of/1)
      |> Enum.reject(&is_nil/1)

    case turns do
      [] ->
        count

      turns ->
        cutoff = Enum.max(turns) - keep
        find_first_recent(tuple, 0, count, cutoff)
    end
  end

  defp find_first_recent(_tuple, index, count, _cutoff) when index >= count, do: count

  defp find_first_recent(tuple, index, count, cutoff) do
    message = elem(tuple, index)

    cond do
      synthetic?(message) -> find_first_recent(tuple, index + 1, count, cutoff)
      turn_after?(turn_of(message), cutoff) -> index
      true -> find_first_recent(tuple, index + 1, count, cutoff)
    end
  end

  defp turn_after?(turn, cutoff) when is_integer(turn), do: turn > cutoff
  defp turn_after?(_turn, _cutoff), do: false

  # --- tail size budget (O(n), index only ever increases) -------------------

  defp fit_budget(tuple, base, budget) do
    count = tuple_size(tuple)

    cond do
      base >= count -> base
      tokens_for(suffix_chars(tuple, base, count, 0)) <= budget -> base
      true -> shrink_to_budget(tuple, base, count, suffix_chars(tuple, base, count, 0), budget)
    end
  end

  defp shrink_to_budget(tuple, index, count, chars, budget) do
    cond do
      index >= count - 1 ->
        count - 1

      tokens_for(chars) <= budget ->
        index

      true ->
        shrink_to_budget(
          tuple,
          index + 1,
          count,
          chars - message_chars(elem(tuple, index)),
          budget
        )
    end
  end

  defp suffix_chars(_tuple, index, count, acc) when index >= count, do: acc

  defp suffix_chars(tuple, index, count, acc) do
    suffix_chars(tuple, index + 1, count, acc + message_chars(elem(tuple, index)))
  end

  # --- tool-result pairing ---------------------------------------------------

  # A boundary that lands on a `:tool` result is rewound onto the producing
  # assistant message, so the protected suffix never starts with an orphaned
  # tool result. The walk crosses the whole run of `:tool` messages and never
  # drops below the first message.
  defp rewind_off_tool(index, tuple) when index > 0 and index < tuple_size(tuple) do
    case elem(tuple, index) do
      %Message{role: :tool} -> rewind_off_tool(index - 1, tuple)
      _message -> index
    end
  end

  defp rewind_off_tool(index, _tuple), do: index

  # --- message accounting ----------------------------------------------------

  defp tokens_for(chars), do: div(chars + 3, 4)

  defp tuple_messages(tuple), do: Tuple.to_list(tuple)

  defp message_chars(%Message{content: content}), do: content_chars(content)
  defp message_chars(%{content: content}), do: content_chars(content)
  defp message_chars(_message), do: 0

  defp content_chars(content) when is_binary(content), do: byte_size(content)

  defp content_chars(content) when is_list(content) do
    Enum.reduce(content, 0, fn part, total -> total + part_chars(part) end)
  end

  defp content_chars(_content), do: 0

  defp part_chars(%ReqLLM.Message.ContentPart{type: :text, text: text}), do: text_bytes(text)
  defp part_chars(%ReqLLM.Message.ContentPart{type: :thinking, text: text}), do: text_bytes(text)
  defp part_chars(%ReqLLM.Message.ContentPart{} = part), do: payload_bytes(part)
  defp part_chars(part) when is_binary(part), do: byte_size(part)
  defp part_chars(_part), do: 0

  defp text_bytes(text) when is_binary(text), do: byte_size(text)
  defp text_bytes(_text), do: 0

  defp payload_bytes(part) do
    cond do
      is_binary(part.data) -> byte_size(part.data)
      is_binary(part.url) -> byte_size(part.url)
      is_binary(part.file_id) -> byte_size(part.file_id)
      true -> 0
    end
  end

  defp text_of(%Message{content: content}), do: content_text(content)

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %ReqLLM.Message.ContentPart{type: :text, text: text} when is_binary(text) -> text
      _part -> ""
    end)
    |> Enum.join("\n")
  end

  defp content_text(_content), do: ""
end
