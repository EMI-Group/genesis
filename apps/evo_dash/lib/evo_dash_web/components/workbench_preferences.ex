defmodule EvoDashWeb.WorkbenchPreferences do
  @moduledoc false
  use EvoDashWeb, :html

  attr(:class, :string, default: nil, doc: "extra classes from the host window")

  def panel(assigns) do
    assigns =
      assign(assigns,
        locale: Gettext.get_locale(EvoDashWeb.Gettext),
        languages: EvoDashWeb.Layouts.supported_languages(),
        accents: EvoDashWeb.SettingsComponents.SettingCard.accent_palette()
      )

    ~H"""
    <section id="workbench-preferences" class={["workbench-preferences", @class]}>
      <h2>{gettext("Appearance")}</h2>
      <p>{gettext("These preferences apply to this browser across all Genesis connections.")}</p>
      <div class="workbench-preference-row">
        <label for="workbench-theme">{gettext("Theme")}</label>
        <select id="workbench-theme" data-workbench-preference="theme">
          <option value="system">{gettext("System theme")}</option>
          <option value="light">{gettext("Light theme")}</option>
          <option value="dark">{gettext("Dark theme")}</option>
        </select>
      </div>
      <div class="workbench-preference-row">
        <label for="workbench-language">{gettext("Language")}</label>
        <select id="workbench-language" data-workbench-preference="locale">
          <option :for={{code, label} <- @languages} value={code} selected={@locale == code}>
            {label}
          </option>
        </select>
      </div>
      <div class="workbench-preference-row">
        <label for="workbench-accent">{gettext("Accent Color")}</label>
        <select id="workbench-accent" data-workbench-preference="accent">
          <option value="">{gettext("Use instance default")}</option>
          <option :for={accent <- @accents} value={accent}>{accent_name(accent)}</option>
        </select>
      </div>
    </section>
    """
  end

  defp accent_name("blue"), do: gettext("Blue")
  defp accent_name("teal"), do: gettext("Teal")
  defp accent_name("green"), do: gettext("Green")
  defp accent_name("yellow"), do: gettext("Yellow")
  defp accent_name("orange"), do: gettext("Orange")
  defp accent_name("red"), do: gettext("Red")
  defp accent_name("pink"), do: gettext("Pink")
  defp accent_name("purple"), do: gettext("Purple")
  defp accent_name("slate"), do: gettext("Slate")
  defp accent_name(accent), do: String.capitalize(accent)
end
