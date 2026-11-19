defmodule EvoDashWeb.SettingsComponents.ProviderWizard.ReasoningStep do
  @moduledoc """
  Renderer behind
  `EvoDashWeb.SettingsComponents.ProviderWizard.step_reasoning_schedule/1`.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.LLMSetup.Reasoning
  alias EvoDashWeb.LLMSetup.Schedule
  alias EvoDashWeb.SettingsComponents.ProviderWizard.Helpers

  import Helpers, only: [clean_string: 1, label_or_id: 2, value_of: 2]

  def step_reasoning_schedule(assigns) do
    assigns =
      assigns
      |> assign(:inventory_values, Reasoning.normalize_inventory(assigns.inventory))
      |> assign(:inventory_name, assigns.inventory_name || Reasoning.inventory_input_name())
      |> assign(:default_name, assigns.default_name || Reasoning.default_input_name())
      |> assign(:default_value, default_select_value(assigns))
      |> assign(:chips, reasoning_chips(assigns.inventory))
      |> assign(:preset_rows, preset_rows(assigns.presets))
      |> assign(:applied_label, applied_preset_label(assigns.preset_applied))
      |> assign(:holiday_choices, holiday_choices(assigns))
      |> assign(:holiday_value, clean_string(assigns.off_peak_holidays))
      |> assign(:holiday_help_text, assigns.holiday_help || Schedule.holiday_help())
      |> assign(:rows, schedule_summary_rows(assigns.schedule_rows))

    ~H"""
    <div class="space-y-6">
      <fieldset>
        <legend class="mb-1 text-sm font-medium text-base-content">
          {gettext("Reasoning efforts this model accepts")}
        </legend>
        <p class="mb-3 text-xs text-base-content/60">
          {gettext(
            "Pick every effort level you want offered for this model, in the provider's own vocabulary."
          )}
        </p>
        <input type="hidden" name={@inventory_name} value="" />
        <div class="flex flex-wrap gap-2">
          <label :for={chip <- @chips} class={reasoning_chip_class(chip.checked)}>
            <input
              type="checkbox"
              name={@inventory_name}
              value={chip.value}
              checked={chip.checked}
              class="checkbox checkbox-sm"
            />
            <span class="text-sm">{chip.label}</span>
          </label>
        </div>
      </fieldset>

      <div :if={@inventory_values != []}>
        <label for="default-reasoning-effort" class="mb-1 block text-sm font-medium text-base-content">
          {gettext("Default reasoning effort")}
        </label>
        <select
          id="default-reasoning-effort"
          name={@default_name}
          class="select select-bordered select-sm w-full rounded-md sm:w-72"
        >
          <option value="" selected={@default_value == ""}>{gettext("Provider default")}</option>
          <option
            :for={effort <- @inventory_values}
            value={effort}
            selected={effort == @default_value}
          >
            {Reasoning.label(effort)}
          </option>
        </select>
      </div>

      <div
        :if={@applied_label || @preset_rows != []}
        class="rounded-lg border border-base-300 bg-base-200/40 p-4"
      >
        <div :if={@applied_label} class="flex flex-wrap items-center justify-between gap-3">
          <p class="flex items-center gap-2 text-sm font-medium text-base-content">
            <.icon name="hero-check-circle" class="size-4 text-primary" />
            {gettext("Recommended schedule applied")}
            <span class="font-normal text-base-content/60">· {@applied_label}</span>
          </p>
          <div class="flex items-center gap-2">
            <button
              :for={preset <- @preset_rows}
              type="button"
              phx-click={@preset_apply_event}
              phx-value-preset_id={preset.id}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Re-apply")}
            </button>
            <button type="button" phx-click={@preset_undo_event} class="btn btn-ghost btn-xs">
              {gettext("Undo")}
            </button>
            <button
              :if={@preset_dismiss_event}
              type="button"
              phx-click={@preset_dismiss_event}
              class="btn btn-ghost btn-xs btn-square"
              aria-label={gettext("Dismiss")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>

        <div :if={@preset_rows != []} class={if(@applied_label, do: "mt-3", else: "")}>
          <p class="mb-2 text-xs font-medium text-base-content/70">
            {gettext("Published schedule presets")}
          </p>
          <div class="flex flex-wrap gap-2">
            <button
              :for={preset <- @preset_rows}
              type="button"
              phx-click={@preset_apply_event}
              phx-value-preset_id={preset.id}
              class="btn btn-outline btn-xs"
              title={preset.note}
            >
              {preset.label}
            </button>
          </div>
        </div>
      </div>

      <div>
        <label for="off-peak-holidays" class="mb-1 block text-sm font-medium text-base-content">
          {gettext("Off-peak public-holiday calendar")}
        </label>
        <select
          id="off-peak-holidays"
          name="off_peak_holidays"
          class="select select-bordered select-sm w-full rounded-md sm:w-72"
        >
          <option value="" selected={@holiday_value == ""}>
            {Schedule.holiday_label(nil)}
          </option>
          <option
            :for={{value, label} <- @holiday_choices}
            value={value}
            selected={value == @holiday_value}
          >
            {label}
          </option>
        </select>
        <p class="mt-1 text-xs text-base-content/60">{@holiday_help_text}</p>
      </div>

      <div :if={@rows != []}>
        <p class="mb-2 text-xs font-medium text-base-content/70">{gettext("Schedule")}</p>
        <dl class="divide-y divide-base-300 rounded-lg border border-base-300">
          <div :for={{label, value} <- @rows} class="flex items-start justify-between gap-4 px-3 py-2">
            <dt class="text-xs text-base-content/60">{label}</dt>
            <dd class="text-right text-xs font-medium text-base-content">{value}</dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  defp reasoning_chips(inventory) do
    normalized = Reasoning.normalize_inventory(inventory)
    seen = MapSet.new(normalized)

    canonical =
      Enum.map(Reasoning.efforts(), fn effort ->
        %{value: effort, label: Reasoning.label(effort), checked: MapSet.member?(seen, effort)}
      end)

    extras =
      normalized
      |> Enum.reject(&Reasoning.level?/1)
      |> Enum.map(fn value -> %{value: value, label: Reasoning.label(value), checked: true} end)

    canonical ++ extras
  end

  defp default_select_value(assigns) do
    value = Reasoning.canonical(assigns.default_effort)

    if value != nil and value in Reasoning.normalize_inventory(assigns.inventory) do
      value
    else
      ""
    end
  end

  defp reasoning_chip_class(true) do
    "flex cursor-pointer items-center gap-2 rounded-lg border border-primary bg-primary/5 px-3 py-1.5"
  end

  defp reasoning_chip_class(_checked?) do
    "flex cursor-pointer items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-3 py-1.5"
  end

  defp preset_rows(presets) when is_list(presets) do
    presets
    |> Enum.map(fn
      %{} = preset ->
        id = clean_string(value_of(preset, ["id"]))
        label = label_or_id(value_of(preset, ["label", "name"]), id)
        note = clean_string(value_of(preset, ["note"]))

        case id do
          blank when blank in [nil, ""] -> nil
          id -> %{id: id, label: label, note: note}
        end

      _preset ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp preset_rows(_presets), do: []

  defp applied_preset_label(nil), do: nil
  defp applied_preset_label(""), do: nil
  defp applied_preset_label(true), do: nil

  defp applied_preset_label(%{} = preset) do
    id = clean_string(value_of(preset, ["id"]))
    label_or_id(value_of(preset, ["label", "name"]), id)
  end

  defp applied_preset_label(value), do: clean_string(value)

  defp holiday_choices(assigns) do
    options =
      case assigns.holiday_options do
        options when is_list(options) and options != [] -> options
        _ -> Schedule.holiday_options()
      end

    Enum.map(options, fn
      {value, label} ->
        {clean_string(value), to_string(label)}

      %{} = option ->
        {clean_string(value_of(option, ["value"])), to_string(value_of(option, ["label"]))}

      value ->
        {clean_string(value), clean_string(value)}
    end)
  end

  defp schedule_summary_rows(rows) when is_list(rows) do
    rows
    |> Enum.map(fn
      {label, value} -> {to_string(label), to_string(value)}
      %{} = row -> {to_string(value_of(row, ["label"])), to_string(value_of(row, ["value"]))}
      _row -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp schedule_summary_rows(_rows), do: []
end
