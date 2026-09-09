defmodule EvoGit.Config.EctoValidation do
  @moduledoc """
  Ecto-backed validation engine beneath the `EvoGit.Config.Schema` DSL.

  `EvoGit.Config.Schema.validate/1` walks the 95 schema descriptors (in
  `EvoGit.Config.Schema.Definitions.schemas/0`) with `safe_get_in/2` and
  delegates each present value here — `errors_for/4` returns the per-entry
  `[%EvoGit.Config.Schema.ValidationError{}]` list. This module is the
  **decision oracle** for scalar DSL types and the **byte-exact error
  adapter** for the whole validator.

  ## Ecto's role — a validator ONLY

  Ecto is used strictly as a *casting oracle* for the scalar half of the DSL
  type vocabulary. The 8 scalar DSL types (`:pos_integer`,
  `:non_neg_integer`, `:integer`, `:string`, `:list_of_strings`, `:float`,
  `:atom`, `:boolean`) map to the strict custom `Ecto.Type` modules in
  `EvoGit.Config.EctoTypes` (`EctoTypes.type_for/1`), and every scalar
  pass/fail decision routes through `EctoTypes.valid?/2` —
  `match?({:ok, _}, Ecto.Type.cast(type_for(type), value))` — which
  dispatches straight to the module's own `cast/1` with no base-type
  coercion. Ecto NEVER rebuilds or transforms the config: no
  `Ecto.Changeset.cast` on the whole map, no `validate_number` /
  `validate_inclusion` / `Ecto.Enum` / `validate_required`. The validated
  map passes through unchanged on `{:ok, config}` — unknown keys survive,
  model profiles stay plain maps, and `""` remains a meaningful value.

  ## What stays hand-written (and why)

  - **Composite, multi-error recursion** — `:model_spec`, `:model_profiles`
    and the optional peak profile fields (`peak_concurrency`, `peak_hours`,
    `timezone`, `off_peak_days`) produce multiple, sub-path-aware errors
    (e.g. one per `llm.models` list index, `indexed_path/3` window indices)
    that a single `cast/1` cannot express. Their **scalar leaves** still
    route through `EctoTypes` where a matching custom type exists (e.g.
    `peak_concurrency` → `EctoTypes.valid?(:non_neg_integer, value)`).
  - **All window/day/timezone math delegates to `EvoGit.PeakHours`**
    (`validate_windows/1`, `validate_timezone/1`, `validate_days/1` — the
    single source of truth; never re-implemented here).
  - **`min`/`max`/`in` rule checks** — these are range/enum rules, not type
    casts, and the Ecto changeset validators for them are banned by design;
    they are ported byte-exact as pure predicates.
  - **Message construction** — every message sentence, `value`, `rule` and
    error-ordering is byte-identical to the former hand-written `schema.ex`
    privates; only the scalar acceptance predicates were replaced with
    `EctoTypes` calls.

  ## Ecto quirk handling

  - Custom strict types reject numeric strings (`"2"` fails integer types —
    no coercion) and never strip empty values (`""` stays a valid string).
  - `nil` ≡ absent is legal: absent keys yield no errors (`Schema.validate/1`
    skips `safe_get_in` misses), and nil present-values are guarded at the
    model-profile level (optional fields).
  - Enum values are atoms after `Config.resolve/0`'s atomization; a bad enum
    string that survived atomization surfaces as a type error, never an
    `in:` error (the `in:` whitelist holds atoms).
  """

  alias EvoGit.Config.EctoTypes
  alias EvoGit.Config.Schema.ValidationError

  @typedoc "Path to a config key as a list of atoms (may contain integer indices)"
  @type key_path :: [atom() | integer()]

  @typedoc "The full DSL type vocabulary (scalar + composite)"
  @type schema_type ::
          EctoTypes.scalar_type()
          | :model_spec
          | :model_profiles

  @doc """
  Validates one schema entry's value.

  Returns the collected `ValidationError` list for the entry — type errors
  FIRST (in type-clause order), then rule errors (in `validation` keyword
  order). Empty list = the value passes.
  """
  @spec errors_for(key_path(), schema_type(), keyword(), term()) :: [ValidationError.t()]
  def errors_for(key_path, type, validation, value) do
    type_errors(key_path, type, value) ++ rule_errors(key_path, validation, value)
  end

  # ── Private: Scalar Type Validation (decisions via EctoTypes) ─────────

  defp type_errors(key_path, :pos_integer, value) do
    if EctoTypes.valid?(:pos_integer, value) do
      []
    else
      [
        error(
          key_path,
          "must be a positive integer (greater than 0), got #{inspect(value)}",
          value,
          :pos_integer
        )
      ]
    end
  end

  defp type_errors(key_path, :non_neg_integer, value) do
    if EctoTypes.valid?(:non_neg_integer, value) do
      []
    else
      [
        error(
          key_path,
          "must be a non-negative integer (0 or greater), got #{inspect(value)}",
          value,
          :non_neg_integer
        )
      ]
    end
  end

  defp type_errors(key_path, :integer, value) do
    if EctoTypes.valid?(:integer, value) do
      []
    else
      [error(key_path, "must be an integer, got #{inspect(value)}", value, :integer)]
    end
  end

  defp type_errors(key_path, :string, value) do
    if EctoTypes.valid?(:string, value) do
      []
    else
      [error(key_path, "must be a string, got #{inspect(value)}", value, :string)]
    end
  end

  defp type_errors(key_path, :list_of_strings, value) do
    if EctoTypes.valid?(:list_of_strings, value) do
      []
    else
      [
        error(
          key_path,
          "must be a list of strings, got #{inspect(value)}",
          value,
          :list_of_strings
        )
      ]
    end
  end

  # Accept tuple model specs (e.g. {:openai, [id: "gpt-5.6-sol", base_url: "..."]}).
  # Tuples are a legacy LLMDB-compatible model spec form passed by API callers
  # (e.g. tests or direct Schema.validate/save_user_config invocations) — they
  # are NOT produced by normalize_model_map/1 (config.ex), which yields
  # "provider:id" strings or atom-keyed maps only.
  # Must be a 2-element tuple: {provider_atom, keyword_list}. The keyword list
  # must have at least :id with a non-empty string. :extra is optional but,
  # if present, must be a map.
  defp type_errors(key_path, :model_spec, {provider, opts})
       when is_atom(provider) and is_list(opts) do
    id = Keyword.get(opts, :id)
    has_extra = Keyword.has_key?(opts, :extra)
    extra = Keyword.get(opts, :extra)

    id_errors =
      if is_binary(id) and id != "" do
        []
      else
        [
          error(
            key_path,
            "model tuple must have a valid non-empty 'id' string, got #{inspect(id)}",
            {provider, opts},
            :model_spec
          )
        ]
      end

    extra_errors =
      if has_extra and not is_map(extra) do
        [
          error(
            key_path,
            "model tuple 'extra' must be a map, got #{inspect(extra)}",
            {provider, opts},
            :model_spec
          )
        ]
      else
        []
      end

    id_errors ++ extra_errors
  end

  defp type_errors(key_path, :model_spec, value) do
    cond do
      is_binary(value) ->
        []

      is_map(value) ->
        # Accept map model specs (e.g. %{provider: :openai, id: "...", base_url: "...",
        # extra: %{...}}). Must have at least :id and :provider keys. :extra is
        # optional but, if present, must be a map.
        has_provider = Map.has_key?(value, :provider) or Map.has_key?(value, "provider")
        has_id = Map.has_key?(value, :id) or Map.has_key?(value, "id")
        has_extra = Map.has_key?(value, :extra) or Map.has_key?(value, "extra")
        extra = Map.get(value, :extra) || Map.get(value, "extra")

        extra_errors =
          if has_extra and not is_map(extra) do
            [
              error(
                key_path,
                "model map 'extra' must be a map, got #{inspect(extra)}",
                value,
                :model_spec
              )
            ]
          else
            []
          end

        cond do
          not has_provider ->
            [
              error(
                key_path,
                "model map must have a 'provider' key, got #{inspect(value)}",
                value,
                :model_spec
              )
            ]

          not has_id ->
            [
              error(
                key_path,
                "model map must have an 'id' key, got #{inspect(value)}",
                value,
                :model_spec
              )
            ]

          true ->
            extra_errors
        end

      true ->
        [
          error(
            key_path,
            "must be a string (e.g. \"provider:model\"), a map (e.g. %{provider: :openai, id: \"...\", base_url: \"...\", extra: %{...}}), or a tuple (e.g. {:openai, [id: \"...\", base_url: \"...\"]}), got #{inspect(value)}",
            value,
            :model_spec
          )
        ]
    end
  end

  defp type_errors(key_path, :model_profiles, value) do
    cond do
      is_list(value) ->
        # Validate each profile in the list
        value
        |> Enum.with_index()
        |> Enum.flat_map(fn {profile, idx} ->
          path = key_path ++ [idx]
          validate_model_profile(path, profile)
        end)

      is_map(value) ->
        # A single table without array brackets — normalize to single-element list
        validate_model_profile(key_path, value)

      true ->
        [
          error(
            key_path,
            "must be a list of model profiles, got #{inspect(value)}",
            value,
            :model_profiles
          )
        ]
    end
  end

  defp type_errors(key_path, :float, value) do
    if EctoTypes.valid?(:float, value) do
      []
    else
      [error(key_path, "must be a float (or integer), got #{inspect(value)}", value, :float)]
    end
  end

  defp type_errors(key_path, :atom, value) do
    if EctoTypes.valid?(:atom, value) do
      []
    else
      [error(key_path, "must be an atom, got #{inspect(value)}", value, :atom)]
    end
  end

  defp type_errors(key_path, :boolean, value) do
    if EctoTypes.valid?(:boolean, value) do
      []
    else
      [error(key_path, "must be a boolean, got #{inspect(value)}", value, :boolean)]
    end
  end

  # ── Private: Rule Validation (min/max/in — ported byte-exact) ─────────

  defp rule_errors(key_path, validation, value) do
    Enum.flat_map(validation, fn
      {:min, min_val} ->
        if is_number(value) and value >= min_val do
          []
        else
          [
            error(
              key_path,
              "must be >= #{min_val}, got #{inspect(value)}",
              value,
              {:min, min_val}
            )
          ]
        end

      {:max, max_val} ->
        if is_number(value) and value <= max_val do
          []
        else
          [
            error(
              key_path,
              "must be <= #{max_val}, got #{inspect(value)}",
              value,
              {:max, max_val}
            )
          ]
        end

      {:in, allowed} ->
        if value in allowed do
          []
        else
          [
            error(
              key_path,
              "must be one of #{inspect(allowed)}, got #{inspect(value)}",
              value,
              {:in, allowed}
            )
          ]
        end

      _ ->
        []
    end)
  end

  # ── Private: Model Profile Validation ─────────────────────────────────

  # Reads a profile field from an atom- or string-keyed map (TOML decoding
  # may leave string keys). A `case Map.get` (not `||`) distinguishes
  # "absent" from "present but nil" — nil means the optional field is
  # unconfigured.
  defp profile_field(profile, key) do
    case Map.get(profile, key) do
      nil -> Map.get(profile, Atom.to_string(key))
      value -> value
    end
  end

  defp validate_model_profile(path, profile) when is_map(profile) do
    id = Map.get(profile, :id) || Map.get(profile, "id")
    model = Map.get(profile, :model) || Map.get(profile, "model")

    id_errors =
      if is_binary(id) and id != "" do
        []
      else
        [
          error(
            path ++ [:id],
            "profile must have a non-empty 'id' string, got #{inspect(id)}",
            id,
            :string
          )
        ]
      end

    model_errors =
      cond do
        is_nil(model) ->
          [error(path ++ [:model], "profile must have a 'model' field", nil, :model_spec)]

        is_binary(model) ->
          []

        true ->
          # Map or any other type — delegate to model_spec validation.
          type_errors(path ++ [:model], :model_spec, model)
      end

    provider_options_errors =
      case Map.get(profile, :provider_options) do
        nil ->
          []

        po when not is_map(po) ->
          [
            error(
              path ++ [:provider_options],
              "provider_options must be a map, got #{inspect(po)}",
              po,
              :map
            )
          ]

        _po ->
          []
      end

    # Optional peak-hour concurrency fields. Atom- and string-keyed maps are
    # both possible (TOML decoding may leave string keys).
    peak_concurrency = profile_field(profile, :peak_concurrency)

    peak_concurrency_errors =
      if is_nil(peak_concurrency) do
        []
      else
        validate_peak_concurrency(path, peak_concurrency)
      end

    peak_hours = profile_field(profile, :peak_hours)

    peak_hours_errors =
      if is_nil(peak_hours) do
        []
      else
        validate_peak_hours(path, peak_hours)
      end

    # Optional IANA timezone name for the profile's peak-hour windows.
    timezone = profile_field(profile, :timezone)

    timezone_errors =
      if is_nil(timezone) do
        []
      else
        validate_timezone_field(path, timezone)
      end

    # Optional list of days on which the profile is entirely off-peak (normal
    # concurrency 24/7, every peak_hours window suppressed).
    off_peak_days = profile_field(profile, :off_peak_days)

    off_peak_days_errors =
      if is_nil(off_peak_days) do
        []
      else
        validate_off_peak_days(path, off_peak_days)
      end

    id_errors ++
      model_errors ++
      provider_options_errors ++
      peak_concurrency_errors ++
      peak_hours_errors ++
      timezone_errors ++
      off_peak_days_errors
  end

  defp validate_model_profile(path, profile) do
    [
      error(
        path,
        "profile must be a map/table, got #{inspect(profile)}",
        profile,
        :model_profiles
      )
    ]
  end

  # Validates the optional peak_concurrency profile field: must be a
  # non-negative integer when present (0 is valid — it disables the model
  # during peak windows). Scalar decision routes through EctoTypes' strict
  # NonNegInteger cast; message/rule stay byte-exact (rule is `:integer` for
  # backward compatibility).
  defp validate_peak_concurrency(path, value) do
    if EctoTypes.valid?(:non_neg_integer, value) do
      []
    else
      [
        error(
          path ++ [:peak_concurrency],
          "peak_concurrency must be a non-negative integer, got #{inspect(value)}",
          value,
          :integer
        )
      ]
    end
  end

  # Validates the optional timezone profile field (an IANA time zone name) by
  # delegating tz-database resolution to EvoGit.PeakHours.validate_timezone/1
  # (single source of truth — do NOT re-implement tz-database probing here).
  # nil/"" is valid (no timezone → local wall clock); {:error, reason} maps
  # to a ValidationError via the error/4 helper.
  defp validate_timezone_field(path, value) do
    case EvoGit.PeakHours.validate_timezone(value) do
      :ok ->
        []

      {:error, reason} ->
        [
          error(
            path ++ [:timezone],
            "invalid timezone: #{inspect(reason)} (got #{inspect(value)})",
            value,
            :timezone
          )
        ]
    end
  end

  # Validates the optional off_peak_days profile field by delegating day-name
  # parsing to EvoGit.PeakHours.validate_days/1 (single source of truth — do
  # NOT re-implement the day vocabulary here). {:ok, _days} (including
  # {:ok, []} = disabled) is valid; {:error, {:invalid_days, v}} maps to a
  # ValidationError via the error/4 helper.
  defp validate_off_peak_days(path, value) do
    case EvoGit.PeakHours.validate_days(value) do
      {:ok, _days} ->
        []

      {:error, {:invalid_days, v}} ->
        [
          error(
            path ++ [:off_peak_days],
            "off_peak_days must be a list of day names (mon|tue|wed|thu|fri|sat|sun) and/or keywords (weekdays|weekends), got #{inspect(v)}",
            v,
            :off_peak_days
          )
        ]
    end
  end

  # Validates the optional peak_hours profile field by delegating window
  # parsing/format/overlap checks to EvoGit.PeakHours.validate_windows/1
  # (single source of truth — do NOT re-implement format/overlap logic).
  # {:ok, _windows} (including {:ok, []} = disabled) is valid; each
  # {:error, reason} maps to a ValidationError via the error/4 helper.
  defp validate_peak_hours(path, value) do
    case EvoGit.PeakHours.validate_windows(value) do
      {:ok, _windows} ->
        []

      {:error, reason} ->
        peak_hours_errors(path, value, reason)
    end
  end

  defp peak_hours_errors(path, value, reason) do
    base_path = path ++ [:peak_hours]

    case reason do
      {:invalid_windows, v} ->
        [
          error(
            base_path,
            "peak_hours must be a list of { start = \"HH:MM\", end = \"HH:MM\" } windows, got #{inspect(v)}",
            v,
            :peak_hours
          )
        ]

      {:invalid_window, v} ->
        [
          error(
            indexed_path(base_path, value, v),
            "peak_hours entries must be maps with start/end \"HH:MM\" strings, got #{inspect(v)}",
            v,
            :peak_hours
          )
        ]

      {:invalid_format, w} ->
        [
          error(
            indexed_path(base_path, value, w),
            "peak_hours window has invalid \"HH:MM\" time, got #{inspect(w)}",
            w,
            :peak_hours
          )
        ]

      {:zero_length, w} ->
        [
          error(
            indexed_path(base_path, value, w),
            "peak_hours window start must differ from end (zero-length window), got #{inspect(w)}",
            w,
            :peak_hours
          )
        ]

      {:overlap, w1, w2} ->
        [
          error(
            indexed_path(base_path, value, w1),
            "peak_hours windows overlap: #{inspect(w1)} and #{inspect(w2)}",
            {w1, w2},
            :peak_hours
          )
        ]

      {:invalid_days, w} ->
        [
          error(
            indexed_path(base_path, value, w) ++ [:days],
            "peak_hours window has invalid days: expected a list of day names (mon|tue|wed|thu|fri|sat|sun) and/or keywords (weekdays|weekends), got #{inspect(Map.get(w, :days, Map.get(w, "days")))}",
            Map.get(w, :days, Map.get(w, "days")),
            :days
          )
        ]
    end
  end

  # Locates a raw window map inside the peak_hours list so the TOML path
  # can include the window index (e.g. [:llm, :models, 0, :peak_hours, 1]).
  # Falls back to the bare :peak_hours path when the value isn't a list or
  # the window can't be found.
  defp indexed_path(base_path, value, window) when is_list(value) do
    case Enum.find_index(value, &(&1 == window)) do
      nil -> base_path
      idx -> base_path ++ [idx]
    end
  end

  defp indexed_path(base_path, _value, _window), do: base_path

  # ── Private: Error Construction ───────────────────────────────────────

  defp error(key_path, message, value, rule) do
    %ValidationError{
      key_path: key_path,
      message: message,
      value: value,
      rule: rule
    }
  end
end
