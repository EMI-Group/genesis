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
  @type category :: :scheduler | :llm | :user | :sandbox | :truncation | :task_history

  @typedoc "Sub-category for sandbox keys; nil for all other categories"
  @type sub_category :: :resources | :process | nil

  @typedoc "Supported config value types"
  @type schema_type :: :pos_integer | :non_neg_integer | :integer | :string | :float | :atom

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

  # ── Schema Definitions (flat list) ───────────────────────────────────

  @schemas [
    # ── Scheduler ──────────────────────────────────────────────────────
    %{
      key_path: [:scheduler, :max_concurrency],
      type: :pos_integer,
      default: 3,
      validation: [min: 1],
      category: :scheduler,
      sub_category: nil,
      description:
        "Maximum number of concurrent LLM API calls. Controls how many agents can make API calls simultaneously. Lower values reduce API rate-limit pressure but slow down overall progress."
    },
    %{
      key_path: [:scheduler, :max_tool_concurrency],
      type: :pos_integer,
      default: 2,
      validation: [min: 1],
      category: :scheduler,
      sub_category: nil,
      description:
        "Maximum number of concurrent tool executions. Controls how many tool calls (bash, file operations, etc.) can run in parallel. Reduce if you encounter system resource pressure."
    },
    %{
      key_path: [:scheduler, :agent_max_retries],
      type: :non_neg_integer,
      default: 3,
      validation: [min: 0],
      category: :scheduler,
      sub_category: nil,
      description:
        "Maximum number of crash-retries per agent. When an agent crashes due to an unexpected error, the scheduler will restart it up to this many times. Set to 0 to disable retries."
    },
    %{
      key_path: [:scheduler, :max_agent_depth],
      type: :pos_integer,
      default: 8,
      validation: [min: 1],
      category: :scheduler,
      sub_category: nil,
      description:
        "Maximum subagent recursion depth. Prevents infinite delegation chains. A manager can spawn sub-managers, who can spawn further managers, up to this many levels deep."
    },
    %{
      key_path: [:scheduler, :max_retries],
      type: :pos_integer,
      default: 15,
      validation: [min: 1],
      category: :scheduler,
      sub_category: nil,
      description:
        "Maximum total LLM API retries across all agents. When the system encounters rate-limit errors or transient API failures, it will retry up to this many times before giving up."
    },
    %{
      key_path: [:scheduler, :max_turns],
      type: :pos_integer,
      default: 128,
      validation: [min: 1],
      category: :scheduler,
      sub_category: nil,
      description:
        "Maximum number of agent turns. An agent turn consists of one LLM call followed by tool execution. This limit prevents runaway loops from consuming excessive API credits."
    },
    # ── LLM ────────────────────────────────────────────────────────────
    %{
      key_path: [:llm, :model],
      type: :string,
      default: nil,
      validation: [],
      category: :llm,
      sub_category: nil,
      description:
        "The LLM model identifier in 'provider:model' format. Examples: 'anthropic:claude-sonnet-4-20250514', 'google:gemini-2.0-flash-exp', 'zai_coding_plan:glm-5.1'. The provider portion determines which API key is used. This setting is required for Genesis to function."
    },
    %{
      key_path: [:llm, :compression_threshold_tokens],
      type: :pos_integer,
      default: 100_000,
      validation: [min: 1],
      category: :llm,
      sub_category: nil,
      description:
        "Token count threshold that triggers context compression. When an agent's accumulated context (system prompt, conversation history, tool outputs) exceeds this token count, older context is compressed to avoid hitting the LLM's context window limit."
    },
    # ── User ───────────────────────────────────────────────────────────
    %{
      key_path: [:user, :github_username],
      type: :string,
      default: nil,
      validation: [],
      category: :user,
      sub_category: nil,
      description:
        "Your GitHub username. Used when creating pull requests to attribute the PR to your account. Optional but recommended if you plan to use the automated PR creation feature."
    },
    # ── Sandbox ────────────────────────────────────────────────────────
    %{
      key_path: [:sandbox, :mode],
      type: :atom,
      default: :auto,
      validation: [in: [:auto, :enabled, :disabled]],
      category: :sandbox,
      sub_category: nil,
      description:
        "Sandbox execution mode. 'auto' enables sandboxing on supported platforms (Linux with systemd-run, macOS with sandbox-exec) and falls back to direct execution on unsupported platforms. 'enabled' forces sandboxing and fails if unavailable. 'disabled' skips sandboxing entirely."
    },
    %{
      key_path: [:sandbox, :resources, :cpu_quota],
      type: :string,
      default: "1000%",
      validation: [],
      category: :sandbox,
      sub_category: :resources,
      description:
        "Aggregate CPU quota for all sandboxed processes combined. Uses systemd CPUQuota format (e.g., '1000%' = 10 CPU cores). This is the total CPU available across the entire sandbox slice."
    },
    %{
      key_path: [:sandbox, :resources, :cpu_weight],
      type: :pos_integer,
      default: 30,
      validation: [min: 1, max: 10_000],
      category: :sandbox,
      sub_category: :resources,
      description:
        "CPU allocation weight for the sandbox slice relative to other system workloads (1-10000). Higher values give Genesis processes more CPU time when the system is under contention. Default of 30 provides moderate priority."
    },
    %{
      key_path: [:sandbox, :resources, :memory_max],
      type: :string,
      default: "16G",
      validation: [],
      category: :sandbox,
      sub_category: :resources,
      description:
        "Total memory limit for all sandboxed processes combined. Uses systemd memory format (e.g., '16G', '8G', '512M'). When the aggregate memory usage exceeds this limit, the kernel's OOM killer may terminate processes."
    },
    %{
      key_path: [:sandbox, :resources, :tasks_max],
      type: :pos_integer,
      default: 8196,
      validation: [min: 1],
      category: :sandbox,
      sub_category: :resources,
      description:
        "Maximum number of tasks (processes and threads) allowed across the entire sandbox slice. Prevents fork bombs and runaway process creation from consuming system resources."
    },
    %{
      key_path: [:sandbox, :process, :cpu_quota],
      type: :string,
      default: "800%",
      validation: [],
      category: :sandbox,
      sub_category: :process,
      description:
        "Per-process CPU quota for individual tool executions. Uses systemd CPUQuota format (e.g., '800%' = 8 CPU cores). Each tool call (bash, compile, etc.) is limited to this amount of CPU time."
    },
    %{
      key_path: [:sandbox, :process, :memory_max],
      type: :string,
      default: "12G",
      validation: [],
      category: :sandbox,
      sub_category: :process,
      description:
        "Per-process memory limit for individual tool executions. Uses systemd memory format (e.g., '12G', '4G', '512M'). A single tool call that exceeds this limit will be killed."
    },
    %{
      key_path: [:sandbox, :process, :limit_nofile],
      type: :pos_integer,
      default: 65536,
      validation: [min: 1],
      category: :sandbox,
      sub_category: :process,
      description:
        "Maximum number of open file descriptors per sandboxed process. Limits how many files a single tool execution can have open simultaneously."
    },
    %{
      key_path: [:sandbox, :process, :oom_score_adjust],
      type: :integer,
      default: 1000,
      validation: [min: -1000, max: 1000],
      category: :sandbox,
      sub_category: :process,
      description:
        "OOM killer adjustment score per process (-1000 to 1000). Higher values make processes more likely to be killed when memory is exhausted. Default of 1000 means sandboxed processes are preferentially killed over system processes."
    },
    # ── Truncation ─────────────────────────────────────────────────────
    %{
      key_path: [:truncation, :tool_output_max_bytes],
      type: :pos_integer,
      default: 131_072,
      validation: [min: 1],
      category: :truncation,
      sub_category: nil,
      description:
        "Maximum tool output size in bytes before truncation is triggered. When a tool returns output larger than this threshold (default 128 KB), the output is truncated to avoid overwhelming the LLM context window."
    },
    %{
      key_path: [:truncation, :tool_output_default_max_bytes],
      type: :pos_integer,
      default: 16_384,
      validation: [min: 1],
      category: :truncation,
      sub_category: nil,
      description:
        "Default maximum output size in bytes for high-output tools. Used as the default truncation point for tools known to produce large outputs. Most tools use this value unless overridden per-tool."
    },
    %{
      key_path: [:truncation, :tool_output_truncate_size],
      type: :pos_integer,
      default: 8_192,
      validation: [min: 1],
      category: :truncation,
      sub_category: nil,
      description:
        "Size in bytes to which truncated output is reduced. When a tool's output exceeds the max bytes threshold, it is cut down to this size (default 8 KB). The truncated portion is replaced with a notice indicating how much was removed."
    },
    %{
      key_path: [:truncation, :context_max_bytes],
      type: :pos_integer,
      default: 65_536,
      validation: [min: 1],
      category: :truncation,
      sub_category: nil,
      description:
        "Maximum size in bytes for CONTEXT.md file content. When reading or writing CONTEXT.md files, content exceeding this limit (default 64 KB) is truncated to prevent context bloat."
    },
    # ── Task History ───────────────────────────────────────────────────
    %{
      key_path: [:task_history, :max_tasks],
      type: :pos_integer,
      default: 100,
      validation: [min: 1],
      category: :task_history,
      sub_category: nil,
      description:
        "Maximum number of recent tasks retained in the dashboard history. Older tasks beyond this limit are automatically purged to manage storage. Each task represents one top-level Genesis run."
    },
    %{
      key_path: [:task_history, :max_age_days],
      type: :pos_integer,
      default: 14,
      validation: [min: 1],
      category: :task_history,
      sub_category: nil,
      description:
        "Maximum age in days for retained task history entries. Tasks older than this are automatically purged regardless of the max_tasks limit. Keeps the task history dashboard manageable."
    }
  ]

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Returns all configuration key schemas as a flat list of maps.

  Each schema map contains:
  - `:key_path` — the full path as a list of atoms
  - `:type` — the expected value type (`:pos_integer`, `:string`, `:atom`, etc.)
  - `:default` — the default value (or nil if none)
  - `:validation` — a keyword list of validation rules (`min:`, `max:`, `in:`)
  - `:category` — the top-level config category
  - `:sub_category` — sub-category within sandbox (`:resources` or `:process`); nil otherwise
  - `:description` — human-readable description string

  Calling this function also preloads all valid config atoms for safe use
  with `String.to_existing_atom/1` elsewhere.
  """
  @spec all_schemas() :: [schema_map()]
  def all_schemas do
    @schemas
  end

  @doc """
  Returns schemas grouped by category.

  The returned map has category atoms as keys and lists of schema maps as values.
  Useful for building category-grouped settings pages.

  ## Examples

      iex> schemas = EvoGit.Config.Schema.schemas_by_category()
      iex> Map.keys(schemas)
      [:scheduler, :llm, :user, :sandbox, :truncation, :task_history]
  """
  @spec schemas_by_category() :: %{category() => [schema_map()]}
  def schemas_by_category do
    @schemas
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
    Enum.reduce(@schemas, %{}, fn schema, acc ->
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
      Enum.flat_map(@schemas, fn schema ->
        case get_in(config, schema.key_path) do
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

  # ── Private: Rule Validation ────────────────────────────────────────

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

  defp error(key_path, message, value, rule) do
    %ValidationError{
      key_path: key_path,
      message: message,
      value: value,
      rule: rule
    }
  end
end
