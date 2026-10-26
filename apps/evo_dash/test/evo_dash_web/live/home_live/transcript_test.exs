defmodule EvoDashWeb.HomeLive.TranscriptTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.Transcript

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
end
