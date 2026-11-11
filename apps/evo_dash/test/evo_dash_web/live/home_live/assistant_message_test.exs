defmodule EvoDashWeb.HomeLive.AssistantMessageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias EvoDashWeb.HomeLive.AgentStream
  alias EvoDashWeb.HomeLive.AssistantMessage
  alias EvoDashWeb.HomeLive.ChatMessages
  alias EvoDashWeb.HomeLive.Transcript

  # Rendered assistant entries pin the answer-first layout, status labels,
  # accessible copy/raw controls and optional thought disclosure.
  # AgentStream.extract_failed_message/1 pins HomeLive's terminal fallback
  # directly because finalize_failed/2 is private.

  @tool_call %ReqLLM.ToolCall{
    id: "c1",
    type: "function",
    function: %{name: "run_bash", arguments: ~s({"command": "ls"})}
  }

  # The HEEx template emits whitespace inside the Task header span, so the
  # literal ">Task<" never matches — match with a whitespace-tolerant regex.
  defp badge_header?(html), do: html =~ ~r/>\s*Task\s*</s

  defp render_card(opts) do
    render_component(&AssistantMessage.assistant_message/1,
      entry:
        Keyword.get(opts, :entry, %{id: "1", role: :assistant, text: "hi", streaming: false}),
      task_status: Keyword.get(opts, :task_status, nil),
      thought_process: Keyword.get(opts, :thought_process, []),
      raw: Keyword.get(opts, :raw, false),
      stream_meta: Keyword.get(opts, :stream_meta)
    )
  end

  defp thought(turn, type, data), do: %{turn: turn, timestamp: nil, type: type, data: data}

  describe "text rendering" do
    test "finalized entries render markdown, normal-flow accessible actions, and no streaming affordances" do
      html =
        render_card(entry: %{id: "2", role: :assistant, text: "**bold** text", streaming: false})

      # No status → no badge; no thought_process → no section.
      refute html =~ "Task"
      refute html =~ "Thought process"

      # Finalized text renders through EvoDash.MarkdownRender. (Do NOT refute the
      # raw "**bold**" on the WHOLE html — the copy button's data-content
      # legitimately carries the raw source — assert the rendered tag.)
      assert html =~ "md-content"

      assert html
             |> Floki.parse_document!()
             |> Floki.find(".md-content strong")
             |> Floki.text() == "bold"

      refute html =~ "help-caret"
      refute html =~ "animate-bounce"

      # Actions reserve their own space below the answer, not an overlay.
      # Pin visibility on touch/mobile AND reveal on desktop hover/keyboard focus.
      doc = Floki.parse_document!(html)
      [footer] = Floki.find(doc, "div[class~='group/assistant'] > div:last-child")
      classes = Floki.attribute([footer], "class") |> hd() |> String.split()

      for class <- [
            "mt-2",
            "flex",
            "py-1",
            "opacity-100",
            "sm:opacity-0",
            "group-hover/assistant:opacity-100",
            "group-focus-within/assistant:opacity-100",
            "[@media(hover:none)]:opacity-100"
          ] do
        assert class in classes
      end

      refute "absolute" in classes
      refute "hidden" in classes
      assert length(Floki.find([footer], "button")) == 2
      assert Floki.attribute(Floki.find([footer], "button[phx-click]"), "phx-value-id") == ["2"]

      assert Floki.attribute(Floki.find([footer], "#assistant-copy-2"), "phx-hook") == [
               "ClipboardCopy"
             ]

      assert Floki.attribute(Floki.find([footer], "#assistant-copy-2"), "data-content") == [
               "**bold** text"
             ]
    end

    test "assistant answers use a borderless reading column before collapsed thoughts and actions" do
      doc =
        render_card(thought_process: [thought(1, "assistant", %{content: "private steps"})])
        |> Floki.parse_document!()

      [column] = Floki.find(doc, "div[class~='group/assistant']")
      classes = Floki.attribute([column], "class") |> hd() |> String.split()
      assert "min-w-0" in classes
      refute Enum.any?(classes, &String.starts_with?(&1, ["border", "rounded", "bg-"]))

      assert Floki.find([column], "div[class~='group/assistant'] > div:first-child .md-content")
             |> Floki.text() == "hi"

      assert length(Floki.find([column], "div[class~='group/assistant'] > details")) == 1

      assert length(Floki.find([column], "div[class~='group/assistant'] > div:last-child button")) ==
               2
    end

    test "copy and raw controls bind to each entry and keep full source in either view" do
      source = "**answer** <tag> & \"quoted\"\n\n" <> String.duplicate("long text ", 200)

      for {id, raw?} <- [{"first", false}, {"second", true}] do
        doc =
          render_card(entry: %{id: id, text: source, streaming: false}, raw: raw?)
          |> Floki.parse_document!()

        [toggle] = Floki.find(doc, "button[phx-click='toggle_assistant_raw']")
        [copy] = Floki.find(doc, "button[phx-hook='ClipboardCopy']")
        label = if raw?, do: "Show rendered markdown", else: "Show raw text"
        icon = if raw?, do: ".hero-document-text", else: ".hero-code-bracket"

        assert Floki.attribute([toggle], "phx-value-id") == [id]
        assert Floki.attribute([toggle], "title") == [label]
        assert Floki.attribute([toggle], "aria-label") == [label]
        assert length(Floki.find([toggle], icon)) == 1
        assert Floki.attribute([copy], "id") == ["assistant-copy-" <> id]
        assert Floki.attribute([copy], "data-content") == [source]
        assert Floki.attribute([copy], "aria-label") == ["Copy message text"]
        assert Floki.attribute([copy], "title") == ["Copy message text"]

        for button <- [toggle, copy] do
          assert Floki.attribute([button], "type") == ["button"]
          classes = Floki.attribute([button], "class") |> hd() |> String.split()
          assert "size-11" in classes
          assert "sm:size-8" in classes
          assert "focus-visible:outline-2" in classes
        end
      end
    end

    test "streaming entries ignore raw mode and never expose finalized actions" do
      for text <- ["", "partial **markdown**"], raw? <- [false, true] do
        doc =
          render_card(entry: %{id: "stream", text: text, streaming: true}, raw: raw?)
          |> Floki.parse_document!()

        assert Floki.find(doc, "button") == []
        assert Floki.find(doc, ".md-content") == []
        assert length(Floki.find(doc, ".help-caret")) == if(text == "", do: 0, else: 1)
        assert length(Floki.find(doc, ".animate-bounce")) == if(text == "", do: 3, else: 0)
      end
    end

    test "streaming entries render plain raw text with the caret and no action group" do
      html =
        render_card(entry: %{id: "1", role: :assistant, text: "partial **md**", streaming: true})

      # Streaming text is NEVER markdown-rendered (a half-rendered stream would
      # flicker; markdown kicks in only when the entry finalizes) and carries no
      # hover action group (nothing to toggle/copy yet).
      assert html =~ "partial **md**"
      assert html =~ "help-caret"
      refute html =~ "animate-bounce"
      refute html =~ "md-content"
      refute html =~ "<strong>"
      refute html =~ "toggle_assistant_raw"
      refute html =~ "assistant-copy-"
      refute html =~ "group-hover/assistant:opacity-100"
    end

    test "empty streaming entries render the pulsing dots; missing keys degrade" do
      dots = render_card(entry: %{id: "1", role: :assistant, text: "", streaming: true})
      assert dots =~ "animate-bounce"
      refute dots =~ "help-caret"
      # The pulsing-dots pill is a placeholder — no hover action group.
      refute dots =~ "toggle_assistant_raw"
      refute dots =~ "assistant-copy-"
      refute dots =~ "group-hover/assistant:opacity-100"

      degraded = render_card(entry: %{role: :assistant})
      refute degraded =~ "help-caret"
      refute degraded =~ "animate-bounce"
    end

    test "raw: true shows the literal source with no markdown; data-content stays escaped" do
      raw_html =
        render_card(
          entry: %{
            id: "3",
            role: :assistant,
            text: ~s(**bold** a <b> & "quote"),
            streaming: false
          },
          raw: true
        )

      # Plain (HTML-escaped) source in the body, no .md-content, no <strong>.
      assert raw_html =~ "**bold** a &lt;b&gt; &amp; &quot;quote&quot;"
      refute raw_html =~ "md-content"
      refute raw_html =~ "<strong>"
      # data-content is an attribute → HTML-escaped so the ClipboardCopy hook
      # reads the attribute value back verbatim.
      assert raw_html =~ ~s(data-content="**bold** a &lt;b&gt; &amp; &quot;quote&quot;")
    end
  end

  describe "task status badge" do
    test "renders the localized label for every known status (plus ping dot / spinner)" do
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

      assert render_card(task_status: :running) =~ "animate-ping"
      assert render_card(task_status: :finalizing) =~ "loading-spinner"
    end

    test "unrecognized statuses degrade (raw atom name, empty label for non-atoms)" do
      assert render_card(task_status: :bogus_status) =~ "bogus_status"

      non_atom = render_card(task_status: "running")
      assert badge_header?(non_atom)
      refute non_atom =~ "Running"
    end
  end

  describe "thought process" do
    test "renders types, turns, reasoning, tool rows and tool-call rows; nothing when empty" do
      refute render_card([]) =~ "Thought process"

      tp = [
        thought(2, "assistant", %{
          content: "",
          reasoning_details: [%{text: "let me think", index: 0}],
          tool_calls: [],
          tool_name: nil
        }),
        thought(2, "tool", %{
          content: "result...",
          tool_name: "spawn_investigator",
          tool_calls: [],
          reasoning_details: []
        }),
        thought(1, "assistant", %{
          content: "",
          tool_calls: [@tool_call],
          reasoning_details: [],
          tool_name: nil
        }),
        # Malformed entry degrades to the "message" type label.
        %{turn: "x", timestamp: nil, type: nil, data: nil}
      ]

      html = render_card(thought_process: tp)
      doc = Floki.parse_document!(html)
      [details] = Floki.find(doc, "details")
      assert Floki.attribute([details], "open") == []
      assert length(Floki.find([details], "summary")) == 1
      assert Floki.find([details], "summary") |> Floki.text() =~ "Thought process"

      # Type labels, count, reasoning text, tool name/content, the
      # ToolCallDisplay contract, and the malformed-entry fallback.
      assert html =~ "Thought process"
      assert html =~ "(4)"
      assert html =~ "assistant"
      assert html =~ "tool"
      assert html =~ "let me think"
      assert html =~ "spawn_investigator"
      assert html =~ "result..."
      assert html =~ "Shell call"
      assert html =~ "Command"
      assert html =~ "ls"
      assert html =~ "message"
    end
  end

  describe "tool_entry/1" do
    defp render_tool(entry) do
      render_component(&AssistantMessage.tool_entry/1, entry: entry)
    end

    test "renders the tool name with its status chip" do
      running = render_tool(%{role: :tool, tool_name: "bash", tool_status: :running})
      assert running =~ "bash"
      assert running =~ "loading loading-spinner loading-xs"
      assert running =~ "Running"

      done = render_tool(%{role: :tool, tool_name: "bash", tool_status: :ok})
      assert done =~ "badge badge-ghost badge-sm"
      assert done =~ "Done"
      refute done =~ "loading-spinner"

      failed = render_tool(%{role: :tool, tool_name: "bash", tool_status: :error})
      assert failed =~ "text-error"
      assert failed =~ "Failed"

      timed_out = render_tool(%{role: :tool, tool_name: "bash", tool_status: :timeout})
      assert timed_out =~ "text-warning"
      assert timed_out =~ "Timed out"
    end

    test "renders no chip for an unknown/nil status" do
      for status <- [nil, :bogus, "running"] do
        html = render_tool(%{role: :tool, tool_name: "bash", tool_status: status})
        classes = Floki.parse_document!(html) |> Floki.attribute("div", "class") |> hd()

        refute html =~ "loading-spinner"
        refute html =~ "badge-ghost"
        refute html =~ "text-error"
        refute html =~ "text-warning"
        assert classes =~ "flex items-center gap-2 text-xs text-base-content/60"
      end
    end

    test "falls back to a generic label for a nil/blank tool name, total on garbage" do
      for entry <- [
            %{role: :tool},
            %{role: :tool, tool_name: nil},
            %{role: :tool, tool_name: "  "}
          ] do
        html = render_tool(entry)
        assert html =~ "Tool"
        # It is a quiet single-row layout with the wrench icon.
        assert html =~ "hero-wrench-screwdriver"
        assert html =~ "my-1"
      end

      # A non-map entry never raises.
      assert render_tool(nil) =~ "Tool"
    end
  end

  describe "stream meta line" do
    test "renders the turn, token and duration labels when present" do
      html =
        render_card(stream_meta: %{turn: 3, total_tokens: 1_234, duration_ms: 1_500, usage: nil})

      assert html =~ "Turn 3"
      assert html =~ "1234 tokens"
      assert html =~ "1.5s"
      assert html =~ "font-mono text-[11px] text-base-content/50"
    end

    test "renders only the labels it has" do
      tokens_only = render_card(stream_meta: %{turn: nil, total_tokens: 42, duration_ms: nil})
      assert tokens_only =~ "42 tokens"
      refute tokens_only =~ "Turn "
      refute tokens_only =~ ~r/>\d+(\.\d+)?s</

      turn_only = render_card(stream_meta: %{turn: 1, total_tokens: nil, duration_ms: nil})
      assert turn_only =~ "Turn 1"
      refute turn_only =~ "tokens"
    end

    test "renders nothing without a usable turn/token count" do
      for meta <- [nil, %{}, :junk, %{turn: "2", total_tokens: "9"}, %{duration_ms: 1_000}] do
        html = render_card(stream_meta: meta)
        refute html =~ "font-mono text-[11px]"
        refute html =~ "tokens"
        refute html =~ "Turn "
      end
    end
  end

  describe "message_list/1 role dispatch" do
    defp render_list(transcript, stream_meta \\ nil) do
      render_component(&ChatMessages.message_list/1,
        transcript: transcript,
        chat_task_status: :running,
        thought_process: [thought(1, "assistant", %{content: "steps"})],
        raw_entry_ids: MapSet.new(),
        stream_meta: stream_meta
      )
    end

    test "renders tool rows and never raises on an unknown role" do
      transcript = [
        Transcript.entry(:user, "hello"),
        Transcript.tool_entry("bash", "c1", :running, 1),
        Transcript.entry(:assistant, "answer"),
        Transcript.entry(:error, "boom"),
        # An unknown role degradation path (normalize/1 would coerce this, so it
        # is only reachable through a direct assign).
        %{id: "x", role: :mystery, text: "odd", streaming: false}
      ]

      html = render_list(transcript)

      assert html =~ "hello"
      assert html =~ "bash"
      assert html =~ "Running"
      assert html =~ "answer"
      assert html =~ "boom"
      assert html =~ "odd"
      # One tool row + the two wrapped bubbles, no duplicated tool row.
      assert length(Floki.find(Floki.parse_document!(html), ".hero-wrench-screwdriver")) == 1
    end

    test "stream_meta is passed ONLY to the last assistant entry" do
      transcript = [Transcript.entry(:assistant, "one"), Transcript.entry(:assistant, "two")]

      html = render_list(transcript, %{turn: 2, total_tokens: 55})

      assert length(String.split(html, "font-mono text-[11px]")) == 2
      assert html =~ "Turn 2"
      assert html =~ "55 tokens"
    end
  end

  describe "AgentStream.extract_failed_message/1" do
    test "returns nil for non-maps, absent/non-binary messages, and blank-only messages" do
      for input <- [
            nil,
            {:error, :boom},
            "legacy string error",
            42,
            %{kind: :boom},
            %{message: nil},
            %{message: :boom},
            %{message: ""},
            %{message: "   "},
            # No :message atom key, but a "message" string key.
            %{"message" => " \t "}
          ] do
        assert AgentStream.extract_failed_message(input) == nil,
               "expected nil for #{inspect(input)}"
      end
    end

    test "returns the message verbatim for atom-key and string-key shapes (no trimming)" do
      # Only the blank check trims; a padded non-blank message is returned as-is.
      for {payload, expected} <- [
            {%{message: "Task force-killed by user"}, "Task force-killed by user"},
            {%{"message" => "Task force-killed by user"}, "Task force-killed by user"},
            {%{message: "  partial note  "}, "  partial note  "}
          ] do
        assert AgentStream.extract_failed_message(payload) == expected,
               "unexpected message for #{inspect(payload)}"
      end
    end
  end
end
