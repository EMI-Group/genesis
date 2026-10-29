defmodule EvoGit.Agent.Compression.ToolResultPrunerTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Compression.{Recency, ToolResultPruner}
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @marker "\n\n[... tool result middle pruned ...]\n\n"
  @head_chars 4_096
  @tail_chars 1_024

  defp tag(message, turn) do
    %{message | metadata: Map.put(message.metadata || %{}, :turn, turn)}
  end

  # Head, middle and tail use distinct letters so a test can prove the MIDDLE is
  # the part that disappeared.
  defp head_middle_tail do
    String.duplicate("H", 5_000) <>
      String.duplicate("M", 20_000) <> String.duplicate("T", 3_000)
  end

  defp assistant_with_call(turn) do
    Context.assistant("working on #{turn}",
      tool_calls: [ReqLLM.ToolCall.new("call_#{turn}", "run_bash", "{}")]
    )
    |> tag(turn)
  end

  defp tool_result(turn, text) do
    Context.tool_result("call_#{turn}", "run_bash", text) |> tag(turn)
  end

  # 20 messages: system + objective + 9 (assistant, tool result) pairs, turns
  # 1..9. With the default 4-turn window the boundary is index 12, so the tool
  # results at indices 3, 5, 7, 9, 11 are "old" and 13, 15, 17, 19 are recent.
  defp conversation(tool_text) do
    conversation_with(fn turn -> tool_result(turn, tool_text.(turn)) end)
  end

  # The same 20-message shape, with the tool result of each turn supplied by the
  # caller — the fixture a media test needs so the interesting message sits in
  # the OLD region (turn 1, index 3) while every tool result keeps its producing
  # assistant `tool_calls`.
  defp conversation_with(tool_result_fun) do
    turns =
      Enum.flat_map(1..9, fn turn ->
        [assistant_with_call(turn), tool_result_fun.(turn)]
      end)

    [
      tag(Context.system("system prompt"), 0),
      tag(Context.user("<objective>do it</objective>"), 0) | turns
    ]
  end

  # A conversation whose turn-1 tool result carries `parts` (so it is OLD and a
  # pruning candidate) and whose remaining results are short and unprunable.
  defp media_conversation(parts) do
    conversation_with(fn
      1 -> Context.tool_result("call_1", "read_file", parts) |> tag(1)
      turn -> tool_result(turn, "short output #{turn}")
    end)
  end

  defp text_parts(message) do
    message.content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map(& &1.text)
  end

  describe "prune/2 text handling" do
    test "(a) a tool result at or below the threshold is left byte-identical" do
      messages = conversation(fn turn -> "short output #{turn}" end)

      result = ToolResultPruner.prune(messages)

      assert result.pruned == 0
      assert result.messages == messages
      assert Enum.at(result.messages, 3) == Enum.at(messages, 3)
    end

    test "(b) a long tool result keeps head + marker + tail with exact byte sizes" do
      original = head_middle_tail()
      messages = conversation(fn _turn -> original end)

      result = ToolResultPruner.prune(messages)
      pruned_message = Enum.at(result.messages, 3)
      pruned_text = pruned_message |> text_parts() |> hd()

      assert pruned_text ==
               String.byte_slice(original, 0, @head_chars) <>
                 @marker <> String.byte_slice(original, -@tail_chars, @tail_chars)

      assert byte_size(pruned_text) == @head_chars + byte_size(@marker) + @tail_chars
      assert byte_size(pruned_text) == 5_159
      assert String.starts_with?(pruned_text, String.duplicate("H", @head_chars))
      assert String.ends_with?(pruned_text, String.duplicate("T", @tail_chars))
      assert String.contains?(pruned_text, @marker)

      # The 20_000-byte middle is gone entirely.
      refute String.contains?(pruned_text, "M")
    end

    test "(c) a huge tool result inside the last K turns is never pruned" do
      messages = conversation(fn _turn -> head_middle_tail() end)

      assert Recency.boundary(messages, Recency.default_keep_recent_turns()) == 12

      result = ToolResultPruner.prune(messages)

      Enum.each([13, 15, 17, 19], fn index ->
        assert Enum.at(result.messages, index) == Enum.at(messages, index),
               "recent tool result at index #{index} was modified"
      end)

      assert result.pruned == 5
    end

    test "(d) huge system, user and assistant messages are never pruned" do
      huge = String.duplicate("X", 50_000)

      messages =
        [tag(Context.system(huge), 0), tag(Context.user(huge), 0)] ++
          Enum.flat_map(1..9, fn turn ->
            [
              assistant_with_call(turn) |> Map.put(:content, [ContentPart.text(huge)]),
              tool_result(turn, huge)
            ]
          end)

      result = ToolResultPruner.prune(messages)

      # The tail BUDGET now shrinks the protected suffix (8 huge messages are
      # ~100k tokens against a 40k budget), so the boundary lands later than the
      # 12 the turn/positional rule alone yields — hidden here as index 16,
      # rewound off the `:tool` result at 17.
      boundary = Recency.boundary(messages)
      assert boundary == 16
      assert Recency.tail_budget() == 40_000

      # Every non-`:tool` message is byte-identical, whatever the boundary.
      messages
      |> Enum.with_index()
      |> Enum.each(fn {message, index} ->
        if message.role != :tool do
          assert Enum.at(result.messages, index) == message,
                 "non-tool message at index #{index} was modified"
        end
      end)

      # Only the OLD tool results are candidates.
      assert result.pruned == 7
      assert Enum.at(result.messages, 0) == Enum.at(messages, 0)
      assert Enum.at(result.messages, 1) == Enum.at(messages, 1)
      assert Enum.at(result.messages, 2) == Enum.at(messages, 2)

      Enum.each([17, 19], fn index ->
        assert Enum.at(result.messages, index) == Enum.at(messages, index),
               "recent tool result at index #{index} was modified"
      end)
    end
  end

  describe "prune/2 media handling" do
    test "(e) a tool result carrying an image loses the payload and gains one placeholder" do
      image_payload = String.duplicate("z", 5_000)

      messages =
        media_conversation([
          ContentPart.text("see attached"),
          ContentPart.image(image_payload, "image/png"),
          ContentPart.thinking("deep thought"),
          ContentPart.text("done")
        ])

      result = ToolResultPruner.prune(messages)
      # The media result sits in the OLD region (index 3) …
      assert hd(messages).role == :system
      assert Enum.at(messages, 3).role == :tool
      assert Enum.at(result.messages, 2) == Enum.at(messages, 2)

      pruned_message = Enum.at(result.messages, 3)

      assert result.pruned == 1
      assert Enum.map(pruned_message.content, & &1.type) == [:text, :text, :thinking, :text]

      placeholder = Enum.at(pruned_message.content, 1).text
      assert placeholder =~ "media omitted"
      assert placeholder =~ "1 attachment part(s)"

      # No raw payload survives anywhere in the message.
      assert Enum.all?(pruned_message.content, &is_nil(&1.data))
      refute String.contains?(inspect(pruned_message), String.duplicate("z", 100))

      # Order of the surviving parts is preserved and thinking is byte-identical.
      assert Enum.at(pruned_message.content, 0).text == "see attached"
      assert Enum.at(pruned_message.content, 2).text == "deep thought"
      assert Enum.at(pruned_message.content, 3).text == "done"
      assert pruned_message.tool_call_id == "call_1"
    end

    test "(e) several media parts collapse into one placeholder naming the count" do
      messages =
        media_conversation([
          ContentPart.image("aaaa", "image/png"),
          ContentPart.image_url("http://example.test/y.png"),
          ContentPart.text("tail")
        ])

      result = ToolResultPruner.prune(messages)
      pruned_message = Enum.at(result.messages, 3)

      assert result.pruned == 1
      assert Enum.map(pruned_message.content, & &1.type) == [:text, :text]
      assert hd(pruned_message.content).text =~ "2 attachment part(s)"
      assert List.last(pruned_message.content).text == "tail"
    end

    test "(e) media inside the recent window survives untouched" do
      messages =
        media_conversation([
          ContentPart.image(String.duplicate("z", 5_000), "image/png")
        ])

      result = ToolResultPruner.prune(messages, keep_recent_turns: 12)

      assert result.pruned == 0
      assert Enum.at(result.messages, 3) == Enum.at(messages, 3)
    end

    test "(e) a message with BOTH oversized text and media gets both treatments" do
      messages =
        media_conversation([
          ContentPart.text(head_middle_tail()),
          ContentPart.image(String.duplicate("q", 1_000), "image/png")
        ])

      result = ToolResultPruner.prune(messages)
      pruned_message = Enum.at(result.messages, 3)

      assert result.pruned == 1
      assert Enum.map(pruned_message.content, & &1.type) == [:text, :text]
      assert Enum.at(pruned_message.content, 0).text =~ @marker

      assert byte_size(Enum.at(pruned_message.content, 0).text) ==
               @head_chars + byte_size(@marker) + @tail_chars

      refute String.contains?(inspect(pruned_message), String.duplicate("q", 100))
    end
  end

  describe "prune/2 accounting" do
    test "(f) pruned / chars_before / chars_after are accurate" do
      original = head_middle_tail()
      messages = conversation(fn _turn -> original end)

      result = ToolResultPruner.prune(messages)

      assert result.pruned == 5
      assert result.chars_before == ToolResultPruner.char_count(messages)
      assert result.chars_after == ToolResultPruner.char_count(result.messages)
      assert result.chars_before == Enum.sum(Enum.map(messages, &byte_size_of/1))
      assert result.chars_after < result.chars_before

      # Five identically sized tool results each shrink by the same delta.
      saved_per_message = byte_size(original) - (@head_chars + byte_size(@marker) + @tail_chars)
      assert result.chars_before - result.chars_after == 5 * saved_per_message
    end

    test "(i) a no-op run returns the input list unchanged" do
      messages = conversation(fn turn -> "short output #{turn}" end)

      result = ToolResultPruner.prune(messages)

      assert result.messages == messages
      assert result.pruned == 0
      assert result.chars_before == result.chars_after
    end
  end

  describe "prune/2 pairing safety" do
    test "(g) message count, order and tool-call pairing survive pruning" do
      messages = conversation(fn _turn -> head_middle_tail() end)

      result = ToolResultPruner.prune(messages)

      assert length(result.messages) == length(messages)
      assert Enum.map(result.messages, & &1.role) == Enum.map(messages, & &1.role)

      tool_ids =
        result.messages |> Enum.filter(&(&1.role == :tool)) |> Enum.map(& &1.tool_call_id)

      assert tool_ids == Enum.map(1..9, &"call_#{&1}")

      assistant_ids =
        result.messages
        |> Enum.filter(&(&1.role == :assistant))
        |> Enum.flat_map(& &1.tool_calls)
        |> Enum.map(& &1.id)

      assert assistant_ids == tool_ids
      assert Enum.all?(result.messages, &Message.valid?/1)
    end
  end

  describe "prune/2 option overrides" do
    test "(h) keep_recent_turns widens the prunable region" do
      messages = conversation(fn _turn -> head_middle_tail() end)

      result = ToolResultPruner.prune(messages, keep_recent_turns: 1)

      assert result.pruned == 8
      assert Enum.at(result.messages, 19) == Enum.at(messages, 19)
    end

    test "(h) threshold_chars / head_chars / tail_chars override the defaults" do
      small = [
        tag(Context.system("s"), 0),
        assistant_with_call(1),
        tool_result(1, "0123456789" <> String.duplicate("x", 90)),
        assistant_with_call(2),
        tool_result(2, "0123456789" <> String.duplicate("y", 90))
      ]

      result =
        ToolResultPruner.prune(small,
          threshold_chars: 20,
          head_chars: 5,
          tail_chars: 5,
          keep_recent_turns: 1
        )

      assert result.pruned == 1
      assert Enum.at(result.messages, 2) |> text_parts() |> hd() == "01234" <> @marker <> "xxxxx"
      assert Enum.at(result.messages, 4) == Enum.at(small, 4)
    end

    test "(h) an unusable keep_recent_turns falls back to the default instead of raising" do
      messages = conversation(fn _turn -> head_middle_tail() end)

      assert ToolResultPruner.prune(messages, keep_recent_turns: 0).pruned == 5
      assert ToolResultPruner.prune(messages, keep_recent_turns: :nope).pruned == 5
    end
  end

  describe "prune/2 tail budget" do
    test "(j) a smaller :context_window shrinks the protected tail and prunes more" do
      messages = conversation(fn _turn -> head_middle_tail() end)

      # The default window (200_000 → a 40_000-token budget, capped) leaves the
      # four-turn tail intact: boundary 12, five old tool results.
      assert Recency.tail_budget() == 40_000
      assert Recency.boundary(messages) == 12
      assert ToolResultPruner.prune(messages).pruned == 5

      # A tiny window's 1_600-token budget cannot hold the four huge recent tool
      # results, so the boundary moves later and MORE old results are candidates.
      assert Recency.tail_budget(context_window: 8_000) == 1_600

      result = ToolResultPruner.prune(messages, context_window: 8_000)

      assert result.pruned == 8
      assert result.pruned > ToolResultPruner.prune(messages).pruned

      # The budget may only shrink the suffix: the retained region still ends at
      # the last message and the boundary never orphans a tool result.
      boundary =
        Recency.boundary(messages, Recency.default_keep_recent_turns(), context_window: 8_000)

      assert boundary > 12

      Enum.each(boundary..(length(messages) - 1), fn index ->
        assert Enum.at(result.messages, index) == Enum.at(messages, index),
               "tool result at index #{index} (>= boundary #{boundary}) was modified"
      end)

      assert List.last(result.messages) == List.last(messages)
      assert Enum.all?(result.messages, &Message.valid?/1)
    end

    test "(j) a LARGER :context_window keeps the default behaviour" do
      messages = conversation(fn _turn -> head_middle_tail() end)

      # 0.2 * 1_000_000 is 200_000 tokens, so the fixed 40_000 cap governs and the
      # budget is identical to the default.
      assert Recency.tail_budget(context_window: 1_000_000) == Recency.tail_budget()
      assert ToolResultPruner.prune(messages, context_window: 1_000_000).pruned == 5
    end

    test "(j) a pathological window never raises and falls back to the default" do
      messages = conversation(fn _turn -> head_middle_tail() end)

      for window <- [0, -1, -100_000, :nope, "8000", 1.5, nil] do
        assert ToolResultPruner.prune(messages, context_window: window).pruned == 5,
               "unexpected pruning for context_window: #{inspect(window)}"

        assert Recency.tail_budget(context_window: window) == Recency.tail_budget()
      end
    end

    test "(j) an explicit :tail_budget_tokens / :tail_budget_fraction override the window" do
      messages = conversation(fn _turn -> head_middle_tail() end)

      # A 1-token cap leaves only the last message protected — every old tool
      # result is then a candidate EXCEPT the ones the rewind keeps.
      assert ToolResultPruner.prune(messages, tail_budget_tokens: 1).pruned == 8

      # A fraction big enough for the whole tail restores the default boundary.
      assert ToolResultPruner.prune(messages, tail_budget_fraction: 0.9).pruned == 5
    end
  end

  describe "legacy and defensive shapes" do
    test "a binary content is treated as one text part and rebuilt as a valid list" do
      legacy =
        %Message{role: :tool, tool_call_id: "legacy", content: head_middle_tail()} |> tag(1)

      messages = [
        tag(Context.system("s"), 0),
        tag(Context.user("u"), 0),
        legacy,
        tag(Context.assistant("a"), 1),
        tag(Context.user("u2"), 2),
        tag(Context.assistant("a2"), 3),
        tag(Context.user("u3"), 4)
      ]

      result = ToolResultPruner.prune(messages, keep_recent_turns: 1)
      rebuilt = Enum.at(result.messages, 2)

      assert result.pruned == 1
      assert is_list(rebuilt.content)
      assert length(rebuilt.content) == 1
      assert hd(rebuilt.content).text =~ @marker
      assert rebuilt.tool_call_id == "legacy"
    end

    test "char_count/1 counts text, thinking and media payloads" do
      assert ToolResultPruner.char_count([]) == 0
      assert ToolResultPruner.char_count([tag(Context.user("abcd"), 0)]) == 4
      assert ToolResultPruner.char_count([%Message{role: :tool, content: "abc"}]) == 3

      assert ToolResultPruner.char_count([
               %Message{role: :tool, content: [ContentPart.image("12345", "image/png")]}
             ]) == 5

      assert ToolResultPruner.char_count([
               %Message{role: :tool, content: [ContentPart.image_url("http://x")]}
             ]) == 8

      assert ToolResultPruner.char_count([
               %Message{role: :assistant, content: [ContentPart.thinking("thinking!")]}
             ]) == 9

      # Totality: anything unexpected contributes 0 rather than raising.
      assert ToolResultPruner.char_count(:not_a_list) == 0
      assert ToolResultPruner.char_count([:not_a_message]) == 0
    end
  end

  defp byte_size_of(%Message{content: content}) when is_binary(content), do: byte_size(content)

  defp byte_size_of(%Message{content: content}) when is_list(content) do
    Enum.reduce(content, 0, fn
      %ContentPart{type: :text, text: text}, total when is_binary(text) ->
        total + byte_size(text)

      %ContentPart{type: :thinking, text: text}, total when is_binary(text) ->
        total + byte_size(text)

      %ContentPart{} = part, total ->
        total + payload_bytes(part)

      _part, total ->
        total
    end)
  end

  defp byte_size_of(_message), do: 0

  defp payload_bytes(part) do
    cond do
      is_binary(part.data) -> byte_size(part.data)
      is_binary(part.url) -> byte_size(part.url)
      is_binary(part.file_id) -> byte_size(part.file_id)
      true -> 0
    end
  end
end
