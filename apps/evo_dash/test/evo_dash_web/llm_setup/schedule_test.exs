defmodule EvoDashWeb.LLMSetup.ScheduleTest do
  @moduledoc """
  Pins the pure schedule-preset adapter over the core inventory and holiday
  table: apply writes schedule keys ONLY, the snapshot/undo cycle restores the
  pre-preset state exactly, and the holiday vocabulary is total.
  """

  use ExUnit.Case, async: true

  alias EvoGit.PeakHours.Holidays
  alias EvoDashWeb.LLMSetup.Schedule

  @deepseek "deepseek-standard"

  @identity_and_auth_keys ~w(id name api_key_env_var auth_mode oauth_file default_model)

  # One string-keyed account draft with identity, auth and model data in it.
  defp draft do
    %{
      "id" => "deepseek-2",
      "name" => "DeepSeek",
      "api_key_env_var" => "DEEPSEEK_API_KEY",
      "auth_mode" => "api_key",
      "default_model" => "deepseek-flash"
    }
  end

  describe "presets_for_provider/1 and preset/1" do
    test "returns the deepseek standard preset for the atom and its string spelling" do
      assert [%{id: @deepseek}] = Schedule.presets_for_provider(:deepseek)
      assert [%{id: @deepseek}] = Schedule.presets_for_provider("deepseek")
      assert [%{id: @deepseek}] = Schedule.presets_for_provider(" DeepSeek ")
    end

    test "returns an empty list for a provider without a published policy" do
      assert Schedule.presets_for_provider(:openrouter) == []
      assert Schedule.presets_for_provider("openrouter") == []
      assert Schedule.presets_for_provider(nil) == []
      assert Schedule.presets_for_provider(42) == []
    end

    test "fetches one preset by id and is nil-safe" do
      assert %{id: @deepseek, provider: :deepseek} = Schedule.preset(@deepseek)
      assert Schedule.preset("does-not-exist") == nil
      assert Schedule.preset(nil) == nil
      assert Schedule.preset(:deepseek) == nil
    end
  end

  describe "schedule_keys/0" do
    test "is exactly the account schedule keys" do
      assert Schedule.schedule_keys() == [
               "concurrency",
               "peak_concurrency",
               "peak_hours",
               "timezone",
               "off_peak_days",
               "off_peak_holidays"
             ]
    end

    test "never names an identity, auth or model key" do
      for key <- @identity_and_auth_keys do
        refute key in Schedule.schedule_keys()
      end
    end
  end

  describe "apply/2" do
    test "merges the preset schedule into a string-keyed draft and returns the pre-apply snapshot" do
      {applied, snapshot} = Schedule.apply(@deepseek, draft())

      assert snapshot == %{}

      assert applied["concurrency"] == 4
      assert applied["peak_concurrency"] == 2
      assert applied["timezone"] == "UTC"
      assert applied["off_peak_days"] == ["sat", "sun"]
      assert applied["off_peak_holidays"] == "CN"

      assert applied["peak_hours"] == [
               %{"start" => "01:00", "end" => "04:00", "days" => ["weekdays"]},
               %{"start" => "06:00", "end" => "10:00", "days" => ["weekdays"]}
             ]
    end

    test "never touches identity, auth or model keys" do
      {applied, _snapshot} = Schedule.apply(@deepseek, draft())

      for key <- @identity_and_auth_keys do
        assert applied[key] == draft()[key]
      end
    end

    test "string-keys peak-hour rows that arrive atom-keyed" do
      preset = %{
        id: "custom",
        schedule: %{"peak_hours" => [%{start: "22:00", end: "02:00", days: [:mon]}]}
      }

      {applied, _snapshot} = Schedule.apply(preset, %{})

      assert applied["peak_hours"] == [%{"start" => "22:00", "end" => "02:00", "days" => [:mon]}]
    end

    test "writes schedule keys only, even when the preset carries other keys" do
      preset = %{
        "id" => "hostile",
        "schedule" => %{"concurrency" => 3, "api_key_env_var" => "HIJACKED", "name" => "x"}
      }

      {applied, _snapshot} = Schedule.apply(preset, draft())

      assert applied["concurrency"] == 3
      assert applied["api_key_env_var"] == "DEEPSEEK_API_KEY"
      assert applied["name"] == "DeepSeek"
    end

    test "returns a normalized, unchanged draft and a valid snapshot for nil/unknown presets" do
      atom_keyed = %{concurrency: 2}

      assert {applied, snapshot} = Schedule.apply(nil, atom_keyed)
      assert applied == %{"concurrency" => 2}
      assert snapshot == %{"concurrency" => 2}

      assert {applied, snapshot} = Schedule.apply("does-not-exist", draft())
      assert applied == draft()
      assert snapshot == %{}
    end

    test "omits off_peak_holidays for a preset that publishes no holiday exclusion" do
      {applied, _snapshot} = Schedule.apply("zai-glm-coding-plan", %{})

      assert applied["timezone"] == "Asia/Singapore"
      assert applied["peak_concurrency"] == 2
      refute Map.has_key?(applied, "off_peak_holidays")
    end
  end

  describe "snapshot/1" do
    test "covers only the schedule keys that are present" do
      assert Schedule.snapshot(draft()) == %{}

      assert Schedule.snapshot(%{"concurrency" => 4, "id" => "x", "name" => "Y"}) ==
               %{"concurrency" => 4}
    end

    test "reads atom keys and string-keys nested window rows" do
      assert Schedule.snapshot(%{concurrency: 2, peak_hours: [%{start: "01:00", end: "04:00"}]}) ==
               %{
                 "concurrency" => 2,
                 "peak_hours" => [%{"start" => "01:00", "end" => "04:00"}]
               }
    end

    test "is total for non-map input" do
      assert Schedule.snapshot(nil) == %{}
      assert Schedule.snapshot("junk") == %{}
      assert Schedule.snapshot([]) == %{}
    end
  end

  describe "undo/2 and changed?/2" do
    test "restores prior values and drops the keys the preset introduced" do
      original =
        Map.merge(draft(), %{
          "concurrency" => 1,
          "timezone" => "Asia/Tokyo",
          "off_peak_days" => ["sun"]
        })

      {applied, snapshot} = Schedule.apply(@deepseek, original)
      assert Schedule.changed?(applied, snapshot)

      restored = Schedule.undo(applied, snapshot)

      refute Schedule.changed?(restored, snapshot)
      assert restored == original
    end

    test "leaves unrelated keys untouched" do
      {applied, snapshot} = Schedule.apply(@deepseek, draft())
      restored = Schedule.undo(applied, snapshot)

      assert restored["id"] == "deepseek-2"
      assert restored["api_key_env_var"] == "DEEPSEEK_API_KEY"
      assert restored["default_model"] == "deepseek-flash"
    end

    test "changed?/2 is false for an untouched draft and true after an apply" do
      snapshot = Schedule.snapshot(draft())

      refute Schedule.changed?(draft(), snapshot)

      {applied, snapshot} = Schedule.apply(@deepseek, draft())
      assert Schedule.changed?(applied, snapshot)
    end

    test "undo/2 accepts an atom-keyed draft and normalizes it" do
      {applied, snapshot} = Schedule.apply(@deepseek, %{concurrency: 1})
      restored = Schedule.undo(applied, snapshot)

      assert restored == %{"concurrency" => 1}
    end
  end

  describe "summary_rows/1" do
    test "renders the applied schedule in display order" do
      {applied, _snapshot} = Schedule.apply(@deepseek, draft())

      assert Schedule.summary_rows(applied) == [
               {"Concurrency", "4"},
               {"Peak concurrency", "2"},
               {"Peak hours", "01:00–04:00 (weekdays) · 06:00–10:00 (weekdays)"},
               {"Timezone", "UTC"},
               {"Off-peak days", "sat, sun"},
               {"Off-peak public holidays", "China (CN)"}
             ]
    end

    test "drops blank values and is empty for a draft with no schedule" do
      assert Schedule.summary_rows(%{}) == []

      assert Schedule.summary_rows(%{"timezone" => "", "off_peak_days" => []}) == []
    end

    test "keeps zero concurrency and shows an unknown holiday calendar as-is" do
      assert Schedule.summary_rows(%{"concurrency" => 0}) == [{"Concurrency", "0"}]

      assert Schedule.summary_rows(%{"off_peak_holidays" => "US"}) == [
               {"Off-peak public holidays", "US"}
             ]
    end

    test "formats a single window without days and is total for non-map input" do
      assert Schedule.summary_rows(%{"peak_hours" => [%{"start" => "01:00", "end" => "04:00"}]}) ==
               [{"Peak hours", "01:00–04:00"}]

      assert Schedule.summary_rows(nil) == []
    end
  end

  describe "holiday calendars" do
    test "holiday_calendars/0 lists the core's calendars" do
      assert Schedule.holiday_calendars() == ["CN"]
      assert Schedule.holiday_calendars() == Holidays.calendars()
    end

    test "holiday_label/1 localizes the real calendar and degrades total" do
      assert Schedule.holiday_label("CN") == "China (CN)"
      assert Schedule.holiday_label("cn") == "China (CN)"
      assert Schedule.holiday_label(:cn) == "China (CN)"
      assert Schedule.holiday_label(nil) == "No public-holiday calendar"
      assert Schedule.holiday_label("") == "No public-holiday calendar"
      assert Schedule.holiday_label("US") == "US"
    end

    test "holiday_options/0 pairs every real calendar with its label" do
      assert Schedule.holiday_options() == [{"CN", "China (CN)"}]
    end

    test "the supported year range is an ordered integer pair" do
      assert {first, last} = Schedule.holidays_supported_year_range()
      assert is_integer(first)
      assert is_integer(last)
      assert first <= last

      assert {first, last} == Holidays.supported_years() |> Enum.min_max()
    end

    test "holiday_help/0 is a non-empty explanation naming the published range" do
      help = Schedule.holiday_help()

      assert is_binary(help)
      assert String.trim(help) != ""
      assert help =~ "off-peak"

      {_first, last} = Schedule.holidays_supported_year_range()
      assert help =~ Integer.to_string(last)
    end
  end
end
