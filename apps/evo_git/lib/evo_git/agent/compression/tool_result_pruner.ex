defmodule EvoGit.Agent.Compression.ToolResultPruner do
  @moduledoc """
  Compression STAGE 1 — the model-free, purely mechanical tool-result pruner.

  ## Why this exists (DeepSeek-Harness economics)

  The bulk of a long agent transcript is RAW TOOL OUTPUT — build logs, `rg`
  dumps, file reads, test output — and most of it is never needed again once the
  agent has drawn its conclusion from it. Shrinking that output costs one cheap
  pass over the message list and **no LLM call at all**, so it is always worth
  trying BEFORE paying for a summarising checkpoint
  (`EvoGit.Agent.Compression.Checkpoint`). Whatever context pressure remains
  after this stage is what the checkpoint is asked to relieve.

  ## What it touches

  Only `:tool` messages OLDER than the recency boundary
  (`EvoGit.Agent.Compression.Recency.boundary/2`) are candidates: the last K
  turns of work (default
  `EvoGit.Agent.Compression.Recency.default_keep_recent_turns/0`) are never
  touched. The system prompt, the first user message (objective + context
  tree), every `:user` and `:assistant` message, and every `:thinking` /
  `:provider_block` part inside a candidate all pass through byte-identically.

  Inside a candidate `:tool` message:

    * a `:text` part longer than `:threshold_chars` (default 8 KiB) keeps its
      first `:head_chars` bytes (default 4 KiB), the exact marker
      `"\\n\\n[... tool result middle pruned ...]\\n\\n"`, and its last
      `:tail_chars` bytes (default 1 KiB) — the tail is where errors, totals and
      summaries usually sit;
    * media parts (`:image`, `:image_url`, `:video_url`, `:file`) are dropped and
      replaced by ONE text placeholder per message naming the omission and how
      many parts were removed, so raw base64 never survives in the context
      (base64 is both enormous and useless to a model that has already read the
      tool's textual answer).

  ## Invariants

    * the message LIST is never shortened and never reordered, and every
      `tool_call_id` / `tool_calls` field is untouched — an assistant
      `tool_calls` entry can never lose its paired tool result;
    * pruning never grows a message: when head + marker + tail would not be
      strictly smaller than the original text (only reachable with pathological
      `:head_chars` / `:tail_chars` overrides) the part is left alone, so
      `chars_after <= chars_before` always holds;
    * a no-op call returns the SAME list (struct equality) with `pruned: 0` and
      `chars_before == chars_after`;
    * no I/O, no processes, no clock, no configuration lookup, no LLM call and no
      `try`/`rescue` — the module is a pure function of its arguments, so it is
      safe to call on every turn.

  ## Options

    * `:keep_recent_turns` — turns protected at the end of the conversation
      (default `Recency.default_keep_recent_turns/0`)
    * `:threshold_chars` — a `:text` part must exceed this many bytes to be
      pruned (default 8192)
    * `:head_chars` — bytes kept from the start of a pruned text part
      (default 4096)
    * `:tail_chars` — bytes kept from the end of a pruned text part
      (default 1024)
  """

  alias EvoGit.Agent.Compression.Recency
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @default_threshold_chars 8_192
  @default_head_chars 4_096
  @default_tail_chars 1_024

  @marker "\n\n[... tool result middle pruned ...]\n\n"

  # Media payload carriers: their bytes are what the placeholder replaces.
  @media_types [:image, :image_url, :video_url, :file]

  @type result :: %{
          messages: [Message.t()],
          pruned: non_neg_integer(),
          chars_before: non_neg_integer(),
          chars_after: non_neg_integer()
        }

  @doc """
  Prunes old tool results in `messages`.

  Returns the rebuilt message list together with the number of messages actually
  changed and the character counts before/after, so the caller can log the
  saving and (`EvoGit.Agent.Compression.Threshold.project/3`) carry the same
  ratio over to the reported token count.
  """
  @spec prune([Message.t()], keyword()) :: result()
  def prune(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    policy = policy(opts)
    boundary = Recency.boundary(messages, policy.keep_recent_turns)
    chars_before = char_count(messages)

    {pruned_messages, pruned} = prune_all(messages, boundary, policy)

    %{
      messages: pruned_messages,
      pruned: pruned,
      chars_before: chars_before,
      chars_after: char_count(pruned_messages)
    }
  end

  @doc """
  Total size in characters of a message list.

  `:text` and `:thinking` parts contribute `byte_size(text)`; media parts
  contribute the byte size of their payload (`data`, else `url`, else
  `file_id`, else 0); anything unrecognized contributes 0. A legacy binary
  `content` counts as its own byte size. Total — never raises.
  """
  @spec char_count([Message.t()] | term()) :: non_neg_integer()
  def char_count(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn message, total -> total + message_chars(message) end)
  end

  def char_count(_messages), do: 0

  ## Pruning

  defp prune_all(messages, boundary, policy) do
    {rebuilt, pruned} =
      messages
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {message, index}, count ->
        case prune_message(message, index, boundary, policy) do
          {:ok, pruned_message} -> {pruned_message, count + 1}
          :keep -> {message, count}
        end
      end)

    {rebuilt, pruned}
  end

  # Only an OLD `:tool` message is a candidate: role and recency are checked
  # together so no other message kind can ever be reached by the pruners below.
  defp prune_message(%Message{role: :tool} = message, index, boundary, policy)
       when index < boundary do
    case prune_content(message.content, policy) do
      {:ok, content} -> {:ok, %{message | content: content}}
      :keep -> :keep
    end
  end

  defp prune_message(_message, _index, _boundary, _policy), do: :keep

  # Legacy shape: a binary `content` -- treated as one text part, and rebuilt as
  # a proper (valid) content-part list only when it actually shrinks.
  defp prune_content(content, policy) when is_binary(content) do
    case prune_text(content, policy) do
      {:ok, text} -> {:ok, [ContentPart.text(text)]}
      :keep -> :keep
    end
  end

  defp prune_content(content, policy) when is_list(content) do
    media_parts = Enum.count(content, &media_part?/1)

    state =
      Enum.reduce(content, %{parts: [], changed?: false, placeholder?: false}, fn part, state ->
        if media_part?(part) do
          # ONE placeholder per message, emitted where the first media part was.
          if state.placeholder? do
            %{state | changed?: true}
          else
            placeholder = ContentPart.text(media_placeholder(media_parts))

            %{state | parts: [placeholder | state.parts], changed?: true, placeholder?: true}
          end
        else
          case prune_part(part, policy) do
            {:ok, pruned_part} -> %{state | parts: [pruned_part | state.parts], changed?: true}
            :keep -> %{state | parts: [part | state.parts]}
          end
        end
      end)

    if state.changed?, do: {:ok, Enum.reverse(state.parts)}, else: :keep
  end

  defp prune_content(_content, _policy), do: :keep

  defp prune_part(%ContentPart{type: :text, text: text} = part, policy) when is_binary(text) do
    case prune_text(text, policy) do
      {:ok, pruned_text} -> {:ok, %{part | text: pruned_text}}
      :keep -> :keep
    end
  end

  # `:thinking` / `:provider_block` / anything unknown: preserved verbatim.
  defp prune_part(_part, _policy), do: :keep

  defp prune_text(text, policy) when is_binary(text) do
    if byte_size(text) > policy.threshold_chars do
      rebuilt = head_and_tail(text, policy)

      # Never grow: with pathological head/tail overrides the rewrite could be
      # larger than the original, in which case there is nothing to gain.
      if byte_size(rebuilt) < byte_size(text), do: {:ok, rebuilt}, else: :keep
    else
      :keep
    end
  end

  # `String.byte_slice/3` keeps the exact byte budget while refusing to cut a
  # multi-byte UTF-8 codepoint in half, so the pruned text can always be
  # JSON-encoded and replayed to a provider.
  defp head_and_tail(text, policy) do
    String.byte_slice(text, 0, policy.head_chars) <>
      @marker <> String.byte_slice(text, -policy.tail_chars, policy.tail_chars)
  end

  defp media_part?(%ContentPart{type: type}) when type in @media_types, do: true
  defp media_part?(_part), do: false

  defp media_placeholder(media_parts) do
    "[... tool result media omitted to keep the context small: " <>
      "#{media_parts} attachment part(s) ...]"
  end

  ## Character accounting

  defp message_chars(%Message{content: content}), do: content_chars(content)
  defp message_chars(%{content: content}), do: content_chars(content)
  defp message_chars(_message), do: 0

  defp content_chars(content) when is_binary(content), do: byte_size(content)

  defp content_chars(content) when is_list(content) do
    Enum.reduce(content, 0, fn part, total -> total + part_chars(part) end)
  end

  defp content_chars(_content), do: 0

  defp part_chars(%ContentPart{type: :text, text: text}), do: text_bytes(text)
  defp part_chars(%ContentPart{type: :thinking, text: text}), do: text_bytes(text)
  defp part_chars(%ContentPart{} = part), do: payload_bytes(part)
  defp part_chars(text) when is_binary(text), do: byte_size(text)
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

  ## Options

  defp policy(opts) do
    %{
      keep_recent_turns:
        positive_opt(opts, :keep_recent_turns, Recency.default_keep_recent_turns()),
      threshold_chars: non_negative_opt(opts, :threshold_chars, @default_threshold_chars),
      head_chars: non_negative_opt(opts, :head_chars, @default_head_chars),
      tail_chars: non_negative_opt(opts, :tail_chars, @default_tail_chars)
    }
  end

  # `Recency.boundary/2` requires a positive window; an unusable override falls
  # back to the default rather than raising inside a per-turn code path.
  defp positive_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp non_negative_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end
end
