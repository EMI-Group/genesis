defmodule EvoDashWeb.HelpLive do
  use EvoDashWeb, :live_view

  @config_reference """
  # EvoGit Configuration Reference
  # Save this as: ~/.config/evogit/config.toml

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
  # REQUIRED: LLM model identifier (format: "provider:model")
  # Examples:
  #   "anthropic:claude-sonnet-4-20250514"
  #   "google:gemini-2.0-flash-exp"
  #   "zai_coding_plan:glm-5.1"
  model = "your-model-here"
  # Token count threshold for context compression
  compression_threshold_tokens = 100_000

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
  # EvoGit Credentials Reference
  # Save this as: ~/.config/evogit/credentials.toml
  # 
  # API keys are stored separately from config.toml for security.
  # Only ONE key is required — choose the provider matching your LLM model.
  # Keys are set as environment variables on load.

  # Google Gemini (e.g., "google:gemini-2.0-flash-exp")
  GOOGLE_API_KEY = "AIza..."

  # ZAI (e.g., "zai_coding_plan:glm-5.1")
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
  #   -R name:/path         Foreign repository (repeatable)
  #   -C, --concepts        Concept expansion seeds (repeatable, complex mode)
  """

  @faq_content [
    {gettext("How do I set my API key?"),
     gettext(
       "Create a credentials.toml file at ~/.config/evogit/credentials.toml with your API key. Only one key is required — set the one matching your LLM provider (e.g., GOOGLE_API_KEY for Google Gemini). Alternatively, you can set API keys directly as environment variables (e.g., export GOOGLE_API_KEY=AIza...)."
     )},
    {gettext("How do I change the LLM model?"),
     gettext(
       "Edit your config.toml file at ~/.config/evogit/config.toml and set the model field under [llm] (e.g., model = \"anthropic:claude-sonnet-4-20250514\"). You can also adjust the model temporarily from the Settings page in the dashboard."
     )},
    {gettext("What is sandbox mode?"),
     gettext(
       "Sandbox mode controls how EvoGit isolates LLM-generated code. On Linux, it uses systemd-run for full sandboxing (filesystem isolation, resource limits, syscall filtering). On macOS, it uses sandbox-exec for filesystem isolation only. \"auto\" enables the appropriate backend for your platform. \"enabled\" forces sandboxing on. \"disabled\" turns it off entirely — use with caution. Resource limits (Linux only) can be configured in config.toml under [sandbox.resources] and [sandbox.process]."
     )},
    {gettext("How does the context tree work?"),
     gettext(
       "EvoGit models your codebase as a hierarchical Context Tree. Each directory has a CONTEXT.md file that acts as a spatial contract — documenting its purpose, API surface, constraints, and routing to child directories. Agents read these files to understand the codebase structure and route work to the appropriate subdirectories."
     )},
    {gettext("What happens if my config is missing?"),
     gettext(
       "EvoGit uses built-in defaults for most settings, so a config file is not strictly required. However, an LLM model and a matching API key are essential to run tasks. The config status indicator at the top of this page shows whether all critical values are set. You can also check from the Settings page."
     )},
    {gettext("How do I configure sandbox resources?"),
     gettext(
       "Sandbox resource limits can be set in your config.toml under the [sandbox.resources] section (aggregate limits) and [sandbox.process] section (per-process limits). Resource limits are only available on Linux with systemd-run. On macOS, sandbox-exec provides filesystem isolation only. You can adjust settings from the Settings page in the dashboard."
     )}
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:help} config_status={@config_status}>
      <div class="flex items-center gap-4 mb-4 animate-fade-in-up">
        <div class="bg-accent/15 text-accent p-3.5 rounded-2xl">
          <.icon name="hero-question-mark-circle" class="size-6" />
        </div>
        <div>
          <h1 class="text-2xl font-bold">{gettext("Help")}</h1>
          <p class="text-sm text-base-content/60 mt-1">{gettext("Guides, references, and frequently asked questions")}</p>
        </div>
      </div>

      <!-- Config Status -->
      <div class="mt-4 animate-fade-in-up animation-delay-100">
        <.config_status_badge status={@config_status} />
      </div>

      <!-- System Dashboard -->
      <div class="mt-4 animate-fade-in-up animation-delay-150">
        <.link navigate={~p"/dashboard"} class="block">
          <div class="bg-base-100 rounded-3xl shadow-sm border border-base-200/60 hover:border-primary/40 hover:shadow-md transition-all duration-200 p-5 md:p-6">
            <div class="flex items-center gap-4">
              <div class="bg-info/15 text-info p-3.5 rounded-2xl">
                <.icon name="hero-chart-bar" class="size-5" />
              </div>
              <div class="flex-1">
                <h3 class="font-semibold text-base">{gettext("System Dashboard")}</h3>
                <p class="text-sm text-base-content/60 mt-0.5">{gettext("View system metrics, processes, and application telemetry")}</p>
              </div>
              <.icon name="hero-arrow-right" class="size-5 text-base-content/30" />
            </div>
          </div>
        </.link>
      </div>

      <!-- Example Configuration -->
      <div class="mt-6 animate-fade-in-up animation-delay-200">
        <.collapsible_card id="config-reference" title={gettext("Example Configuration")} icon="hero-book-open" color={:info}>
          <pre class="text-sm font-mono bg-base-200/40 rounded-2xl p-5 border border-base-200/60 whitespace-pre-wrap break-words max-h-[500px] overflow-y-auto">{@config_reference}</pre>
        </.collapsible_card>
      </div>

      <!-- Example Usage -->
      <div class="mt-6 animate-fade-in-up animation-delay-300">
        <.collapsible_card id="usage-reference" title={gettext("Example Usage")} icon="hero-command-line" color={:success}>
          <pre class="text-sm font-mono bg-base-200/40 rounded-2xl p-5 border border-base-200/60 whitespace-pre-wrap break-words max-h-[500px] overflow-y-auto">{@usage_reference}</pre>
        </.collapsible_card>
      </div>

      <!-- FAQ -->
      <div class="mt-6 animate-fade-in-up animation-delay-400">
        <.collapsible_card id="faq" title={gettext("Frequently Asked Questions")} icon="hero-question-mark-circle" color={:accent}>
          <div class="space-y-4">
            <%= for {{question, answer}, idx} <- Enum.with_index(@faq_content) do %>
              <details class={"group rounded-2xl border border-base-200/60 overflow-hidden bg-base-100/50"}>
                <summary class="flex items-center gap-3 px-5 py-4 cursor-pointer select-none hover:bg-base-200/50 transition-colors list-none">
                  <.icon name="hero-chevron-down" class="size-4.5 shrink-0 text-base-content/50 transition-transform duration-200 group-open:rotate-180" />
                  <span class="font-semibold text-sm">{question}</span>
                </summary>
                <div class="px-5 py-4 text-sm text-base-content/70 leading-relaxed border-t border-base-200/60">
                  <p id={"faq-answer-#{idx}"}>{answer}</p>
                </div>
              </details>
            <% end %>
          </div>
        </.collapsible_card>
      </div>

      <!-- Credentials Reference -->
      <div class="mt-6 animate-fade-in-up animation-delay-500">
        <.collapsible_card id="credentials-reference" title={gettext("Credentials Reference")} icon="hero-key" color={:accent}>
          <pre class="text-sm font-mono bg-base-200/40 rounded-2xl p-5 border border-base-200/60 whitespace-pre-wrap break-words max-h-[500px] overflow-y-auto">{@credentials_reference}</pre>
          <div class="mt-4 space-y-2">
            <p class="text-sm text-base-content/60 flex items-start gap-2.5">
              <.icon name="hero-arrows-right-left" class="size-4.5 shrink-0 mt-0.5" />
              <span>{gettext("Keys from credentials.toml are loaded as environment variables on startup. You can also set API keys directly via environment variables (e.g., GOOGLE_API_KEY).")}</span>
            </p>
            <p class="text-sm text-base-content/60 flex items-start gap-2.5">
              <.icon name="hero-shield-check" class="size-4.5 shrink-0 mt-0.5" />
              <span>{gettext("For security, credentials cannot be edited from this page. Edit the file directly on your system.")}</span>
            </p>
          </div>
        </.collapsible_card>
      </div>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    config_status = safe_config_status()

    socket =
      socket
      |> assign(:config_status, config_status)
      |> assign(:config_reference, @config_reference)
      |> assign(:credentials_reference, @credentials_reference)
      |> assign(:usage_reference, @usage_reference)
      |> assign(:faq_content, @faq_content)

    {:ok, socket}
  end

  defp safe_config_status do
    try do
      EvoGit.Config.config_status()
    rescue
      _ -> %{missing: [], warnings: [], ok?: true}
    catch
      _, _ -> %{missing: [], warnings: [], ok?: true}
    end
  end
end
