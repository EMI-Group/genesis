defmodule LLMDB.Sources.OpenAI do
  @moduledoc """
  Remote source for OpenAI models (https://api.openai.com/v1/models).

  - `pull/1` fetches data from OpenAI API and caches locally
  - `load/1` reads from cached file (no network call)

  ## Options

  - `:url` - API endpoint (default: "https://api.openai.com/v1/models")
  - `:api_key` - OpenAI API key (required, or set `OPENAI_API_KEY` env var)
  - `:organization` - Optional OpenAI organization ID
  - `:project` - Optional OpenAI project ID
  - `:req_opts` - Additional Req options for testing

  ## Configuration

  Cache directory can be configured in application config:

      config :llm_db,
        openai_cache_dir: "priv/llm_db/remote"

  Default: `"priv/llm_db/remote"`

  ## Usage

      # Pull remote data and cache (requires API key)
      mix llm_db.pull --source openai

      # Load from cache
      {:ok, data} = OpenAI.load(%{})
  """

  @behaviour LLMDB.Source

  require Logger

  @default_url "https://api.openai.com/v1/models"
  @default_cache_dir "priv/llm_db/remote"

  @impl true
  def pull(opts) do
    api_key = get_api_key(opts)

    if is_nil(api_key) or api_key == "" do
      {:error, :no_api_key}
    else
      do_pull(opts, api_key)
    end
  end

  defp do_pull(opts, api_key) do
    url = Map.get(opts, :url, @default_url)
    cache_dir = get_cache_dir()
    cache_path = cache_path(url, cache_dir)
    manifest_path = manifest_path(url, cache_dir)
    req_opts = Map.get(opts, :req_opts, [])

    headers = build_headers(api_key, opts)
    headers = headers ++ Keyword.get(req_opts, :headers, [])
    req_opts = Keyword.put(req_opts, :headers, headers)

    cond_headers = build_cond_headers(manifest_path)
    headers = cond_headers ++ Keyword.get(req_opts, :headers, [])
    req_opts = Keyword.put(req_opts, :headers, headers)

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: 304}} ->
        :noop

      {:ok, %Req.Response{status: 200, body: body, headers: resp_headers}} ->
        bin =
          cond do
            is_map(body) or is_list(body) ->
              Jason.encode!(body, pretty: true)

            is_binary(body) ->
              case Jason.decode(body) do
                {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
                {:error, _} -> body
              end

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
  Transforms OpenAI API response to canonical Zoi format.

  ## Input Format (OpenAI)

  ```json
  {
    "object": "list",
    "data": [
      {
        "id": "gpt-4",
        "object": "model",
        "created": 1686935002,
        "owned_by": "openai"
      }
    ]
  }
  ```

  ## Output Format (Canonical Zoi)

  ```elixir
  %{
    "openai" => %{
      id: :openai,
      name: "OpenAI",
      models: [
        %{
          id: "gpt-4",
          provider: :openai,
          extra: %{
            created: 1686935002,
            owned_by: "openai"
          }
        }
      ]
    }
  }
  ```
  """
  def transform(content) when is_map(content) do
    models_list =
      content
      |> Map.get("data", [])
      |> Enum.map(&transform_model/1)

    %{
      "openai" => %{
        id: :openai,
        name: "OpenAI",
        models: models_list
      }
    }
  end

  defp transform_model(model) do
    %{
      id: model["id"],
      provider: :openai,
      extra: %{
        created: model["created"],
        owned_by: model["owned_by"]
      }
    }
  end

  defp get_api_key(opts) do
    Map.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")
  end

  defp get_cache_dir do
    Application.get_env(:llm_db, :openai_cache_dir, @default_cache_dir)
  end

  defp cache_path(url, cache_dir) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join(cache_dir, "openai-#{hash}.json")
  end

  defp manifest_path(url, cache_dir) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join(cache_dir, "openai-#{hash}.manifest.json")
  end

  defp build_headers(api_key, opts) do
    headers = [{"authorization", "Bearer #{api_key}"}]

    headers =
      case Map.get(opts, :organization) do
        nil -> headers
        org -> [{"openai-organization", org} | headers]
      end

    case Map.get(opts, :project) do
      nil -> headers
      project -> [{"openai-project", project} | headers]
    end
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
end
