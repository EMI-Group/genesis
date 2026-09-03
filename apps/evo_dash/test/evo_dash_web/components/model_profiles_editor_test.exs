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
    test "editing a profile without peak fields renders an empty peak_concurrency input with min=0" do
      html = render_edit_form(%{id: "profile-1", model: "deepseek:deepseek-v4-pro"})

      assert [input] = Floki.find(parse(html), ~s(input[name="peak_concurrency"]))
      assert attribute(input, "type") == ["number"]
      assert attribute(input, "min") == ["0"]
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

    test "the edit form carries phx-change for draft-tracking" do
      html = render_edit_form(%{id: "profile-1", model: "deepseek:deepseek-v4-pro"})

      assert [form] = Floki.find(parse(html), ~s(form[phx-submit="save_model_profile"]))
      assert attribute(form, "phx-change") == ["model_profile_form_change"]
    end

    test "timezone input renders with placeholder and pre-fills the saved timezone" do
      html = render_edit_form(%{id: "profile-1", model: "deepseek:deepseek-v4-pro"})

      assert [input] = Floki.find(parse(html), ~s(input[name="timezone"]))
      assert attribute(input, "type") == ["text"]
      assert attribute(input, "placeholder") == ["Asia/Shanghai"]
      assert attribute(input, "value") == [""]

      html =
        render_edit_form(%{
          id: "profile-1",
          model: "deepseek:deepseek-v4-pro",
          timezone: "Asia/Shanghai"
        })

      assert [input] = Floki.find(parse(html), ~s(input[name="timezone"]))
      assert attribute(input, "value") == ["Asia/Shanghai"]
    end

    test "peak_concurrency 0 pre-fills as \"0\" in the input" do
      html =
        render_edit_form(%{
          id: "profile-1",
          model: "deepseek:deepseek-v4-pro",
          peak_concurrency: 0
        })

      assert [input] = Floki.find(parse(html), ~s(input[name="peak_concurrency"]))
      assert attribute(input, "value") == ["0"]
    end

    test "a form draft pre-fills every input, including draft peak_hours rows" do
      profile = %{
        id: "profile-1",
        model: "deepseek:deepseek-v4-pro",
        concurrency: 3,
        peak_concurrency: 8,
        peak_hours: [%{start: "09:00", end: "12:00"}],
        temperature: 0.7
      }

      draft = %{
        "profile_id" => "profile-1",
        "profile_id_new" => "renamed",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "base_url" => "https://proxy.example.com/v1",
        "concurrency" => "5",
        "peak_concurrency" => "0",
        "timezone" => "Asia/Shanghai",
        "peak_hours" => [
          %{start: "14:00", end: "18:00"},
          %{start: "20:00", end: "22:00"}
        ],
        "temperature" => "0.2"
      }

      html = render_edit_form(profile, draft: draft)

      # Every draft value wins over the profile's saved value.
      assert attr(find(html, ~s(input[name="profile_id_new"])), 0, "value") == ["renamed"]
      assert attr(find(html, ~s(input[name="provider"])), 0, "value") == ["anthropic"]
      assert attr(find(html, ~s(input[name="model_id"])), 0, "value") == ["claude-sonnet-4-6"]

      assert attr(find(html, ~s(input[name="base_url"])), 0, "value") == [
               "https://proxy.example.com/v1"
             ]

      assert attr(find(html, ~s(input[name="concurrency"])), 0, "value") == ["5"]
      assert attr(find(html, ~s(input[name="peak_concurrency"])), 0, "value") == ["0"]
      assert attr(find(html, ~s(input[name="timezone"])), 0, "value") == ["Asia/Shanghai"]
      assert attr(find(html, ~s(input[name="temperature"])), 0, "value") == ["0.2"]

      # The draft's peak_hours row list is authoritative (count AND values).
      start0 = find(html, ~s(input[name="peak_hours[0][start]"]))
      end0 = find(html, ~s(input[name="peak_hours[0][end]"]))
      start1 = find(html, ~s(input[name="peak_hours[1][start]"]))
      end1 = find(html, ~s(input[name="peak_hours[1][end]"]))

      assert length(start0) == 1 and length(end0) == 1
      assert length(start1) == 1 and length(end1) == 1
      assert attr(start0, 0, "value") == ["14:00"]
      assert attr(end0, 0, "value") == ["18:00"]
      assert attr(start1, 0, "value") == ["20:00"]
      assert attr(end1, 0, "value") == ["22:00"]
      # The draft's row count (2) wins over the profile's single row.
      refute find(html, ~s(input[name="peak_hours[2][start]"])) != []
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

    test "profile edit form renders the off_peak_days hidden seed and 9 day chips" do
      html = render_edit_form(%{id: "profile-1", model: "deepseek:deepseek-v4-pro"})

      assert [seed] = find(html, ~s(input[type="hidden"][name="off_peak_days"][value=""]))
      assert attribute(seed, "type") == ["hidden"]
      assert attribute(seed, "value") == [""]

      chips = find(html, ~s(input[type="checkbox"][name="off_peak_days"]))
      assert length(chips) == 9
      values = Enum.map(chips, fn chip -> attribute(chip, "value") |> hd() end)
      assert values == ~w(mon tue wed thu fri sat sun weekdays weekends)
    end

    test "off_peak_days chips reflect the profile's saved off_peak_days" do
      profile = %{
        id: "profile-1",
        model: "deepseek:deepseek-v4-pro",
        off_peak_days: ["mon", "weekends"]
      }

      html = render_edit_form(profile)

      assert_day_chips(html, ~s(input[type="checkbox"][name="off_peak_days"]), ["mon", "weekends"])
    end

    test "a form draft's off_peak_days wins over the profile's saved value" do
      profile = %{
        id: "profile-1",
        model: "deepseek:deepseek-v4-pro",
        off_peak_days: ["mon"]
      }

      html = render_edit_form(profile, draft: %{"off_peak_days" => ["fri", "weekends"]})

      assert_day_chips(html, ~s(input[type="checkbox"][name="off_peak_days"]), ["fri", "weekends"])
    end

    test "a draft's off_peak_days as a BARE STRING renders without crashing (regression)" do
      # The exact crash repro: a draft (or any source) holding the raw
      # single-checked-chip value — a binary, not a list — previously crashed
      # the chip membership test with "protocol Enumerable not implemented for
      # BitString". The render is now total: the value is normalized at the
      # boundary so only "weekends" renders checked.
      html =
        render_edit_form(%{id: "profile-1", model: "deepseek:deepseek-v4-pro"},
          draft: %{"off_peak_days" => "weekends"}
        )

      assert_day_chips(html, ~s(input[type="checkbox"][name="off_peak_days"]), ["weekends"])
    end

    test "a draft's off_peak_days as an odd shape (atom list) renders all-unchecked" do
      html =
        render_edit_form(%{id: "profile-1", model: "deepseek:deepseek-v4-pro"},
          draft: %{"off_peak_days" => [930]}
        )

      assert_day_chips(html, ~s(input[type="checkbox"][name="off_peak_days"]), [])
    end

    test "a draft's per-window days as a bare string renders without crashing" do
      profile = %{
        id: "profile-1",
        model: "deepseek:deepseek-v4-pro",
        peak_hours: [%{start: "09:00", end: "12:00", days: "tue"}]
      }

      html = render_edit_form(profile)

      assert_day_chips(
        html,
        ~s(input[type="checkbox"][name="peak_hours[0][days]"]),
        ["tue"]
      )
    end

    test "per-window days chips render checked for a window's saved days" do
      profile = %{
        id: "profile-1",
        model: "deepseek:deepseek-v4-pro",
        peak_hours: [%{start: "09:00", end: "12:00", days: ["tue", "thu"]}]
      }

      html = render_edit_form(profile)

      assert_day_chips(
        html,
        ~s(input[type="checkbox"][name="peak_hours[0][days]"]),
        ["tue", "thu"]
      )

      # No hidden seed for window days — absent = every day.
      refute find(html, ~s(input[type="hidden"][name="peak_hours[0][days]"])) != []
    end

    test "a window without days renders all day chips unchecked" do
      profile = %{
        id: "profile-1",
        model: "deepseek:deepseek-v4-pro",
        peak_hours: [%{start: "09:00", end: "12:00"}]
      }

      html = render_edit_form(profile)

      chips = find(html, ~s(input[type="checkbox"][name="peak_hours[0][days]"]))
      assert length(chips) == 9
      assert Enum.all?(chips, fn chip -> Floki.attribute(chip, "checked") == [] end)

      refute find(html, ~s(input[type="hidden"][name="peak_hours[0][days]"])) != []
    end

    test "multiple windows thread the days index per window" do
      profile = %{
        id: "profile-1",
        model: "deepseek:deepseek-v4-pro",
        peak_hours: [
          %{start: "09:00", end: "12:00", days: ["mon"]},
          %{start: "14:00", end: "18:00", days: ["fri"]}
        ]
      }

      html = render_edit_form(profile)

      assert_day_chips(html, ~s(input[type="checkbox"][name="peak_hours[0][days]"]), ["mon"])
      assert_day_chips(html, ~s(input[type="checkbox"][name="peak_hours[1][days]"]), ["fri"])
    end

    test "peak-hours row keeps start/end inputs and remove button alongside the days chips" do
      profile = %{
        id: "profile-1",
        model: "deepseek:deepseek-v4-pro",
        peak_hours: [%{start: "09:00", end: "12:00", days: ["mon"]}]
      }

      html = render_edit_form(profile)

      start_inputs = find(html, ~s(input[name="peak_hours[0][start]"]))
      end_inputs = find(html, ~s(input[name="peak_hours[0][end]"]))
      assert length(start_inputs) == 1 and length(end_inputs) == 1
      assert attr(start_inputs, 0, "type") == ["time"]
      assert attr(end_inputs, 0, "type") == ["time"]
      assert attr(start_inputs, 0, "value") == ["09:00"]
      assert attr(end_inputs, 0, "value") == ["12:00"]

      assert [remove] = find(html, ~s(button[phx-click="remove_peak_hours_row"]))
      assert attribute(remove, "type") == ["button"]
      assert attribute(remove, "phx-value-index") == ["0"]

      # The days chips coexist in the same row.
      assert length(find(html, ~s(input[type="checkbox"][name="peak_hours[0][days]"]))) == 9
    end
  end

  # --- helpers ---

  # Renders the editor with a single profile in edit mode (editing_profile_id
  # must match the profile's id string for the edit form to render). An
  # optional `draft:` keyword sets the profile_form_draft assign (simulates a
  # phx-change snapshot of the typed form).
  defp render_edit_form(profile, opts \\ []) do
    render_component(&ModelProfilesEditor.model_profiles_editor/1,
      profiles: [profile],
      editing_profile_id: to_string(Map.get(profile, :id)),
      profile_form_draft: Keyword.get(opts, :draft)
    )
  end

  defp find(html, selector) do
    Floki.find(parse(html), selector)
  end

  # Asserts a day-chip group (profile-level off_peak_days or per-window days):
  # exactly 9 checkboxes carrying the full day vocabulary, where exactly the
  # values in `checked` carry the checked attribute and all others do not.
  # `selector` selects the chip inputs, e.g.
  # ~s(input[type="checkbox"][name="off_peak_days"]).
  defp assert_day_chips(html, selector, checked) do
    chips = find(html, selector)
    assert length(chips) == 9

    values = Enum.map(chips, fn chip -> attribute(chip, "value") |> hd() end)
    assert Enum.sort(values) == Enum.sort(~w(mon tue wed thu fri sat sun weekdays weekends))

    for value <- ~w(mon tue wed thu fri sat sun weekdays weekends) do
      [chip] = find(html, ~s(#{selector}[value="#{value}"]))

      if value in checked do
        assert Floki.attribute(chip, "checked") != []
      else
        assert Floki.attribute(chip, "checked") == []
      end
    end
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
