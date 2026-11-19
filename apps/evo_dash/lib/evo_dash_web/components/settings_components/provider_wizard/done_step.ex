defmodule EvoDashWeb.SettingsComponents.ProviderWizard.DoneStep do
  @moduledoc """
  Renderer behind `EvoDashWeb.SettingsComponents.ProviderWizard.step_done/1`.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.SettingsComponents.ProviderWizard.Helpers

  import Helpers, only: [clean_string: 1, value_of: 2]

  def step_done(assigns) do
    assigns =
      assigns
      |> assign(:rows, done_rows(assigns.summary))
      |> assign(:dashboard_label, assigns.dashboard_label || gettext("Go to the dashboard"))

    ~H"""
    <div class="space-y-5">
      <p class="text-sm text-base-content/70">
        {gettext(
          "Your provider account is ready. Genesis can start tasks with this configuration now."
        )}
      </p>

      <dl :if={@rows != []} class="divide-y divide-base-300 rounded-lg border border-base-300">
        <div :for={{label, value} <- @rows} class="flex items-start justify-between gap-4 px-3 py-2">
          <dt class="text-xs text-base-content/60">{label}</dt>
          <dd class="text-right text-sm font-medium text-base-content">{value}</dd>
        </div>
      </dl>

      <div class="flex flex-wrap items-center gap-2">
        <a href={@dashboard_path} class="btn btn-primary btn-sm">{@dashboard_label}</a>
        {render_slot(@secondary)}
      </div>
    </div>
    """
  end

  defp done_rows(summary) when is_list(summary) do
    summary
    |> Enum.map(fn
      {label, value} -> done_row(label, value)
      %{} = row -> done_row(value_of(row, ["label"]), value_of(row, ["value"]))
      _row -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp done_rows(_summary), do: []

  defp done_row(label, value) do
    case {clean_string(label), clean_string(value)} do
      {blank, _value} when blank in [nil, ""] -> nil
      {_label, blank} when blank in [nil, ""] -> nil
      {label, value} -> {label, value}
    end
  end
end
