defmodule EvoGit.Config.Schema do
  @moduledoc """
  Schema definition and validation for EvoGit configuration.

  Defines the structure, types, and defaults for all configuration sections.
  Provides validation for user-provided config maps to catch type errors early.

  ## Usage

      # Get defaults
      Schema.defaults()

      # Validate a config map
      case Schema.validate(config) do
        {:ok, validated} -> # config is valid
        {:error, errors} -> # errors is a list of ValidationError structs
      end

      # Preload all schema atoms (called at compile time)
      Schema.all_schemas()
  """

  defmodule ValidationError do
    @moduledoc """
    Represents a single validation error found during config validation.

    Fields:
    - `:key_path` — the path to the invalid key as a list of atoms
    - `:message` — human-readable description of the validation failure
    - `:value` — the actual value that failed validation
    """
    defstruct [:key_path, :message, :value]

    @type t :: %__MODULE__{
      key_path: [atom()],
      message: String.t(),
      value: term()
    }
  end

  @typedoc "Schema definition for a single config field"
  @type field_schema :: %{
    required(:type) => :integer | :positive_integer | :string | :atom | :boolean | :float | :map,
    required(:default) => term(),
    optional(:required) => boolean()
  }

  @typedoc "Schema definition for a config section (key => field_schema)"
  @type section_schema :: %{atom() => field_schema()}

  # ── Schema Definitions ──────────────────────────────────────────────

  @scheduler_schema %{
    max_concurrency: %{type: :positive_integer, default: 3},
    max_tool_concurrency: %{type: :positive_integer, default: 2},
    agent_max_retries: %{type: :positive_integer, default: 3},
    max_agent_depth: %{type: :positive_integer, default: 8},
    max_retries: %{type: :positive_integer, default: 15},
    max_turns: %{type: :positive_integer, default: 128}
  }

  @llm_schema %{
    model: %{type: :string, default: nil},
    compression_threshold_tokens: %{type: :positive_integer, default: 100_000}
  }

  @user_schema %{
    github_username: %{type: :string, default: nil}
  }

  @sandbox_resources_schema %{
    cpu_quota: %{type: :string, default: "1000%"},
    cpu_weight: %{type: :positive_integer, default: 30},
    memory_max: %{type: :string, default: "16G"},
    tasks_max: %{type: :positive_integer, default: 8196}
  }

  @sandbox_process_schema %{
    cpu_quota: %{type: :string, default: "800%"},
    memory_max: %{type: :string, default: "12G"},
    limit_nofile: %{type: :positive_integer, default: 65_536},
    oom_score_adjust: %{type: :integer, default: 1000}
  }

  @evolution_schema %{
    pool_size: %{type: :positive_integer, default: 50},
    max_generations: %{type: :positive_integer, default: 20},
    selection_size: %{type: :positive_integer, default: 10},
    crossover_rate: %{type: :float, default: 0.7},
    mutation_rate: %{type: :float, default: 0.3},
    convergence_threshold: %{type: :float, default: 0.01},
    novelty_neighbors: %{type: :positive_integer, default: 5},
    stagnation_limit: %{type: :positive_integer, default: 5},
    initial_seed_count: %{type: :positive_integer, default: 15},
    llm_seed_count: %{type: :positive_integer, default: 25}
  }

  @truncation_schema %{
    tool_output_max_bytes: %{type: :positive_integer, default: 131_072},
    tool_output_default_max_bytes: %{type: :positive_integer, default: 16_384},
    tool_output_truncate_size: %{type: :positive_integer, default: 8_192},
    context_max_bytes: %{type: :positive_integer, default: 65_536}
  }

  @task_history_schema %{
    max_tasks: %{type: :positive_integer, default: 100},
    max_age_days: %{type: :positive_integer, default: 14}
  }

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Returns a map of all schema definitions, keyed by section name.

  This can be used to preload all valid config atoms at compile time.
  Simply calling this function at compile time ensures all section keys,
  field keys, and type atoms are loaded into the atom table.
  """
  @spec all_schemas() :: %{atom() => section_schema()}
  def all_schemas do
    %{
      scheduler: @scheduler_schema,
      llm: @llm_schema,
      user: @user_schema,
      sandbox_resources: @sandbox_resources_schema,
      sandbox_process: @sandbox_process_schema,
      evolution: @evolution_schema,
      truncation: @truncation_schema,
      task_history: @task_history_schema
    }
  end

  @doc """
  Returns the built-in application defaults map.

  These defaults are derived from the schema definitions. No default
  model or username is provided — those have nil defaults.
  """
  @spec defaults() :: map()
  def defaults do
    %{
      scheduler: extract_defaults(@scheduler_schema),
      llm: extract_defaults(@llm_schema),
      user: extract_defaults(@user_schema),
      sandbox: %{
        mode: :auto,
        resources: extract_defaults(@sandbox_resources_schema),
        process: extract_defaults(@sandbox_process_schema)
      },
      evolution: extract_defaults(@evolution_schema),
      truncation: extract_defaults(@truncation_schema),
      task_history: extract_defaults(@task_history_schema)
    }
  end

  @doc """
  Validates a config map against the schema.

  Returns `{:ok, config}` if valid, or `{:error, errors}` where errors
  is a list of `ValidationError` structs.

  Validation checks:
  - Type mismatches in known fields are reported as errors.
  - nil values are always accepted (they represent "not configured").
  """
  @spec validate(map()) :: {:ok, map()} | {:error, [ValidationError.t()]}
  def validate(config) when is_map(config) do
    errors =
      []
      |> validate_section(Map.get(config, :scheduler, %{}), @scheduler_schema, [:scheduler])
      |> validate_section(Map.get(config, :llm, %{}), @llm_schema, [:llm])
      |> validate_section(Map.get(config, :user, %{}), @user_schema, [:user])
      |> validate_sandbox(Map.get(config, :sandbox, %{}))
      |> validate_section(Map.get(config, :evolution, %{}), @evolution_schema, [:evolution])
      |> validate_section(Map.get(config, :truncation, %{}), @truncation_schema, [:truncation])
      |> validate_section(Map.get(config, :task_history, %{}), @task_history_schema, [:task_history])

    if errors == [] do
      {:ok, config}
    else
      {:error, errors}
    end
  end

  # ── Private: Default Extraction ─────────────────────────────────────

  defp extract_defaults(schema) do
    Map.new(schema, fn {key, %{default: default}} -> {key, default} end)
  end

  # ── Private: Validation ─────────────────────────────────────────────

  defp validate_sandbox(acc, sandbox) when not is_map(sandbox) do
    [%ValidationError{key_path: [:sandbox], message: "expected a map", value: sandbox} | acc]
  end

  defp validate_sandbox(acc, sandbox) do
    acc
    |> validate_sandbox_mode(sandbox)
    |> validate_sandbox_resources(sandbox)
    |> validate_sandbox_process(sandbox)
  end

  defp validate_sandbox_mode(acc, sandbox) do
    mode = Map.get(sandbox, :mode) || sandbox["mode"]

    cond do
      mode in [:auto, :enabled, :disabled] ->
        acc

      mode in ["auto", "enabled", "disabled"] ->
        acc

      is_nil(mode) ->
        acc

      true ->
        [
          %ValidationError{
            key_path: [:sandbox, :mode],
            message: "expected :auto, :enabled, or :disabled, got #{inspect(mode)}",
            value: mode
          }
          | acc
        ]
    end
  end

  defp validate_sandbox_resources(acc, sandbox) do
    resources = Map.get(sandbox, :resources) || sandbox["resources"] || %{}
    validate_section(acc, resources, @sandbox_resources_schema, [:sandbox, :resources])
  end

  defp validate_sandbox_process(acc, sandbox) do
    process = Map.get(sandbox, :process) || sandbox["process"] || %{}
    validate_section(acc, process, @sandbox_process_schema, [:sandbox, :process])
  end

  defp validate_section(acc, value, schema, key_path) when is_map(value) do
    Enum.reduce(schema, acc, fn {field_key, %{type: expected_type}}, acc ->
      case Map.fetch(value, field_key) do
        {:ok, field_value} ->
          if valid_type?(field_value, expected_type) do
            acc
          else
            [
              %ValidationError{
                key_path: key_path ++ [field_key],
                message: "expected #{expected_type}, got #{inspect(field_value)}",
                value: field_value
              }
              | acc
            ]
          end

        :error ->
          string_key = Atom.to_string(field_key)

          case Map.fetch(value, string_key) do
            {:ok, field_value} ->
              if valid_type?(field_value, expected_type) do
                acc
              else
                [
                  %ValidationError{
                    key_path: key_path ++ [field_key],
                    message: "expected #{expected_type}, got #{inspect(field_value)}",
                    value: field_value
                  }
                  | acc
                ]
              end

            :error ->
              acc
          end
      end
    end)
  end

  defp validate_section(acc, _value, _schema, _key_path) do
    acc
  end

  defp valid_type?(nil, _expected_type), do: true
  defp valid_type?(value, :integer), do: is_integer(value)
  defp valid_type?(value, :positive_integer), do: is_integer(value) and value > 0
  defp valid_type?(value, :string), do: is_binary(value)
  defp valid_type?(value, :atom), do: is_atom(value) or is_binary(value)
  defp valid_type?(value, :boolean), do: is_boolean(value)

  defp valid_type?(value, :float) do
    is_float(value) or is_integer(value)
  end

  defp valid_type?(_value, :map), do: true
end
