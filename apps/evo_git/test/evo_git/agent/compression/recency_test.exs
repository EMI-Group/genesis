defmodule EvoGit.Agent.Compression.RecencyTest do
  @moduledoc """
  `async: false` — the recency RULE, the tail-size budget and the tail SHRINK
  step of `EvoGit.Agent.Compression.Recency`, the single source of truth shared
  by both compression stages (and, until now, covered only through the pruner
  and checkpoint suites).

  `shrink_to_budget/2` is the one lever that can shrink a protected suffix whose
  minimal pairing-safe form is itself over budget (`boundary/3` never protects
  less than that), so its truncate-then-drop behaviour — and the promise that it
  never touches the head — is pinned here and wired through `Checkpoint.build/3`
  in `checkpoint_test`.

  Forced serial because the two seam tests mutate the app-env keys
  `:compression_tail_budget_fraction` / `:compression_tail_budget_tokens`, which
  `Recency.tail_budget/1` reads at CALL time and which the concurrently running
  `checkpoint_test` / `tool_result_pruner_test` suites also exercise.
  `setup` clears both to their defaults and `on_exit` restores whatever the
  operator had.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Compression.Checkpoint
  alias EvoGit.Agent.Compression.Recency
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @default_window 200_000

  setup do
    previous = %{
      compression_tail_budget_fraction:
        Application.fetch_env(:evo_git, :compression_tail_budget_fraction),
      compression_tail_budget_tokens:
        Application.fetch_env(:evo_git, :compression_tail_budget_tokens)
    }

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:evo_git, key, value)
        {key, :error} -> Application.delete_env(:evo_git, key)
      end)
    end)

    # Deterministic defaults for every test that does not set a seam itself.
    Application.delete_env(:evo_git, :compression_tail_budget_fraction)
    Application.delete_env(:evo_git, :compression_tail_budget_tokens)

    :ok
  end

  # --- Fixtures ---

  defp tag(message, turn), do: EvoGit.Agent.ContextBuilder.tag_message_turn(message, turn)

  defp assistant_with_call(call_id, text) do
    ReqLLM.Context.assistant(text, tool_calls: [ReqLLM.ToolCall.new(call_id, "read_file", "{}")])
  end

  # system + objective + `turn_count` (assistant-tool_calls, tool_result) pairs +
  # one closing assistant message, every message turn-tagged.
  defp conversation(turn_count, tool_text \\ "result") do
    system = tag(ReqLLM.Context.system("SYSTEM PROMPT"), 0)
    objective = tag(ReqLLM.Context.user("OBJECTIVE: do the thing"), 0)

    turns =
      for turn <- 0..(turn_count - 1) do
        [
          assistant_with_call("call_#{turn}", "working on turn #{turn}") |> tag(turn),
          ReqLLM.Context.tool_result("call_#{turn}", "read_file", "#{tool_text} #{turn}")
          |> tag(turn)
        ]
      end

    closing = tag(ReqLLM.Context.assistant("turn done"), turn_count - 1)

    [system, objective] ++ Enum.concat(turns) ++ [closing]
  end

  # The same 19-message shape with HUGE tool results (28_159 chars each).
  defp huge_conversation do
    huge = String.duplicate("T", 28_159)
    conversation(8, huge)
  end

  # 18 messages: the huge conversation WITHOUT the trailing assistant, so the
  # last message is a `:tool` result (the budget rewind case).
  defp huge_conversation_ending_on_tool do
    huge_conversation() |> Enum.drop(-1)
  end

  defp text(message) do
    message.content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  # --- Defaults ---

  describe "defaults" do
    test "exposes the documented window, fraction and cap" do
      assert Recency.default_keep_recent_turns() == 4
      assert Recency.default_tail_budget_fraction() == 0.2
      assert Recency.default_tail_budget_tokens() == 40_000
    end
  end

  # --- tail_budget/1 ---

  describe "tail_budget/1" do
    test "derives 0.2 * window and caps it at 40_000 tokens" do
      # 0.2 * 200_000 = 40_000 — right at the cap.
      assert Recency.tail_budget() == 40_000
      assert Recency.tail_budget(context_window: @default_window) == 40_000

      # Below the cap the window governs.
      assert Recency.tail_budget(context_window: 8_000) == 1_600
      assert Recency.tail_budget(context_window: 50_000) == 10_000
      assert Recency.tail_budget(context_window: 1_000_000) == 40_000
    end

    test "floors the budget at one token for a tiny window" do
      assert Recency.tail_budget(context_window: 1) == 1
      assert Recency.tail_budget(context_window: 3) == 1
      assert Recency.tail_budget(context_window: 10) == 2
    end

    test "honours the :tail_budget_fraction and :tail_budget_tokens overrides" do
      assert Recency.tail_budget(context_window: 100_000, tail_budget_fraction: 0.1) == 10_000
      assert Recency.tail_budget(context_window: 200_000, tail_budget_fraction: 0.5) == 40_000
      assert Recency.tail_budget(tail_budget_tokens: 5) == 5
      assert Recency.tail_budget(context_window: 8_000, tail_budget_tokens: 1) == 1

      # The fixed cap governs a window whose fraction asks for more.
      assert Recency.tail_budget(context_window: 100_000, tail_budget_fraction: 0.9) == 40_000
      assert Recency.tail_budget(context_window: 8_000, tail_budget_fraction: 0.9) == 7_200
    end

    test "unusable option values fall back to the defaults" do
      for window <- [0, -1, -100_000, :nope, "8000", 1.5, nil] do
        assert Recency.tail_budget(context_window: window) == 40_000,
               "unexpected budget for context_window: #{inspect(window)}"
      end

      for fraction <- [0, -0.5, :nope, "0.5", nil] do
        assert Recency.tail_budget(context_window: 8_000, tail_budget_fraction: fraction) == 1_600,
               "unexpected budget for tail_budget_fraction: #{inspect(fraction)}"
      end

      for tokens <- [0, -5, :nope, "5", 1.5, nil] do
        assert Recency.tail_budget(tail_budget_tokens: tokens) == 40_000,
               "unexpected budget for tail_budget_tokens: #{inspect(tokens)}"
      end

      # Total over a non-keyword second argument.
      assert Recency.tail_budget(:nope) == 40_000
    end

    test "the app-env seams override the defaults and lose to explicit options" do
      Application.put_env(:evo_git, :compression_tail_budget_tokens, 1_234)
      assert Recency.tail_budget() == 1_234
      assert Recency.tail_budget(context_window: 8_000) == 1_234
      assert Recency.tail_budget(tail_budget_tokens: 7) == 7

      Application.put_env(:evo_git, :compression_tail_budget_fraction, 0.01)
      assert Recency.tail_budget() == 1_234
      assert Recency.tail_budget(context_window: 100_000) == 1_000
      assert Recency.tail_budget(tail_budget_fraction: 0.5) == 1_234
    end

    test "an unusable app-env seam value falls back to the default" do
      for value <- [0, -3, :nope, "0.1"] do
        Application.put_env(:evo_git, :compression_tail_budget_tokens, value)
        assert Recency.tail_budget() == 40_000
      end

      for value <- [0, -0.2, :nope, "x", nil] do
        Application.put_env(:evo_git, :compression_tail_budget_fraction, value)
        assert Recency.tail_budget(context_window: 8_000) == 1_600
      end
    end
  end

  # --- char_count/1 and estimate_tokens/1 ---

  describe "char_count/1" do
    test "counts text and thinking parts, media payloads and legacy binaries" do
      assert Recency.char_count([]) == 0
      assert Recency.char_count([tag(ReqLLM.Context.user("abcd"), 0)]) == 4

      assert Recency.char_count([
               ReqLLM.Context.assistant("abc",
                 tool_calls: [ReqLLM.ToolCall.new("c", "read", "{}")]
               )
             ]) == 3

      assert Recency.char_count([
               %Message{role: :assistant, content: [ContentPart.thinking("think")]}
             ]) == 5

      # Media parts contribute their payload: data first, then url, then file_id.
      assert Recency.char_count([
               %Message{role: :tool, content: [ContentPart.image("12345", "image/png")]}
             ]) == 5

      assert Recency.char_count([
               %Message{role: :tool, content: [ContentPart.image_url("http://x")]}
             ]) == 8

      assert Recency.char_count([%Message{role: :tool, content: [ContentPart.file_id("file-7")]}]) ==
               6

      # Legacy binary content.
      assert Recency.char_count([%Message{role: :tool, content: "abcdef"}]) == 6
    end

    test "sums across a message list" do
      messages = conversation(2)
      expected = Enum.sum(Enum.map(messages, fn m -> Recency.char_count([m]) end))

      assert Recency.char_count(messages) == expected
      assert Recency.char_count(messages) > 0
    end

    test "is total: anything unexpected contributes 0" do
      assert Recency.char_count(:not_a_list) == 0
      assert Recency.char_count(nil) == 0
      assert Recency.char_count([:not_a_message]) == 0
      assert Recency.char_count([%{content: :nope}]) == 0
      assert Recency.char_count([%Message{role: :user, content: nil}]) == 0
    end
  end

  describe "estimate_tokens/1" do
    test "is the ceiling of chars / 4 — the ONE estimator of the subsystem" do
      assert Recency.estimate_tokens([]) == 0
      assert Recency.estimate_tokens([ReqLLM.Context.user("abcd")]) == 1
      assert Recency.estimate_tokens([ReqLLM.Context.user("abcde")]) == 2
      assert Recency.estimate_tokens([ReqLLM.Context.user(String.duplicate("x", 4_000))]) == 1_000
      assert Recency.estimate_tokens([ReqLLM.Context.user(String.duplicate("x", 4_001))]) == 1_001
      assert Recency.estimate_tokens(:not_a_list) == 0
    end

    test "agrees with char_count/1 for the same list" do
      messages = huge_conversation()
      chars = Recency.char_count(messages)

      assert Recency.estimate_tokens(messages) == div(chars + 3, 4)
    end
  end

  # --- synthetic?/1 ---

  describe "synthetic?/1" do
    test "recognises a compressor checkpoint by metadata" do
      message = Checkpoint.checkpoint_message("SUMMARY")

      assert message.metadata[:checkpoint] == true
      assert Recency.synthetic?(message)

      assert Recency.synthetic?(
               ReqLLM.Context.user("anything")
               |> Map.put(:metadata, %{checkpoint: true})
             )
    end

    test "recognises a summary user message carrying BOTH SummaryPrompt tags" do
      open_tag = EvoGit.Agent.Compression.SummaryPrompt.open_tag()
      close_tag = EvoGit.Agent.Compression.SummaryPrompt.close_tag()

      summary = ReqLLM.Context.user("#{open_tag}\nbody\n#{close_tag}")
      assert Recency.synthetic?(summary)

      # The tags are detected in a multi-part content list too.
      multipart =
        ReqLLM.Context.user([
          ContentPart.text(open_tag),
          ContentPart.text("body"),
          ContentPart.text(close_tag)
        ])

      assert Recency.synthetic?(multipart)
    end

    test "rejects every other shape" do
      open_tag = EvoGit.Agent.Compression.SummaryPrompt.open_tag()
      close_tag = EvoGit.Agent.Compression.SummaryPrompt.close_tag()

      refute Recency.synthetic?(ReqLLM.Context.user("ordinary question"))
      refute Recency.synthetic?(ReqLLM.Context.user("#{open_tag} only the open tag"))
      refute Recency.synthetic?(ReqLLM.Context.user("only the close tag #{close_tag}"))
      refute Recency.synthetic?(:nope)
      refute Recency.synthetic?(nil)
      refute Recency.synthetic?("a binary carrying #{open_tag} and #{close_tag}")
      refute Recency.synthetic?(%{role: :user, content: []})

      # Only a `:user` message participates in the tag rule.
      refute Recency.synthetic?(ReqLLM.Context.assistant("#{open_tag}\nbody\n#{close_tag}"))
      refute Recency.synthetic?(ReqLLM.Context.system("#{open_tag}\nbody\n#{close_tag}"))

      # A non-`%Message{}` map carrying checkpoint metadata is not a message.
      refute Recency.synthetic?(%{metadata: %{checkpoint: true}})
    end

    test "tolerates a message whose metadata is nil" do
      assert Recency.synthetic?(%Message{
               role: :user,
               metadata: nil,
               content: [ContentPart.text("hi")]
             }) ==
               false
    end
  end

  # --- turn_of/1 ---

  describe "turn_of/1" do
    test "reads an integer turn tag and nothing else" do
      assert Recency.turn_of(tag(ReqLLM.Context.user("x"), 0)) == 0
      assert Recency.turn_of(tag(ReqLLM.Context.user("x"), 7)) == 7
      assert Recency.turn_of(%Message{role: :user, metadata: %{turn: -1}}) == nil
      assert Recency.turn_of(%Message{role: :user, metadata: %{turn: "7"}}) == nil
      assert Recency.turn_of(%Message{role: :user, metadata: %{turn: nil}}) == nil
      assert Recency.turn_of(%Message{role: :user, metadata: nil}) == nil
      assert Recency.turn_of(ReqLLM.Context.user("untagged")) == nil
      assert Recency.turn_of(nil) == nil
      assert Recency.turn_of(:nope) == nil
    end
  end

  # --- boundary/3 ---

  describe "boundary/3 — turn rule" do
    test "protects the last four turns of a tagged conversation" do
      messages = conversation(8)
      boundary = Recency.boundary(messages)

      assert length(messages) == 19
      assert boundary == 10

      {old, recent} = Enum.split(messages, boundary)

      assert Enum.map(old, &Recency.turn_of/1) == [0, 0, 0, 0, 1, 1, 2, 2, 3, 3]
      assert Enum.map(recent, &Recency.turn_of/1) == [4, 4, 5, 5, 6, 6, 7, 7, 7]

      assert hd(recent).role == :assistant
    end

    test "a larger keep protects more and a smaller keep protects less" do
      messages = conversation(8)

      one = Recency.boundary(messages, 1)
      four = Recency.boundary(messages)
      twelve = Recency.boundary(messages, 12)

      assert one > four
      assert four > twelve
      assert twelve == 0
    end

    test "falls back to the positional floor (last 2 * keep messages) without turn tags" do
      messages = Enum.map(conversation(8), fn message -> %{message | metadata: %{}} end)

      # 19 messages - 2 * 4 = index 11, a tool RESULT, rewound to its assistant.
      assert Recency.boundary(messages) == 10
      assert Enum.at(messages, 10).role == :assistant
      assert Recency.boundary(messages, 1) == 16

      # The floor never goes negative.
      short = Enum.map(conversation(1), fn message -> %{message | metadata: %{}} end)
      assert Recency.boundary(short) == 0
    end

    test "takes the SMALLER of the turn rule and the positional floor" do
      messages = conversation(8)
      positional = max(length(messages) - 2 * Recency.default_keep_recent_turns(), 0)

      assert Recency.boundary(messages) <= positional
    end
  end

  describe "boundary/3 — synthetic messages" do
    test "a checkpoint turn-tagged with the NEWEST turn cannot pin the boundary" do
      # The stage-2 bug: a checkpoint at index 2 tagged with the conversation's
      # current turn made `max_turn - keep` land on ITS index, so the protected
      # tail swallowed the whole transcript and every later compression found
      # nothing to replace.
      messages = conversation(8)
      checkpoint = tag(Checkpoint.checkpoint_message("OLD SUMMARY"), 7)

      inserted = Enum.take(messages, 2) ++ [checkpoint] ++ Enum.drop(messages, 2)

      assert Recency.synthetic?(checkpoint)
      assert Recency.turn_of(checkpoint) == 7

      boundary = Recency.boundary(inserted)

      refute boundary == 2
      assert boundary > 2
      # The synthetic message changes nothing about which REAL messages are old:
      # the boundary lands on the same real message, shifted by the ONE message
      # the compressor inserted before it (a tagged message would have pulled it
      # back to index 2).
      assert boundary == Recency.boundary(messages) + 1
      assert Enum.at(inserted, boundary) == Enum.at(messages, Recency.boundary(messages))
      assert Enum.at(inserted, 2) == checkpoint
      assert boundary > 2
    end

    test "a synthetic summary message does not shift the boundary" do
      open_tag = EvoGit.Agent.Compression.SummaryPrompt.open_tag()
      close_tag = EvoGit.Agent.Compression.SummaryPrompt.close_tag()
      summary = tag(ReqLLM.Context.user("#{open_tag}\nbody\n#{close_tag}"), 0)

      messages = conversation(8)
      inserted = Enum.take(messages, 2) ++ [summary] ++ Enum.drop(messages, 2)

      # Shift-invariant: the same REAL message starts the protected suffix.
      assert Recency.boundary(inserted) == Recency.boundary(messages) + 1

      assert Enum.at(inserted, Recency.boundary(inserted)) ==
               Enum.at(messages, Recency.boundary(messages))
    end
  end

  describe "boundary/3 — tail size budget" do
    test "a small window moves the boundary LATER (protects less), never earlier" do
      messages = huge_conversation()
      untuned = Recency.boundary(messages)

      assert untuned == 10

      for window <- [40_000, 20_000, 8_000, 2_000, 10] do
        boundary = Recency.boundary(messages, 4, context_window: window)

        assert boundary >= untuned, "window #{window} protected MORE than the default budget"
        assert boundary <= length(messages) - 1
      end

      assert Recency.boundary(messages, 4, context_window: 8_000) > untuned
    end

    test "a huge default budget leaves the turn rule untouched" do
      messages = huge_conversation()

      assert Recency.boundary(messages, 4, context_window: 1_000_000) ==
               Recency.boundary(messages)

      assert Recency.boundary(messages, 4, tail_budget_tokens: 1) >= Recency.boundary(messages)
    end

    test "rewinds off a tool result the budget fit exposed" do
      messages = huge_conversation_ending_on_tool()
      boundary = Recency.boundary(messages, 4, context_window: 8_000)

      # The fit lands on the LAST message, a `:tool` result, and the rewind moves
      # it onto the assistant message that produced it.
      assert List.last(messages).role == :tool
      assert Recency.boundary(messages, 4, tail_budget_tokens: 1) == 16
      assert Enum.at(messages, 16).role == :assistant
      assert boundary == 16
    end

    test "a one-token budget keeps only the final exchange and rewinds off its tool result" do
      messages = huge_conversation_ending_on_tool()
      boundary = Recency.boundary(messages, 4, context_window: 1)

      assert boundary == length(messages) - 2
      assert Enum.at(messages, boundary).role == :assistant
    end
  end

  describe "boundary/3 — tool pairing and totality" do
    test "the protected suffix never starts on an orphaned tool result" do
      messages = conversation(8)

      for keep <- 1..10,
          window <- [nil, 8_000, 1_000] do
        opts = if window, do: [context_window: window], else: []
        boundary = Recency.boundary(messages, keep, opts)

        refute match?(%Message{role: :tool}, Enum.at(messages, boundary)),
               "boundary landed on a tool result (keep #{keep}, window #{inspect(window)})"
      end
    end

    test "is total over unusable input" do
      assert Recency.boundary([]) == 0
      assert Recency.boundary([ReqLLM.Context.user("only")]) == 0
      assert Recency.boundary(:not_a_list) == 0
      assert Recency.boundary(nil) == 0
      assert Recency.boundary(conversation(8), 0) == 0
      assert Recency.boundary(conversation(8), -1) == 0
      assert Recency.boundary(conversation(8), :nope) == 0
    end
  end

  # A `:tool` first message is out of contract, but the rewind must not raise.
  describe "boundary/3 — degenerate shapes" do
    test "a tool message at index 0 is never rewound below zero" do
      messages = [ReqLLM.Context.tool_result("c", "read_file", "r"), ReqLLM.Context.user("u")]

      assert Recency.boundary(messages, 1) == 0
    end
  end

  # --- shrink_to_budget/2 ---
  #
  # The compaction dead end this covers: `boundary/3` can never protect LESS
  # than the minimal pairing-safe suffix, so a suffix whose LAST message alone
  # exceeds the budget used to survive every rebuild untouched and compaction
  # re-triggered forever. `shrink_to_budget/2` is the step that can actually
  # shrink such a tail (truncating message text, then dropping whole leading
  # messages) — and it never touches the head.

  describe "shrink_to_budget/2 — within budget" do
    test "returns the SAME list untouched when the estimate already fits" do
      messages = conversation(2)

      for opts <- [[], [budget: 40_000], [context_window: @default_window]] do
        result = Recency.shrink_to_budget(messages, opts)

        assert result.messages === messages
        assert result.truncated == 0
        assert result.estimated_tokens == Recency.estimate_tokens(messages)
      end
    end
  end

  describe "shrink_to_budget/2 — truncating an oversized message" do
    test "a single huge tool result is head/tail truncated into its allowance" do
      # One message, so it cannot be dropped without losing the whole tail:
      # truncation is the ONLY lever.
      huge = "HEAD:" <> String.duplicate("a", 99_990) <> ":TAIL"
      assert byte_size(huge) == 100_000

      message = ReqLLM.Context.tool_result("call_big", "bash", huge)
      result = Recency.shrink_to_budget([message], budget: 8_000)

      assert length(result.messages) == 1
      assert [shrunk] = result.messages

      # Role, id, metadata and the part shape survive; only the text shrinks.
      assert shrunk.role == :tool
      assert shrunk.tool_call_id == "call_big"
      assert shrunk.metadata == message.metadata
      assert Enum.map(shrunk.content, & &1.type) == [:text]

      text = text(shrunk)

      assert text =~ ~r/… \[truncated \d+ characters\] …/u
      assert String.starts_with?(text, "HEAD:")
      assert String.ends_with?(text, ":TAIL")
      assert Recency.char_count([shrunk]) < Recency.char_count([message])

      assert result.truncated == 1
      assert result.estimated_tokens == Recency.estimate_tokens(result.messages)
      assert result.estimated_tokens <= 8_000
    end
  end

  describe "shrink_to_budget/2 — tool pairing survives truncation" do
    test "a huge assistant message keeps its tool_calls and the following results" do
      calls = [
        ReqLLM.ToolCall.new("c1", "read_file", "{}"),
        ReqLLM.ToolCall.new("c2", "bash", ~s({"cmd":"ls"}))
      ]

      assistant =
        ReqLLM.Context.assistant("HEAD:" <> String.duplicate("a", 99_990) <> ":TAIL",
          tool_calls: calls
        )
        |> tag(3)

      messages = [
        tag(ReqLLM.Context.system("SYSTEM PROMPT"), 0),
        tag(ReqLLM.Context.user("OBJECTIVE"), 0),
        assistant,
        ReqLLM.Context.tool_result("c1", "read_file", "one"),
        ReqLLM.Context.tool_result("c2", "bash", "two")
      ]

      result = Recency.shrink_to_budget(messages, budget: 8_000)

      # Nothing was dropped: only the oversized assistant text was truncated.
      assert length(result.messages) == 5
      assert result.truncated == 1
      assert result.estimated_tokens <= 8_000

      shrunk = Enum.at(result.messages, 2)

      assert shrunk.role == :assistant
      assert shrunk.tool_calls === assistant.tool_calls
      assert Enum.map(shrunk.tool_calls, & &1.id) == ["c1", "c2"]
      assert Recency.turn_of(shrunk) == 3
      assert text(shrunk) =~ ~r/… \[truncated \d+ characters\] …/u

      assert Enum.map(Enum.drop(result.messages, 3), & &1.tool_call_id) == ["c1", "c2"]
      assert Enum.take(result.messages, 2) === Enum.take(messages, 2)
    end
  end

  describe "shrink_to_budget/2 — leading-drop fallback" do
    test "three moderately large messages truncation cannot fix lose their leading message" do
      messages = for i <- 1..3, do: ReqLLM.Context.user(String.duplicate("#{i}", 2_000))

      # Every message is far below its allowance (min 1_000 tokens = 4_000
      # chars), so truncation is a no-op and only a DROP can fit the budget.
      assert Recency.estimate_tokens(messages) == 1_500

      result = Recency.shrink_to_budget(messages, budget: 1_000)

      assert result.messages == Enum.drop(messages, 1)
      assert result.truncated == 0
      assert result.estimated_tokens <= 1_000
      assert result.estimated_tokens == Recency.estimate_tokens(result.messages)
    end

    test "a dropped assistant tool call takes its tool results with it" do
      pairs =
        for turn <- 1..4 do
          [
            assistant_with_call("call_#{turn}", String.duplicate("A", 500)) |> tag(turn),
            ReqLLM.Context.tool_result("call_#{turn}", "bash", String.duplicate("T", 500))
            |> tag(turn)
          ]
        end

      messages =
        [tag(ReqLLM.Context.system("SYSTEM"), 0), tag(ReqLLM.Context.user("OBJECTIVE"), 0)] ++
          Enum.concat(pairs)

      result = Recency.shrink_to_budget(messages, budget: 1_000)

      dropped = length(messages) - length(result.messages)
      assert dropped > 0
      assert result.messages == Enum.drop(messages, dropped)

      # A valid conversation: it never STARTS on an orphaned tool result, and no
      # retained call lost its results (or vice versa).
      refute match?(%Message{role: :tool}, hd(result.messages))

      call_ids =
        for %Message{role: :assistant, tool_calls: calls} <- result.messages,
            call <- List.wrap(calls),
            do: Map.get(call, :id)

      result_ids =
        for %Message{role: :tool} = message <- result.messages, do: message.tool_call_id

      assert result_ids -- call_ids == []
      assert call_ids -- result_ids == []

      assert result.truncated == 0
      assert result.estimated_tokens <= 1_000
    end
  end

  describe "shrink_to_budget/2 — totality" do
    test "empty and non-list inputs come back untouched with a zero estimate" do
      assert Recency.shrink_to_budget([]) == %{messages: [], truncated: 0, estimated_tokens: 0}

      for input <- [nil, :nope, %{a: 1}, "a binary"] do
        assert Recency.shrink_to_budget(input) ==
                 %{messages: input, truncated: 0, estimated_tokens: 0}
      end
    end

    test "an unusable :budget falls back to tail_budget/1" do
      # 400 chars = 100 tokens: comfortably inside the DEFAULT 40_000 budget and
      # far outside a literal 0 / negative one, so an untouched list proves the
      # fallback (a literal reading of 0 would collapse the list).
      messages = [ReqLLM.Context.user(String.duplicate("x", 400))]

      for budget <- [0, -5, -100_000, :nope, "8000", 1.5, nil] do
        result = Recency.shrink_to_budget(messages, budget: budget)

        assert result.messages === messages,
               "budget #{inspect(budget)} did not fall back to tail_budget/1"

        assert result.truncated == 0
        assert result.estimated_tokens == 100
      end
    end

    test "a pathological :context_window falls back to the default window" do
      messages = [ReqLLM.Context.user(String.duplicate("x", 400))]

      for window <- [0, -1, -100_000, :nope, "8000", 1.5, nil] do
        result = Recency.shrink_to_budget(messages, context_window: window)

        assert result.messages === messages,
               "context_window #{inspect(window)} did not fall back to the default"

        assert result.estimated_tokens == 100
      end
    end

    test "an impossible budget collapses the list instead of raising" do
      # 100 tokens of text against a 1-token budget: the message is below its
      # allowance, so truncation cannot help — the only way to honour the budget
      # is to drop it, down to `[]`.
      result =
        Recency.shrink_to_budget([ReqLLM.Context.user(String.duplicate("x", 400))], budget: 1)

      assert result.messages == []
      assert result.truncated == 0
      assert result.estimated_tokens == 0
    end
  end

  # Guard: `text/1` exists so the fixture shape is asserted once, not per test.
  test "fixture messages carry text content" do
    assert text(tag(ReqLLM.Context.user("hello"), 0)) == "hello"
    assert Recency.char_count(huge_conversation()) > 0
  end
end
