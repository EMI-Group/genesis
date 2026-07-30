defmodule EvoGit.Config.Schema.LLM do
  @moduledoc """
  LLM generation parameter extraction from config/model profiles.
  """

  @doc """
  Extracts LLM generation parameters, filtering out nil values.

  Returns a keyword list suitable for passing to `ReqLLM.stream_text/3`.

  Accepts either:
  - A **model profile map** (e.g. `%{id: "default", temperature: 0.7, ...}`) —
    extracts params directly from the profile.
  - A **resolved config map** (e.g. `%{llm: %{temperature: 0.7, ...}}`) —
    delegates to the default model profile.

  ## Example

      iex> Schema.LLM.llm_generation_params(%{id: "default", temperature: 0.7, max_tokens: 4096})
      [temperature: 0.7, max_tokens: 4096]

      iex> Schema.LLM.llm_generation_params(%{llm: %{models: [%{id: "default", temperature: 0.7}]}})
      [temperature: 0.7]
  """
  @spec llm_generation_params(map()) :: keyword()
  def llm_generation_params(config) when is_map(config) do
    cond do
      # Model profile map: has an :id key (profiles always have id)
      Map.has_key?(config, :id) ->
        profile_generation_params(config)

      # Resolved config map: delegate to default profile
      Map.has_key?(config, :llm) ->
        case default_model_profile(config) do
          {:ok, profile} -> profile_generation_params(profile)
          {:error, :not_found} -> []
        end

      true ->
        []
    end
  end

  @doc """
  Returns the list of model profiles from a resolved config map.

  Defensive against malformed config: if `:llm` is not a map (e.g. user wrote
  `llm = "claude"` — a scalar — instead of a `[llm]` table), returns `[]`.

  ## Example

      iex> Schema.LLM.model_profiles(%{llm: %{models: [%{id: "default", model: "x:y"}]}})
      [%{id: "default", model: "x:y"}]
  """
  @spec model_profiles(map()) :: [map()]
  def model_profiles(config) when is_map(config) do
    llm = Map.get(config, :llm)
    models = if is_map(llm), do: Map.get(llm, :models), else: nil
    if is_list(models), do: models, else: []
  end

  @doc """
  Resolves a model profile by id.

  Returns `{:ok, profile}` if found, or `{:error, :not_found}`.

  ## Example

      iex> Schema.LLM.get_model_profile(%{llm: %{models: [%{id: "fast", model: "x:y"}]}}, "fast")
      {:ok, %{id: "fast", model: "x:y"}}
  """
  @spec get_model_profile(map(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_model_profile(config, id) when is_map(config) and is_binary(id) do
    case Enum.find(model_profiles(config), fn p -> Map.get(p, :id) == id end) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  @doc """
  Returns the first (default) model profile from a resolved config map.

  Returns `{:ok, profile}` if at least one profile exists, or `{:error, :not_found}`.

  ## Example

      iex> Schema.LLM.default_model_profile(%{llm: %{models: [%{id: "default", model: "x:y"}]}})
      {:ok, %{id: "default", model: "x:y"}}
  """
  @spec default_model_profile(map()) :: {:ok, map()} | {:error, :not_found}
  def default_model_profile(config) when is_map(config) do
    case model_profiles(config) do
      [] -> {:error, :not_found}
      [profile | _] -> {:ok, profile}
    end
  end

  @doc """
  Builds a single "default" model profile from flat (legacy) `[llm]` and
  `[scheduler]` config sections.

  Used when `[[llm.models]]` is empty or absent, so the runtime always has at
  least one profile to work with. Generation params from the flat `[llm]`
  section are included; nil values are omitted.

  The returned profile always has at least `:id`, `:model`, and `:concurrency`
  keys. The `:model` value may be `nil` when no model is configured.

  ## Example

      iex> Schema.LLM.build_legacy_default_profile(%{
      ...>   llm: %{model: "anthropic:claude", temperature: 0.7},
      ...>   scheduler: %{max_concurrency: 5}
      ...> })
      %{id: "default", model: "anthropic:claude", concurrency: 5, temperature: 0.7}
  """
  @spec build_legacy_default_profile(map()) :: map()
  def build_legacy_default_profile(config) when is_map(config) do
    raw_llm = Map.get(config, :llm, %{})
    llm = if is_map(raw_llm), do: raw_llm, else: %{}
    raw_scheduler = Map.get(config, :scheduler, %{})
    scheduler = if is_map(raw_scheduler), do: raw_scheduler, else: %{}
    concurrency = Map.get(scheduler, :max_concurrency, 3)

    %{
      id: "default",
      model: Map.get(llm, :model),
      concurrency: concurrency
    }
    |> maybe_put(:temperature, Map.get(llm, :temperature))
    |> maybe_put(:max_tokens, Map.get(llm, :max_tokens))
    |> maybe_put(:reasoning_effort, Map.get(llm, :reasoning_effort))
    |> maybe_put(:top_p, Map.get(llm, :top_p))
    |> maybe_put(:top_k, Map.get(llm, :top_k))
    |> maybe_put(:frequency_penalty, Map.get(llm, :frequency_penalty))
    |> maybe_put(:presence_penalty, Map.get(llm, :presence_penalty))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Default provider options for OpenAI models.

  Disables the OpenAI Responses API server-side storage (`store: false`), which in turn
  prevents the automatic injection of `previous_response_id` — a field only supported
  on WebSocket v2, not the default HTTP/SSE streaming transport. EvoGit manages its own
  full conversation history, so server-side response chaining/storage is never needed.

  This is **OpenAI-specific** — the `store` option only exists for OpenAI's Responses API.
  Applying it globally to all providers would break non-OpenAI providers. Use
  `provider_options_for_model/1` at call sites instead, which returns this default only
  when the model's provider is `:openai`.
  """
  @spec default_provider_options() :: keyword()
  def default_provider_options, do: [store: false]

  @doc """
  Extracts the provider atom from a model spec.

  Supports the three model spec formats used throughout EvoGit:

  - **String** like `"openai:gpt-5"` — splits on the first `":"` and atomizes the
    provider part via `String.to_atom/1`.
  - **Map** like `%{provider: :openai, id: "gpt-5"}` — returns `Map.get(model, :provider)`,
    normalizing string values to atoms.
  - **Tuple** `{:openai, opts}` — returns the first element (the provider atom).

  Returns `nil` for string specs without a colon, or any unrecognized format.
  """
  @spec provider_from_model(String.t() | map() | tuple() | nil) :: atom() | nil
  def provider_from_model(nil), do: nil

  def provider_from_model(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _id] when provider != "" -> String.to_atom(provider)
      _ -> nil
    end
  end

  def provider_from_model({provider, _opts}) when is_atom(provider), do: provider

  def provider_from_model(model) when is_map(model) do
    case Map.get(model, :provider) do
      provider when is_atom(provider) and not is_nil(provider) -> provider
      provider when is_binary(provider) -> String.to_atom(provider)
      _ -> nil
    end
  end

  def provider_from_model(_other), do: nil

  @doc """
  Returns the appropriate `provider_options` keyword list for a given model spec.

  Returns `[store: false]` (via `default_provider_options/0`) when the model's
  provider is `:openai`, otherwise `[]`. This prevents applying OpenAI-specific
  options (like `store`) to non-OpenAI providers.
  """
  @spec provider_options_for_model(String.t() | map() | tuple() | nil) :: keyword()
  def provider_options_for_model(model) do
    if provider_from_model(model) == :openai, do: default_provider_options(), else: []
  end

  @doc """
  Extracts generation params from a single profile map.
  """
  @spec profile_generation_params(map()) :: keyword()
  def profile_generation_params(profile) when is_map(profile) do
    []
    |> maybe_param(:temperature, Map.get(profile, :temperature))
    |> maybe_param(:max_tokens, Map.get(profile, :max_tokens))
    |> maybe_param(:reasoning_effort, profile |> Map.get(:reasoning_effort) |> convert_reasoning_effort())
    |> maybe_param(:top_p, Map.get(profile, :top_p))
    |> maybe_param(:top_k, Map.get(profile, :top_k))
    |> maybe_param(:frequency_penalty, Map.get(profile, :frequency_penalty))
    |> maybe_param(:presence_penalty, Map.get(profile, :presence_penalty))
    |> maybe_provider_options(profile)
  end

  # Resolves provider_options for a profile, preferring an explicit user override
  # over the provider-aware default.
  #
  # - Explicit `provider_options` map in config → converted to a keyword list (user override).
  # - Explicit `provider_options` keyword list in config → used as-is.
  # - Otherwise → `provider_options_for_model/1` (store: false only for OpenAI).
  # When the resolved list is empty, the `:provider_options` key is omitted entirely
  # (non-OpenAI profiles without an override must NOT get store: false).
  defp maybe_provider_options(keyword_list, profile) do
    case resolve_provider_options(profile) do
      [] -> keyword_list
      opts -> keyword_list ++ [{:provider_options, opts}]
    end
  end

  defp resolve_provider_options(profile) do
    case Map.get(profile, :provider_options) do
      nil ->
        provider_options_for_model(Map.get(profile, :model))

      override when is_map(override) ->
        Map.to_list(override)

      override when is_list(override) ->
        override
    end
  end

  @doc """
  Conditionally appends a key/value pair to a keyword list, skipping nil values.
  """
  @spec maybe_param(keyword(), atom(), term()) :: keyword()
  def maybe_param(keyword_list, _key, nil), do: keyword_list
  def maybe_param(keyword_list, key, value), do: keyword_list ++ [{key, value}]

  @doc """
  Converts reasoning_effort string from config (TOML) to atom expected by ReqLLM.
  Uses explicit case matching rather than String.to_existing_atom for safety.
  """
  @spec convert_reasoning_effort(String.t() | nil | atom()) :: atom() | String.t() | nil
  def convert_reasoning_effort(nil), do: nil
  def convert_reasoning_effort("none"), do: :none
  def convert_reasoning_effort("minimal"), do: :minimal
  def convert_reasoning_effort("low"), do: :low
  def convert_reasoning_effort("medium"), do: :medium
  def convert_reasoning_effort("high"), do: :high
  def convert_reasoning_effort("xhigh"), do: :xhigh
  def convert_reasoning_effort("default"), do: :default
  def convert_reasoning_effort(other), do: other
end
