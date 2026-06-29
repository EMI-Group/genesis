defmodule EvoDashWeb.SystemLive do
  @moduledoc """
  System page: scheduler and system controls (pause/resume, restart/stop),
  system self-check, plus usage guides and references (example config, CLI
  usage, FAQ, credentials).
  """
  use EvoDashWeb, :live_view

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
  #   -C, --concepts        Concept expansion seeds (repeatable, complex mode)
  """

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:system} config_status={@config_status}>
      <div class="flex items-center gap-5 mb-8 animate-fade-in-up mt-2">
        <div class="relative flex items-center justify-center size-16 rounded-2xl bg-gradient-to-br from-primary/20 to-primary/5 text-primary shadow-[0_8px_30px_rgb(0,0,0,0.04)] border border-primary/10">
          <.icon name="hero-server-stack" class="size-8" />
          <div class="absolute inset-0 rounded-2xl bg-primary/10 blur-xl -z-10"></div>
        </div>
        <div>
          <h1 class="text-3xl font-extrabold tracking-tight text-base-content">{gettext("System")}</h1>
          <p class="text-sm text-base-content/60 mt-1 font-medium">{gettext("Scheduler controls, system health, and usage guides")}</p>
        </div>
      </div>

      <!-- Scheduler Control banner -->
      <div class="bg-base-100 rounded-3xl shadow-sm border border-base-200/70 overflow-hidden animate-fade-in-up animation-delay-100 relative group mb-8">
        <div class="absolute inset-0 bg-gradient-to-r from-base-200/30 to-transparent pointer-events-none"></div>
        <div class="relative p-6 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-6 transition-all duration-300">
          <div class="flex items-center gap-5">
            <div class={[
              "p-4 rounded-2xl flex items-center justify-center transition-colors duration-500",
              if(@scheduler_paused, do: "bg-warning/15 text-warning shadow-[0_0_20px_rgba(251,189,35,0.15)]", else: "bg-success/15 text-success shadow-[0_0_20px_rgba(54,211,153,0.15)]")
            ]}>
              <.icon
                name={if @scheduler_paused, do: "hero-pause-circle", else: "hero-play-circle"}
                class={"size-8" <> if(!@scheduler_paused, do: " animate-pulse", else: "")}
              />
            </div>
            <div>
              <h2 class="text-xl font-bold tracking-tight mb-1">
                {if @scheduler_paused, do: gettext("Scheduler Paused"), else: gettext("Scheduler Active")}
              </h2>
              <p class="text-sm text-base-content/60 font-medium leading-relaxed max-w-lg">
                <%= if @scheduler_paused do %>
                  {gettext("Running agents continue. No new slots or agents will be granted until resumed.")}
                <% else %>
                  {gettext("Agents and slots are being granted normally.")}
                <% end %>
              </p>
            </div>
          </div>
          <button
            type="button"
            phx-click="toggle_pause"
            class={[
              "btn btn-lg rounded-2xl font-bold tracking-wide shadow-sm hover:shadow-md transition-all duration-300 border-none shrink-0",
              if(@scheduler_paused, do: "bg-success/20 hover:bg-success/30 text-success-content", else: "bg-warning/20 hover:bg-warning/30 text-warning-content")
            ]}
          >
            <.icon name={if @scheduler_paused, do: "hero-play", else: "hero-pause"} class="size-5 mr-2" />
            {if @scheduler_paused, do: gettext("Resume Scheduler"), else: gettext("Pause Scheduler")}
          </button>
        </div>
      </div>

      <!-- System Control section (destructive actions) -->
      <div class="bg-error/5 border border-error/20 rounded-3xl p-6 animate-fade-in-up animation-delay-100 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-6 shadow-sm mb-8">
        <div class="flex items-start gap-4">
          <div class="p-3 bg-error/15 text-error rounded-2xl shrink-0">
            <.icon name="hero-power" class="size-6" />
          </div>
          <div>
            <h2 class="text-xl font-bold tracking-tight text-error mb-1">
              {gettext("System Control")}
            </h2>
            <p class="text-sm text-base-content/60 font-medium leading-relaxed max-w-lg">
              {gettext("Gracefully restart or stop the Erlang VM. Restart tears down and restarts all applications; stop gracefully shuts down the VM and it must be started again manually. In-memory runtime state will be lost in both cases.")}
            </p>
          </div>
        </div>
        <div class="flex flex-col sm:flex-row gap-3 shrink-0">
          <button
            type="button"
            phx-click="request_restart"
            class="btn btn-lg rounded-2xl bg-error/15 hover:bg-error/25 text-error font-bold tracking-wide shadow-sm hover:shadow-md transition-all duration-300 border-none gap-2"
          >
            <.icon name="hero-arrow-path" class="size-5" />
            {gettext("Restart System")}
          </button>
          <button
            type="button"
            phx-click="request_stop"
            class="btn btn-lg rounded-2xl bg-error/15 hover:bg-error/25 text-error font-bold tracking-wide shadow-sm hover:shadow-md transition-all duration-300 border-none gap-2"
          >
            <.icon name="hero-power" class="size-5" />
            {gettext("Stop System")}
          </button>
        </div>
      </div>

      <!-- System Self-Check -->
      <div class="animate-fade-in-up animation-delay-150">
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
            <.system_check_row title={gettext("Sandbox")} icon="hero-lock-closed" status={sandbox_status(@sandbox_check)}>
              <:details>
                <div class="flex flex-wrap gap-2 items-center">
                  <span class={"badge badge-sm #{case @sandbox_check.backend do :systemd_run -> "badge-success"; :sandbox_exec -> "badge-info"; _ -> "badge-ghost" end}"}>
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
            <.system_check_row title={gettext("EvoX Genesis Process Tree")} icon="hero-server-stack" status={if @supervisor_check.healthy, do: :ok, else: :error}>
              <:details>
                <div class="space-y-1">
                  <.supervisor_status label={gettext("EvoGit")} children={@supervisor_check.evo_git} />
                  <.supervisor_status label={gettext("EvoDash")} children={@supervisor_check.evo_dash} />
                </div>
              </:details>
            </.system_check_row>

            <!-- LLM Test Row -->
            <.system_check_row title={gettext("LLM Connection")} icon="hero-chat-bubble-left-right" status={:info}>
              <:details>
                <div class="flex items-center gap-3">
                  <span class="text-sm text-base-content/60">{gettext("LLM connection testing is now available on the Settings page.")}</span>
                  <.link navigate={~p"/settings?category=llm"} class="btn btn-primary btn-sm gap-2">
                    <.icon name="hero-sparkles" class="size-4" />
                    {gettext("Test in Settings")}
                  </.link>
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

      <!-- Restart confirmation modal -->
      <%= if @show_restart_confirm do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="cancel_restart"></div>
          <div class="relative bg-base-100 rounded-3xl shadow-2xl border border-base-200 max-w-lg w-full p-6 md:p-8">
            <div class="flex items-center gap-3 mb-4">
              <div class="flex items-center justify-center size-10 rounded-2xl bg-error/15">
                <.icon name="hero-exclamation-triangle" class="size-5 text-error" />
              </div>
              <h3 class="text-lg font-bold">{gettext("Restart System?")}</h3>
            </div>

            <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
              {gettext("This will gracefully restart the Erlang VM. All applications will be torn down and restarted.")}
            </p>
            <p class="text-sm text-error/80 font-semibold mb-5 leading-relaxed">
              {gettext("All in-memory runtime state (running tasks, scheduler state, in-progress agents) will be lost. This cannot be undone.")}
            </p>

            <div class="flex justify-end gap-3 pt-2">
              <button type="button" class="btn btn-ghost rounded-full px-6" phx-click="cancel_restart">
                {gettext("Cancel")}
              </button>
              <button type="button" class="btn btn-error rounded-full px-6 gap-2" phx-click="confirm_restart">
                <.icon name="hero-arrow-path" class="size-4.5" />
                {gettext("Restart System")}
              </button>
            </div>
          </div>
        </div>
      <% end %>

      <!-- Stop confirmation modal -->
      <%= if @show_stop_confirm do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="cancel_stop"></div>
          <div class="relative bg-base-100 rounded-3xl shadow-2xl border border-base-200 max-w-lg w-full p-6 md:p-8">
            <div class="flex items-center gap-3 mb-4">
              <div class="flex items-center justify-center size-10 rounded-2xl bg-error/15">
                <.icon name="hero-exclamation-triangle" class="size-5 text-error" />
              </div>
              <h3 class="text-lg font-bold">{gettext("Stop System?")}</h3>
            </div>

            <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
              {gettext("This will gracefully shut down the Erlang VM. All applications will be stopped in order.")}
            </p>
            <p class="text-sm text-error/80 font-semibold mb-5 leading-relaxed">
              {gettext("The VM will stop and must be restarted manually. All in-memory runtime state (running tasks, scheduler state, in-progress agents) will be lost. This cannot be undone.")}
            </p>

            <div class="flex justify-end gap-3 pt-2">
              <button type="button" class="btn btn-ghost rounded-full px-6" phx-click="cancel_stop">
                {gettext("Cancel")}
              </button>
              <button type="button" class="btn btn-error rounded-full px-6 gap-2" phx-click="confirm_stop">
                <.icon name="hero-power" class="size-4.5" />
                {gettext("Stop System")}
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "scheduler_config")
    end

    system_checks = safe_system_checks()

    config_dir = EvoGit.Platform.config_dir()
    config_path = Path.join(config_dir, "config.toml")
    credentials_path = Path.join(config_dir, "credentials.toml")

    socket =
      socket
      |> assign(:scheduler_paused, load_paused_state())
      |> assign(:show_restart_confirm, false)
      |> assign(:show_stop_confirm, false)
      |> assign(:config_status, system_checks.config)
      |> assign(:tool_check, system_checks.tools)
      |> assign(:sandbox_check, system_checks.sandbox)
      |> assign(:supervisor_check, system_checks.supervisor)
      |> assign(:config_dir, config_dir)
      |> assign(:config_path, config_path)
      |> assign(:credentials_path, credentials_path)
      |> assign(
        :config_reference,
        String.replace(@config_reference, "__CONFIG_PATH__", config_path)
      )
      |> assign(
        :credentials_reference,
        String.replace(@credentials_reference, "__CREDENTIALS_PATH__", credentials_path)
      )
      |> assign(:usage_reference, @usage_reference)
      |> assign(:faq_content, faq_content(config_path, credentials_path))

    {:ok, socket}
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
  def handle_event("toggle_pause", _params, socket) do
    if socket.assigns.scheduler_paused do
      EvoGit.AgentScheduler.resume()

      {:noreply,
       socket
       |> assign(:scheduler_paused, false)
       |> put_flash(:info, gettext("Scheduler resumed. New agents and slots are being granted."))}
    else
      EvoGit.AgentScheduler.pause()

      {:noreply,
       socket
       |> assign(:scheduler_paused, true)
       |> put_flash(
         :info,
         gettext(
           "Scheduler paused. Running agents continue, but no new slots or agents will be granted."
         )
       )}
    end
  end

  @impl true
  def handle_event("request_restart", _params, socket) do
    {:noreply, assign(socket, :show_restart_confirm, true)}
  end

  @impl true
  def handle_event("cancel_restart", _params, socket) do
    {:noreply, assign(socket, :show_restart_confirm, false)}
  end

  @impl true
  def handle_event("confirm_restart", _params, socket) do
    # Spawn a short-lived process so this LiveView can finish replying (and the
    # browser can close the modal) before the VM tears down. System.restart/0
    # gracefully restarts the BEAM runtime — all applications are stopped and
    # started again. It does NOT shut down the host OS.
    spawn(fn ->
      Process.sleep(150)
      System.restart()
    end)

    {:noreply,
     socket
     |> assign(:show_restart_confirm, false)
     |> put_flash(
       :info,
       gettext("System is restarting. Please wait while the Erlang VM comes back up.")
     )}
  end

  @impl true
  def handle_event("request_stop", _params, socket) do
    {:noreply, assign(socket, :show_stop_confirm, true)}
  end

  @impl true
  def handle_event("cancel_stop", _params, socket) do
    {:noreply, assign(socket, :show_stop_confirm, false)}
  end

  @impl true
  def handle_event("confirm_stop", _params, socket) do
    # Spawn a short-lived process so this LiveView can finish replying (and the
    # browser can close the modal) before the VM shuts down. System.stop/0
    # gracefully shuts down the BEAM runtime — all applications are stopped in
    # order and the VM exits. It does NOT affect the host OS, but the VM will
    # need to be started again manually.
    spawn(fn ->
      Process.sleep(150)
      System.stop()
    end)

    {:noreply,
     socket
     |> assign(:show_stop_confirm, false)
     |> put_flash(
       :info,
       gettext(
         "System is stopping. The Erlang VM will shut down and must be started again manually."
       )
     )}
  end

  @impl true
  def handle_info({:scheduler_config_updated}, socket) do
    {:noreply, assign(socket, :scheduler_paused, load_paused_state())}
  end

  # --- Private Helpers ---

  defp load_paused_state do
    try do
      EvoGit.AgentScheduler.get_config()[:paused] || false
    rescue
      _ -> false
    catch
      _, _ -> false
    end
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
        <%= if Enum.empty?(@children) || Enum.all?(@children, &(&1.status == :running)) do %>
          <span class="text-xs text-base-content/40">{gettext("All healthy")}</span>
        <% else %>
          <%= for child <- @children, child.status != :running do %>
            <span class="badge badge-sm badge-error">
              <.icon name="hero-x-mark" class="size-3" />
              {child.id}
            </span>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Private Helper Functions ---

  # Build FAQ content at runtime so the platform-specific config/credentials paths
  # can be interpolated into the gettext strings.
  defp faq_content(config_path, credentials_path) do
    [
      {gettext("How do I set my API key?"),
       gettext(
         "Create a credentials.toml file at %{path} with your API key. Only one key is required — set the one matching your LLM provider (e.g., GOOGLE_API_KEY for Google Gemini). Alternatively, you can set API keys directly as environment variables (e.g., export GOOGLE_API_KEY=AIza...).",
         path: credentials_path
       )},
      {gettext("How do I change the LLM model?"),
       gettext(
         "Edit your config.toml file at %{path} and set the model field under [llm] (e.g., model = \"anthropic:claude-sonnet-4-20250514\"). You can also adjust the model temporarily from the Settings page in the dashboard.",
         path: config_path
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
  end

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

  # Determine sandbox overall status
  defp sandbox_status(%{backend: :systemd_run} = check) do
    if check.systemd_available && check.capabilities.filesystem_isolation &&
         check.capabilities.resource_limits do
      :ok
    else
      :error
    end
  end

  defp sandbox_status(%{backend: :sandbox_exec} = check) do
    if check.sandbox_exec_available && check.capabilities.filesystem_isolation do
      :ok
    else
      :error
    end
  end

  defp sandbox_status(%{backend: :none}), do: :info
  defp sandbox_status(_), do: :error

  # Format backend name
  defp format_backend(:systemd_run), do: "systemd-run (Linux)"
  defp format_backend(:sandbox_exec), do: "sandbox-exec (macOS)"
  defp format_backend(:none), do: gettext("None")

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
