defmodule LLMDB.Engine do
  @moduledoc """
  Pure ETL pipeline for BUILD-TIME LLM model catalog generation.

  Engine is a pure function: sources in, snapshot out. It processes ONLY
  the sources explicitly passed via options or configured sources.

  This module is designed for BUILD-TIME use (e.g., mix tasks) to generate
  complete, unfiltered snapshots from remote/local sources that will be
  packaged into the library.

  ## Pipeline Stages

  1. **Ingest** - Load data from configured sources
  2. **Normalize** - Apply normalization to providers and models per layer
  3. **Validate** - Validate schemas and log dropped records per layer
  4. **Merge** - Combine layers with precedence rules (last wins)
  5. **Finalize** - Enrich and nest models under providers
  6. **Ensure viable** - Verify catalog has content (warns if empty)

  ## Architecture

  Sources are processed in order with last-wins precedence:
  1. First source (lowest precedence)
  2. Second source
  3. ... (higher precedence)
  4. Last source (highest precedence)

  The engine coordinates data ingestion, normalization, validation, merging,
  and finalization to produce a complete v2 snapshot ready for JSON serialization.

  **Filtering and indexing are deferred to load-time** - the snapshot contains
  ALL data from sources. Runtime policies (allow/deny patterns, preferences)
  are applied when the snapshot is loaded via `LLMDB.load/1`.
  """

  require Logger

  alias LLMDB.{Config, Enrich, Merge, Normalize, Source, Validate}
  alias LLMDB.Enrich.RuntimeContract

  # List fields that should be unioned when merging models from multiple sources
  @list_union_keys [:aliases, :tags, :input, :output]

  @doc """
  Runs the complete ETL pipeline to generate a model catalog snapshot.

  Pure function that processes sources into a complete, unfiltered snapshot.
  BUILD-TIME only.

  ## Options

  - `:sources` - List of `{module, opts}` source tuples (optional, defaults to Config.sources!())

  Note: `:allow`, `:deny`, `:prefer`, and `:filters` options are ignored.
  Filtering is a load-time concern applied via `LLMDB.load/1` and runtime config.

  ## Returns

  - `{:ok, snapshot_map}` - Success with v2 snapshot structure
  - `{:ok, snapshot_map}` - Empty catalog (warns but succeeds if no sources)
  - `{:error, term}` - Other error

  ## Snapshot Structure (v2)

  ```elixir
  %{
    version: 2,
    generated_at: String.t(),
    providers: %{atom => %{provider_fields... + models: %{String.t() => Model.t()}}}
  }
  ```

  The snapshot contains ALL models from all sources. Indexes and filters are
  built at load-time by `LLMDB.load/1` using the `LLMDB.Index` module.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, layers_data} <- ingest(opts),
         {:ok, normalized} <- normalize_layers(layers_data),
         {:ok, validated} <- validate_layers(normalized),
         {:ok, merged} <- merge_layers(validated),
         {:ok, merged_validated} <- validate_merged(merged),
         {:ok, snapshot} <- finalize(merged_validated),
         :ok <- validate_runtime_contract(snapshot),
         :ok <- ensure_viable(snapshot) do
      {:ok, snapshot}
    end
  end

  # Stage 1: Ingest - load data from configured sources only
  defp ingest(opts) do
    # Get sources list (from opts or config)
    sources_list =
      case Keyword.get(opts, :sources) do
        nil -> Config.sources!()
        sources when is_list(sources) -> sources
      end
      |> prioritize_source_precedence()

    # Warn if no sources provided
    if sources_list == [] do
      Logger.warning("No sources configured - catalog will be empty")
    end

    # Load data from each source
    source_layers =
      Enum.map(sources_list, fn {module, source_opts} ->
        case module.load(source_opts) do
          {:ok, data} ->
            # Assert canonical format - fail fast if source forgot to transform
            Source.assert_canonical!(data)

            {providers, models} = flatten_nested_data(data)

            %{
              name: module,
              providers: providers,
              models: models
            }

          {:error, reason} ->
            Logger.warning("Source #{inspect(module)} failed to load: #{inspect(reason)}")

            %{
              name: module,
              providers: [],
              models: []
            }
        end
      end)

    {:ok, %{layers: source_layers}}
  end

  # Stage 2: Normalize - apply to each layer
  defp normalize_layers(layers_data) do
    normalized_layers =
      Enum.map(layers_data.layers, fn layer ->
        %{
          name: layer.name,
          providers: Normalize.normalize_providers(layer.providers),
          models: Normalize.normalize_models(layer.models)
        }
      end)

    {:ok, %{layers: normalized_layers}}
  end

  # Stage 3: Validate - apply to each layer and preserve sparse overlay intent
  defp validate_layers(normalized) do
    validated_layers =
      Enum.map(normalized.layers, fn layer ->
        {:ok, providers, providers_dropped} =
          Validate.validate_providers_for_merge(layer.providers)

        {:ok, models, models_dropped} = Validate.validate_models_for_merge(layer.models)

        if providers_dropped > 0 do
          Logger.warning(
            "Dropped #{providers_dropped} invalid provider(s) from #{inspect(layer.name)}"
          )
        end

        if models_dropped > 0 do
          Logger.warning("Dropped #{models_dropped} invalid model(s) from #{inspect(layer.name)}")
        end

        %{
          name: layer.name,
          providers: providers,
          models: models
        }
      end)

    {:ok, %{layers: validated_layers}}
  end

  # Stage 4: Merge - combine all layers with precedence (last wins)
  defp merge_layers(validated) do
    # Reduce layers left-to-right (first = lowest precedence, last = highest)
    {providers, models} =
      Enum.reduce(validated.layers, {[], []}, fn layer, {acc_providers, acc_models} ->
        {
          Merge.merge_providers(acc_providers, layer.providers),
          merge_models_with_list_rules(acc_models, layer.models)
        }
      end)

    # Collect exclude_models from all providers
    excludes =
      Enum.reduce(providers, %{}, fn provider, acc ->
        case Map.get(provider, :exclude_models) do
          models when is_list(models) -> Map.put(acc, provider.id, models)
          _ -> acc
        end
      end)

    # Apply excludes to models
    filtered_models = Merge.merge_models(models, [], excludes)

    {:ok, %{providers: providers, models: filtered_models}}
  end

  defp validate_merged(merged) do
    {:ok, providers, providers_dropped} = Validate.validate_providers(merged.providers)
    {:ok, models, models_dropped} = Validate.validate_models(merged.models)

    if providers_dropped > 0 do
      Logger.warning("Dropped #{providers_dropped} invalid provider(s) after merge")
    end

    if models_dropped > 0 do
      Logger.warning("Dropped #{models_dropped} invalid model(s) after merge")
    end

    {:ok, %{providers: providers, models: models}}
  end

  # Stage 5: Finalize (Enrich → Nest)
  defp finalize(merged) do
    models =
      merged.models
      |> Enrich.enrich_models()

    {providers, models} = RuntimeContract.enrich(merged.providers, models)
    nested_providers = build_nested_providers(providers, models)

    snapshot = %{
      version: 2,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      providers: nested_providers
    }

    {:ok, snapshot}
  end

  # Stage 6: Ensure viable - warn on empty catalog but don't error
  defp ensure_viable(snapshot) do
    providers = snapshot.providers

    total_models =
      providers
      |> Map.values()
      |> Enum.map(fn provider -> map_size(provider.models) end)
      |> Enum.sum()

    if map_size(providers) == 0 or total_models == 0 do
      Logger.warning("Empty catalog generated - no providers or models found")
    end

    :ok
  end

  defp validate_runtime_contract(%{providers: providers}) when is_map(providers) do
    provider_list = Map.values(providers)

    model_list =
      providers
      |> Map.values()
      |> Enum.flat_map(fn provider -> Map.values(provider.models) end)

    Validate.validate_runtime_contract(provider_list, model_list)
  end

  @doc """
  Applies allow/deny filters to models.

  Deny patterns always win over allow patterns.

  ## Parameters

  - `models` - List of model maps
  - `filters` - %{allow: compiled_patterns, deny: compiled_patterns}

  ## Returns

  Filtered list of models
  """
  @spec apply_filters([map()], map()) :: [map()]
  def apply_filters(models, %{allow: allow, deny: deny}) do
    models
    |> Enum.filter(fn model ->
      provider = model.provider
      model_id = model.id

      # Deny wins - check first
      deny_patterns = Map.get(deny, provider, [])

      if matches_patterns?(model_id, deny_patterns) do
        false
      else
        # Then check allow
        case allow do
          :all ->
            true

          allow_map when is_map(allow_map) ->
            allow_patterns = Map.get(allow_map, provider, [])

            if map_size(allow_map) > 0 and allow_patterns == [] do
              false
            else
              allow_patterns == [] or matches_patterns?(model_id, allow_patterns)
            end
        end
      end
    end)
  end

  @doc """
  Builds the nested v2 provider structure for snapshot serialization.

  Groups models by provider and nests them under their provider.
  Models are keyed by model.id for easy lookup.

  ## Parameters

  - `providers` - List of provider maps
  - `models` - List of model maps

  ## Returns

  %{atom => %{provider fields + models: %{string => model}}}
  """
  @spec build_nested_providers([map()], [map()]) :: %{atom() => map()}
  def build_nested_providers(providers, models) do
    models_by_provider = Enum.group_by(models, & &1.provider)

    providers
    |> Enum.map(fn provider ->
      provider_id = provider.id
      provider_models = Map.get(models_by_provider, provider_id, [])

      models_map =
        provider_models
        |> Enum.map(&{&1.id, &1})
        |> Enum.sort_by(fn {id, _} -> id end)
        |> Map.new()

      {provider_id, Map.put(provider, :models, models_map)}
    end)
    |> Enum.sort_by(fn {id, _} -> to_string(id) end)
    |> Map.new()
  end

  # Private helpers

  # Merge models with special list handling rules
  # Union for known list fields (:aliases, :tags, modalities :input/:output), replace for others
  defp merge_models_with_list_rules(base_models, override_models) do
    base_map = Map.new(base_models, fn m -> {{Map.get(m, :provider), Map.get(m, :id)}, m} end)

    override_map =
      Map.new(override_models, fn m -> {{Map.get(m, :provider), Map.get(m, :id)}, m} end)

    Map.merge(base_map, override_map, fn _identity, base_model, override_model ->
      deep_merge_with_list_rules(base_model, override_model)
    end)
    |> Map.values()
  end

  # Deep merge with special list handling
  defp deep_merge_with_list_rules(left, right) when is_map(left) and is_map(right) do
    LLMDB.DeepMergeShim.deep_merge(left, right, Merge.resolver(union_list_keys: @list_union_keys))
  end

  defp matches_patterns?(_model_id, []), do: false

  defp matches_patterns?(model_id, patterns) when is_binary(model_id) do
    Enum.any?(patterns, fn
      %Regex{} = pattern -> Regex.match?(pattern, model_id)
      pattern when is_binary(pattern) -> model_id == pattern
    end)
  end

  defp flatten_nested_data(data) when is_map(data) do
    Enum.reduce(data, {[], []}, fn {_provider_id, provider_data}, {provs_acc, mods_acc} ->
      models = Map.get(provider_data, :models, Map.get(provider_data, "models", []))
      provider = Map.delete(Map.delete(provider_data, :models), "models")

      {[provider | provs_acc], models ++ mods_acc}
    end)
  end

  # Local TOML overlays are the highest-precedence source regardless of config order.
  defp prioritize_source_precedence(sources) when is_list(sources) do
    {locals, non_locals} =
      Enum.split_with(sources, fn
        {LLMDB.Sources.Local, _opts} -> true
        _other -> false
      end)

    non_locals ++ locals
  end
end
