defmodule EvoGit.Config.Normalization do
  @moduledoc false

  # Shared by snapshot loading and settings patch validation; never persists
  # defaults or the derived legacy-model mirrors on its own.
  def resolve(user_config) do
    EvoGit.Config.defaults()
    |> deep_merge(atomize_keys(user_config))
    |> atomize_enum_values()
    |> migrate_llm_models()
  end

  def atomize_enum_values(config) when is_map(config) do
    Enum.reduce(config, config, fn
      {:sandbox, section}, acc when is_map(section) ->
        acc
        |> put_in(
          [:sandbox, :mode],
          atomize_if_string(Map.get(section, :mode), [:auto, :enabled, :disabled])
        )
        |> put_in(
          [:sandbox, :backend],
          atomize_if_string(Map.get(section, :backend), [:auto, :systemd, :bwrap])
        )

      {:git, section}, acc when is_map(section) ->
        put_in(
          acc,
          [:git, :cow_worktree_creation],
          atomize_if_string(Map.get(section, :cow_worktree_creation), [:auto, :enabled, :disabled])
        )

      {:tmp, section}, acc when is_map(section) ->
        put_in(
          acc,
          [:tmp, :mode],
          atomize_if_string(Map.get(section, :mode), [:system, :custom, :per_repo])
        )

      {:llm, llm}, acc when is_map(llm) ->
        acc =
          case Map.get(llm, :model) do
            model when is_map(model) -> put_in(acc, [:llm, :model], normalize_model_map(model))
            _ -> acc
          end

        # Canonical provider profiles and every nested option map use strings.
        # Malformed entries must survive normalization for validation.
        acc =
          case Map.fetch(llm, :providers) do
            {:ok, providers} ->
              put_in(
                acc,
                [:llm, :providers],
                EvoGit.Config.Schema.ProviderProfiles.Normalize.stringify(providers)
              )

            :error ->
              acc
          end

        case Map.get(llm, :models) do
          models when is_list(models) ->
            normalized =
              Enum.map(models, fn
                profile when is_map(profile) ->
                  profile =
                    Map.new(profile, fn
                      {key, value} when is_binary(key) -> {safe_atomize(key), value}
                      pair -> pair
                    end)

                  case Map.get(profile, :model) do
                    model when is_map(model) ->
                      Map.put(profile, :model, normalize_model_map(model))

                    _ ->
                      profile
                  end

                _ ->
                  %{}
              end)

            put_in(acc, [:llm, :models], normalized)

          _ ->
            acc
        end

      {:tools, tools}, acc when is_map(tools) ->
        search = Map.get(tools, :search, %{})

        if is_map(search) do
          providers = EvoGit.Config.Schema.Definitions.search_providers()

          acc =
            put_in(
              acc,
              [:tools, :search, :provider],
              atomize_if_string(Map.get(search, :provider), providers)
            )

          Enum.reduce(providers, acc, fn provider, acc ->
            section = Map.get(search, provider, %{})

            if is_map(section) do
              put_in(
                acc,
                [:tools, :search, provider, :search_depth],
                atomize_if_string(Map.get(section, :search_depth), [:basic, :advanced])
              )
            else
              acc
            end
          end)
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

  def migrate_llm_models(config) when is_map(config) do
    raw_llm = Map.get(config, :llm, %{})
    llm = if is_map(raw_llm), do: raw_llm, else: %{}

    if canonical_providers?(llm) do
      Map.put(config, :llm, llm)
    else
      existing = Map.get(llm, :models, [])

      models =
        cond do
          is_list(existing) and existing != [] -> existing
          Map.get(llm, :model) in [nil, ""] -> []
          true -> [EvoGit.Config.Schema.LLM.build_legacy_default_profile(config)]
        end

      llm =
        case models do
          [first | _] when is_map(first) ->
            case Map.get(first, :model) do
              nil -> llm
              model -> Map.put(llm, :model, model)
            end

          _ ->
            llm
        end

      put_in(config, [:llm], Map.put(llm, :models, models))
    end
  end

  def canonical_providers?(llm) do
    case get_key(llm, :providers) do
      providers when is_list(providers) and providers != [] -> true
      _ -> false
    end
  end

  def get_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp normalize_model_map(model) do
    atomized =
      Map.new(model, fn
        {key, value} when is_binary(key) -> {safe_atomize(key), value}
        pair -> pair
      end)

    atomized =
      case Map.get(atomized, :provider) do
        provider when is_binary(provider) -> Map.put(atomized, :provider, safe_atomize(provider))
        _ -> atomized
      end

    provider = Map.get(atomized, :provider)
    id = Map.get(atomized, :id)

    if provider != nil and id != nil and Map.keys(atomized) -- [:provider, :id] == [] do
      "#{provider}:#{id}"
    else
      atomized
    end
  end

  defp atomize_if_string(value, valid) when is_binary(value) do
    Map.get(Map.new(valid, &{Atom.to_string(&1), &1}), value, value)
  end

  defp atomize_if_string(value, _valid), do: value

  defp safe_atomize(string) do
    # Existing-atom conversion has no non-raising variant; unknown TOML keys
    # remain strings and can never grow the atom table.
    try do
      String.to_existing_atom(string)
    rescue
      ArgumentError -> string
    end
  end

  # Keep the established snapshot semantics for malformed section overrides.
  def deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, base_val, override_val ->
      cond do
        is_map(base_val) and is_map(override_val) -> deep_merge(base_val, override_val)
        is_map(base_val) and not is_map(override_val) -> base_val
        true -> override_val
      end
    end)
  end

  def deep_merge(base, _override) when is_map(base), do: base
  def deep_merge(_base, override), do: override

  # Map values recurse, but list members are normalized by their own schema.
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {safe_atomize(key), atomize_keys(value)}
      {key, value} -> {key, atomize_keys(value)}
    end)
  end

  defp atomize_keys(value), do: value
end
