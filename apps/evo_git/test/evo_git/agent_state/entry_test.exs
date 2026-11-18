defmodule EvoGit.AgentState.EntryTest do
  @moduledoc """
  PURE coverage for `EvoGit.AgentState.Entry`: entry validation
  (`normalize/1`) and the arithmetic the writer uses to turn a queue of
  checkpoints for ONE run into the minimal ordered list of store operations
  (`fold/1`).

  No processes, no store and no app-env mutation are involved — the module is
  pure by design — hence `async: true` with no `:tmp_dir` tag.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentState.Entry

  ## Fixtures

  defp message(text) do
    %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text(text)]}
  end

  defp messages(texts), do: Enum.map(texts, &message/1)

  defp rewrite(texts, fields \\ %{}, owner \\ nil) do
    %{kind: :rewrite, base_seq: nil, messages: messages(texts), fields: fields, owner: owner}
  end

  defp append(base_seq, texts, fields \\ %{}, owner \\ nil) do
    %{kind: :append, base_seq: base_seq, messages: messages(texts), fields: fields, owner: owner}
  end

  ## normalize/1

  describe "normalize/1" do
    test "accepts the documented atom-keyed shape and defaults fields/owner" do
      messages = messages(["a"])

      assert {:ok,
              %{
                kind: :append,
                base_seq: 2,
                messages: ^messages,
                fields: %{},
                owner: nil
              }} = Entry.normalize(%{kind: :append, base_seq: 2, messages: messages})

      # `nil` base_seq (means 0), supplied fields and an owner are kept.
      assert {:ok, %{kind: :append, base_seq: nil, fields: %{turn: 1}, owner: owner}} =
               Entry.normalize(%{
                 kind: :append,
                 messages: messages,
                 fields: %{turn: 1},
                 owner: self()
               })

      assert owner == self()

      assert {:ok, %{kind: :rewrite, base_seq: nil}} =
               Entry.normalize(%{kind: :rewrite, messages: messages})
    end

    test "rejects every malformed shape" do
      message = message("a")

      for entry <- [
            :not_a_map,
            nil,
            [],
            %{kind: :bogus, messages: []},
            %{kind: :append},
            %{kind: :append, messages: "not a list"},
            %{kind: :append, messages: ["not a message"]},
            %{kind: :append, messages: [message, "mixed"]},
            %{kind: :append, base_seq: -1, messages: [message]},
            %{kind: :append, base_seq: 1.5, messages: [message]},
            %{kind: :append, messages: [message], fields: "not a map"},
            %{kind: :append, messages: [message], fields: [turn: 1]}
          ] do
        assert Entry.normalize(entry) == :error, "expected :error for #{inspect(entry)}"
      end
    end
  end

  ## fold/1

  describe "fold/1" do
    test "an empty queue folds to []" do
      assert Entry.fold([]) == []
      assert Entry.fold(:not_a_list) == []
    end

    test "N queued rewrites collapse into ONE rewrite carrying the LAST content" do
      ops = Entry.fold([rewrite(["a"]), rewrite(["b", "c"]), rewrite(["d"])])

      assert [%{kind: :rewrite, base_seq: nil, messages: folded}] = ops
      assert folded == messages(["d"])
    end

    test "chained appends fold into ONE append with the first base_seq and the concatenated tail" do
      ops = Entry.fold([append(4, ["a"]), append(5, ["b"]), append(6, ["c", "d"])])

      assert [%{kind: :append, base_seq: 4, messages: folded}] = ops
      assert folded == messages(["a", "b", "c", "d"])
    end

    test "a nil base_seq is 0, so an append at 1 chains onto it" do
      ops = Entry.fold([append(nil, ["a"]), append(1, ["b"])])

      assert [%{kind: :append, base_seq: nil, messages: folded}] = ops
      assert folded == messages(["a", "b"])
    end

    test "a rewrite followed by chained appends stays ONE rewrite" do
      ops = Entry.fold([rewrite(["a", "b"]), append(2, ["c"]), append(3, ["d", "e"])])

      assert [%{kind: :rewrite, messages: folded}] = ops
      assert folded == messages(["a", "b", "c", "d", "e"])
    end

    test "a continuity GAP keeps the operations SEPARATE and in order" do
      ops = Entry.fold([append(0, ["a"]), append(5, ["b"]), append(6, ["c"])])

      assert [
               %{kind: :append, base_seq: 0, messages: first},
               %{kind: :append, base_seq: 5, messages: second}
             ] = ops

      assert first == messages(["a"])
      assert second == messages(["b", "c"])
    end

    test "an append at or below a rewrite's end does not chain" do
      ops =
        Entry.fold([rewrite(["a", "b", "c"]), append(1, ["d"]), rewrite(["e"]), append(9, ["f"])])

      assert [
               %{kind: :rewrite, messages: first},
               %{kind: :append, base_seq: 9, messages: second}
             ] = ops

      assert first == messages(["e"])
      assert second == messages(["f"])
    end

    test "fields merge LAST-WINS and are carried across a superseding rewrite" do
      ops =
        Entry.fold([
          append(0, ["a"], %{turn: 1, usage: "old"}),
          append(1, ["b"], %{usage: "new"}),
          rewrite(["c"], %{phase: "thinking"})
        ])

      assert [%{kind: :rewrite, fields: fields}] = ops
      assert fields == %{turn: 1, usage: "new", phase: "thinking"}
    end

    test "each surviving operation carries the merge accumulated through its own group" do
      ops = Entry.fold([append(0, ["a"], %{turn: 1}), append(9, ["b"], %{phase: "x"})])

      assert [
               %{base_seq: 0, fields: first_fields},
               %{base_seq: 9, fields: second_fields}
             ] = ops

      assert first_fields == %{turn: 1}
      assert second_fields == %{turn: 1, phase: "x"}
    end

    test "owner is the last NON-NIL owner" do
      pid = spawn(fn -> :ok end)

      assert [%{owner: nil}] = Entry.fold([rewrite(["a"])])
      assert [%{owner: ^pid}] = Entry.fold([rewrite(["a"], %{}, pid), rewrite(["b"])])

      assert [%{owner: last}] =
               Entry.fold([rewrite(["a"], %{}, pid), rewrite(["b"], %{}, self())])

      assert last == self()
    end

    test "entries the module cannot interpret are ignored (fold stays total)" do
      ops = Entry.fold([:garbage, %{kind: :bogus, messages: []}, rewrite(["a"]), %{}])

      assert [%{kind: :rewrite, messages: folded}] = ops
      assert folded == messages(["a"])
    end
  end
end
