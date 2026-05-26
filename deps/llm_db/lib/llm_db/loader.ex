defmodule LLMDB.Loader do
  @moduledoc """
  Handles loading and merging of packaged snapshots with runtime customization.

  Phase 2 of LLMDB: Load the packaged snapshot, apply custom overlays,
  compile filters, and build indexes for runtime queries.

  This module encapsulates all snapshot loading logic, keeping the main
  LLMDB module focused on the query API.
  """

  alias LLMDB.{Engine, Merge, Model, Packaged, Pricing, Provider, Runtime, Snapshot, Validate}
  alias LLMDB.Snapshot.ReleaseStore

  require Logger

  @doc """
  Loads the packaged snapshot and applies runtime configuration.

  This is the main entry point for Phase 2 (runtime) loading. It:
  1. Loads the packaged snapshot
  2. Normalizes providers/models from v1 or v2 format
  3. Merges custom providers/models overlay
  4. Compiles and applies filters
  5. Builds indexes for O(1) queries
  6. Returns snapshot ready for Store

  ## Parameters

  - `opts` - Keyword list passed to Runtime.compile/1

  ## Returns

  - `{:ok, snapshot}` - Successfully loaded and prepared snapshot
  - `{:error, :no_snapshot}` - No packaged snapshot available
  - `{:error, term}` - Other errors

  ## Examples

      {:ok, snapshot} = Loader.load()

      {:ok, snapshot} = Loader.load(
        allow: [:openai],
        custom: %{
          local: [
            models: %{"llama-3" => %{capabilities: %{chat: true}}}
          ]
        }
      )
  """
  @spec load(keyword()) :: {:ok, map()} | {:error, term()}
  def load(opts \\ []) do
    with {:ok, {providers, models, generated_at, source_snapshot_id}} <- load_packaged(opts),
         runtime <- Runtime.compile(opts ++ [provider_ids: Enum.map(providers, & &1.id)]),
         :ok <- warn_unknown_providers(runtime.unknown, providers),
         {providers2, models2} <- merge_custom({providers, models}, runtime.custom),
         models3 <- Pricing.apply_cost_components(models2),
         models4 <- Pricing.apply_provider_defaults(providers2, models3),
         filtered_models <- Engine.apply_filters(models4, runtime.filters),
         :ok <- validate_not_empty(filtered_models, runtime),
         snapshot <-
           build_snapshot(
             providers2,
             filtered_models,
             models4,
             runtime,
             generated_at,
             source_snapshot_id
           ) do
      {:ok, snapshot}
    end
  end

  @doc """
  Builds an empty snapshot with no providers or models.

  Used as a fallback when no packaged snapshot is available.

  ## Examples

      {:ok, snapshot} = Loader.load_empty()
  """
  @spec load_empty(keyword()) :: {:ok, map()}
  def load_empty(opts \\ []) do
    runtime = Runtime.compile(opts)

    snapshot = %{
      providers_by_id: %{},
      models_by_key: %{},
      aliases_by_key: %{},
      providers: [],
      models: %{},
      base_models: [],
      filters: runtime.filters,
      prefer: runtime.prefer,
      meta: %{
        epoch: nil,
        source_generated_at: nil,
        source_snapshot_id: nil,
        loaded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        digest: compute_digest([], [], runtime)
      }
    }

    {:ok, snapshot}
  end

  @doc """
  Computes a digest for a snapshot configuration.

  Used to detect if a reload would result in the same snapshot,
  enabling idempotent load operations.

  ## Parameters

  - `providers` - List of provider maps
  - `base_models` - List of all models before filtering
  - `runtime` - Runtime configuration map

  ## Returns

  Integer digest (phash2 hash)
  """
  @spec compute_digest(list(), list(), map()) :: integer()
  def compute_digest(providers, base_models, runtime) do
    # Stable hash of configuration that affects the final snapshot
    :erlang.phash2({
      # Provider IDs (order matters for determinism)
      Enum.map(providers, & &1.id),
      # Model keys (provider + id)
      Enum.map(base_models, fn m -> {m.provider, m.id} end),
      # Runtime config that affects filtering
      runtime.raw_allow,
      runtime.raw_deny,
      runtime.prefer,
      # Custom overlay
      custom_digest(runtime.custom)
    })
  end

  # Private helpers
  defp load_packaged(opts) do
    case load_snapshot_document(snapshot_source(opts)) do
      nil ->
        {:error, :no_snapshot}

      %{version: 2, providers: nested_providers, generated_at: generated_at} = snapshot ->
        # V2 snapshot with nested providers
        {providers, models} = flatten_nested_providers(nested_providers)

        {:ok,
         {deserialize_json_atoms(providers, :provider), deserialize_json_atoms(models, :model),
          generated_at, snapshot_snapshot_id(snapshot)}}

      %{"version" => 2, "providers" => nested_providers, "generated_at" => generated_at} =
          snapshot ->
        {providers, models} = flatten_nested_providers(nested_providers)

        {:ok,
         {deserialize_json_atoms(providers, :provider), deserialize_json_atoms(models, :model),
          generated_at, snapshot_snapshot_id(snapshot)}}

      %{providers: providers, models: models, generated_at: generated_at} = snapshot
      when is_list(providers) and is_list(models) ->
        # V1 snapshot with generated_at
        {:ok,
         {deserialize_json_atoms(providers, :provider), deserialize_json_atoms(models, :model),
          generated_at, snapshot_snapshot_id(snapshot)}}

      %{"providers" => providers, "models" => models, "generated_at" => generated_at} = snapshot
      when is_list(providers) and is_list(models) ->
        {:ok,
         {deserialize_json_atoms(providers, :provider), deserialize_json_atoms(models, :model),
          generated_at, snapshot_snapshot_id(snapshot)}}

      %{providers: providers, models: models} = snapshot
      when is_list(providers) and is_list(models) ->
        # V1 snapshot without generated_at
        {:ok,
         {deserialize_json_atoms(providers, :provider), deserialize_json_atoms(models, :model),
          nil, snapshot_snapshot_id(snapshot)}}

      %{"providers" => providers, "models" => models} = snapshot
      when is_list(providers) and is_list(models) ->
        {:ok,
         {deserialize_json_atoms(providers, :provider), deserialize_json_atoms(models, :model),
          nil, snapshot_snapshot_id(snapshot)}}

      _ ->
        {:error, :invalid_snapshot_format}
    end
  end

  defp flatten_nested_providers(nested_providers) when is_map(nested_providers) do
    {providers, all_models} =
      Enum.reduce(nested_providers, {[], []}, fn {_provider_id, provider_data},
                                                 {acc_providers, acc_models} ->
        # Extract provider without models key
        provider = map_delete(provider_data, :models)

        # Get provider ID as string for models
        provider_id_str =
          case get_value(provider_data, :id) do
            a when is_atom(a) -> Atom.to_string(a)
            s when is_binary(s) -> s
          end

        # Extract models and ensure they have provider field
        models =
          case get_value(provider_data, :models) do
            models when is_map(models) ->
              Enum.map(models, fn {_model_id, model_data} ->
                map_put_new(model_data, :provider, provider_id_str)
              end)

            _ ->
              []
          end

        {[provider | acc_providers], models ++ acc_models}
      end)

    {Enum.reverse(providers), Enum.reverse(all_models)}
  end

  defp deserialize_json_atoms(items, :provider) do
    Enum.map(items, fn provider ->
      provider_map = normalize_provider_item(provider)

      # Validate and create Provider struct
      case provider_map do
        %Provider{} = normalized -> normalized
        _ -> Provider.new!(provider_map)
      end
    end)
  end

  defp deserialize_json_atoms(items, :model) do
    Enum.map(items, fn model ->
      model_map = normalize_model_item(model)

      # Validate and create Model struct
      case model_map do
        %Model{} = normalized -> normalized
        _ -> Model.new!(model_map)
      end
    end)
  end

  defp deserialize_modality_list(list) when is_list(list) do
    Enum.map(list, fn
      s when is_binary(s) -> safe_existing_atom(s)
      a when is_atom(a) -> a
    end)
  end

  defp deserialize_modality_list(other), do: other

  defp merge_custom({providers, models}, %{providers: [], models: []}) do
    # No custom overlay
    {providers, models}
  end

  defp merge_custom({providers, models}, custom) do
    custom_providers = validate_custom_overlays!(custom.providers, :provider)
    custom_models = validate_custom_overlays!(custom.models, :model)

    merged_providers =
      providers
      |> Merge.merge_providers(custom_providers)
      |> revalidate_merged!(&Validate.validate_provider/1, "custom provider")

    merged_models =
      models
      |> Merge.merge_models(custom_models, %{})
      |> revalidate_merged!(&Validate.validate_model/1, "custom model")

    {merged_providers, merged_models}
  end

  defp validate_custom_overlays!(items, :provider) when is_list(items) do
    Enum.map(items, fn provider ->
      provider
      |> normalize_provider_item()
      |> validate_custom_overlay!(&Validate.validate_provider_overlay/1, "custom provider")
    end)
  end

  defp validate_custom_overlays!(items, :model) when is_list(items) do
    Enum.map(items, fn model ->
      model
      |> normalize_model_item()
      |> validate_custom_overlay!(&Validate.validate_model_overlay/1, "custom model")
    end)
  end

  defp validate_custom_overlay!(item, validator, label) do
    case validator.(item) do
      {:ok, overlay} ->
        overlay

      {:error, reason} ->
        raise ArgumentError, "Invalid #{label}: #{inspect(reason)}"
    end
  end

  defp revalidate_merged!(items, validator, label) when is_list(items) do
    Enum.map(items, fn item ->
      case validator.(item) do
        {:ok, validated} ->
          validated

        {:error, reason} ->
          raise ArgumentError, "Invalid #{label} after merge: #{inspect(reason)}"
      end
    end)
  end

  defp warn_unknown_providers([], _providers), do: :ok

  defp warn_unknown_providers(unknown_providers, providers) do
    provider_ids_set = MapSet.new(providers, & &1.id)

    Logger.warning(
      "llm_db: unknown provider(s) in filter: #{inspect(unknown_providers)}. " <>
        "Known providers: #{inspect(MapSet.to_list(provider_ids_set))}. " <>
        "Check spelling or remove unknown providers from configuration."
    )

    :ok
  end

  defp validate_not_empty(filtered_models, runtime) do
    if runtime.filters.allow != :all and filtered_models == [] do
      {:error,
       "llm_db: filters eliminated all models. Check :llm_db filter configuration. " <>
         "allow: #{summarize_filter(runtime.raw_allow)}, deny: #{summarize_filter(runtime.raw_deny)}. " <>
         "Use allow: :all to widen filters or remove deny patterns."}
    else
      :ok
    end
  end

  defp build_snapshot(
         providers,
         filtered_models,
         base_models,
         runtime,
         generated_at,
         source_snapshot_id
       ) do
    # Apply provider aliases AFTER all sources are loaded
    providers_with_aliases = apply_provider_aliases(providers)

    %{
      providers_by_id: index_providers(providers_with_aliases),
      models_by_key: index_models(filtered_models),
      aliases_by_key: index_aliases(filtered_models),
      providers: providers_with_aliases,
      models: Enum.group_by(filtered_models, & &1.provider),
      base_models: base_models,
      filters: runtime.filters,
      prefer: runtime.prefer,
      meta: %{
        epoch: nil,
        source_generated_at: generated_at,
        source_snapshot_id: source_snapshot_id,
        loaded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        digest: compute_digest(providers, base_models, runtime)
      }
    }
  end

  # Apply provider aliases post-load (after all sources merged)
  # This handles cases where a single implementation (e.g., GoogleVertex)
  # should handle models from multiple LLMDB providers
  defp apply_provider_aliases(providers) do
    # Hardcoded provider alias mappings
    # Key: aliased provider ID, Value: primary provider ID
    alias_map = %{
      google_vertex_anthropic: :google_vertex
    }

    Enum.map(providers, fn provider ->
      case Map.get(alias_map, provider.id) do
        nil -> provider
        primary_id -> Map.put(provider, :alias_of, primary_id)
      end
    end)
  end

  defp index_providers(providers), do: Map.new(providers, &{&1.id, &1})

  defp index_models(models), do: Map.new(models, &{{&1.provider, &1.id}, &1})

  defp index_aliases(models) do
    models
    |> Enum.flat_map(fn model ->
      provider = model.provider
      canonical_id = model.id
      aliases = Map.get(model, :aliases, [])

      Enum.map(aliases, fn alias_name ->
        {{provider, alias_name}, canonical_id}
      end)
    end)
    |> Map.new()
  end

  defp custom_digest(%{providers: [], models: []}), do: nil

  defp custom_digest(%{providers: providers, models: models}) do
    :erlang.phash2({
      Enum.map(providers, & &1.id),
      Enum.map(models, fn m -> {m.provider, m.id} end)
    })
  end

  defp summarize_filter(:all), do: ":all"

  defp summarize_filter(filter) when is_map(filter) and map_size(filter) == 0 do
    "%{}"
  end

  defp summarize_filter(filter) when is_map(filter) do
    keys = Map.keys(filter) |> Enum.take(5)

    if map_size(filter) > 5 do
      "#{inspect(keys)} ... (#{map_size(filter)} providers total)"
    else
      inspect(filter)
    end
  end

  defp snapshot_source(opts) do
    base = LLMDB.Config.get()
    Keyword.get(opts, :snapshot_source, base.snapshot_source)
  end

  defp load_snapshot_document(:packaged), do: Packaged.snapshot()

  defp load_snapshot_document({:file, path}) when is_binary(path) do
    case Snapshot.read(path) do
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> nil
    end
  end

  defp load_snapshot_document({:github_releases, store_opts}) do
    {ref, overrides} = release_ref_and_overrides(store_opts)

    case ReleaseStore.fetch_snapshot(ref, overrides) do
      {:ok, %{snapshot: snapshot}} -> snapshot
      {:error, _reason} -> nil
    end
  end

  defp load_snapshot_document(other) when is_binary(other),
    do: load_snapshot_document({:file, other})

  defp load_snapshot_document(_), do: Packaged.snapshot()

  defp release_ref_and_overrides(store_opts) do
    normalized =
      cond do
        is_map(store_opts) -> store_opts
        Keyword.keyword?(store_opts) -> Enum.into(store_opts, %{})
        true -> %{}
      end

    ref =
      Map.get(normalized, :ref) ||
        Map.get(normalized, "ref") ||
        :latest

    overrides =
      normalized
      |> Map.delete(:ref)
      |> Map.delete("ref")

    {ref, overrides}
  end

  defp snapshot_snapshot_id(snapshot) when is_map(snapshot) do
    snapshot["snapshot_id"] || snapshot[:snapshot_id]
  end

  defp provider_atom(provider) when is_binary(provider) do
    safe_existing_atom(provider, true)
  end

  defp normalize_provider_item(provider) do
    normalized_id =
      case get_value(provider, :id) do
        id when is_atom(id) -> id
        id when is_binary(id) -> provider_atom(id)
      end

    provider
    |> deep_atomize_keys()
    |> Map.put(:id, normalized_id)
  end

  defp normalize_model_item(model) do
    normalized_provider =
      case get_value(model, :provider) do
        provider when is_atom(provider) -> provider
        provider when is_binary(provider) -> provider_atom(provider)
      end

    model
    |> normalize_model_modalities()
    |> put_value(:provider, normalized_provider)
    |> deep_atomize_keys()
  end

  defp normalize_model_modalities(model) do
    case get_value(model, :modalities) do
      modalities when is_map(modalities) ->
        normalized =
          modalities
          |> maybe_normalize_modality(:input)
          |> maybe_normalize_modality(:output)

        put_value(model, :modalities, normalized)

      _other ->
        model
    end
  end

  defp maybe_normalize_modality(modalities, key) do
    case get_value(modalities, key) do
      list when is_list(list) -> put_value(modalities, key, deserialize_modality_list(list))
      _other -> modalities
    end
  end

  defp safe_existing_atom(value, allow_create \\ false)

  defp safe_existing_atom(value, allow_create) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError ->
      _ = allow_create
      String.to_atom(value)
  end

  defp get_value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp put_value(%_{} = struct, key, value), do: Map.put(struct, key, value)

  defp put_value(map, key, value) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.put(map, key, value)
      Map.has_key?(map, Atom.to_string(key)) -> Map.put(map, Atom.to_string(key), value)
      true -> Map.put(map, key, value)
    end
  end

  defp map_put_new(%_{} = struct, key, value), do: Map.put_new(struct, key, value)

  defp map_put_new(map, key, value) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> map
      Map.has_key?(map, Atom.to_string(key)) -> map
      true -> Map.put(map, key, value)
    end
  end

  defp map_delete(%_{} = struct, key), do: Map.delete(struct, key)

  defp map_delete(map, key) when is_map(map) do
    map
    |> Map.delete(key)
    |> Map.delete(Atom.to_string(key))
  end

  defp deep_atomize_keys(%_{} = struct), do: struct

  defp deep_atomize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      normalized_key =
        case key do
          key when is_atom(key) -> key
          key when is_binary(key) -> safe_existing_atom(key, true)
        end

      {normalized_key, deep_atomize_keys(value)}
    end)
  end

  defp deep_atomize_keys(list) when is_list(list), do: Enum.map(list, &deep_atomize_keys/1)
  defp deep_atomize_keys(value), do: value
end
