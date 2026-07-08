defmodule EvoGit.Agent.ToolDispatchTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.ToolDispatch

  import ExUnit.CaptureLog

  # Build a ReqLLM.Response with a text-only assistant message (no tool calls).
  # ReqLLM.Response.tool_calls/1 returns [] when message.tool_calls is nil.
  defp text_response(text) do
    msg = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: nil
    }

    %ReqLLM.Response{
      id: "test-resp",
      model: "test:model",
      context: nil,
      message: msg,
      usage: nil
    }
  end

  # Build a ReqLLM.Response whose assistant message carries a tool call.
  # ReqLLM.Response.tool_calls/1 reads message.tool_calls directly.
  defp tool_call_response(tool_call_maps) do
    msg = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text("Calling a tool.")],
      tool_calls: tool_call_maps
    }

    %ReqLLM.Response{
      id: "test-resp",
      model: "test:model",
      context: nil,
      message: msg,
      usage: nil
    }
  end

  # ---------------------------------------------------------------------------
  # ensure_tool_calls/2
  # ---------------------------------------------------------------------------

  describe "ensure_tool_calls/2" do
    test "returns :ok when the response has tool calls" do
      resp =
        tool_call_response([
          %{id: "call_1", name: "read_file", arguments: %{"file_path" => "./src.ex"}}
        ])

      assert ToolDispatch.ensure_tool_calls(resp, 1) == :ok
    end

    test "returns {:error, :no_tool_calls} when the response has NO tool calls" do
      resp = text_response("I'll just stop here without calling any tools.")

      assert ToolDispatch.ensure_tool_calls(resp, 1) == {:error, :no_tool_calls}
    end

    test "logs a specific warning when no tool calls are present" do
      resp = text_response("No tools here.")

      log =
        capture_log(fn ->
          ToolDispatch.ensure_tool_calls(resp, 42)
        end)

      assert log =~ "Agent 42: LLM returned no tool calls, retrying..."
    end

    test "does not log a warning when tool calls are present" do
      resp =
        tool_call_response([
          %{id: "call_1", name: "run_bash", arguments: %{"command" => "echo hi"}}
        ])

      log =
        capture_log(fn ->
          ToolDispatch.ensure_tool_calls(resp, 7)
        end)

      refute log =~ "LLM returned no tool calls"
    end
  end

  # ---------------------------------------------------------------------------
  # process_tool_calls/3 defensive fallback
  # ---------------------------------------------------------------------------

  describe "process_tool_calls/3 defensive fallback" do
    test "returns {:error, :protocol_violation} for an empty tool-call list" do
      # This clause is now a defensive fallback: ensure_tool_calls/2 catches the
      # empty case inside the retry loop first. The clause must still return the
      # same protocol-violation error if reached directly.
      assert ToolDispatch.process_tool_calls([], nil, []) == {:error, :protocol_violation}
    end
  end
end
