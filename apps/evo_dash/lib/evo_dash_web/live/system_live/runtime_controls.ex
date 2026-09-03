defmodule EvoDashWeb.SystemLive.RuntimeControls do
  @moduledoc """
  The grouped "System Controls" section for `EvoDashWeb.SystemLive`.

  The LAST content section of the System page: ONE section
  (`id="system-controls"`) holding the three system-control-related cards —
  **System Dashboard** (link to `/dashboard`), **Scheduler Control**
  (pause/resume) and **System Control** (VM restart/stop) — rendered as three
  VERTICAL cards in a responsive grid (`grid-cols-1 md:grid-cols-2
  lg:grid-cols-3`) so all three sit on ONE line on wide screens and stack on
  narrow ones. The old standalone System Dashboard link card and the former
  two-column runtime-controls row were merged into this section.

  Pure markup — all behavior stays in the LiveView event handlers
  (`toggle_pause`, `request_restart`, `request_stop` and the confirmation
  modals rendered by `system_live.ex`). The dashboard link path is passed in
  as `dashboard_path` (computed in `system_live.ex` via `with_node_param/2`,
  keeping this component free of `~p`/`with_node_param` imports).
  """

  use Phoenix.Component
  use Gettext, backend: EvoDashWeb.Gettext
  import EvoDashWeb.CoreComponents, only: [icon: 1]

  attr(:scheduler_paused, :boolean, required: true)
  attr(:dashboard_path, :string, required: true)

  @doc """
  The full System Controls section: light section header + a responsive grid
  (`grid-cols-1 md:grid-cols-2 lg:grid-cols-3`) with the System Dashboard,
  Scheduler Control, and System Control vertical cards.
  """
  def controls_section(assigns) do
    ~H"""
    <div id="system-controls" class="mt-4">
      <div class="p-4 border-b border-base-300">
        <div class="flex items-center gap-3">
          <.icon name="hero-adjustments-horizontal" class="size-5 text-info shrink-0" />
          <div class="flex-1 min-w-0">
            <h2 class="font-bold text-base">
              {gettext("System Controls")} <% # zh_CN: "系统控制（系统仪表盘、调度器与虚拟机控制分组）" %>
            </h2>
            <p class="text-sm text-base-content/60">
              {gettext(
                "The system dashboard, scheduler pause/resume, and Erlang VM restart/stop controls."
              )} <% # zh_CN: "系统仪表盘、调度器暂停/恢复与 Erlang VM 重启/停止" %>
            </p>
          </div>
        </div>
      </div>
      <div id="runtime-controls" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3 p-4">
        <!-- Scheduler Control card -->
        <div class="rounded-lg border border-base-200 bg-base-100 p-4 flex flex-col gap-3">
          <div class="flex items-center gap-3 min-w-0">
            <div class={"p-2 rounded-md shrink-0 " <>
              if(@scheduler_paused, do: "bg-warning/10", else: "bg-success/10")}>
              <.icon
                name={if @scheduler_paused, do: "hero-pause-circle", else: "hero-play-circle"}
                class={"size-5 " <>
                  if(@scheduler_paused, do: "text-warning", else: "text-success")}
              />
            </div>
            <h3 class="text-base font-bold tracking-tight">
              {if @scheduler_paused,
                do: gettext("Scheduler Paused"),
                else: gettext("Scheduler Active")} <% # zh_CN: "调度器" %>
            </h3>
          </div>
          <p class="text-sm text-base-content/60 flex-1">
            <%= if @scheduler_paused do %>
              {gettext(
                "Running agents continue. No new slots or agents will be granted until resumed."
              )} <% # zh_CN: "智能体" %>
            <% else %>
              {gettext("Agents and slots are being granted normally.")} <% # zh_CN: "智能体" %>
            <% end %>
          </p>
          <button
            type="button"
            phx-click="toggle_pause"
            class={[
              "btn rounded-md font-medium self-start",
              if(@scheduler_paused,
                do: "bg-success/20 hover:bg-success/30 text-success-content",
                else: "bg-warning/20 hover:bg-warning/30 text-warning-content"
              )
            ]}
          >
            <.icon
              name={if @scheduler_paused, do: "hero-play", else: "hero-pause"}
              class="size-5 mr-2"
            />
            {if @scheduler_paused, do: gettext("Resume Scheduler"), else: gettext("Pause Scheduler")} <% # zh_CN: "调度器" %>
          </button>
        </div>

        <!-- System Dashboard card (link to the full-bleed LiveDashboard iframe) -->
        <.link navigate={@dashboard_path} class="block h-full">
          <div class="rounded-lg border border-base-200 bg-base-100 p-4 flex flex-col gap-3 h-full hover:border-base-300 transition-colors">
            <div class="flex items-center gap-3 min-w-0">
              <div class="p-2 rounded-md bg-info/10 shrink-0">
                <.icon name="hero-chart-bar" class="size-5 text-info" />
              </div>
              <h3 class="text-base font-bold tracking-tight">{gettext("System Dashboard")}</h3>
            </div>
            <p class="text-sm text-base-content/60 flex-1">
              {gettext("View system metrics, processes, and application telemetry")}
            </p>
            <span class="flex items-center gap-1 text-sm font-medium text-base-content/70 self-start">
              {gettext("Open")} <% # zh_CN: "打开系统仪表盘" %>
              <.icon name="hero-arrow-right" class="size-4 text-base-content/30" />
            </span>
          </div>
        </.link>

        <!-- System Control card (destructive actions) -->
        <div class="rounded-lg border border-error/30 bg-error/5 p-4 flex flex-col gap-3">
          <div class="flex items-center gap-3 min-w-0">
            <div class="p-2 rounded-md bg-error/10 shrink-0">
              <.icon name="hero-power" class="size-5 text-error" />
            </div>
            <h3 class="text-base font-bold tracking-tight text-error">
              {gettext("System Control")}
            </h3>
          </div>
          <p class="text-sm text-base-content/60 flex-1">
            {gettext(
              "Gracefully restart or stop the Erlang VM. Restart tears down and restarts all applications; stop gracefully shuts down the VM and it must be started again manually. In-memory runtime state will be lost in both cases."
            )} <% # zh_CN: "平滑重启", "运行时" %>
          </p>
          <div class="flex flex-wrap gap-3">
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
    </div>
    """
  end
end
