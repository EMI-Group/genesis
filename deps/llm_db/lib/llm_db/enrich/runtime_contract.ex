defmodule LLMDB.Enrich.RuntimeContract do
  @moduledoc """
  Deterministic runtime-contract enrichment for packaged provider and model data.

  This module upgrades descriptive catalog data into executable metadata where we
  have a stable contract for doing so. Providers and models we cannot execute
  safely are marked `catalog_only: true` so downstream consumers can distinguish
  between descriptive and executable entries without ad hoc heuristics.
  """

  alias LLMDB.{Merge, Model, Provider}

  @provider_runtime_defaults %{
    openai: %{
      base_url: "https://api.openai.com/v1",
      auth: %{type: "bearer"},
      doc_url: "https://platform.openai.com/docs"
    },
    anthropic: %{
      base_url: "https://api.anthropic.com",
      auth: %{type: "x_api_key", header_name: "x-api-key"},
      doc_url: "https://docs.anthropic.com"
    },
    google: %{
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      auth: %{type: "header", header_name: "x-goog-api-key"},
      doc_url: "https://ai.google.dev/docs"
    },
    openrouter: %{
      base_url: "https://openrouter.ai/api/v1",
      auth: %{type: "bearer"},
      doc_url: "https://openrouter.ai/docs"
    },
    groq: %{
      base_url: "https://api.groq.com/openai/v1",
      auth: %{type: "bearer"},
      doc_url: "https://groq.com/docs"
    },
    xai: %{
      base_url: "https://api.x.ai/v1",
      auth: %{type: "bearer"},
      doc_url: "https://docs.x.ai"
    },
    zenmux: %{
      base_url: "https://zenmux.ai/api/v1",
      auth: %{type: "bearer"},
      doc_url: "https://docs.zenmux.ai"
    },
    elevenlabs: %{
      base_url: "https://api.elevenlabs.io",
      auth: %{type: "header", header_name: "xi-api-key"},
      doc_url: "https://elevenlabs.io/docs/api-reference/introduction"
    },
    cohere: %{
      base_url: "https://api.cohere.com",
      auth: %{type: "bearer"},
      doc_url: "https://docs.cohere.com/docs/models"
    },
    mistral: %{
      base_url: "https://api.mistral.ai/v1",
      auth: %{type: "bearer"},
      doc_url: "https://docs.mistral.ai/getting-started/models/"
    },
    togetherai: %{
      base_url: "https://api.together.xyz/v1",
      auth: %{type: "bearer"},
      doc_url: "https://docs.together.ai/docs/serverless-models"
    },
    github_models: %{
      base_url: "https://models.github.ai/inference",
      auth: %{type: "bearer"},
      doc_url: "https://docs.github.com/en/github-models"
    },
    perplexity: %{
      base_url: "https://api.perplexity.ai",
      auth: %{type: "bearer"},
      doc_url: "https://docs.perplexity.ai"
    },
    cloudflare_workers_ai: %{
      base_url: "https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1",
      auth: %{type: "bearer", env: ["CLOUDFLARE_API_KEY"]},
      config_schema: [
        %{
          name: "account_id",
          type: "string",
          required: true,
          doc: "Cloudflare account ID used in the Workers AI base URL template."
        }
      ],
      doc_url: "https://developers.cloudflare.com/workers-ai/models/"
    },
    fireworks_ai: %{
      base_url: "https://api.fireworks.ai/inference/v1",
      auth: %{type: "bearer"},
      doc_url: "https://fireworks.ai/docs/"
    },
    friendli: %{
      base_url: "https://api.friendli.ai/serverless/v1",
      auth: %{type: "bearer"},
      doc_url: "https://friendli.ai/docs/guides/serverless_endpoints/introduction"
    },
    ollama_cloud: %{
      base_url: "https://ollama.com/v1",
      auth: %{type: "bearer"},
      doc_url: "https://docs.ollama.com/cloud"
    },
    deepseek: %{
      base_url: "https://api.deepseek.com",
      auth: %{type: "bearer"},
      doc_url: "https://api-docs.deepseek.com"
    },
    alibaba: %{
      base_url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
      auth: %{type: "bearer"},
      doc_url: "https://www.alibabacloud.com/help/en/model-studio/models"
    },
    venice: %{
      base_url: "https://api.venice.ai/api/v1",
      auth: %{type: "bearer"},
      doc_url: "https://docs.venice.ai"
    },
    cerebras: %{
      base_url: "https://api.cerebras.ai/v1",
      auth: %{type: "bearer"},
      doc_url: "https://cerebras.ai/docs"
    },
    zai: %{
      base_url: "https://api.z.ai/api/paas/v4",
      auth: %{type: "bearer"},
      doc_url: "https://docs.z.ai/guides/overview/pricing"
    }
  }

  @openai_compatible_providers Map.keys(@provider_runtime_defaults)
                               |> Enum.filter(
                                 &(&1 not in [:anthropic, :google, :cohere, :elevenlabs])
                               )
                               |> MapSet.new()

  @google_generation_methods MapSet.new([
                               "generateAnswer",
                               "generateContent",
                               "batchGenerateContent"
                             ])
  @google_embedding_methods MapSet.new(["embedContent", "asyncBatchEmbedContent"])
  @cohere_embedding_methods MapSet.new(["embed", "embedText", "embedTexts"])
  @cohere_rerank_methods MapSet.new(["rerank"])

  @family_wire_protocol %{
    "openai_chat_compatible" => "openai_chat",
    "openai_responses_compatible" => "openai_responses",
    "openai_embeddings" => "openai_embeddings",
    "openai_images" => "openai_images",
    "openai_transcription" => "openai_transcription",
    "openai_speech" => "openai_speech",
    "openai_realtime" => "openai_realtime",
    "anthropic_messages" => "anthropic_messages",
    "google_generate_content" => "google_generate_content",
    "cohere_chat" => "cohere_chat",
    "elevenlabs_speech" => "elevenlabs_speech",
    "elevenlabs_transcription" => "elevenlabs_transcription"
  }

  @family_paths %{
    "openai_chat_compatible" => "/chat/completions",
    "openai_responses_compatible" => "/responses",
    "openai_embeddings" => "/embeddings",
    "openai_images" => "/images/generations",
    "openai_transcription" => "/audio/transcriptions",
    "openai_speech" => "/audio/speech",
    "openai_realtime" => "/realtime",
    "anthropic_messages" => "/v1/messages",
    "google_generate_content" => "/models/{provider_model_id}:generateContent",
    "cohere_chat" => "/v2/chat",
    "elevenlabs_speech" => "/v1/text-to-speech/{provider_model_id}",
    "elevenlabs_transcription" => "/v1/speech-to-text"
  }

  @rerank_capabilities %{
    chat: false,
    embeddings: false,
    reasoning: %{enabled: false},
    rerank: true,
    tools: %{enabled: false, streaming: false, strict: false, parallel: false},
    json: %{native: false, schema: false, strict: false},
    streaming: %{text: false, tool_calls: false}
  }

  @spec enrich([Provider.t()], [Model.t()]) :: {[Provider.t()], [Model.t()]}
  def enrich(providers, models) when is_list(providers) and is_list(models) do
    enriched_providers = Enum.map(providers, &enrich_provider/1)
    provider_lookup = Map.new(enriched_providers, &{&1.id, &1})

    enriched_models =
      Enum.map(models, fn model ->
        enrich_model(model, Map.get(provider_lookup, model.provider))
      end)

    {enriched_providers, enriched_models}
  end

  @spec enrich_provider(Provider.t()) :: Provider.t()
  def enrich_provider(%Provider{} = provider) do
    runtime = resolved_runtime(provider)

    catalog_only =
      provider.catalog_only or
        (is_nil(provider.runtime) and is_nil(runtime))

    provider
    |> Map.put(:runtime, runtime)
    |> Map.put(:catalog_only, catalog_only)
  end

  @spec enrich_model(Model.t(), Provider.t() | nil) :: Model.t()
  def enrich_model(%Model{} = model, provider) do
    execution =
      model
      |> derive_execution(provider)
      |> merge_execution(model.execution)
      |> normalize_execution()

    capabilities =
      merge_capabilities(model.capabilities, derive_capabilities(model))

    catalog_only =
      model.catalog_only or
        is_nil(provider) or
        Map.get(provider, :catalog_only) == true or
        (is_nil(model.execution) and not executable_execution?(execution))

    model
    |> Map.put(:execution, execution)
    |> Map.put(:capabilities, capabilities)
    |> Map.put(:catalog_only, catalog_only)
  end

  defp resolved_runtime(%Provider{id: provider_id} = provider) do
    defaults = Map.get(@provider_runtime_defaults, provider_id)
    existing = provider.runtime

    cond do
      is_map(existing) and runtime_complete?(existing) ->
        normalize_runtime(existing, provider)

      is_map(defaults) ->
        defaults
        |> normalize_runtime(provider)
        |> merge_runtime(existing, provider)
        |> maybe_runtime(existing)

      is_map(existing) ->
        existing
        |> normalize_runtime(provider)
        |> maybe_runtime(existing)

      true ->
        nil
    end
  end

  defp normalize_runtime(runtime, provider) do
    auth =
      runtime
      |> Map.get(:auth, %{})
      |> normalize_auth(provider)

    %{
      base_url: Map.get(runtime, :base_url) || provider.base_url,
      auth: auth,
      default_headers: Map.get(runtime, :default_headers, %{}),
      default_query: Map.get(runtime, :default_query, %{}),
      config_schema: Map.get(runtime, :config_schema) || provider.config_schema,
      doc_url: Map.get(runtime, :doc_url) || provider.doc
    }
  end

  defp normalize_auth(auth, provider) do
    env =
      case Map.get(auth, :env) do
        env when is_list(env) and env != [] -> env
        _other -> provider.env || []
      end

    auth
    |> Map.put(:env, env)
    |> Map.put_new(:headers, [])
  end

  defp merge_runtime(defaults, existing, provider) when is_map(existing) do
    auth = defaults.auth |> Map.merge(Map.get(existing, :auth, %{})) |> normalize_auth(provider)

    %{
      base_url: Map.get(existing, :base_url) || defaults.base_url || provider.base_url,
      auth: auth,
      default_headers:
        Map.merge(defaults.default_headers || %{}, Map.get(existing, :default_headers, %{})),
      default_query:
        Map.merge(defaults.default_query || %{}, Map.get(existing, :default_query, %{})),
      config_schema:
        Map.get(existing, :config_schema) || defaults.config_schema || provider.config_schema,
      doc_url: Map.get(existing, :doc_url) || defaults.doc_url || provider.doc
    }
  end

  defp merge_runtime(defaults, _existing, _provider), do: defaults

  defp maybe_runtime(runtime, existing) do
    cond do
      runtime_complete?(runtime) ->
        runtime

      is_map(existing) ->
        runtime

      true ->
        nil
    end
  end

  defp runtime_complete?(%{base_url: base_url, auth: auth})
       when is_binary(base_url) and is_map(auth) do
    valid_auth?(auth)
  end

  defp runtime_complete?(_runtime), do: false

  defp valid_auth?(%{type: type, env: env}) when type in ["bearer", "x_api_key"],
    do: is_list(env) and env != []

  defp valid_auth?(%{type: "header", env: env, header_name: header_name}),
    do: is_binary(header_name) and is_list(env) and env != []

  defp valid_auth?(%{type: "query", env: env, query_name: query_name}),
    do: is_binary(query_name) and is_list(env) and env != []

  defp valid_auth?(%{type: "multi_header", headers: headers}),
    do: is_list(headers) and headers != []

  defp valid_auth?(_auth), do: false

  defp derive_execution(
         %Model{} = model,
         %Provider{id: provider_id, catalog_only: false}
       ) do
    []
    |> maybe_put_entry(:text, text_entry(model, provider_id))
    |> maybe_put_entry(:object, object_entry(model, provider_id))
    |> maybe_put_entry(:embed, embed_entry(model, provider_id))
    |> maybe_put_entry(:image, image_entry(model, provider_id))
    |> maybe_put_entry(:transcription, transcription_entry(model, provider_id))
    |> maybe_put_entry(:speech, speech_entry(model, provider_id))
    |> maybe_put_entry(:realtime, realtime_entry(model, provider_id))
    |> Map.new()
    |> nil_if_empty()
  end

  defp derive_execution(_model, _provider), do: nil

  defp text_entry(model, provider_id) do
    if text_object_capable?(model, provider_id) do
      execution_entry(model, provider_id, text_object_family(model, provider_id))
    end
  end

  defp object_entry(model, provider_id) do
    if text_object_capable?(model, provider_id) do
      execution_entry(model, provider_id, text_object_family(model, provider_id))
    end
  end

  defp embed_entry(model, provider_id) do
    cond do
      provider_id == :google and google_embedding_model?(model) ->
        nil

      provider_id == :cohere and cohere_embedding_or_rerank_model?(model) ->
        nil

      provider_id in @openai_compatible_providers and embedding_model?(model) ->
        execution_entry(model, provider_id, "openai_embeddings")

      true ->
        nil
    end
  end

  defp image_entry(model, provider_id) do
    if provider_id in @openai_compatible_providers and image_generation_model?(model) do
      execution_entry(model, provider_id, "openai_images")
    end
  end

  defp transcription_entry(model, provider_id) do
    cond do
      provider_id == :elevenlabs and elevenlabs_transcription_model?(model) ->
        execution_entry(model, provider_id, "elevenlabs_transcription")

      provider_id in @openai_compatible_providers and dedicated_transcription_model?(model) ->
        execution_entry(model, provider_id, "openai_transcription")

      true ->
        nil
    end
  end

  defp speech_entry(model, provider_id) do
    cond do
      provider_id == :elevenlabs and elevenlabs_speech_model?(model) ->
        execution_entry(model, provider_id, "elevenlabs_speech")

      provider_id == :openai and openai_speech_model?(model) ->
        execution_entry(model, provider_id, "openai_speech")

      true ->
        nil
    end
  end

  defp realtime_entry(model, provider_id) do
    if provider_id == :openai and realtime_model?(model) do
      execution_entry(model, provider_id, "openai_realtime")
      |> Map.put(:transport, "websocket")
    end
  end

  defp text_object_capable?(model, provider_id) do
    family = text_object_family(model, provider_id)
    is_binary(family)
  end

  defp text_object_family(model, provider_id) do
    cond do
      google_text_object_model?(model, provider_id) ->
        "google_generate_content"

      provider_id == :anthropic and chat_generation_model?(model) ->
        "anthropic_messages"

      provider_id == :cohere and cohere_chat_model?(model) ->
        "cohere_chat"

      protocol = text_object_protocol(model) ->
        protocol_family(protocol)

      provider_id in @openai_compatible_providers and chat_generation_model?(model) ->
        "openai_chat_compatible"

      true ->
        nil
    end
  end

  defp google_text_object_model?(model, :google) do
    methods = supported_generation_methods(model)
    MapSet.disjoint?(@google_generation_methods, methods) == false
  end

  defp google_text_object_model?(_model, _provider_id), do: false

  defp cohere_chat_model?(model) do
    chat_generation_model?(model) and not cohere_embedding_or_rerank_model?(model)
  end

  defp cohere_embedding_or_rerank_model?(model) do
    methods = supported_generation_methods(model)

    MapSet.disjoint?(@cohere_embedding_methods, methods) == false or
      rerank_model?(model) or
      embedding_model?(model)
  end

  defp derive_capabilities(model) do
    if rerank_model?(model), do: @rerank_capabilities
  end

  defp merge_capabilities(nil, nil), do: nil
  defp merge_capabilities(nil, derived), do: derived
  defp merge_capabilities(existing, nil), do: existing

  defp merge_capabilities(existing, derived) when is_map(existing) and is_map(derived) do
    Merge.merge(existing, derived, :higher)
  end

  defp google_embedding_model?(model) do
    methods = supported_generation_methods(model)
    MapSet.disjoint?(@google_embedding_methods, methods) == false or embedding_model?(model)
  end

  defp text_object_protocol(model) do
    protocol =
      case wire_protocol(model) do
        "openai_chat" -> "openai_chat"
        "openai_responses" -> "openai_responses"
        "anthropic_messages" -> "anthropic_messages"
        _other -> nil
      end

    if protocol in ["openai_chat", "openai_responses", "anthropic_messages"], do: protocol
  end

  defp protocol_family("openai_chat"), do: "openai_chat_compatible"
  defp protocol_family("openai_responses"), do: "openai_responses_compatible"
  defp protocol_family("anthropic_messages"), do: "anthropic_messages"
  defp protocol_family(_protocol), do: nil

  defp execution_entry(model, provider_id, family) when is_binary(family) do
    wire_protocol = Map.get(@family_wire_protocol, family)
    provider_model_id = provider_model_id_override(model)
    base_url = model_base_url_override(model, provider_id)

    %{
      supported: true,
      family: family,
      wire_protocol: wire_protocol,
      provider_model_id: provider_model_id,
      base_url: base_url,
      path: Map.get(@family_paths, family)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp provider_model_id_override(%Model{id: id, provider_model_id: provider_model_id})
       when is_binary(provider_model_id) and provider_model_id != id,
       do: provider_model_id

  defp provider_model_id_override(_model), do: nil

  defp model_base_url_override(%Model{base_url: base_url}, provider_id)
       when is_binary(base_url) do
    provider_base_url =
      @provider_runtime_defaults
      |> Map.get(provider_id, %{})
      |> Map.get(:base_url)

    if base_url != provider_base_url, do: base_url
  end

  defp model_base_url_override(_model, _provider_id), do: nil

  defp merge_execution(nil, existing), do: existing
  defp merge_execution(derived, nil), do: derived

  defp merge_execution(derived, existing) when is_map(derived) and is_map(existing) do
    Map.merge(derived, existing, fn _operation, derived_entry, existing_entry ->
      Map.merge(derived_entry, existing_entry)
    end)
  end

  defp normalize_execution(nil), do: nil

  defp normalize_execution(execution) when is_map(execution) do
    execution
    |> Enum.reject(fn {_operation, entry} -> is_nil(entry) end)
    |> Enum.map(fn {operation, entry} ->
      normalized_entry =
        entry
        |> Map.put_new(:supported, true)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      {operation, normalized_entry}
    end)
    |> Map.new()
    |> nil_if_empty()
  end

  defp executable_execution?(nil), do: false

  defp executable_execution?(execution) when is_map(execution) do
    Enum.any?(execution, fn {_operation, entry} ->
      is_map(entry) and Map.get(entry, :supported) == true and is_binary(Map.get(entry, :family))
    end)
  end

  defp maybe_put_entry(entries, _operation, nil), do: entries
  defp maybe_put_entry(entries, operation, entry), do: [{operation, entry} | entries]

  defp nil_if_empty(map) when map in [%{}, []], do: nil
  defp nil_if_empty(map), do: map

  defp wire_protocol(%Model{extra: extra}) when is_map(extra) do
    wire = Map.get(extra, :wire) || Map.get(extra, "wire") || %{}

    protocol =
      cond do
        is_map(wire) ->
          Map.get(wire, :protocol) || Map.get(wire, "protocol")

        true ->
          nil
      end

    normalize_string(
      protocol || Map.get(extra, :wire_protocol) || Map.get(extra, "wire_protocol") ||
        Map.get(extra, :api) || Map.get(extra, "api")
    )
  end

  defp wire_protocol(_model), do: nil

  defp supported_generation_methods(%Model{extra: extra}) when is_map(extra) do
    extra
    |> then(fn map ->
      Map.get(map, :supported_generation_methods) ||
        Map.get(map, "supported_generation_methods") || []
    end)
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp supported_generation_methods(_model), do: MapSet.new()

  defp rerank_model?(model) do
    rerank_capability?(model) or
      rerank_type?(model) or
      rerank_generation_method?(model) or
      rerank_named_model?(model)
  end

  defp rerank_capability?(%Model{capabilities: %{rerank: true}}), do: true
  defp rerank_capability?(_model), do: false

  defp rerank_type?(%Model{extra: extra}) when is_map(extra) do
    normalize_string(Map.get(extra, :type) || Map.get(extra, "type")) == "rerank"
  end

  defp rerank_type?(_model), do: false

  defp rerank_generation_method?(model) do
    methods = supported_generation_methods(model)
    MapSet.disjoint?(@cohere_rerank_methods, methods) == false
  end

  defp rerank_named_model?(%Model{id: id, name: name}) do
    rerank_name?(id) or rerank_name?(name)
  end

  defp rerank_name?(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.contains?("rerank")
  end

  defp rerank_name?(_value), do: false

  defp chat_generation_model?(model) do
    cond do
      exclusive_media_model?(model) ->
        false

      chat_capability?(model) ->
        true

      text_input?(model) and text_output?(model) ->
        true

      no_capability_or_modality_metadata?(model) ->
        true

      true ->
        false
    end
  end

  defp chat_capability?(%Model{capabilities: %{chat: true}}), do: true
  defp chat_capability?(_model), do: false

  defp no_capability_or_modality_metadata?(%Model{capabilities: nil, modalities: nil}), do: true
  defp no_capability_or_modality_metadata?(_model), do: false

  defp text_input?(%Model{modalities: %{input: input}}) when is_list(input), do: :text in input
  defp text_input?(_model), do: false

  defp text_output?(%Model{modalities: %{output: output}}) when is_list(output),
    do: :text in output

  defp text_output?(%Model{capabilities: %{chat: true}}), do: true
  defp text_output?(_model), do: false

  defp embedding_model?(%Model{modalities: %{output: output}}) when is_list(output),
    do: :embedding in output

  defp embedding_model?(%Model{capabilities: capabilities}) when is_map(capabilities) do
    case Map.get(capabilities, :embeddings) do
      true -> true
      embeddings when is_map(embeddings) -> true
      _other -> false
    end
  end

  defp embedding_model?(%Model{extra: extra}) when is_map(extra) do
    normalize_string(Map.get(extra, :type) || Map.get(extra, "type")) == "embedding"
  end

  defp embedding_model?(_model), do: false

  defp image_generation_model?(%Model{modalities: %{output: output}}) when is_list(output),
    do: :image in output

  defp image_generation_model?(model) do
    wire_protocol(model) in ["images", "openai_images"]
  end

  defp transcription_model?(%Model{id: id} = model) do
    normalized_id = String.downcase(id)

    audio_transcription_shape?(model) or
      wire_protocol(model) in ["audio", "audio.transcriptions", "audio.translation"] or
      String.contains?(normalized_id, "transcribe") or
      String.contains?(normalized_id, "whisper")
  end

  defp speech_model?(%Model{id: id} = model) do
    normalized_id = String.downcase(id)

    text_to_audio_shape?(model) or
      wire_protocol(model) in ["tts", "audio.speech"] or
      String.starts_with?(normalized_id, "tts-") or
      String.contains?(normalized_id, "-tts")
  end

  defp realtime_model?(%Model{id: id} = model) do
    normalized_id = String.downcase(id)

    wire_protocol(model) in ["realtime", "openai_realtime"] or
      String.contains?(normalized_id, "realtime")
  end

  defp openai_speech_model?(model), do: dedicated_speech_model?(model)
  defp elevenlabs_speech_model?(model), do: dedicated_speech_model?(model)

  defp elevenlabs_transcription_model?(model) do
    dedicated_transcription_model?(model) and not elevenlabs_speech_model?(model)
  end

  defp exclusive_media_model?(model) do
    embedding_model?(model) or image_generation_model?(model) or realtime_model?(model) or
      dedicated_transcription_model?(model) or dedicated_speech_model?(model)
  end

  defp dedicated_transcription_model?(model) do
    transcription_model?(model) and not chat_capability?(model) and not text_input?(model)
  end

  defp dedicated_speech_model?(model) do
    speech_model?(model) and not chat_capability?(model) and not text_output?(model)
  end

  defp audio_transcription_shape?(%Model{modalities: %{input: input, output: output}})
       when is_list(input) and is_list(output),
       do: :audio in input and :text in output

  defp audio_transcription_shape?(_model), do: false

  defp text_to_audio_shape?(%Model{modalities: %{input: input, output: output}})
       when is_list(input) and is_list(output),
       do: :text in input and :audio in output

  defp text_to_audio_shape?(_model), do: false

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(_value), do: nil
end
