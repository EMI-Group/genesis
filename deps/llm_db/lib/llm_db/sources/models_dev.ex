defmodule LLMDB.Sources.ModelsDev do
  @moduledoc """
  Remote source for models.dev metadata (https://models.dev/api.json).

  - `pull/1` fetches data via Req and caches locally
  - `load/1` reads from cached file (no network call)

  ## Options

  - `:url` - API endpoint (default: "https://models.dev/api.json")
  - `:req_opts` - Additional Req options for testing (e.g., `[plug: test_plug]`)

  ## Configuration

  Cache directory can be configured in application config:

      config :llm_db,
        models_dev_cache_dir: "priv/llm_db/remote"

  Default: `"priv/llm_db/remote"`

  ## Usage

      # Pull remote data and cache
      mix llm_db.pull

      # Load from cache
      {:ok, data} = ModelsDev.load(%{})
  """

  @behaviour LLMDB.Source

  require Logger

  @default_url "https://models.dev/api.json"
  @default_cache_dir "priv/llm_db/remote"

  @impl true
  def pull(opts) do
    url = Map.get(opts, :url, @default_url)
    cache_dir = get_cache_dir()
    cache_path = cache_path(url, cache_dir)
    manifest_path = manifest_path(url, cache_dir)
    req_opts = Map.get(opts, :req_opts, [])

    # Build conditional headers from manifest
    cond_headers = build_cond_headers(manifest_path)
    headers = cond_headers ++ Keyword.get(req_opts, :headers, [])
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
  Transforms models.dev JSON format to canonical Zoi format.

  ## Input Format (models.dev)

  ```json
  {
    "provider_id": {
      "id": "provider_id",
      "name": "Provider Name",
      "models": {
        "model_id": {
          "id": "model_id",
          "name": "Model Name",
          "limit": {"context": 128000, "output": 16384},
          "cost": {"input": 2.50, "output": 10.00},
          ...
        }
      }
    }
  }
  ```

  ## Output Format (Canonical Zoi)

  ```elixir
  %{
    "provider_id" => %{
      id: :provider_id,
      name: "Provider Name",
      models: [
        %{
          id: "model_id",
          provider: :provider_id,
          name: "Model Name",
          limits: %{context: 128000, output: 16384},
          cost: %{input: 2.50, output: 10.00},
          ...
        }
      ]
    }
  }
  ```

  Main transformations:
  - Convert provider string IDs to atom keys
  - Convert models map to models list
  - Add provider field to each model
  - Transform field names (limit → limits, etc.)
  - Atomize known field keys
  """
  def transform(content) when is_map(content), do: do_transform(content)

  # Private helpers

  defp get_cache_dir do
    Application.get_env(:llm_db, :models_dev_cache_dir, @default_cache_dir)
  end

  defp cache_path(url, cache_dir) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join(cache_dir, "models-dev-#{hash}.json")
  end

  defp manifest_path(url, cache_dir) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join(cache_dir, "models-dev-#{hash}.manifest.json")
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

  # Fields we explicitly map to canonical Zoi fields (should not go to extra)
  @mapped_fields ~w[
    id name knowledge release_date last_updated
    limit cost modalities reasoning tool_call
    aliases deprecated
  ]

  # Transform a single model from models.dev format to canonical Zoi format
  defp transform_model(model, provider_id) do
    # Build canonical model map with explicit field mappings
    canonical =
      %{
        id: model["id"],
        provider: provider_id,
        name: model["name"]
      }
      |> put_if_present(:knowledge, model["knowledge"])
      |> put_if_present(:release_date, model["release_date"])
      |> put_if_present(:last_updated, model["last_updated"])
      |> put_if_present(:aliases, model["aliases"])
      |> put_if_present(:deprecated, model["deprecated"])
      |> map_limits(model["limit"])
      |> map_cost(model["cost"])
      |> map_modalities(model["modalities"])
      |> map_capabilities(model)
      |> map_extra(model)

    canonical
  end

  # Map models.dev "limit" to canonical "limits"
  defp map_limits(model, nil), do: model

  defp map_limits(model, limit) when is_map(limit) do
    limits =
      %{}
      |> put_if_valid_limit(:context, limit["context"])
      |> put_if_valid_limit(:output, limit["output"])

    if map_size(limits) > 0 do
      Map.put(model, :limits, limits)
    else
      model
    end
  end

  # Map models.dev "cost" (passthrough with atom keys)
  defp map_cost(model, nil), do: model

  defp map_cost(model, cost) when is_map(cost) do
    cost_canonical =
      %{}
      |> put_if_present(:input, cost["input"])
      |> put_if_present(:output, cost["output"])
      |> put_if_present(:cache_read, cost["cache_read"])
      |> put_if_present(:cache_write, cost["cache_write"])
      |> put_if_present(:training, cost["training"])
      |> put_if_present(:reasoning, cost["reasoning"])
      |> put_if_present(:image, cost["image"])
      |> put_if_present(:audio, cost["audio"])
      |> put_if_present(:input_audio, cost["input_audio"])
      |> put_if_present(:output_audio, cost["output_audio"])
      |> put_if_present(:input_video, cost["input_video"])
      |> put_if_present(:output_video, cost["output_video"])

    if map_size(cost_canonical) > 0 do
      Map.put(model, :cost, cost_canonical)
    else
      model
    end
  end

  # Map models.dev "modalities" (atomize keys, values normalized later)
  defp map_modalities(model, nil), do: model

  defp map_modalities(model, modalities) when is_map(modalities) do
    # Atomize the input/output keys for Normalize to process
    modalities_atomized =
      modalities
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        atom_key =
          case key do
            "input" -> :input
            "output" -> :output
            other -> String.to_atom(other)
          end

        Map.put(acc, atom_key, value)
      end)

    Map.put(model, :modalities, modalities_atomized)
  end

  # Map models.dev boolean flags to canonical capabilities structure
  defp map_capabilities(model, source_model) do
    capabilities =
      %{}
      |> put_if_true(:reasoning, %{enabled: true}, source_model["reasoning"])
      |> put_if_true(:tools, %{enabled: true}, source_model["tool_call"])
      |> put_if_true(:streaming, %{tool_calls: true}, source_model["tool_call"])

    if map_size(capabilities) > 0 do
      Map.put(model, :capabilities, capabilities)
    else
      model
    end
  end

  # Collect unmapped fields into "extra" map
  defp map_extra(model, source_model) do
    extra =
      source_model
      |> Map.drop(@mapped_fields)
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        # Convert string keys to atoms for consistency
        atom_key = String.to_atom(key)
        Map.put(acc, atom_key, value)
      end)

    if map_size(extra) > 0 do
      Map.put(model, :extra, extra)
    else
      model
    end
  end

  # Helper: put value if not nil
  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  # Helper: put limit value if valid (not nil, not 0)
  defp put_if_valid_limit(map, _key, nil), do: map
  defp put_if_valid_limit(map, _key, 0), do: map

  defp put_if_valid_limit(map, key, value) when is_integer(value) and value > 0 do
    Map.put(map, key, value)
  end

  defp put_if_valid_limit(map, _key, _value), do: map

  # Helper: put nested map if boolean is true
  defp put_if_true(map, _key, _value, nil), do: map
  defp put_if_true(map, _key, _value, false), do: map
  defp put_if_true(map, key, value, true), do: Map.put(map, key, value)

  defp do_transform(content) when is_map(content) do
    # models.dev format: top-level keys are provider IDs,
    # each containing provider metadata + nested "models" map
    # Transform to nested format: %{provider_id => %{...provider, models: [...]}}

    content
    |> Enum.reduce(%{}, fn {provider_id, provider_data}, acc ->
      # Convert provider string keys to atom keys (keep models for now)
      provider_atomized = atomize_keys(provider_data, [:id, :name, :env, :doc])

      # Extract models from nested map and convert to list
      models_map = Map.get(provider_data, "models", %{})

      # Add provider field to each model and transform to canonical format
      models_list =
        models_map
        |> Map.values()
        |> Enum.map(fn model ->
          transform_model(model, provider_id)
        end)

      # Replace models map with models list and store
      provider_with_list = Map.put(provider_atomized, :models, models_list)
      Map.put(acc, provider_id, provider_with_list)
    end)
  end

  # Convert string keys to atom keys for specific known fields
  defp atomize_keys(map, keys) when is_map(map) do
    Enum.reduce(keys, map, fn key, acc ->
      string_key = to_string(key)

      if Map.has_key?(acc, string_key) do
        acc
        |> Map.put(key, Map.get(acc, string_key))
        |> Map.delete(string_key)
      else
        acc
      end
    end)
  end
end
