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

  ## Moving the boundary cannot shrink an oversized message

  The index-only rule above has one blind spot: when the MINIMAL contiguous
  pairing-safe trailing exchange (one huge tool result, one huge assistant
  message) is itself larger than the budget, no index can make it fit — the
  suffix would either stay over budget or be dropped whole, and compression
  would retrigger immediately. `shrink_to_budget/2` closes that gap: it
  truncates the oversize TEXT content head-heavily (role, metadata,
  `tool_calls`/`tool_call_id` and every non-text part preserved) and only drops
  whole leading exchanges as a last resort, so the returned list always lands
  at or under the budget whenever that is reachable.
  """

  alias ReqLLM.Message

  alias EvoGit.Agent.Compression.SummaryPrompt

  @default_keep_recent_turns 4
  @default_tail_budget_fraction 0.2
  @default_tail_budget_tokens 40_000

  # Per-message token allowance floor: below it a single message is truncated to
  # something meaningful instead of being dropped for a handful of tokens.
  @min_message_allowance 1_000

  # Head-heavy split of the retained text (the tail is where errors, totals and
  # summaries sit, but the beginning carries the file/command identity).
  @truncation_head_share 0.75

  # Budgeted worst-case size of the truncation marker (`"\n… [truncated N
  # characters] …\n"`), so head + marker + tail stays inside the allowance.
  @truncation_marker_reserve 40

  # Present in the marker of every truncated text part — the detection anchor of
  # `truncated?/1`.
  @truncation_tag "[truncated "

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
  Shrinks `messages` down to `budget` tokens, KEEPING every message (and its
  pairing) when truncation alone suffices.

  Returns `%{messages: messages, truncated: n, estimated_tokens: t}` where
  `truncated` counts the messages whose content was truncated and
  `estimated_tokens` is the estimate of the RETURNED list.

  The policy, in order:

    1. a list already at or under the budget (or an empty/unusable one) is
       returned unchanged with `truncated: 0`;
    2. every message whose own estimate exceeds the per-message allowance
       (`max(div(budget, message_count), 1_000)` tokens) gets its `:text`
       content truncated head-heavily (about 75% head / 25% tail of
       `4 * allowance` characters) around a visible
       `"\\n… [truncated N characters] …\\n"` marker — role, metadata,
       `tool_calls`, `tool_call_id` and every non-text part (`:thinking`,
       `:provider_block`, media) survive untouched, in their original order, and
       a message is never grown;
    3. if the list is STILL over budget (too many messages), whole leading
       exchanges are dropped until it fits or the list is empty — an assistant
       message carrying `tool_calls` goes together with its following `:tool`
       results, so the result never STARTS with an orphaned tool result and
       never holds a `tool_calls` without its results.

  ## Options

    * `:budget` — an explicit token budget; a positive integer wins
    * `:context_window`, `:tail_budget_fraction`, `:tail_budget_tokens` — the
      fallback budget, resolved by `tail_budget/1`

  Unusable values fall back to `tail_budget/1`. Pure and total — never raises,
  never mutates a message that is not over its allowance.
  """
  @spec shrink_to_budget(term(), keyword()) :: %{
          messages: term(),
          truncated: non_neg_integer(),
          estimated_tokens: non_neg_integer()
        }
  def shrink_to_budget(messages, opts \\ [])

  def shrink_to_budget(messages, opts) when is_list(messages) do
    budget = budget_from(opts)
    estimated = estimate_tokens(messages)

    if messages == [] or estimated <= budget do
      %{messages: messages, truncated: 0, estimated_tokens: estimated}
    else
      allowance = max(div(budget, length(messages)), @min_message_allowance)
      {truncated_messages, truncated} = truncate_all(messages, allowance)
      kept = drop_to_budget(truncated_messages, budget)

      %{messages: kept, truncated: truncated, estimated_tokens: estimate_tokens(kept)}
    end
  end

  def shrink_to_budget(messages, _opts) do
    %{messages: messages, truncated: 0, estimated_tokens: estimate_tokens(messages)}
  end

  @doc """
  True when a message carries a truncation marker — i.e. `shrink_to_budget/2`
  shortened its text content. Total over any term — never raises.
  """
  @spec truncated?(term()) :: boolean()
  def truncated?(%Message{content: content}) when is_binary(content),
    do: String.contains?(content, @truncation_tag)

  def truncated?(%Message{content: content}) when is_list(content) do
    Enum.any?(content, fn
      %ReqLLM.Message.ContentPart{type: :text, text: text} when is_binary(text) ->
        String.contains?(text, @truncation_tag)

      _part ->
        false
    end)
  end

  def truncated?(_message), do: false

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
      true -> advance_past_budget(tuple, base, count, suffix_chars(tuple, base, count, 0), budget)
    end
  end

  defp advance_past_budget(tuple, index, count, chars, budget) do
    cond do
      index >= count - 1 ->
        count - 1

      tokens_for(chars) <= budget ->
        index

      true ->
        advance_past_budget(
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

  # --- truncating an oversized tail down to the budget ----------------------

  defp budget_from(opts) when is_list(opts) do
    case Keyword.get(opts, :budget) do
      budget when is_integer(budget) and budget > 0 ->
        budget

      _unusable ->
        tail_budget(
          Keyword.take(opts, [:context_window, :tail_budget_fraction, :tail_budget_tokens])
        )
    end
  end

  defp budget_from(_opts), do: tail_budget([])

  defp truncate_all(messages, allowance) do
    {reversed, truncated} =
      Enum.reduce(messages, {[], 0}, fn message, {acc, count} ->
        case truncate_message(message, allowance) do
          {:truncated, truncated_message} -> {[truncated_message | acc], count + 1}
          :unchanged -> {[message | acc], count}
        end
      end)

    {Enum.reverse(reversed), truncated}
  end

  # Only a message whose OWN estimate exceeds the allowance is touched: a small
  # message keeps its bytes byte-identically.
  defp truncate_message(message, allowance) do
    if tokens_for(message_chars(message)) > allowance do
      truncate_content(message, allowance)
    else
      :unchanged
    end
  end

  defp truncate_content(%Message{content: content} = message, allowance) when is_list(content) do
    case truncate_parts(content, allowance) do
      {_parts, 0} -> :unchanged
      {parts, _truncated} -> {:truncated, %{message | content: parts}}
    end
  end

  # Legacy shape: a binary `content` is one text part, rebuilt as a proper
  # (valid) content-part list only when it actually shrinks.
  defp truncate_content(%Message{content: content} = message, allowance)
       when is_binary(content) do
    case truncate_text(content, 4 * allowance) do
      {:truncated, text} ->
        {:truncated, %{message | content: [ReqLLM.Message.ContentPart.text(text)]}}

      :unchanged ->
        :unchanged
    end
  end

  defp truncate_content(_message, _allowance), do: :unchanged

  # The message's `:text` parts SHARE one allowance of `4 * allowance`
  # characters, split proportionally by size, so a message with several text
  # parts lands at the same total as one with a single part. Non-text parts
  # (`:thinking`, `:provider_block`, media) are never touched.
  defp truncate_parts(parts, allowance) do
    target_chars = 4 * allowance
    sizes = Enum.map(parts, &part_text_bytes/1)
    total = Enum.sum(sizes)
    text_parts = Enum.count(sizes, &(&1 > 0))

    if total <= target_chars or text_parts == 0 do
      {parts, 0}
    else
      retained = max(target_chars - text_parts * @truncation_marker_reserve, text_parts)

      parts
      |> Enum.zip(sizes)
      |> Enum.map_reduce(0, fn {part, size}, truncated ->
        share =
          if text_parts == 1 do
            retained
          else
            max(div(size * retained, total), @truncation_marker_reserve)
          end

        case truncate_part(part, share) do
          {:truncated, truncated_part} -> {truncated_part, truncated + 1}
          :unchanged -> {part, truncated}
        end
      end)
    end
  end

  defp truncate_part(%ReqLLM.Message.ContentPart{type: :text, text: text} = part, allowed)
       when is_binary(text) do
    case truncate_text(text, allowed) do
      {:truncated, truncated_text} -> {:truncated, %{part | text: truncated_text}}
      :unchanged -> :unchanged
    end
  end

  defp truncate_part(_part, _allowed), do: :unchanged

  # Head-heavy rewrite around a visible marker. `String.byte_slice/3` keeps the
  # byte budget while refusing to cut a multi-byte codepoint in half, so the
  # truncated text can always be JSON-encoded and replayed to a provider.
  defp truncate_text(text, allowed)
       when is_binary(text) and is_integer(allowed) and allowed > 0 do
    if byte_size(text) <= allowed do
      :unchanged
    else
      keep = max(allowed - @truncation_marker_reserve, 1)
      head_chars = round(keep * @truncation_head_share)
      tail_chars = max(keep - head_chars, 0)

      head = String.byte_slice(text, 0, head_chars)
      tail = if tail_chars > 0, do: String.byte_slice(text, -tail_chars, tail_chars), else: ""

      removed = byte_size(text) - byte_size(head) - byte_size(tail)
      truncated = head <> truncation_marker(removed) <> tail

      # Never grow: a multi-byte text can lose fewer bytes than budgeted, in
      # which case there is nothing to gain and the part is left alone.
      if byte_size(truncated) < byte_size(text), do: {:truncated, truncated}, else: :unchanged
    end
  end

  defp truncate_text(_text, _allowed), do: :unchanged

  defp truncation_marker(removed), do: "\n… #{@truncation_tag}#{removed} characters] …\n"

  defp part_text_bytes(%ReqLLM.Message.ContentPart{type: :text, text: text})
       when is_binary(text),
       do: byte_size(text)

  defp part_text_bytes(_part), do: 0

  # Last resort: whole leading exchanges go until the list fits. Dropping an
  # assistant message that carries `tool_calls` also drops the `:tool` results
  # directly after it, so the list never STARTS on an orphaned tool result and
  # never holds a `tool_calls` without its results.
  defp drop_to_budget([], _budget), do: []

  defp drop_to_budget(messages, budget) do
    if estimate_tokens(messages) <= budget do
      messages
    else
      drop_to_budget(drop_leading(messages), budget)
    end
  end

  defp drop_leading([_first | rest]), do: Enum.drop_while(rest, &tool_message?/1)

  defp tool_message?(%Message{role: :tool}), do: true
  defp tool_message?(_message), do: false

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
