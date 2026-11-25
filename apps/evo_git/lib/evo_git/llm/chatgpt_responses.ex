defmodule EvoGit.LLM.ChatGPTResponses do
  @moduledoc """
  ReqLLM adapter for the OpenAI Responses API with ChatGPT plan usage.

  The existing provider identifier remains readable in Genesis profiles.
  Requests and stream decoding use the public OpenAI Responses protocol.
  """

  use ReqLLM.Provider, id: :openai_codex, default_base_url: "https://api.openai.com/v1"

  alias EvoGit.Auth.ChatGPT
  alias EvoGit.Auth.ChatGPT.Store
  alias ReqLLM.Providers.OpenAI.ResponsesAPI
  alias ReqLLM.StreamChunk

  @provider_schema [
    siwc_account: [type: :string, doc: "Genesis ChatGPT registration alias"],
    prompt_cache_key: [type: :string, doc: "Stable Responses cache identity"],
    session_id: [type: :string, doc: "Legacy cache identity alias"]
  ]

  @unsupported_fields ~w(background conversation max_output_tokens max_tool_calls metadata moderation
    multi_agent prompt prompt_cache_retention safety_identifier temperature top_logprobs top_p truncation user
    previous_response_id context_management)
  @supported_tools ~w(namespace web_search web_search_preview)

  @impl true
  def stream_transport(_model, _opts), do: :http

  @impl true
  def prepare_request(_operation, _model, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "ChatGPT subscription requires streaming"
     )}
  end

  @impl true
  def attach_stream(model, context, opts, _finch_name) do
    account = Keyword.get(opts[:provider_options] || [], :siwc_account, Store.default_account())

    with {:ok, token} <- Store.token(account, model_name(model)) do
      build_request(model, context, opts, token)
    else
      {:error, reason} ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(parameter: credential_error(reason, account))}
    end
  end

  defp credential_error(reason, account)
       when reason in [
              :no_credentials,
              :invalid_credentials,
              :reauthorization_required,
              :plan_not_authorized
            ] do
    "Reconnect this ChatGPT subscription on the execution node using genesis chatgpt login --account #{account}"
  end

  defp credential_error(:model_not_available_for_chatgpt_account, _account),
    do: "Choose a model available to this ChatGPT account"

  defp credential_error(reason, _account),
    do: "ChatGPT subscription connection: #{inspect(reason)}"

  @doc false
  def build_request(model, context, opts, token) do
    model = openai_model(model)
    name = model_name(model)

    context = %{
      context
      | messages:
          Enum.map(context.messages, fn
            %{role: :system} = message -> %{message | role: :developer}
            message -> message
          end)
    }

    original_provider_opts = opts[:provider_options] || []
    cache_key = original_provider_opts[:prompt_cache_key] || original_provider_opts[:session_id]
    # `siwc_account` is a Genesis registration alias, never an OpenAI body field.
    provider_opts = [store: false, prompt_cache_key: cache_key]

    opts =
      opts
      |> Keyword.put(:provider_options, provider_opts)
      |> Keyword.put(:stream, true)
      |> Keyword.delete(:responses_transport)

    body =
      context
      |> ResponsesAPI.build_request_body(name, opts, nil, :openai)
      |> Map.drop(@unsupported_fields)

    with {:ok, body} <- adapt_tools(body) do
      payload = body |> ReqLLM.Schema.apply_property_ordering() |> Jason.encode!()

      {:ok,
       Finch.build(
         :post,
         ChatGPT.resource() <> ResponsesAPI.path(),
         [
           {"authorization", "Bearer " <> token},
           {"content-type", "application/json"},
           {"accept", "text/event-stream"}
         ] ++ identity_headers(original_provider_opts, cache_key),
         payload
       )}
    end
  end

  # The per-agent-run identity rides BOTH the body `prompt_cache_key` and the
  # `session-id` header. Thread headers are emitted only when supplied.
  defp identity_headers(original_provider_opts, cache_key) do
    thread_id = original_provider_opts[:thread_id]

    [
      {"session-id", original_provider_opts[:session_id] || cache_key},
      {"thread-id", thread_id},
      {"x-client-request-id", thread_id}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end

  @impl true
  def init_stream_state(_model),
    do: %{responses: ResponsesAPI.init_stream_state(), terminal: false}

  @impl true
  def decode_stream_event(%{data: "[DONE]"}, _model), do: [missing_completion_error()]

  def decode_stream_event(event, model) do
    ResponsesAPI.decode_stream_event(event, openai_model(model))
    |> reject_incomplete(event)
  end

  @impl true
  def decode_stream_event(%{data: "[DONE]"}, _model, %{terminal: true} = state),
    do: {[], state}

  def decode_stream_event(%{data: "[DONE]"}, _model, state),
    do: {[missing_completion_error()], %{state | terminal: true}}

  def decode_stream_event(event, model, state) do
    {chunks, responses} =
      ResponsesAPI.decode_stream_event(event, openai_model(model), state.responses)

    chunks = reject_incomplete(chunks, event)
    terminal = state.terminal or Enum.any?(chunks, &ReqLLM.Streaming.Decoder.terminal_chunk?/1)
    {chunks, %{state | responses: responses, terminal: terminal}}
  end

  @impl true
  def flush_stream_state(_model, %{terminal: true} = state), do: {[], state}

  def flush_stream_state(_model, state), do: {[missing_completion_error()], state}

  defp missing_completion_error,
    do:
      StreamChunk.meta(%{
        terminal?: true,
        finish_reason: :error,
        error: "ChatGPT stream ended before completion"
      })

  defp reject_incomplete(chunks, event) do
    case event do
      %{data: %{"type" => "response.incomplete"}} -> incomplete_error(chunks)
      %{event: "response.incomplete"} -> incomplete_error(chunks)
      _ -> chunks
    end
  end

  defp incomplete_error(chunks) do
    chunks ++
      [
        StreamChunk.meta(%{
          terminal?: true,
          finish_reason: :error,
          error: "ChatGPT response is incomplete"
        })
      ]
  end

  defp adapt_tools(%{"tools" => tools} = body) when is_list(tools) do
    {functions, other} = Enum.split_with(tools, &(&1["type"] in ["function", "custom"]))

    if Enum.all?(other, &(&1["type"] in @supported_tools)) do
      supported =
        case functions do
          [] ->
            other

          _ ->
            [
              %{
                "type" => "namespace",
                "name" => "genesis",
                "description" => "Genesis tools",
                "tools" => functions
              }
              | other
            ]
        end

      {:ok, Map.put(body, "tools", supported)}
    else
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter: "Tool is unavailable with ChatGPT plan usage"
       )}
    end
  end

  defp adapt_tools(body), do: {:ok, body}

  defp openai_model(nil), do: nil
  defp openai_model(model), do: %{model | provider: :openai}
  defp model_name(model), do: model.provider_model_id || model.id
end
