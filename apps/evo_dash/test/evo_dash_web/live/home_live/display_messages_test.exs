defmodule EvoDashWeb.HomeLive.DisplayMessagesTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.DisplayMessages

  # Unit tests for the chat-transcript projection: the agent's LLM history is
  # NOT a chat log (system prompt, harness injections, tool results), so
  # `bubbles/1` projects it into the ordered bubbles the user actually sees.
  # Fixtures are hand-built %ReqLLM.Message{} structs — no LiveView, no core.
  # Every function must stay TOTAL across the async/RPC boundary whose payload
  # shape is owned by the :evo_git core.

  @wrapped_turn_0 "<context>\nrepo: /tmp/demo\n</context>\n\n---\n\n" <>
                    "<objective>\nFix the bug\n</objective>"

  @refresh_prefix "This is an automatically generated runtime-context refresh."

  describe "bubbles/1 — ordered display projection" do
    test "system messages never produce a bubble" do
      messages = [
        text_message(:system, "You are Genesis."),
        text_message(:user, "hi")
      ]

      assert DisplayMessages.bubbles(messages) == [{:user, "hi"}]
      assert DisplayMessages.bubble(text_message(:system, "You are Genesis.")) == nil
    end

    test "one assistant bubble per assistant message, interleaved chronologically" do
      messages = [
        text_message(:system, "You are Genesis."),
        text_message(:user, "first question"),
        text_message(:assistant, "first answer"),
        text_message(:user, "second question"),
        text_message(:assistant, "second answer")
      ]

      assert DisplayMessages.bubbles(messages) == [
               {:user, "first question"},
               {:assistant, "first answer"},
               {:user, "second question"},
               {:assistant, "second answer"}
             ]
    end

    test "empty and thinking-only assistant messages are skipped; reasoning never leaks" do
      thinking_only = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :thinking, text: "secret reasoning"}]
      }

      empty = %ReqLLM.Message{role: :assistant, content: []}

      mixed = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{type: :thinking, text: "secret reasoning"},
          %ReqLLM.Message.ContentPart{type: :text, text: "visible answer"}
        ]
      }

      assert DisplayMessages.bubbles([thinking_only, empty, mixed]) ==
               [{:assistant, "visible answer"}]

      refute inspect(DisplayMessages.bubbles([thinking_only])) =~ "secret reasoning"
    end

    test "tool role messages never produce a bubble" do
      tool = %ReqLLM.Message{
        role: :tool,
        name: "bash",
        tool_call_id: "c1",
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "tool output"}]
      }

      assert DisplayMessages.bubbles([tool]) == []
      assert DisplayMessages.bubble(tool) == nil

      assert DisplayMessages.bubbles([
               text_message(:user, "ask"),
               tool,
               text_message(:assistant, "answer")
             ]) ==
               [{:user, "ask"}, {:assistant, "answer"}]
    end

    test "genuine plain user text renders verbatim (trimmed)" do
      assert DisplayMessages.bubble(text_message(:user, "Fix the bug")) == {:user, "Fix the bug"}

      assert DisplayMessages.bubble(text_message(:user, "line one\nline two")) ==
               {:user, "line one\nline two"}

      # Surrounding whitespace is trimmed (documented total behavior).
      assert DisplayMessages.bubble(text_message(:user, "  padded  ")) == {:user, "padded"}
    end
  end

  describe "the core's user_authored marker wins when present" do
    test "true keeps a plain user turn and the string key is honored too" do
      assert DisplayMessages.bubble(text_message(:user, "real turn", %{user_authored: true})) ==
               {:user, "real turn"}

      assert DisplayMessages.bubble(text_message(:user, "real turn", %{"user_authored" => true})) ==
               {:user, "real turn"}
    end

    test "true unwraps the turn-0 wrapped body to its objective" do
      message = text_message(:user, @wrapped_turn_0, %{turn: 0, user_authored: true})

      assert DisplayMessages.bubble(message) == {:user, "Fix the bug"}
    end

    test "false drops a turn no matter how user-like its text is" do
      assert DisplayMessages.bubble(
               text_message(:user, "not really mine", %{user_authored: false})
             ) ==
               nil

      assert DisplayMessages.bubble(
               text_message(:user, @wrapped_turn_0, %{"user_authored" => false})
             ) ==
               nil
    end

    test "user_authored?/1 reports the marker and :unknown without one" do
      assert DisplayMessages.user_authored?(text_message(:user, "x", %{user_authored: true})) ==
               true

      assert DisplayMessages.user_authored?(text_message(:user, "x", %{"user_authored" => false})) ==
               false

      assert DisplayMessages.user_authored?(text_message(:user, "x")) == :unknown

      # Only a real boolean counts; junk values fall back to the heuristic.
      assert DisplayMessages.user_authored?(text_message(:user, "x", %{user_authored: "yes"})) ==
               :unknown

      for input <- [nil, :garbage, "x", 42, []] do
        assert DisplayMessages.user_authored?(input) == :unknown
      end
    end
  end

  describe "heuristic fallback when the marker is absent" do
    test "the turn-0 wrapped first message contributes only its objective body" do
      assert DisplayMessages.bubble(text_message(:user, @wrapped_turn_0)) ==
               {:user, "Fix the bug"}
    end

    test "a context-only body contributes nothing" do
      context_only = "<context>\nrepo: /tmp/demo\n</context>"

      assert DisplayMessages.bubble(text_message(:user, context_only)) == nil
    end

    test "compression checkpoints contribute nothing" do
      assert DisplayMessages.bubble(
               text_message(:user, "Summary of the conversation so far", %{checkpoint: true})
             ) == nil

      assert DisplayMessages.bubble(
               text_message(:user, "Summary of the conversation so far", %{"checkpoint" => true})
             ) == nil
    end

    test "every synthetic notice prefix contributes nothing" do
      bodies = [
        "[NOTICE] Background job 7 finished with exit code 0.",
        "[WARNING] You are running low on turns.",
        "[URGENT] Turn budget nearly exhausted.",
        @refresh_prefix <> " SUPERSEDES any earlier <context> snapshot.",
        "You have exceeded your turn budget. Wrap up now.",
        "The task is being cancelled by the user. Save your work."
      ]

      for body <- bodies do
        assert DisplayMessages.bubble(text_message(:user, body)) == nil,
               "expected #{inspect(body)} to be dropped"
      end
    end

    test "plain user text still renders when the marker is absent" do
      assert DisplayMessages.bubbles([
               text_message(:system, "prompt"),
               text_message(:user, "What is running?"),
               text_message(:assistant, "Two tasks.")
             ]) == [{:user, "What is running?"}, {:assistant, "Two tasks."}]
    end
  end

  describe "totality" do
    test "non-list input and malformed messages yield [] — never raises" do
      assert DisplayMessages.bubbles(nil) == []
      assert DisplayMessages.bubbles(:garbage) == []
      assert DisplayMessages.bubbles(%{}) == []
      assert DisplayMessages.bubbles("x") == []
      assert DisplayMessages.bubbles(42) == []

      malformed = [
        nil,
        42,
        :junk,
        %{},
        %{role: :user},
        %{role: :user, content: nil},
        %{role: :user, content: 42},
        %{role: :user, content: [nil, :junk, %{text: 42}]},
        %{role: :unknown_role, content: "text"},
        %{"role" => "user", "content" => "text"}
      ]

      assert DisplayMessages.bubbles(malformed) == []
    end

    test "plain map payloads with atom roles still project; nil metadata is empty" do
      assert DisplayMessages.bubbles([
               %{role: :user, content: "typed", metadata: nil},
               %{role: :assistant, content: [%{text: "answered"}]}
             ]) == [{:user, "typed"}, {:assistant, "answered"}]
    end
  end

  defp text_message(role, text, metadata \\ %{}) do
    %ReqLLM.Message{
      role: role,
      content: [%ReqLLM.Message.ContentPart{type: :text, text: text}],
      metadata: metadata
    }
  end
end
