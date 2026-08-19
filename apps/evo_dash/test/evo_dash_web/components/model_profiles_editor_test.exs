defmodule EvoDashWeb.ModelProfilesEditorTest do
  @moduledoc """
  Render-only component tests for `EvoDashWeb.SettingsComponents.ModelProfilesEditor`,
  focused on the peak/off-peak concurrency form section.

  Render-only by design: the row events (`add_peak_hours_row` /
  `remove_peak_hours_row`) are handled by SettingsLive, not the component.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsComponents.ModelProfilesEditor

  describe "model_profiles_editor/1 — peak/off-peak concurrency fields" do
    test "editing a profile without peak fields renders an empty peak_concurrency input with min=1" do
      html = render_edit_form(%{id: "profile-1", model: "deepseek:deepseek-v4-pro"})

      assert [input] = Floki.find(parse(html), ~s(input[name="peak_concurrency"]))
      assert attribute(input, "type") == ["number"]
      assert attribute(input, "min") == ["1"]
      assert attribute(input, "value") == [""]
    end

    test "editing a profile without peak hours renders a single blank peak_hours[0] row" do
      html = render_edit_form(%{id: "profile-1", model: "deepseek:deepseek-v4-pro"})

      start_inputs = Floki.find(parse(html), ~s(input[name="peak_hours[0][start]"]))
      end_inputs = Floki.find(parse(html), ~s(input[name="peak_hours[0][end]"]))

      assert length(start_inputs) == 1
      assert length(end_inputs) == 1
      assert attr(start_inputs, 0, "type") == ["time"]
      assert attr(end_inputs, 0, "type") == ["time"]
      assert attr(start_inputs, 0, "value") == [""]
      assert attr(end_inputs, 0, "value") == [""]
    end

    test "two pre-filled windows render as peak_hours[0] and peak_hours[1] with pre-filled values" do
      profile = %{
        id: "profile-1",
        model: "deepseek:deepseek-v4-pro",
        peak_concurrency: 8,
        peak_hours: [
          %{start: "09:00", end: "12:00"},
          %{start: "14:00", end: "18:00"}
        ]
      }

      html = render_edit_form(profile)

      assert [input] = Floki.find(parse(html), ~s(input[name="peak_concurrency"]))
      assert attribute(input, "value") == ["8"]

      start0 = Floki.find(parse(html), ~s(input[name="peak_hours[0][start]"]))
      end0 = Floki.find(parse(html), ~s(input[name="peak_hours[0][end]"]))
      start1 = Floki.find(parse(html), ~s(input[name="peak_hours[1][start]"]))
      end1 = Floki.find(parse(html), ~s(input[name="peak_hours[1][end]"]))

      assert length(start0) == 1 and length(end0) == 1
      assert length(start1) == 1 and length(end1) == 1
      assert attr(start0, 0, "value") == ["09:00"]
      assert attr(end0, 0, "value") == ["12:00"]
      assert attr(start1, 0, "value") == ["14:00"]
      assert attr(end1, 0, "value") == ["18:00"]
    end

    test "the add_peak_hours_row button renders as type=button" do
      html = render_edit_form(%{id: "profile-1", model: "deepseek:deepseek-v4-pro"})

      assert [button] = Floki.find(parse(html), ~s(button[phx-click="add_peak_hours_row"]))
      assert attribute(button, "type") == ["button"]
    end

    test "remove_peak_hours_row buttons render as type=button carrying phx-value-index" do
      profile = %{
        id: "profile-1",
        model: "deepseek:deepseek-v4-pro",
        peak_hours: [
          %{start: "09:00", end: "12:00"},
          %{start: "14:00", end: "18:00"}
        ]
      }

      html = render_edit_form(profile)

      buttons = Floki.find(parse(html), ~s(button[phx-click="remove_peak_hours_row"]))
      assert length(buttons) == 2
      assert attr(buttons, 0, "type") == ["button"]
      assert attr(buttons, 0, "phx-value-index") == ["0"]
      assert attr(buttons, 1, "type") == ["button"]
      assert attr(buttons, 1, "phx-value-index") == ["1"]
    end
  end

  # --- helpers ---

  # Renders the editor with a single profile in edit mode (editing_profile_id
  # must match the profile's id string for the edit form to render).
  defp render_edit_form(profile) do
    render_component(&ModelProfilesEditor.model_profiles_editor/1,
      profiles: [profile],
      editing_profile_id: to_string(Map.get(profile, :id))
    )
  end

  defp attr(els, index, name) do
    els |> Enum.at(index) |> Floki.attribute(name) |> Enum.map(&to_string/1)
  end

  defp attribute(el, name) do
    el |> Floki.attribute(name) |> Enum.map(&to_string/1)
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
