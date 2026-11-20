defmodule EvoGit.Config.Schema.ProviderProfiles.Normalize do
  @moduledoc false

  alias EvoGit.Config.Keys
  alias EvoGit.Config.Schema.LLM

  @generation_keys ~w(temperature max_tokens reasoning_effort top_p top_k frequency_penalty presence_penalty provider_options)
  @shared_keys ~w(auth_mode api_key_env_var base_url oauth_file siwc_account concurrency peak_concurrency peak_hours timezone off_peak_days off_peak_holidays context_window extra)

  @spec generation_keys() :: [String.t()]
  def generation_keys, do: @generation_keys

  # `EvoGit.Config.Keys.stringify/2` owns the recursive traversal; the
  # `keyword_lists: true` policy is this call site's own (a provider/model entry
  # may arrive as a keyword list) and nil values are KEPT, because a present nil
  # is meaningful input here rather than a TOML null.
  @spec stringify(term()) :: term()
  def stringify(value), do: Keys.stringify(value, keyword_lists: true)

  @spec section(map(), String.t()) :: map()
  def section(config, key) do
    case Map.get(config, key) do
      %{} = map -> map
      _ -> %{}
    end
  end

  @spec profiles(map()) :: [map()]
  def profiles(config) do
    llm = section(config, "llm")

    case Map.get(llm, "providers") do
      providers when is_list(providers) and providers != [] ->
        Enum.flat_map(providers, &canonical_profile/1)

      _ ->
        legacy_profiles(config, llm)
    end
  end

  defp canonical_profile(%{"id" => id, "provider" => provider} = profile)
       when is_binary(id) and id != "" do
    case provider_name(provider) do
      nil ->
        []

      provider ->
        models = normalize_models(Map.get(profile, "models", []), provider)

        route =
          if provider == "openai" and auth_mode(profile, provider) == "oauth",
            do: "openai_codex",
            else: provider

        profile =
          profile
          |> Map.put("models", models)
          |> Map.put_new("concurrency", 3)
          |> Map.put("auth_mode", auth_mode(profile, provider))
          |> Map.put("reasoning_efforts", efforts(Map.get(profile, "reasoning_efforts")))
          |> normalize_default_effort()
          |> put_default_model(models, provider)
          |> Map.put("provider", route)

        [profile]
    end
  end

  defp canonical_profile(_), do: []

  defp normalize_models(models, provider) when is_list(models) do
    Enum.flat_map(models, fn
      model when is_binary(model) and model != "" ->
        [%{"model" => unqualify(model, provider)}]

      %{} = model ->
        case Map.get(model, "model", Map.get(model, "id")) do
          id when is_binary(id) and id != "" ->
            normalized = model |> Map.delete("id") |> Map.put("model", unqualify(id, provider))

            normalized =
              if Map.has_key?(model, "reasoning_efforts") do
                Map.put(normalized, "reasoning_efforts", efforts(model["reasoning_efforts"]))
              else
                normalized
              end

            [normalize_default_effort(normalized)]

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp normalize_models(_, _), do: []

  defp normalize_default_effort(map) do
    Enum.reduce(["default_reasoning_effort", "reasoning_effort"], map, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.update!(acc, key, &string_effort/1), else: acc
    end)
  end

  defp put_default_model(profile, models, provider) do
    case Map.get(profile, "default_model") do
      model when is_binary(model) and model != "" ->
        Map.put(profile, "default_model", unqualify(model, provider))

      _ ->
        Map.put(profile, "default_model", first_model(models))
    end
  end

  defp first_model([model | _]), do: model["model"]
  defp first_model([]), do: nil

  defp legacy_profiles(config, llm) do
    profiles =
      case Map.get(llm, "models") do
        models when is_list(models) and models != [] -> models
        _ -> [legacy_flat(config, llm)]
      end

    Enum.flat_map(profiles, &migrate_profile/1)
  end

  defp legacy_flat(config, llm) do
    concurrency = Map.get(section(config, "scheduler"), "default_llm_max_concurrency", 3)
    llm |> Map.put("id", "default") |> Map.put_new("concurrency", concurrency)
  end

  # Each old model profile remains its own account, even when its provider,
  # endpoint and model coincide with another profile's values.
  defp migrate_profile(%{"id" => id, "model" => model} = old)
       when is_binary(id) and id != "" do
    case split_model(model) do
      {provider, model_id, overrides} ->
        effort = string_effort(Map.get(old, "reasoning_effort"))

        profile =
          old
          |> Map.take(@shared_keys ++ @generation_keys ++ ["name"])
          |> Map.merge(overrides)
          |> Map.merge(%{
            "id" => id,
            "provider" => provider,
            "default_model" => model_id,
            "models" => [%{"model" => model_id}],
            "reasoning_efforts" => if(effort, do: [effort], else: []),
            "default_reasoning_effort" => effort
          })

        canonical_profile(profile)

      nil ->
        []
    end
  end

  defp migrate_profile(_), do: []

  defp split_model(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, id] when provider != "" and id != "" -> {provider, id, %{}}
      _ -> nil
    end
  end

  defp split_model(%{"provider" => provider, "id" => id} = model)
       when is_binary(id) and id != "" do
    case provider_name(provider) do
      nil -> nil
      provider -> {provider, id, Map.take(model, ["base_url", "extra", "api_key_env_var"])}
    end
  end

  defp split_model({provider, opts}) when is_list(opts) do
    split_model(opts |> Map.new() |> stringify() |> Map.put("provider", provider))
  end

  defp split_model(_), do: nil

  defp auth_mode(profile, provider) do
    case Map.get(profile, "auth_mode") do
      value when value in [:oauth, "oauth"] -> "oauth"
      _ -> if LLM.oauth_profile?(%{model: provider <> ":_"}), do: "oauth", else: "api_key"
    end
  end

  @spec provider_name(term()) :: String.t() | nil
  def provider_name(provider) when is_atom(provider) and not is_nil(provider),
    do: Atom.to_string(provider)

  def provider_name(provider) when is_binary(provider) and provider != "", do: provider
  def provider_name(_), do: nil

  @spec unqualify(String.t(), String.t()) :: String.t()
  def unqualify(model, provider) do
    prefix = provider <> ":"

    if String.starts_with?(model, prefix),
      do: String.replace_prefix(model, prefix, ""),
      else: model
  end

  @spec efforts(term()) :: [String.t()]
  def efforts(values) when is_list(values) do
    values |> Enum.map(&string_effort/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  def efforts(_), do: []

  @doc """
  Canonical STRING spelling of one reasoning-effort value, or `nil` for an
  unusable input.

  Acceptance is decided ONCE by the canonical ladder
  (`EvoGit.Config.Schema.LLM.canonical_reasoning_effort/1`), never re-derived
  here: a KNOWN effort — string or atom, any case, surrounding whitespace
  ignored — becomes its canonical string spelling (`"MAX"` / `:max` /
  `" max "` → `"xhigh"`, `" High "` → `"high"`, `:default` → `"default"`).
  An UNKNOWN binary or atom keeps its own string form (it is not offered, so
  validation reports it), and any other type (`42`, `%{}`) is `nil`.
  """
  @spec string_effort(term()) :: String.t() | nil
  def string_effort(value) when is_binary(value) and value != "" do
    canonical_effort(value) || value
  end

  def string_effort(value) when is_atom(value) and not is_nil(value) do
    canonical_effort(value) || Atom.to_string(value)
  end

  def string_effort(_), do: nil

  # The ONE ladder's answer as a string: `nil` means "not a recognized effort",
  # including the `:max` legacy alias, which the ladder itself canonicalizes to
  # `:xhigh`.
  defp canonical_effort(value) do
    case LLM.canonical_reasoning_effort(value) do
      nil -> nil
      effort -> Atom.to_string(effort)
    end
  end
end
