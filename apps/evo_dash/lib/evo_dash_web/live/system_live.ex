defmodule EvoDashWeb.SystemLive do
  @moduledoc """
  System page: software update, system self-check (merged health banner +
  responsive check grid, including the local-only Genesis Source grid card),
  scheduler-status charts, and the grouped System Controls section (System
  Dashboard + scheduler pause/resume + VM restart/stop).
  """

  # zh_CN glossary translations used in this file:
  #   Scheduler → 调度器
  #   Agent → 智能体
  #   Graceful restart → 平滑重启
  #   Runtime → 运行时
  #   Sandbox → 沙箱
  #   Genesis → 启元
  #   Context Tree → 上下文树
  #   LLM Provider → 服务商
  #   Configuration → 配置
  #   Required Tools → 必需工具
  #   Nix Environment → Nix 环境

  use EvoDashWeb, :live_view

  alias EvoDashWeb.SystemLive.Charts
  alias EvoDashWeb.SystemLive.Status

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:system}
      config_status={@config_status}
      current_node_id={@current_node_id}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      pending_tasks={@pending_tasks}
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
    >
      <%= if EvoDashWeb.RemoteGateComponents.gate_active?(assigns) do %>
        {EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns)}
      <% else %>
        <%= if @update_card_visible do %>
          <!-- Software Update card (desktop shell only; hidden on remote nodes) -->
          <div
            id="software-update-card"
            class="rounded-lg border border-base-200 bg-base-100 p-4 mb-6"
          >
            <div class="flex items-start justify-between gap-4">
              <div class="flex items-start gap-3">
                <.icon name="hero-arrow-down-tray" class="size-5 text-info shrink-0" />
                <div>
                  <h2 class="text-base font-bold tracking-tight">
                    {gettext("Software Update")} <% # zh_CN: "软件更新" %>
                  </h2>
                  <p class="text-sm text-base-content/60 mt-0.5">
                    {gettext("Check for and install the latest Genesis release.")} <% # zh_CN: "检查并安装最新版 Genesis" %>
                  </p>
                  <%= if @update_status.current_version do %>
                    <p class="text-xs text-base-content/40 mt-1">
                      {gettext("Current version: %{version}",
                        version: @update_status.current_version
                      )} <% # zh_CN: "当前版本" %>
                    </p>
                  <% end %>
                </div>
              </div>
              <button
                id="update-check-now"
                type="button"
                phx-click="check_for_updates"
                class="btn btn-ghost btn-sm rounded-md gap-2 shrink-0"
                disabled={@update_status.phase in [:checking, :applying]}
              >
                <.icon
                  name="hero-arrow-path"
                  class={"size-4 #{if @update_status.phase == :checking, do: "animate-spin"}"}
                />
                {if @update_status.phase == :checking,
                  do: gettext("Checking..."),
                  else: gettext("Check now")} <% # zh_CN: "立即检查" %>
              </button>
            </div>

            <div class="mt-3">
              <%= case @update_status.phase do %>
                <% :idle -> %>
                  <p class="text-sm text-base-content/60">
                    {gettext("Update information will appear here after the first check.")} <% # zh_CN: "首次检查后此处会显示更新信息" %>
                  </p>
                <% :checking -> %>
                  <div class="flex items-center gap-3 py-1">
                    <.icon name="hero-arrow-path" class="size-5 animate-spin text-base-content/50" />
                    <span class="text-sm text-base-content/60">{gettext("Checking for updates…")}</span>
                    <%= if @update_status.last_checked_at do %>
                      <span class="text-xs text-base-content/40">
                        {gettext("Last checked")} {EvoDashWeb.Helpers.format_datetime(
                          @update_status.last_checked_at
                        )}
                      </span>
                    <% end %>
                  </div>
                <% :up_to_date -> %>
                  <div class="flex items-center gap-2 py-1">
                    <.icon name="hero-check-circle" class="size-4 text-success" />
                    <span class="text-sm">
                      {gettext("Genesis %{version} is up to date",
                        version: @update_status.current_version
                      )} <% # zh_CN: "已是最新版本" %>
                    </span>
                  </div>
                  <p class="text-xs text-base-content/40 mt-1">
                    {gettext("Last checked")} {EvoDashWeb.Helpers.format_datetime(
                      @update_status.last_checked_at
                    )}
                  </p>
                <% :available -> %>
                  <div class="flex items-center gap-2 py-1">
                    <span class="size-2 rounded-full bg-warning shrink-0"></span>
                    <span class="text-sm font-medium">
                      {gettext("Version %{version} is available",
                        version: @update_status.latest_version
                      )} <% # zh_CN: "发现新版本" %>
                    </span>
                    <.changelog_link update_status={@update_status} />
                  </div>
                  <div class="mt-3">
                    <%= if @update_status.notify_only do %>
                      <!-- Linux deb/rpm/portable installs: no self-install per plan §3 -->
                      <p class="text-sm text-base-content/60 flex items-center gap-2">
                        <.icon name="hero-information-circle" class="size-4 text-info shrink-0" />
                        {gettext("Update via your package manager")} <% # zh_CN: "请通过系统包管理器更新（deb/rpm/便携版不自动安装）" %>
                      </p>
                    <% else %>
                      <button
                        id="update-download"
                        type="button"
                        phx-click="download_update"
                        class="btn btn-primary btn-sm rounded-md gap-2"
                      >
                        <.icon name="hero-arrow-down-tray" class="size-4" />
                        {gettext("Download")} <% # zh_CN: "下载" %>
                      </button>
                    <% end %>
                  </div>
                <% :ready -> %>
                  <div class="flex items-center gap-2 py-1">
                    <span class="relative flex size-2 shrink-0">
                      <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-info opacity-75"></span>
                      <span class="relative inline-flex size-2 rounded-full bg-info"></span>
                    </span>
                    <span class="text-sm font-medium">
                      {gettext("Update ready — version %{version}",
                        version: @update_status.latest_version
                      )} <% # zh_CN: "更新已就绪" %>
                    </span>
                    <.changelog_link update_status={@update_status} />
                  </div>
                  <div class="mt-3">
                    <button
                      id="update-restart"
                      type="button"
                      phx-click="request_apply_update"
                      class="btn btn-primary btn-sm rounded-md gap-2"
                    >
                      <.icon name="hero-arrow-path" class="size-4" />
                      {gettext("Restart & Update")} <% # zh_CN: "重启并更新" %>
                    </button>
                  </div>
                <% :error -> %>
                  <div class="flex items-center gap-2 py-1">
                    <%= case @update_status.error do %>
                      <% "not_available" -> %>
                        <!-- latest.json fetched but no auto-update payload for this platform -->
                        <.icon name="hero-information-circle" class="size-4 text-info shrink-0" />
                        <%= if @update_status.latest_version do %>
                          <span class="text-sm text-info">
                            {gettext("Latest version %{version} — no auto-update for this platform",
                              version: @update_status.latest_version
                            )} <% # zh_CN: "当前平台不支持自动更新，提示最新可用版本" %>
                          </span>
                        <% else %>
                          <span class="text-sm text-info">
                            {gettext("No auto update on this platform")} <% # zh_CN: "当前平台没有可用的自动更新（未发布对应平台的安装包）" %>
                          </span>
                        <% end %>
                      <% "not_configured" -> %>
                        <.icon name="hero-exclamation-triangle" class="size-4 text-error shrink-0" />
                        <span class="text-sm text-base-content/70">
                          {gettext("Automatic updates are not configured yet")} <% # zh_CN: "尚未配置自动更新（缺少更新签名密钥等）" %>
                        </span>
                      <% _ -> %>
                        <.icon name="hero-exclamation-triangle" class="size-4 text-error shrink-0" />
                        <div>
                          <span class="text-sm text-error">{gettext("Check failed")}</span>
                          <%= if @update_status.error do %>
                            <!-- Raw backend diagnostic detail (English) — not a UI string -->
                            <span class="block text-xs text-base-content/40 break-all">
                              {@update_status.error}
                            </span>
                          <% end %>
                        </div>
                    <% end %>
                  </div>
                <% :applying -> %>
                  <div class="flex items-center gap-3 py-1">
                    <.icon name="hero-arrow-path" class="size-5 animate-spin text-base-content/50" />
                    <span class="text-sm text-base-content/60">{gettext("Applying update…")} <% # zh_CN: "正在应用更新" %></span>
                  </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <!-- System Self-Check -->
        <div id="system-self-check">
          <div class="p-4 border-b border-slate-200 dark:border-slate-800">
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

            <!-- Overall health banner: merges all checks into one status light -->
            <% health = Status.overall_health(health_checks(assigns)) %>
            <div class={"rounded-lg border p-4 mb-4 flex items-start gap-3 #{health_banner_class(health.status)}"}>
              <%= case health.status do %>
                <% :ok -> %>
                  <.icon name="hero-check-circle-solid" class="size-6 text-success shrink-0" />
                <% :warning -> %>
                  <.icon name="hero-exclamation-triangle-solid" class="size-6 text-warning shrink-0" />
                <% :error -> %>
                  <.icon name="hero-x-circle-solid" class="size-6 text-error shrink-0" />
                <% :loading -> %>
                  <.icon
                    name="hero-arrow-path"
                    class="size-6 text-base-content/40 animate-spin shrink-0"
                  />
              <% end %>
              <div class="flex-1 min-w-0">
                <h3 class="font-bold text-sm">
                  <%= case health.status do %>
                    <% :ok -> %>
                      {gettext("System running correctly")}
                    <% :warning -> %>
                      {gettext("System running, but needs attention")}
                    <% :error -> %>
                      {gettext("System needs attention")}
                    <% :loading -> %>
                      {gettext("Checking system health...")}
                  <% end %>
                </h3>
                <%= if health.reasons != [] do %>
                  <ul class="mt-1.5 space-y-1 text-sm">
                    <%= for reason <- health.reasons do %>
                      <li class="flex items-start gap-1.5 text-base-content/70">
                        <.icon
                          name="hero-exclamation-circle"
                          class="size-3.5 text-base-content/50 shrink-0 mt-0.5"
                        />
                        <span>{reason}</span>
                      </li>
                    <% end %>
                  </ul>
                <% else %>
                  <%= if health.status == :ok do %>
                    <p class="text-sm text-base-content/60">{gettext("All self-checks passed.")}</p>
                  <% end %>
                <% end %>
              </div>
            </div>

            <div class="space-y-3">
              <%= if @system_checks_status == :checking do %>
                <div class="flex items-center gap-3 py-6 justify-center">
                  <.icon name="hero-arrow-path" class="size-5 animate-spin text-base-content/50" />
                  <span class="text-sm text-base-content/60">{gettext("Checking system status...")}</span>
                </div>
              <% else %>
                <!-- Check terms in a responsive grid (1 col mobile → 3 cols wide) -->
                <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
                  <!-- Configuration cell -->
                  <.check_cell
                    title={gettext("Configuration")}
                    icon="hero-cog-6-tooth"
                    status={if Status.config_ok?(@config_status), do: :ok, else: :error}
                  >
                    <:details>
                      <p class="text-xs text-base-content/60 mb-2">
                        {gettext(
                          "Verifies that the required settings — LLM provider, model, and API key — are configured."
                        )}
                      </p>
                      <%= if Status.config_ok?(@config_status) do %>
                        <span class="text-sm text-success">{gettext("All configured")}</span>
                      <% else %>
                        <div class="flex flex-wrap gap-1.5">
                          <%= for item <- (@config_status[:missing] || []) do %>
                            <span class="badge badge-warning badge-sm gap-1">
                              <.icon name="hero-x-mark" class="size-3" />
                              {Status.format_config_item(item)}
                            </span>
                          <% end %>
                        </div>
                      <% end %>
                      <%= if @config_status != nil and @config_status[:validation_errors] not in [[], nil] do %>
                        <div class="mt-1 text-xs text-warning">
                          {ngettext(
                            "%{count} validation warning",
                            "%{count} validation warnings",
                            length(@config_status.validation_errors)
                          )}
                        </div>
                      <% end %>
                    </:details>
                    <:fix>
                      {gettext("Fix the missing or invalid settings in Settings.")}
                      <.link
                        navigate={with_node_param(~p"/settings", @current_node_id)}
                        class="link link-primary ml-1"
                      >
                        {gettext("Open Settings")}
                      </.link>
                    </:fix>
                  </.check_cell>

                  <!-- Required Tools cell -->
                  <.check_cell
                    title={gettext("Required Tools")}
                    icon="brand-git"
                    status={Status.tools_status(@tool_check)}
                  >
                    <:details>
                      <p class="text-xs text-base-content/60 mb-2">
                        {gettext(
                          "Checks that the git and ripgrep command-line tools are installed and available on your PATH."
                        )}
                      </p>
                      <div class="flex flex-wrap gap-3">
                        <.tool_badge name="git" check={@tool_check.git} />
                        <.tool_badge name="rg (ripgrep)" check={@tool_check.rg} />
                      </div>
                    </:details>
                    <:fix>
                      <%= if @tool_check.git.available == false do %>
                        <div>
                          {gettext("Install git and make sure it is available on your PATH.")}
                        </div>
                      <% end %>
                      <%= if @tool_check.rg.available == false do %>
                        <div>
                          {gettext("Install ripgrep and make sure it is available on your PATH.")}
                        </div>
                      <% end %>
                    </:fix>
                  </.check_cell>

                  <!-- Sandbox cell (hidden on Windows/unknown platforms) -->
                  <% # zh_CN: "沙箱" %>
                  <%= if EvoDashWeb.PlatformInfo.show_sandbox?(@platform_os) do %>
                    <.check_cell
                      title={gettext("Sandbox")}
                      icon="hero-lock-closed"
                      status={Status.sandbox_status(@sandbox_check)}
                    >
                      <:details>
                        <p class="text-xs text-base-content/60 mb-2">
                          {gettext(
                            "Checks that agent commands can be isolated in a sandbox to protect your system."
                          )}
                        </p>
                        <div class="flex flex-wrap gap-2 items-center">
                          <span class={"badge badge-sm #{case @sandbox_check.backend do :systemd_run -> "badge-success"; :bwrap -> "badge-success"; :sandbox_exec -> "badge-info"; _ -> "badge-ghost" end}"}>
                            {Status.format_backend(@sandbox_check.backend)}
                          </span>
                          <span class="text-sm text-base-content/60">
                            {if @sandbox_check.enabled,
                              do: gettext("Enabled"),
                              else: gettext("Disabled")}
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
                      <:fix>
                        <%= case @sandbox_check.backend do %>
                          <% :systemd_run -> %>
                            {gettext(
                              "Enable or install systemd-run. Sandboxing requires a systemd user session."
                            )}
                          <% :sandbox_exec -> %>
                            {gettext("Sandbox-exec sandboxing is unavailable on this system.")}
                          <% _ -> %>
                            {gettext("No sandbox backend is available on this system.")}
                        <% end %>
                      </:fix>
                    </.check_cell>
                  <% end %>

                  <!-- Nix Environment cell (gated on nix enabled in config AND binary available) -->
                  <%= if @nix_check != nil and @nix_check.enabled and @nix_check.available do %>
                    <.check_cell
                      title={gettext("Nix Environment")}
                      icon="brand-nix"
                      status={Status.nix_status(@nix_check)}
                    >
                      <:details>
                        <p class="text-xs text-base-content/60 mb-2">
                          {gettext(
                            "Checks the Nix development environment used for reproducible builds."
                          )}
                        </p>
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
                              {gettext("Flake valid")}: {if @nix_check.dev_env_built,
                                do: "✓",
                                else: "✗"}
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
                      <:fix>
                        {gettext(
                          "The Nix dev environment could not be built. Fix the flake or disable Nix in Settings."
                        )}
                      </:fix>
                    </.check_cell>
                  <% end %>

                  <!-- LLM Connection cell -->
                  <.check_cell
                    title={gettext("LLM Connection")}
                    icon="hero-chat-bubble-left-right"
                    status={:info}
                  >
                    <:details>
                      <p class="text-xs text-base-content/60 mb-2">
                        {gettext(
                          "Check that your LLM provider is reachable with the configured API key."
                        )}
                      </p>
                      <div class="flex items-center gap-3">
                        <span class="text-sm text-base-content/60">{gettext(
                          "LLM connection testing is now available on the Settings page."
                        )}</span>
                        <.link
                          navigate={
                            ~p"/settings?category=llm#{if @current_node_id, do: "&node=#{@current_node_id}", else: ""}"
                          }
                          class="btn btn-primary btn-sm gap-2"
                        >
                          <.icon name="hero-sparkles" class="size-4" />
                          {gettext("Test in Settings")}
                        </.link>
                      </div>
                    </:details>
                  </.check_cell>

                  <%= if @source_card_visible do %>
                    <!-- Genesis Source cell (local nodes only — a remote
                         genesis_remote daemon's self-reflective agent reads the
                         REMOTE host's filesystem, so clone/update must never act
                         remotely). A peer card in the check grid, so it hides
                         together with the grid while a re-check is running. -->
                    <EvoDashWeb.SystemLive.SourceCard.source_section
                      source_status={@source_status}
                      source_status_loading={@source_status_loading}
                      source_busy={@source_busy}
                    />
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Scheduler status charts (server-rendered SVG, no JS plotting lib) -->
        <Charts.charts_section
          samples={@chart_samples}
          paused={@scheduler_paused}
          selected_llm_model={@selected_llm_model}
        />

        <!-- System Controls (LAST content section): System Dashboard + Scheduler
             Control + System Control grouped in one responsive 3-card grid -->
        <EvoDashWeb.SystemLive.RuntimeControls.controls_section
          scheduler_paused={@scheduler_paused}
          dashboard_path={with_node_param(~p"/dashboard", @current_node_id)}
        />

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
                <%= if @remote? do %>
                  {gettext(
                    "This will gracefully restart the remote node's Erlang VM. All applications on the remote node will be torn down and restarted."
                  )}
                <% else %>
                  {gettext(
                    "This will gracefully restart the Erlang VM. All applications will be torn down and restarted."
                  )} <% # zh_CN: "平滑重启" %>
                <% end %>
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
                <%= if @remote? do %>
                  {gettext(
                    "This will gracefully shut down the remote node's Erlang VM. All applications on the remote node will be stopped in order."
                  )}
                <% else %>
                  {gettext(
                    "This will gracefully shut down the Erlang VM. All applications will be stopped in order."
                  )}
                <% end %>
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

        <%= if @update_card_visible and @update_apply_busy_count != nil do %>
          <!-- Software Update busy-apply modal (tasks still running) -->
          <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
            <div class="fixed inset-0 bg-black/50 backdrop-blur-sm"></div>
            <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-200 max-w-lg w-full p-6 md:p-8">
              <div class="flex items-center gap-3 mb-4">
                <.icon name="hero-clock" class="size-5 text-warning" />
                <h3 class="text-lg font-bold">{gettext("Tasks still running")}</h3>
              </div>

              <%= if @update_winddown do %>
                <!-- Wind-down in progress: graceful cancels are running; no buttons -->
                <div class="flex items-center gap-3 py-2">
                  <.icon name="hero-arrow-path" class="size-5 animate-spin text-base-content/50" />
                  <span class="text-sm text-base-content/60">{gettext("Stopping tasks…")} <% # zh_CN: "正在优雅停止任务（保存工作并退出）" %></span>
                </div>
              <% else %>
                <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
                  {gettext("%{count} task(s) still running", count: @update_apply_busy_count)} <% # zh_CN: "任务计数：用 task(s) 表达单复数，避免拆分复数形式" %>
                </p>
                <p class="text-sm text-base-content/60 mb-5 leading-relaxed">
                  {gettext(
                    "The update can only be applied when no tasks are running. Gracefully stopping tasks asks their agents to save their work and finish; results are preserved for review."
                  )} <% # zh_CN: "优雅停止：智能体保存工作后正常退出，结果保留可审阅" %>
                </p>

                <div class="flex justify-end gap-3 pt-2">
                  <button
                    type="button"
                    class="btn btn-ghost rounded-md px-6"
                    phx-click="defer_apply_update"
                  >
                    {gettext("Defer")} <% # zh_CN: "稍后处理" %>
                  </button>
                  <button
                    type="button"
                    class="btn btn-primary rounded-md px-6 gap-2"
                    phx-click="confirm_apply_graceful"
                  >
                    <.icon name="hero-check" class="size-4.5" />
                    {gettext("Apply & gracefully stop tasks")} <% # zh_CN: "应用更新并优雅停止任务" %>
                  </button>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @update_card_visible and @update_force_kill_count != nil do %>
          <!-- Software Update force-kill modal (wind-down timed out) -->
          <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
            <div
              class="fixed inset-0 bg-black/50 backdrop-blur-sm"
              phx-click="cancel_force_kill_update"
            >
            </div>
            <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-200 max-w-lg w-full p-6 md:p-8">
              <div class="flex items-center gap-3 mb-4">
                <.icon name="hero-exclamation-triangle" class="size-5 text-error" />
                <h3 class="text-lg font-bold">{gettext("Force Kill & Update?")}</h3>
              </div>

              <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
                {gettext("%{count} task(s) still running after waiting",
                  count: @update_force_kill_count
                )} <% # zh_CN: "等待后仍有任务在运行" %>
              </p>
              <p class="text-sm text-error/80 font-semibold mb-5 leading-relaxed">
                {gettext("In-flight work will be lost and tasks will need manual review.")} <% # zh_CN: "未保存的工作将丢失，任务需人工复核" %>
              </p>

              <div class="flex justify-end gap-3 pt-2">
                <button
                  type="button"
                  class="btn btn-ghost rounded-md px-6"
                  phx-click="cancel_force_kill_update"
                >
                  {gettext("Cancel")}
                </button>
                <button
                  type="button"
                  class="btn btn-error rounded-md px-6 gap-2"
                  phx-click="confirm_force_kill_update"
                >
                  <.icon name="hero-power" class="size-4.5" />
                  {gettext("Force Kill & Update")} <% # zh_CN: "强制终止任务并更新" %>
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <%= if @update_card_visible and @changelog_open and changelog_notes?(@update_status) do %>
          <!-- Update changelog modal (release notes from the update feed) -->
          <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
            <div
              class="fixed inset-0 bg-black/50 backdrop-blur-sm"
              phx-click="close_changelog"
            >
            </div>
            <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-200 max-w-2xl w-full p-6 md:p-8">
              <div class="flex items-center gap-3 mb-4">
                <.icon name="hero-document-text" class="size-5 text-info" />
                <h3 class="text-lg font-bold">
                  {gettext("Update changelog")} <% # zh_CN: "更新日志" %>
                </h3>
              </div>

              <div class="max-h-[70vh] overflow-y-auto text-sm text-base-content/80 whitespace-pre-wrap pr-1">
                {@update_status.notes}
              </div>

              <div class="flex justify-end gap-3 pt-4">
                <button
                  type="button"
                  class="btn btn-ghost rounded-md px-6"
                  phx-click="close_changelog"
                >
                  {gettext("Close")} <% # zh_CN: "关闭" %>
                </button>
              </div>
            </div>
          </div>
        <% end %>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "scheduler_config")
      # Scheduler-status chart samples: the evo_git system sampler broadcasts
      # `{:system_sample, node, seq, sample}` on this topic every 3s.
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "system")
      # Software Update card: subscribe to `EvoDash.UpdateStatus` hub
      # transitions. Idempotent to subscribe from the same pid, so this stays
      # correct even after workstream B's on_mount hook adds a second
      # subscription to the same topic.
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "updates")
      spawn_system_checks(socket)
    end

    socket =
      assign(socket,
        remote?: false,
        # Safe default — the node-aware paused state is loaded asynchronously
        # in handle_params/3 (never block the initial render on a node RPC).
        scheduler_paused: false,
        show_restart_confirm: false,
        show_stop_confirm: false,
        system_checks_status: :checking,
        config_status: nil,
        tool_check: nil,
        sandbox_check: nil,
        supervisor_check: nil,
        nix_check: nil,
        # Local fast-path only: the mount's `current_node` is always local/nil
        # (NodeAware seeds it before mount; remote resolution happens in
        # handle_params), so this is a cheap host call. Remote nodes get
        # `:unknown` here and are filled in by the async handle_params load.
        platform_os:
          if socket.assigns[:current_node] in [nil, node()] do
            EvoDashWeb.PlatformInfo.os_for_node(socket.assigns[:current_node])
          else
            :unknown
          end,
        chart_samples: [],
        # Selected model profile for the LLM Slots chart — nil until samples
        # carrying `llm_slots` arrive; resolution re-defaults to the first id
        # (see resolve_selected_llm_model/2).
        selected_llm_model: nil,
        chart_node: nil,
        # Monotonic sequence for async sample-seed results (never reset — see
        # spawn_sample_seed/1). `chart_seed_retried` gates the one-shot retry
        # after a failed seed (reset to false on node change).
        chart_seed_seq: 0,
        chart_seed_retried: false,
        # Software Update card assigns (visibility is recomputed in
        # handle_params/3 after assign_node; modal ids are nil-guarded no-ops).
        update_card_visible: false,
        update_status: EvoDash.UpdateStatus.get(),
        update_apply_busy_count: nil,
        update_force_kill_count: nil,
        update_winddown: false,
        changelog_open: false,
        # Genesis Source card assigns (visibility is recomputed in
        # handle_params/3 after assign_node; local-only by design — a remote
        # genesis_remote daemon's self-reflective agent reads the REMOTE host's
        # filesystem). `source_status_seq` is a monotonic spawn sequence,
        # never reset (mirrors `chart_seed_seq`).
        source_card_visible: false,
        source_status: nil,
        source_status_loading: false,
        source_busy: nil,
        source_status_seq: 0
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Detect whether the node context is changing (e.g. user switched from
    # Local to a remote target via ?node= navigation, or vice versa). When it
    # changes, clear stale confirmation modal flags so a restart/stop modal
    # opened on the local node doesn't persist (and potentially get confirmed)
    # after switching to a remote node.
    previous_remote? = socket.assigns[:remote?]

    # NOTE: `remote?` must be derived from the socket AFTER `assign_node/2`
    # re-assigns `current_node` — computing it inside the pipe from the outer
    # `socket` variable would read the PRE-assign_node value, so a page load at
    # a connected `?node=` URL would render as local (restart/stop would act on
    # the LOCAL VM while the user is viewing a remote node).
    socket = EvoDashWeb.LiveHooks.NodeAware.assign_node(socket, params)
    socket = assign(socket, :current_path, ~p"/system")
    socket = assign(socket, :remote?, socket.assigns.current_node != node())

    # Load the node-dependent values (scheduler paused state + platform OS for
    # sandbox/nix row gating) ASYNCHRONOUSLY — each is a cross-node RPC on a
    # remote node, which could otherwise block navigation for up to the RPC
    # timeout. Results arrive via handle_info, stale-guarded on the node the
    # request was made for. Initial render keeps the mount defaults. Both this
    # and the chart seed below are gated on `connected?(socket)`: handle_params
    # runs twice per page load (dead render + live websocket mount), and a task
    # spawned from the dead render sends its result to a process that is gone —
    # the live mount's handle_params re-runs and does the real work.
    socket = if connected?(socket), do: spawn_node_loads(socket), else: socket

    # Reset the chart ring buffer + seed state when the node context changes so
    # charts never mix samples from different nodes. Each node gets ONE async
    # seed RPC (the "system" topic only carries live samples — there is no
    # replay), filling the buffer with the sampler's recent history.
    socket =
      if socket.assigns[:chart_node] != socket.assigns.current_node do
        socket =
          socket
          |> assign(:chart_node, socket.assigns.current_node)
          |> assign(:chart_samples, [])
          |> assign(:selected_llm_model, nil)
          |> assign(:chart_seed_retried, false)

        if connected?(socket), do: spawn_sample_seed(socket), else: socket
      else
        socket
      end

    # Software Update card: visibility is desktop-only and hidden on remote
    # nodes. The mount-triggered check fires once — the `phase == :idle` guard
    # makes re-triggers on patches impossible (after the first check the hub
    # leaves :idle until explicitly reset).
    socket =
      assign(
        socket,
        :update_card_visible,
        EvoDashWeb.SystemLive.UpdateCard.visible?(socket.assigns.current_node)
      )

    socket =
      if socket.assigns.update_card_visible and connected?(socket) and
           EvoDash.UpdateStatus.phase() == :idle do
        EvoDash.UpdateStatus.check_started()
        socket = Phoenix.LiveView.push_event(socket, "update_check_requested", %{})
        EvoDashWeb.SystemLive.UpdateCard.spawn_check_watchdog(self())
        socket
      else
        socket
      end

    # Genesis Source card: local-only (a remote genesis_remote daemon's
    # self-reflective agent reads the REMOTE host's filesystem, so clone/update
    # must never act remotely). When visible, load the status asynchronously —
    # the dead render's task sends to a dead process, so the live handle_params
    # re-spawns (connected? gate).
    socket =
      assign(
        socket,
        :source_card_visible,
        EvoDashWeb.SystemLive.SourceCard.visible?(socket.assigns.current_node)
      )

    socket =
      if socket.assigns.source_card_visible and connected?(socket) do
        spawn_source_status_load(socket)
      else
        socket
      end

    socket =
      if previous_remote? != nil and previous_remote? != socket.assigns.remote? do
        # Node context changed — clear stale confirm flags.
        socket
        |> assign(:show_restart_confirm, false)
        |> assign(:show_stop_confirm, false)
        |> assign(:changelog_open, false)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("rerun_checks", _params, socket) do
    spawn_system_checks(socket)

    socket =
      assign(socket,
        system_checks_status: :checking,
        config_status: nil,
        tool_check: nil,
        sandbox_check: nil,
        supervisor_check: nil,
        nix_check: nil
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_llm_model", %{"model" => id}, socket) do
    # Chip click from the in-card LLM Slots model selector. The choice is
    # clamped by the SAME deterministic rule as every samples-change path
    # (resolve_selected_llm_model/2): an id no longer present in the ring
    # buffer (e.g. a model profile removed from config while stale samples
    # remain) falls back to the first available id. Ids are user-config
    # strings — never converted to atoms.
    {:noreply,
     assign(
       socket,
       :selected_llm_model,
       resolve_selected_llm_model(id, socket.assigns.chart_samples)
     )}
  end

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    node = socket.assigns.current_node
    remote? = node != node()

    if socket.assigns.scheduler_paused do
      # Resume the scheduler
      if remote? do
        EvoDash.NodeContext.call_remote(node, EvoGit.AgentScheduler, :resume, [])
      else
        EvoGit.AgentScheduler.resume()
      end

      {:noreply,
       socket
       |> assign(:scheduler_paused, false)
       # GENESIS_TERM: Scheduler → 调度器, Agent → 智能体
       |> put_flash(
         :info,
         gettext("Scheduler resumed. New agents and slots are being granted.")
       )}
    else
      # Pause the scheduler
      if remote? do
        EvoDash.NodeContext.call_remote(node, EvoGit.AgentScheduler, :pause, [])
      else
        EvoGit.AgentScheduler.pause()
      end

      {:noreply,
       socket
       |> assign(:scheduler_paused, true)
       |> put_flash(
         :info,
         # GENESIS_TERM: Scheduler → 调度器, Agent → 智能体
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
    if socket.assigns.remote? do
      # Restart the remote node via RPC. The :erpc call to System.restart/0
      # tears down the remote VM mid-call, so the RPC failure is expected —
      # restart_remote/1 always returns :ok.
      EvoDash.NodeContext.restart_remote(socket.assigns.current_node)

      {:noreply,
       socket
       |> assign(:show_restart_confirm, false)
       |> put_flash(
         :info,
         gettext("Remote node is restarting. Please wait for it to come back up, then reconnect.")
       )}
    else
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
    if socket.assigns.remote? do
      EvoDash.NodeContext.stop_remote(socket.assigns.current_node)

      {:noreply,
       socket
       |> assign(:show_stop_confirm, false)
       |> put_flash(
         :info,
         gettext("Remote node is stopping. It will need to be started again on the remote host.")
       )}
    else
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
  end

  @impl true
  def handle_event("retry_remote_connection", _params, socket) do
    EvoDash.NodeContext.connect(socket.assigns.current_node_id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_to_local", _params, socket) do
    send(self(), {:node_selected, "local"})
    {:noreply, socket}
  end

  # --- Genesis Source card events (no-ops unless the card is visible) ---

  @impl true
  def handle_event("clone_source", _params, socket) do
    if source_card_visible?(socket) and socket.assigns[:source_busy] == nil do
      socket = assign(socket, :source_busy, :clone)
      {:noreply, spawn_source_load(socket, :clone)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_source", _params, socket) do
    if source_card_visible?(socket) and socket.assigns[:source_busy] == nil do
      socket = assign(socket, :source_busy, :update)
      {:noreply, spawn_source_load(socket, :update)}
    else
      {:noreply, socket}
    end
  end

  # --- Software Update card events (all no-ops unless the card is visible) ---

  @impl true
  def handle_event("check_for_updates", _params, socket) do
    if update_card_visible?(socket) do
      EvoDash.UpdateStatus.check_started()
      socket = Phoenix.LiveView.push_event(socket, "update_check_requested", %{})
      EvoDashWeb.SystemLive.UpdateCard.spawn_check_watchdog(self())
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("download_update", _params, socket) do
    if update_card_visible?(socket) do
      {:noreply, Phoenix.LiveView.push_event(socket, "update_download_requested", %{})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("request_apply_update", _params, socket) do
    if update_card_visible?(socket) do
      count = length(EvoDashWeb.SystemLive.UpdateCard.active_task_ids(:gate))

      if count == 0 do
        # No tasks running — apply directly (no modal).
        {:noreply, EvoDashWeb.SystemLive.UpdateCard.proceed_apply(socket)}
      else
        {:noreply, assign(socket, :update_apply_busy_count, count)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_apply_update", _params, socket) do
    # (Idle-confirm modal variant — unused today; kept for the event surface.)
    if update_card_visible?(socket) do
      {:noreply, EvoDashWeb.SystemLive.UpdateCard.proceed_apply(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("defer_apply_update", _params, socket) do
    if update_card_visible?(socket) do
      {:noreply, assign(socket, :update_apply_busy_count, nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_apply_graceful", _params, socket) do
    if update_card_visible?(socket) do
      # Graceful-cancel every active task, then wind down: poll until the list
      # empties (or the deadline passes), then apply.
      for id <- EvoDashWeb.SystemLive.UpdateCard.active_task_ids(:gate) do
        EvoDashWeb.SystemLive.UpdateCard.graceful_cancel(id)
      end

      EvoDashWeb.SystemLive.UpdateCard.start_winddown(self())

      {:noreply,
       socket
       |> assign(:update_apply_busy_count, nil)
       |> assign(:update_winddown, true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_force_kill_update", _params, socket) do
    if update_card_visible?(socket) do
      EvoDashWeb.SystemLive.UpdateCard.force_kill_all()

      socket =
        socket
        |> assign(:update_force_kill_count, nil)
        |> assign(:update_winddown, false)

      {:noreply, EvoDashWeb.SystemLive.UpdateCard.proceed_apply(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_force_kill_update", _params, socket) do
    if update_card_visible?(socket) do
      {:noreply,
       socket
       |> assign(:update_force_kill_count, nil)
       |> assign(:update_winddown, false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_changelog", _params, socket) do
    # Shows the update changelog modal (release notes from the update feed).
    if update_card_visible?(socket) do
      {:noreply, assign(socket, :changelog_open, true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_changelog", _params, socket) do
    if update_card_visible?(socket) do
      {:noreply, assign(socket, :changelog_open, false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:node_selected, node_id}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)
  end

  @impl true
  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)
  end

  @impl true
  def handle_info({:scheduler_config_updated, node}, socket) do
    # The broadcast fires from the node's scheduler — on a remote node a
    # local-only read would show the WRONG paused state. Node-filter first (a
    # foreign node's scheduler broadcast must not touch this view), then reload
    # node-aware (and async, so the broadcast never blocks the LiveView on a
    # cross-node RPC).
    if EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, spawn_paused_load(socket)}
    else
      {:noreply, socket}
    end
  end

  # --- Software Update card messages ---

  @impl true
  def handle_info({:update_status, state}, socket) do
    # Hub transition broadcast. (In the merged system, workstream B's on_mount
    # :handle_info interceptor consumes this message first, making this clause
    # a no-op there — kept for self-containment.)
    {:noreply, assign(socket, :update_status, state)}
  end

  @impl true
  def handle_info({:update_check_result, payload}, socket) do
    # The check-runner seam's send-pattern: feeds the hub, which broadcasts
    # the resulting state back to this view.
    EvoDash.UpdateStatus.handle_check_result(payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:update_winddown_complete}, socket) do
    # All tasks gracefully stopped — apply the update now.
    socket = assign(socket, :update_winddown, false)
    {:noreply, EvoDashWeb.SystemLive.UpdateCard.proceed_apply(socket)}
  end

  @impl true
  def handle_info({:update_winddown_timeout, count}, socket) do
    # Wind-down deadline passed with tasks still active — offer the user the
    # force-kill fallback (in-flight work will be lost).
    {:noreply,
     socket
     |> assign(:update_winddown, false)
     |> assign(:update_force_kill_count, count)}
  end

  @impl true
  def handle_info({:update_winddown_error, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:update_winddown, false)
     |> put_flash(
       :error,
       gettext("Failed to stop running tasks. The update was not applied.")
     )}
  end

  # --- Genesis Source card messages ---

  @impl true
  def handle_info({:source_status_loaded, seq, node, result}, socket) do
    if source_result_current?(socket, seq, node) do
      {:noreply,
       socket
       |> assign(:source_status, result)
       |> assign(:source_status_loading, false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:source_clone_result, seq, node, result}, socket) do
    if source_result_current?(socket, seq, node) do
      {:noreply, apply_source_mutation_result(socket, result, :clone)}
    else
      # A newer operation superseded this result (e.g. a navigation-triggered
      # status reload) — still clear the busy flag so the card never wedges on
      # a spinner; the superseding status load assigns the fresh status.
      {:noreply, assign(socket, :source_busy, nil)}
    end
  end

  @impl true
  def handle_info({:source_update_result, seq, node, result}, socket) do
    if source_result_current?(socket, seq, node) do
      {:noreply, apply_source_mutation_result(socket, result, :update)}
    else
      {:noreply, assign(socket, :source_busy, nil)}
    end
  end

  @impl true
  def handle_info({:system_checks_result, result}, socket) do
    {:noreply,
     socket
     |> assign(:system_checks_status, :done)
     |> assign(:config_status, result[:config])
     |> assign(:tool_check, result[:tools])
     |> assign(:sandbox_check, result[:sandbox])
     |> assign(:supervisor_check, result[:supervisor])
     |> assign(:nix_check, result[:nix])}
  end

  @impl true
  def handle_info({:task_updated, _task_id, _status, _node} = msg, socket) do
    # New node-identity contract on the "tasks" topic. Forward the FULL message
    # to NodeAware's task handler — it node-filters and debounces the sidebar
    # reload.
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info({:task_deleted, _task_id, _node} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    # Debounce timer fired — reload the sidebar's running/pending tasks.
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)}
  end

  @impl true
  def handle_info({:system_sample, node, _seq, sample}, socket) do
    # Push-based sample from the evo_git system sampler ("system" topic, one
    # every 3s). Node-filter first — a foreign node's samples are dropped
    # unchanged. `seq` is the publisher's monotonic sample sequence
    # (informational — samples arrive in order on the PubSub channel), and the
    # ring buffer trims itself to its capacity (Charts.push, 60 samples).
    if EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?(socket.assigns, node) do
      samples = Charts.push(socket.assigns.chart_samples, sample)

      {:noreply,
       assign(socket,
         chart_samples: samples,
         selected_llm_model:
           resolve_selected_llm_model(socket.assigns.selected_llm_model, samples)
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:paused_state, node, paused}, socket) do
    # Async node-aware paused-state result (handle_params load + the
    # {:scheduler_config_updated} broadcast reload). Stale-guard: drop results
    # that arrived after a node switch so a slow remote RPC never overwrites
    # the current node's state.
    socket =
      if socket.assigns.current_node == node do
        assign(socket, :scheduler_paused, paused)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:platform_os_result, node, os}, socket) do
    # Async platform-OS result for sandbox/nix row gating. Same node
    # stale-guard as {:paused_state, ...}.
    socket =
      if socket.assigns.current_node == node do
        assign(socket, :platform_os, os)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:system_samples_seeded, seq, node, result}, socket) do
    # Async seed-RPC result (see spawn_sample_seed/1). Stale-guard: drop
    # results from an older seed request (a newer one already spawned — its
    # result will arrive later) or from a previously-viewed node (the ring
    # buffer was reset on the node change). `seq` is monotonic across node
    # switches (never reset), so a re-visit to an earlier node cannot re-apply
    # a pre-switch seed either.
    cond do
      seq < socket.assigns.chart_seed_seq ->
        {:noreply, socket}

      node != socket.assigns.current_node ->
        {:noreply, socket}

      true ->
        case result do
          {:ok, samples} when is_list(samples) ->
            # Fill the buffer preserving order, trimmed to the ring capacity
            # (Charts.push keeps the newest 60).
            filled =
              Enum.reduce(samples, socket.assigns.chart_samples, &Charts.push(&2, &1))

            {:noreply,
             assign(socket,
               chart_samples: filled,
               selected_llm_model:
                 resolve_selected_llm_model(socket.assigns.selected_llm_model, filled)
             )}

          {:error, _reason} ->
            # One-shot retry on failure ONLY — not periodic. The retry timer is
            # scheduled exactly once (gated by `chart_seed_retried`); a second
            # failure gives up silently, leaving the chart empty until live
            # samples arrive.
            if socket.assigns.chart_seed_retried do
              {:noreply, socket}
            else
              socket = assign(socket, :chart_seed_retried, true)
              Process.send_after(self(), :system_samples_seed_retry, 3000)
              {:noreply, socket}
            end
        end
    end
  end

  @impl true
  def handle_info(:system_samples_seed_retry, socket) do
    # Retry timer from a failed seed — fires once (the failure handler above
    # set `chart_seed_retried` before scheduling it). The re-spawned seed does
    # NOT schedule a further retry on its own failure: the retry's result
    # handler sees `chart_seed_retried == true` and gives up silently.
    if socket.assigns.chart_seed_retried do
      {:noreply, spawn_sample_seed(socket)}
    else
      {:noreply, socket}
    end
  end

  # --- Private Helpers ---

  defp spawn_system_checks(socket) do
    parent = self()
    node = socket.assigns.current_node

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = safe_system_checks(node)
      send(parent, {:system_checks_result, result})
    end)
  end

  # Runs the system self-check. On a remote node, the config-status row should
  # reflect the remote node's config (via RPC); tools/sandbox/supervisor/nix are
  # inherently local to the dashboard VM, so they are NOT fetched remotely.
  defp safe_system_checks(node) when node != node() do
    base = EvoGit.SystemCheck.run_all_checks()
    remote_status = EvoDash.NodeContext.get_remote_config_status(node)
    Map.put(base, :config, remote_status)
  end

  defp safe_system_checks(_node) do
    EvoGit.SystemCheck.run_all_checks()
  end

  # Asynchronously loads the node-dependent values rendered on this page
  # (scheduler paused state + platform OS for sandbox/nix row gating). Both
  # callees are total (`NodeContext.paused?/1` → false on failure,
  # `PlatformInfo.os_for_node/1` never raises), so the tasks can never crash
  # the LiveView; results are stale-guarded in handle_info.
  defp spawn_node_loads(socket) do
    socket = spawn_paused_load(socket)

    parent = self()
    node = socket.assigns.current_node

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      send(parent, {:platform_os_result, node, EvoDashWeb.PlatformInfo.os_for_node(node)})
    end)

    socket
  end

  # Asynchronously reloads the node-aware scheduler paused state. Shared by
  # handle_params/3 and the {:scheduler_config_updated} broadcast handler —
  # the broadcast fires from the node's scheduler, so the reload must be
  # node-aware too (a local-only read would show the wrong state when viewing
  # a remote node). The local liveness gate keeps the task total on a fresh
  # boot where the scheduler process isn't running yet (`AgentScheduler.paused?`
  # would raise :noproc).
  defp spawn_paused_load(socket) do
    parent = self()
    node = socket.assigns.current_node

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      paused = if scheduler_alive?(node), do: EvoDash.NodeContext.paused?(node), else: false
      send(parent, {:paused_state, node, paused})
    end)

    socket
  end

  # Spawns ONE async seed RPC for the viewed node's recent system samples (the
  # "system" PubSub topic only carries live samples — the seed fills the ring
  # buffer with the sampler's history so charts aren't empty on load). Bumps
  # `chart_seed_seq` at spawn time: monotonic across node switches, never
  # reset — the sequence guard for `{:system_samples_seeded, ...}` result
  # application (mirrors the old chart-tick sequence). The runner is
  # injectable via the :system_samples_runner env seam, resolved AT SPAWN TIME
  # (inside the task) so tests can stub it. No try/rescue at this boundary:
  # the default runner (`NodeContext.get_recent_system_samples/1` →
  # `RemoteNode`) is total — it degrades to `{:error, reason}` (the evo_git
  # sampler stub returns `{:error, :not_implemented}`), it never raises.
  defp spawn_sample_seed(socket) do
    parent = self()
    node = socket.assigns.current_node
    seq = socket.assigns.chart_seed_seq + 1
    socket = assign(socket, :chart_seed_seq, seq)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      runner =
        Application.get_env(
          :evo_dash,
          :system_samples_runner,
          &EvoDash.NodeContext.get_recent_system_samples/1
        )

      result = runner.(node)
      send(parent, {:system_samples_seeded, seq, node, result})
    end)

    socket
  end

  # Deterministic model selection for the LLM Slots chart: keep `selected`
  # when it is still present in the samples' model ids, otherwise fall back to
  # the first id (`nil` when the buffer has no ids yet — the series then
  # renders all-zero). Shared by every samples-change path (live push, seed
  # fill) and the select_llm_model event so the plotted model never flickers
  # between stale and current profiles.
  defp resolve_selected_llm_model(selected, samples) do
    ids = Charts.llm_model_ids(samples)
    if selected in ids, do: selected, else: List.first(ids)
  end

  # Gate for the Software Update card's event handlers — all update events are
  # no-ops unless the card is visible (desktop shell + local node).
  defp update_card_visible?(socket) do
    socket.assigns[:update_card_visible] || false
  end

  # Gate for the Genesis Source card's event handlers — all source-card events
  # are no-ops unless the card is visible (local node only).
  defp source_card_visible?(socket) do
    socket.assigns[:source_card_visible] || false
  end

  # Spawns an async status load for the Genesis Source card (see
  # SourceCard.spawn_status_load/3). Bumps `source_status_seq` at spawn time —
  # monotonic, never reset (mirrors `chart_seed_seq`) — so stale results are
  # dropped by the handle_info stale-guard.
  defp spawn_source_status_load(socket) do
    spawn_source_load(socket, :status)
  end

  # Shared spawn for the Genesis Source card's three operations (status/clone/
  # update). Each runner is injectable via its app-env seam (`:source_status_
  # runner` / `:source_clone_runner` / `:source_update_runner`), resolved AT
  # SPAWN TIME inside the task (see SourceCard). The status operation also sets
  # the loading flag; clone/update set `:source_busy` in their event handlers.
  defp spawn_source_load(socket, kind) do
    parent = self()
    node = socket.assigns.current_node
    seq = socket.assigns.source_status_seq + 1
    socket = assign(socket, :source_status_seq, seq)

    case kind do
      :status ->
        EvoDashWeb.SystemLive.SourceCard.spawn_status_load(parent, seq, node)
        assign(socket, :source_status_loading, true)

      :clone ->
        EvoDashWeb.SystemLive.SourceCard.spawn_clone(parent, seq, node)
        socket

      :update ->
        EvoDashWeb.SystemLive.SourceCard.spawn_update(parent, seq, node)
        socket
    end
  end

  # Stale-guard for Genesis Source card results: drop when the result was
  # spawned for a different node or a newer spawn (status/clone/update) has
  # superseded it (seq is monotonic, never reset).
  defp source_result_current?(socket, seq, node) do
    node == socket.assigns.current_node and seq >= socket.assigns.source_status_seq
  end

  # Applies a clone/update runner result (see SourceCard for the shape
  # contract). {:ok, status} assigns the fresh status + info flash;
  # {:error, reason} flashes the failure and re-spawns a status load so the
  # card reflects reality after a failed mutation; {:unavailable, reason} (the
  # backend module is absent in this build) assigns the unavailable state.
  # Every branch clears `:source_busy` (done above) and the mutation branches
  # also clear `:source_status_loading` — a mutation that lands while a status
  # load is in flight supersedes it (the stale status result is dropped by the
  # seq stale-guard), so the card must never stay on the loading spinner.
  defp apply_source_mutation_result(socket, result, kind) do
    socket = assign(socket, :source_busy, nil)

    case result do
      {:ok, status} when is_map(status) ->
        socket
        |> assign(:source_status, status)
        |> assign(:source_status_loading, false)
        |> put_flash(:info, source_mutation_success_msg(kind))

      {:error, _reason} ->
        socket
        |> spawn_source_status_load()
        |> put_flash(:error, source_mutation_failure_msg(kind))

      {:unavailable, reason} ->
        socket
        |> assign(:source_status, {:unavailable, reason})
        |> assign(:source_status_loading, false)
        |> put_flash(:error, gettext("Genesis source is not available in this version"))

      _ ->
        # Unknown result shape (should not happen with the stable contract) —
        # never wedge the busy state; refresh the status to re-sync.
        socket
        |> spawn_source_status_load()
        |> put_flash(:error, source_mutation_failure_msg(kind))
    end
  end

  defp source_mutation_success_msg(:clone), do: gettext("Genesis source cloned.")
  defp source_mutation_success_msg(:update), do: gettext("Genesis source updated.")

  defp source_mutation_failure_msg(:clone), do: gettext("Failed to clone the Genesis source.")
  defp source_mutation_failure_msg(:update), do: gettext("Failed to update the Genesis source.")

  # Remote nodes: NodeContext RPC degrades to []/%{}/false on failure, so no
  # gate is needed. Local node: the scheduler may not be started (fresh boot,
  # dashboard-only runs), and a GenServer.call to a missing process raises
  # :noproc — use a non-crashing liveness check before sampling instead of a
  # try/rescue around the calls (project policy).
  defp scheduler_alive?(node) when node != node(), do: true

  defp scheduler_alive?(_node) do
    Process.whereis(EvoGit.AgentScheduler) != nil or :ets.info(:evogit_sched_meta) != :undefined
  end

  # --- Private Components ---

  attr(:title, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:status, :atom, default: :ok)
  slot(:details, required: true)
  slot(:fix)

  # A self-check term rendered as a card in the responsive grid. The
  # details (what was checked and the detected values) are ALWAYS rendered —
  # there is no `<details>` disclosure; the `:fix` slot renders a how-to-fix
  # hint when the term is failing (any status other than :ok/:info).
  defp check_cell(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-100">
      <div class="flex items-center gap-3 p-4">
        <div class={"p-2 rounded-md #{status_bg(@status)}"}>
          <.icon name={@icon} class={"size-4 #{status_text(@status)}"} />
        </div>
        <div class="flex-1 min-w-0 flex items-center gap-2">
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
      </div>
      <div class="px-4 pb-4 text-sm">
        {render_slot(@details)}
        <%= if @status not in [:ok, :info] and @fix != [] do %>
          <div class="mt-3 pt-3 border-t border-base-200/60 flex items-start gap-2 text-xs text-base-content/70">
            <.icon name="hero-light-bulb" class="size-3.5 text-warning shrink-0 mt-0.5" />
            <div class="min-w-0">{render_slot(@fix)}</div>
          </div>
        <% end %>
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

  attr(:update_status, :map, required: true)

  # Software Update "View changelog" link — shared by the `:available` and
  # `:ready` card states. Renders only when the update feed carried release
  # notes (nil or empty body → nothing). The notes themselves live in the
  # changelog modal (see the `changelog_open` assign) rather than inline in
  # the card, which keeps the card compact.
  defp changelog_link(assigns) do
    ~H"""
    <%= if changelog_notes?(@update_status) do %>
      <button
        id="view-changelog"
        type="button"
        phx-click="open_changelog"
        class="link link-hover text-xs text-base-content/60"
      >
        {gettext("View changelog")} <% # zh_CN: "查看更新日志" %>
      </button>
    <% end %>
    """
  end

  # Changelog content is available only when the feed's `notes` (release body)
  # is present and a non-empty string.
  defp changelog_notes?(%{notes: notes}), do: is_binary(notes) and notes != ""
  defp changelog_notes?(_status), do: false

  # --- Private Helper Functions ---

  # Builds the checks map consumed by `Status.overall_health/1`. The shown-flags
  # mirror the cell gating in the template, so sandbox/nix only count toward the
  # health light when their cells are actually rendered.
  defp health_checks(assigns) do
    %{
      supervisor: assigns.supervisor_check,
      config: assigns.config_status,
      tools: assigns.tool_check,
      sandbox: assigns.sandbox_check,
      nix: assigns.nix_check,
      sandbox_shown: EvoDashWeb.PlatformInfo.show_sandbox?(assigns.platform_os),
      nix_shown:
        assigns.nix_check != nil and assigns.nix_check.enabled and assigns.nix_check.available
    }
  end

  # Border/background classes for the overall health banner.
  defp health_banner_class(:ok), do: "border-success/40 bg-success/10"
  defp health_banner_class(:warning), do: "border-warning/40 bg-warning/10"
  defp health_banner_class(:error), do: "border-error/40 bg-error/10"
  defp health_banner_class(:loading), do: "border-base-200 bg-base-100"

  # Status background colors for check_cell
  defp status_bg(:ok), do: "bg-success/10"
  defp status_bg(:error), do: "bg-error/10"
  defp status_bg(:info), do: "bg-info/10"
  defp status_bg(:warning), do: "bg-warning/10"
  defp status_bg(_), do: "bg-base-200/50"

  # Status text colors for check_cell icon
  defp status_text(:ok), do: "text-success"
  defp status_text(:error), do: "text-error"
  defp status_text(:info), do: "text-info"
  defp status_text(:warning), do: "text-warning"
  defp status_text(_), do: "text-base-content/50"
end
