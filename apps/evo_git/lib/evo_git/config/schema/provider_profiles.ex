defmodule EvoGit.Config.Schema.ProviderProfiles do
  @moduledoc """
  Canonical provider accounts and ordered model selections.

  `provider_profiles/1` is a read-only normalization boundary: it accepts atom-
  or string-keyed config and returns string-keyed provider maps, including nested
  model maps. Explicit `llm.providers` wins over legacy `llm.models`; legacy
  profiles migrate one-for-one without combining accounts or changing ids.
  Flat `llm.model` becomes the provider profile `"default"`.

  A model entry is a string or a map with `model` (also accepts `id` on input),
  optional `context_window`, `reasoning_efforts`, `default_reasoning_effort` and
  generation overrides. Provider defaults apply first, then model overrides.
  Effort inventories retain their configured order; no effort is invented when
  neither level declares a default. An empty inventory imposes no restriction.

  `resolve_model_spec/2` accepts nil (configured default), a provider/legacy id,
  or a map with `provider_profile_id`, optional `model` and `reasoning_effort`.
  It returns selection fields plus the chosen `reasoning_effort`, canonical
  `provider_profile`, atom-keyed `runtime_profile`, ReqLLM `model_spec`, shared
  concurrency/peak fields and `generation_params`. The latter reuses LLM's OAuth
  and constraint choke point, adding `api_key` only when the named environment
  variable has a value. Enumeration never imports credentials or reads metadata;
  resolution can do both through the existing LLM helper.
  """

  alias EvoGit.Config.Schema.LLM
  alias EvoGit.Config.Schema.ProviderProfiles.Normalize

  @runtime_keys ~w(id model auth_mode oauth_file api_key_env_var temperature max_tokens reasoning_effort top_p top_k frequency_penalty presence_penalty provider_options context_window concurrency peak_concurrency peak_hours timezone off_peak_days)a
  @schedule_keys ~w(concurrency peak_concurrency peak_hours timezone off_peak_days)a

  @spec provider_profiles(term()) :: [map()]
  def provider_profiles(%{} = config), do: config |> Normalize.stringify() |> Normalize.profiles()
  def provider_profiles(_), do: []

  @spec model_selections(term()) :: [map()]
  def model_selections(config) do
    for profile <- provider_profiles(config), model <- profile["models"] do
      selection(profile, model)
    end
  end

  @spec resolve_model_spec(term(), term()) :: {:ok, map()} | {:error, term()}
  def resolve_model_spec(%{} = config, spec) do
    config = Normalize.stringify(config)
    profiles = provider_profiles(config)

    with {:ok, {profile, model, effort}} <- resolve_selection(config, profiles, spec) do
      runtime_profile = runtime_profile(profile, model, effort)
      params = LLM.profile_generation_params(runtime_profile)

      resolved =
        selection(profile, model)
        |> Map.merge(Map.take(runtime_profile, @schedule_keys))
        |> Map.merge(%{
          reasoning_effort: effort,
          provider_profile: profile,
          runtime_profile: runtime_profile,
          model_spec: runtime_profile.model,
          generation_params: params
        })

      {:ok, resolved}
    end
  end

  def resolve_model_spec(_, _), do: {:error, :invalid_config}

  # Runtime compatibility reads must not assemble generation params: scheduler
  # boot deliberately leaves cold catalog loading to CatalogWarmup.
  @doc false
  @spec resolve_runtime_profile(term(), term()) :: {:ok, map()} | {:error, term()}
  def resolve_runtime_profile(%{} = config, spec) do
    config = Normalize.stringify(config)

    with {:ok, {profile, model, effort}} <-
           resolve_selection(config, provider_profiles(config), spec) do
      {:ok, runtime_profile(profile, model, effort)}
    end
  end

  def resolve_runtime_profile(_, _), do: {:error, :invalid_config}

  defp resolve_selection(config, profiles, spec) do
    with {:ok, spec} <- normalize_spec(spec),
         {:ok, profile} <- find_profile(config, profiles, spec),
         {:ok, model} <- find_model(profile, spec),
         {:ok, effort} <- resolve_effort(profile, model, spec) do
      {:ok, {profile, model, effort}}
    end
  end

  defp normalize_spec(nil), do: {:ok, %{}}

  defp normalize_spec(id) when is_binary(id) and id != "",
    do: {:ok, %{"provider_profile_id" => id}}

  defp normalize_spec(%{} = spec), do: {:ok, Normalize.stringify(spec)}
  defp normalize_spec(_), do: {:error, :invalid_model_spec}

  defp find_profile(config, profiles, spec) do
    llm = Normalize.section(config, "llm")

    id =
      Map.get(spec, "provider_profile_id") || Map.get(llm, "default_provider_profile") ||
        first_profile_id(profiles)

    case Enum.filter(profiles, &(&1["id"] == id)) do
      [profile] -> {:ok, profile}
      [] -> {:error, {:provider_profile_not_found, id}}
      _ -> {:error, {:duplicate_provider_profile_id, id}}
    end
  end

  defp first_profile_id([profile | _]), do: profile["id"]
  defp first_profile_id([]), do: nil

  defp find_model(profile, spec) do
    case Map.get(spec, "model") || profile["default_model"] do
      id when is_binary(id) and id != "" ->
        id = Normalize.unqualify(id, profile["provider"])

        case Enum.filter(profile["models"], &(&1["model"] == id)) do
          [model] -> {:ok, model}
          [] -> {:error, {:model_not_found, profile["id"], id}}
          _ -> {:error, {:duplicate_model, profile["id"], id}}
        end

      _ ->
        {:error, {:model_not_found, profile["id"], nil}}
    end
  end

  defp selection(profile, model) do
    %{
      provider_profile_id: profile["id"],
      profile_name: profile["name"] || profile["id"],
      provider: profile["provider"],
      model: model["model"],
      reasoning_efforts: effective_efforts(profile, model),
      default_reasoning_effort: default_effort(profile, model),
      context_window: LLM.context_window(inherit(profile, model))
    }
  end

  defp inherit(profile, model) do
    # nil means absent, matching the existing generation-parameter contract.
    overrides =
      model
      |> Map.take(
        Normalize.generation_keys() ++
          ["context_window", "reasoning_efforts", "default_reasoning_effort"]
      )
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Map.merge(profile, overrides)
  end

  defp effective_efforts(profile, model) do
    Map.get(model, "reasoning_efforts", profile["reasoning_efforts"])
  end

  defp default_effort(profile, model) do
    Normalize.string_effort(
      model["default_reasoning_effort"] || model["reasoning_effort"] ||
        profile["default_reasoning_effort"] || profile["reasoning_effort"]
    )
  end

  defp resolve_effort(profile, model, spec) do
    value = Map.get(spec, "reasoning_effort")

    effort =
      if is_nil(value), do: default_effort(profile, model), else: Normalize.string_effort(value)

    allowed = effective_efforts(profile, model)

    cond do
      not is_nil(value) and is_nil(effort) ->
        {:error, {:invalid_reasoning_effort, value}}

      is_nil(effort) or allowed == [] or effort in allowed ->
        {:ok, effort}

      true ->
        {:error, {:unsupported_reasoning_effort, effort, allowed}}
    end
  end

  defp runtime_profile(profile, model, effort) do
    inherited = inherit(profile, model)

    runtime =
      Map.new(@runtime_keys, fn key -> {key, Map.get(inherited, Atom.to_string(key))} end)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.put(:id, profile["id"])
      |> Map.put(:model, reqllm_model(profile, model))
      |> Map.put(:context_window, LLM.context_window(inherited))
      |> Map.put(:reasoning_effort, effort)

    case Map.get(runtime, :provider_options) do
      %{} = options -> Map.put(runtime, :provider_options, option_keys(options))
      _ -> runtime
    end
  end

  defp reqllm_model(profile, model) do
    qualified = profile["provider"] <> ":" <> model["model"]
    overrides = Map.take(profile, ["base_url", "extra"])
    overrides = Map.reject(overrides, fn {_key, value} -> is_nil(value) end)

    if map_size(overrides) == 0 do
      qualified
    else
      overrides
      |> option_keys()
      |> Map.put(:provider, LLM.provider_from_model(qualified))
      |> Map.put(:id, model["model"])
    end
  end

  # The existing config path also converts known option keys to existing atoms.
  # Unknown keys stay strings rather than growing the atom table on user input.
  defp option_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {existing_key(key), option_keys(value)} end)
  end

  defp option_keys(list) when is_list(list), do: Enum.map(list, &option_keys/1)
  defp option_keys(value), do: value

  defp existing_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    # There is no non-raising existing-atom lookup; keep unknown custom keys.
    ArgumentError -> key
  end

  defp existing_key(key), do: key
end
