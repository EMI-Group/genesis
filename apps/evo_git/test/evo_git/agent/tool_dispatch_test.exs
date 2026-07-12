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

      assert log =~ "Agent 42: LLM returned no tool calls"
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
      # This clause is now a defensive fallback: ensure_tool_calls/2 (called
      # inside prompt_until_tools_or_limit/5) catches the empty case before
      # tool calls are extracted. The clause must still return the same
      # protocol-violation error if reached directly.
      assert ToolDispatch.process_tool_calls([], nil, []) == {:error, :protocol_violation}
    end
  end

  # ---------------------------------------------------------------------------
  # no_tool_call_nudge_message / append_no_tool_call_nudge
  # ---------------------------------------------------------------------------

  describe "no_tool_call_nudge_message/0" do
    test "returns a user-role message instructing the model to use tools" do
      msg = ToolDispatch.no_tool_call_nudge_message()

      assert msg.role == :user
      # Extract the text content from the message
      text_parts =
        Enum.filter(msg.content, fn
          %ReqLLM.Message.ContentPart{text: _} -> true
          _ -> false
        end)

      combined = Enum.map_join(text_parts, "", & &1.text)
      assert combined =~ "tool call"
      assert combined =~ "did not make any tool calls"
    end
  end

  describe "append_no_tool_call_nudge/1" do
    test "appends a user nudge message to the context" do
      ctx = ReqLLM.Context.new([])
      nudge_msg = ToolDispatch.no_tool_call_nudge_message()

      updated = ToolDispatch.append_no_tool_call_nudge(ctx)

      assert length(updated.messages) == 1
      [appended] = updated.messages
      assert appended.role == :user
      assert appended == nudge_msg
    end

    test "preserves existing messages and appends the nudge at the end" do
      existing = ReqLLM.Context.user("prior assistant message")
      ctx = ReqLLM.Context.new([existing])

      updated = ToolDispatch.append_no_tool_call_nudge(ctx)

      assert length(updated.messages) == 2
      [first, second] = updated.messages
      assert first == existing
      assert second.role == :user
    end
  end

  # ---------------------------------------------------------------------------
  # dedupe_tool_calls/2
  # ---------------------------------------------------------------------------

  describe "dedupe_tool_calls/2" do
    test "removes calls with duplicate ids, keeping the first" do
      calls = [
        %{id: "call_1", name: "read_file", arguments: %{"file_path" => "./a.ex"}},
        %{id: "call_1", name: "read_file", arguments: %{"file_path" => "./b.ex"}}
      ]

      [only] = ToolDispatch.dedupe_tool_calls(calls, "agent")

      assert only.id == "call_1"
      assert only.arguments == %{"file_path" => "./a.ex"}
    end

    test "removes calls with identical content but different ids, keeping the first" do
      calls = [
        %{
          id: "call_1",
          name: "subagent_manager",
          arguments: %{"path" => "./src", "objective" => "foo"}
        },
        %{
          id: "call_2",
          name: "subagent_manager",
          arguments: %{"path" => "./src", "objective" => "foo"}
        }
      ]

      [only] = ToolDispatch.dedupe_tool_calls(calls, "agent")

      assert only.id == "call_1"
    end

    test "keeps all calls when there are no duplicates" do
      calls = [
        %{id: "call_1", name: "read_file", arguments: %{"file_path" => "./a.ex"}},
        %{id: "call_2", name: "run_bash", arguments: %{"command" => "echo hi"}}
      ]

      result = ToolDispatch.dedupe_tool_calls(calls, "agent")

      assert length(result) == 2
      assert Enum.map(result, & &1.id) == ["call_1", "call_2"]
    end

    test "logs a warning when duplicates are removed" do
      calls = [
        %{id: "call_1", name: "read_file", arguments: %{"file_path" => "./a.ex"}},
        %{id: "call_1", name: "read_file", arguments: %{"file_path" => "./b.ex"}}
      ]

      log =
        capture_log(fn ->
          ToolDispatch.dedupe_tool_calls(calls, "my-agent")
        end)

      assert log =~ "Removed 1 duplicate tool call"
      assert log =~ "Agent my-agent"
      assert log =~ "read_file"
    end

    test "does not log a warning when there are no duplicates" do
      calls = [
        %{id: "call_1", name: "read_file", arguments: %{"file_path" => "./a.ex"}},
        %{id: "call_2", name: "run_bash", arguments: %{"command" => "echo hi"}}
      ]

      log =
        capture_log(fn ->
          ToolDispatch.dedupe_tool_calls(calls, "agent")
        end)

      refute log =~ "duplicate tool call"
    end

    test "handles an empty list" do
      assert ToolDispatch.dedupe_tool_calls([], "agent") == []
    end
  end

  # ---------------------------------------------------------------------------
  # sync_context_tool_calls/2
  # ---------------------------------------------------------------------------

  # Build an assistant message (the last message in a context) carrying a list
  # of %ReqLLM.ToolCall{} structs in its tool_calls field.
  defp assistant_msg_with_tool_calls(tool_call_structs) do
    %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text("Calling tools.")],
      tool_calls: tool_call_structs
    }
  end

  describe "sync_context_tool_calls/2" do
    test "filters last message tool_calls to match deduped set" do
      tc1 = ReqLLM.ToolCall.new("call_1", "read_file", ~s({"file_path":"./a.ex"}))
      tc2 = ReqLLM.ToolCall.new("call_2", "run_bash", ~s({"command":"echo hi"}))
      tc3 = ReqLLM.ToolCall.new("call_3", "write_file", ~s({"file_path":"./c.ex"}))

      ctx = ReqLLM.Context.new([assistant_msg_with_tool_calls([tc1, tc2, tc3])])

      # Deduped set keeps only call_1 and call_3.
      deduped = [%{id: "call_1"}, %{id: "call_3"}]

      updated = ToolDispatch.sync_context_tool_calls(ctx, deduped)

      last_msg = List.last(updated.messages)
      assert length(last_msg.tool_calls) == 2
      assert Enum.map(last_msg.tool_calls, & &1.id) == ["call_1", "call_3"]
    end

    test "returns context unchanged when last message tool_calls is nil" do
      ctx =
        ReqLLM.Context.new([
          assistant_msg_with_tool_calls(nil)
        ])

      deduped = [%{id: "call_1"}]

      assert ToolDispatch.sync_context_tool_calls(ctx, deduped) == ctx
    end

    test "returns context unchanged for empty messages" do
      ctx = ReqLLM.Context.new([])
      deduped = [%{id: "call_1"}]

      assert ToolDispatch.sync_context_tool_calls(ctx, deduped) == ctx
    end
  end

  # ---------------------------------------------------------------------------
  # dedupe_and_sync/3
  # ---------------------------------------------------------------------------

  # Build a ReqLLM.Response that has BOTH a context (with messages) AND a
  # message, where the message's tool_calls are %ReqLLM.ToolCall{} structs
  # with a duplicate (same id and content).
  defp response_with_duplicate_tool_calls do
    tc1 = ReqLLM.ToolCall.new("call_1", "read_file", ~s({"file_path":"./a.ex"}))
    tc1_dup = ReqLLM.ToolCall.new("call_1", "read_file", ~s({"file_path":"./a.ex"}))

    msg = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text("calling")],
      tool_calls: [tc1, tc1_dup]
    }

    %ReqLLM.Response{
      id: "test-resp",
      model: "test:model",
      context: ReqLLM.Context.new([msg]),
      message: msg,
      usage: nil
    }
  end

  # Build a ReqLLM.Response with two distinct tool calls (no duplicates).
  defp response_with_distinct_tool_calls do
    tc1 = ReqLLM.ToolCall.new("call_1", "read_file", ~s({"file_path":"./a.ex"}))
    tc2 = ReqLLM.ToolCall.new("call_2", "run_bash", ~s({"command":"echo hi"}))

    msg = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text("calling")],
      tool_calls: [tc1, tc2]
    }

    %ReqLLM.Response{
      id: "test-resp",
      model: "test:model",
      context: ReqLLM.Context.new([msg]),
      message: msg,
      usage: nil
    }
  end

  # Build a ReqLLM.Response with a nil message but a valid context carrying
  # duplicate tool calls.
  defp response_with_nil_message do
    tc1 = ReqLLM.ToolCall.new("call_1", "read_file", ~s({"file_path":"./a.ex"}))
    tc1_dup = ReqLLM.ToolCall.new("call_1", "read_file", ~s({"file_path":"./a.ex"}))

    msg = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text("calling")],
      tool_calls: [tc1, tc1_dup]
    }

    %ReqLLM.Response{
      id: "test-resp",
      model: "test:model",
      context: ReqLLM.Context.new([msg]),
      message: nil,
      usage: nil
    }
  end

  describe "dedupe_and_sync/3" do
    test "dedupes both context and message tool_calls" do
      response = response_with_duplicate_tool_calls()

      # Replicate how process_llm_response builds the tool_calls argument
      tool_calls =
        ReqLLM.Response.tool_calls(response)
        |> Enum.map(&ReqLLM.ToolCall.from_map/1)

      {deduped, updated_response} = ToolDispatch.dedupe_and_sync(tool_calls, response, "agent")

      assert length(deduped) == 1

      last_msg = List.last(updated_response.context.messages)
      assert length(last_msg.tool_calls) == 1

      assert length(updated_response.message.tool_calls) == 1
    end

    test "returns response unchanged when there are no duplicates" do
      response = response_with_distinct_tool_calls()

      tool_calls =
        ReqLLM.Response.tool_calls(response)
        |> Enum.map(&ReqLLM.ToolCall.from_map/1)

      {_deduped, updated_response} = ToolDispatch.dedupe_and_sync(tool_calls, response, "agent")

      # message.tool_calls unchanged
      assert length(updated_response.message.tool_calls) == 2
      assert Enum.map(updated_response.message.tool_calls, & &1.id) == ["call_1", "call_2"]

      # context last message tool_calls unchanged
      last_msg = List.last(updated_response.context.messages)
      assert length(last_msg.tool_calls) == 2
    end

    test "handles nil message without crashing and still dedups context" do
      response = response_with_nil_message()

      # When message is nil, ReqLLM.Response.tool_calls/1 returns [], so we
      # build the tool_calls argument independently (as process_llm_response
      # would when the context carries the tool calls).
      tool_calls =
        ReqLLM.Response.tool_calls(%{response | message: hd(response.context.messages)})
        |> Enum.map(&ReqLLM.ToolCall.from_map/1)

      {deduped, updated_response} = ToolDispatch.dedupe_and_sync(tool_calls, response, "agent")

      assert length(deduped) == 1
      assert is_nil(updated_response.message)

      last_msg = List.last(updated_response.context.messages)
      assert length(last_msg.tool_calls) == 1
    end

    test "logs a warning when duplicates are removed via dedupe_and_sync" do
      response = response_with_duplicate_tool_calls()

      tool_calls =
        ReqLLM.Response.tool_calls(response)
        |> Enum.map(&ReqLLM.ToolCall.from_map/1)

      log =
        capture_log(fn ->
          ToolDispatch.dedupe_and_sync(tool_calls, response, "my-agent")
        end)

      assert log =~ "Removed 1 duplicate tool call"
      assert log =~ "Agent my-agent"
      assert log =~ "read_file"
    end
  end
end
