defmodule EvoDashWeb.HomeLive.ChatStateTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.ChatState
  alias EvoDashWeb.HomeLive.Transcript

  # Unit tests for the persisted chat-state shape (ChatState.build/1 → persist,
  # ChatState.restore/1 → mount). Both directions are TOTAL: persisted garbage
  # degrades to safe defaults, never raises.

  @default_state %{
    transcript: [],
    chat_draft: "",
    chat_status: :idle,
    chat_task_id: nil,
    chat_agent_id: nil,
    agent_message_count: nil,
    chat_task_status: nil,
    chat_node: nil,
    selected_model_id: nil,
    thought_process: []
  }

  @thought_entry %{turn: 1, timestamp: 1_700_000_000, type: "tool", data: %{content: "r"}}

  describe "build/1" do
    test "extracts every persisted field from assigns" do
      entry = Transcript.entry(:user, "hi")

      assigns = %{
        transcript: [entry],
        chat_draft: "draft",
        chat_status: :running,
        chat_task_id: "t1",
        chat_agent_id: 7,
        agent_message_count: 3,
        chat_task_status: :running,
        chat_node: :node@host,
        selected_model_id: "profile-a",
        thought_process: [@thought_entry]
      }

      assert ChatState.build(assigns) == assigns
    end

    test "missing keys and nil values degrade to the safe defaults" do
      assert ChatState.build(%{}) == @default_state

      assert ChatState.build(%{
               transcript: nil,
               chat_draft: nil,
               chat_status: nil,
               thought_process: nil
             }) == @default_state
    end
  end

  describe "restore/1" do
    test "restores a fully-populated state map unchanged" do
      entry = Transcript.entry(:assistant, "text")

      state = %{
        transcript: [entry],
        chat_draft: "draft",
        chat_status: :cancelling,
        chat_task_id: "t1",
        chat_agent_id: 7,
        agent_message_count: 2,
        chat_task_status: :cancelling,
        chat_node: :node@host,
        selected_model_id: "profile-a",
        thought_process: [@thought_entry]
      }

      assert ChatState.restore(state) == state
    end

    test "non-map state and malformed fields degrade to the empty default per key" do
      for garbage <- [nil, "x", 42, [:a], %{}] do
        assert ChatState.restore(garbage) == @default_state,
               "expected defaults for #{inspect(garbage)}"
      end

      assert ChatState.restore(%{
               transcript: "not a list",
               chat_draft: 42,
               chat_status: :bogus,
               chat_task_id: 42,
               # chat_agent_id is deliberately NOT validated (arbitrary term).
               chat_agent_id: "kept-as-is",
               agent_message_count: -1,
               chat_task_status: :weird,
               chat_node: "not-an-atom",
               thought_process: "nope"
             }) == %{@default_state | chat_agent_id: "kept-as-is"}
    end

    test "empty-string task id degrades to nil; selected_model_id is normalized" do
      assert ChatState.restore(%{chat_task_id: ""}).chat_task_id == nil
      assert ChatState.restore(%{chat_task_id: "ok"}).chat_task_id == "ok"

      for {stored, expected} <- [{"p1", "p1"}, {"", nil}, {nil, nil}] do
        assert ChatState.restore(%{selected_model_id: stored}).selected_model_id == expected
      end

      assert ChatState.restore(%{}).selected_model_id == nil
    end

    test "nested transcript and thought_process entries are normalized" do
      restored =
        ChatState.restore(%{
          transcript: [
            %{id: 7, role: "user", text: 123, streaming: "yes"},
            :junk,
            %{role: :weird, text: nil},
            %{id: nil, role: :assistant, text: "x"}
          ]
        })

      [e1, e2, e3] = restored.transcript
      assert {e1.id, e1.role, e1.text, e1.streaming} == {"7", :user, "123", false}
      # Unknown roles keep the entry visible, left-aligned.
      assert {e2.role, e2.text} == {:assistant, ""}
      # nil id gets a fresh unique id.
      assert e3.id != "" and e3.role == :assistant

      assert ChatState.restore(%{
               thought_process: [
                 %{turn: "x", type: :tool, data: %{k: 1}},
                 :junk,
                 %{turn: 3, type: "assistant", data: "bad"}
               ]
             }).thought_process == [
               %{turn: 0, timestamp: nil, type: "tool", data: %{k: 1}},
               %{turn: 3, timestamp: nil, type: "assistant", data: %{}}
             ]
    end
  end

  describe "normalize_model_id/1" do
    test "non-empty binaries are kept as-is; everything else becomes nil (Auto)" do
      # Auto is the empty string from the select; whitespace ids are NOT trimmed
      # by design — a whitespace-only binary IS a non-empty binary.
      for {input, expected} <- [
            {nil, nil},
            {"", nil},
            {42, nil},
            {"profile-a", "profile-a"},
            {"  ", "  "}
          ] do
        assert ChatState.normalize_model_id(input) == expected,
               "expected #{inspect(expected)} for #{inspect(input)}"
      end
    end
  end
end
