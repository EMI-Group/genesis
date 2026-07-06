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
