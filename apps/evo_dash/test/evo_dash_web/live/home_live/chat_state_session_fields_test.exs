defmodule EvoDashWeb.HomeLive.ChatStateSessionFieldsTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.ChatState

  # Focused unit coverage for the interactive-session fields ChatState persists:
  # `session_id` (the session agent id, which also doubles as the chat id),
  # `session_mode` (:interactive | :one_shot | nil) and `queued_echoes` (the
  # transient "queued for the next turn boundary" echoes, newest 20 kept).
  #
  # build/1 is a pure extractor; restore/1 owns every validation, including the
  # queued-echo caps. Both directions are total and never raise.

  describe "session_id" do
    test "a positive integer agent id round-trips through build/1 → restore/1" do
      for id <- [1, 7, 4_294_967_296] do
        state = ChatState.build(%{session_id: id})
        assert state.session_id == id
        assert ChatState.restore(state).session_id == id
        # It doubles as the ChatHistory chat id, so a string form must never
        # sneak back in.
        assert is_integer(ChatState.restore(state).session_id)
      end
    end

    test "0, negatives, strings and nil degrade to nil" do
      for bad <- [0, -1, -7, "7", "", 7.0, :seven, nil] do
        assert ChatState.restore(%{session_id: bad}).session_id == nil,
               "expected nil for #{inspect(bad)}"
      end

      assert ChatState.restore(%{}).session_id == nil
      assert ChatState.build(%{}).session_id == nil
    end
  end

  describe "session_mode" do
    test "both session modes round-trip" do
      for mode <- [:interactive, :one_shot] do
        state = ChatState.build(%{session_mode: mode})
        assert state.session_mode == mode
        assert ChatState.restore(state).session_mode == mode
      end
    end

    test "unknown spellings degrade to nil" do
      for bad <- [:oneshot, :one_off, :"one-shot", "interactive", "one_shot", nil, 1] do
        assert ChatState.restore(%{session_mode: bad}).session_mode == nil,
               "expected nil for #{inspect(bad)}"
      end

      assert ChatState.restore(%{}).session_mode == nil
      assert ChatState.build(%{}).session_mode == nil
    end
  end

  describe "queued_echoes" do
    test "order is preserved and each echo restores to exactly id/text/at" do
      echoes = [
        %{id: "3", text: "third", at: 300},
        %{id: "1", text: "first", at: 100},
        %{id: "2", text: "second", at: 200, extra: :dropped}
      ]

      assert ChatState.restore(%{queued_echoes: echoes}).queued_echoes == [
               %{id: "3", text: "third", at: 300},
               %{id: "1", text: "first", at: 100},
               %{id: "2", text: "second", at: 200}
             ]
    end

    test "non-map entries and entries without a binary id are dropped" do
      echoes = [
        %{id: "1", text: "kept", at: 1},
        :junk,
        "junk",
        nil,
        [%{id: "dropped"}],
        %{text: "missing id"},
        %{id: nil, text: "nil id"},
        %{id: 7, text: "integer id"},
        # A blank string IS a binary id, so it survives (the page never mints
        # one, but restore only validates shape).
        %{id: "", text: "blank id"},
        %{id: "2", text: "also kept", at: 2}
      ]

      assert ChatState.restore(%{queued_echoes: echoes}).queued_echoes == [
               %{id: "1", text: "kept", at: 1},
               %{id: "", text: "blank id", at: nil},
               %{id: "2", text: "also kept", at: 2}
             ]
    end

    test "text is coerced to a binary and at stays opaque" do
      for text <- [nil, 42, :atom, [:a], %{k: 1}] do
        assert ChatState.restore(%{queued_echoes: [%{id: "a", text: text}]}).queued_echoes ==
                 [%{id: "a", text: "", at: nil}],
               "expected a blank text for #{inspect(text)}"
      end

      assert ChatState.restore(%{queued_echoes: [%{id: "a"}]}).queued_echoes ==
               [%{id: "a", text: "", at: nil}]

      # A binary text (blank included) is kept verbatim.
      assert ChatState.restore(%{queued_echoes: [%{id: "a", text: ""}]}).queued_echoes ==
               [%{id: "a", text: "", at: nil}]

      assert ChatState.restore(%{queued_echoes: [%{id: "a", text: "hi"}]}).queued_echoes ==
               [%{id: "a", text: "hi", at: nil}]

      # `at` is opaque: any term survives identity-preserving.
      at = {:monotonic, [1, 2]}
      [echo] = ChatState.restore(%{queued_echoes: [%{id: "a", text: "hi", at: at}]}).queued_echoes
      assert echo.at == at
    end

    test "more than 20 input echoes keep the newest 20 in order" do
      echoes = for i <- 1..25, do: %{id: Integer.to_string(i), text: "m#{i}", at: i}

      kept = ChatState.restore(%{queued_echoes: echoes}).queued_echoes
      assert length(kept) == 20
      assert Enum.map(kept, & &1.id) == Enum.map(6..25, &Integer.to_string/1)
      assert List.first(kept).text == "m6"
      assert List.last(kept).text == "m25"
      refute Enum.any?(kept, &(&1.text in ["m1", "m5"]))
    end

    test "garbage degrades to []" do
      for garbage <- [nil, "x", 42, %{}, %{id: "a"}, [:a]] do
        assert ChatState.restore(%{queued_echoes: garbage}).queued_echoes == [],
               "expected [] for #{inspect(garbage)}"
      end

      assert ChatState.restore(%{}).queued_echoes == []
      assert ChatState.build(%{}).queued_echoes == []
    end

    test "build/1 persists echoes verbatim; restore/1 owns all validation" do
      echoes = [%{id: "a", text: "hi", at: 1}, :junk]

      assert ChatState.build(%{queued_echoes: echoes}).queued_echoes == echoes

      assert ChatState.restore(ChatState.build(%{queued_echoes: echoes})).queued_echoes ==
               [%{id: "a", text: "hi", at: 1}]
    end
  end
end
