defmodule EvoGit.Auth.ChatGPTResponsesTest do
  use ExUnit.Case, async: true

  alias EvoGit.LLM.ChatGPTResponses
  alias ReqLLM.Context

  test "subscription requests use the official endpoint and a stateless streaming envelope" do
    context = Context.new([Context.system("Explain."), Context.user("Hello.")])

    model = %LLMDB.Model{
      provider: :openai_codex,
      id: "gpt-6.1-sol",
      base_url: "https://example.invalid"
    }

    tool =
      ReqLLM.tool(
        name: "example",
        description: "Return an example",
        parameter_schema: [query: [type: :string, required: true]],
        callback: fn args -> args end
      )

    assert {:ok, request} =
             ChatGPTResponses.build_request(
               model,
               context,
               [max_tokens: 42, tools: [tool]],
               "example-token"
             )

    assert request.host == "api.openai.com"
    assert request.path == "/v1/responses"
    assert {"authorization", "Bearer example-token"} in request.headers
    body = Jason.decode!(request.body)
    assert body["store"] == false
    assert body["stream"] == true
    assert body["model"] == "gpt-6.1-sol"
    assert [%{"role" => "developer"}, %{"role" => "user"}] = body["input"]
    assert [%{"type" => "namespace", "tools" => [%{"name" => "example"}]}] = body["tools"]
    refute Map.has_key?(body, "max_output_tokens")
    refute Map.has_key?(body, "previous_response_id")
  end

  test "registered adapter serves the normal ReqLLM call and fails closed without an account" do
    EvoGit.TestSupport.ConfigDir.isolate!("evogit-siwc-request")
    assert {:ok, ChatGPTResponses} = ReqLLM.Providers.get(:openai_codex)
    assert {:error, reason} = ReqLLM.stream_text("openai_codex:gpt-5.6-terra", "test")
    assert inspect(reason) =~ "genesis chatgpt login --account default"
  end

  test "an interrupted stream reports an error at EOF" do
    model = %LLMDB.Model{provider: :openai_codex, id: "gpt-6.1-sol"}
    state = ChatGPTResponses.init_stream_state(model)

    assert {[%ReqLLM.StreamChunk{metadata: %{finish_reason: :error}}], _} =
             ChatGPTResponses.flush_stream_state(model, state)
  end
end
