defmodule LLMDB.Validate do
  @moduledoc """
  Validation functions for providers and models using Zoi schemas.

  Provides functions to validate individual records or batches of records,
  handling errors gracefully and ensuring catalog viability.
  """

  require Logger

  alias LLMDB.{Model, Provider}

  @type validation_error :: term()

  @execution_operations [:text, :object, :embed, :image, :transcription, :speech, :realtime]

  @openai_compatible_providers MapSet.new([
                                 :openai,
                                 :openrouter,
                                 :groq,
                                 :xai,
                                 :zenmux,
                                 :mistral,
                                 :togetherai,
                                 :github_models,
                                 :perplexity,
                                 :cloudflare_workers_ai,
                                 :fireworks_ai,
                                 :friendli,
                                 :ollama_cloud,
                                 :deepseek,
                                 :alibaba,
                                 :venice,
                                 :cerebras,
                                 :zai
                               ])
  @execution_families [
    "openai_chat_compatible",
    "openai_responses_compatible",
    "openai_embeddings",
    "openai_images",
    "openai_transcription",
    "openai_speech",
    "openai_realtime",
    "anthropic_messages",
    "google_generate_content",
    "cohere_chat",
    "elevenlabs_speech",
    "elevenlabs_transcription"
  ]

  @doc """
  Validates a single provider map against the Provider schema.

  ## Examples

      iex> validate_provider(%{id: :openai})
      {:ok, %{id: :openai}}

      iex> validate_provider(%{id: "openai"})
      {:error, _}
  """
  @spec validate_provider(map()) :: {:ok, Provider.t()} | {:error, validation_error()}
  def validate_provider(map) when is_map(map) do
    Zoi.parse(Provider.schema(), map)
  end

  @doc """
  Validates a single model map against the Model schema.

  ## Examples

      iex> validate_model(%{id: "gpt-4o", provider: :openai})
      {:ok, %{id: "gpt-4o", provider: :openai, deprecated: false, aliases: []}}

      iex> validate_model(%{id: "gpt-4o"})
      {:error, _}
  """
  @spec validate_model(map()) :: {:ok, Model.t()} | {:error, validation_error()}
  def validate_model(map) when is_map(map) do
    Zoi.parse(Model.schema(), map)
  end

  @doc """
  Validates a provider map and returns a sparse overlay that preserves only the
  explicitly supplied fields plus required identity.
  """
  @spec validate_provider_overlay(map()) :: {:ok, map()} | {:error, validation_error()}
  def validate_provider_overlay(map) when is_map(map),
    do: validate_overlay(map, &validate_provider/1, [:id])

  @doc """
  Validates a model map and returns a sparse overlay that preserves only the
  explicitly supplied fields plus required identity.
  """
  @spec validate_model_overlay(map()) :: {:ok, map()} | {:error, validation_error()}
  def validate_model_overlay(map) when is_map(map),
    do: validate_overlay(map, &validate_model/1, [:id, :provider])

  @doc """
  Validates a list of provider maps, collecting valid ones and counting invalid.

  Returns all valid providers and the count of invalid ones that were dropped.

  ## Examples

      iex> providers = [%{id: :openai}, %{id: "invalid"}, %{id: :anthropic}]
      iex> validate_providers(providers)
      {:ok, [%{id: :openai}, %{id: :anthropic}], 1}
  """
  @spec validate_providers([map()]) :: {:ok, [Provider.t()], non_neg_integer()}
  def validate_providers(maps) when is_list(maps), do: validate_many(maps, &validate_provider/1)

  @doc """
  Validates a list of provider maps and returns sparse overlays suitable for merge.
  """
  @spec validate_providers_for_merge([map()]) :: {:ok, [map()], non_neg_integer()}
  def validate_providers_for_merge(maps) when is_list(maps),
    do: validate_many(maps, &validate_provider_overlay/1)

  @doc """
  Validates a list of model maps, collecting valid ones and counting invalid.

  Returns all valid models and the count of invalid ones that were dropped.

  ## Examples

      iex> models = [
      ...>   %{id: "gpt-4o", provider: :openai},
      ...>   %{id: :invalid, provider: :openai},
      ...>   %{id: "claude-3", provider: :anthropic}
      ...> ]
      iex> validate_models(models)
      {:ok, [%{id: "gpt-4o", ...}, %{id: "claude-3", ...}], 1}
  """
  @spec validate_models([map()]) :: {:ok, [Model.t()], non_neg_integer()}
  def validate_models(maps) when is_list(maps),
    do: validate_many(maps, &validate_model/1, &log_model_validation_error/2)

  @doc """
  Validates a list of model maps and returns sparse overlays suitable for merge.
  """
  @spec validate_models_for_merge([map()]) :: {:ok, [map()], non_neg_integer()}
  def validate_models_for_merge(maps) when is_list(maps),
    do: validate_many(maps, &validate_model_overlay/1, &log_model_validation_error/2)

  @doc """
  Validates typed provider runtime and model execution metadata after merge/enrichment.

  This validator is migration-safe:
  - providers without `runtime` are accepted for now
  - models without `execution` are accepted for now
  - once typed metadata is present, invalid declarations fail
  - `catalog_only: true` opts a provider or model out of execution requirements
  """
  @spec validate_runtime_contract([Provider.t()], [Model.t()]) ::
          :ok | {:error, {:invalid_runtime_contract, [map()]}}
  def validate_runtime_contract(providers, models)
      when is_list(providers) and is_list(models) do
    provider_lookup = Map.new(providers, &{&1.id, &1})

    errors =
      Enum.flat_map(providers, &provider_runtime_errors/1) ++
        Enum.flat_map(models, &model_execution_errors(&1, Map.get(provider_lookup, &1.provider)))

    if errors == [] do
      :ok
    else
      {:error, {:invalid_runtime_contract, errors}}
    end
  end

  @doc """
  Ensures that we have at least one provider and one model for a viable catalog.

  Returns :ok if both lists are non-empty, otherwise returns an error.

  ## Examples

      iex> ensure_viable([%{id: :openai}], [%{id: "gpt-4o", provider: :openai}])
      :ok

      iex> ensure_viable([], [%{id: "gpt-4o", provider: :openai}])
      {:error, :empty_catalog}

      iex> ensure_viable([%{id: :openai}], [])
      {:error, :empty_catalog}
  """
  @spec ensure_viable([Provider.t()], [Model.t()]) :: :ok | {:error, :empty_catalog}
  def ensure_viable(providers, models)
      when is_list(providers) and is_list(models) do
    if providers != [] and models != [] do
      :ok
    else
      {:error, :empty_catalog}
    end
  end

  defp provider_runtime_errors(%Provider{catalog_only: true}), do: []

  defp provider_runtime_errors(%Provider{id: provider_id, runtime: runtime})
       when is_map(runtime) do
    auth = Map.get(runtime, :auth)

    []
    |> maybe_add_error(is_nil(Map.get(runtime, :base_url)), %{
      scope: :provider,
      provider: provider_id,
      error: :missing_runtime_base_url
    })
    |> maybe_add_error(is_nil(auth), %{
      scope: :provider,
      provider: provider_id,
      error: :missing_runtime_auth
    })
    |> maybe_add_error(not valid_auth?(auth), %{
      scope: :provider,
      provider: provider_id,
      error: :invalid_runtime_auth,
      auth: auth
    })
  end

  defp provider_runtime_errors(%Provider{}), do: []

  defp model_execution_errors(%Model{catalog_only: true}, _provider), do: []

  defp model_execution_errors(%Model{execution: execution} = model, provider)
       when is_map(execution) do
    implied = implied_operations(model)

    entry_errors =
      Enum.flat_map(@execution_operations, fn operation ->
        case Map.get(execution, operation) do
          nil ->
            if operation in implied do
              [
                %{
                  scope: :model,
                  provider: model.provider,
                  model_id: model.id,
                  operation: operation,
                  error: :missing_execution_entry
                }
              ]
            else
              []
            end

          entry when is_map(entry) ->
            execution_entry_errors(model, operation, entry, provider)
        end
      end)

    provider_errors =
      if executable_model?(execution) and is_nil(provider_runtime(provider)) and
           not catalog_only?(provider) do
        [
          %{
            scope: :model,
            provider: model.provider,
            model_id: model.id,
            error: :provider_runtime_required_for_execution
          }
        ]
      else
        []
      end

    entry_errors ++ provider_errors
  end

  defp model_execution_errors(%Model{}, _provider), do: []

  defp execution_entry_errors(model, operation, entry, _provider) do
    supported? = Map.get(entry, :supported) == true
    family = Map.get(entry, :family)

    []
    |> maybe_add_error(supported? and is_nil(family), %{
      scope: :model,
      provider: model.provider,
      model_id: model.id,
      operation: operation,
      error: :missing_execution_family
    })
    |> maybe_add_error(
      supported? and is_binary(family) and family not in @execution_families,
      %{
        scope: :model,
        provider: model.provider,
        model_id: model.id,
        operation: operation,
        error: :unknown_execution_family,
        family: family
      }
    )
  end

  defp implied_operations(%Model{} = model) do
    []
    |> maybe_add_operation(text_like?(model), :text)
    |> maybe_add_operation(text_like?(model), :object)
    |> maybe_add_operation(embeddings?(model), :embed)
    |> maybe_add_operation(image_generation?(model), :image)
    |> maybe_add_operation(transcription?(model), :transcription)
    |> maybe_add_operation(speech?(model), :speech)
    |> maybe_add_operation(realtime?(model), :realtime)
  end

  defp text_like?(%Model{} = model) do
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

  defp embeddings?(%Model{capabilities: capabilities}) when is_map(capabilities) do
    case Map.get(capabilities, :embeddings) do
      true -> true
      embeddings when is_map(embeddings) -> true
      _other -> false
    end
  end

  defp embeddings?(_model), do: false

  defp image_generation?(%Model{provider: provider, modalities: %{output: output}})
       when is_list(output) do
    provider in @openai_compatible_providers and :image in output
  end

  defp image_generation?(%Model{extra: extra}) when is_map(extra) do
    Map.get(extra, :api) == "images" or get_in(extra, [:wire, :protocol]) == "openai_images"
  end

  defp image_generation?(_model), do: false

  defp transcription?(%Model{} = model) do
    exclusive_transcription_model?(model) or explicit_transcription_model?(model)
  end

  defp explicit_transcription_model?(%Model{id: id, extra: extra}) do
    normalized_id = String.downcase(id)

    api =
      case extra do
        map when is_map(map) -> Map.get(map, :api)
        _other -> nil
      end

    api in ["audio.transcriptions", "audio.translation"] or
      String.contains?(normalized_id, "transcribe") or
      String.contains?(normalized_id, "whisper")
  end

  defp explicit_transcription_model?(_model), do: false

  defp speech?(%Model{} = model) do
    exclusive_speech_model?(model) or explicit_speech_model?(model)
  end

  defp explicit_speech_model?(%Model{id: id, extra: extra}) do
    normalized_id = String.downcase(id)

    api =
      case extra do
        map when is_map(map) -> Map.get(map, :api)
        _other -> nil
      end

    api == "audio.speech" or
      String.starts_with?(normalized_id, "tts-") or
      String.contains?(normalized_id, "-tts")
  end

  defp explicit_speech_model?(_model), do: false

  defp realtime?(%Model{provider: provider, id: id, extra: extra}) do
    extra_realtime? =
      case extra do
        map when is_map(map) ->
          Map.get(map, :api) == "realtime" or get_in(map, [:wire, :protocol]) == "openai_realtime"

        _other ->
          false
      end

    extra_realtime? or
      (provider == :openai and String.contains?(String.downcase(id), "realtime"))
  end

  defp realtime?(_model), do: false

  defp exclusive_media_model?(%Model{} = model) do
    embeddings?(model) or image_generation?(model) or realtime?(model) or
      exclusive_transcription_model?(model) or explicit_transcription_model?(model) or
      exclusive_speech_model?(model) or explicit_speech_model?(model)
  end

  defp exclusive_transcription_model?(%Model{} = model) do
    audio_input?(model) and text_output?(model) and not chat_capability?(model) and
      not text_input?(model)
  end

  defp exclusive_speech_model?(%Model{} = model) do
    text_input?(model) and audio_output?(model) and not chat_capability?(model) and
      not text_output?(model)
  end

  defp chat_capability?(%Model{capabilities: capabilities}) when is_map(capabilities) do
    Map.get(capabilities, :chat) == true
  end

  defp chat_capability?(_model), do: false

  defp no_capability_or_modality_metadata?(%Model{capabilities: nil, modalities: nil}), do: true
  defp no_capability_or_modality_metadata?(_model), do: false

  defp text_input?(%Model{modalities: %{input: input}}) when is_list(input), do: :text in input
  defp text_input?(_model), do: false

  defp text_output?(%Model{modalities: %{output: output}}) when is_list(output),
    do: :text in output

  defp text_output?(_model), do: false

  defp audio_input?(%Model{modalities: %{input: input}}) when is_list(input), do: :audio in input
  defp audio_input?(_model), do: false

  defp audio_output?(%Model{modalities: %{output: output}}) when is_list(output),
    do: :audio in output

  defp audio_output?(_model), do: false

  defp executable_model?(execution) when is_map(execution) do
    Enum.any?(@execution_operations, fn operation ->
      case Map.get(execution, operation) do
        %{supported: true} -> true
        _other -> false
      end
    end)
  end

  defp catalog_only?(%Provider{catalog_only: value}), do: value == true
  defp catalog_only?(_provider), do: false

  defp provider_runtime(%Provider{runtime: runtime}) when is_map(runtime), do: runtime
  defp provider_runtime(_provider), do: nil

  defp valid_auth?(nil), do: false

  defp valid_auth?(auth) when is_map(auth) do
    type = Map.get(auth, :type)
    env = Map.get(auth, :env, [])
    header_name = Map.get(auth, :header_name)
    query_name = Map.get(auth, :query_name)
    headers = Map.get(auth, :headers, [])

    cond do
      type in ["bearer", "x_api_key"] ->
        is_list(env) and env != []

      type == "header" ->
        is_binary(header_name) and is_list(env) and env != []

      type == "query" ->
        is_binary(query_name) and is_list(env) and env != []

      type == "multi_header" ->
        is_list(headers) and headers != []

      true ->
        false
    end
  end

  defp valid_auth?(_auth), do: false

  defp maybe_add_error(errors, true, error), do: [error | errors]
  defp maybe_add_error(errors, false, _error), do: errors

  defp maybe_add_operation(operations, true, operation), do: [operation | operations]
  defp maybe_add_operation(operations, false, _operation), do: operations

  defp validate_overlay(map, validator, required_keys) when is_map(map) do
    with {:ok, parsed} <- validator.(map) do
      {:ok, sparse_overlay(parsed, map, required_keys)}
    end
  end

  defp validate_many(maps, validator, on_error \\ fn _, _ -> :ok end) when is_list(maps) do
    {valid, invalid_count} =
      Enum.reduce(maps, {[], 0}, fn map, {valid_acc, invalid_acc} ->
        case validator.(map) do
          {:ok, item} ->
            {[item | valid_acc], invalid_acc}

          {:error, error} ->
            on_error.(map, error)
            {valid_acc, invalid_acc + 1}
        end
      end)

    {:ok, Enum.reverse(valid), invalid_count}
  end

  defp log_model_validation_error(map, error) do
    model_id = Map.get(map, :id, Map.get(map, "id", "unknown"))
    provider = Map.get(map, :provider, Map.get(map, "provider", "unknown"))

    Logger.warning(
      "Validation failed for model #{inspect(provider)}:#{inspect(model_id)}: #{inspect(error)}"
    )
  end

  defp sparse_overlay(parsed, raw, required_keys) when is_map(raw) do
    parsed_map =
      case parsed do
        struct when is_struct(struct) -> Map.from_struct(struct)
        map when is_map(map) -> map
      end

    explicit =
      Enum.reduce(raw, %{}, fn {raw_key, raw_value}, acc ->
        case overlay_key(raw_key, parsed_map) do
          nil ->
            acc

          key ->
            parsed_value = Map.get(parsed_map, key)
            Map.put(acc, key, sparse_overlay_value(parsed_value, raw_value))
        end
      end)

    Enum.reduce(required_keys, explicit, fn key, acc ->
      if Map.has_key?(acc, key) or not Map.has_key?(parsed_map, key) do
        acc
      else
        Map.put(acc, key, Map.get(parsed_map, key))
      end
    end)
  end

  defp sparse_overlay_value(parsed_value, raw_value)

  defp sparse_overlay_value(parsed_value, raw_value)
       when is_map(parsed_value) and is_map(raw_value) do
    sparse_overlay(parsed_value, raw_value, [])
  end

  defp sparse_overlay_value(parsed_value, raw_value)
       when is_list(parsed_value) and is_list(raw_value) do
    if length(parsed_value) == length(raw_value) and
         Enum.all?(raw_value, &is_map/1) and
         Enum.all?(parsed_value, &(is_map(&1) or is_struct(&1))) do
      Enum.zip(parsed_value, raw_value)
      |> Enum.map(fn {parsed_item, raw_item} ->
        sparse_overlay(parsed_item, raw_item, [])
      end)
    else
      parsed_value
    end
  end

  defp sparse_overlay_value(parsed_value, _raw_value), do: parsed_value

  defp overlay_key(raw_key, parsed_map) when is_map(parsed_map) do
    cond do
      Map.has_key?(parsed_map, raw_key) ->
        raw_key

      is_binary(raw_key) ->
        case maybe_existing_atom(raw_key) do
          {:ok, atom_key} ->
            if Map.has_key?(parsed_map, atom_key), do: atom_key

          :error ->
            nil
        end

      is_atom(raw_key) ->
        string_key = Atom.to_string(raw_key)

        if Map.has_key?(parsed_map, string_key) do
          string_key
        end

      true ->
        nil
    end
  end

  defp maybe_existing_atom(key) when is_binary(key) do
    try do
      {:ok, String.to_existing_atom(key)}
    rescue
      ArgumentError -> :error
    end
  end
end
