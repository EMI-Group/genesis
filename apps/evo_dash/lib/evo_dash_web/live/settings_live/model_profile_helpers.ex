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

    id = generate_profile_id(models, base_name_from_model_value(model_value))
    profile = %{id: id, concurrency: 3} |> maybe_put_profile_model(model_value)
    put_in_model_profiles(file_config, models ++ [profile])
  end

  @doc """
  Generates a unique profile id like `"profile-2"`, `"profile-3"`, ...
  based on the count of existing profiles whose ids match the `"profile-N"` pattern.
  """
  def generate_profile_id(models) do
    generate_profile_id(models, nil)
  end

  @doc """
  Generates a unique profile id from a base name: `<base>`, `<base>-2`,
  `<base>-3`, ... (numeric suffix starting at 2), skipping any ids already
  present in `models`. When `base_name` is nil or empty, falls back to the
  `"profile-N"` scheme based on the count of existing profiles.
  """
  def generate_profile_id(models, base_name) do
    existing_ids = Enum.map(models, &profile_id/1) |> MapSet.new()

    if base_name == "" or is_nil(base_name) do
      Stream.iterate(length(models) + 1, &(&1 + 1))
      |> Stream.map(&"profile-#{&1}")
      |> Enum.find(fn id -> not MapSet.member?(existing_ids, id) end)
    else
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(fn
        1 -> base_name
        n -> "#{base_name}-#{n}"
      end)
      |> Enum.find(fn id -> not MapSet.member?(existing_ids, id) end)
    end
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
  Moves the profile identified by `id` up or down in the file_config's
  `[:llm, :models]` list.

  `direction` is `"up"` (swap with the previous element) or `"down"` (swap
  with the next element). The id comparison uses `profile_id/1` string
  semantics, so atom- or string-keyed profiles both match.

  Returns the file_config with the list UNCHANGED (never crashes, never
  raises) for boundary/edge cases: unknown id, invalid/missing direction,
  empty list, already-first + "up", already-last + "down".
  """
  def move_model_profile(file_config, id, direction) do
    models = get_in(file_config, [:llm, :models]) || []

    new_models =
      case Enum.find_index(models, fn profile -> profile_id(profile) == id end) do
        nil ->
          models

        idx ->
          swap_idx =
            case direction do
              "up" -> idx - 1
              "down" -> idx + 1
              _ -> nil
            end

          if is_integer(swap_idx) and swap_idx >= 0 and swap_idx < length(models) do
            swap_elements(models, idx, swap_idx)
          else
            models
          end
      end

    put_in_model_profiles(file_config, new_models)
  end

  @doc """
  Parses the form params for a single profile into a normalized map with atom
  keys and correctly-typed values.

  Reads the structured model fields `provider`, `model_id`, and `base_url`
  (instead of the flat single `model` string) and produces the `:model` value
  in one of two formats:

  - Compact STRING form `"provider:model_id"` (or just `model_id` when the
    provider is empty) when there are no genuine overrides — no `base_url`
    and no `extra` JSON. This is the default stored format for profiles saved
    without overrides.
  - ReqLLM-native MAP spec `%{provider: atom, id: string}` (+ `:base_url`
    and/or `:extra`) when a custom `base_url` or `extra` JSON override is
    present.

  Returns `{:ok, profile_map}` on success, or `{:error, reason_string}` when
  validation fails (model_id required, invalid extra/provider_options JSON).
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
        extra_present? = extra_raw != ""

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

        # Parse the optional peak/off-peak concurrency fields (peak_concurrency
        # + peak_hours). Both keys stay ABSENT from the profile when disabled,
        # so TOML serialization omits them (never nil/empty values).
        peak_result = parse_peak_fields(params)

        case {spec_result, provider_options_result, peak_result} do
          {{:ok, final_spec}, {:ok, provider_options}, {:ok, peak_fields}} ->
            # Determine the final :model value. When there are no genuine
            # overrides (no base_url, no extra JSON) store the compact STRING
            # form `"provider:model_id"` (or just `model_id` for an empty
            # provider). Otherwise keep the ReqLLM-native map spec (`final_spec`
            # carries :extra when present). provider_options is a profile-level
            # field (sibling of temperature) and never forces the map form.
            model_value =
              if base_url == "" and not extra_present? do
                if provider_str == "", do: model_id, else: "#{provider_str}:#{model_id}"
              else
                final_spec
              end

            profile =
              %{id: id}
              |> Map.put(:model, model_value)
              |> maybe_put_int(:concurrency, params["concurrency"], 3)
              |> maybe_put_float(:temperature, params["temperature"])
              |> maybe_put_string(:reasoning_effort, params["reasoning_effort"])
              |> maybe_put_int(:max_tokens, params["max_tokens"])
              |> maybe_put_float(:top_p, params["top_p"])
              |> maybe_put_int(:top_k, params["top_k"])
              |> maybe_put_float(:frequency_penalty, params["frequency_penalty"])
              |> maybe_put_float(:presence_penalty, params["presence_penalty"])
              |> maybe_put_map(:provider_options, provider_options)
              # peak_fields is %{} when disabled, else carries :peak_concurrency
              # and/or :peak_hours (absent keys → TOML omits them).
              |> Map.merge(peak_fields)

            {:ok, profile}

          {{:error, reason}, _, _} ->
            {:error, reason}

          {_, {:error, reason}, _} ->
            {:error, reason}

          {_, _, {:error, reason}} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Parses the optional peak/off-peak concurrency form fields into atom-keyed
  profile fields.

  Reads `params["peak_concurrency"]` (plain number string) and
  `params["peak_hours"]` (Phoenix-nested map keyed by string index, a list, or
  absent). Returns `{:ok, %{}}` when both fields are disabled/absent (keys must
  stay ABSENT from the profile so TOML omits them), `{:ok, %{peak_concurrency:
  int, peak_hours: [%{start: "HH:MM", end: "HH:MM"}]}}` on success, or
  `{:error, reason}` with one of the four peak error strings:
  `"peak_concurrency_invalid"`, `"peak_hours_invalid_time"`,
  `"peak_hours_start_equals_end"`, `"peak_hours_overlap"`.
  """
  def parse_peak_fields(params) do
    with {:ok, concurrency} <- parse_peak_concurrency(params["peak_concurrency"]),
         {:ok, hours} <- parse_peak_hours(params["peak_hours"]) do
      fields =
        if is_nil(concurrency), do: %{}, else: %{peak_concurrency: concurrency}

      fields =
        if is_nil(hours), do: fields, else: Map.put(fields, :peak_hours, hours)

      {:ok, fields}
    end
  end

  @doc """
  Checks whether a string is a valid 24-hour clock time in `HH:MM` format
  (hour 0-23, minute 0-59, two digits each). `"09:00"` → true; `"9:00"`,
  `"24:00"`, `"12:60"`, `"12:0"`, `"12:00am"` → false.
  """
  def valid_clock_time?(value) when is_binary(value) do
    Regex.match?(~r/\A(?:[01]\d|2[0-3]):[0-5]\d\z/, value)
  end

  def valid_clock_time?(_), do: false

  @doc """
  Converts a valid `"HH:MM"` clock time to minutes since midnight
  (e.g. `"09:00"` → 540). Returns `nil` for anything not matching the format;
  callers should validate with `valid_clock_time?/1` first.
  """
  def clock_to_minutes(value) when is_binary(value) do
    case String.split(value, ":") do
      [h, m] ->
        case {Integer.parse(h), Integer.parse(m)} do
          {{hour, ""}, {minute, ""}} -> hour * 60 + minute
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def clock_to_minutes(_), do: nil

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

  # Derives a profile-id base name from a model value. Accepts:
  #   - binary "provider:model_id" → the model_id part (after the FIRST colon);
  #     a plain binary without a colon → itself
  #   - map spec %{id: "..."} (or string-keyed "id") → the id value
  # Then slugifies (downcase, non-alphanumeric runs → single "-", trim "-").
  # Returns nil when nothing usable can be derived (callers fall back to
  # the "profile-N" scheme).
  defp base_name_from_model_value(value) when is_binary(value) do
    value |> String.split(":", parts: 2) |> List.last() |> slugify_base_name()
  end

  defp base_name_from_model_value(value) when is_map(value) do
    model_id = Map.get(value, :id) || Map.get(value, "id")
    slugify_base_name(model_id)
  end

  defp base_name_from_model_value(_), do: nil

  defp slugify_base_name(nil), do: nil
  defp slugify_base_name(""), do: nil

  defp slugify_base_name(value) when is_binary(value) do
    slug =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
      |> String.trim("-")

    case slug do
      "" -> nil
      slug -> slug
    end
  end

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

  # Swaps the elements at indices `i` and `j` in the list (both assumed in
  # bounds). Reads both original values before either replacement, so the
  # second List.replace_at/3 never sees a partially-swapped list.
  defp swap_elements(list, i, j) do
    {a, b} = {Enum.at(list, i), Enum.at(list, j)}
    list |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

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

  # ── peak/off-peak concurrency parsing helpers ─────────────────────────────
  #
  # Serialization contract: `peak_concurrency` (pos_integer) and `peak_hours`
  # ([%{start: "HH:MM", end: "HH:MM"}]) are OPTIONAL profile fields; when
  # disabled/empty the keys are ABSENT from the profile map so TOML omits them.
  # Validation here is UI-side UX validation only — the evo_git schema owns the
  # authoritative validation.

  # Blank/absent → {:ok, nil} (key omitted). A non-blank value must parse as a
  # POSITIVE integer ("0", "-1", "abc" are all invalid; blank is NOT an error).
  defp parse_peak_concurrency(nil), do: {:ok, nil}
  defp parse_peak_concurrency(""), do: {:ok, nil}

  defp parse_peak_concurrency(raw) do
    case SettingsUtils.parse_int(raw) do
      int when is_integer(int) and int > 0 -> {:ok, int}
      _ -> {:error, "peak_concurrency_invalid"}
    end
  end

  # Normalizes the peak_hours form value (Phoenix-nested map keyed by string
  # index, a list, or absent) into atom-keyed windows. Returns {:ok, nil} when
  # absent/all-blank (key omitted) or {:ok, [%{start:, end:}]} / {:error, _}.
  defp parse_peak_hours(input) do
    # normalize_peak_hours_input/1 is total — every input shape normalizes to a
    # row list (absent/unknown → []).
    rows = normalize_peak_hours_input(input)

    case normalize_peak_hours_rows(rows) do
      # Every row was fully blank → omit the key.
      {:ok, []} -> {:ok, nil}
      {:ok, windows} -> validate_peak_hours_windows(windows)
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_peak_hours_input(nil), do: {:ok, []}
  defp normalize_peak_hours_input(hours) when is_list(hours), do: {:ok, hours}

  defp normalize_peak_hours_input(hours) when is_map(hours) do
    # String-index keys sort NUMERICALLY ("10" after "9") so row order is
    # preserved regardless of map iteration order.
    sorted =
      hours
      |> Enum.sort_by(fn {idx, _row} ->
        case Integer.parse(to_string(idx)) do
          {int, ""} -> int
          _ -> -1
        end
      end)
      |> Enum.map(fn {_idx, row} -> row end)

    {:ok, sorted}
  end

  defp normalize_peak_hours_input(_), do: {:ok, []}

  defp normalize_peak_hours_rows(rows) do
    result =
      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
        case normalize_peak_hours_row(row) do
          # Fully-blank rows are dropped (only OK when ALL rows are blank —
          # handled by the caller omitting the key).
          {:ok, nil} -> {:cont, {:ok, acc}}
          {:ok, window} -> {:cont, {:ok, [window | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, windows} -> {:ok, Enum.reverse(windows)}
      error -> error
    end
  end

  # Reads start/end from a row with atom-or-string key safety. A row with
  # exactly one of start/end filled is invalid (must be both or neither).
  defp normalize_peak_hours_row(row) when is_map(row) do
    start_time = Map.get(row, "start") || Map.get(row, :start) || ""
    end_time = Map.get(row, "end") || Map.get(row, :end) || ""

    cond do
      start_time == "" and end_time == "" -> {:ok, nil}
      start_time == "" or end_time == "" -> {:error, "peak_hours_invalid_time"}
      true -> {:ok, %{start: start_time, end: end_time}}
    end
  end

  defp normalize_peak_hours_row(_), do: {:error, "peak_hours_invalid_time"}

  defp validate_peak_hours_windows(windows) do
    with :ok <- validate_window_times(windows),
         :ok <- validate_start_not_end(windows),
         :ok <- validate_no_overlap(windows) do
      {:ok, windows}
    end
  end

  defp validate_window_times(windows) do
    if Enum.all?(windows, fn w -> valid_clock_time?(w.start) and valid_clock_time?(w.end) end) do
      :ok
    else
      {:error, "peak_hours_invalid_time"}
    end
  end

  defp validate_start_not_end(windows) do
    if Enum.any?(windows, fn w -> w.start == w.end end) do
      {:error, "peak_hours_start_equals_end"}
    else
      :ok
    end
  end

  # Strict-overlap predicate on minute-windows: windows overlap when
  # startA < endB AND startB < endA. Touching boundaries (e.g. [09:00,12:00] +
  # [12:00,15:00]) are allowed.
  defp validate_no_overlap(windows) do
    minutes = Enum.map(windows, fn w -> {clock_to_minutes(w.start), clock_to_minutes(w.end)} end)

    overlaps? =
      for {a, i} <- Enum.with_index(minutes),
          {b, j} <- Enum.with_index(minutes),
          j > i,
          overlap?(a, b) do
        true
      end
      |> Enum.any?()

    if overlaps?, do: {:error, "peak_hours_overlap"}, else: :ok
  end

  defp overlap?({start_a, end_a}, {start_b, end_b}) do
    start_a < end_b and start_b < end_a
  end

  defp ensure_llm_key(file_config) do
    if is_map(get_in(file_config, [:llm])) do
      file_config
    else
      put_in(file_config, [:llm], %{})
    end
  end
end
