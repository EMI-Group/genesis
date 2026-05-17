defmodule LLMDB.Runtime do
  @moduledoc """
  Runtime configuration compilation for consumer applications.

  Phase 2 of LLMDB: Compile runtime configuration by merging application
  environment config with per-call options, enabling consumers to:
  - Filter models by provider/model patterns (allow/deny)
  - Define provider preferences
  - Add custom providers/models

  This module handles the consumer-facing runtime configuration that gets
  applied when loading the packaged snapshot into the Store.

  ## Example

      # Compile runtime config from app env + per-call opts
      runtime = LLMDB.Runtime.compile(
        allow: [:openai, :anthropic],
        custom: %{
          providers: [%{id: :myprov, name: "My Provider"}],
          models: [%{provider: :myprov, id: "my-model", capabilities: %{chat: true}}]
        }
      )

      # Runtime config can then be used to filter and customize the catalog
  """

  alias LLMDB.Config

  require Logger

  @doc """
  Compiles runtime configuration by merging app env and per-call options.

  Merges application environment configuration (from `config :llm_db, ...`) with
  options passed at load time, normalizes the configuration, and compiles filters.

  ## Parameters

  - `opts` - Keyword list of per-call options that override app env:
    - `:allow` - `:all`, list of providers `[:openai]`, or map `%{openai: :all | [patterns]}`
    - `:deny` - List of providers `[:provider]` or map `%{provider: [patterns]}`
    - `:prefer` - List of provider atoms in preference order
    - `:custom` - Map with provider IDs as keys, provider configs (with models) as values
    - `:provider_ids` - Optional list of known provider IDs for validation

  ## Returns

  Map with compiled runtime configuration:
  - `:filters` - Compiled allow/deny patterns
  - `:prefer` - Provider preference list
  - `:custom` - Normalized custom providers/models (%{providers: [...], models: [...]})
  - `:unknown` - List of unknown providers in filters (for warnings)

  ## Examples

      # Simple provider allow list
      runtime = Runtime.compile(allow: [:openai, :anthropic])
      runtime.filters.allow
      #=> %{openai: :all, anthropic: :all}

      # Provider allow list with model patterns
      runtime = Runtime.compile(
        allow: %{openai: ["gpt-4*"], anthropic: :all},
        deny: %{openai: ["gpt-4-0613"]}
      )

      # With custom providers
      runtime = Runtime.compile(
        custom: %{
          vllm: [
            name: "Local vLLM Provider",
            models: %{
              "llama-3" => %{capabilities: %{chat: true}}
            }
          ]
        }
      )
  """
  @spec compile(keyword()) :: map()
  def compile(opts \\ []) do
    # Get base config from app env
    base = Config.get()

    # Normalize and merge options
    allow = normalize_allow(Keyword.get(opts, :allow, base.allow))
    deny = normalize_deny(Keyword.get(opts, :deny, base.deny))
    prefer = Keyword.get(opts, :prefer, base.prefer) || []
    custom = normalize_custom(Keyword.get(opts, :custom, base.custom))
    provider_ids = Keyword.get(opts, :provider_ids)

    # Compile filters (deferred if provider_ids not provided)
    {filters, unknown: unknown} =
      if provider_ids do
        Config.compile_filters(allow, deny, provider_ids)
      else
        # Compile without validation, will recompile later with known providers
        Config.compile_filters(allow, deny, nil)
      end

    %{
      filters: filters,
      prefer: prefer,
      custom: custom,
      unknown: unknown,
      # Keep raw patterns for digest calculation
      raw_allow: allow,
      raw_deny: deny
    }
  end

  @doc """
  Applies runtime overrides to an existing snapshot.

  ## Parameters

  - `snapshot` - The current snapshot map
  - `overrides` - Map with optional `:filter` and `:prefer` keys

  ## Override Options

  - `:filter` - %{allow: patterns, deny: patterns} to recompile and reapply
  - `:prefer` - List of provider atoms to update preference order

  ## Returns

  - `{:ok, updated_snapshot}` - Success with updated snapshot
  - `{:error, reason}` - Validation or processing error
  """
  @spec apply(map(), map() | nil) :: {:ok, map()} | {:error, term()}
  def apply(snapshot, overrides) when is_map(snapshot) do
    case validate_and_prepare_overrides(overrides) do
      {:ok, prepared} ->
        apply_overrides(snapshot, prepared)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helpers

  # Normalize :allow from various formats to canonical form
  defp normalize_allow(:all), do: :all

  defp normalize_allow(allow) when is_list(allow) do
    # Convert [:openai, :anthropic] to %{openai: :all, anthropic: :all}
    Map.new(allow, fn provider -> {provider, :all} end)
  end

  defp normalize_allow(allow) when is_map(allow), do: allow
  defp normalize_allow(nil), do: :all

  # Normalize :deny from various formats to canonical form
  defp normalize_deny(deny) when is_list(deny) do
    # Convert [:openai] to %{openai: :all}
    Map.new(deny, fn provider -> {provider, :all} end)
  end

  defp normalize_deny(deny) when is_map(deny), do: deny
  defp normalize_deny(nil), do: %{}

  # Normalize custom overlay from new format to internal format
  # New format: %{provider_id: [name: "...", models: %{id => config}]}
  # Internal format: %{providers: [...], models: [...]}
  defp normalize_custom(custom) when is_map(custom) and map_size(custom) > 0 do
    {providers, models} =
      Enum.reduce(custom, {[], []}, fn {provider_id, provider_config},
                                       {acc_providers, acc_models} ->
        # Normalize provider_id to atom
        provider_atom =
          case provider_id do
            id when is_atom(id) -> id
            id when is_binary(id) -> String.to_atom(id)
          end

        # Extract provider fields (only include non-nil values)
        provider_map =
          %{id: provider_atom}
          |> maybe_put(:name, Keyword.get(provider_config, :name))
          |> maybe_put(:base_url, Keyword.get(provider_config, :base_url))
          |> maybe_put(:env, Keyword.get(provider_config, :env))
          |> maybe_put(:config_schema, Keyword.get(provider_config, :config_schema))
          |> maybe_put(:doc, Keyword.get(provider_config, :doc))
          |> maybe_put(:pricing_defaults, Keyword.get(provider_config, :pricing_defaults))
          |> maybe_put(:extra, Keyword.get(provider_config, :extra))

        # Extract models
        provider_models =
          case Keyword.get(provider_config, :models) do
            models when is_map(models) ->
              Enum.map(models, fn {model_id, model_config} ->
                Map.merge(model_config, %{
                  id: model_id,
                  provider: provider_atom
                })
              end)

            _ ->
              []
          end

        {[provider_map | acc_providers], provider_models ++ acc_models}
      end)

    %{providers: Enum.reverse(providers), models: Enum.reverse(models)}
  end

  defp normalize_custom(_), do: %{providers: [], models: []}

  # Helper to conditionally add non-nil values to a map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp validate_and_prepare_overrides(nil), do: {:ok, %{}}
  defp validate_and_prepare_overrides(overrides) when overrides == %{}, do: {:ok, %{}}

  defp validate_and_prepare_overrides(overrides) when is_map(overrides) do
    with :ok <- validate_filter(overrides[:filter]),
         :ok <- validate_prefer(overrides[:prefer]) do
      {:ok, overrides}
    end
  end

  defp validate_filter(nil), do: :ok
  defp validate_filter(%{} = filter) when map_size(filter) == 0, do: :ok

  defp validate_filter(%{allow: allow, deny: deny}) do
    allow_ok = allow in [:all, nil] or is_map(allow)
    deny_ok = deny == nil or is_map(deny)

    if allow_ok and deny_ok do
      :ok
    else
      {:error, "filter.allow must be :all or map; filter.deny must be map"}
    end
  end

  defp validate_filter(_), do: {:error, "filter must be %{allow: ..., deny: ...}"}

  defp validate_prefer(nil), do: :ok
  defp validate_prefer([]), do: :ok

  defp validate_prefer(prefer) when is_list(prefer) do
    if Enum.all?(prefer, &is_atom/1) do
      :ok
    else
      {:error, "prefer must be a list of atoms"}
    end
  end

  defp validate_prefer(_), do: {:error, "prefer must be a list of atoms"}

  defp apply_overrides(snapshot, overrides) do
    snapshot
    |> maybe_update_filter(overrides[:filter])
    |> maybe_update_prefer(overrides[:prefer])
    |> wrap_ok()
  end

  defp maybe_update_filter(snapshot, nil), do: {:ok, snapshot}
  defp maybe_update_filter(snapshot, filter) when map_size(filter) == 0, do: {:ok, snapshot}

  defp maybe_update_filter(snapshot, filter) do
    alias LLMDB.{Config, Engine}

    require Logger

    # Get known provider IDs for validation
    provider_ids = Map.keys(snapshot.providers_by_id)

    # Compile filters with provider validation
    {compiled_filters, unknown: unknown_providers} =
      Config.compile_filters(
        Map.get(filter, :allow, :all),
        Map.get(filter, :deny, %{}),
        provider_ids
      )

    # Warn on unknown providers in runtime overrides
    if unknown_providers != [] do
      provider_ids_set = MapSet.new(provider_ids)

      Logger.warning(
        "llm_db: unknown provider(s) in runtime filter: #{inspect(unknown_providers)}. " <>
          "Known providers: #{inspect(MapSet.to_list(provider_ids_set))}. " <>
          "Check spelling or remove unknown providers from runtime overrides."
      )
    end

    # Use base_models to enable filter widening, fall back to current models
    all_models = Map.get(snapshot, :base_models, Map.values(snapshot.models) |> List.flatten())
    filtered_models = Engine.apply_filters(all_models, compiled_filters)

    # Fail fast if filters eliminate all models - return error instead of raise
    if compiled_filters.allow != :all and filtered_models == [] do
      allow_summary = summarize_runtime_filter(Map.get(filter, :allow, :all))
      deny_summary = summarize_runtime_filter(Map.get(filter, :deny, %{}))

      {:error,
       "llm_db: runtime filters eliminated all models " <>
         "(allow: #{allow_summary}, deny: #{deny_summary}). " <>
         "Use allow: :all to widen filters or remove deny patterns."}
    else
      updated_snapshot = %{
        snapshot
        | filters: compiled_filters,
          models_by_key: index_models(filtered_models),
          models: Enum.group_by(filtered_models, & &1.provider),
          aliases_by_key: index_aliases(filtered_models)
      }

      {:ok, updated_snapshot}
    end
  end

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

  defp maybe_update_prefer({:ok, snapshot}, nil), do: {:ok, snapshot}
  defp maybe_update_prefer({:ok, snapshot}, []), do: {:ok, snapshot}

  defp maybe_update_prefer({:ok, snapshot}, prefer) when is_list(prefer) do
    {:ok, %{snapshot | prefer: prefer}}
  end

  defp maybe_update_prefer({:error, _} = error, _prefer), do: error

  defp wrap_ok({:ok, _} = result), do: result
  defp wrap_ok({:error, _} = error), do: error

  defp summarize_runtime_filter(:all), do: ":all"

  defp summarize_runtime_filter(filter) when is_map(filter) and map_size(filter) == 0 do
    "%{}"
  end

  defp summarize_runtime_filter(filter) when is_map(filter) do
    # Summarize large filter maps to avoid huge error messages
    keys = Map.keys(filter) |> Enum.take(5)

    if map_size(filter) > 5 do
      "#{inspect(keys)} ... (#{map_size(filter)} providers total)"
    else
      inspect(filter)
    end
  end

  defp summarize_runtime_filter(other), do: inspect(other)
end
