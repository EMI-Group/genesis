defmodule EvoDashWeb.SettingsLive.HelpContent do
  @moduledoc """
  Static content helpers for the `:help` pseudo-category on the Settings page.

  Provides the example configuration, credentials, and usage reference
  strings (with path interpolation) and the runtime-built FAQ content list.
  These are pure functions with no LiveView state.

  Ported from the retired `/system` page (`EvoDashWeb.SystemLive.Content`).
  """

  use Gettext, backend: EvoDashWeb.Gettext

  @config_reference """
  # Genesis Configuration Reference
  # Save this as: __CONFIG_PATH__

  [scheduler]
  # Maximum concurrent LLM calls
  max_concurrency = 3
  # Maximum concurrent tool executions
  max_tool_concurrency = 2
  # Crash-retries per agent
  agent_max_retries = 3
  # Maximum subagent recursion depth
  max_agent_depth = 8
  # LLM API call retries
  max_retries = 15

  [llm]
  # Token count threshold for context compression
  compression_threshold_tokens = 100_000

  # Model profiles — define one or more [[llm.models]] entries.
  # The first profile is the default. Each task can select a profile
  # via the dashboard task form's Model dropdown or the runtime :model_id opt.
  [[llm.models]]
  id = "default"
  # LLM model identifier (format: "provider:model")
  # Examples:
  #   "anthropic:claude-sonnet-4-20250514"
  #   "google:gemini-2.0-flash-exp"
  #   "zai:glm-5.1"
  model = "your-model-here"
  concurrency = 3

  [user]
  # Your GitHub username (used for commit co-authoring)
  github_username = "your-username"

  [task_history]
  # Maximum number of finished tasks to keep
  max_tasks = 100
  # Maximum age in days for finished tasks (whichever limit is smaller is applied)
  max_age_days = 14

  [sandbox]
  # Sandbox mode: "auto" | "enabled" | "disabled"
  mode = "auto"

  [sandbox.resources]
  # Slice-level limits (aggregate across all processes)
  cpu_quota = "1000%"
  cpu_weight = 30
  memory_max = "16G"
  tasks_max = 8196

  [sandbox.process]
  # Per-process limits (each tool call)
  cpu_quota = "800%"
  memory_max = "12G"
  limit_nofile = 65536
  oom_score_adjust = 1000
  """

  @credentials_reference """
  # Genesis Credentials Reference
  # Save this as: __CREDENTIALS_PATH__
  #
  # API keys are stored separately from config.toml for security.
  # Only ONE key is required — choose the provider matching your LLM model.
  # Keys are set as environment variables on load.

  # Google Gemini (e.g., "google:gemini-2.0-flash-exp")
  GOOGLE_API_KEY = "AIza..."

  # ZAI (e.g., "zai:glm-5.1")
  ZAI_API_KEY = "sk-..."

  # DeepSeek (e.g., "deepseek:deepseek-chat")
  DEEPSEEK_API_KEY = "sk-..."

  # Groq (e.g., "groq:llama-3.1-8b-instant")
  GROQ_API_KEY = "gsk_..."

  # Anthropic (e.g., "anthropic:claude-sonnet-4-20250514")
  ANTHROPIC_API_KEY = "sk-ant-..."

  # OpenAI (e.g., "openai:gpt-4o")
  OPENAI_API_KEY = "sk-..."

  # Tavily (optional — for web search tool)
  TAVILY_API_KEY = "tvly-..."
  """

  @usage_reference """
  # Genesis — Create a new codebase from a prompt
  mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis "Build a REST API for task management"

  # Genesis — Analyze an existing codebase
  mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis "Analyze and document this project" -p /path/to/project

  # Evolution — Modify an existing codebase
  mix run -e 'EvoGit.CLI.main(System.argv())' -- evolve "Add authentication with JWT tokens"

  # With concurrency control
  mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis "Build a web scraper" -c 5

  # With foreign repositories
  mix run -e 'EvoGit.CLI.main(System.argv())' -- evolve "Fix the login bug" -R original:/path/to/repo

  # Common flags:
  #   -c, --concurrency     Max parallel LLM calls (default: 3)
  #   --tool-concurrency    Max parallel tool executions (default: 2)
  #   -p, --path            Target project path
  #   -R <id:>path         Foreign repository (repeatable)
  """

  @doc """
  Returns the example configuration reference string with the given config
  path interpolated in place of the `__CONFIG_PATH__` placeholder.
  """
  def config_reference(config_path) do
    String.replace(@config_reference, "__CONFIG_PATH__", config_path)
  end

  @doc """
  Returns the credentials reference string with the given credentials path
  interpolated in place of the `__CREDENTIALS_PATH__` placeholder.
  """
  def credentials_reference(credentials_path) do
    String.replace(@credentials_reference, "__CREDENTIALS_PATH__", credentials_path)
  end

  @doc """
  Returns the CLI usage reference string (no interpolation needed).
  """
  def usage_reference do
    @usage_reference
  end

  @doc """
  Builds the FAQ content as a list of `{question, answer}` tuples.

  The platform-specific config and credentials paths are interpolated into the
  gettext strings at runtime.
  """
  def faq_content(config_path, credentials_path) do
    [
      {
        gettext("How do I set my API key?"),
        # GENESIS_TERM: LLM Provider → 服务商
        gettext(
          "Create a credentials.toml file at %{path} with your API key. Only one key is required — set the one matching your LLM provider (e.g., GOOGLE_API_KEY for Google Gemini). Alternatively, you can set API keys directly as environment variables (e.g., export GOOGLE_API_KEY=AIza...).",
          path: credentials_path
        )
      },
      {gettext("How do I change the LLM model?"),
       gettext(
         "Edit your config.toml file at %{path} and set the model field in a [[llm.models]] profile (e.g., model = \"anthropic:claude-sonnet-4-20250514\"). You can define multiple profiles and select one per task from the dashboard's Model dropdown. You can also adjust the model temporarily from the Settings page in the dashboard.",
         path: config_path
       )},
      # GENESIS_TERM: Sandbox → 沙箱, Genesis → 启元
      {gettext("What is sandbox mode?"),
       gettext(
         "Sandbox mode controls how EvoX Genesis isolates LLM-generated code. On Linux, it uses systemd-run for full sandboxing (filesystem isolation, resource limits, syscall filtering). On macOS, it uses sandbox-exec for filesystem isolation only. \"auto\" enables the appropriate backend for your platform. \"enabled\" forces sandboxing on. \"disabled\" turns it off entirely — use with caution. Resource limits (Linux only) can be configured in config.toml under [sandbox.resources] and [sandbox.process]."
       )},
      # GENESIS_TERM: Context Tree → 上下文树, Genesis → 启元, Agent → 智能体
      {gettext("How does the context tree work?"),
       gettext(
         "EvoX Genesis models your codebase as a hierarchical Context Tree. Each directory has a CONTEXT.md file that acts as a spatial contract — documenting its purpose, API surface, constraints, and routing to child directories. Agents read these files to understand the codebase structure and route work to the appropriate subdirectories."
       )},
      # GENESIS_TERM: Genesis → 启元
      {gettext("What happens if my config is missing?"),
       gettext(
         "Genesis uses built-in defaults for most settings, so a config file is not strictly required. However, an LLM model and a matching API key are essential to run tasks. The config status indicator at the top of this page shows whether all critical values are set. You can also check from the Settings page."
       )},
      # GENESIS_TERM: Sandbox → 沙箱
      {gettext("How do I configure sandbox resources?"),
       gettext(
         "Sandbox resource limits can be set in your config.toml under the [sandbox.resources] section (aggregate limits) and [sandbox.process] section (per-process limits). Resource limits are only available on Linux with systemd-run. On macOS, sandbox-exec provides filesystem isolation only. You can adjust settings from the Settings page in the dashboard."
       )}
    ]
  end
end
