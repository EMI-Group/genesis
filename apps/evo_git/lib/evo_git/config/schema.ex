defmodule EvoGit.Config.Schema do
  @moduledoc """
  Schema definition and validation for EvoGit configuration.

  Defines the structure, types, defaults, validation rules, descriptions,
  and categories for all configuration keys. Provides validation for
  user-provided config maps to catch type errors, range violations,
  and invalid enum values early.

  This is the **single source of truth** for configuration defaults
  and validation rules. The `EvoGit.Config` module delegates to
  `Schema.defaults/0` and `Schema.validate/1`.

  ## Usage

      # Get all schemas as flat list with full metadata
      Schema.all_schemas()

      # Get schemas grouped by category
      Schema.schemas_by_category()

      # Get defaults (nested map)
      Schema.defaults()

      # Validate a config map
      case Schema.validate(config) do
        {:ok, validated} -> # config is valid
        {:error, errors} -> # errors is a list of ValidationError structs
      end
  """

  # ── Types ───────────────────────────────────────────────────────────

  @typedoc "Path to a config key as a list of atoms"
  @type key_path :: [atom()]

  @typedoc "Top-level config category"
  @type category ::
          :scheduler
          | :llm
          | :user
          | :sandbox
          | :truncation
          | :task_history
          | :nix
          | :git
          | :server
          | :tools
          | :node
          | :appearance

  @typedoc "Sub-category for sandbox keys; nil for all other categories"
  @type sub_category :: :resources | :process | :linux | nil

  @typedoc "Supported config value types"
  @type schema_type ::
          :pos_integer
          | :non_neg_integer
          | :integer
          | :string
          | :list_of_strings
          | :float
          | :atom
          | :boolean
          | :model_spec
          | :model_profiles

  @typedoc "A single config key's full schema metadata"
  @type schema_map :: %{
          key_path: key_path(),
          type: schema_type(),
          default: term(),
          validation: keyword(),
          category: category(),
          sub_category: sub_category(),
          description: String.t()
        }

  defmodule ValidationError do
    @moduledoc """
    Represents a single validation error found during config validation.

    Fields:
    - `:key_path` — the path to the invalid key as a list of atoms
    - `:message` — human-readable description of the validation failure
    - `:value` — the actual value that failed validation
    - `:rule` — which validation rule failed (e.g., `{:min, 1}`, `{:max, 100}`, `{:in, [...]}`, or the expected type atom)
    """
    defstruct [:key_path, :message, :value, :rule]

    @type t :: %__MODULE__{
            key_path: [atom()],
            message: String.t(),
            value: term(),
            rule: term()
          }
  end

  alias EvoGit.Config.Schema.{Definitions, LLM}

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Returns all configuration key schemas as a flat list of maps.

  Each schema map contains:
  - `:key_path` — the full path as a list of atoms
  - `:type` — the expected value type (`:pos_integer`, `:string`, `:atom`, etc.)
  - `:default` — the default value (or nil if none)
  - `:validation` — a keyword list of validation rules (`min:`, `max:`, `in:`)
  - `:category` — the top-level config category
  - `:sub_category` — sub-category within sandbox (`:resources`, `:process`, or `:linux`); nil otherwise
  - `:description` — human-readable description string

  Calling this function also preloads all valid config atoms for safe use
  with `String.to_existing_atom/1` elsewhere.
  """
  @spec all_schemas() :: [schema_map()]
  def all_schemas do
    Definitions.schemas()
  end

  @doc """
  Returns schemas grouped by category.

  The returned map has category atoms as keys and lists of schema maps as values.
  Useful for building category-grouped settings pages.

  ## Examples

      iex> schemas = EvoGit.Config.Schema.schemas_by_category()
      iex> Map.keys(schemas) |> MapSet.new()
      MapSet.new([:nix, :scheduler, :llm, :user, :sandbox, :truncation, :task_history])
  """
  @spec schemas_by_category() :: %{category() => [schema_map()]}
  def schemas_by_category do
    Definitions.schemas()
    |> Enum.group_by(& &1.category)
  end

  @doc """
  Returns the default configuration map derived from all schemas.

  Builds a deeply nested map by setting each schema's default value
  at its `key_path`. This is the single source of truth for all default values.

  ## Examples

      iex> defaults = EvoGit.Config.Schema.defaults()
      iex> defaults.scheduler.default_llm_max_concurrency
      3
      iex> defaults.sandbox.resources.cpu_quota
      "1000%"
  """
  @spec defaults() :: map()
  def defaults do
    Enum.reduce(Definitions.schemas(), %{}, fn schema, acc ->
      deep_put(acc, schema.key_path, schema.default)
    end)
  end

  @doc """
  Validates a resolved configuration map against the schema.

  Returns `{:ok, config}` if all values pass validation, or
  `{:error, errors}` where errors is a list of `ValidationError` structs.

  Validation checks:
  - **Type compatibility** — is the value the right kind of data?
  - **Range constraints** — does the value satisfy min/max rules?
  - **Enum membership** — is the value in the allowed set?

  All errors are collected — validation does not stop at the first error.
  nil values are always accepted (they represent "not configured").
  """
  @spec validate(map()) :: {:ok, map()} | {:error, [ValidationError.t()]}
  def validate(config) when is_map(config) do
    errors =
      Enum.flat_map(Definitions.schemas(), fn schema ->
        # Use safe_get_in instead of get_in: get_in uses the Access
        # behaviour, which crashes (ArgumentError) if an intermediate value
        # is a non-map/non-Access type (e.g. `scheduler = "string"` instead
        # of a `[scheduler]` table). safe_get_in returns nil for any
        # non-traversable path, so the type check below catches the error.
        case safe_get_in(config, schema.key_path) do
          nil ->
            []

          value ->
            type_errors(schema.key_path, schema.type, value) ++
              rule_errors(schema.key_path, schema.validation, value)
        end
      end)

    if errors == [] do
      {:ok, config}
    else
      {:error, errors}
    end
  end

  # ── Private: Defaults Builder ───────────────────────────────────────

  defp deep_put(map, [key], value) do
    Map.put(map, key, value)
  end

  defp deep_put(map, [key | rest], value) do
    existing = Map.get(map, key, %{})
    Map.put(map, key, deep_put(existing, rest, value))
  end

  # ── Private: Type Validation ────────────────────────────────────────

  defp type_errors(key_path, :pos_integer, value) do
    if is_integer(value) and value > 0 do
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
    if is_integer(value) and value >= 0 do
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
    if is_integer(value) do
      []
    else
      [error(key_path, "must be an integer, got #{inspect(value)}", value, :integer)]
    end
  end

  defp type_errors(key_path, :string, value) do
    if is_binary(value) do
      []
    else
      [error(key_path, "must be a string, got #{inspect(value)}", value, :string)]
    end
  end

  defp type_errors(key_path, :list_of_strings, value) do
    if is_list(value) and Enum.all?(value, &is_binary/1) do
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
  # These are produced by normalize_model_map/1 when a model has override keys.
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
    if is_float(value) or is_integer(value) do
      []
    else
      [error(key_path, "must be a float (or integer), got #{inspect(value)}", value, :float)]
    end
  end

  defp type_errors(key_path, :atom, value) do
    if is_atom(value) do
      []
    else
      [error(key_path, "must be an atom, got #{inspect(value)}", value, :atom)]
    end
  end

  defp type_errors(key_path, :boolean, value) do
    if is_boolean(value) do
      []
    else
      [error(key_path, "must be a boolean, got #{inspect(value)}", value, :boolean)]
    end
  end

  # ── Private: Rule Validation ────────────────────────────────────────

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
    # both possible (TOML decoding may leave string keys). A `case Map.get`
    # (not `||`) distinguishes "absent" from "present but 0".
    peak_concurrency =
      case Map.get(profile, :peak_concurrency) do
        nil -> Map.get(profile, "peak_concurrency")
        value -> value
      end

    peak_concurrency_errors =
      if is_nil(peak_concurrency) do
        []
      else
        validate_peak_concurrency(path, peak_concurrency)
      end

    peak_hours =
      case Map.get(profile, :peak_hours) do
        nil -> Map.get(profile, "peak_hours")
        value -> value
      end

    peak_hours_errors =
      if is_nil(peak_hours) do
        []
      else
        validate_peak_hours(path, peak_hours)
      end

    # Optional IANA timezone name for the profile's peak-hour windows. Atom-
    # and string-keyed maps are both possible (TOML decoding may leave string
    # keys). A `case Map.get` (not `||`) distinguishes "absent" from
    # "present but nil".
    timezone =
      case Map.get(profile, :timezone) do
        nil -> Map.get(profile, "timezone")
        value -> value
      end

    timezone_errors =
      if is_nil(timezone) do
        []
      else
        validate_timezone_field(path, timezone)
      end

    # Optional list of days on which the profile is entirely off-peak (normal
    # concurrency 24/7, every peak_hours window suppressed). Atom- and
    # string-keyed maps are both possible (TOML decoding may leave string
    # keys). A `case Map.get` (not `||`) distinguishes "absent" from
    # "present but nil".
    off_peak_days =
      case Map.get(profile, :off_peak_days) do
        nil -> Map.get(profile, "off_peak_days")
        value -> value
      end

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
  # during peak windows).
  defp validate_peak_concurrency(path, value) do
    if is_integer(value) and value >= 0 do
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

  # ── Private: Helpers ────────────────────────────────────────────────

  # Safe nested-map accessor. Unlike Kernel.get_in/2 (which uses the Access
  # behaviour and raises ArgumentError on non-map intermediate values like
  # strings or integers), this traverses the path only through actual maps,
  # returning nil if any step is not a map. This is necessary because user
  # config may contain type-mismatched values (e.g. `scheduler = "x"` instead
  # of a `[scheduler]` table) and validation must not crash on them.
  defp safe_get_in(map, []), do: map

  defp safe_get_in(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> safe_get_in(value, rest)
      :error -> nil
    end
  end

  defp safe_get_in(_non_map, _path), do: nil

  defp error(key_path, message, value, rule) do
    %ValidationError{
      key_path: key_path,
      message: message,
      value: value,
      rule: rule
    }
  end

  # ── LLM Delegations ──────────────────────────────────────────────────

  defdelegate llm_generation_params(config), to: LLM
  defdelegate model_profiles(config), to: LLM
  defdelegate get_model_profile(config, id), to: LLM
  defdelegate default_model_profile(config), to: LLM
end
