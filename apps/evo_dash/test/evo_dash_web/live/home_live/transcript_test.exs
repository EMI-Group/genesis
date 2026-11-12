defmodule EvoDashWeb.HomeLive.TranscriptTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.Transcript

  @first_reasoning for i <- 1..3, do: %{type: "thinking", data: %{text: "turn-1-#{i}"}}
  @second_reasoning for i <- 1..2, do: %{type: "thinking", data: %{text: "turn-2-#{i}"}}

  # Unit tests for Transcript.normalize/1 — the mount-direction guard that
  # coerces arbitrary persisted transcript data into the current entry shape.
  # Total: non-lists, non-map entries, non-binary ids, unknown roles, missing
  # keys, and non-boolean streaming flags all degrade instead of crashing.

  describe "normalize/1" do
    test "non-lists normalize to []; non-map entries are dropped" do
      for input <- [nil, "x", 42, %{}] do
        assert Transcript.normalize(input) == []
      end

      assert [%{id: "1", role: :user, text: "hi"}] =
               Transcript.normalize([%{id: "1", role: :user, text: "hi"}, :junk, "str", nil])
    end

    test "non-binary ids are coerced; nil and absent ids get fresh unique ids" do
      [e1, e2, e3] =
        Transcript.normalize([
          %{id: 7, role: :user, text: "a"},
          %{id: nil, role: :user, text: "b"},
          %{role: :user, text: "c"}
        ])

      assert e1.id == "7"
      assert e2.id != "" and e3.id != ""
      assert e2.id != e3.id
    end

    test "string roles are whitelisted, unknown roles fall back to :assistant" do
      # Unknown roles keep the entry visible, left-aligned.
      [u, a, e, bogus] =
        Transcript.normalize([
          %{role: "user", text: "1"},
          %{role: "assistant", text: "2"},
          %{role: "error", text: "3"},
          %{role: :bogus, text: "x"}
        ])

      assert {u.role, a.role, e.role, bogus.role} == {:user, :assistant, :error, :assistant}
    end

    test "missing keys degrade; streaming is boolean-ized; text is coerced" do
      [empty] = Transcript.normalize([%{}])
      assert {empty.text, empty.role, empty.streaming} == {"", :assistant, false}
      assert is_binary(empty.id)

      # true only for exactly true.
      [s1, s2, s3] =
        Transcript.normalize([
          %{streaming: true, text: "a"},
          %{streaming: "yes", text: "b"},
          %{streaming: false, text: "c"}
        ])

      assert {s1.streaming, s2.streaming, s3.streaming} == {true, false, false}

      assert [%{text: "123"}] = Transcript.normalize([%{text: 123}])
      assert [%{text: ""}] = Transcript.normalize([%{text: nil}])
    end

    test "valid entries pass through unchanged" do
      entry = %{id: "abc", role: :error, text: "boom", streaming: false}
      assert Transcript.normalize([entry]) == [entry]
    end
  end

  describe "caps" do
    test "the transcript keeps at most 200 entries, newest kept" do
      entries = for i <- 0..204, do: Transcript.entry(:user, "m#{i}")

      transcript = Enum.reduce(entries, Transcript.new(), &Transcript.append(&2, &1))

      assert length(transcript) == 200
      # The oldest five fell off; the newest is last (oldest-first ordering).
      assert List.first(transcript).text == "m5"
      assert List.last(transcript).text == "m204"
      refute Enum.any?(transcript, &(&1.text in ["m0", "m1", "m2", "m3", "m4"]))

      # The restore/normalize path enforces the same cap.
      restored = Transcript.normalize(entries)
      assert length(restored) == 200
      assert {List.first(restored).text, List.last(restored).text} == {"m5", "m204"}
    end

    test "per-entry rendered text is capped at 8 000 graphemes" do
      builders = [
        fn text -> Transcript.entry(:assistant, text) end,
        fn text -> hd(Transcript.normalize([%{role: :assistant, text: text}])) end,
        fn text -> hd(Transcript.put_streaming_text([], text)) end,
        fn text -> hd(Transcript.finalize_assistant([], text)) end
      ]

      for build <- builders do
        entry = build.(String.duplicate("a", 9_000))
        assert String.length(entry.text) == 8_000
        # No ellipsis marker: a truncated bubble must not grow text the model
        # never produced.
        refute String.ends_with?(entry.text, "…")
      end

      # Grapheme-safe, not byte-safe: multi-byte text also stops at 8 000.
      assert String.length(Transcript.entry(:assistant, String.duplicate("日", 9_000)).text) ==
               8_000

      # Text at or under the cap is untouched.
      assert Transcript.entry(:assistant, "short").text == "short"
      at_cap = String.duplicate("a", 8_000)
      assert Transcript.entry(:assistant, at_cap).text == at_cap
    end
  end

  describe "per-message reasoning" do
    test "reasoning is attached per assistant entry and never mixed between turns" do
      [first, second] =
        transcript = [
          Transcript.entry(:assistant, "first answer"),
          Transcript.entry(:assistant, "second answer")
        ]

      transcript =
        transcript
        |> Transcript.put_reasoning(first.id, @first_reasoning)
        |> Transcript.put_reasoning(second.id, @second_reasoning)

      [a, b] = transcript
      assert {a.id, b.id} == {first.id, second.id}
      assert a.reasoning == @first_reasoning
      assert b.reasoning == @second_reasoning
      assert a.reasoning != b.reasoning
      refute Enum.any?(a.reasoning, &String.contains?(&1.data.text, "turn-2"))
      refute Enum.any?(b.reasoning, &String.contains?(&1.data.text, "turn-1"))
      # Reasoning is entry metadata, not transcript-wide state.
      assert Enum.map(transcript, & &1.text) == ["first answer", "second answer"]
    end

    test "an earlier turn keeps its own reasoning as later turns arrive" do
      first = Transcript.entry(:assistant, "one")
      transcript = Transcript.put_reasoning([first], first.id, @first_reasoning)

      second = Transcript.entry(:assistant, "two")

      transcript =
        transcript
        |> Transcript.append(second)
        |> Transcript.put_reasoning(second.id, @second_reasoning)
        |> then(fn transcript ->
          Enum.reduce(1..5, transcript, fn i, acc ->
            Transcript.append(acc, Transcript.entry(:user, "u#{i}"))
          end)
        end)

      [a, b | rest] = transcript
      assert {a.id, b.id} == {first.id, second.id}
      assert a.reasoning == @first_reasoning
      assert b.reasoning == @second_reasoning
      assert length(rest) == 5
      # Reasoning survives a normalize round-trip untouched.
      [na, nb | _] = Transcript.normalize(transcript)
      assert {na.reasoning, nb.reasoning} == {@first_reasoning, @second_reasoning}
    end

    test "per-message reasoning is capped at 40 entries, oldest dropped" do
      entry = Transcript.entry(:assistant, "answer")
      reasoning = Enum.to_list(1..45)

      [restored] = Transcript.put_reasoning([entry], entry.id, reasoning)
      assert length(restored.reasoning) == 40
      assert restored.reasoning == Enum.to_list(6..45)

      [normalized] =
        Transcript.normalize([%{id: "r", role: :assistant, text: "x", reasoning: reasoning}])

      assert length(normalized.reasoning) == 40
      assert normalized.reasoning == Enum.to_list(6..45)
    end

    test "unknown ids and malformed reasoning stay total" do
      entry = Transcript.entry(:assistant, "answer")
      with_reasoning = Transcript.put_reasoning([entry], entry.id, [%{k: 1}])

      assert Transcript.put_reasoning(with_reasoning, "missing-id", [%{k: 2}]) == with_reasoning
      assert Transcript.put_reasoning(with_reasoning, nil, [%{k: 2}]) == with_reasoning

      for malformed <- ["not-a-list", nil, %{}, 42] do
        assert hd(Transcript.put_reasoning(with_reasoning, entry.id, malformed)).reasoning == [],
               "expected [] for #{inspect(malformed)}"
      end

      # Integer ids are matched against the normalized (string) entry id.
      assert hd(Transcript.put_reasoning(with_reasoning, String.to_integer(entry.id), [%{k: 3}])).reasoning ==
               [%{k: 3}]
    end

    test "a stored entry without :reasoning keeps its exact shape; put_reasoning adds it" do
      [plain] = Transcript.normalize([%{id: "a", role: :assistant, text: "x"}])
      refute Map.has_key?(plain, :reasoning)

      [attached] = Transcript.put_reasoning([plain], "a", [%{k: 1}])
      assert attached.reasoning == [%{k: 1}]
    end
  end

  describe "append_streaming_text/2" do
    test "the first chunk opens a streaming assistant entry, later chunks append to it" do
      [first] = Transcript.append_streaming_text([], "Hello")
      assert %{role: :assistant, text: "Hello", streaming: true} = first

      [entry] =
        first
        |> then(&Transcript.append_streaming_text([&1], " "))
        |> then(&Transcript.append_streaming_text(&1, "world"))

      assert entry.id == first.id
      assert %{text: "Hello world", streaming: true} = entry
    end

    test "it targets the last streaming entry and never disturbs settled ones" do
      settled = Transcript.entry(:assistant, "done")

      transcript =
        Transcript.append_streaming_text([settled], "live")
        |> then(&Transcript.append_streaming_text(&1, " update"))

      assert [%{text: "done", streaming: false}, %{text: "live update", streaming: true}] =
               transcript
    end

    test "an empty or non-binary chunk leaves the transcript unchanged" do
      transcript = [Transcript.entry(:assistant, "text", streaming: true)]

      for chunk <- ["", nil, 42, :chunk] do
        assert Transcript.append_streaming_text(transcript, chunk) ==
                 Transcript.normalize(transcript)
      end
    end

    test "the 8 000-grapheme cap applies to the accumulated text" do
      [entry] = Transcript.append_streaming_text([], String.duplicate("a", 7_990))
      [entry] = Transcript.append_streaming_text([entry], String.duplicate("b", 100))

      assert String.length(entry.text) == 8_000
      assert String.starts_with?(entry.text, "aaaa")
    end
  end

  describe "finalize_streaming/1" do
    test "clears the streaming flag of the last streaming entry, text untouched" do
      transcript =
        [
          Transcript.entry(:assistant, "done"),
          Transcript.entry(:assistant, "live", streaming: true)
        ]

      assert [%{text: "done", streaming: false}, %{text: "live", streaming: false}] =
               Transcript.finalize_streaming(transcript)
    end

    test "a transcript with no streaming entry comes back normalized and unchanged" do
      transcript = [%{id: "a", role: :user, text: "hi", streaming: false}]

      assert Transcript.finalize_streaming(transcript) == transcript
      assert Transcript.finalize_streaming([]) == []
      assert Transcript.finalize_streaming(nil) == []
    end
  end

  describe "close_streaming/1" do
    test "finalizes a non-empty streaming entry, text untouched" do
      transcript = [
        Transcript.entry(:assistant, "done"),
        Transcript.entry(:assistant, "live", streaming: true)
      ]

      assert [%{text: "done", streaming: false}, %{text: "live", streaming: false}] =
               Transcript.close_streaming(transcript)
    end

    test "removes an EMPTY streaming entry instead of finalizing it" do
      transcript = [
        Transcript.entry(:user, "hi"),
        Transcript.entry(:assistant, "", streaming: true)
      ]

      assert [%{role: :user, text: "hi", streaming: false}] =
               Transcript.close_streaming(transcript)

      # The pulsing-dots placeholder a send opens disappears entirely.
      assert Transcript.close_streaming(Transcript.put_streaming_text([], "")) == []
    end

    test "a transcript with no streaming entry comes back normalized and unchanged" do
      transcript = [%{id: "a", role: :user, text: "hi", streaming: false}]

      assert Transcript.close_streaming(transcript) == transcript
    end

    test "it is total on junk input" do
      for input <- [nil, :junk, "str", %{}, 42] do
        assert Transcript.close_streaming(input) == []
      end
    end
  end

  describe "tool entries" do
    test "tool_entry/4 builds a non-streaming :tool entry with its call fields" do
      entry = Transcript.tool_entry("bash", "c1", :running, 2)

      assert %{
               role: :tool,
               text: "",
               streaming: false,
               reasoning: [],
               tool_name: "bash",
               tool_call_id: "c1",
               tool_status: :running,
               turn: 2
             } = entry

      assert is_binary(entry.id)
    end

    test "tool_entry/4 is total: garbage name/turn/status degrade" do
      for name <- [nil, 42, :bash] do
        assert Transcript.tool_entry(name, "c1", :ok, 1).tool_name == nil
      end

      for turn <- [nil, "2", 2.0] do
        assert Transcript.tool_entry("bash", "c1", :ok, turn).turn == nil
      end

      for status <- [:bogus, "ok", nil] do
        assert Transcript.tool_entry("bash", "c1", status, 1).tool_status == nil
      end
    end

    test "put_tool_status/3 targets the tool entry of a call id" do
      transcript =
        Transcript.new()
        |> Transcript.append(Transcript.tool_entry("bash", "c1", :running, 1))
        |> Transcript.append(Transcript.tool_entry("read", "c2", :running, 1))

      assert [%{tool_status: :ok}, %{tool_status: :running}] =
               Transcript.put_tool_status(transcript, "c1", :ok)

      # The MOST RECENT match wins when a call id repeats.
      transcript =
        Transcript.append(transcript, Transcript.tool_entry("bash", "c1", :running, 2))

      assert [_, _, %{tool_status: :error}] = Transcript.put_tool_status(transcript, "c1", :error)
    end

    test "a nil call id targets the most recent still-running entry" do
      transcript =
        Transcript.new()
        |> Transcript.append(Transcript.tool_entry("bash", nil, :running, 1))
        |> Transcript.append(Transcript.tool_entry("read", nil, :timeout, 1))

      assert [%{tool_status: :ok}, %{tool_status: :timeout}] =
               Transcript.put_tool_status(transcript, nil, :ok)
    end

    test "an unmatched call id or a tool-free transcript is returned unchanged" do
      transcript = [Transcript.tool_entry("bash", "c1", :running, 1)]

      assert Transcript.put_tool_status(transcript, "missing", :ok) ==
               Transcript.normalize(transcript)

      chat_only = [Transcript.entry(:user, "hi")]

      assert Transcript.put_tool_status(chat_only, nil, :ok) ==
               Transcript.normalize(chat_only)
    end

    test "the :tool role and its carried fields survive normalize/1" do
      entry = Transcript.tool_entry("bash", {:call, 1}, :ok, 3)

      assert [normalized] = Transcript.normalize([entry])
      assert normalized == entry

      # String-keyed tool fields are picked up like string-keyed `:reasoning`
      # (the base entry fields stay atom-keyed, as before).
      [restored] =
        Transcript.normalize([
          %{
            "tool_name" => "bash",
            "tool_call_id" => "c1",
            "tool_status" => :error,
            "turn" => 2,
            id: "t1",
            role: "tool",
            text: "",
            streaming: false
          }
        ])

      assert %{
               id: "t1",
               role: :tool,
               tool_name: "bash",
               tool_call_id: "c1",
               tool_status: :error,
               turn: 2
             } = restored
    end

    test "legacy entries never grow tool keys for free" do
      [plain] = Transcript.normalize([%{id: "a", role: :assistant, text: "x"}])

      for key <- [:tool_name, :tool_call_id, :tool_status, :turn] do
        refute Map.has_key?(plain, key)
      end
    end

    test "a non-whitelisted persisted tool status degrades to nil" do
      [entry] =
        Transcript.normalize([
          %{id: "t1", role: "tool", tool_name: 42, tool_status: "bogus", turn: "3"}
        ])

      assert {entry.role, entry.tool_name, entry.tool_status, entry.turn} ==
               {:tool, nil, nil, nil}
    end
  end

  describe "conversation-memory preamble" do
    test "tool entries are skipped by build_preamble/2" do
      transcript = [
        Transcript.entry(:user, "hi"),
        Transcript.entry(:tool, "raw tool output"),
        Transcript.entry(:assistant, "hello")
      ]

      assert {:ok, preamble} = Transcript.build_preamble(transcript)
      assert preamble =~ "User: hi"
      assert preamble =~ "Assistant: hello"
      refute preamble =~ "raw tool output"
    end
  end
end
