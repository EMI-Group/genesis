defmodule EvoDashWeb.SystemLive do
  @moduledoc """
  System page: scheduler and system controls (pause/resume, restart/stop)
  and system self-check.
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
    >
      <%= if EvoDashWeb.RemoteGateComponents.gate_active?(assigns) do %>
        <%= EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns) %>
      <% else %>
      <!-- Scheduler Control banner -->
      <div class="p-4 mb-6 border-b border-slate-200 dark:border-slate-800 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
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

      <!-- System Control section (destructive actions) -->
      <div class="border border-error/30 bg-error/5 p-4 mb-6 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
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

      <!-- System Self-Check -->
      <div>
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
          <div
            class={"rounded-lg border p-4 mb-4 flex items-start gap-3 #{health_banner_class(health.status)}"}
          >
            <%= case health.status do %>
              <% :ok -> %>
                <.icon name="hero-check-circle-solid" class="size-6 text-success shrink-0" />
              <% :warning -> %>
                <.icon name="hero-exclamation-triangle-solid" class="size-6 text-warning shrink-0" />
              <% :error -> %>
                <.icon name="hero-x-circle-solid" class="size-6 text-error shrink-0" />
              <% :loading -> %>
                <.icon name="hero-arrow-path" class="size-6 text-base-content/40 animate-spin shrink-0" />
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
              <!-- Check terms in a responsive 2D grid -->
              <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
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
                      <div>{gettext("Install git and make sure it is available on your PATH.")}</div>
                    <% end %>
                    <%= if @tool_check.rg.available == false do %>
                      <div>{gettext("Install ripgrep and make sure it is available on your PATH.")}</div>
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
                        <span class={"badge badge-sm #{case @sandbox_check.backend do :systemd_run -> "badge-success"; :sandbox_exec -> "badge-info"; _ -> "badge-ghost" end}"}>
                          {Status.format_backend(@sandbox_check.backend)}
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
                    <:fix>
                      <%= case @sandbox_check.backend do %>
                        <% :systemd_run -> %>
                          {gettext("Enable or install systemd-run. Sandboxing requires a systemd user session.")}
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
                        {gettext("Checks the Nix development environment used for reproducible builds.")}
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
                      {gettext("Check that your LLM provider is reachable with the configured API key.")}
                    </p>
                    <div class="flex items-center gap-3">
                      <span class="text-sm text-base-content/60">{gettext(
                        "LLM connection testing is now available on the Settings page."
                      )}</span>
                      <.link
                        navigate={~p"/settings?category=llm#{if @current_node_id, do: "&node=#{@current_node_id}", else: ""}"}
                        class="btn btn-primary btn-sm gap-2"
                      >
                        <.icon name="hero-sparkles" class="size-4" />
                        {gettext("Test in Settings")}
                      </.link>
                    </div>
                  </:details>
                </.check_cell>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <!-- System Dashboard -->
      <div class="mt-4">
        <.link navigate={with_node_param(~p"/dashboard", @current_node_id)} class="block">
          <div class="rounded-lg border border-base-200 bg-base-100 p-4 hover:border-base-300 transition-colors">
            <div class="flex items-center gap-3">
              <.icon name="hero-chart-bar" class="size-5 text-info shrink-0" />
              <div class="flex-1">
                <h3 class="font-semibold text-base">{gettext("System Dashboard")}</h3>
                <p class="text-sm text-base-content/60 mt-0.5">
                  {gettext("View system metrics, processes, and application telemetry")}
                </p>
              </div>
              <.icon name="hero-arrow-right" class="size-5 text-base-content/30" />
            </div>
          </div>
        </.link>
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
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "scheduler_config")
      spawn_system_checks(socket)
    end

    socket =
      assign(socket,
        remote?: false,
        scheduler_paused: load_paused_state(),
        show_restart_confirm: false,
        show_stop_confirm: false,
        system_checks_status: :checking,
        config_status: nil,
        tool_check: nil,
        sandbox_check: nil,
        supervisor_check: nil,
        nix_check: nil,
        platform_os: EvoDashWeb.PlatformInfo.os_for_node(socket.assigns[:current_node])
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
    # Recompute the platform OS for the (possibly remote) node AFTER assign_node
    # so sandbox/nix row gating reflects the node being viewed.
    socket =
      assign(
        socket,
        :platform_os,
        EvoDashWeb.PlatformInfo.os_for_node(socket.assigns.current_node)
      )

    socket =
      assign(socket, :scheduler_paused, EvoDash.NodeContext.paused?(socket.assigns.current_node))

    socket =
      if previous_remote? != nil and previous_remote? != socket.assigns.remote? do
        # Node context changed — clear stale confirm flags.
        socket
        |> assign(:show_restart_confirm, false)
        |> assign(:show_stop_confirm, false)
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

  @impl true
  def handle_info({:node_selected, node_id}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)
  end

  @impl true
  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)
  end

  @impl true
  def handle_info({:scheduler_config_updated}, socket) do
    {:noreply, assign(socket, :scheduler_paused, load_paused_state())}
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
  def handle_info({:tasks_updated}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, :tasks_updated)
  end

  @impl true
  def handle_info({:task_status, _task_id, _status}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, :task_status)
  end

  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    # Debounce timer fired — reload the sidebar's running/pending tasks.
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)}
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

  defp load_paused_state do
    Map.get(EvoGit.AgentScheduler.get_config(), :paused, false)
  end

  # --- Private Components ---

  attr(:title, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:status, :atom, default: :ok)
  slot(:details, required: true)
  slot(:fix)

  # A self-check term rendered as a card in the responsive 2D grid. The
  # `<details>` disclosure expands to show what was checked and the detected
  # values; the `:fix` slot renders a how-to-fix hint when the term is
  # failing (any status other than :ok/:info).
  defp check_cell(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-100">
      <details class="group">
        <summary class="flex items-center gap-3 p-4 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
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
          <.icon
            name="hero-chevron-down"
            class="size-4 text-base-content/30 transition-transform group-open:rotate-180 shrink-0"
          />
        </summary>
        <div class="px-4 pb-4 text-sm">
          {render_slot(@details)}
          <%= if @status not in [:ok, :info] and @fix != [] do %>
            <div class="mt-3 pt-3 border-t border-base-200/60 flex items-start gap-2 text-xs text-base-content/70">
              <.icon name="hero-light-bulb" class="size-3.5 text-warning shrink-0 mt-0.5" />
              <div class="min-w-0">{render_slot(@fix)}</div>
            </div>
          <% end %>
        </div>
      </details>
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
