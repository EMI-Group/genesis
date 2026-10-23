defmodule EvoGit.Agent.Compression.CheckpointTest do
  @moduledoc """
  `async: true` — pure structural assertions on
  `EvoGit.Agent.Compression.Checkpoint` over in-memory `ReqLLM.Message` fixtures.
  No I/O, no global state, no scheduler, no network.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Compression.Checkpoint
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

  defp message_text(%Message{content: content}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp turns_of(messages), do: Enum.map(messages, &EvoGit.Agent.Compression.Recency.turn_of/1)

  defp call_id(%ReqLLM.ToolCall{id: id}), do: id
  defp call_id(%{id: id}), do: id

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

      for blank <- [nil, "", "   \n\t "] do
        result = Checkpoint.build(messages, blank)

        assert result.messages == messages
        assert result.replaced == 0
      end
    end

    test "nothing old to replace returns the input unchanged" do
      two_messages = [tag(ReqLLM.Context.system("SYSTEM"), 0), tag(ReqLLM.Context.user("OBJ"), 0)]

      assert Checkpoint.build(two_messages, "SUMMARY") == %{
               messages: two_messages,
               replaced: 0,
               kept: 0
             }

      single_turn = conversation(1)
      result = Checkpoint.build(single_turn, "SUMMARY")
      assert result.messages == single_turn
      assert result.replaced == 0
    end

    test "honours keep_recent_turns" do
      messages = conversation(8)
      result = Checkpoint.build(messages, "SUM", keep_recent_turns: 1)

      assert result.replaced == 14
      assert result.kept == 3
      assert length(result.messages) == 3 + 3
    end

    test "turn-tags the checkpoint message when :turn is given" do
      messages = conversation(8)
      result = Checkpoint.build(messages, "SUM", turn: 5)
      checkpoint = Enum.at(result.messages, 2)

      assert checkpoint.metadata[:turn] == 5
      assert EvoGit.Agent.Compression.Recency.turn_of(checkpoint) == 5
    end

    test "leaves the checkpoint message untagged when :turn is absent" do
      messages = conversation(8)
      result = Checkpoint.build(messages, "SUM")
      checkpoint = Enum.at(result.messages, 2)

      refute Map.has_key?(checkpoint.metadata, :turn)
      assert checkpoint.metadata == %{}
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
