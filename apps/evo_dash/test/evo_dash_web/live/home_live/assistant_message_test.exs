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
      thought_process: Keyword.get(opts, :thought_process, []),
      # Per-message raw flag (ephemeral HomeLive UI state; default false).
      raw: Keyword.get(opts, :raw, false)
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
      # The pulsing-dots pill is a placeholder — no hover action group.
      refute html =~ "toggle_assistant_raw"
      refute html =~ "assistant-copy-"
      refute html =~ "group-hover/assistant:opacity-100"
    end

    test "finalized markdown entries render .md-content with the rendered html" do
      html =
        render_card(entry: %{id: "1", role: :assistant, text: "**bold** text", streaming: false})

      # The finalized text renders through EvoDash.MarkdownRender: a .md-content
      # container holding the rendered <strong>. (Do NOT refute the raw
      # "**bold**" on the WHOLE html — the copy button's data-content
      # legitimately carries the raw source text — assert the rendered tag.)
      assert html =~ "md-content"

      assert html
             |> Floki.parse_document!()
             |> Floki.find(".md-content strong")
             |> Floki.text() == "bold"
    end

    test "raw: true shows the literal source text without the markdown render" do
      html =
        render_card(
          entry: %{id: "1", role: :assistant, text: "**bold** text", streaming: false},
          raw: true
        )

      # Plain (HTML-escaped) source text in the body, no .md-content, and no
      # rendered <strong> element anywhere in the message body.
      assert html =~ "**bold** text"
      refute html =~ "md-content"
      refute html =~ "<strong>"
    end

    test "streaming entries with text render plain raw text, never markdown, no action group" do
      html =
        render_card(entry: %{id: "1", role: :assistant, text: "partial **md**", streaming: true})

      # Streaming text is NEVER markdown-rendered (a half-rendered stream would
      # flicker — the markdown render kicks in only when the entry finalizes):
      # the literal source text + the blinking caret, no .md-content.
      assert html =~ "partial **md**"
      assert html =~ "help-caret"
      refute html =~ "md-content"
      refute html =~ "<strong>"

      # No hover action group mid-stream (nothing to toggle/copy yet).
      refute html =~ "toggle_assistant_raw"
      refute html =~ "assistant-copy-"
      refute html =~ "group-hover/assistant:opacity-100"
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

  describe "action group (raw toggle + copy)" do
    test "finalized entries render the hover-revealed action group with both buttons" do
      html =
        render_card(entry: %{id: "2", role: :assistant, text: "done **md**", streaming: false})

      # Hover-reveal container at the card's bottom-right corner (opacity-0 →
      # visible on group hover).
      assert html =~ "absolute bottom-1.5 right-1.5"
      assert html =~ "opacity-0"
      assert html =~ "group-hover/assistant:opacity-100"

      # (a) per-message raw/markdown toggle carrying the entry id.
      assert html =~ ~s(phx-click="toggle_assistant_raw")
      assert html =~ ~s(phx-value-id="2")

      # (b) copy-whole-text button: unique id + the global ClipboardCopy hook +
      # data-content carrying the FULL entry text.
      assert html =~ ~s(id="assistant-copy-2")
      assert html =~ ~s(phx-hook="ClipboardCopy")
      assert html =~ ~s(data-content="done **md**")
    end

    test "the copy button's data-content HTML-escapes the full entry text" do
      html =
        render_card(
          entry: %{id: "3", role: :assistant, text: ~s(a <b> & "quote"), streaming: false}
        )

      # data-content is an attribute → HTML-escaped so the attribute value stays
      # intact (the ClipboardCopy hook reads it back verbatim).
      assert html =~ ~s(data-content="a &lt;b&gt; &amp; &quot;quote&quot;")
    end
  end
end
