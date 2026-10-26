defmodule EvoDashWeb.HomeLive.MessagesTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.Messages

  # Unit tests for the total message-conversion helpers behind the assistant
  # bubble. The history payload's shape is owned by the :evo_git core — every
  # function must degrade on nil/string/[]/thinking content, missing keys, and
  # nil metadata. Thinking parts are EXCLUDED from text (reasoning is not
  # response text); only the ATOM :role key is recognized (real payloads are
  # %ReqLLM.Message{} structs); role_type/1 on nil yields "nil" (benign).

  describe "assistant_text/1" do
    test "joins one line per non-empty assistant message, excluding thinking parts" do
      messages = [
        %{role: :system, content: [%{text: "system prompt"}]},
        %{role: :user, content: [%{text: "user echo"}]},
        %{role: :assistant, content: [%{text: "first"}]},
        %{role: :assistant, content: [%{text: "second"}]}
      ]

      assert Messages.assistant_text(messages) == "first\nsecond"

      # Empty content is skipped; thinking parts are reasoning, NOT response text.
      assert Messages.assistant_text([%{role: :assistant, content: []}]) == ""

      assert Messages.assistant_text([
               %{role: :assistant, content: [%{type: :thinking, text: "think"}]}
             ]) == ""

      assert Messages.assistant_text([
               %{role: :assistant, content: [%{type: :thinking, text: "think"}]},
               %{role: :assistant, content: [%{text: "visible"}]}
             ]) == "visible"
    end

    test "string-keyed maps and non-list input degrade to the empty string" do
      assert Messages.assistant_text([%{"role" => "assistant", "content" => "text"}]) == ""

      for input <- [nil, "x", 42, %{}] do
        assert Messages.assistant_text(input) == "", "expected \"\" for #{inspect(input)}"
      end
    end
  end

  describe "message_text/1" do
    test "binary content passes through; nil/absent/malformed content is empty" do
      assert Messages.message_text(%{content: "plain"}) == "plain"

      for input <- [%{}, %{content: nil}, %{content: 42}, nil, "not a map"] do
        assert Messages.message_text(input) == "", "expected \"\" for #{inspect(input)}"
      end
    end

    test "content-part lists join text parts and binaries, excluding thinking parts" do
      # Bare maps (no type) and raw binaries contribute; :thinking maps are
      # EXCLUDED (reasoning is not response text).
      assert Messages.message_text(%{
               content: [
                 %{text: "a"},
                 %{type: :thinking, text: "think"},
                 %{text: "b"},
                 "bin",
                 :junk,
                 %{}
               ]
             }) == "abbin"

      assert Messages.message_text(%{content: [%{type: :thinking, text: "think"}]}) == ""

      # A real :thinking ContentPart is excluded while :text parts contribute.
      assert Messages.message_text(%{
               content: [%ReqLLM.Message.ContentPart{type: :thinking, text: "R"}]
             }) == ""

      assert Messages.message_text(%{
               content: [
                 %ReqLLM.Message.ContentPart{type: :thinking, text: "R"},
                 %ReqLLM.Message.ContentPart{type: :text, text: "visible"}
               ]
             }) == "visible"
    end
  end

  describe "to_entries/1" do
    test "maps real ReqLLM.Message structs; nil metadata degrades to %{}" do
      tool_call = %ReqLLM.ToolCall{
        id: "c1",
        type: "function",
        function: %{name: "run_bash", arguments: "{}"}
      }

      reasoning = [%ReqLLM.Message.ReasoningDetails{text: "think", index: 0}]
      metadata = %{turn: 2, timestamp: 1_700_000_000, tool_name: "x"}

      msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "hi"}],
        tool_calls: [tool_call],
        reasoning_details: reasoning,
        metadata: metadata
      }

      [entry] = Messages.to_entries([msg])

      assert entry.type == "assistant"
      assert {entry.turn, entry.timestamp} == {2, 1_700_000_000}
      assert entry.data.content == "hi"
      assert entry.data.tool_calls == [tool_call]
      assert entry.data.reasoning_details == reasoning
      assert entry.data.tool_name == "x"
      assert entry.data.metadata == metadata

      [bare] = Messages.to_entries([%{msg | metadata: nil}])
      assert {bare.turn, bare.timestamp, bare.data.metadata} == {0, nil, %{}}
    end

    test "plain maps: atom keys convert, string keys/nil roles degrade to the \"nil\" type" do
      [entry] = Messages.to_entries([%{role: :tool, content: "result", name: "n"}])
      assert entry.type == "tool"
      assert {entry.turn, entry.timestamp} == {0, nil}
      assert entry.data.content == "result"
      assert entry.data.tool_name == "n"
      assert entry.data.metadata == %{}

      # Atom :role / :content keys only — string keys degrade.
      [string_keyed] =
        Messages.to_entries([%{"role" => "tool", "content" => "result", "name" => "n"}])

      assert string_keyed.type == "nil"
      assert string_keyed.data.content == ""

      # String ROLES keep their text; Atom.to_string(nil) == "nil" (pinned).
      assert [%{type: "assistant"}] = Messages.to_entries([%{role: "assistant", content: "x"}])
      assert [%{type: "nil"}] = Messages.to_entries([%{role: nil, content: "x"}])

      # Non-map messages are dropped; non-list input is empty.
      assert [%{type: "user"}] = Messages.to_entries([nil, 42, %{role: :user, content: "x"}])
      assert Messages.to_entries(nil) == []
      assert Messages.to_entries(%{}) == []
    end
  end
end
