defmodule LLMDB.Sources.OpenRouter do
  @moduledoc """
  Remote source for OpenRouter metadata (https://openrouter.ai/api/v1/models).

  - `pull/1` fetches data via Req and caches locally
  - `load/1` reads from cached file (no network call)

  ## Options

  - `:url` - API endpoint (default: "https://openrouter.ai/api/v1/models")
  - `:req_opts` - Additional Req options for testing (e.g., `[plug: test_plug]`)
  - `:api_key` - OpenRouter API key (optional for public model list)

  ## Configuration

  Cache directory can be configured in application config:

      config :llm_db,
        openrouter_cache_dir: "priv/llm_db/upstream"

  Default: `"priv/llm_db/upstream"`

  ## Usage

      # Pull remote data and cache
      mix llm_db.pull

      # Load from cache
      {:ok, data} = OpenRouter.load(%{})
  """

  @behaviour LLMDB.Source

  require Logger

  @default_url "https://openrouter.ai/api/v1/models"
  @default_cache_dir "priv/llm_db/upstream"

  @impl true
  def pull(opts) do
    url = Map.get(opts, :url, @default_url)
    cache_dir = get_cache_dir()
    cache_path = cache_path(url, cache_dir)
    manifest_path = manifest_path(url, cache_dir)
    req_opts = Map.get(opts, :req_opts, [])

    # Build conditional headers from manifest
    cond_headers = build_cond_headers(manifest_path)

    # Add authorization header if API key provided
    auth_headers =
      case Map.get(opts, :api_key) do
        nil -> []
        key -> [{"authorization", "Bearer #{key}"}]
      end

    headers = cond_headers ++ auth_headers ++ Keyword.get(req_opts, :headers, [])
    req_opts = Keyword.put(req_opts, :headers, headers)

    # Disable automatic JSON decoding for more control
    req_opts = Keyword.put(req_opts, :decode_body, false)

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: 304}} ->
        :noop

      {:ok, %Req.Response{status: 200, body: body, headers: resp_headers}} ->
        bin =
          cond do
            is_binary(body) and String.starts_with?(body, ["{", "["]) ->
              case Jason.decode(body) do
                {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
                {:error, _} -> body
              end

            is_binary(body) ->
              case Jason.decode(body) do
                {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
                {:error, _} -> body
              end

            is_map(body) or is_list(body) ->
              Jason.encode!(body, pretty: true)

            true ->
              Jason.encode!(body, pretty: true)
          end

        write_cache(cache_path, manifest_path, bin, url, resp_headers)
        {:ok, cache_path}

      {:ok, %Req.Response{status: status}} when status >= 400 ->
        {:error, {:http_status, status}}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Unexpected status #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def load(opts) do
    url = Map.get(opts, :url, @default_url)
    cache_dir = get_cache_dir()
    cache_path = cache_path(url, cache_dir)

    case File.read(cache_path) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, decoded} -> {:ok, transform(decoded)}
          {:error, err} -> {:error, {:json_error, err}}
        end

      {:error, :enoent} ->
        {:error, :no_cache}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Transforms OpenRouter JSON format to canonical Zoi format.

  ## Input Format (OpenRouter)

  ```json
  {
    "data": [
      {
        "id": "openai/gpt-4",
        "name": "GPT-4",
        "context_length": 128000,
        "pricing": {
          "prompt": "0.00003",
          "completion": "0.00006"
        },
        "architecture": {
          "modality": "text->text",
          "tokenizer": "GPT",
          "instruct_type": "chatml"
        },
        "top_provider": {
          "max_completion_tokens": 16384
        },
        ...
      }
    ]
  }
  ```

  ## Output Format (Canonical Zoi)

  ```elixir
  %{
    "openrouter" => %{
      id: :openrouter,
      name: "OpenRouter",
      models: [
        %{
          id: "openai/gpt-4",
          provider: :openrouter,
          name: "GPT-4",
          limits: %{context: 128000, output: 16384},
          cost: %{input: 0.03, output: 0.06},
          ...
        },
        %{
          id: "perplexity/sonar-pro",
          provider: :openrouter,
          name: "Perplexity: Sonar Pro",
          ...
        }
      ]
    }
  }
  ```

  Main transformations:
  - Keep model IDs exactly as provided by OpenRouter (e.g., `perplexity/sonar-pro`)
  - All models registered under `:openrouter` provider only
  - Transform pricing strings to floats (per 1M tokens)
  - Map context_length → limits.context
  - Map top_provider.max_completion_tokens → limits.output
  - Extract modality information

  ## Provider Separation

  OpenRouter models are distinct from native provider models. For example:
  - `openrouter:perplexity/sonar-pro` - accessed via OpenRouter API
  - `perplexity:sonar-pro` - accessed via native Perplexity API (from Perplexity source)

  These are separate entries with potentially different pricing, limits, and capabilities.
  Model IDs may contain `/` which is part of the ID string, not a provider delimiter.
  """
  def transform(content) when is_map(content) do
    models = Map.get(content, "data", [])

    canonical_models =
      models
      |> Enum.map(&transform_model/1)

    %{
      "openrouter" => %{
        id: :openrouter,
        name: "OpenRouter",
        models: canonical_models
      }
    }
  end

  # Private helpers

  defp get_cache_dir do
    Application.get_env(:llm_db, :openrouter_cache_dir, @default_cache_dir)
  end

  defp cache_path(url, cache_dir) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join(cache_dir, "openrouter-#{hash}.json")
  end

  defp manifest_path(url, cache_dir) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join(cache_dir, "openrouter-#{hash}.manifest.json")
  end

  defp write_cache(cache_path, manifest_path, content, url, headers) do
    File.mkdir_p!(Path.dirname(cache_path))
    File.write!(cache_path, content)

    manifest = %{
      source_url: url,
      etag: get_header(headers, "etag"),
      last_modified: get_header(headers, "last-modified"),
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      size_bytes: byte_size(content),
      downloaded_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
  end

  defp build_cond_headers(manifest_path) do
    case File.read(manifest_path) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, manifest} ->
            headers = []

            headers =
              case Map.get(manifest, "etag") do
                etag when is_binary(etag) -> [{"if-none-match", etag} | headers]
                _ -> headers
              end

            headers =
              case Map.get(manifest, "last_modified") do
                last_mod when is_binary(last_mod) -> [{"if-modified-since", last_mod} | headers]
                _ -> headers
              end

            headers

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp get_header(headers, name) do
    case Enum.find(headers, fn {k, _} -> String.downcase(k) == name end) do
      {_, [v | _]} when is_list(v) -> v
      {_, v} when is_binary(v) -> v
      {_, v} when is_list(v) -> List.first(v)
      _ -> nil
    end
  end

  # Fields we explicitly map to canonical Zoi fields
  @mapped_fields ~w[
    id name description context_length pricing architecture
    top_provider supported_parameters default_parameters
    per_request_limits created canonical_slug
  ]

  defp transform_model(model) do
    # Keep the full OpenRouter model ID (including any "/")
    # All models are registered under :openrouter provider
    model_id = model["id"]

    canonical =
      %{
        id: model_id,
        provider: :openrouter,
        name: model["name"]
      }
      |> put_if_present(:description, model["description"])
      |> put_if_present(:release_date, parse_timestamp(model["created"]))
      |> map_limits(model)
      |> map_cost(model["pricing"])
      |> map_modalities(model["architecture"])
      |> map_capabilities(model)
      |> map_extra(model)

    canonical
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_integer(ts) do
    DateTime.from_unix!(ts)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp parse_timestamp(_), do: nil

  defp map_limits(model, source) do
    limits =
      %{}
      |> put_if_valid_limit(:context, source["context_length"])
      |> put_if_valid_limit(:output, get_in(source, ["top_provider", "max_completion_tokens"]))

    if map_size(limits) > 0 do
      Map.put(model, :limits, limits)
    else
      model
    end
  end

  defp map_cost(model, nil), do: model

  defp map_cost(model, pricing) when is_map(pricing) do
    cost =
      %{}
      |> put_cost_if_present(:input, pricing["prompt"])
      |> put_cost_if_present(:output, pricing["completion"])
      |> put_cost_if_present(:request, pricing["request"])
      |> put_cost_if_present(:reasoning, pricing["internal_reasoning"])
      |> put_cost_if_present(:image, pricing["image"])
      |> put_cost_if_present(:input_audio, pricing["input_audio"])
      |> put_cost_if_present(:output_audio, pricing["output_audio"])
      |> put_cost_if_present(:input_video, pricing["input_video"])
      |> put_cost_if_present(:output_video, pricing["output_video"])

    if map_size(cost) > 0 do
      Map.put(model, :cost, cost)
    else
      model
    end
  end

  defp put_cost_if_present(map, _key, nil), do: map

  defp put_cost_if_present(map, key, value) when is_binary(value) do
    case Float.parse(value) do
      {float_val, _} -> Map.put(map, key, Float.round(float_val * 1_000_000, 6))
      :error -> map
    end
  end

  defp put_cost_if_present(map, key, value) when is_number(value) do
    Map.put(map, key, Float.round(value * 1_000_000, 6))
  end

  defp put_cost_if_present(map, _key, _value), do: map

  defp map_modalities(model, nil), do: model

  defp map_modalities(model, arch) when is_map(arch) do
    case Map.get(arch, "modality") do
      nil ->
        model

      modality_str when is_binary(modality_str) ->
        modalities = parse_modality_string(modality_str)

        if map_size(modalities) > 0 do
          Map.put(model, :modalities, modalities)
        else
          model
        end

      _ ->
        model
    end
  end

  defp parse_modality_string(str) do
    case String.split(str, "->") do
      [input, output] ->
        %{
          input: parse_modality_list(input),
          output: parse_modality_list(output)
        }

      _ ->
        %{}
    end
  end

  defp parse_modality_list(str) do
    str
    |> String.split("+")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
  end

  defp map_capabilities(model, source) do
    capabilities = %{}

    capabilities =
      if Enum.member?(Map.get(source, "supported_parameters", []), "tools") do
        Map.put(capabilities, :tools, %{enabled: true})
      else
        capabilities
      end

    if map_size(capabilities) > 0 do
      Map.put(model, :capabilities, capabilities)
    else
      model
    end
  end

  defp map_extra(model, source) do
    extra =
      source
      |> Map.drop(@mapped_fields)
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        atom_key = String.to_atom(key)
        Map.put(acc, atom_key, value)
      end)

    if map_size(extra) > 0 do
      Map.put(model, :extra, extra)
    else
      model
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp put_if_valid_limit(map, _key, nil), do: map
  defp put_if_valid_limit(map, _key, 0), do: map

  defp put_if_valid_limit(map, key, value) when is_integer(value) and value > 0 do
    Map.put(map, key, value)
  end

  defp put_if_valid_limit(map, _key, _value), do: map
end
