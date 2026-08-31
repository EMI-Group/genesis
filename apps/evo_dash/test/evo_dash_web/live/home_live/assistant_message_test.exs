defmodule EvoDashWeb.HomeLive.AssistantMessageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias EvoDashWeb.HomeLive.AssistantMessage

  # Rendered-HTML tests for the assistant mini task-card (the private
  # status_label/card_border/type_color helpers have no public API — the
  # rendered card IS the contract). All assigns are passed explicitly so the
  # component's total payload access (Map.get-guarded) is what is exercised.

  # The HEEx template emits whitespace inside the Task header span, so the
  # literal ">Task<" never matches — match with a whitespace-tolerant regex.
  defp badge_header?(html), do: html =~ ~r/>\s*Task\s*</s

  defp render_card(opts) do
    render_component(&AssistantMessage.assistant_message/1,
      entry:
        Keyword.get(opts, :entry, %{id: "1", role: :assistant, text: "hi", streaming: false}),
      task_status: Keyword.get(opts, :task_status, nil),
      thought_process: Keyword.get(opts, :thought_process, [])
    )
  end

  defp tool_entry do
    %{
      turn: 2,
      timestamp: 1_700_000_000,
      type: "tool",
      data: %{
        content: "result...",
        tool_name: "spawn_investigator",
        tool_calls: [],
        reasoning_details: []
      }
    }
  end

  defp reasoning_entry do
    %{
      turn: 2,
      timestamp: 1_700_000_000,
      type: "assistant",
      data: %{
        content: "",
        reasoning_details: [%{text: "let me think", index: 0}],
        tool_calls: [],
        tool_name: nil
      }
    }
  end

  describe "text rendering" do
    test "renders the entry text without a badge when task_status is nil" do
      html = render_card([])
      assert html =~ "hi"
      refute html =~ "Task"
      refute html =~ "Thought process"
    end

    test "non-streaming entries render no caret and no pulsing dots" do
      html = render_card(entry: %{id: "1", role: :assistant, text: "done", streaming: false})
      assert html =~ "done"
      refute html =~ "help-caret"
      refute html =~ "animate-bounce"
    end

    test "streaming entries with text render the caret" do
      html = render_card(entry: %{id: "1", role: :assistant, text: "partial", streaming: true})
      assert html =~ "partial"
      assert html =~ "help-caret"
      refute html =~ "animate-bounce"
    end

    test "empty streaming entries render the pulsing dots (and no caret)" do
      html = render_card(entry: %{id: "1", role: :assistant, text: "", streaming: true})
      assert html =~ "animate-bounce"
      refute html =~ "help-caret"
    end

    test "entries with missing text/streaming keys degrade (no crash)" do
      html = render_card(entry: %{role: :assistant})
      refute html =~ "help-caret"
      refute html =~ "animate-bounce"
    end
  end

  describe "task status badge" do
    test "renders the localized label for every known status" do
      labels = %{
        pending: "Pending",
        running: "Running",
        finalizing: "Finalizing",
        cancelling: "Cancelling…",
        completed: "Completed",
        failed: "Failed",
        cancelled: "Cancelled"
      }

      for {status, label} <- labels do
        html = render_card(task_status: status)
        assert badge_header?(html), "expected the Task header for #{inspect(status)}"
        assert html =~ label, "expected label #{inspect(label)} for #{inspect(status)}"
      end
    end

    test "the running badge carries the ping dot; finalizing carries the spinner" do
      assert render_card(task_status: :running) =~ "animate-ping"
      assert render_card(task_status: :finalizing) =~ "loading-spinner"
    end

    test "unknown atom statuses render their raw atom name" do
      html = render_card(task_status: :bogus_status)
      assert html =~ "bogus_status"
    end

    test "non-atom statuses render an empty badge label" do
      html = render_card(task_status: "running")
      assert badge_header?(html)
      refute html =~ "Running"
    end
  end

  describe "thought process" do
    test "renders nothing when thought_process is empty" do
      refute render_card([]) =~ "Thought process"
    end

    test "renders entry types, turns, tool rows, and reasoning text" do
      html =
        render_card(
          thought_process: [
            reasoning_entry(),
            tool_entry(),
            %{turn: "x", timestamp: nil, type: nil, data: nil}
          ]
        )

      assert html =~ "Thought process"
      assert html =~ "(3)"
      # Type labels: assistant + tool entries.
      assert html =~ "assistant"
      assert html =~ "tool"
      # Reasoning text from reasoning_details.
      assert html =~ "let me think"
      # Tool entry: tool name + content.
      assert html =~ "spawn_investigator"
      assert html =~ "result..."
      # Malformed entry degrades to the "message" type label.
      assert html =~ "message"
    end

    test "tool-call rows render via the ToolCallDisplay contract" do
      entry = %{
        turn: 1,
        timestamp: nil,
        type: "assistant",
        data: %{
          content: "",
          tool_calls: [
            %ReqLLM.ToolCall{
              id: "c1",
              type: "function",
              function: %{name: "run_bash", arguments: ~s({"command": "ls"})}
            }
          ],
          reasoning_details: [],
          tool_name: nil
        }
      }

      html = render_card(thought_process: [entry])
      assert html =~ "Shell call"
      assert html =~ "Command"
      assert html =~ "ls"
    end
  end
end
