defmodule EvoGit.AgentScheduler.ModelSelection do
  @moduledoc """
  Scheduler adapter for configuration model selections and provider/account pools.

  Configuration owns validation and request-parameter assembly; this module keeps
  the resolved configuration snapshot together so dispatch never re-reads disk.
  Legacy scheduler fixtures remain usable without the provider-profile schema.
  """

  alias EvoGit.AgentScheduler.State
  alias EvoGit.Config.Schema

  @doc "Returns the model configuration options shared by boot and reload."
  def config_opts(config) do
    if schema_available?() do
      [
        model_profiles: apply(Schema, :model_selections, [config]),
        provider_profiles: apply(Schema, :provider_profiles, [config]),
        model_selection_config: config
      ]
    else
      [model_profiles: Schema.effective_model_profiles(config)]
    end
  end

  @doc "Reads a known atom/string configuration key without creating atoms."
  def value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  @doc "Returns the resource-pool identity, distinct from a legacy selection id."
  def pool_id(profile) do
    selection = value(profile, :model_spec, profile)

    value(selection, :provider_profile_id) || value(profile, :provider_profile_id) ||
      value(profile, :id, "default")
  end

  @doc "Finds an explicit task selection, including options from older AgentSpec structs."
  def explicit_spec(spec) do
    case Map.get(spec, :model_spec) do
      nil -> Keyword.fetch(spec.opts, :model_spec)
      selection -> {:ok, selection}
    end
  end

  @doc "Copies a locked parent's entire selection, not merely its legacy id."
  def inherit(spec, %{model_id_locked: true, model_spec: selection} = parent)
      when is_map(selection) do
    opts = spec.opts |> Keyword.put(:model_spec, selection) |> Keyword.put(:model_id_locked, true)
    spec = %{spec | model_id: parent.model_id, opts: opts}
    if Map.has_key?(spec, :model_spec), do: Map.put(spec, :model_spec, selection), else: spec
  end

  def inherit(spec, %{model_id_locked: true} = parent) do
    %{spec | model_id: parent.model_id, opts: Keyword.put(spec.opts, :model_id_locked, true)}
  end

  def inherit(spec, _parent), do: spec

  @doc "Validates the task wire shape before schema resolution (nil is not a default here)."
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
  def resolve(%State{} = state, requested) do
    if schema_available?() and is_map(state.model_selection_config) do
      case apply(Schema, :resolve_model_spec, [state.model_selection_config, requested]) do
        {:ok, resolved} ->
          selection = normalize(state, requested, resolved)

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

  defp normalize(state, requested, resolved) do
    selection = value(resolved, :model_spec, resolved)
    provider_id = value(selection, :provider_profile_id) || value(resolved, :provider_profile_id)
    model = value(selection, :model) || value(resolved, :model)
    effort = value(selection, :reasoning_effort)
    model_spec = %{"provider_profile_id" => provider_id, "model" => model}

    model_spec =
      if is_nil(effort), do: model_spec, else: Map.put(model_spec, "reasoning_effort", effort)

    profile =
      if requested in [nil, ""],
        do: List.first(state.model_profiles) || %{},
        else: Enum.find(state.model_profiles, &(value(&1, :id) == requested)) || %{}

    %{
      model_id: value(resolved, :model_id) || value(resolved, :id) || value(profile, :id),
      provider_profile_id: provider_id,
      model_spec: model_spec,
      llm_model: value(resolved, :llm_model, value(resolved, :model)),
      llm_generation_params:
        value(
          resolved,
          :llm_generation_params,
          value(resolved, :generation_params, value(resolved, :params, []))
        ),
      llm_context_window: value(resolved, :context_window, Schema.LLM.context_window(profile))
    }
  end

  defp schema_available? do
    Code.ensure_loaded?(Schema) and function_exported?(Schema, :provider_profiles, 1) and
      function_exported?(Schema, :model_selections, 1) and
      function_exported?(Schema, :resolve_model_spec, 2)
  end
end
