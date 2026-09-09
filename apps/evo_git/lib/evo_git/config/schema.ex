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

  ## Validation architecture

  Scalar type decisions are validated through Ecto (`EctoValidation` →
  the strict custom `Ecto.Type` modules in `EctoTypes`), while the schema
  maps in `Definitions.schemas/0` remain the plain data source of truth
  (also the dashboard's read model) and the defaults/transform pipeline in
  `EvoGit.Config` stays hand-written. See `EctoValidation`'s moduledoc for
  the full design; `validate/1` below keeps the map-walk and delegates
  per-entry error collection.

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
          | :data

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

  alias EvoGit.Config.EctoValidation
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
      MapSet.new([
        :nix,
        :scheduler,
        :llm,
        :user,
        :sandbox,
        :truncation,
        :task_history,
        :git,
        :server,
        :tools,
        :node,
        :appearance,
        :data
      ])
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

  Per-entry error collection (type errors then rule errors) is delegated to
  `EctoValidation.errors_for/4`; scalar type decisions route through the
  strict custom Ecto types in `EctoTypes`.
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
            EctoValidation.errors_for(schema.key_path, schema.type, schema.validation, value)
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

  # ── Private: Helpers ────────────────────────────────────────────────

  @doc false
  # Safe nested-map accessor. Unlike Kernel.get_in/2 (which uses the Access
  # behaviour and raises ArgumentError on non-map intermediate values like
  # strings or integers), this traverses the path only through actual maps,
  # returning nil if any step is not a map. This is necessary because user
  # config may contain type-mismatched values (e.g. `scheduler = "x"` instead
  # of a `[scheduler]` table) and validation must not crash on them.
  def safe_get_in(map, []), do: map

  def safe_get_in(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> safe_get_in(value, rest)
      :error -> nil
    end
  end

  def safe_get_in(_non_map, _path), do: nil

  # ── LLM Delegations ──────────────────────────────────────────────────

  defdelegate llm_generation_params(config), to: LLM
  defdelegate model_profiles(config), to: LLM
  defdelegate get_model_profile(config, id), to: LLM
  defdelegate default_model_profile(config), to: LLM
end
