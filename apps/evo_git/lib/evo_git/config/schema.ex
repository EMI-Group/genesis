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
  @type category :: :scheduler | :llm | :user | :sandbox | :truncation | :task_history | :nix | :git | :server | :tools | :node

  @typedoc "Sub-category for sandbox keys; nil for all other categories"
  @type sub_category :: :resources | :process | :linux | nil

  @typedoc "Supported config value types"
  @type schema_type :: :pos_integer | :non_neg_integer | :integer | :string | :float | :atom | :boolean | :model_spec | :model_profiles

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
      iex> defaults.scheduler.max_concurrency
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
      [error(key_path, "must be a positive integer (greater than 0), got #{inspect(value)}", value, :pos_integer)]
    end
  end

  defp type_errors(key_path, :non_neg_integer, value) do
    if is_integer(value) and value >= 0 do
      []
    else
      [error(key_path, "must be a non-negative integer (0 or greater), got #{inspect(value)}", value, :non_neg_integer)]
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

  # Accept tuple model specs (e.g. {:openai, [id: "gpt-5.6", base_url: "..."]}).
  # These are produced by normalize_model_map/1 when a model has override keys.
  # Must be a 2-element tuple: {provider_atom, keyword_list}. The keyword list
  # must have at least :id with a non-empty string. :extra is optional but,
  # if present, must be a map.
  defp type_errors(key_path, :model_spec, {provider, opts}) when is_atom(provider) and is_list(opts) do
    id = Keyword.get(opts, :id)
    has_extra = Keyword.has_key?(opts, :extra)
    extra = Keyword.get(opts, :extra)

    id_errors =
      if is_binary(id) and id != "" do
        []
      else
        [error(key_path, "model tuple must have a valid non-empty 'id' string, got #{inspect(id)}", {provider, opts}, :model_spec)]
      end

    extra_errors =
      if has_extra and not is_map(extra) do
        [error(key_path, "model tuple 'extra' must be a map, got #{inspect(extra)}", {provider, opts}, :model_spec)]
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
            [error(key_path, "model map 'extra' must be a map, got #{inspect(extra)}", value, :model_spec)]
          else
            []
          end

        cond do
          not has_provider ->
            [error(key_path, "model map must have a 'provider' key, got #{inspect(value)}", value, :model_spec)]

          not has_id ->
            [error(key_path, "model map must have an 'id' key, got #{inspect(value)}", value, :model_spec)]

          true ->
            extra_errors
        end

      true ->
        [error(key_path, "must be a string (e.g. \"provider:model\"), a map (e.g. %{provider: :openai, id: \"...\", base_url: \"...\", extra: %{...}}), or a tuple (e.g. {:openai, [id: \"...\", base_url: \"...\"]}), got #{inspect(value)}", value, :model_spec)]
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
        [error(key_path, "must be a list of model profiles, got #{inspect(value)}", value, :model_profiles)]
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

    errors = []

    errors =
      if is_binary(id) and id != "" do
        errors
      else
        [error(path ++ [:id], "profile must have a non-empty 'id' string, got #{inspect(id)}", id, :string) | errors]
      end

    model_errors =
      cond do
        is_nil(model) ->
          [error(path ++ [:model], "profile must have a 'model' field", nil, :model_spec)]

        is_binary(model) ->
          []

        is_map(model) ->
          type_errors(path ++ [:model], :model_spec, model)

        true ->
          type_errors(path ++ [:model], :model_spec, model)
      end

    errors ++ model_errors
  end

  defp validate_model_profile(path, profile) do
    [error(path, "profile must be a map/table, got #{inspect(profile)}", profile, :model_profiles)]
  end

  defp rule_errors(key_path, validation, value) do
    Enum.flat_map(validation, fn
      {:min, min_val} ->
        if is_number(value) and value >= min_val do
          []
        else
          [error(key_path, "must be >= #{min_val}, got #{inspect(value)}", value, {:min, min_val})]
        end

      {:max, max_val} ->
        if is_number(value) and value <= max_val do
          []
        else
          [error(key_path, "must be <= #{max_val}, got #{inspect(value)}", value, {:max, max_val})]
        end

      {:in, allowed} ->
        if value in allowed do
          []
        else
          [error(key_path, "must be one of #{inspect(allowed)}, got #{inspect(value)}", value, {:in, allowed})]
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
