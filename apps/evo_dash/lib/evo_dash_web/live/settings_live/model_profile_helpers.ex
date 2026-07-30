defmodule EvoDashWeb.SettingsLive.ModelProfileHelpers do
  @moduledoc """
  Pure data-transformation functions for model profile CRUD operations.

  These helpers operate on the file_config map (before persistence) and are used
  by the SettingsLive LiveView for managing the `[[llm.models]]` profile list.
  """

  alias EvoDash.SettingsUtils
  alias EvoGit.Config.LLMCatalog

  @doc """
  Adds a new model profile to the file_config's `[:llm, :models]` list.

  Generates a unique profile id and creates a profile map with default
  concurrency of 3. When `model_value` is non-nil (e.g. from a shortcut), the
  `:model` key is included; otherwise it is omitted so the user can fill it in.
  """
  def add_model_profile(file_config, model_value) do
    models = get_in(file_config, [:llm, :models]) || []

    # Drop incomplete draft profiles when adding a COMPLETE profile (non-nil).
    # This prevents stale drafts (from the "Add Profile" button) from
    # contaminating subsequent saves (quick setup, shortcut, custom model).
    # Draft creation (nil/empty model_value) preserves existing drafts.
    models =
      if draft_model_value?(model_value) do
        models
      else
        Enum.reject(models, &incomplete_profile?/1)
      end

    id = generate_profile_id(models)
    profile = %{id: id, concurrency: 3} |> maybe_put_profile_model(model_value)
    put_in_model_profiles(file_config, models ++ [profile])
  end

  @doc """
  Generates a unique profile id like `"profile-2"`, `"profile-3"`, ...
  based on the count of existing profiles whose ids match the `"profile-N"` pattern.
  """
  def generate_profile_id(models) do
    existing_ids = Enum.map(models, &profile_id/1) |> MapSet.new()

    Stream.iterate(length(models) + 1, &(&1 + 1))
    |> Stream.map(&"profile-#{&1}")
    |> Enum.find(fn id -> not MapSet.member?(existing_ids, id) end)
  end

  @doc """
  Updates the profile identified by `old_id` in the file_config's model list,
  replacing it with `updated_profile`.
  """
  def update_model_profile(file_config, old_id, updated_profile) do
    models = get_in(file_config, [:llm, :models]) || []

    new_models =
      Enum.map(models, fn profile ->
        if profile_id(profile) == old_id, do: updated_profile, else: profile
      end)

    put_in_model_profiles(file_config, new_models)
  end

  @doc """
  Replaces the entire `[:llm, :models]` list in the file_config with the given
  `models` list.
  """
  def put_in_model_profiles(file_config, models) do
    file_config
    |> ensure_llm_key()
    |> put_in([:llm, :models], models)
  end

  @doc """
  Checks whether `new_id` is already used by a profile OTHER than the one
  being edited (`old_id`). Returns `true` on collision.
  """
  def id_collision?(models, old_id, new_id) do
    Enum.any?(models, fn profile ->
      pid = profile_id(profile)
      pid != old_id and pid == new_id
    end)
  end

  @doc """
  Parses the form params for a single profile into a normalized map with atom
  keys and correctly-typed values.

  Reads the structured model fields `provider`, `model_id`, and `base_url`
  (instead of the flat single `model` string) and composes a ReqLLM-native
  map model spec `%{provider: atom, id: string}` with `base_url` included only
  when provided/non-empty.

  Returns `{:ok, profile_map}` on success, or `{:error, reason_string}` when
  validation fails (model_id required, provider must be a known catalog entry).
  """
  def parse_model_profile_params(params, id) do
    provider_str = String.trim(params["provider"] || "")
    model_id = String.trim(params["model_id"] || "")
    base_url = String.trim(params["base_url"] || "")

    cond do
      model_id == "" ->
        {:error, "model_id_empty"}

      true ->
        # Provider-atom conversion via whitelist Map.get lookup (no try/rescue,
        # no String.to_existing_atom on untrusted input). Unknown provider
        # strings resolve to nil → we keep the provider as a STRING in the spec.
        # The map spec intentionally accepts string providers so the value is
        # preserved verbatim and the schema validator can surface a friendly
        # error rather than silently dropping data.
        provider_atom = provider_atom_from_str(provider_str)

        spec =
          if provider_atom do
            %{provider: provider_atom, id: model_id}
          else
            %{provider: provider_str, id: model_id}
          end

        spec = if base_url == "", do: spec, else: Map.put(spec, :base_url, base_url)

        # Parse extra JSON config
        extra_raw = String.trim(params["extra"] || "")
        spec_result =
          if extra_raw == "" do
            {:ok, spec}
          else
            case Jason.decode(extra_raw) do
              {:ok, extra_map} when is_map(extra_map) ->
                {:ok, Map.put(spec, :extra, extra_map)}
              {:ok, _} ->
                {:error, "extra_must_be_object"}
              {:error, _} ->
                {:error, "invalid_extra_json"}
            end
          end

        # Parse provider_options JSON config (profile-level, sibling of temperature etc.)
        provider_options_raw = String.trim(params["provider_options"] || "")
        provider_options_result =
          if provider_options_raw == "" do
            {:ok, nil}
          else
            case Jason.decode(provider_options_raw) do
              {:ok, po_map} when is_map(po_map) ->
                {:ok, po_map}
              {:ok, _} ->
                {:error, "provider_options_must_be_object"}
              {:error, _} ->
                {:error, "invalid_provider_options_json"}
            end
          end

        case {spec_result, provider_options_result} do
          {{:ok, spec}, {:ok, provider_options}} ->
            profile =
              %{id: id}
              |> Map.put(:model, spec)
              |> maybe_put_int(:concurrency, params["concurrency"], 3)
              |> maybe_put_float(:temperature, params["temperature"])
              |> maybe_put_string(:reasoning_effort, params["reasoning_effort"])
              |> maybe_put_int(:max_tokens, params["max_tokens"])
              |> maybe_put_float(:top_p, params["top_p"])
              |> maybe_put_int(:top_k, params["top_k"])
              |> maybe_put_float(:frequency_penalty, params["frequency_penalty"])
              |> maybe_put_float(:presence_penalty, params["presence_penalty"])
              |> maybe_put_map(:provider_options, provider_options)

            {:ok, profile}

          {{:error, reason}, _} ->
            {:error, reason}

          {_, {:error, reason}} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Conditionally puts an integer value into the map. When parsing fails, uses
  the provided default.
  """
  def maybe_put_int(map, key, raw, default) do
    case SettingsUtils.parse_int(raw) do
      nil -> Map.put(map, key, default)
      int -> Map.put(map, key, int)
    end
  end

  @doc """
  Conditionally puts an integer value into the map. Skips the key when parsing
  fails (no default).
  """
  def maybe_put_int(map, key, raw) do
    case SettingsUtils.parse_int(raw) do
      nil -> map
      int -> Map.put(map, key, int)
    end
  end

  @doc """
  Conditionally puts a float value into the map. Skips the key when parsing fails.
  """
  def maybe_put_float(map, key, raw) do
    case SettingsUtils.parse_float(raw) do
      nil -> map
      float -> Map.put(map, key, float)
    end
  end

  @doc """
  Conditionally puts a string value into the map. Skips the key when the value
  is empty or nil.
  """
  def maybe_put_string(map, _key, ""), do: map
  def maybe_put_string(map, _key, nil), do: map
  def maybe_put_string(map, key, value), do: Map.put(map, key, value)

  @doc """
  Conditionally puts a map value into the map. Skips the key when the value is nil
  or not a map.
  """
  def maybe_put_map(map, _key, nil), do: map
  def maybe_put_map(map, key, map_value) when is_map(map_value), do: Map.put(map, key, map_value)
  def maybe_put_map(map, _key, _), do: map

  @doc """
  Safely reads the id from a profile map whether the key is an atom or string
  (TOML-parsed profiles may arrive with string keys before normalization).
  """
  def profile_id(profile) when is_map(profile) do
    case Map.get(profile, :id) || Map.get(profile, "id") do
      nil -> nil
      id -> to_string(id)
    end
  end

  def profile_id(_), do: nil

  # ───────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ───────────────────────────────────────────────────────────────────────────

  # Converts an untrusted provider id string to a canonical provider atom via a
  # whitelist Map.get lookup built from the LLMCatalog. Returns nil for unknown
  # providers (callers keep the string verbatim so the schema can surface a
  # friendly error). Mirrors ConfigIO.provider_by_id_str/0. We map to the full
  # struct and use hd/1 on its provider_atoms to get the canonical atom usable
  # in model specs (e.g. the :openai_compatible entry has provider_atoms
  # [:openai] → resolves to :openai). Using resolve_provider_atom/1 would look
  # up by membership and leave :openai_compatible unchanged (the bug).
  defp provider_atom_from_str(provider_str) when is_binary(provider_str) do
    provider_by_id = Map.new(LLMCatalog.providers(), fn p -> {Atom.to_string(p.id), p} end)

    case Map.get(provider_by_id, provider_str) do
      nil -> nil
      entry -> hd(entry.provider_atoms)
    end
  end

  # Only include :model key when a non-nil value is given (e.g. from a shortcut).
  # For "add_model_profile" with nil, we omit it so the user can fill it in.
  defp maybe_put_profile_model(profile, nil), do: profile
  defp maybe_put_profile_model(profile, ""), do: profile
  defp maybe_put_profile_model(profile, model_value), do: Map.put(profile, :model, model_value)

  defp draft_model_value?(nil), do: true
  defp draft_model_value?(""), do: true
  defp draft_model_value?(_), do: false

  defp incomplete_profile?(profile) when is_map(profile) do
    case Map.get(profile, :model) do
      nil -> true
      "" -> true
      _ -> false
    end
  end

  defp incomplete_profile?(_), do: true

  defp ensure_llm_key(file_config) do
    if is_map(get_in(file_config, [:llm])) do
      file_config
    else
      put_in(file_config, [:llm], %{})
    end
  end
end
