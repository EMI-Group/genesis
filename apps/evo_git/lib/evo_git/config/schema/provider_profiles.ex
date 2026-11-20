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

  `resolve_selection/2` accepts nil (configured default), a provider/legacy id,
  or a map with `provider_profile_id`, optional `model` and `reasoning_effort`.
  It returns selection fields plus the chosen `reasoning_effort`, canonical
  `provider_profile`, atom-keyed `runtime_profile`, ReqLLM `model_spec`, shared
  concurrency/peak fields and `generation_params`. The latter reuses LLM's OAuth
  and constraint choke point, adding `api_key` only when the named environment
  variable has a value. Enumeration never imports credentials or reads metadata;
  resolution can do both through the existing LLM helper.

  `resolve_model_spec/2` is only a compatibility alias for
  `resolve_selection/2`: the old name collides with a task's `model_spec`, which
  is the STRING-keyed selection identity (`provider_profile_id`/`model`/
  `reasoning_effort`) a task persists, whereas THIS resolver answers a ReqLLM
  model identifier under a `model_spec` key.
  """

  alias EvoGit.Config.Schema.LLM
  alias EvoGit.Config.Schema.ProviderProfiles.Normalize

  # ── Types ───────────────────────────────────────────────────────────

  @typedoc """
  A canonical provider account, STRING-keyed.

  `"id"`, `"provider"` and `"models"` (an ordered list of model maps) are always
  present; `"name"`, `"default_model"`, the reasoning-effort inventory and the
  auth/endpoint/schedule keys appear only when configured. Normalization (and
  legacy migration) belongs to
  `EvoGit.Config.Schema.ProviderProfiles.Normalize`.
  """
  @type provider_profile :: %{required(String.t()) => term()}

  @typedoc "One enumerated model/effort choice from an account's inventory."
  @type selection :: %{
          provider_profile_id: String.t(),
          profile_name: String.t(),
          provider: String.t(),
          model: String.t(),
          reasoning_efforts: [String.t()],
          default_reasoning_effort: String.t() | nil,
          context_window: pos_integer()
        }

  @typedoc """
  The ATOM-keyed profile the LLM layer consumes: the account's (model-overridden)
  auth/endpoint/generation fields plus `:id`, the ReqLLM `:model`, the resolved
  `:context_window` and the chosen `:reasoning_effort`. Absent fields are omitted
  rather than set to `nil`.
  """
  @type runtime_profile :: %{
          required(:id) => String.t(),
          required(:model) => reqllm_model(),
          required(:context_window) => pos_integer(),
          required(:reasoning_effort) => String.t() | nil,
          optional(atom()) => term()
        }

  @typedoc """
  A ReqLLM model identifier: the qualified `"provider:model"` string, or the
  endpoint-override map form ReqLLM also accepts.
  """
  @type reqllm_model ::
          String.t()
          | %{
              required(:provider) => atom(),
              required(:id) => String.t(),
              optional(:base_url) => String.t() | nil,
              optional(:extra) => map()
            }

  @typedoc "What a caller may ask `resolve_selection/2` for."
  @type selection_input :: nil | String.t() | map()

  @typedoc "Why a selection could not be resolved."
  @type resolution_error ::
          :invalid_config
          | :invalid_model_spec
          | {:provider_profile_not_found, term()}
          | {:duplicate_provider_profile_id, String.t()}
          | {:model_not_found, String.t() | nil, String.t() | nil}
          | {:duplicate_model, String.t(), String.t()}
          | {:invalid_reasoning_effort, term()}
          | {:unsupported_reasoning_effort, String.t(), [String.t()]}

  @typedoc """
  A resolved selection: the `selection/0` fields plus the chosen effort, the
  canonical account, its atom-keyed `runtime_profile`, the ReqLLM `model_spec`
  identifier and the assembled `generation_params`. The account's schedule keys
  (`:concurrency`, `:peak_concurrency`, `:peak_hours`, `:timezone`,
  `:off_peak_days`, `:off_peak_holidays`) are copied to the top level when set.
  """
  @type resolved_selection :: %{
          required(:provider_profile_id) => String.t(),
          required(:profile_name) => String.t(),
          required(:provider) => String.t(),
          required(:model) => String.t(),
          required(:reasoning_efforts) => [String.t()],
          required(:default_reasoning_effort) => String.t() | nil,
          required(:context_window) => pos_integer(),
          required(:reasoning_effort) => String.t() | nil,
          required(:provider_profile) => provider_profile(),
          required(:runtime_profile) => runtime_profile(),
          required(:model_spec) => reqllm_model(),
          required(:generation_params) => keyword(),
          optional(:concurrency) => pos_integer(),
          optional(:peak_concurrency) => non_neg_integer(),
          optional(:peak_hours) => [map()],
          optional(:timezone) => String.t(),
          optional(:off_peak_days) => [String.t()],
          optional(:off_peak_holidays) => String.t()
        }

  @runtime_keys ~w(id model auth_mode oauth_file siwc_account api_key_env_var temperature max_tokens reasoning_effort top_p top_k frequency_penalty presence_penalty provider_options context_window concurrency peak_concurrency peak_hours timezone off_peak_days off_peak_holidays)a
  @schedule_keys ~w(concurrency peak_concurrency peak_hours timezone off_peak_days off_peak_holidays)a

  @spec provider_profiles(term()) :: [provider_profile()]
  def provider_profiles(%{} = config), do: config |> Normalize.stringify() |> Normalize.profiles()
  def provider_profiles(_), do: []

  @spec model_selections(term()) :: [selection()]
  def model_selections(config) do
    for profile <- provider_profiles(config), model <- profile["models"] do
      selection(profile, model)
    end
  end

  @doc """
  Resolves a provider-profile selection into everything the runtime needs.

  Accepts `nil` (the configured default account/model), a provider or legacy
  profile id, or a map with `provider_profile_id`, optional `model` and
  `reasoning_effort`. See the module doc for the returned shape.
  """
  @spec resolve_selection(term(), selection_input()) ::
          {:ok, resolved_selection()} | {:error, resolution_error()}
  def resolve_selection(%{} = config, spec) do
    config = Normalize.stringify(config)
    profiles = provider_profiles(config)

    with {:ok, {profile, model, effort}} <- resolve_selection_fields(config, profiles, spec) do
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

  def resolve_selection(_, _), do: {:error, :invalid_config}

  @doc """
  Compatibility alias for `resolve_selection/2`, identical in arguments and
  return value.

  Kept because in-tree callers (task admission, scheduler dispatch, the
  dashboard's selection surfaces) and their tests still use this name. Prefer
  `resolve_selection/2` in new code: this resolver's `model_spec` key is a
  ReqLLM-ready identifier, NOT a task's STRING-keyed `model_spec` selection
  identity, so the old name reads as the wrong thing at every call site.
  """
  @spec resolve_model_spec(term(), selection_input()) ::
          {:ok, resolved_selection()} | {:error, resolution_error()}
  def resolve_model_spec(config, spec), do: resolve_selection(config, spec)

  # Runtime compatibility reads must not assemble generation params: scheduler
  # boot deliberately leaves cold catalog loading to CatalogWarmup.
  @doc false
  @spec resolve_runtime_profile(term(), selection_input()) ::
          {:ok, runtime_profile()} | {:error, resolution_error()}
  def resolve_runtime_profile(%{} = config, spec) do
    config = Normalize.stringify(config)

    with {:ok, {profile, model, effort}} <-
           resolve_selection_fields(config, provider_profiles(config), spec) do
      {:ok, runtime_profile(profile, model, effort)}
    end
  end

  def resolve_runtime_profile(_, _), do: {:error, :invalid_config}

  defp resolve_selection_fields(config, profiles, spec) do
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

  defp reqllm_model(%{"provider" => "openai_compatible"} = profile, model) do
    extra = option_keys(profile["extra"] || %{})
    wire = Map.get(extra, :wire)
    wire = if is_map(wire), do: wire, else: %{}

    %{
      provider: :openai,
      id: model["model"],
      base_url: profile["base_url"],
      extra: Map.put(extra, :wire, Map.put(wire, :protocol, "openai_chat"))
    }
  end

  defp reqllm_model(profile, model) do
    qualified = profile["provider"] <> ":" <> model["model"]

    overrides =
      if profile["provider"] == "openai_codex",
        do: %{},
        else: Map.take(profile, ["base_url", "extra"])

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
