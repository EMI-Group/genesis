defmodule EvoDashWeb.HomeLive.TranscriptTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.Transcript

  # Unit tests for Transcript.normalize/1 — the mount-direction guard that
  # coerces arbitrary persisted transcript data into the current entry shape.
  # Total: non-lists, non-map entries, non-binary ids, unknown roles, missing
  # keys, and non-boolean streaming flags all degrade instead of crashing.

  describe "normalize/1" do
    test "non-lists normalize to []" do
      for input <- [nil, "x", 42, %{}] do
        assert Transcript.normalize(input) == []
      end
    end

    test "non-map entries are dropped" do
      assert length(
               Transcript.normalize([%{id: "1", role: :user, text: "hi"}, :junk, "str", nil])
             ) == 1
    end

    test "non-binary ids are coerced; nil ids get fresh unique ids" do
      [e1, e2, e3] =
        Transcript.normalize([
          %{id: 7, role: :user, text: "a"},
          %{id: nil, role: :user, text: "b"},
          %{role: :user, text: "c"}
        ])

      assert e1.id == "7"
      assert e2.id != ""
      assert e3.id != ""
      assert e2.id != e3.id
    end

    test "unknown roles fall back to :assistant (kept visible, left-aligned)" do
      [e] = Transcript.normalize([%{role: :bogus, text: "x"}])
      assert e.role == :assistant
    end

    test "string roles are whitelisted" do
      [u, a, e] =
        Transcript.normalize([
          %{role: "user", text: "1"},
          %{role: "assistant", text: "2"},
          %{role: "error", text: "3"}
        ])

      assert u.role == :user
      assert a.role == :assistant
      assert e.role == :error
    end

    test "missing/absent keys degrade" do
      [e] = Transcript.normalize([%{}])
      assert e.text == ""
      assert e.role == :assistant
      assert e.streaming == false
      assert is_binary(e.id)
    end

    test "streaming is boolean-ized (true only for exactly true)" do
      [e1, e2, e3] =
        Transcript.normalize([
          %{streaming: true, text: "a"},
          %{streaming: "yes", text: "b"},
          %{streaming: false, text: "c"}
        ])

      assert e1.streaming == true
      assert e2.streaming == false
      assert e3.streaming == false
    end

    test "text is coerced to a binary" do
      [e] = Transcript.normalize([%{text: 123}])
      assert e.text == "123"

      [e2] = Transcript.normalize([%{text: nil}])
      assert e2.text == ""
    end

    test "valid entries pass through unchanged" do
      entry = %{id: "abc", role: :error, text: "boom", streaming: false}
      assert Transcript.normalize([entry]) == [entry]
    end
  end
end
