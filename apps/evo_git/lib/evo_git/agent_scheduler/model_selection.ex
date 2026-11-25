defmodule EvoGit.AgentScheduler.ModelSelection do
  @moduledoc """
  Scheduler adapter for configuration model selections and provider/account pools.

  Configuration owns validation and request-parameter assembly; this module keeps
  the resolved configuration snapshot together so dispatch never re-reads disk.
  `EvoGit.Config.Schema` is a compile-time dependency, so every selection read is
  a direct call; legacy scheduler fixtures stay usable through the LEGACY branch
  (`model_profiles` only) rather than through runtime schema probing.
  """

  alias EvoGit.AgentScheduler.State
  alias EvoGit.Config.Keys
  alias EvoGit.Config.Schema

  @doc "Returns the model configuration options shared by boot and reload."
  @spec config_opts(map()) :: keyword()
  def config_opts(config) do
    providers = Schema.provider_profiles(config)

    canonical? =
      case Keys.get(config, :llm) do
        %{} = llm -> match?([_ | _], Keys.get(llm, :providers))
        _ -> false
      end

    profiles =
      if canonical?,
        do: Schema.model_selections(config),
        else: Schema.effective_model_profiles(config)

    if canonical? or providers != [] do
      [
        model_profiles: profiles,
        provider_profiles: providers,
        model_selection_config: config
      ]
    else
      # An unconfigured legacy default has a nil model and cannot be resolved
      # through the account schema. Use the legacy replacement path on reload
      # too, so nil filtering cannot leave an old account snapshot installed.
      [model_profiles: profiles]
    end
  end

  @doc """
  Returns true when an update replaces the complete model profiles with a
  legacy inventory (id + qualified model) instead of the canonical selection
  inventory (provider_profile_id + unqualified model).
  """
  @spec legacy_replacement?(keyword()) :: boolean()
  def legacy_replacement?(opts) do
    Keyword.has_key?(opts, :model_profiles) and
      not Keyword.has_key?(opts, :provider_profiles) and
      not Keyword.has_key?(opts, :model_selection_config) and
      Enum.all?(Keyword.fetch!(opts, :model_profiles), fn profile ->
        selection = Keys.get(profile, :model_spec) || profile

        is_nil(Keys.get(profile, :provider_profile_id)) and
          is_nil(Keys.get(selection, :provider_profile_id))
      end)
  end

  @doc "Keeps runtime profile replacements and their selection snapshot consistent."
  @spec update_opts(State.t(), keyword()) :: keyword()
  def update_opts(%State{} = state, opts) do
    # Legacy callers replace complete profiles (id + qualified model), not the
    # canonical selection inventory (provider_profile_id + unqualified model).
    # They must return to legacy resolution, including model-selection scripts,
    # rather than resolving the new ids against the boot-time account snapshot.
    # Empty replacements also clear model configuration, as they always did.
    if legacy_replacement?(opts) do
      opts
      |> Keyword.put(:provider_profiles, [])
      |> Keyword.put(:model_selection_config, nil)
    else
      opts
      |> Keyword.put_new(:provider_profiles, state.provider_profiles)
      |> Keyword.put_new(:model_selection_config, state.model_selection_config)
    end
  end

  @doc "Returns the resource-pool identity, distinct from a legacy selection id."
  @spec pool_id(map()) :: String.t()
  def pool_id(profile) do
    selection = Keys.get(profile, :model_spec, profile)

    Keys.get(selection, :provider_profile_id) || Keys.get(profile, :provider_profile_id) ||
      Keys.get(profile, :id, "default")
  end

  @doc "Finds an explicit task selection, including options from older AgentSpec structs."
  @spec explicit_spec(map()) :: {:ok, map()} | :error
  def explicit_spec(spec) do
    case Map.get(spec, :model_spec) do
      nil -> Keyword.fetch(spec.opts, :model_spec)
      selection -> {:ok, selection}
    end
  end

  @doc "Copies a locked parent's entire selection, not merely its legacy id."
  @spec inherit(map(), map()) :: map()
  def inherit(spec, %{model_id_locked: true, model_spec: selection} = parent)
      when is_map(selection) do
    opts = spec.opts |> Keyword.put(:model_spec, selection) |> Keyword.put(:model_id_locked, true)
    spec = %{spec | model_id: parent.model_id, opts: opts}
    if Map.has_key?(spec, :model_spec), do: Map.put(spec, :model_spec, selection), else: spec
  end

  def inherit(spec, %{model_id_locked: true} = parent) do
    # A legacy lock has no canonical selection to copy. Remove both child
    # selection sources so explicit-spec resolution cannot override the lock.
    opts = spec.opts |> Keyword.delete(:model_spec) |> Keyword.put(:model_id_locked, true)
    spec = %{spec | model_id: parent.model_id, opts: opts}
    if Map.has_key?(spec, :model_spec), do: Map.put(spec, :model_spec, nil), else: spec
  end

  def inherit(spec, _parent), do: spec

  @doc "Validates the task wire shape before schema resolution (nil is not a default here)."
  @spec resolve_explicit(State.t(), term()) :: {:ok, map()} | {:error, term()}
  def resolve_explicit(state, %{"provider_profile_id" => id, "model" => model} = requested)
      when is_binary(id) and is_binary(model) do
    if String.trim(id) != "" and String.trim(model) != "" do
      resolve(state, requested)
    else
      {:error, :invalid_model_spec}
    end
  end

  def resolve_explicit(_state, _requested), do: {:error, :invalid_model_spec}

  @doc "Resolves an explicit map or legacy selection id through the schema."
  @spec resolve(State.t(), term()) :: {:ok, map()} | {:error, term()}
  def resolve(%State{} = state, requested) do
    if is_map(state.model_selection_config) do
      case Schema.resolve_selection(state.model_selection_config, requested) do
        {:ok, resolved} ->
          selection = normalize(requested, resolved)

          if is_binary(selection.provider_profile_id) and selection.provider_profile_id != "" and
               is_binary(selection.model_spec["model"]) and
               (is_binary(selection.llm_model) or is_map(selection.llm_model)) and
               Keyword.keyword?(selection.llm_generation_params) do
            {:ok, selection}
          else
            {:error, :invalid_resolved_model_spec}
          end

        {:error, _} = error ->
          error
      end
    else
      {:error, :model_spec_schema_unavailable}
    end
  end

  defp normalize(requested, resolved) do
    # Schema's model_spec is a ReqLLM identifier (qualified string or endpoint
    # map), NOT the task selection. Keep these two wire contracts separate.
    provider_id = Keys.get(resolved, :provider_profile_id)
    effort = Keys.get(resolved, :reasoning_effort)
    model_spec = %{"provider_profile_id" => provider_id, "model" => Keys.get(resolved, :model)}

    model_spec =
      if is_nil(effort), do: model_spec, else: Map.put(model_spec, "reasoning_effort", effort)

    runtime_profile = Keys.get(resolved, :runtime_profile)

    %{
      # Schema migrates legacy ids one-for-one to provider ids; explicit task
      # maps have no legacy alias. Default resolution must honor configured
      # provider/model defaults, not the first enumerated selection.
      model_id: if(is_map(requested), do: nil, else: provider_id),
      provider_profile_id: provider_id,
      model_spec: model_spec,
      llm_model: Keys.get(resolved, :model_spec),
      llm_generation_params: Keys.get(resolved, :generation_params),
      llm_context_window: Schema.LLM.context_window(runtime_profile),
      # The ACCOUNT provider identity (a STRING such as "openai"; nil when the
      # schema resolved none). Used solely to attach the per-run prompt-cache
      # identity at registration, because the resolved model spec need not
      # carry a provider part. This is NOT the model spec.
      provider: Keys.get(resolved, :provider)
    }
  end
end
