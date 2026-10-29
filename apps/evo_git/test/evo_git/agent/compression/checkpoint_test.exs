defmodule EvoGit.Agent.Compression.CheckpointTest do
  @moduledoc """
  `async: true` — pure structural assertions on
  `EvoGit.Agent.Compression.Checkpoint` over in-memory `ReqLLM.Message` fixtures.
  No I/O, no global state, no scheduler, no network.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Compression.Checkpoint
  alias EvoGit.Agent.Compression.Recency
  alias EvoGit.Agent.Compression.SummaryPrompt
  alias ReqLLM.Message

  # The pinned checkpoint preamble (asserted verbatim — the wording is part of
  # the contract with the resuming agent).
  @preamble "This is an automatically generated checkpoint of the earlier conversation in this task. Everything before this message has been compacted. Continue the task directly from the summary below — do NOT acknowledge this checkpoint, do NOT restate it, and do NOT repeat work it says is already done."

  # --- Fixtures ---

  defp tag(message, turn), do: EvoGit.Agent.ContextBuilder.tag_message_turn(message, turn)

  defp assistant_with_call(call_id, text) do
    ReqLLM.Context.assistant(text, tool_calls: [ReqLLM.ToolCall.new(call_id, "read_file", "{}")])
  end

  # system + objective + `turn_count` (assistant-tool_calls, tool_result) pairs +
  # one closing assistant message, every message turn-tagged.
  defp conversation(turn_count) do
    system = tag(ReqLLM.Context.system("SYSTEM PROMPT"), 0)
    objective = tag(ReqLLM.Context.user("OBJECTIVE: do the thing"), 0)

    turns =
      for turn <- 0..(turn_count - 1) do
        [
          assistant_with_call("call_#{turn}", "working on turn #{turn}") |> tag(turn),
          ReqLLM.Context.tool_result("call_#{turn}", "read_file", "result #{turn}") |> tag(turn)
        ]
      end

    closing = tag(ReqLLM.Context.assistant("turn done"), turn_count - 1)

    [system, objective] ++ Enum.concat(turns) ++ [closing]
  end

  # A conversation built so the recency boundary (keep_recent_turns: 2) lands ON
  # a `:tool` message (index 7) and must be rewound to its producing assistant
  # message (index 6).
  defp straddling_conversation do
    [
      tag(ReqLLM.Context.system("SYSTEM"), 0),
      tag(ReqLLM.Context.user("OBJECTIVE"), 0),
      assistant_with_call("c1", "one") |> tag(1),
      ReqLLM.Context.tool_result("c1", "read_file", "r1") |> tag(1),
      assistant_with_call("c2", "two") |> tag(2),
      ReqLLM.Context.tool_result("c2", "read_file", "r2") |> tag(3),
      assistant_with_call("c3", "three") |> tag(4),
      ReqLLM.Context.tool_result("c3", "read_file", "r3") |> tag(4),
      assistant_with_call("c4", "four") |> tag(5),
      ReqLLM.Context.tool_result("c4", "read_file", "r4") |> tag(5),
      tag(ReqLLM.Context.assistant("six done"), 6)
    ]
  end

  # The head is [system, objective] and the rest is `turns` — for tests that
  # need a tail of a KNOWN, uniform size (the tail budget shrinks by message).
  defp uniform_tail_conversation(turns, text_chars) do
    assistant_text = String.duplicate("A", div(text_chars, 4))
    tool_text = String.duplicate("T", text_chars)

    tail =
      Enum.flat_map(turns, fn turn ->
        [
          assistant_with_call("m#{turn}", assistant_text) |> tag(turn),
          ReqLLM.Context.tool_result("m#{turn}", "bash", tool_text) |> tag(turn)
        ]
      end)

    [tag(ReqLLM.Context.system("SYSTEM"), 0), tag(ReqLLM.Context.user("OBJECTIVE"), 0)] ++ tail
  end

  # `turn`'s assistant call plus its tool result, the result carrying `chars` of
  # DISTINCTIVE text so a truncation can be recognised at the head AND the tail.
  defp giant_tool_turn(turn, chars) do
    [
      assistant_with_call("call_giant_#{turn}", "last look") |> tag(turn),
      ReqLLM.Context.tool_result(
        "call_giant_#{turn}",
        "bash",
        "GIANT-HEAD:" <> String.duplicate("G", chars) <> ":GIANT-TAIL"
      )
      |> tag(turn)
    ]
  end

  # head + four turns whose OLD-span tool results are huge (so `pre_estimate`
  # stays far above the budget and the progress guard never trims the tail) + a
  # FINAL turn whose `:tool` result alone blows the tail budget. The minimal
  # pairing-safe suffix (assistant + its tool result) is therefore still over
  # budget when `build/3` reassembles the list — the shape that used to leave
  # the rebuilt list permanently above the compaction threshold.
  defp oversized_tail_conversation(giant_chars \\ 120_000) do
    head = [tag(ReqLLM.Context.system("SYSTEM"), 0), tag(ReqLLM.Context.user("OBJECTIVE"), 0)]

    turns =
      Enum.flat_map(1..4, fn turn ->
        filler = if turn >= 2, do: String.duplicate("F", 60_000), else: "result #{turn}"

        [
          assistant_with_call("call_#{turn}", "work #{turn}") |> tag(turn),
          ReqLLM.Context.tool_result("call_#{turn}", "bash", filler) |> tag(turn)
        ]
      end)

    head ++ turns ++ giant_tool_turn(5, giant_chars)
  end

  defp message_text(%Message{content: content}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp turns_of(messages), do: Enum.map(messages, &Recency.turn_of/1)

  defp call_id(%ReqLLM.ToolCall{id: id}), do: id
  defp call_id(%{id: id}), do: id

  defp checkpoint_index(messages), do: Enum.find_index(messages, &Checkpoint.checkpoint?/1)

  defp expected_checkpoint_text(summary) do
    @preamble <>
      "\n\n" <>
      SummaryPrompt.open_tag() <>
      "\n" <> summary <> "\n" <> SummaryPrompt.close_tag() <> "\n"
  end

  # Every retained tool result is produced by a retained assistant `tool_calls`,
  # and every retained assistant tool call has its result — no orphan either way.
  defp assert_tool_pairings_intact(messages) do
    call_ids =
      for %Message{role: :assistant, tool_calls: calls} <- messages,
          call <- List.wrap(calls),
          do: call_id(call)

    result_ids = for %Message{role: :tool} = message <- messages, do: message.tool_call_id

    assert result_ids -- call_ids == [],
           "orphaned tool results (no retained assistant tool call): #{inspect(result_ids -- call_ids)}"

    assert call_ids -- result_ids == [],
           "tool calls without a retained result: #{inspect(call_ids -- result_ids)}"
  end

  # The retained suffix is ONE contiguous conversation: every assistant message
  # that carries `tool_calls` is IMMEDIATELY followed by its tool results, so a
  # provider never sees a call whose results live in the replaced span.
  defp assert_pairing_contiguous(messages) do
    messages
    |> Enum.with_index()
    |> Enum.each(fn {message, index} ->
      case message do
        %Message{role: :assistant, tool_calls: calls} when is_list(calls) and calls != [] ->
          expected = Enum.map(calls, &call_id/1)

          actual =
            messages
            |> Enum.drop(index + 1)
            |> Enum.take(length(expected))
            |> Enum.map(fn
              %Message{role: :tool, tool_call_id: id} -> id
              _other -> :not_a_tool_result
            end)

          assert actual == expected,
                 "tool results did not immediately follow their call at index #{index}: " <>
                   "expected #{inspect(expected)}, got #{inspect(actual)}"

        _other ->
          :ok
      end
    end)
  end

  # --- split/2 ---

  describe "split/2 — head" do
    test "keeps the first two messages byte-identical and in order" do
      messages = conversation(8)
      split = Checkpoint.split(messages)

      assert split.head == Enum.take(messages, 2)
      assert Enum.at(split.head, 0) == Enum.at(messages, 0)
      assert Enum.at(split.head, 1) == Enum.at(messages, 1)
      assert Enum.at(split.head, 0).role == :system
      assert Enum.at(split.head, 1).role == :user
    end

    test "head ++ old ++ recent reproduces the input exactly" do
      for messages <- [conversation(8), conversation(1), straddling_conversation()] do
        split = Checkpoint.split(messages)
        assert split.head ++ split.old ++ split.recent == messages
      end
    end

    test "a list shorter than two messages is all head" do
      assert Checkpoint.split([]) == %{head: [], old: [], recent: []}

      one = [ReqLLM.Context.system("SYSTEM")]
      assert Checkpoint.split(one) == %{head: one, old: [], recent: []}
    end
  end

  describe "split/2 — recency window" do
    test "keeps the last four turns verbatim and puts turns 0-3 in old" do
      messages = conversation(8)
      split = Checkpoint.split(messages)

      # 2 head + 8 turns x 2 messages + 1 closing = 19 messages.
      assert length(messages) == 19
      assert length(split.old) == 8
      assert length(split.recent) == 9

      # The retained suffix is exactly the tail of the input — no rewriting.
      assert split.old == Enum.slice(messages, 2, 8)
      assert split.recent == Enum.drop(messages, 10)

      assert turns_of(split.old) == [0, 0, 1, 1, 2, 2, 3, 3]
      assert turns_of(split.recent) == [4, 4, 5, 5, 6, 6, 7, 7, 7]

      recent_text = Enum.map_join(split.recent, "\n", &message_text/1)

      for turn <- 4..7 do
        assert recent_text =~ "result #{turn}"
        assert recent_text =~ "working on turn #{turn}"
      end

      old_text = Enum.map_join(split.old, "\n", &message_text/1)

      for turn <- 0..3 do
        assert old_text =~ "result #{turn}"
        refute recent_text =~ "result #{turn}"
      end
    end

    test "a larger keep_recent_turns protects more (and can protect everything)" do
      messages = conversation(8)

      split = Checkpoint.split(messages, keep_recent_turns: 8)
      assert split.old == []
      assert split.recent == Enum.drop(messages, 2)

      split = Checkpoint.split(messages, keep_recent_turns: 1)
      assert length(split.old) == 14
      assert length(split.recent) == 3
    end

    test "no turn tags at all falls back to the positional floor" do
      messages =
        Enum.map(conversation(8), fn message -> %{message | metadata: %{}} end)

      split = Checkpoint.split(messages)

      # 19 messages - 2 * keep(4) = 11 — and index 11 is a tool RESULT, so the
      # rewind moves the boundary one message earlier, onto its assistant.
      assert split.recent == Enum.drop(messages, 10)
      assert hd(split.recent).role == :assistant
      assert_tool_pairings_intact(split.recent)
    end

    test "a mid-size conversation still has messages to replace (floor rewinds onto the assistant)" do
      # 13 messages: the positional floor is index 5 — a tool RESULT — so the
      # rewind moves the boundary to its producing assistant (index 4) and two
      # messages legitimately enter `old`. This is the shape that keeps stage 2
      # from collapsing into a no-op, and it is why a no-op fixture must protect
      # its WHOLE tail (see build/3 "nothing old to replace").
      messages = conversation(5)
      split = Checkpoint.split(messages)

      assert length(messages) == 13
      assert length(split.old) == 2
      assert turns_of(split.old) == [0, 0]
      assert hd(split.recent) == Enum.at(messages, 4)
      assert hd(split.recent).role == :assistant
      assert split.head ++ split.old ++ split.recent == messages
    end
  end

  describe "split/2 — tool-pair integrity" do
    test "rewinds a boundary that lands on a :tool message" do
      messages = straddling_conversation()
      split = Checkpoint.split(messages, keep_recent_turns: 2)

      # The raw boundary is index 7 (a tool result); the rewind moves it to 6.
      assert length(split.old) == 4
      assert hd(split.recent) == Enum.at(messages, 6)
      assert hd(split.recent).role == :assistant
      assert split.head ++ split.old ++ split.recent == messages
    end

    test "the retained suffix never contains an orphaned tool result" do
      for messages <- [conversation(8), straddling_conversation()],
          keep <- [1, 2, 3, 4, 5, 8] do
        split = Checkpoint.split(messages, keep_recent_turns: keep)

        refute match?(%Message{role: :tool}, List.first(split.recent)),
               "recent started on an orphaned tool result (keep: #{keep})"

        assert_tool_pairings_intact(split.recent)
      end
    end
  end

  describe "split/2 — prior checkpoints (regression)" do
    test "a checkpoint turn-tagged with the NEWEST turn never pins the boundary" do
      # The historical bug: the checkpoint was turn-tagged with the conversation's
      # current turn and inserted at index 2, so `max_turn - keep` pointed AT it
      # and every later compression found nothing old to replace.
      messages = conversation(8)
      legacy_checkpoint = tag(Checkpoint.checkpoint_message("OLD SUMMARY"), 7)
      inserted = Enum.take(messages, 2) ++ [legacy_checkpoint] ++ Enum.drop(messages, 2)

      assert Checkpoint.checkpoint?(legacy_checkpoint)
      assert Recency.turn_of(legacy_checkpoint) == 7

      boundary = Recency.boundary(inserted)
      refute boundary == 2
      assert boundary > 2

      split = Checkpoint.split(inserted)
      refute split.old == []
      assert Enum.any?(split.old, &Checkpoint.checkpoint?/1)
      assert split.head ++ split.old ++ split.recent == inserted

      # …and the legacy checkpoint is therefore REPLACED on the next compaction.
      result = Checkpoint.build(inserted, "NEW SUMMARY")
      assert result.replaced >= 1
      assert length(Enum.filter(result.messages, &Checkpoint.checkpoint?/1)) == 1
      assert Checkpoint.prior_summary(result.messages) == "NEW SUMMARY"
    end

    test "forces the split past a prior checkpoint even when the whole list would be protected" do
      # A just-compacted transcript plus ONE further turn: five messages, of which
      # the default recency rule protects all of them.
      checkpoint = Checkpoint.checkpoint_message("FIRST SUMMARY")

      compacted = [
        tag(ReqLLM.Context.system("SYSTEM"), 0),
        tag(ReqLLM.Context.user("OBJECTIVE"), 0),
        checkpoint,
        assistant_with_call("call_7", "working on turn 7") |> tag(7),
        ReqLLM.Context.tool_result("call_7", "read_file", "result 7") |> tag(7)
      ]

      assert Recency.boundary(compacted) == 0
      assert checkpoint_index(compacted) == 2

      split = Checkpoint.split(compacted)

      # …yet the split is forced past the checkpoint, so it always lands in old.
      assert split.old == [checkpoint]
      assert split.recent == Enum.drop(compacted, 3)
      assert split.head ++ split.old ++ split.recent == compacted
      assert Checkpoint.checkpoint?(hd(split.old))
    end
  end

  # --- build/3 ---

  describe "build/3" do
    test "replaces the old span with one checkpoint message" do
      messages = conversation(8)
      result = Checkpoint.build(messages, "THE SUMMARY")

      assert result.replaced == 8
      assert result.kept == 9
      assert length(result.messages) == 1 + 1 + 1 + 9

      assert [system, objective, checkpoint | rest] = result.messages
      assert system == Enum.at(messages, 0)
      assert objective == Enum.at(messages, 1)
      assert checkpoint.role == :user
      assert message_text(checkpoint) == expected_checkpoint_text("THE SUMMARY")
      assert rest == Enum.drop(messages, 10)
    end

    test "reports the seven-field result map" do
      messages = conversation(8)
      result = Checkpoint.build(messages, "THE SUMMARY")

      assert result |> Map.keys() |> Enum.sort() ==
               [:budget, :estimated_tokens, :kept, :messages, :pre_estimate, :replaced, :shrunk]

      assert result.pre_estimate == Recency.estimate_tokens(messages)
      assert result.estimated_tokens == Recency.estimate_tokens(result.messages)
      assert result.budget == Recency.tail_budget()
      assert result.kept == length(result.messages) - 3
      refute result.shrunk
    end

    test "the checkpoint text carries the pinned preamble and the summary tags" do
      message = Checkpoint.checkpoint_message("SOME SUMMARY")
      text = message_text(message)

      assert message.role == :user
      assert String.starts_with?(text, @preamble)

      assert text =~ SummaryPrompt.open_tag() <> "\nSOME SUMMARY\n" <> SummaryPrompt.close_tag()
      refute message.tool_calls
    end

    test "a blank summary never fabricates a checkpoint" do
      messages = conversation(8)
      pre_estimate = Recency.estimate_tokens(messages)

      for blank <- [nil, "", "   \n\t "] do
        result = Checkpoint.build(messages, blank)

        assert result.messages == messages
        assert result.replaced == 0
        assert result.estimated_tokens == pre_estimate
        assert result.pre_estimate == pre_estimate
        refute result.shrunk
      end
    end

    test "nothing old to replace returns the input unchanged" do
      two_messages = [tag(ReqLLM.Context.system("SYSTEM"), 0), tag(ReqLLM.Context.user("OBJ"), 0)]
      estimate = Recency.estimate_tokens(two_messages)

      # A no-op fixture must protect its WHOLE tail: with fewer messages than the
      # head + positional floor, no index lands on a prunable message.
      assert Checkpoint.build(two_messages, "SUMMARY") == %{
               messages: two_messages,
               replaced: 0,
               kept: 0,
               estimated_tokens: estimate,
               pre_estimate: estimate,
               budget: Recency.tail_budget(),
               shrunk: false
             }

      single_turn = conversation(1)
      result = Checkpoint.build(single_turn, "SUMMARY")
      assert result.messages == single_turn
      assert result.replaced == 0
      assert result.kept == 3
      assert result.estimated_tokens == result.pre_estimate
    end

    test "honours keep_recent_turns" do
      messages = conversation(8)
      result = Checkpoint.build(messages, "SUM", keep_recent_turns: 1)

      assert result.replaced == 14
      assert result.kept == 3
      assert length(result.messages) == 3 + 3
    end

    test "checkpoint_message ignores :turn and stamps metadata[:checkpoint]" do
      for turn <- [nil, 0, 5] do
        message = Checkpoint.checkpoint_message("SUM", turn)

        assert message.metadata[:checkpoint] == true
        refute Map.has_key?(message.metadata, :turn)
        assert Recency.turn_of(message) == nil
        assert Recency.synthetic?(message)
      end

      result = Checkpoint.build(conversation(8), "SUM", turn: 5)
      checkpoint = Enum.at(result.messages, 2)

      assert checkpoint.metadata[:checkpoint] == true
      assert checkpoint.metadata[:turn] == nil
      assert Recency.turn_of(checkpoint) == nil
      refute Map.has_key?(checkpoint.metadata, :turn)
    end
  end

  describe "build/3 — repeated compactions (regression)" do
    test "two consecutive compactions keep exactly ONE checkpoint after the head and accumulate" do
      first = Checkpoint.build(conversation(8), "FIRST SUMMARY")
      assert first.replaced == 8

      # Keep working, then compact again with a NEW summary.
      continued =
        first.messages ++
          Enum.flat_map(8..11, fn turn ->
            [
              assistant_with_call("call_#{turn}", "working on turn #{turn}") |> tag(turn),
              ReqLLM.Context.tool_result("call_#{turn}", "read_file", "result #{turn}")
              |> tag(turn)
            ]
          end) ++ [tag(ReqLLM.Context.assistant("later done"), 11)]

      second = Checkpoint.build(continued, "FIRST + SECOND SUMMARY")

      assert second.replaced >= 1
      assert length(Enum.filter(second.messages, &Checkpoint.checkpoint?/1)) == 1
      assert checkpoint_index(second.messages) == 2
      assert Checkpoint.prior_summary(second.messages) == "FIRST + SECOND SUMMARY"

      # The head is still byte-identical and the tail is a contiguous suffix.
      assert Enum.take(second.messages, 2) == Enum.take(conversation(8), 2)
      assert second.messages |> Enum.drop(3) |> List.last() == List.last(continued)
      assert_tool_pairings_intact(second.messages)
    end

    test "a prior checkpoint inside the protected tail is REPLACED, not retained" do
      first = Checkpoint.build(conversation(8), "FIRST SUMMARY")

      # Only one exchange later, and that exchange is enormous: without the
      # forced split the whole list would be inside the protected tail and the
      # previous checkpoint would simply be carried forward.
      huge = String.duplicate("X", 300_000)

      later =
        first.messages ++
          [
            ReqLLM.Context.user("keep going")
            |> Map.put(:content, [ReqLLM.Message.ContentPart.text(huge)])
            |> tag(8),
            tag(ReqLLM.Context.assistant("ok"), 8)
          ]

      third = Checkpoint.build(later, "THIRD SUMMARY")

      assert third.replaced >= 1
      assert length(Enum.filter(third.messages, &Checkpoint.checkpoint?/1)) == 1
      assert checkpoint_index(third.messages) == 2
      assert Checkpoint.prior_summary(third.messages) == "THIRD SUMMARY"
      assert Checkpoint.prior_summary(third.messages) != "FIRST SUMMARY"
      assert Enum.take(third.messages, 2) == Enum.take(conversation(8), 2)
    end

    test "an oversized tail is budget-bounded and keeps tool pairing" do
      # 4 enormous turns (8 messages, ~5k tokens of tail) against a window whose
      # tail budget is 1_600 tokens: the retained suffix must be shrunk.
      messages = uniform_tail_conversation(4..7, 4_000)
      budget = Recency.tail_budget(context_window: 8_000)

      assert budget == 1_600
      assert Recency.estimate_tokens(messages) > budget

      result = Checkpoint.build(messages, "SUM", context_window: 8_000)

      assert result.replaced >= 1
      assert result.budget == budget
      assert result.estimated_tokens <= budget
      assert result.estimated_tokens <= result.pre_estimate
      assert result.estimated_tokens <= 0.9 * result.pre_estimate

      [head_system, head_objective, checkpoint | retained] = result.messages

      assert head_system == Enum.at(messages, 0)
      assert head_objective == Enum.at(messages, 1)
      assert Checkpoint.checkpoint?(checkpoint)
      assert retained != []
      assert length(retained) < length(messages) - 2
      refute match?(%Message{role: :tool}, hd(retained))
      assert List.last(result.messages) == List.last(messages)

      assert_tool_pairings_intact(result.messages)
      assert_pairing_contiguous(retained)
      assert Enum.all?(result.messages, &Message.valid?/1)
    end

    test "repeated compressions stay bounded" do
      budget = Recency.tail_budget(context_window: 8_000)
      initial = uniform_tail_conversation(4..7, 4_000)

      {final, reversed_estimates} =
        Enum.reduce(1..5, {initial, []}, fn round, {current, estimates} ->
          # Each round the agent keeps working (a fresh huge tail), then compacts.
          grown =
            current ++
              (uniform_tail_conversation((10 + round)..(11 + round), 4_000) |> Enum.drop(2))

          result = Checkpoint.build(grown, "SUMMARY #{round}", context_window: 8_000)

          assert result.replaced >= 1
          assert length(Enum.filter(result.messages, &Checkpoint.checkpoint?/1)) == 1
          assert checkpoint_index(result.messages) == 2
          assert Checkpoint.prior_summary(result.messages) == "SUMMARY #{round}"
          assert result.estimated_tokens <= budget
          assert_tool_pairings_intact(result.messages)

          {result.messages, [result.estimated_tokens | estimates]}
        end)

      estimates = Enum.reverse(reversed_estimates)

      # Bounded, and never growing across rounds.
      assert Enum.all?(estimates, &(&1 <= budget))
      assert estimates == Enum.sort(estimates, :desc)
      assert estimates != []
      assert length(final) < length(initial) + 10
    end
  end

  # --- build/3 — oversized recent tail (regression) ---
  #
  # `Recency.boundary/3` may only protect LESS down to the minimal pairing-safe
  # suffix, so when that suffix's LAST message alone exceeds the tail budget the
  # rebuilt list stayed over budget and compaction re-triggered forever. The
  # retained tail is now additionally shrunk after the existing trimming.

  describe "build/3 — oversized recent tail (regression)" do
    test "one enormous final tool result is shrunk instead of kept over budget" do
      messages = oversized_tail_conversation()
      budget = Recency.tail_budget(context_window: 8_000)

      assert budget == 1_600
      assert Recency.estimate_tokens(messages) > budget

      result = Checkpoint.build(messages, "SUM", context_window: 8_000)

      assert result.replaced >= 1
      assert result.budget == budget
      assert result.estimated_tokens == Recency.estimate_tokens(result.messages)
      assert result.estimated_tokens <= budget
      assert result.estimated_tokens <= result.pre_estimate
      assert result.shrunk

      # The head is still byte-identical and the list holds exactly ONE
      # checkpoint, right after the head.
      assert Enum.take(result.messages, 2) === Enum.take(messages, 2)
      assert checkpoint_index(result.messages) == 2
      assert length(Enum.filter(result.messages, &Checkpoint.checkpoint?/1)) == 1

      [system, objective, checkpoint | retained] = result.messages

      assert system.role == :system
      assert objective.role == :user
      assert Checkpoint.checkpoint?(checkpoint)
      assert result.kept == length(retained)

      # The retained tail does not start on an orphaned tool result…
      assert Enum.at(result.messages, 3).role != :tool
      refute match?(%Message{role: :tool}, Enum.at(result.messages, 3))

      # …and the giant tool result SURVIVED, truncated, with its id intact and
      # both ends of the original text present.
      giant = List.last(retained)

      assert giant.role == :tool
      assert giant.tool_call_id == "call_giant_5"

      text = message_text(giant)

      assert text =~ ~r/… \[truncated \d+ characters\] …/u
      assert String.starts_with?(text, "GIANT-HEAD:")
      assert String.ends_with?(text, ":GIANT-TAIL")

      assert_tool_pairings_intact(result.messages)
      assert_pairing_contiguous(retained)
      assert Enum.all?(result.messages, &Message.valid?/1)
    end

    test "repeated builds over a fresh giant tool result stay bounded and never grow" do
      budget = Recency.tail_budget(context_window: 8_000)
      initial = oversized_tail_conversation()

      {final, reversed_estimates} =
        Enum.reduce(1..3, {initial, []}, fn round, {current, estimates} ->
          # Each round the agent keeps working and produces ANOTHER huge tail.
          grown = current ++ giant_tool_turn(5 + round, 120_000)
          result = Checkpoint.build(grown, "SUMMARY #{round}", context_window: 8_000)

          assert result.replaced >= 1
          assert checkpoint_index(result.messages) == 2
          assert length(Enum.filter(result.messages, &Checkpoint.checkpoint?/1)) == 1
          assert Checkpoint.prior_summary(result.messages) == "SUMMARY #{round}"
          assert Enum.take(result.messages, 2) === Enum.take(initial, 2)
          assert result.estimated_tokens == Recency.estimate_tokens(result.messages)
          assert result.estimated_tokens <= budget
          assert_tool_pairings_intact(result.messages)

          {result.messages, [result.estimated_tokens | estimates]}
        end)

      estimates = Enum.reverse(reversed_estimates)

      # Bounded every round, and never growing across rounds.
      assert length(estimates) == 3
      assert Enum.all?(estimates, &(&1 <= budget))
      assert estimates == Enum.sort(estimates, :desc)
      assert length(final) <= length(initial)
    end
  end

  # --- checkpoint?/1 and prior_summary/1 ---

  describe "checkpoint?/1" do
    test "detects a checkpoint message" do
      assert Checkpoint.checkpoint?(Checkpoint.checkpoint_message("anything"))
      assert Checkpoint.checkpoint?(Enum.at(Checkpoint.build(conversation(8), "S").messages, 2))
    end

    test "rejects every other shape" do
      refute Checkpoint.checkpoint?(ReqLLM.Context.user("ordinary question"))
      refute Checkpoint.checkpoint?(ReqLLM.Context.system("SYSTEM"))
      refute Checkpoint.checkpoint?(ReqLLM.Context.assistant("reply"))
      refute Checkpoint.checkpoint?(nil)
      refute Checkpoint.checkpoint?(:nope)
      refute Checkpoint.checkpoint?("a binary with <compacted-summary> and </compacted-summary>")
      refute Checkpoint.checkpoint?(%{role: :user, content: []})
      refute Checkpoint.checkpoint?(ReqLLM.Context.user("<compacted-summary> only the open tag"))
    end
  end

  describe "prior_summary/1" do
    test "is nil when there is no checkpoint" do
      assert Checkpoint.prior_summary([]) == nil
      assert Checkpoint.prior_summary(conversation(8)) == nil
      assert Checkpoint.prior_summary(nil) == nil
    end

    test "recovers the inner text of the last checkpoint" do
      first = Checkpoint.checkpoint_message("FIRST SUMMARY")
      second = Checkpoint.checkpoint_message("  SECOND SUMMARY  ")

      assert Checkpoint.prior_summary([first]) == "FIRST SUMMARY"

      assert Checkpoint.prior_summary([first, ReqLLM.Context.user("chatter"), second]) ==
               "SECOND SUMMARY"

      assert Checkpoint.prior_summary([second, first]) == "FIRST SUMMARY"
    end

    test "a build → detect → recover round trip" do
      built = Checkpoint.build(conversation(8), "THE SUMMARY").messages
      checkpoint = Enum.at(built, 2)

      assert Checkpoint.checkpoint?(checkpoint)
      assert Checkpoint.prior_summary(built) == "THE SUMMARY"
    end

    test "repeated compactions replace the previous checkpoint and accumulate" do
      first = Checkpoint.build(conversation(8), "FIRST SUMMARY")

      # Feeding an ALREADY compacted list back in replaces the previous
      # checkpoint (rather than stacking a second one).
      second = Checkpoint.build(first.messages, "FIRST + SECOND SUMMARY")

      assert second.replaced == 1
      assert Checkpoint.prior_summary(second.messages) == "FIRST + SECOND SUMMARY"

      checkpoints = Enum.filter(second.messages, &Checkpoint.checkpoint?/1)
      assert length(checkpoints) == 1

      # …and the head is still byte-identical after any number of rounds.
      assert Enum.take(second.messages, 2) == Enum.take(conversation(8), 2)
    end
  end
end
