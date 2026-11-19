defmodule EvoDashWeb.SettingsComponents.ProviderProfiles.ScheduleEditor do
  @moduledoc """
  The SCHEDULE half of the expanded provider-account editor.

  It composes three things that must never be confused with one another:

    * the account's schedule FIELDS — `ProviderProfileFields.provider_schedule/1`
      (concurrency, peak capacity, windows, timezone, always-off-peak days),
      extended HERE with the single-select public-holiday calendar so the shared
      field module stays untouched;
    * the provider's PUBLISHED presets (`EvoDashWeb.LLMSetup.Schedule`), each a
      one-click `apply_provider_schedule` action;
    * the recommendation STRIP — "applied" / "modified after applying" plus
      re-apply, `undo_provider_schedule` and dismiss.

  Rendering is inert: nothing is prefilled and nothing is overwritten unless the
  user clicks a preset (`apply_provider_schedule`) or undo. The owner holds the
  only state that matters here (`:schedule`), so this module stays pure.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.LLMSetup.Schedule

  import EvoDashWeb.SettingsComponents.ProviderProfileFields,
    only: [provider_schedule: 1, value: 2, value: 3]

  attr :fields, :map, required: true
  attr :schedule, :map, default: %{}

  def schedule_editor(assigns) do
    provider = value(assigns.fields, "provider")

    assigns =
      assigns
      |> assign(:provider, provider)
      |> assign(:presets, Schedule.presets_for_provider(provider))
      |> assign(:preset_id, Map.get(assigns.schedule, :preset_id))
      |> assign(:applied, Map.get(assigns.schedule, :applied, false) == true)
      |> assign(:modified, Map.get(assigns.schedule, :modified, false) == true)
      |> assign(:can_undo, Map.get(assigns.schedule, :can_undo, false) == true)
      |> assign(:selected_holiday, value(assigns.fields, "off_peak_holidays", ""))
      |> assign(:holiday_options, Schedule.holiday_options())
      |> assign(:holiday_help, Schedule.holiday_help())

    ~H"""
    <div id="provider-schedule-editor" class="space-y-3">
      <div :if={@presets != []} class="flex flex-wrap items-center gap-2">
        <span class="text-xs font-medium text-base-content/70">
          {gettext("Recommended schedule")}
        </span>
        <button
          :for={preset <- @presets}
          type="button"
          phx-click="apply_provider_schedule"
          phx-value-preset_id={preset.id}
          title={Map.get(preset, :note)}
          class="btn btn-ghost btn-xs"
        >
          {preset.label}
        </button>
      </div>

      <div
        :if={@applied}
        id="provider-schedule-applied"
        role="status"
        class="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-info/30 bg-info/10 px-3 py-2"
      >
        <span class="text-xs font-medium text-base-content">
          {gettext("Recommended schedule applied")}
        </span>
        <div class="flex flex-wrap items-center gap-1">
          <button
            :if={@preset_id not in [nil, ""]}
            type="button"
            phx-click="apply_provider_schedule"
            phx-value-preset_id={@preset_id}
            class="btn btn-ghost btn-xs"
          >
            {gettext("Re-apply")}
          </button>
          <button
            :if={@can_undo}
            type="button"
            phx-click="undo_provider_schedule"
            class="btn btn-ghost btn-xs"
          >
            {gettext("Undo")}
          </button>
          <button
            type="button"
            phx-click="dismiss_schedule_applied"
            aria-label={gettext("Dismiss schedule notice")}
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </div>
      </div>

      <p :if={@applied and @modified} class="text-xs text-warning">
        {gettext("Schedule modified after applying the recommendation.")}
      </p>

      <fieldset class="rounded-lg border border-base-300 p-3">
        <%!-- zh_CN: 非高峰假期（法定节假日全天按非高峰计费/调度） --%>
        <legend class="px-1 text-xs font-medium text-base-content/70">
          {gettext("Off-peak public-holiday calendar")}
        </legend>
        <select
          id="provider-off-peak-holidays"
          name="off_peak_holidays"
          class="select select-sm w-full rounded-md border-base-300 bg-base-100"
          aria-describedby="provider-off-peak-holidays-help"
        >
          <option value="" selected={@selected_holiday in [nil, ""]}>
            {gettext("No public-holiday calendar")}
          </option>
          <option
            :for={{value, label} <- @holiday_options}
            value={value}
            selected={value == @selected_holiday}
          >
            {label}
          </option>
        </select>
        <p id="provider-off-peak-holidays-help" class="mt-1 text-xs text-base-content/70">
          {@holiday_help}
        </p>
      </fieldset>

      <.provider_schedule fields={@fields} />
    </div>
    """
  end
end
