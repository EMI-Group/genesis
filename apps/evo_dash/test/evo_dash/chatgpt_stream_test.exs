defmodule EvoDash.ChatGPTStreamTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  defmodule TitleRequestAdapter do
    @behaviour ReqLLM.FinchRequestAdapter

    @impl true
    def call(request), do: Application.fetch_env!(:evo_dash, __MODULE__).(request)
  end

  setup do
    dir = EvoDash.Test.ConfigDir.isolate!("genesis-chatgpt-stream")
    previous = Application.get_env(:evo_git, :config_dir_fun)
    Application.put_env(:evo_git, :config_dir_fun, fn -> dir end)
    on_exit(fn -> Application.put_env(:evo_git, :config_dir_fun, previous) end)
    EvoGit.TestSupport.ChatGPTFixture.seed!("work")
    :ok
  end

  test "ReqLLM receives the selected account's token and consumes a complete SSE response" do
    events = [
      %{"type" => "response.output_text.delta", "delta" => "Hello"},
      %{"type" => "response.completed", "response" => %{"status" => "completed"}},
      "[DONE]"
    ]

    assert {:ok, response} = stream(events)
    assert ReqLLM.Response.text(response) == "Hello"
    assert_received {:sent, "Bearer access-work", %{"stream" => true, "store" => false}}
  end

  test "the connection check resolves the configured account before opening the stream" do
    profile = %{
      "id" => "team-chatgpt",
      "provider" => "openai_codex",
      "siwc_account" => "work",
      "models" => [%{"model" => "gpt-5.6-terra"}]
    }

    assert :ok =
             EvoGit.Config.save_user_config(%{
               llm: %{providers: [profile], default_provider_profile: "team-chatgpt"}
             })

    transform =
      test_endpoint([
        %{"type" => "response.output_text.delta", "delta" => "Hello"},
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ])

    assert {:ok, %{response: "Hello"}} =
             EvoGit.SystemCheck.llm_test(
               %{"provider_profile_id" => "team-chatgpt", "model" => "gpt-5.6-terra"},
               on_finch_request: transform
             )

    assert_received {:sent, "Bearer access-work", %{"model" => "gpt-5.6-terra"}}
  end

  test "PR title generation uses the selected account and model from the provider profile" do
    assert :ok =
             EvoGit.Config.save_user_config(%{
               llm: %{
                 providers: [
                   %{
                     "id" => "team-chatgpt",
                     "provider" => "openai_codex",
                     "siwc_account" => "work",
                     "models" => [%{"model" => "gpt-5.6-terra"}]
                   }
                 ],
                 default_provider_profile: "team-chatgpt"
               }
             })

    transform =
      test_endpoint([
        %{"type" => "response.output_text.delta", "delta" => "Fix title generation"},
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ])

    previous = Application.get_env(:req_llm, :finch_request_adapter)

    on_exit(fn ->
      Application.put_env(:req_llm, :finch_request_adapter, previous)
      Application.delete_env(:evo_dash, TitleRequestAdapter)
    end)

    Application.put_env(:evo_dash, TitleRequestAdapter, transform)
    Application.put_env(:req_llm, :finch_request_adapter, TitleRequestAdapter)

    assert EvoGit.Runtime.PullRequest.generate_title("Add title generation", "Done") ==
             "Fix title generation"

    assert_received {:sent, "Bearer access-work", %{"model" => "gpt-5.6-terra"}}
  end

  test "ReqLLM rejects an incomplete response" do
    events = [
      %{"type" => "response.output_text.delta", "delta" => "Partial"},
      %{"type" => "response.incomplete", "response" => %{"status" => "incomplete"}}
    ]

    assert {:error, _} = stream(events)
  end

  test "ReqLLM rejects partial output even when the stream has a generic end marker" do
    partial = %{"type" => "response.output_text.delta", "delta" => "Partial"}

    for events <- [[partial], [partial, "[DONE]"]] do
      assert {:error, _} = stream(events)
    end
  end

  test "a namespaced tool call and its result survive separate stateless requests" do
    function = %{
      "type" => "function_call",
      "id" => "fc_test",
      "call_id" => "call_test",
      "name" => "hello",
      "namespace" => "genesis",
      "arguments" => "{}",
      "status" => "completed"
    }

    tool =
      ReqLLM.tool(
        name: "hello",
        description: "Return a greeting",
        parameter_schema: [],
        callback: fn _ -> "Hi" end
      )

    context =
      ReqLLM.Context.new([
        ReqLLM.Context.system("Answer briefly."),
        ReqLLM.Context.user("Run hello.")
      ])

    events = [
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => function},
      %{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "output" => [function]}
      }
    ]

    assert {:ok, response} = stream(events, context, [tool])
    assert [call] = ReqLLM.Response.tool_calls(response)
    assert call.function.name == "hello"
    assert_received {:sent, _, %{"tools" => [%{"name" => "genesis"}]}}

    updated =
      ReqLLM.Context.append(context, [response.message, ReqLLM.Context.tool_result(call.id, "Hi")])

    events = [
      %{"type" => "response.output_text.delta", "delta" => "Done"},
      %{"type" => "response.completed", "response" => %{"status" => "completed"}}
    ]

    assert {:ok, resumed} = stream(events, updated, [tool])
    assert ReqLLM.Response.text(resumed) == "Done"
    assert_received {:sent, _, %{"input" => input}}

    assert Enum.any?(
             input,
             &match?(%{"type" => "function_call_output", "call_id" => "call_test"}, &1)
           )
  end

  defp stream(events, messages \\ "Hello", tools \\ []) do
    with {:ok, stream} <-
           ReqLLM.stream_text("openai_codex:gpt-5.6-terra", messages,
             tools: tools,
             provider_options: [siwc_account: "work"],
             on_finch_request: test_endpoint(events)
           ) do
      ReqLLM.StreamResponse.process_stream(stream)
    end
  end

  defp test_endpoint(events) do
    owner = self()

    listener =
      Supervisor.child_spec(
        {Bandit,
         plug: {__MODULE__, {owner, events}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    server = start_supervised!(listener)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    fn request ->
      assert request.host == "api.openai.com"
      assert request.path == "/v1/responses"
      Finch.build(:post, "http://127.0.0.1:#{port}/v1/responses", request.headers, request.body)
    end
  end

  def init(opts), do: opts

  def call(conn, {owner, events}) do
    {:ok, body, conn} = read_body(conn)
    [authorization] = get_req_header(conn, "authorization")
    send(owner, {:sent, authorization, Jason.decode!(body)})

    sse =
      Enum.map_join(events, fn
        "[DONE]" -> "data: [DONE]\n\n"
        event -> "data: " <> Jason.encode!(event) <> "\n\n"
      end)

    conn |> put_resp_content_type("text/event-stream") |> send_resp(200, sse)
  end
end
