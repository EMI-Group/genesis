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
end
