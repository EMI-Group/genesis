defmodule EvoDashWeb.HomeLive.MessagesTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.Messages

  # Unit tests for the total message-conversion helpers behind the assistant
  # bubble + thought-process section. The history payload crosses an
  # async/RPC boundary and its shape is owned by the :evo_git core — every
  # function must degrade on nil/string/[]/thinking content, missing keys,
  # and nil metadata, never raise.
  #
  # Pinned behavior notes (verified identical to the pre-rework module):
  # - message_text/1 joins the :text of EVERY map part (including
  #   %{type: :thinking, text: _} parts) plus plain binary parts.
  # - assistant_message?/1 reads only the ATOM :role key — string-KEYED plain
  #   maps are not recognized (real payloads are %ReqLLM.Message{} structs).
  # - role_type/1 on nil yields "nil" (Atom.to_string/1) — benign degradation.

  describe "assistant_text/1" do
    test "joins the text of every assistant message, one per line" do
      messages = [
        %{role: :system, content: [%{text: "system prompt"}]},
        %{role: :user, content: [%{text: "user echo"}]},
        %{role: :assistant, content: [%{text: "first"}]},
        %{role: :assistant, content: [%{text: "second"}]}
      ]

      assert Messages.assistant_text(messages) == "first\nsecond"
    end

    test "empty-content assistants are skipped; thinking parts still contribute their text" do
      assert Messages.assistant_text([%{role: :assistant, content: []}]) == ""
      # Thinking content parts carry :text and ARE joined (pre-rework behavior).
      assert Messages.assistant_text([
               %{role: :assistant, content: [%{type: :thinking, text: "think"}]}
             ]) == "think"

      assert Messages.assistant_text([
               %{role: :assistant, content: [%{type: :thinking, text: "think"}]},
               %{role: :assistant, content: [%{text: "visible"}]}
             ]) == "think\nvisible"
    end

    test "string-KEYED maps are not recognized (atom :role key only)" do
      assert Messages.assistant_text([%{"role" => "assistant", "content" => "text"}]) == ""
    end

    test "non-list input degrades to the empty string" do
      for input <- [nil, "x", 42, %{}] do
        assert Messages.assistant_text(input) == ""
      end
    end
  end

  describe "message_text/1" do
    test "plain binary content passes through" do
      assert Messages.message_text(%{content: "plain"}) == "plain"
    end

    test "content-part lists join the :text of every map part plus binary parts" do
      # :thinking maps and raw binaries both contribute — pinned actual behavior.
      assert Messages.message_text(%{
               content: [
                 %{text: "a"},
                 %{type: :thinking, text: "think"},
                 %{text: "b"},
                 "bin",
                 :junk,
                 %{}
               ]
             }) == "athinkbbin"
    end

    test "thinking-only messages contribute their thinking text" do
      assert Messages.message_text(%{content: [%{type: :thinking, text: "think"}]}) == "think"
    end

    test "nil/absent/malformed content is empty" do
      assert Messages.message_text(%{}) == ""
      assert Messages.message_text(%{content: nil}) == ""
      assert Messages.message_text(%{content: 42}) == ""
      assert Messages.message_text(nil) == ""
      assert Messages.message_text("not a map") == ""
    end
  end

  describe "to_entries/1" do
    test "maps real ReqLLM.Message structs to the entry format" do
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
      assert entry.turn == 2
      assert entry.timestamp == 1_700_000_000
      assert entry.data.content == "hi"
      assert entry.data.tool_calls == [tool_call]
      assert entry.data.reasoning_details == reasoning
      assert entry.data.tool_name == "x"
      assert entry.data.metadata == metadata
    end

    test "atom-keyed plain maps are converted (missing keys degrade)" do
      [entry] = Messages.to_entries([%{role: :tool, content: "result", name: "n"}])

      assert entry.type == "tool"
      assert entry.turn == 0
      assert entry.timestamp == nil
      assert entry.data.content == "result"
      assert entry.data.tool_name == "n"
      assert entry.data.metadata == %{}
    end

    test "string-KEYED plain maps degrade to a nil type (atom :role key only)" do
      [entry] = Messages.to_entries([%{"role" => "tool", "content" => "result", "name" => "n"}])

      assert entry.type == "nil"
      # content is read via the atom :content key too — string keys degrade.
      assert entry.data.content == ""
    end

    test "nil metadata on structs degrades to %{}" do
      msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "hi"}],
        metadata: nil
      }

      [entry] = Messages.to_entries([msg])
      assert entry.turn == 0
      assert entry.timestamp == nil
      assert entry.data.metadata == %{}
    end

    test "string roles keep their text; nil roles degrade to the \"nil\" type" do
      [entry] = Messages.to_entries([%{role: "assistant", content: "x"}])
      assert entry.type == "assistant"

      # Atom.to_string(nil) == "nil" — benign degradation, pinned.
      [entry2] = Messages.to_entries([%{role: nil, content: "x"}])
      assert entry2.type == "nil"
    end

    test "non-map messages are dropped; non-list input is empty" do
      assert length(Messages.to_entries([nil, 42, %{role: :user, content: "x"}])) == 1
      assert Messages.to_entries(nil) == []
      assert Messages.to_entries(%{}) == []
    end
  end
end
