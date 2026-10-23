defmodule EvoGit.Agent.CompletionProtocolTest do
  @moduledoc """
  Unit tests for `EvoGit.Agent.CompletionProtocol` — the pure classifier that
  decides how one LLM turn ends: `{:tool_calls, calls}` (the turn continues with
  tool execution), `{:text_reply, text}` (zero tool calls with usable text = an
  implicit completion) or `:empty` (nothing usable, recovered by one nudge at
  the dispatch site).

  Pins the four properties the classifier is responsible for:

    * tool calls win — a turn carrying BOTH tool calls and text still classifies
      as `{:tool_calls, calls}`, with the call structs returned as-is;
    * text is read through `ReqLLM.Response.text/1`, i.e. ONLY `:text` content
      parts count, so a `:thinking` part never becomes the agent's report;
    * the reported text is returned VERBATIM — blankness is judged after
      trimming, the text itself is never rewritten;
    * every "nothing usable" shape (empty content, whitespace-only text, a
      thinking-only reply, a nil message, a hand-built `content: nil`, non-list
      content) is `:empty` — never a text reply, never a raise.

  `async: true` is safe: `CompletionProtocol` is pure (no git, no HTTP, no
  scheduler, no app env, no ETS, no `:persistent_term`), and every value here is
  built in-process from plain structs, so nothing another concurrently running
  module can observe is touched.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.CompletionProtocol

  # Build a ReqLLM.Response with an assistant message carrying `content` parts
  # and, optionally, tool calls. ReqLLM.Response.tool_calls/1 returns
  # message.tool_calls verbatim when it is a list and [] when it is nil.
  defp response(content, tool_calls \\ nil) do
    %ReqLLM.Response{
      id: "test-resp",
      model: "test:model",
      context: nil,
      message: %ReqLLM.Message{role: :assistant, content: content, tool_calls: tool_calls},
      usage: nil
    }
  end

  defp text_response(text) do
    response([ReqLLM.Message.ContentPart.text(text)])
  end

  defp tool_call_response(tool_calls) do
    response([ReqLLM.Message.ContentPart.text("Calling a tool.")], tool_calls)
  end

  defp read_call(id, path) do
    ReqLLM.ToolCall.new(id, "read", ~s({"path":"#{path}"}))
  end

  # ---------------------------------------------------------------------------
  # classify/1 — tool calls
  # ---------------------------------------------------------------------------

  describe "classify/1 — tool calls" do
    test "returns the tool call structs for a turn with one call" do
      call = read_call("call_1", "./lib/app.ex")

      assert {:tool_calls, [returned]} = CompletionProtocol.classify(tool_call_response([call]))
      assert returned == call
      assert returned.function.name == "read"
    end

    test "returns every call for a multi-call turn, in order" do
      first = read_call("call_1", "./a.ex")
      second = read_call("call_2", "./b.ex")

      assert {:tool_calls, calls} =
               CompletionProtocol.classify(tool_call_response([first, second]))

      assert calls == [first, second]
    end

    test "tool calls win over text present in the same turn" do
      call = read_call("call_1", "./a.ex")
      resp = tool_call_response([call])

      assert {:tool_calls, [returned]} = CompletionProtocol.classify(resp)
      assert returned == call
    end

    test "tool calls win even when the message content is not enumerable" do
      call = read_call("call_1", "./a.ex")

      assert {:tool_calls, [returned]} = CompletionProtocol.classify(response(nil, [call]))
      assert returned == call
    end
  end

  # ---------------------------------------------------------------------------
  # classify/1 — text replies
  # ---------------------------------------------------------------------------

  describe "classify/1 — text replies" do
    test "returns a plain text reply" do
      assert {:text_reply, "Done. All tests pass."} =
               CompletionProtocol.classify(text_response("Done. All tests pass."))
    end

    test "returns the text VERBATIM, keeping surrounding whitespace" do
      text = "  \n\nImplemented the parser.\n\n"
      resp = text_response(text)

      assert {:text_reply, returned} = CompletionProtocol.classify(resp)
      assert returned == text
      assert returned != String.trim(text)
    end

    test "preserves multi-line markdown untouched" do
      text = "## Summary\n\n- added `foo/1`\n- fixed the **bug**\n\n```elixir\nfoo(1)\n```\n"

      assert {:text_reply, returned} = CompletionProtocol.classify(text_response(text))
      assert returned == text
    end

    test "joins multiple text parts in order" do
      resp =
        response([
          ReqLLM.Message.ContentPart.text("first "),
          ReqLLM.Message.ContentPart.text("second")
        ])

      assert {:text_reply, "first second"} = CompletionProtocol.classify(resp)
    end
  end

  # ---------------------------------------------------------------------------
  # classify/1 — thinking parts never become the report
  # ---------------------------------------------------------------------------

  describe "classify/1 — thinking parts" do
    test "returns only the text part when a reply carries text AND thinking" do
      resp =
        response([
          ReqLLM.Message.ContentPart.text("The fix is in `lib/app.ex`."),
          ReqLLM.Message.ContentPart.thinking("SECRET-REASONING-TOKEN")
        ])

      assert {:text_reply, returned} = CompletionProtocol.classify(resp)
      assert returned == "The fix is in `lib/app.ex`."
      refute String.contains?(returned, "SECRET-REASONING-TOKEN")
    end

    test "returns :empty for a reply carrying ONLY a thinking part" do
      resp = response([ReqLLM.Message.ContentPart.thinking("SECRET-REASONING-TOKEN")])

      assert CompletionProtocol.classify(resp) == :empty
    end
  end

  # ---------------------------------------------------------------------------
  # classify/1 — empty variants
  # ---------------------------------------------------------------------------

  describe "classify/1 — empty replies" do
    test "returns :empty for empty content" do
      assert CompletionProtocol.classify(response([])) == :empty
    end

    test "returns :empty for whitespace-only text" do
      assert CompletionProtocol.classify(text_response("   \n\t")) == :empty
    end

    test "returns :empty for an empty text part" do
      assert CompletionProtocol.classify(text_response("")) == :empty
    end

    test "returns :empty for a nil message" do
      resp = %ReqLLM.Response{
        id: "test-resp",
        model: "test:model",
        context: nil,
        message: nil,
        usage: nil
      }

      assert CompletionProtocol.classify(resp) == :empty
    end

    test "returns :empty (never raises) for a hand-built `content: nil` message" do
      # ReqLLM's own struct default for `:content` is `[]`, so this shape is only
      # reachable via a hand-built struct — it must not raise
      # `Protocol.UndefinedError` out of `ReqLLM.Response.text/1`.
      resp = response(nil)

      assert resp.message.content == nil

      assert CompletionProtocol.classify(resp) == :empty
    end

    test "returns :empty (never raises) for non-list content" do
      assert CompletionProtocol.classify(response("a bare string")) == :empty
    end
  end

  # ---------------------------------------------------------------------------
  # report_text/1
  # ---------------------------------------------------------------------------

  describe "report_text/1" do
    test "returns {:ok, text} for a text reply" do
      assert CompletionProtocol.report_text(text_response("All good.")) == {:ok, "All good."}
    end

    test "returns the text verbatim, not trimmed" do
      text = "\n\n  Report body  \n\n"

      assert CompletionProtocol.report_text(text_response(text)) == {:ok, text}
    end

    test "ignores thinking parts" do
      resp =
        response([
          ReqLLM.Message.ContentPart.text("Report."),
          ReqLLM.Message.ContentPart.thinking("SECRET-REASONING-TOKEN")
        ])

      assert CompletionProtocol.report_text(resp) == {:ok, "Report."}
    end

    test "returns :empty for a thinking-only reply" do
      resp = response([ReqLLM.Message.ContentPart.thinking("SECRET-REASONING-TOKEN")])

      assert CompletionProtocol.report_text(resp) == :empty
    end

    test "returns :empty for empty content" do
      assert CompletionProtocol.report_text(response([])) == :empty
    end

    test "returns :empty for whitespace-only text" do
      assert CompletionProtocol.report_text(text_response("   \n\t")) == :empty
    end

    test "returns :empty for a nil message" do
      resp = %ReqLLM.Response{
        id: "test-resp",
        model: "test:model",
        context: nil,
        message: nil,
        usage: nil
      }

      assert CompletionProtocol.report_text(resp) == :empty
    end

    test "returns :empty (never raises) for a hand-built `content: nil` message" do
      # Only reachable via a hand-built struct (ReqLLM defaults `:content` to
      # `[]`); `ReqLLM.Response.text/1` would raise `Protocol.UndefinedError`
      # enumerating nil.
      resp = response(nil)

      assert resp.message.content == nil
      assert CompletionProtocol.report_text(resp) == :empty
    end

    test "returns :empty (never raises) for non-list content" do
      assert CompletionProtocol.report_text(response(%{text: "not a list"})) == :empty
    end
  end
end
