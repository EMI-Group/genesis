defmodule LLMDB.Enrich.AzureWireProtocol do
  @moduledoc """
  Wire protocol enrichment using Azure AI Foundry inference task metadata.

  Fetches model catalog data from Azure AI Foundry's public API and uses
  the `inferenceTasks` field to determine which wire protocol each Azure
  model supports (openai_responses, openai_completion, anthropic_messages).

  Only enriches models from Azure providers since models.dev already syncs
  model data but lacks wire protocol information for Azure's model catalog.

  - `pull/1` fetches the Azure catalog and caches locally
  - `build_lookup/0` reads cached data and builds a model -> wire_protocol map
  - `enrich_models/1` applies wire protocol to Azure models using the lookup
  """

  require Logger

  @api_url "https://ai.azure.com/api/eastus/ux/v1.0/entities/crossRegion"
  @default_cache_dir "priv/llm_db/remote"
  @cache_id "azure-foundry"
  @page_size 200

  @registries [
    "azure-openai",
    "azureml",
    "azureml-meta",
    "azureml-mistral",
    "azureml-cohere",
    "azureml-deepseek",
    "azureml-xai",
    "azureml-anthropic",
    "azureml-moonshotai",
    "azureml-nvidia",
    "azureml-ai21",
    "azureml-alibaba"
  ]

  @chat_tasks ["chat-completion", "completions", "text-generation"]
  @lookup_suffixes ["-instruct"]

  @azure_providers [:azure, :azure_cognitive_services]

  @spec pull(map()) :: :noop | {:ok, String.t()} | {:error, term()}
  def pull(opts \\ %{}) do
    req_opts = Map.get(opts, :req_opts, [])
    cache_dir = get_cache_dir()
    cache_path = Path.join(cache_dir, "#{@cache_id}.json")
    manifest_path = Path.join(cache_dir, "#{@cache_id}.manifest.json")

    case fetch_all_pages(req_opts) do
      {:ok, models} ->
        bin = Jason.encode!(models, pretty: true)
        write_cache(cache_path, manifest_path, bin)
        {:ok, cache_path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec build_lookup() :: %{String.t() => atom()}
  def build_lookup do
    cache_path = Path.join(get_cache_dir(), "#{@cache_id}.json")

    case File.read(cache_path) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, models} ->
            build_lookup_from_models(models)

          {:error, err} ->
            Logger.warning("Failed to decode Azure Foundry cache: #{inspect(err)}")
            %{}
        end

      {:error, :enoent} ->
        Logger.debug("No Azure Foundry cache found, wire protocol lookup will be empty")
        %{}

      {:error, reason} ->
        Logger.warning("Failed to read Azure Foundry cache: #{inspect(reason)}")
        %{}
    end
  end

  @spec enrich_models([map()]) :: [map()]
  def enrich_models(models) when is_list(models) do
    lookup = build_lookup()

    if map_size(lookup) == 0 do
      models
    else
      Enum.map(models, &enrich_model(&1, lookup))
    end
  end

  defp enrich_model(%{provider: provider, extra: %{wire_protocol: _}} = model, _lookup)
       when provider in @azure_providers,
       do: model

  defp enrich_model(%{provider: provider} = model, lookup)
       when provider in @azure_providers do
    set_wire_protocol(model, lookup)
  end

  defp enrich_model(model, _lookup), do: model

  defp set_wire_protocol(%{id: model_id} = model, lookup) do
    case resolve_wire_protocol(model_id, lookup) do
      nil ->
        model

      protocol ->
        extra = Map.get(model, :extra, %{})
        Map.put(model, :extra, Map.put(extra, :wire_protocol, protocol))
    end
  end

  defp resolve_wire_protocol(model_id, lookup) do
    model_id
    |> lookup_candidates()
    |> Enum.find_value(&Map.get(lookup, &1))
  end

  @date_suffix ~r/-\d{4}-\d{2}-\d{2}$/

  defp strip_date_suffix(model_id) do
    Regex.replace(@date_suffix, model_id, "")
  end

  defp lookup_candidates(model_id) do
    canonical_id = strip_date_suffix(model_id)

    [model_id, canonical_id]
    |> Enum.flat_map(fn candidate ->
      [candidate | Enum.map(@lookup_suffixes, &"#{candidate}#{&1}")]
    end)
    |> Enum.uniq()
  end

  defp build_lookup_from_models(models) do
    Enum.reduce(models, %{}, fn model, acc ->
      name = model_name(model)
      tasks = get_in(model, ["annotations", "systemCatalogData", "inferenceTasks"]) || []

      case derive_wire_protocol(tasks) do
        nil -> acc
        protocol -> Map.put(acc, name, protocol)
      end
    end)
  end

  defp model_name(model) do
    model
    |> get_in(["annotations", "name"])
    |> to_string()
    |> String.downcase()
  end

  defp derive_wire_protocol(tasks) do
    cond do
      "messages" in tasks -> :anthropic_messages
      "responses" in tasks -> :openai_responses
      Enum.any?(tasks, &(&1 in @chat_tasks)) -> :openai_completion
      true -> nil
    end
  end

  # Pull helpers

  defp fetch_all_pages(req_opts, continuation_token \\ nil, acc \\ []) do
    body = build_request_body(continuation_token)

    headers = [{"user-agent", "AzureAiStudio"}]
    merged_headers = headers ++ Keyword.get(req_opts, :headers, [])
    merged_opts = Keyword.put(req_opts, :headers, merged_headers)

    case Req.post(@api_url, [json: body] ++ merged_opts) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        ier = Map.get(resp_body, "indexEntitiesResponse", %{})
        entities = Map.get(ier, "value", [])
        acc = Enum.reverse(entities) ++ acc

        case Map.get(ier, "continuationToken") do
          nil -> {:ok, Enum.reverse(acc)}
          "" -> {:ok, Enum.reverse(acc)}
          token -> fetch_all_pages(req_opts, token, acc)
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_request_body(continuation_token) do
    resource_ids =
      Enum.map(@registries, fn registry ->
        %{"resourceId" => registry, "entityContainerType" => "Registry"}
      end)

    index_request = %{
      "filters" => [
        %{"field" => "type", "operator" => "eq", "values" => ["models"]},
        %{"field" => "kind", "operator" => "eq", "values" => ["Versioned"]},
        %{"field" => "labels", "operator" => "eq", "values" => ["latest"]}
      ],
      "pageSize" => @page_size,
      "skip" => nil,
      "continuationToken" => continuation_token
    }

    %{
      "resourceIds" => resource_ids,
      "indexEntitiesRequest" => index_request
    }
  end

  defp get_cache_dir do
    Application.get_env(:llm_db, :azure_foundry_cache_dir, @default_cache_dir)
  end

  defp write_cache(cache_path, manifest_path, content) do
    File.mkdir_p!(Path.dirname(cache_path))
    File.write!(cache_path, content)

    manifest = %{
      source_url: @api_url,
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      size_bytes: byte_size(content),
      downloaded_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
  end
end
