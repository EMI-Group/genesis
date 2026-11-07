defmodule EvoDashWeb.LLMSelection do
  @moduledoc """
  Shared canonical task-model selection for Projects, Assistant and onboarding.

  `from_config/2` keeps the node's config together with the core's canonical
  provider/model projections and the model-selection-rules flag. This bundle
  is server-side state: config may contain credentials and must not be persisted
  in browser state or chat history.

  Picker state is a string-keyed map containing `provider_profile_id`, `model`
  and, when applicable, `reasoning_effort`. An empty map (or empty legacy string)
  explicitly means Auto; nil means uninitialized and selects the configured
  default, even when rules are enabled. Nonempty legacy profile ids migrate
  through the core resolver, never by splitting or interpreting their strings.

  `reconcile/2` is for restoring/displaying state: stale selections revert to
  the configured default (or an empty picker if no valid default exists).
  `task_opts/3` is deliberately stricter: invalid explicit selections return
  an error rather than silently launching with another model. It removes all
  old model options before emitting canonical task options.

  The three `select_*` functions return `{:ok, spec}` or `{:error, reason}`.
  Provider/model changes reset downstream defaults; reasoning changes accept
  the component's zero-based range index or an already resolved effort string.
  Core resolution owns schema validation; the component owns slider decoding.
  Models without an advertised effort inventory omit the task-level reasoning
  override, while an inventory without a default starts at its first effort.
  No client input is converted to an atom.
  """

  alias EvoDashWeb.LLMSelectionComponents
  alias EvoGit.Config.Schema

  @type model_spec :: %{optional(String.t()) => String.t()}
  @type bundle :: %{
          config: map(),
          provider_profiles: [map()],
          model_selections: [map()],
          model_selection_enabled: boolean()
        }

  @doc "Builds a node-scoped picker bundle from the core's canonical projections."
  @spec from_config(map(), boolean()) :: bundle()
  def from_config(config, rules_enabled \\ false) do
    %{
      config: config,
      provider_profiles: Schema.provider_profiles(config),
      model_selections: Schema.model_selections(config),
      model_selection_enabled: rules_enabled
    }
  end

  @doc "Restores picker state, replacing stale explicit values with the configured default."
  @spec reconcile(bundle(), term()) :: model_spec()
  def reconcile(bundle, candidate) do
    case resolve(bundle, candidate) do
      {:ok, spec} -> spec
      {:error, _reason} -> default_spec(bundle)
    end
  end

  @doc "Validates a selection and replaces model options, preserving unrelated task options."
  @spec task_opts(bundle() | map(), term(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def task_opts(bundle_or_config, candidate, opts \\ []) do
    bundle = as_bundle(bundle_or_config)

    with {:ok, spec} <- resolve(bundle, candidate) do
      opts = Keyword.drop(opts, [:model_spec, :model_id, :model_id_locked])

      if map_size(spec) == 0 do
        {:ok, opts}
      else
        {:ok, Keyword.merge(opts, model_spec: spec, model_id_locked: true)}
      end
    end
  end

  @doc "Selects a provider's default model and effort; a blank provider explicitly selects Auto."
  @spec select_provider(bundle(), term(), term()) :: {:ok, model_spec()} | {:error, term()}
  def select_provider(_bundle, _current, ""), do: {:ok, %{}}

  def select_provider(bundle, _current, id) when is_binary(id),
    do: resolve(bundle, %{"provider_profile_id" => id})

  def select_provider(_bundle, _current, _id), do: {:error, :invalid_model_spec}

  @doc "Selects a model on the current provider, resetting its reasoning effort to the default."
  @spec select_model(bundle(), term(), term()) :: {:ok, model_spec()} | {:error, term()}
  def select_model(bundle, current, model) when is_binary(model) and model != "" do
    with {:ok, spec} <- explicit_current(bundle, current) do
      resolve(bundle, %{"provider_profile_id" => spec["provider_profile_id"], "model" => model})
    end
  end

  def select_model(_bundle, _current, _model), do: {:error, :invalid_model_spec}

  @doc "Decodes a reasoning slider index (or effort string) for the exact current model."
  @spec select_reasoning_effort(bundle(), term(), term()) ::
          {:ok, model_spec()} | {:error, term()}
  def select_reasoning_effort(bundle, current, index) do
    with {:ok, spec} <- explicit_current(bundle, current),
         {:ok, effort} <-
           LLMSelectionComponents.resolve_reasoning_effort(bundle.model_selections, spec, index) do
      resolve(bundle, Map.put(spec, "reasoning_effort", effort))
    end
  end

  defp as_bundle(%{config: _, provider_profiles: _, model_selections: _} = bundle), do: bundle
  defp as_bundle(config), do: from_config(config)

  defp explicit_current(bundle, current) do
    case resolve(bundle, current) do
      {:ok, spec} when map_size(spec) > 0 -> {:ok, spec}
      {:ok, _auto} -> {:error, :provider_profile_required}
      error -> error
    end
  end

  defp default_spec(bundle) do
    case resolve(bundle, nil) do
      {:ok, spec} -> spec
      {:error, _reason} -> %{}
    end
  end

  defp resolve(_bundle, ""), do: {:ok, %{}}
  defp resolve(_bundle, spec) when is_map(spec) and map_size(spec) == 0, do: {:ok, %{}}

  defp resolve(bundle, candidate)
       when is_nil(candidate) or is_binary(candidate) or is_map(candidate) do
    # Core owns legacy migration, provider/model defaults and validation. Project
    # only picker fields: the remaining resolved runtime data can hold credentials.
    with {:ok, resolved} <- Schema.resolve_model_spec(bundle.config, candidate) do
      {:ok, canonical_spec(resolved)}
    end
  end

  defp resolve(_bundle, _candidate), do: {:error, :invalid_model_spec}

  defp canonical_spec(resolved) do
    spec = %{"provider_profile_id" => resolved.provider_profile_id, "model" => resolved.model}

    case resolved.reasoning_efforts do
      efforts when is_list(efforts) and efforts != [] ->
        # Match the component's initial slider position when core has no default.
        Map.put(spec, "reasoning_effort", resolved.reasoning_effort || List.first(efforts))

      _ ->
        # No slider means no task-level reasoning override, even if the provider
        # has a shared default. Core retains responsibility for runtime defaults.
        spec
    end
  end
end
