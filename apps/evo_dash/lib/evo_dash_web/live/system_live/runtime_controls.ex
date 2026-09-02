defmodule EvoDashWeb.SystemLive.RuntimeControls do
  @moduledoc """
  Scheduler + system controls section for `EvoDashWeb.SystemLive`.

  The bottom "runtime controls" row of the System page: the scheduler
  pause/resume card and the system restart/stop card, rendered SIDE BY SIDE in
  a two-column grid (stacked on mobile). Extracted from `system_live.ex` as
  part of the layout re-arrangement that moved these controls to the very
  bottom of the page.

  Pure markup — all behavior stays in the LiveView event handlers
  (`toggle_pause`, `request_restart`, `request_stop` and the confirmation
  modals rendered by `system_live.ex`).
  """

  use Phoenix.Component
  use Gettext, backend: EvoDashWeb.Gettext
  import EvoDashWeb.CoreComponents, only: [icon: 1]

  attr(:scheduler_paused, :boolean, required: true)

  @doc """
  The full controls row: a two-column grid (`grid-cols-1 md:grid-cols-2`) with
  the scheduler pause/resume card and the system restart/stop card.
  """
  def controls_section(assigns) do
    ~H"""
    <div id="runtime-controls" class="grid grid-cols-1 md:grid-cols-2 gap-3">
      <!-- Scheduler Control card -->
      <div class="rounded-lg border border-base-200 bg-base-100 p-4 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div class="flex items-center gap-3 min-w-0">
          <.icon
            name={if @scheduler_paused, do: "hero-pause-circle", else: "hero-play-circle"}
            class={"size-5 shrink-0 " <>
              if(@scheduler_paused, do: "text-warning", else: "text-success")}
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
          <.icon
            name={if @scheduler_paused, do: "hero-play", else: "hero-pause"}
            class="size-5 mr-2"
          />
          {if @scheduler_paused, do: gettext("Resume Scheduler"), else: gettext("Pause Scheduler")} <% # zh_CN: "调度器" %>
        </button>
      </div>

      <!-- System Control card (destructive actions) -->
      <div class="rounded-lg border border-error/30 bg-error/5 p-4 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div class="flex items-start gap-3 min-w-0">
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
    """
  end
end
