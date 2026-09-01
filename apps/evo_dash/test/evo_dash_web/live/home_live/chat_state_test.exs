defmodule EvoDashWeb.HomeLive.ChatStateTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.ChatState
  alias EvoDashWeb.HomeLive.Transcript

  # Unit tests for the persisted chat-state shape (ChatState.build/1 →
  # persist, ChatState.restore/1 → mount). Both directions are TOTAL:
  # persisted garbage degrades to safe defaults, never raises.

  describe "build/1" do
    test "extracts every persisted field from assigns" do
      entry = Transcript.entry(:user, "hi")
      tp = %{turn: 1, timestamp: 1_700_000_000, type: "tool", data: %{content: "r"}}

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
        thought_process: [tp]
      }

      assert ChatState.build(assigns) == %{
               transcript: [entry],
               chat_draft: "draft",
               chat_status: :running,
               chat_task_id: "t1",
               chat_agent_id: 7,
               agent_message_count: 3,
               chat_task_status: :running,
               chat_node: :node@host,
               selected_model_id: "profile-a",
               thought_process: [tp]
             }
    end

    test "missing keys degrade to safe defaults" do
      assert ChatState.build(%{}) == %{
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
    end

    test "nil values fall back via || guards" do
      state =
        ChatState.build(%{
          transcript: nil,
          chat_draft: nil,
          chat_status: nil,
          thought_process: nil
        })

      assert state.transcript == []
      assert state.chat_draft == ""
      assert state.chat_status == :idle
      assert state.thought_process == []
      assert state.chat_task_id == nil
      assert state.chat_agent_id == nil
    end
  end

  describe "restore/1" do
    test "restores a fully-populated state map" do
      entry = Transcript.entry(:assistant, "text")
      tp = %{turn: 1, timestamp: 1_700_000_000, type: "tool", data: %{content: "r"}}

      restored =
        ChatState.restore(%{
          transcript: [entry],
          chat_draft: "draft",
          chat_status: :cancelling,
          chat_task_id: "t1",
          chat_agent_id: 7,
          agent_message_count: 2,
          chat_task_status: :cancelling,
          chat_node: :node@host,
          thought_process: [tp]
        })

      assert restored.transcript == [entry]
      assert restored.chat_draft == "draft"
      assert restored.chat_status == :cancelling
      assert restored.chat_task_id == "t1"
      assert restored.chat_agent_id == 7
      assert restored.agent_message_count == 2
      assert restored.chat_task_status == :cancelling
      assert restored.chat_node == :node@host
      assert restored.thought_process == [tp]
    end

    test "non-map state restores as the empty default" do
      for garbage <- [nil, "x", 42, [:a], %{}] do
        restored = ChatState.restore(garbage)

        assert restored.transcript == []
        assert restored.chat_draft == ""
        assert restored.chat_status == :idle
        assert restored.chat_task_id == nil
        assert restored.chat_agent_id == nil
        assert restored.agent_message_count == nil
        assert restored.chat_task_status == nil
        assert restored.chat_node == nil
        assert restored.thought_process == []
      end
    end

    test "malformed fields degrade per key" do
      restored =
        ChatState.restore(%{
          transcript: "not a list",
          chat_draft: 42,
          chat_status: :bogus,
          chat_task_id: 42,
          chat_agent_id: "kept-as-is",
          agent_message_count: -1,
          chat_task_status: :weird,
          chat_node: "not-an-atom",
          thought_process: "nope"
        })

      assert restored.transcript == []
      assert restored.chat_draft == ""
      assert restored.chat_status == :idle
      assert restored.chat_task_id == nil
      # chat_agent_id is deliberately NOT validated (arbitrary term).
      assert restored.chat_agent_id == "kept-as-is"
      assert restored.agent_message_count == nil
      assert restored.chat_task_status == nil
      assert restored.chat_node == nil
      assert restored.thought_process == []
    end

    test "empty-string task id degrades to nil" do
      assert ChatState.restore(%{chat_task_id: ""}).chat_task_id == nil
      assert ChatState.restore(%{chat_task_id: "ok"}).chat_task_id == "ok"
    end

    test "transcript entries are normalized (non-binary ids, string roles, non-maps dropped)" do
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
      assert e1.id == "7"
      assert e1.role == :user
      assert e1.text == "123"
      assert e1.streaming == false

      # Unknown roles keep the entry visible, left-aligned.
      assert e2.role == :assistant
      assert e2.text == ""

      # nil id gets a fresh unique id.
      assert e3.id != ""
      assert e3.role == :assistant
    end

    test "thought_process entries are filtered and normalized" do
      restored =
        ChatState.restore(%{
          thought_process: [
            %{turn: "x", type: :tool, data: %{k: 1}},
            :junk,
            %{turn: 3, type: "assistant", data: "bad"}
          ]
        })

      assert restored.thought_process == [
               %{turn: 0, timestamp: nil, type: "tool", data: %{k: 1}},
               %{turn: 3, timestamp: nil, type: "assistant", data: %{}}
             ]
    end

    test "selected_model_id round-trips through restore" do
      assert ChatState.restore(%{selected_model_id: "p1"}).selected_model_id == "p1"
      assert ChatState.restore(%{selected_model_id: ""}).selected_model_id == nil
      assert ChatState.restore(%{selected_model_id: nil}).selected_model_id == nil
      assert ChatState.restore(%{}).selected_model_id == nil
    end
  end

  describe "normalize_model_id/1" do
    test "nil normalizes to nil (Auto)" do
      assert ChatState.normalize_model_id(nil) == nil
    end

    test "empty string normalizes to nil (Auto)" do
      assert ChatState.normalize_model_id("") == nil
    end

    test "non-binary values normalize to nil" do
      assert ChatState.normalize_model_id(42) == nil
    end

    test "non-empty binary is kept as-is" do
      assert ChatState.normalize_model_id("profile-a") == "profile-a"
    end

    test "whitespace-only binary is kept as-is (not trimmed)" do
      # Auto is the empty string from the select; whitespace ids are not
      # trimmed by design — a whitespace-only binary IS a non-empty binary.
      assert ChatState.normalize_model_id("  ") == "  "
    end
  end
end
