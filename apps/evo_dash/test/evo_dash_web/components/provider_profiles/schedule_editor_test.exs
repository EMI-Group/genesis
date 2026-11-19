defmodule EvoDashWeb.SettingsComponents.ProviderProfiles.ScheduleEditorTest do
  @moduledoc """
  The schedule half of the expanded account: published provider presets, the
  inert "applied/modified" strip, the single-select holiday calendar and the
  account schedule fields it composes.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias EvoDashWeb.LLMSetup.Schedule
  alias EvoDashWeb.SettingsComponents.ProviderProfiles.ScheduleEditor

  test "renders the published preset of a provider as one apply action" do
    tree = render_editor(fields("deepseek"))

    preset = Schedule.preset("deepseek-standard")
    button = one(tree, ~s(button[phx-click="apply_provider_schedule"]))
    assert attr(button, "phx-value-preset_id") == ["deepseek-standard"]
    assert text(button) == preset.label
  end

  test "renders nothing preset-shaped for a provider without presets" do
    tree = render_editor(fields("anthropic"))

    assert Floki.find(tree, ~s(button[phx-click="apply_provider_schedule"])) == []
    refute text(tree) =~ "Recommended schedule"
    refute text(tree) =~ "DeepSeek"
  end

  test "the applied strip offers re-apply, undo and dismissal" do
    tree =
      render_editor(
        fields("deepseek"),
        schedule: %{
          preset_id: "deepseek-standard",
          applied: true,
          modified: false,
          can_undo: true
        }
      )

    strip = one(tree, "#provider-schedule-applied")
    assert text(strip) =~ "Recommended schedule applied"
    assert [reapply] = Floki.find(strip, ~s(button[phx-click="apply_provider_schedule"]))
    assert attr(reapply, "phx-value-preset_id") == ["deepseek-standard"]
    assert [_] = Floki.find(strip, ~s(button[phx-click="undo_provider_schedule"]))
    assert [_] = Floki.find(strip, ~s(button[phx-click="dismiss_schedule_applied"]))
    refute text(tree) =~ "modified after applying"
  end

  test "an inert editor has no strip at all" do
    tree = render_editor(fields("deepseek"), schedule: %{})

    assert Floki.find(tree, "#provider-schedule-applied") == []
    assert Floki.find(tree, ~s(button[phx-click="undo_provider_schedule"])) == []
  end

  test "reports a schedule modified after applying while Undo stays available" do
    tree =
      render_editor(
        fields("deepseek"),
        schedule: %{preset_id: "deepseek-standard", applied: true, modified: true, can_undo: true}
      )

    assert text(tree) =~ "Schedule modified after applying the recommendation."
    assert [_] = Floki.find(tree, ~s(button[phx-click="undo_provider_schedule"]))
  end

  test "offers exactly the real holiday calendars plus a blank none option" do
    tree = render_editor(fields("deepseek"))

    select = one(tree, ~s(select[name="off_peak_holidays"]))
    assert attr(select, "id") == ["provider-off-peak-holidays"]
    assert attr(select, "aria-describedby") == ["provider-off-peak-holidays-help"]

    assert option_values(select) == ["" | Enum.map(Schedule.holiday_options(), &elem(&1, 0))]
    assert text(one(select, ~s(option[value=""]))) == "No public-holiday calendar"
    assert text(one(tree, "#provider-off-peak-holidays-help")) == Schedule.holiday_help()
  end

  test "submits the saved calendar as the selected option" do
    tree = render_editor(Map.put(fields("deepseek"), "off_peak_holidays", "CN"))

    assert selected(one(tree, ~s(select[name="off_peak_holidays"]))) == ["CN"]
  end

  test "composes the account schedule fields without prefilling them" do
    tree = render_editor(fields("deepseek"))

    assert [_] = Floki.find(tree, "#provider-peak-schedule")
    assert Floki.find(tree, ~s(input[name="peak_concurrency"])) != []
    assert Floki.find(tree, ~s(input[name="timezone"])) != []
    # Nothing is applied on render: the fields stay exactly as the draft has them.
    assert attr(one(tree, ~s(input[name="peak_concurrency"])), "value") == [""]
  end

  defp render_editor(fields, opts \\ []) do
    render_component(
      &ScheduleEditor.schedule_editor/1,
      Keyword.merge([fields: fields], opts)
    )
    |> Floki.parse_document!()
  end

  defp fields(provider) do
    %{
      "id" => "account-a",
      "provider" => provider,
      "auth_mode" => "api_key",
      "concurrency" => "4",
      "peak_concurrency" => "",
      "off_peak_holidays" => "",
      "off_peak_days" => []
    }
  end

  defp one(tree, selector) do
    assert [node] = Floki.find(tree, selector)
    node
  end

  defp attr(node, name), do: Floki.attribute(node, name)

  defp text(tree), do: tree |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp option_values(select), do: select |> Floki.find("option") |> Floki.attribute("value")

  defp selected(select), do: select |> Floki.find("option[selected]") |> Floki.attribute("value")
end
