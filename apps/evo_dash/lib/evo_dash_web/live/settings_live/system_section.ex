defmodule EvoDashWeb.SettingsLive.SystemSection do
  @moduledoc """
  Function components and status helpers for the `:system` and `:help`
  pseudo-categories on the Settings page.

  Ported from the retired standalone `/system` page (`SystemLive`): scheduler
  pause/resume, destructive system controls (restart/stop the Erlang VM with
  confirmation modals), the system self-check rows, and the static
  guides/references (example config, CLI usage, FAQ, credentials).

  Status helpers (`config_ok?/1`, `tools_status/1`, ...) are pure functions
  that derive overall status (`:ok` / `:error` / `:info` / `:warning`) from
  the system-check result maps.

  # zh_CN glossary translations used in this file:
  #   Scheduler → 调度器
  #   Agent → 智能体
  #   Graceful restart → 平滑重启
  #   Runtime → 运行时
  #   Sandbox → 沙箱
  """

  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # :system category
  # ---------------------------------------------------------------------------

  attr(:scheduler_paused, :boolean, required: true)
  attr(:remote, :boolean, required: true)
  attr(:system_checks_status, :atom, required: true)
  attr(:sys_config_status, :any, default: nil)
  attr(:tool_check, :any, default: nil)
  attr(:sandbox_check, :any, default: nil)
  attr(:supervisor_check, :any, default: nil)
  attr(:nix_check, :any, default: nil)
  attr(:show_restart_confirm, :boolean, required: true)
  attr(:show_stop_confirm, :boolean, required: true)

  def system_category(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-w-0">
      <div class="sticky top-0 z-10 bg-base-100/90 backdrop-blur-md px-6 py-4 border-b border-base-200/70">
        <div class="flex items-center gap-3 mb-1">
          <.icon name="hero-server-stack" class="size-5 text-base-content/70" />
          <h2 class="text-lg font-bold text-base-content">
            {gettext("System")}
          </h2>
        </div>
        <p class="text-sm text-base-content/60">
          {gettext("Scheduler and system controls, plus system health self-check.")}
        </p>
      </div>

      <div class="p-6 space-y-6">
        <!-- Scheduler Control banner -->
        <div class="p-4 border border-base-200 rounded-lg flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div class="flex items-center gap-3">
            <.icon
              name={if @scheduler_paused, do: "hero-pause-circle", else: "hero-play-circle"}
              class={"size-5 " <> if(@scheduler_paused, do: "text-warning", else: "text-success")}
            />
            <div>
              <h2 class="text-base font-bold tracking-tight">
                {if @scheduler_paused,
                  do: gettext("Scheduler Paused"),
                  else: gettext("Scheduler Active")} <% # zh_CN: "调度器" %>
              </h2>
              <p class="text-sm text-base-content/60 mt-0.5 max-w-lg">
                <%= if @scheduler_paused do %>
                  {gettext(
                    "Running agents continue. No new slots or agents will be granted until resumed."
                  )} <% # zh_CN: "智能体" %>
                <% else %>
                  {gettext("Agents and slots are being granted normally.")} <% # zh_CN: "智能体" %>
                <% end %>
              </p>
            </div>
          </div>
          <button
            type="button"
            phx-click="toggle_pause"
            class={[
              "btn rounded-md font-medium shrink-0",
              if(@scheduler_paused,
                do: "bg-success/20 hover:bg-success/30 text-success-content",
                else: "bg-warning/20 hover:bg-warning/30 text-warning-content"
              )
            ]}
          >
            <.icon name={if @scheduler_paused, do: "hero-play", else: "hero-pause"} class="size-5 mr-2" />
            {if @scheduler_paused, do: gettext("Resume Scheduler"), else: gettext("Pause Scheduler")} <% # zh_CN: "调度器" %>
          </button>
        </div>

        <!-- System Self-Check -->
        <div class="border border-base-200 rounded-lg">
          <div class="p-4">
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center gap-3">
                <.icon name="hero-shield-check" class="size-5 text-success" />
                <div>
                  <h2 class="font-bold text-base">{gettext("System Self-Check")}</h2>
                  <p class="text-sm text-base-content/60">
                    {gettext("System status and health overview")}
                  </p>
                </div>
              </div>
              <button
                phx-click="rerun_checks"
                class="btn btn-ghost btn-sm gap-2"
                disabled={@system_checks_status == :checking}
              >
                <.icon
                  name="hero-arrow-path"
                  class={"size-4 #{if @system_checks_status == :checking, do: "animate-spin"}"}
                />
                {if @system_checks_status == :checking,
                  do: gettext("Checking..."),
                  else: gettext("Re-check")}
              </button>
            </div>

            <div class="space-y-3">
              <%= if @system_checks_status != :done do %>
                <div class="flex items-center gap-3 py-6 justify-center">
                  <.icon name="hero-arrow-path" class="size-5 animate-spin text-base-content/50" />
                  <span class="text-sm text-base-content/60">{gettext("Checking system status...")}</span>
                </div>
              <% else %>
                <!-- Config Status Row -->
                <.system_check_row
                  title={gettext("Configuration")}
                  icon="hero-cog-6-tooth"
                  status={if config_ok?(@sys_config_status), do: :ok, else: :error}
                >
                  <:details>
                    <%= if config_ok?(@sys_config_status) do %>
                      <span class="text-sm text-success">{gettext("All configured")}</span>
                    <% else %>
                      <div class="flex flex-wrap gap-1.5">
                        <%= for item <- (@sys_config_status[:missing] || []) do %>
                          <span class="badge badge-warning badge-sm gap-1">
                            <.icon name="hero-x-mark" class="size-3" />
                            {format_config_item(item)}
                          </span>
                        <% end %>
                      </div>
                    <% end %>
                    <%= if @sys_config_status != nil and @sys_config_status[:validation_errors] not in [[], nil] do %>
                      <div class="mt-1 text-xs text-warning">
                        {ngettext(
                          "%{count} validation warning",
                          "%{count} validation warnings",
                          length(@sys_config_status.validation_errors)
                        )}
                      </div>
                    <% end %>
                  </:details>
                </.system_check_row>

                <!-- Tools Row -->
                <.system_check_row
                  title={gettext("Required Tools")}
                  icon="brand-git"
                  status={tools_status(@tool_check)}
                >
                  <:details>
                    <div class="flex flex-wrap gap-3">
                      <.tool_badge name="git" check={@tool_check.git} />
                      <.tool_badge name="rg (ripgrep)" check={@tool_check.rg} />
                    </div>
                  </:details>
                </.system_check_row>

                <!-- Sandbox Row -->
                <% # zh_CN: "沙箱" %>
                <.system_check_row
                  title={gettext("Sandbox")}
                  icon="hero-lock-closed"
                  status={sandbox_status(@sandbox_check)}
                >
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
                          {gettext("Filesystem isolation")}: {if @sandbox_check.capabilities.filesystem_isolation,
                            do: "✓",
                            else: "✗"} · {gettext("Resource limits")}: {if @sandbox_check.capabilities.resource_limits,
                            do: "✓",
                            else: "✗"}
                        </span>
                      <% end %>
                    </div>
                  </:details>
                </.system_check_row>

                <!-- Supervisor Row -->
                <.system_check_row
                  title={gettext("EvoX Genesis Process Tree")}
                  icon="hero-server-stack"
                  status={if supervisor_healthy?(@supervisor_check), do: :ok, else: :error}
                >
                  <:details>
                    <div class="space-y-1">
                      <.supervisor_status
                        label={gettext("EvoGit")}
                        children={@supervisor_check.evo_git}
                      />
                      <.supervisor_status
                        label={gettext("EvoDash")}
                        children={@supervisor_check.evo_dash}
                      />
                    </div>
                  </:details>
                </.system_check_row>

                <!-- Nix Environment Row -->
                <.system_check_row
                  title={gettext("Nix Environment")}
                  icon="brand-nix"
                  status={nix_status(@nix_check)}
                >
                  <:details>
                    <div class="flex flex-wrap gap-2 items-center">
                      <span class={"badge badge-sm #{if @nix_check.enabled, do: "badge-success", else: "badge-ghost"}"}>
                        {if @nix_check.enabled, do: gettext("Enabled"), else: gettext("Disabled")}
                      </span>
                      <span class="text-sm text-base-content/60">
                        {gettext("Binary")}: {if @nix_check.available, do: "✓", else: "✗"}
                      </span>
                      <span class="text-sm text-base-content/60">
                        {gettext("flake.nix")}: {if @nix_check.flake_present, do: "✓", else: "✗"}
                      </span>
                      <%= if @nix_check.flake_present do %>
                        <span class="text-xs text-base-content/40">
                          {gettext("Flake valid")}: {if @nix_check.dev_env_built, do: "✓", else: "✗"}
                        </span>
                      <% end %>
                    </div>
                    <%= if @nix_check[:error] do %>
                      <div class="mt-1 text-xs text-error/80">
                        <.icon name="hero-exclamation-triangle" class="size-3 inline -mt-0.5" />
                        {@nix_check.error}
                      </div>
                    <% end %>
                  </:details>
                </.system_check_row>

                <!-- LLM Test Row -->
                <.system_check_row
                  title={gettext("LLM Connection")}
                  icon="hero-chat-bubble-left-right"
                  status={:info}
                >
                  <:details>
                    <div class="flex items-center gap-3">
                      <span class="text-sm text-base-content/60">{gettext(
                        "LLM connection testing is now available on the Settings page."
                        )}</span>
                      <.link navigate={~p"/settings?category=llm"} class="btn btn-primary btn-sm gap-2">
                        <.icon name="hero-sparkles" class="size-4" />
                        {gettext("Test in Settings")}
                      </.link>
                    </div>
                  </:details>
                </.system_check_row>
              <% end %>
            </div>
          </div>
        </div>

        <!-- System Control section (destructive actions) -->
        <div class="border border-error/30 bg-error/5 p-4 rounded-lg flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div class="flex items-start gap-3">
            <.icon name="hero-power" class="size-5 text-error shrink-0" />
            <div>
              <h2 class="text-base font-bold tracking-tight text-error mb-0.5">
                {gettext("System Control")}
              </h2>
              <p class="text-sm text-base-content/60 max-w-lg">
                {gettext(
                  "Gracefully restart or stop the Erlang VM. Restart tears down and restarts all applications; stop gracefully shuts down the VM and it must be started again manually. In-memory runtime state will be lost in both cases."
                )} <% # zh_CN: "平滑重启", "运行时" %>
              </p>
            </div>
          </div>
          <div class="flex flex-col sm:flex-row gap-3 shrink-0">
            <button
              type="button"
              phx-click="request_restart"
              class="btn rounded-md bg-error/15 hover:bg-error/25 text-error font-medium gap-2"
            >
              <.icon name="hero-arrow-path" class="size-5" />
              {gettext("Restart System")}
            </button>
            <button
              type="button"
              phx-click="request_stop"
              class="btn rounded-md bg-error/15 hover:bg-error/25 text-error font-medium gap-2"
            >
              <.icon name="hero-power" class="size-5" />
              {gettext("Stop System")}
            </button>
          </div>
        </div>
      </div>

      <!-- Restart confirmation modal -->
      <%= if @show_restart_confirm do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="cancel_restart"></div>
          <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-200 max-w-lg w-full p-6 md:p-8">
            <div class="flex items-center gap-3 mb-4">
              <.icon name="hero-exclamation-triangle" class="size-5 text-error" />
              <h3 class="text-lg font-bold">{gettext("Restart System?")}</h3>
            </div>

            <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
              {gettext(
                "This will gracefully restart the Erlang VM. All applications will be torn down and restarted."
              )} <% # zh_CN: "平滑重启" %>
            </p>
            <p class="text-sm text-error/80 font-semibold mb-5 leading-relaxed">
              {gettext(
                "All in-memory runtime state (running tasks, scheduler state, in-progress agents) will be lost. This cannot be undone."
              )} <% # zh_CN: "运行时", "调度器", "智能体" %>
            </p>

            <div class="flex justify-end gap-3 pt-2">
              <button type="button" class="btn btn-ghost rounded-md px-6" phx-click="cancel_restart">
                {gettext("Cancel")}
              </button>
              <button
                type="button"
                class="btn btn-error rounded-md px-6 gap-2"
                phx-click="confirm_restart"
              >
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
          <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-200 max-w-lg w-full p-6 md:p-8">
            <div class="flex items-center gap-3 mb-4">
              <.icon name="hero-exclamation-triangle" class="size-5 text-error" />
              <h3 class="text-lg font-bold">{gettext("Stop System?")}</h3>
            </div>

            <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
              {gettext(
                "This will gracefully shut down the Erlang VM. All applications will be stopped in order."
              )}
            </p>
            <p class="text-sm text-error/80 font-semibold mb-5 leading-relaxed">
              {gettext(
                "The VM will stop and must be restarted manually. All in-memory runtime state (running tasks, scheduler state, in-progress agents) will be lost. This cannot be undone."
              )}
            </p>

            <div class="flex justify-end gap-3 pt-2">
              <button type="button" class="btn btn-ghost rounded-md px-6" phx-click="cancel_stop">
                {gettext("Cancel")}
              </button>
              <button
                type="button"
                class="btn btn-error rounded-md px-6 gap-2"
                phx-click="confirm_stop"
              >
                <.icon name="hero-power" class="size-4.5" />
                {gettext("Stop System")}
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # :help category
  # ---------------------------------------------------------------------------

  attr(:help_content, :map, required: true)

  def help_category(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-w-0">
      <div class="sticky top-0 z-10 bg-base-100/90 backdrop-blur-md px-6 py-4 border-b border-base-200/70">
        <div class="flex items-center gap-3 mb-1">
          <.icon name="hero-book-open" class="size-5 text-base-content/70" />
          <h2 class="text-lg font-bold text-base-content">
            {gettext("Help & Guides")}
          </h2>
        </div>
        <p class="text-sm text-base-content/60">
          {gettext("Usage guides, example configuration, and frequently asked questions.")}
        </p>
      </div>

      <div class="p-6 space-y-6">
        <!-- Example Configuration -->
        <details id="config-reference" open class="overflow-hidden group border border-base-200 rounded-lg">
          <summary class="px-4 py-3 cursor-pointer select-none flex items-center gap-3 list-none hover:bg-slate-50 dark:hover:bg-slate-800/50 transition-colors">
            <.icon name="hero-book-open" class="size-5 shrink-0 text-info" />
            <span class="font-semibold flex-1">{gettext("Example Configuration")}</span>
            <.icon name="hero-chevron-down" class="size-5 shrink-0 text-base-content/50 transition-transform duration-200 group-open:rotate-180" />
          </summary>
          <div class="p-4">
            <pre class="text-sm font-mono bg-base-200/40 rounded-md p-4 border border-base-200 whitespace-pre-wrap break-words max-h-[500px] overflow-y-auto">{@help_content.config_reference}</pre>
          </div>
        </details>

        <!-- Example Usage -->
        <details id="usage-reference" open class="overflow-hidden group border border-base-200 rounded-lg">
          <summary class="px-4 py-3 cursor-pointer select-none flex items-center gap-3 list-none hover:bg-slate-50 dark:hover:bg-slate-800/50 transition-colors">
            <.icon name="hero-command-line" class="size-5 shrink-0 text-success" />
            <span class="font-semibold flex-1">{gettext("Example Usage")}</span>
            <.icon name="hero-chevron-down" class="size-5 shrink-0 text-base-content/50 transition-transform duration-200 group-open:rotate-180" />
          </summary>
          <div class="p-4">
            <pre class="text-sm font-mono bg-base-200/40 rounded-md p-4 border border-base-200 whitespace-pre-wrap break-words max-h-[500px] overflow-y-auto">{@help_content.usage_reference}</pre>
          </div>
        </details>

        <!-- FAQ -->
        <details id="faq" open class="overflow-hidden group border border-base-200 rounded-lg">
          <summary class="px-4 py-3 cursor-pointer select-none flex items-center gap-3 list-none hover:bg-slate-50 dark:hover:bg-slate-800/50 transition-colors">
            <.icon name="hero-question-mark-circle" class="size-5 shrink-0 text-accent" />
            <span class="font-semibold flex-1">{gettext("Frequently Asked Questions")}</span>
            <.icon name="hero-chevron-down" class="size-5 shrink-0 text-base-content/50 transition-transform duration-200 group-open:rotate-180" />
          </summary>
          <div class="p-4">
            <div class="space-y-4">
              <%= for {{question, answer}, idx} <- Enum.with_index(@help_content.faq_content) do %>
                <details class="group rounded-lg border border-base-200 overflow-hidden bg-base-100/50">
                  <summary class="flex items-center gap-3 px-4 py-3 cursor-pointer select-none hover:bg-base-200/50 transition-colors list-none">
                    <.icon
                      name="hero-chevron-down"
                      class="size-4.5 shrink-0 text-base-content/50 transition-transform duration-200 group-open:rotate-180"
                    />
                    <span class="font-semibold text-sm">{question}</span>
                  </summary>
                  <div class="px-4 py-3 text-sm text-base-content/70 leading-relaxed border-t border-base-200">
                    <p id={"faq-answer-#{idx}"}>{answer}</p>
                  </div>
                </details>
              <% end %>
            </div>
          </div>
        </details>

        <!-- Credentials Reference -->
        <details id="credentials-reference" open class="overflow-hidden group border border-base-200 rounded-lg">
          <summary class="px-4 py-3 cursor-pointer select-none flex items-center gap-3 list-none hover:bg-slate-50 dark:hover:bg-slate-800/50 transition-colors">
            <.icon name="hero-key" class="size-5 shrink-0 text-accent" />
            <span class="font-semibold flex-1">{gettext("Credentials Reference")}</span>
            <.icon name="hero-chevron-down" class="size-5 shrink-0 text-base-content/50 transition-transform duration-200 group-open:rotate-180" />
          </summary>
          <div class="p-4">
            <pre class="text-sm font-mono bg-base-200/40 rounded-md p-4 border border-base-200 whitespace-pre-wrap break-words max-h-[500px] overflow-y-auto">{@help_content.credentials_reference}</pre>
            <div class="mt-4 space-y-2">
              <p class="text-sm text-base-content/60 flex items-start gap-2.5">
                <.icon name="hero-arrows-right-left" class="size-4.5 shrink-0 mt-0.5" />
                <span>{gettext(
                  "Keys from credentials.toml are loaded as environment variables on startup. You can also set API keys directly via environment variables (e.g., GOOGLE_API_KEY)."
                )}</span>
              </p>
              <p class="text-sm text-base-content/60 flex items-start gap-2.5">
                <.icon name="hero-shield-check" class="size-4.5 shrink-0 mt-0.5" />
                <span>{gettext(
                  "For security, credentials cannot be edited from this page. Edit the file directly on your system."
                )}</span>
              </p>
            </div>
          </div>
        </details>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Status helpers (ported from EvoDashWeb.SystemLive.Status)
  # ---------------------------------------------------------------------------

  @doc """
  Nil-safe config check (assigns are nil during loading).
  """
  def config_ok?(nil), do: false
  def config_ok?(%{ok?: ok?}), do: ok?

  @doc """
  Determines the overall tools status from the tool-check map.
  """
  def tools_status(%{git: %{available: true}, rg: %{available: true}}), do: :ok
  def tools_status(%{git: %{available: false}}), do: :error
  def tools_status(%{rg: %{available: false}}), do: :error
  def tools_status(_), do: :warning

  @doc """
  Nil-safe supervisor health check.
  """
  def supervisor_healthy?(nil), do: false
  def supervisor_healthy?(%{healthy: healthy}), do: healthy

  @doc """
  Determines the nix environment overall status.
  """
  def nix_status(%{enabled: true, dev_env_built: true}), do: :ok
  def nix_status(%{enabled: true}), do: :warning
  def nix_status(%{available: true}), do: :info
  def nix_status(_), do: :info

  @doc """
  Determines the sandbox overall status from the sandbox-check map.
  """
  def sandbox_status(%{backend: :systemd_run} = check) do
    if check.systemd_available && check.capabilities.filesystem_isolation &&
         check.capabilities.resource_limits do
      :ok
    else
      :error
    end
  end

  def sandbox_status(%{backend: :sandbox_exec} = check) do
    if check.sandbox_exec_available && check.capabilities.filesystem_isolation do
      :ok
    else
      :error
    end
  end

  def sandbox_status(%{backend: :none}), do: :info
  def sandbox_status(_), do: :error

  @doc """
  Formats the sandbox backend name for display.
  """
  def format_backend(:systemd_run), do: "systemd-run (Linux)"
  def format_backend(:sandbox_exec), do: "sandbox-exec (macOS)"
  def format_backend(:none), do: gettext("None")

  @doc """
  Formats a config item name for display.
  """
  def format_config_item(:llm_model), do: gettext("LLM Model")
  def format_config_item(:api_key), do: gettext("API Key")
  def format_config_item(:github_username), do: gettext("GitHub Username")

  def format_config_item(item) do
    item |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  # ---------------------------------------------------------------------------
  # Private components
  # ---------------------------------------------------------------------------

  attr(:title, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:status, :atom, default: :ok)
  slot(:details, required: true)

  defp system_check_row(assigns) do
    ~H"""
    <div class="flex items-start gap-3 py-3 border-b border-base-200/40 last:border-0">
      <div class={"p-2 rounded-md #{status_bg(@status)}"}>
        <.icon name={@icon} class={"size-4 #{status_text(@status)}"} />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 mb-1">
          <span class="font-semibold text-sm">{@title}</span>
          <%= case @status do %>
            <% :ok -> %>
              <.icon name="hero-check-circle-solid" class="size-4 text-success" />
            <% :error -> %>
              <.icon name="hero-x-circle-solid" class="size-4 text-error" />
            <% :info -> %>
              <.icon name="hero-information-circle-solid" class="size-4 text-info" />
            <% :warning -> %>
              <.icon name="hero-exclamation-triangle-solid" class="size-4 text-warning" />
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
end
