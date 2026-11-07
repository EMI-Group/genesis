defmodule EvoDashWeb.SettingsLive.ProviderProfiles do
  @moduledoc """
  Pure canonical provider-profile editor boundary.

  `profiles/1` delegates legacy migration to the core, never reimplements it.
  Profiles and drafts have string keys; config containers use atom keys.
  Drafts are detached from file_config until Save.
  """
  alias EvoDash.SettingsUtils
  alias EvoDashWeb.SettingsLive.ModelProfileHelpers, as: Helpers
  alias EvoGit.Config.{LLMCatalog, Schema}

  @integer_fields ~w(concurrency context_window max_tokens top_k)
  @float_fields ~w(temperature top_p frequency_penalty presence_penalty)
  @string_fields ~w(name base_url api_key api_key_env_var oauth_file default_model)
  @json_fields ~w(extra provider_options)
  @generation_fields ~w(temperature max_tokens top_p top_k frequency_penalty presence_penalty)

  def profiles(config), do: Schema.provider_profiles(config)

  @doc "Replaces providers, removes the legacy shadow, and keeps unrelated config."
  def put_profiles(config, profiles) do
    llm = field(config, "llm") || %{}
    default = field(llm, "default_provider_profile")
    ids = Enum.map(profiles, &field(&1, "id"))
    default = if default in ids, do: default, else: List.first(ids)

    llm =
      llm
      |> Map.drop([:models, "models", :providers, "providers", :default_provider_profile])
      |> Map.put(:providers, profiles)
      |> Map.delete("default_provider_profile")
      |> put_optional(:default_provider_profile, default)

    config |> Map.drop([:llm, "llm"]) |> Map.put(:llm, llm)
  end

  def update(config, old_id, profile) do
    existing = profiles(config)
    found? = Enum.any?(existing, &(field(&1, "id") == old_id))
    updated = Enum.map(existing, &if(field(&1, "id") == old_id, do: profile, else: &1))
    updated = if found?, do: updated, else: updated ++ [profile]
    default = field(field(config, "llm") || %{}, "default_provider_profile")
    config = put_profiles(config, updated)
    # Adding to legacy config with no explicit default must keep the first
    # migrated account selected, not treat nil == nil as a default rename.
    if found? and default == old_id,
      do: set_default(config, field(profile, "id")),
      else: config
  end

  def delete(config, id),
    do: put_profiles(config, Enum.reject(profiles(config), &(field(&1, "id") == id)))

  def set_default(config, id) do
    if Enum.any?(profiles(config), &(field(&1, "id") == id)) do
      config = put_profiles(config, profiles(config))
      Map.update!(config, :llm, &Map.put(&1, :default_provider_profile, id))
    else
      config
    end
  end

  def move(config, id, direction) do
    list = profiles(config)
    index = Enum.find_index(list, &(field(&1, "id") == id))
    offset = Map.get(%{"up" => -1, "down" => 1}, direction)
    target = if is_integer(index) and is_integer(offset), do: index + offset

    if is_integer(target) and target >= 0 and target < length(list) do
      a = Enum.at(list, index)
      b = Enum.at(list, target)
      put_profiles(config, list |> List.replace_at(index, b) |> List.replace_at(target, a))
    else
      config
    end
  end

  @doc "Creates an unsaved blank provider draft; no incomplete profile enters config."
  def new_draft(config) do
    %{
      "id" => Helpers.generate_profile_id(profiles(config)),
      "name" => "",
      "provider" => "",
      "auth_mode" => "api_key",
      "concurrency" => 3,
      "default_model" => "",
      "models" => [],
      "peak_hours" => []
    }
  end

  @doc "Editable snapshot, including JSON text fields and all nested model overrides."
  def draft(profile) do
    profile
    |> stringify()
    |> canonical_credentials()
    |> json_draft()
    |> Map.update("models", [], fn models -> Enum.map(rows(models), &json_draft/1) end)
  end

  def normalize_draft(params) do
    params
    |> stringify()
    |> canonical_credentials()
    |> Map.update("models", [], &rows/1)
    |> Map.update("peak_hours", [], &Helpers.normalize_peak_hours_draft/1)
    |> Map.update("off_peak_days", [], &Helpers.normalize_days/1)
  end

  @doc "Keeps explicitly emptied draft collections when HTML omits their inputs."
  def submission(params, draft) do
    keys =
      if Map.has_key?(params, "model_id"),
        do: ~w(peak_hours off_peak_days),
        else: ~w(models peak_hours off_peak_days)

    Map.merge(Map.take(draft || %{}, keys), params)
  end

  @doc "Parses canonical forms, or the old single-model form, into a provider map."
  def parse(params, id, original \\ %{}) do
    case parse_editor(params, id, original) do
      {:error, errors} -> {:error, errors |> Map.values() |> hd()}
      result -> result
    end
  end

  @doc "Editor parser returning string input names mapped to stable error reasons."
  def parse_editor(params, id, original \\ %{}) do
    params = params |> stringify() |> canonical_credentials() |> legacy_params()
    params = Map.merge(draft(original), params)
    provider = text(params["provider"])
    provider_atom = provider_atom(provider)
    provider = if provider_atom, do: Atom.to_string(provider_atom), else: provider

    auth_mode =
      if LLMCatalog.oauth_only?(provider_atom),
        do: "oauth",
        else: text(params["auth_mode"] || "api_key")

    with :ok <- required(provider != "", "provider_empty"),
         :ok <- required(auth_mode in ["api_key", "oauth"], "auth_mode_invalid"),
         :ok <-
           required(
             auth_mode != "oauth" or LLMCatalog.supports_oauth?(provider_atom),
             "auth_mode_invalid"
           ),
         {:ok, profile} <-
           parse_values(
             params,
             Map.merge(canonical_credentials(stringify(original)), %{
               "id" => id,
               "provider" => provider,
               "auth_mode" => auth_mode
             })
           ),
         {:ok, peak} <- parse_peak(params),
         {:ok, models} <- parse_models(params["models"]),
         {:ok, profile} <- reasoning(profile, params) do
      profile =
        profile
        |> Map.drop(~w(peak_concurrency peak_hours timezone off_peak_days model reasoning_effort))
        |> Map.merge(stringify(peak))
        |> Map.put("name", nonblank(params["name"]) || id)
        |> Map.delete("models")
        |> put_optional("models", if(models != [], do: models))

      profile =
        if auth_mode == "oauth",
          do: Map.drop(profile, ~w(api_key api_key_env api_key_env_var)),
          else: Map.delete(profile, "oauth_file")

      default = nonblank(profile["default_model"]) || (List.first(models) || %{})["model"]
      profile = put_optional(profile, "default_model", default)

      # Nested models are optional overrides, not a saved-model allowlist.
      # A default-only account must remain default-only after an untouched save.
      with :ok <- required(not is_nil(default), "default_model_invalid"),
           :ok <- validate_inherited_reasoning(profile, models, params["models"]) do
        {:ok, profile}
      end
    end
  end

  def add_model(config, model_value) do
    {provider, model, overrides} = split_model(model_value)
    id = Helpers.generate_profile_id(profiles(config), slug(model))

    params =
      Map.merge(overrides, %{
        "provider" => provider,
        "name" => id,
        "models" => [%{"model" => model}],
        "concurrency" => "3"
      })

    with {:ok, profile} <- parse(params, id), do: {:ok, update(config, nil, profile)}
  end

  defp parse_values(params, base) do
    Enum.reduce_while(
      @integer_fields ++ @float_fields ++ @string_fields ++ @json_fields,
      {:ok, base},
      fn key, {:ok, acc} ->
        case parse_value(key, params[key]) do
          {:ok, nil} -> {:cont, {:ok, Map.delete(acc, key)}}
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          {:error, reason} -> {:halt, field_error(input_name(key), reason)}
        end
      end
    )
  end

  defp parse_value(key, raw) when key in @integer_fields or key in @float_fields do
    cond do
      is_nil(raw) or raw == "" ->
        {:ok, if(key == "concurrency", do: 3)}

      true ->
        value =
          cond do
            key in @integer_fields and is_integer(raw) -> raw
            key in @float_fields and is_number(raw) -> raw
            key in @integer_fields -> SettingsUtils.parse_int(raw)
            true -> SettingsUtils.parse_float(raw)
          end

        if is_nil(value), do: {:error, "numeric_invalid"}, else: {:ok, value}
    end
  end

  defp parse_value(key, raw) when key in @json_fields do
    cond do
      is_map(raw) ->
        {:ok, stringify(raw)}

      is_nil(raw) or raw == "" ->
        {:ok, nil}

      is_binary(raw) ->
        case Jason.decode(raw) do
          {:ok, value} when is_map(value) -> {:ok, value}
          {:ok, _} -> {:error, "#{key}_must_be_object"}
          {:error, _} -> {:error, "invalid_#{key}_json"}
        end

      true ->
        {:error, "invalid_#{key}_json"}
    end
  end

  defp parse_value(_key, raw), do: {:ok, nonblank(raw)}

  defp parse_models(raw) do
    values =
      cond do
        is_list(raw) -> raw
        is_map(raw) -> Map.values(raw)
        is_nil(raw) -> []
        true -> [raw]
      end

    with :ok <- required(Enum.all?(values, &is_map/1), "models_invalid") do
      parse_model_rows(raw)
    end
  end

  defp parse_model_rows(raw) do
    Enum.reduce_while(Enum.with_index(rows(raw)), {:ok, []}, fn {row, index}, {:ok, acc} ->
      model = nonblank(row["model"] || row["model_id"])

      cond do
        blank_model_row?(row) ->
          {:cont, {:ok, acc}}

        is_nil(model) ->
          {:halt, model_error(index, "model", "model_id_empty")}

        Enum.any?(acc, &(&1["model"] == model)) ->
          {:halt, model_error(index, "model", "duplicate_model")}

        true ->
          with {:ok, parsed} <- parse_values(Map.put(row, "concurrency", ""), %{"model" => model}),
               {:ok, parsed} <- reasoning(parsed, row) do
            parsed =
              Map.take(
                parsed,
                [
                  "model",
                  "context_window",
                  "reasoning_efforts",
                  "default_reasoning_effort",
                  "extra",
                  "provider_options"
                ] ++ @generation_fields
              )

            {:cont, {:ok, acc ++ [parsed]}}
          else
            {:error, errors} -> {:halt, prefix_model_errors(index, errors)}
          end
      end
    end)
  end

  defp reasoning(profile, params) do
    efforts = string_list(params["reasoning_efforts"])
    default = nonblank(params["default_reasoning_effort"])

    if default && efforts != [] && default not in efforts do
      field_error("default_reasoning_effort", "reasoning_default_invalid")
    else
      {:ok,
       profile
       |> Map.drop(~w(reasoning_efforts default_reasoning_effort))
       |> put_optional(
         "reasoning_efforts",
         if(Map.has_key?(params, "reasoning_efforts"), do: efforts)
       )
       |> put_optional("default_reasoning_effort", default)}
    end
  end

  defp blank_model_row?(row) do
    is_nil(nonblank(row["model"] || row["model_id"])) and
      Enum.all?(Map.values(row), &(&1 in [nil, "", []]))
  end

  defp validate_inherited_reasoning(profile, models, raw) do
    indices =
      raw
      |> rows()
      |> Enum.with_index()
      |> Enum.reject(fn {row, _} -> blank_model_row?(row) end)
      |> Enum.map(&elem(&1, 1))

    Enum.reduce_while([{profile, nil} | Enum.zip(models, indices)], :ok, fn {row, index}, :ok ->
      efforts = Map.get(row, "reasoning_efforts", profile["reasoning_efforts"] || [])
      default = Map.get(row, "default_reasoning_effort", profile["default_reasoning_effort"])

      if is_nil(default) or efforts == [] or default in efforts do
        {:cont, :ok}
      else
        result = field_error("default_reasoning_effort", "reasoning_default_invalid")
        result = if is_nil(index), do: result, else: prefix_model_errors(index, elem(result, 1))
        {:halt, result}
      end
    end)
  end

  def string_list(value) when is_binary(value),
    do: value |> String.split([",", "\n"], trim: true) |> string_list()

  def string_list(value) when is_list(value),
    do: value |> Enum.map(&nonblank/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  def string_list(_), do: []

  def rows(value) when is_list(value), do: Enum.filter(value, &is_map/1) |> Enum.map(&stringify/1)

  def rows(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _} ->
      case Integer.parse(to_string(key)) do
        {n, ""} -> n
        _ -> -1
      end
    end)
    |> Enum.map(&elem(&1, 1))
    |> rows()
  end

  def rows(_), do: []

  def field(map, key) when is_map(map) do
    Enum.find_value(map, fn {k, value} -> if to_string(k) == key, do: {:found, value} end)
    |> case do
      {:found, value} -> value
      nil -> nil
    end
  end

  def field(_, _), do: nil

  # Key presence matters: an explicitly blank canonical input clears a saved value.
  defp canonical_credentials(profile) do
    case Map.fetch(profile, "api_key_env") do
      :error ->
        profile

      {:ok, legacy} ->
        profile |> Map.delete("api_key_env") |> Map.put_new("api_key_env_var", legacy)
    end
  end

  defp legacy_params(%{"model_id" => model} = params) do
    params
    |> Map.put_new("models", [%{"model" => model, "context_window" => params["context_window"]}])
    |> Map.put_new("default_model", model)
    |> Map.put_new("default_reasoning_effort", params["reasoning_effort"])
  end

  defp legacy_params(params), do: params

  defp split_model(value) when is_map(value) do
    {text(field(value, "provider")), text(field(value, "id")),
     Map.drop(stringify(value), ~w(provider id))}
  end

  defp split_model(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [provider, model] -> {provider, model, %{}}
      [model] -> {"", model, %{}}
    end
  end

  defp json_draft(profile) do
    Enum.reduce(@json_fields, profile, fn key, acc ->
      case acc[key] do
        value when is_map(value) -> Map.put(acc, key, Jason.encode!(value))
        _ -> acc
      end
    end)
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
  defp required(true, _), do: :ok

  defp required(false, reason) do
    key =
      case reason do
        "provider_empty" -> "provider"
        "auth_mode_invalid" -> "auth_mode"
        "models_invalid" -> "models"
        "default_model_invalid" -> "default_model"
      end

    field_error(key, reason)
  end

  defp field_error(key, reason), do: {:error, %{key => reason}}

  defp input_name(key) when key in @generation_fields or key in @json_fields,
    do: "generation[#{key}]"

  defp input_name(key), do: key

  defp model_error(index, key, reason),
    do: prefix_model_errors(index, %{key => reason})

  defp prefix_model_errors(index, errors) do
    {:error,
     Map.new(errors, fn {key, reason} ->
       suffix = key |> String.split(["[", "]"], trim: true) |> Enum.map_join(&"[#{&1}]")
       {"models[#{index}]" <> suffix, reason}
     end)}
  end

  defp parse_peak(params) do
    case Helpers.parse_peak_fields(params) do
      {:error, "peak_concurrency_invalid" = reason} -> field_error("peak_concurrency", reason)
      {:error, reason} -> field_error("peak_hours", reason)
      result -> result
    end
  end

  defp text(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_), do: ""

  defp nonblank(value) do
    case text(value) do
      "" -> nil
      value -> value
    end
  end

  defp slug(value),
    do: value |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

  @doc "Catalog whitelist lookup; never creates atoms from editor input."
  def provider_atom(provider) do
    provider = text(provider)

    Enum.find_value(LLMCatalog.providers(), fn entry ->
      cond do
        to_string(entry.id) == provider -> List.first(entry.provider_atoms)
        true -> Enum.find(entry.provider_atoms, &(to_string(&1) == provider))
      end
    end)
  end
end
