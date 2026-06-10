defmodule EvoDashWeb.HelpLive do
  use EvoDashWeb, :live_view

  @config_reference """
  # Genesis Configuration Reference
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
  #   "zai:glm-5.1"
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
  # Genesis Credentials Reference
  # Save this as: ~/.config/evogit/credentials.toml
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
       "Sandbox mode controls how EvoX Genesis isolates LLM-generated code. On Linux, it uses systemd-run for full sandboxing (filesystem isolation, resource limits, syscall filtering). On macOS, it uses sandbox-exec for filesystem isolation only. \"auto\" enables the appropriate backend for your platform. \"enabled\" forces sandboxing on. \"disabled\" turns it off entirely — use with caution. Resource limits (Linux only) can be configured in config.toml under [sandbox.resources] and [sandbox.process]."
     )},
    {gettext("How does the context tree work?"),
     gettext(
       "EvoX Genesis models your codebase as a hierarchical Context Tree. Each directory has a CONTEXT.md file that acts as a spatial contract — documenting its purpose, API surface, constraints, and routing to child directories. Agents read these files to understand the codebase structure and route work to the appropriate subdirectories."
     )},
    {gettext("What happens if my config is missing?"),
     gettext(
       "Genesis uses built-in defaults for most settings, so a config file is not strictly required. However, an LLM model and a matching API key are essential to run tasks. The config status indicator at the top of this page shows whether all critical values are set. You can also check from the Settings page."
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

      <!-- System Self-Check -->
      <div class="mt-4 animate-fade-in-up animation-delay-100">
        <div class="bg-base-100 rounded-3xl shadow-sm border border-base-200/60 p-5 md:p-6">
          <div class="flex items-center justify-between mb-4">
            <div class="flex items-center gap-3">
              <div class="bg-success/15 text-success p-3 rounded-2xl">
                <.icon name="hero-shield-check" class="size-5" />
              </div>
              <div>
                <h2 class="font-bold text-lg">{gettext("System Self-Check")}</h2>
                <p class="text-sm text-base-content/60">{gettext("System status and health overview")}</p>
              </div>
            </div>
            <button phx-click="rerun_checks" class="btn btn-ghost btn-sm gap-2">
              <.icon name="hero-arrow-path" class="size-4" />
              {gettext("Re-check")}
            </button>
          </div>

          <div class="space-y-3">
            <!-- Config Status Row -->
            <.system_check_row title={gettext("Configuration")} icon="hero-cog-6-tooth" status={if @config_status.ok?, do: :ok, else: :error}>
              <:details>
                <%= if @config_status.ok? do %>
                  <span class="text-sm text-success">{gettext("All configured")}</span>
                <% else %>
                  <div class="flex flex-wrap gap-1.5">
                    <%= for item <- @config_status.missing do %>
                      <span class="badge badge-warning badge-sm gap-1">
                        <.icon name="hero-x-mark" class="size-3" />
                        {format_config_item(item)}
                      </span>
                    <% end %>
                  </div>
                <% end %>
                <%= if @config_status[:validation_errors] != [] and @config_status[:validation_errors] != nil do %>
                  <div class="mt-1 text-xs text-warning">
                    {ngettext("%{count} validation warning", "%{count} validation warnings", length(@config_status.validation_errors))}
                  </div>
                <% end %>
              </:details>
            </.system_check_row>

            <!-- Tools Row -->
            <.system_check_row title={gettext("Required Tools")} icon="hero-wrench-screwdriver" status={tools_status(@tool_check)}>
              <:details>
                <div class="flex flex-wrap gap-3">
                  <.tool_badge name="git" check={@tool_check.git} />
                  <.tool_badge name="rg (ripgrep)" check={@tool_check.rg} />
                </div>
              </:details>
            </.system_check_row>

            <!-- Sandbox Row -->
            <.system_check_row title={gettext("Sandbox")} icon="hero-lock-closed" status={:info}>
              <:details>
                <div class="flex flex-wrap gap-2 items-center">
                  <span class="badge badge-sm {sandbox_badge_color(@sandbox_check)}">
                    {format_backend(@sandbox_check.backend)}
                  </span>
                  <span class="text-sm text-base-content/60">
                    {if @sandbox_check.enabled, do: gettext("Enabled"), else: gettext("Disabled")}
                  </span>
                  <%= if @sandbox_check.backend != :none do %>
                    <span class="text-xs text-base-content/40">
                      {gettext("Filesystem isolation")}: {if @sandbox_check.capabilities.filesystem_isolation, do: "✓", else: "✗"}
                      · {gettext("Resource limits")}: {if @sandbox_check.capabilities.resource_limits, do: "✓", else: "✗"}
                    </span>
                  <% end %>
                </div>
              </:details>
            </.system_check_row>

            <!-- Supervisor Row -->
            <.system_check_row title={gettext("Supervision Tree")} icon="hero-server-stack" status={if @supervisor_check.healthy, do: :ok, else: :error}>
              <:details>
                <div class="space-y-1">
                  <.supervisor_status label="EvoGit" children={@supervisor_check.evo_git} />
                  <.supervisor_status label="EvoDash" children={@supervisor_check.evo_dash} />
                </div>
              </:details>
            </.system_check_row>

            <!-- LLM Test Row -->
            <.system_check_row title={gettext("LLM Connection")} icon="hero-chat-bubble-left-right" status={llm_status_icon(@llm_test_status)}>
              <:details>
                <div class="flex items-center gap-3">
                  <%= case @llm_test_status do %>
                    <% :idle -> %>
                      <span class="text-sm text-base-content/60">{gettext("Not tested — click to verify LLM connectivity")}</span>
                      <button phx-click="test_llm" class="btn btn-primary btn-sm gap-2">
                        <.icon name="hero-signal" class="size-4" />
                        {gettext("Test Connection")}
                      </button>
                    <% :testing -> %>
                      <span class="loading loading-spinner loading-sm text-primary"></span>
                      <span class="text-sm text-base-content/60">{gettext("Testing LLM connection...")}</span>
                    <% {:ok, data} -> %>
                      <.icon name="hero-check-circle" class="size-5 text-success" />
                      <span class="text-sm text-success">{gettext("Connected")}</span>
                      <span class="text-xs text-base-content/40">({data.model})</span>
                      <span class="text-xs text-base-content/50 bg-base-200/50 px-2 py-0.5 rounded">"{truncate_string(data.response, 50)}"</span>
                      <button phx-click="test_llm" class="btn btn-ghost btn-xs gap-1 ml-2">
                        <.icon name="hero-arrow-path" class="size-3" />
                        {gettext("Retest")}
                      </button>
                    <% {:error, reason} -> %>
                      <.icon name="hero-x-circle" class="size-5 text-error" />
                      <span class="text-sm text-error">{reason}</span>
                      <button phx-click="test_llm" class="btn btn-ghost btn-xs gap-1 ml-2">
                        <.icon name="hero-arrow-path" class="size-3" />
                        {gettext("Retry")}
                      </button>
                  <% end %>
                </div>
              </:details>
            </.system_check_row>
          </div>
        </div>
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
    system_checks = safe_system_checks()

    socket =
      socket
      |> assign(:config_status, system_checks.config)
      |> assign(:tool_check, system_checks.tools)
      |> assign(:sandbox_check, system_checks.sandbox)
      |> assign(:supervisor_check, system_checks.supervisor)
      |> assign(:llm_test_status, :idle)
      |> assign(:config_reference, @config_reference)
      |> assign(:credentials_reference, @credentials_reference)
      |> assign(:usage_reference, @usage_reference)
      |> assign(:faq_content, @faq_content)

    {:ok, socket}
  end

  @impl true
  def handle_event("test_llm", _params, socket) do
    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = EvoGit.SystemCheck.llm_test()
      send(self(), {:llm_test_result, result})
    end)

    {:noreply, assign(socket, :llm_test_status, :testing)}
  end

  @impl true
  def handle_event("rerun_checks", _params, socket) do
    system_checks = safe_system_checks()

    socket =
      socket
      |> assign(:config_status, system_checks.config)
      |> assign(:tool_check, system_checks.tools)
      |> assign(:sandbox_check, system_checks.sandbox)
      |> assign(:supervisor_check, system_checks.supervisor)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:llm_test_result, result}, socket) do
    status =
      case result do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end

    {:noreply, assign(socket, :llm_test_status, status)}
  end

  # --- Private Components ---

  attr(:title, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:status, :atom, default: :ok)
  slot(:details, required: true)

  defp system_check_row(assigns) do
    ~H"""
    <div class="flex items-start gap-3 py-3 border-b border-base-200/40 last:border-0">
      <div class={"p-2 rounded-xl #{status_bg(@status)}"}>
        <.icon name={@icon} class={"size-4 #{status_text(@status)}"} />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 mb-1">
          <span class="font-semibold text-sm">{@title}</span>
          <%= case @status do %>
            <% :ok -> %><.icon name="hero-check-circle-solid" class="size-4 text-success" />
            <% :error -> %><.icon name="hero-x-circle-solid" class="size-4 text-error" />
            <% :info -> %><.icon name="hero-information-circle-solid" class="size-4 text-info" />
            <% :warning -> %><.icon name="hero-exclamation-triangle-solid" class="size-4 text-warning" />
          <% end %>
        </div>
        {render_slot(@details)}
      </div>
    </div>
    """
  end

  attr(:name, :string, required: true)
  attr(:check, :map, required: true)

  defp tool_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <%= if @check.available do %>
        <.icon name="hero-check-circle" class="size-4 text-success" />
        <span class="text-sm">{@name}</span>
        <span class="text-xs text-base-content/40">{@check.version}</span>
      <% else %>
        <.icon name="hero-x-circle" class="size-4 text-error" />
        <span class="text-sm text-error">{@name}</span>
        <span class="text-xs text-error/60">{@check.error}</span>
      <% end %>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:children, :list, required: true)

  defp supervisor_status(assigns) do
    ~H"""
    <div class="flex items-center gap-2 text-sm">
      <span class="font-medium text-base-content/70">{@label}:</span>
      <div class="flex flex-wrap gap-1.5">
        <%= for child <- @children do %>
          <span class={"badge badge-sm #{if child.status == :running, do: "badge-success", else: "badge-error"}"}>
            <%= if child.status == :running do %>
              <.icon name="hero-check" class="size-3" />
            <% else %>
              <.icon name="hero-x-mark" class="size-3" />
            <% end %>
            {child.id}
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Private Helper Functions ---

  # Status background colors for system_check_row
  defp status_bg(:ok), do: "bg-success/10"
  defp status_bg(:error), do: "bg-error/10"
  defp status_bg(:info), do: "bg-info/10"
  defp status_bg(:warning), do: "bg-warning/10"
  defp status_bg(_), do: "bg-base-200/50"

  # Status text colors for system_check_row icon
  defp status_text(:ok), do: "text-success"
  defp status_text(:error), do: "text-error"
  defp status_text(:info), do: "text-info"
  defp status_text(:warning), do: "text-warning"
  defp status_text(_), do: "text-base-content/50"

  # Determine tools overall status
  defp tools_status(%{git: %{available: true}, rg: %{available: true}}), do: :ok
  defp tools_status(%{git: %{available: false}}), do: :error
  defp tools_status(%{rg: %{available: false}}), do: :error
  defp tools_status(_), do: :warning

  # LLM test status to icon status
  defp llm_status_icon(:idle), do: :info
  defp llm_status_icon(:testing), do: :info
  defp llm_status_icon({:ok, _}), do: :ok
  defp llm_status_icon({:error, _}), do: :error

  # Sandbox badge color
  defp sandbox_badge_color(%{backend: :systemd_run}), do: "badge-success"
  defp sandbox_badge_color(%{backend: :sandbox_exec}), do: "badge-info"
  defp sandbox_badge_color(_), do: "badge-ghost"

  # Format backend name
  defp format_backend(:systemd_run), do: "systemd-run (Linux)"
  defp format_backend(:sandbox_exec), do: "sandbox-exec (macOS)"
  defp format_backend(:none), do: gettext("None")

  # Truncate string helper
  defp truncate_string(nil, _len), do: ""
  defp truncate_string(str, len) when byte_size(str) > len, do: String.slice(str, 0, len) <> "..."
  defp truncate_string(str, _len), do: str

  # Format config item names
  defp format_config_item(:llm_model), do: gettext("LLM Model")
  defp format_config_item(:api_key), do: gettext("API Key")
  defp format_config_item(:github_username), do: gettext("GitHub Username")
  defp format_config_item(item) do
    item |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp safe_system_checks do
    try do
      EvoGit.SystemCheck.run_all_checks()
    rescue
      e ->
        %{
          config: %{missing: [], warnings: [], ok?: true, validation_errors: []},
          tools: %{
            git: %{available: false, path: nil, version: nil, error: inspect(e)},
            rg: %{available: false, path: nil, version: nil, error: inspect(e)}
          },
          sandbox: %{
            backend: :none,
            enabled: false,
            capabilities: %{filesystem_isolation: false, resource_limits: false, backend: :none},
            systemd_available: false,
            sandbox_exec_available: false
          },
          supervisor: %{evo_git: [], evo_dash: [], healthy: false}
        }
    catch
      _, _ ->
        %{
          config: %{missing: [], warnings: [], ok?: true, validation_errors: []},
          tools: %{
            git: %{available: false, path: nil, version: nil, error: "Unknown error"},
            rg: %{available: false, path: nil, version: nil, error: "Unknown error"}
          },
          sandbox: %{
            backend: :none,
            enabled: false,
            capabilities: %{filesystem_isolation: false, resource_limits: false, backend: :none},
            systemd_available: false,
            sandbox_exec_available: false
          },
          supervisor: %{evo_git: [], evo_dash: [], healthy: false}
        }
    end
  end

end
