defmodule LLMDB.Store do
  @moduledoc """
  Manages persistent_term storage for LLM model snapshots with atomic swaps.

  Uses `:persistent_term` for fast, concurrent reads with atomic updates tracked by monotonic epochs.
  """

  @store_key :llm_db_store

  @doc """
  Reads the full store from persistent_term.

  ## Returns

  Map with `:snapshot`, `:epoch`, and `:opts` keys, or `nil` if not set.
  """
  @spec get() :: map() | nil
  def get do
    :persistent_term.get(@store_key, nil)
  end

  @doc """
  Returns the snapshot portion from the store.

  ## Returns

  The snapshot map or `nil` if not set.
  """
  @spec snapshot() :: map() | nil
  def snapshot do
    case get() do
      %{snapshot: snapshot} -> snapshot
      _ -> nil
    end
  end

  @doc """
  Returns the current epoch from the store.

  ## Returns

  Non-negative integer representing the current epoch, or `0` if not set.
  """
  @spec epoch() :: non_neg_integer()
  def epoch do
    case get() do
      %{epoch: epoch} -> epoch
      _ -> 0
    end
  end

  @doc """
  Returns the last load options from the store.

  ## Returns

  Keyword list of options used in the last load, or `[]` if not set.
  """
  @spec last_opts() :: keyword()
  def last_opts do
    case get() do
      %{opts: opts} -> opts
      _ -> []
    end
  end

  @doc """
  Atomically swaps the store with new snapshot and options.

  Creates a new epoch using a monotonic unique integer and stores the complete state.

  ## Parameters

  - `snapshot` - The snapshot map to store
  - `opts` - Keyword list of options to store

  ## Returns

  `:ok`
  """
  @spec put!(map(), keyword()) :: :ok
  def put!(snapshot, opts) do
    epoch = :erlang.unique_integer([:monotonic, :positive])
    store = %{snapshot: snapshot, epoch: epoch, opts: opts}
    :persistent_term.put(@store_key, store)
    :ok
  end

  @doc """
  Clears the persistent_term store.

  Primarily used for testing cleanup.

  ## Returns

  `:ok`
  """
  @spec clear!() :: :ok
  def clear! do
    :persistent_term.erase(@store_key)
    :ok
  end

  # Query functions

  @doc """
  Returns all providers from the snapshot.

  ## Returns

  List of Provider structs, or empty list if no snapshot.
  """
  @spec providers() :: [LLMDB.Provider.t()]
  def providers do
    case snapshot() do
      %{providers: providers} when is_list(providers) ->
        Enum.map(providers, fn
          %LLMDB.Provider{} = p -> p
          provider -> LLMDB.Provider.new!(provider)
        end)

      _ ->
        []
    end
  end

  @doc """
  Returns a specific provider by ID.

  ## Parameters

  - `provider_id` - Provider atom

  ## Returns

  - `{:ok, provider}` - Provider found
  - `{:error, :not_found}` - Provider not found
  """
  @spec provider(atom()) :: {:ok, LLMDB.Provider.t()} | {:error, :not_found}
  def provider(provider_id) when is_atom(provider_id) do
    case snapshot() do
      %{providers_by_id: providers_by_id} ->
        case Map.get(providers_by_id, provider_id) do
          nil -> {:error, :not_found}
          provider -> {:ok, LLMDB.Provider.new!(provider)}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns all models for a specific provider.

  Includes models from aliased providers. For example, calling `models(:google_vertex)`
  will return models from both `:google_vertex` AND `:google_vertex_anthropic` since
  `google_vertex_anthropic` has `alias_of: :google_vertex`.

  ## Parameters

  - `provider_id` - Provider atom

  ## Returns

  List of Model structs for the provider and its aliases, or empty list if provider not found.
  """
  @spec models(atom()) :: [LLMDB.Model.t()]
  def models(provider_id) when is_atom(provider_id) do
    case snapshot() do
      %{models: models_by_provider, providers_by_id: providers_by_id} ->
        # Get models for the requested provider
        direct_models = Map.get(models_by_provider, provider_id, [])

        # Find all providers that alias to this provider
        aliased_models =
          providers_by_id
          |> Enum.filter(fn {_id, provider} ->
            Map.get(provider, :alias_of) == provider_id ||
              Map.get(provider, "alias_of") == Atom.to_string(provider_id)
          end)
          |> Enum.flat_map(fn {aliased_provider_id, _provider} ->
            Map.get(models_by_provider, aliased_provider_id, [])
          end)

        # Combine and deduplicate models
        (direct_models ++ aliased_models)
        |> Enum.uniq_by(fn m -> Map.get(m, :id) || Map.get(m, "id") end)
        |> Enum.map(fn
          %LLMDB.Model{} = m -> m
          model -> LLMDB.Model.new!(model)
        end)

      _ ->
        []
    end
  end

  @doc """
  Returns a specific model by provider and ID.

  Resolves both model aliases and provider aliases. For example, looking up
  `model(:google_vertex, "claude-haiku-4-5@20251001")` will find the model
  even if it's stored under `:google_vertex_anthropic` provider (via alias_of).

  ## Parameters

  - `provider_id` - Provider atom
  - `model_id` - Model ID string (can be an alias)

  ## Returns

  - `{:ok, model}` - Model found
  - `{:error, :not_found}` - Model not found
  """
  @spec model(atom(), String.t()) :: {:ok, LLMDB.Model.t()} | {:error, :not_found}
  def model(provider_id, model_id) when is_atom(provider_id) and is_binary(model_id) do
    case snapshot() do
      %{
        models_by_key: models_by_key,
        aliases_by_key: aliases_by_key,
        providers_by_id: providers_by_id
      } ->
        # Build list of provider IDs to search: [requested_provider | aliased_providers]
        providers_to_search =
          [provider_id] ++
            (providers_by_id
             |> Enum.filter(fn {_id, provider} ->
               Map.get(provider, :alias_of) == provider_id ||
                 Map.get(provider, "alias_of") == Atom.to_string(provider_id)
             end)
             |> Enum.map(fn {id, _} -> id end))

        # Strip inference profile prefix for Bedrock lookups
        {lookup_id, _prefix} = LLMDB.Spec.strip_prefix(provider_id, model_id)

        # Try each provider in the search list
        result =
          Enum.find_value(providers_to_search, fn search_provider_id ->
            key = {search_provider_id, lookup_id}

            # Try direct lookup first
            case Map.get(models_by_key, key) do
              nil ->
                # Try alias resolution
                case Map.get(aliases_by_key, key) do
                  nil ->
                    nil

                  canonical_id ->
                    canonical_key = {search_provider_id, canonical_id}
                    Map.get(models_by_key, canonical_key)
                end

              model ->
                model
            end
          end)

        case result do
          nil ->
            {:error, :not_found}

          %LLMDB.Model{provider: model_provider} = m ->
            # If model's provider is aliased, normalize it to the requested provider
            provider_info = Map.get(providers_by_id, model_provider)

            normalized_provider =
              cond do
                is_nil(provider_info) -> model_provider
                Map.get(provider_info, :alias_of) == provider_id -> provider_id
                Map.get(provider_info, "alias_of") == Atom.to_string(provider_id) -> provider_id
                true -> model_provider
              end

            {:ok, %{m | provider: normalized_provider}}

          model ->
            # Convert to struct first
            {:ok, model_struct} = LLMDB.Model.new(model)

            # Normalize provider
            provider_info = Map.get(providers_by_id, model_struct.provider)

            normalized_provider =
              cond do
                is_nil(provider_info) -> model_struct.provider
                Map.get(provider_info, :alias_of) == provider_id -> provider_id
                Map.get(provider_info, "alias_of") == Atom.to_string(provider_id) -> provider_id
                true -> model_struct.provider
              end

            {:ok, %{model_struct | provider: normalized_provider}}
        end

      _ ->
        {:error, :not_found}
    end
  end
end
