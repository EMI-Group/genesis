defmodule EvoGit.Config.Normalization do
  @moduledoc false

  alias EvoGit.Config.Keys
  alias EvoGit.Config.Schema.LLM

  # Shared by snapshot loading and settings patch validation; never persists
  # defaults or the derived legacy-model mirrors on its own.
  @spec resolve(map()) :: map()
  def resolve(user_config) do
    EvoGit.Config.defaults()
    |> deep_merge(atomize_keys(user_config))
    |> atomize_enum_values()
    |> migrate_llm_models()
  end

  @spec atomize_enum_values(map()) :: map()
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

        # Every reasoning-effort-valued field is written in the ONE ladder's
        # canonical STRING spelling before validation runs, so the flat
        # `~w(none minimal low medium high xhigh default)` enum accepts exactly
        # what `LLM.canonical_reasoning_effort/1` accepts: a persisted "max",
        # `:max`, `"MAX"` or `" High "` all load, and a later save writes the
        # canonical spelling. An UNKNOWN value is left untouched so validation
        # still reports it.
        acc =
          case canonical_effort(Map.get(llm, :reasoning_effort)) do
            nil -> acc
            effort -> put_in(acc, [:llm, :reasoning_effort], effort)
          end

        # Canonical provider profiles and every nested option map use strings.
        # Malformed entries must survive normalization for validation.
        acc =
          case Map.fetch(llm, :providers) do
            {:ok, providers} ->
              put_in(
                acc,
                [:llm, :providers],
                providers
                |> EvoGit.Config.Schema.ProviderProfiles.Normalize.stringify()
                |> canonicalize_provider_efforts()
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

  @spec migrate_llm_models(map()) :: map()
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

  @spec canonical_providers?(map()) :: boolean()
  def canonical_providers?(llm) do
    case get_key(llm, :providers) do
      providers when is_list(providers) and providers != [] -> true
      _ -> false
    end
  end

  # `EvoGit.Config.Keys.fetch/2` owns the tolerant read (atom- OR
  # string-keyed maps, presence-based, never interning an atom). This public
  # name/arity stays because `EvoGit.Config` imports `get_key: 2`.
  @spec get_key(map(), atom() | String.t()) :: term() | nil
  def get_key(map, key) when is_map(map) do
    case Keys.fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
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
  @spec deep_merge(term(), term()) :: term()
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

  # ── Reasoning-effort canonicalization (the ONE ladder) ─────────────────
  #
  # `EvoGit.Config.Schema.LLM` owns effort ACCEPTANCE
  # (`reasoning_efforts/0`, `allowed?/1`, `canonical_reasoning_effort/1`); this
  # step only writes its answer back in the string spelling the schema stores.
  # `Normalize` canonicalizes account/model efforts when it RESOLVES a profile,
  # but validation runs on the normalized config first, so the same canonical
  # spelling is written here for the canonical account inventory and its nested
  # models. Unknown values are never rewritten, so validation still reports
  # them; a non-list/non-map entry survives untouched for the same reason.
  @effort_fields ~w(reasoning_effort default_reasoning_effort)

  defp canonicalize_provider_efforts(providers) when is_list(providers),
    do: Enum.map(providers, &canonicalize_profile_efforts/1)

  defp canonicalize_provider_efforts(other), do: other

  defp canonicalize_profile_efforts(%{} = profile) do
    profile
    |> canonicalize_effort_fields()
    |> canonicalize_effort_inventory()
    |> canonicalize_nested_model_efforts()
  end

  defp canonicalize_profile_efforts(other), do: other

  defp canonicalize_nested_model_efforts(%{"models" => models} = profile)
       when is_list(models) do
    Map.put(profile, "models", Enum.map(models, &canonicalize_model_efforts/1))
  end

  defp canonicalize_nested_model_efforts(profile), do: profile

  defp canonicalize_model_efforts(%{} = model) do
    model
    |> canonicalize_effort_fields()
    |> canonicalize_effort_inventory()
  end

  defp canonicalize_model_efforts(other), do: other

  defp canonicalize_effort_fields(map) do
    Enum.reduce(@effort_fields, map, fn key, acc ->
      case canonical_effort(Map.get(acc, key)) do
        nil -> acc
        effort -> Map.put(acc, key, effort)
      end
    end)
  end

  defp canonicalize_effort_inventory(%{"reasoning_efforts" => values} = map)
       when is_list(values) do
    Map.put(map, "reasoning_efforts", Enum.map(values, &keep_or_canonical_effort/1))
  end

  defp canonicalize_effort_inventory(map), do: map

  defp keep_or_canonical_effort(value), do: canonical_effort(value) || value

  # `nil` = "not a recognized effort" (including `nil` itself), so the caller
  # leaves the original value in place.
  defp canonical_effort(value) do
    case LLM.canonical_reasoning_effort(value) do
      nil -> nil
      effort -> Atom.to_string(effort)
    end
  end
end
