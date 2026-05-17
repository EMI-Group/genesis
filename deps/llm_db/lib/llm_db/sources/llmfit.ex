defmodule LLMDB.Sources.Llmfit do
  @moduledoc """
  Sidecar source for llmfit open-weight metadata.

  This module is intentionally **not** a primary catalog source. It is used to:

  - `pull/1` fetch and cache llmfit's `hf_models.json`
  - `load_index/1` build a lookup index by Hugging Face repo ID for enrichment

  `load/1` returns an empty canonical map so this source can participate in
  generic source workflows without injecting non-canonical providers/models.
  """

  @behaviour LLMDB.Source

  require Logger

  @default_url "https://raw.githubusercontent.com/AlexsJones/llmfit/main/data/hf_models.json"
  @default_cache_dir "priv/llm_db/upstream"

  @valid_pipeline_tags MapSet.new([
                         "text-generation",
                         "image-text-to-text",
                         "feature-extraction"
                       ])

  # Keep enrichment data high-signal by rejecting obvious test/dummy repos.
  @noise_repo_pattern ~r/(?:peft-internal-testing|optimum-intel-internal-testing|nm-testing|tiny-random|unit-test|dummy)/i

  # 50M param floor avoids tiny random/unit-test artifacts.
  @min_parameters 50_000_000

  @impl true
  def pull(opts) do
    url = Map.get(opts, :url, @default_url)
    cache_dir = get_cache_dir()
    cache_path = cache_path(url, cache_dir)
    manifest_path = manifest_path(url, cache_dir)
    req_opts = Map.get(opts, :req_opts, [])

    cond_headers = build_cond_headers(manifest_path)
    headers = cond_headers ++ Keyword.get(req_opts, :headers, [])
    req_opts = Keyword.put(req_opts, :headers, headers)
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
  def load(_opts), do: {:ok, %{}}

  @doc """
  Load raw llmfit metadata list from cache.
  """
  @spec load_raw(map()) :: {:ok, [map()]} | {:error, term()}
  def load_raw(opts \\ %{}) do
    url = Map.get(opts, :url, @default_url)
    cache_dir = get_cache_dir()
    path = cache_path(url, cache_dir)

    case File.read(path) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
          {:ok, _other} -> {:error, :invalid_shape}
          {:error, err} -> {:error, {:json_error, err}}
        end

      {:error, :enoent} ->
        {:error, :no_cache}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Build an enrichment index keyed by Hugging Face repo ID (`org/model`).
  """
  @spec load_index(map()) :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def load_index(opts \\ %{}) do
    with {:ok, rows} <- load_raw(opts) do
      {:ok, index_rows(rows)}
    end
  end

  # Private helpers

  defp get_cache_dir do
    Application.get_env(:llm_db, :llmfit_cache_dir, @default_cache_dir)
  end

  defp cache_path(url, cache_dir) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join(cache_dir, "llmfit-#{hash}.json")
  end

  defp manifest_path(url, cache_dir) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join(cache_dir, "llmfit-#{hash}.manifest.json")
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

  defp index_rows(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      with true <- is_map(row),
           repo_id when is_binary(repo_id) <- Map.get(row, "name"),
           true <- eligible_row?(row),
           normalized <- normalize_row(row) do
        Map.put(acc, repo_id, normalized)
      else
        _ -> acc
      end
    end)
  end

  defp eligible_row?(row) do
    repo_id = Map.get(row, "name", "")
    params = Map.get(row, "parameters_raw", 0)
    pipeline = Map.get(row, "pipeline_tag")

    is_binary(repo_id) and
      not String.match?(repo_id, @noise_repo_pattern) and
      is_integer(params) and params >= @min_parameters and
      MapSet.member?(@valid_pipeline_tags, pipeline)
  end

  defp normalize_row(row) do
    memory =
      %{
        min_ram_gb: Map.get(row, "min_ram_gb"),
        recommended_ram_gb: Map.get(row, "recommended_ram_gb"),
        min_vram_gb: Map.get(row, "min_vram_gb")
      }
      |> drop_nil_values()

    moe =
      if Map.get(row, "is_moe") == true do
        %{
          is_moe: true,
          num_experts: Map.get(row, "num_experts"),
          active_experts: Map.get(row, "active_experts"),
          active_parameters: Map.get(row, "active_parameters")
        }
        |> drop_nil_values()
      else
        nil
      end

    gguf_sources =
      case Map.get(row, "gguf_sources") do
        sources when is_list(sources) ->
          Enum.map(sources, fn source ->
            %{
              repo: Map.get(source, "repo"),
              provider: Map.get(source, "provider")
            }
            |> drop_nil_values()
          end)

        _ ->
          []
      end

    %{
      source: "llmfit",
      model_id: Map.get(row, "name"),
      provider: Map.get(row, "provider"),
      parameter_count: Map.get(row, "parameter_count"),
      parameters_raw: Map.get(row, "parameters_raw"),
      quantization: Map.get(row, "quantization"),
      context_length: Map.get(row, "context_length"),
      use_case: Map.get(row, "use_case"),
      pipeline_tag: Map.get(row, "pipeline_tag"),
      architecture: Map.get(row, "architecture"),
      hf_downloads: Map.get(row, "hf_downloads"),
      hf_likes: Map.get(row, "hf_likes"),
      release_date: Map.get(row, "release_date"),
      discovered: Map.get(row, "_discovered") == true,
      memory: if(map_size(memory) > 0, do: memory, else: nil),
      gguf_sources: gguf_sources,
      moe: moe
    }
    |> drop_nil_values()
  end

  defp drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
