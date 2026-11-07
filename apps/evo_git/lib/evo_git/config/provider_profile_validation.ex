defmodule EvoGit.Config.ProviderProfileValidation do
  @moduledoc false

  alias EvoGit.Config.EctoValidation
  alias EvoGit.Config.Schema
  alias EvoGit.Config.Schema.Definitions
  alias EvoGit.Config.Schema.ProviderProfiles.Normalize
  alias EvoGit.Config.Schema.ValidationError

  # Validate raw input, not normalized profiles: normalization deliberately
  # drops malformed entries and supplies defaults, hiding configuration errors.
  def errors(path, profiles) when is_list(profiles) do
    profiles
    |> Enum.with_index()
    |> Enum.flat_map(fn {profile, index} -> profile_errors(path ++ [index], profile) end)
    |> Kernel.++(duplicate_errors(path, profiles, "id", :id))
  end

  def errors(path, value) do
    [
      error(
        path,
        "must be a list of provider profiles, got #{inspect(value)}",
        value,
        :provider_profiles
      )
    ]
  end

  # Only canonical inventories constrain this selector here; legacy-only config
  # retains its existing validation contract. Scalar type errors belong to EctoValidation.
  def cross_field_errors(config) do
    profiles = Schema.safe_get_in(config, [:llm, :providers])
    selector = Schema.safe_get_in(config, [:llm, :default_provider_profile])

    if is_list(profiles) and profiles != [] and is_binary(selector) do
      ids =
        Enum.flat_map(profiles, fn
          %{} = profile ->
            id = string_keys(profile)["id"]
            if nonblank?(id), do: [id], else: []

          _ ->
            []
        end)

      membership_errors(
        [:llm, :default_provider_profile],
        selector,
        ids,
        "default_provider_profile",
        selector
      )
    else
      []
    end
  end

  defp profile_errors(path, %{} = raw) do
    profile = string_keys(raw)
    provider = Normalize.provider_name(profile["provider"])
    models = profile["models"]

    required_string(path, profile, "id") ++
      provider_errors(path, profile["provider"]) ++
      optional_string(path, profile, "name") ++
      Enum.flat_map(["api_key_env_var", "base_url"], &optional_string(path, profile, &1)) ++
      concurrency_errors(path, profile) ++
      EctoValidation.provider_profile_shared_errors(path, profile) ++
      map_errors(path, profile, "extra") ++
      generation_errors(path, profile) ++
      effort_errors(path, profile, %{}) ++
      models_errors(path ++ [:models], models, profile, provider) ++
      default_model_errors(path, profile, models, provider)
  end

  defp profile_errors(path, value) do
    [
      error(
        path,
        "provider profile must be a map/table, got #{inspect(value)}",
        value,
        :provider_profiles
      )
    ]
  end

  defp provider_errors(path, value) do
    if nonblank?(Normalize.provider_name(value)) and value not in [true, false] do
      []
    else
      [
        error(
          path ++ [:provider],
          "provider must be a non-empty provider name, got #{inspect(value)}",
          value,
          :string
        )
      ]
    end
  end

  defp concurrency_errors(path, profile) do
    case profile["concurrency"] do
      nil -> []
      value -> EctoValidation.errors_for(path ++ [:concurrency], :pos_integer, [], value)
    end
  end

  defp models_errors(path, models, profile, provider) when is_list(models) do
    entries = Enum.map(models, &model_map(&1, provider))

    errors =
      models
      |> Enum.with_index()
      |> Enum.flat_map(fn {model, index} ->
        model_errors(path ++ [index], model, profile, provider)
      end)

    errors ++ duplicate_errors(path, entries, "model", :model)
  end

  defp models_errors(path, value, _profile, _provider) do
    [
      error(
        path,
        "models must be a list of model names or tables, got #{inspect(value)}",
        value,
        :models
      )
    ]
  end

  defp model_errors(path, model, profile, provider) when is_binary(model) or is_map(model) do
    model = model_map(model, provider)

    required_string(path, model, "model") ++
      EctoValidation.provider_profile_shared_errors(path, Map.take(model, ["context_window"])) ++
      generation_errors(path, model) ++ effort_errors(path, model, profile)
  end

  defp model_errors(path, value, _profile, _provider) do
    [
      error(
        path,
        "model must be a non-empty string or map/table, got #{inspect(value)}",
        value,
        :model
      )
    ]
  end

  defp model_map(model, provider) when is_binary(model),
    do: %{"model" => unqualify(model, provider)}

  defp model_map(%{} = model, provider) do
    model = string_keys(model)
    Map.put(model, "model", unqualify(Map.get(model, "model", model["id"]), provider))
  end

  defp model_map(_, _), do: %{}

  defp unqualify(model, provider) when is_binary(model) and is_binary(provider),
    do: Normalize.unqualify(model, provider)

  defp unqualify(model, _provider), do: model

  defp default_model_errors(path, profile, models, provider) do
    case profile["default_model"] do
      nil ->
        []

      value ->
        ids =
          if is_list(models), do: Enum.map(models, &model_map(&1, provider)["model"]), else: []

        membership_errors(
          path ++ [:default_model],
          value,
          ids,
          "default_model",
          unqualify(value, provider)
        )
    end
  end

  defp effort_errors(path, fields, inherited) do
    inventory = Map.get(fields, "reasoning_efforts", inherited["reasoning_efforts"])
    own_inventory = fields["reasoning_efforts"]

    inventory_errors =
      cond do
        is_nil(own_inventory) ->
          []

        is_list(own_inventory) and Enum.all?(own_inventory, &nonblank?/1) ->
          duplicate_values(path ++ [:reasoning_efforts], own_inventory)

        true ->
          [
            error(
              path ++ [:reasoning_efforts],
              "reasoning_efforts must be an ordered list of non-empty strings, got #{inspect(own_inventory)}",
              own_inventory,
              :list_of_strings
            )
          ]
      end

    defaults =
      Enum.flat_map([:default_reasoning_effort, :reasoning_effort], fn key ->
        case fields[Atom.to_string(key)] do
          nil -> []
          value -> effort_default_errors(path ++ [key], value, inventory)
        end
      end)

    # A model-specific inventory also constrains the inherited provider default.
    # A model default/override takes precedence exactly as in the resolver.
    inherited_default = inherited["default_reasoning_effort"] || inherited["reasoning_effort"]

    inherited_errors =
      if is_nil(fields["default_reasoning_effort"]) and is_nil(fields["reasoning_effort"]) and
           not is_nil(inherited_default) do
        effort_default_errors(path ++ [:default_reasoning_effort], inherited_default, inventory)
      else
        []
      end

    inventory_errors ++ defaults ++ inherited_errors
  end

  defp effort_default_errors(path, value, inventory) do
    if is_list(inventory) and inventory != [] do
      membership_errors(path, value, inventory, "reasoning effort", value)
    else
      if nonblank?(value), do: [], else: [string_error(path, "reasoning effort", value)]
    end
  end

  defp membership_errors(path, value, allowed, label, normalized) do
    cond do
      not nonblank?(value) ->
        [string_error(path, label, value)]

      normalized in allowed ->
        []

      true ->
        [
          error(
            path,
            "#{label} must be one of #{inspect(allowed)}, got #{inspect(value)}",
            value,
            {:in, allowed}
          )
        ]
    end
  end

  defp generation_errors(path, fields) do
    # Keep scalar ranges in the schema's existing descriptors, rather than
    # maintaining another temperature/token/penalty constraint table.
    scalar_keys = Normalize.generation_keys() -- ["reasoning_effort", "provider_options"]

    scalar_errors =
      Definitions.schemas()
      |> Enum.flat_map(fn descriptor ->
        case descriptor.key_path do
          [:llm, key] ->
            name = Atom.to_string(key)
            value = fields[name]

            if name in scalar_keys and not is_nil(value),
              do:
                EctoValidation.errors_for(
                  path ++ [key],
                  descriptor.type,
                  descriptor.validation,
                  value
                ),
              else: []

          _ ->
            []
        end
      end)

    scalar_errors ++ map_errors(path, fields, "provider_options")
  end

  defp map_errors(path, fields, key) do
    case fields[key] do
      nil ->
        []

      %{} ->
        []

      value ->
        [
          error(
            path ++ [field_key(key)],
            "#{key} must be a map, got #{inspect(value)}",
            value,
            :map
          )
        ]
    end
  end

  defp required_string(path, fields, key) do
    value = fields[key]
    if nonblank?(value), do: [], else: [string_error(path ++ [field_key(key)], key, value)]
  end

  defp optional_string(path, fields, key) do
    if is_nil(fields[key]), do: [], else: required_string(path, fields, key)
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp string_error(path, label, value),
    do: error(path, "#{label} must be a non-empty string, got #{inspect(value)}", value, :string)

  defp duplicate_errors(path, entries, key, path_key) do
    entries
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), []}, fn {entry, index}, {seen, errors} ->
      value = if is_map(entry), do: Map.get(entry, key, Map.get(entry, path_key)), else: nil

      if nonblank?(value) and MapSet.member?(seen, value) do
        {seen,
         [
           error(path ++ [index, path_key], "duplicate #{key}: #{inspect(value)}", value, :unique)
           | errors
         ]}
      else
        {MapSet.put(seen, value), errors}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp duplicate_values(path, values) do
    values
    |> Enum.map(&%{"value" => &1})
    |> then(&duplicate_errors(path, &1, "value", :value))
    |> Enum.map(fn error -> %{error | key_path: Enum.drop(error.key_path, -1)} end)
  end

  # Only normalize the keys at the level being validated. Recursing through
  # arbitrary option values would disguise malformed lists as maps and can
  # invoke Enumerable on a struct supplied by a programmatic caller.
  defp string_keys(map) do
    Map.new(Map.to_list(map), fn {key, value} ->
      {if(is_atom(key), do: Atom.to_string(key), else: key), value}
    end)
  end

  # This is a closed field vocabulary; never intern atoms from user input.
  defp field_key("id"), do: :id
  defp field_key("model"), do: :model
  defp field_key("name"), do: :name
  defp field_key("api_key_env_var"), do: :api_key_env_var
  defp field_key("base_url"), do: :base_url
  defp field_key("extra"), do: :extra
  defp field_key("provider_options"), do: :provider_options

  defp error(path, message, value, rule),
    do: %ValidationError{key_path: path, message: message, value: value, rule: rule}
end
