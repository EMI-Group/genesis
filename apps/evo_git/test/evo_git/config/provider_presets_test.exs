defmodule EvoGit.Config.ProviderPresetsTest do
  use ExUnit.Case, async: true

  alias EvoGit.Config.ProviderPresets
  alias EvoGit.PeakHours

  # Schedule keys a canonical provider account can consume. Anything else in a
  # preset would silently be written into config.toml without effect.
  @allowed_schedule_keys ~w(
    concurrency peak_concurrency peak_hours timezone off_peak_days off_peak_holidays
  )

  describe "shape" do
    test "every preset has the full envelope" do
      assert [_ | _] = ProviderPresets.all()

      for preset <- ProviderPresets.all() do
        assert is_binary(preset.id) and preset.id != ""
        assert is_binary(preset.label) and preset.label != ""
        assert is_atom(preset.provider)
        assert is_binary(preset.note) and preset.note != ""
        assert is_map(preset.schedule)
        assert Map.keys(preset) |> Enum.sort() == [:id, :label, :note, :provider, :schedule]
      end
    end

    test "schedule keys are STRING-keyed and stay within the account vocabulary" do
      for preset <- ProviderPresets.all() do
        assert Enum.all?(Map.keys(preset.schedule), &is_binary/1),
               "non-string schedule key in #{preset.id}"

        unknown = Map.keys(preset.schedule) -- @allowed_schedule_keys
        assert unknown == [], "unexpected schedule keys in #{preset.id}: #{inspect(unknown)}"

        refute Map.has_key?(preset.schedule, "reasoning_effort")
        refute Map.has_key?(preset.schedule, "models")
        refute String.contains?(inspect(preset.schedule), "\"max\"")
      end
    end

    test "every preset carries peak_hours and a timezone" do
      for preset <- ProviderPresets.all() do
        assert is_list(preset.schedule["peak_hours"]) and preset.schedule["peak_hours"] != []
        assert is_binary(preset.schedule["timezone"])
      end
    end

    test "ids are unique and stable strings" do
      ids = ProviderPresets.ids()
      assert ids == Enum.map(ProviderPresets.all(), & &1.id)
      assert length(ids) == length(Enum.uniq(ids))
      assert Enum.all?(ids, &(is_binary(&1) and &1 =~ ~r/^[a-z0-9-]+$/))
    end

    test "off_peak_holidays, when present, is an ISO 3166-1 alpha-2 string" do
      holidays =
        for preset <- ProviderPresets.all(),
            Map.has_key?(preset.schedule, "off_peak_holidays"),
            do: preset.schedule["off_peak_holidays"]

      assert holidays != []
      assert Enum.all?(holidays, &(is_binary(&1) and &1 =~ ~r/^[A-Z]{2}$/))
    end
  end

  describe "get/1" do
    test "fetches each preset by id" do
      for preset <- ProviderPresets.all() do
        assert ProviderPresets.get(preset.id) == preset
      end
    end

    test "unknown ids and non-binaries yield nil" do
      assert ProviderPresets.get("nope") == nil
      assert ProviderPresets.get("") == nil
      assert ProviderPresets.get(nil) == nil
      assert ProviderPresets.get(:deepseek) == nil
      assert ProviderPresets.get(42) == nil
    end
  end

  describe "for_provider/1" do
    test "accepts the provider atom" do
      for preset <- ProviderPresets.all() do
        assert preset in ProviderPresets.for_provider(preset.provider)
      end
    end

    test "accepts the provider string, case- and separator-insensitively" do
      assert ProviderPresets.for_provider("deepseek") == ProviderPresets.for_provider(:deepseek)

      assert ProviderPresets.for_provider("DeepSeek") ==
               ProviderPresets.for_provider(:deepseek)

      assert ProviderPresets.for_provider("zai_coding_plan") ==
               ProviderPresets.for_provider(:zai_coding_plan)

      assert ProviderPresets.for_provider("ZAI-Coding-Plan") ==
               ProviderPresets.for_provider(:zai_coding_plan)

      assert ProviderPresets.for_provider("zai_coding_plan") != []
    end

    test "unknown providers and nil yield []" do
      assert ProviderPresets.for_provider(nil) == []
      assert ProviderPresets.for_provider(:openai) == []
      assert ProviderPresets.for_provider("unknown-provider") == []
      assert ProviderPresets.for_provider("") == []
      assert ProviderPresets.for_provider(42) == []
      assert ProviderPresets.for_provider(%{}) == []
      # The pay-as-you-go Z.AI account has no published peak policy.
      assert ProviderPresets.for_provider(:zai) == []
    end
  end

  describe "coverage" do
    test "each covered provider has at least one preset" do
      for provider <- [:deepseek, :zai_coding_plan] do
        assert ProviderPresets.for_provider(provider) != [],
               "missing preset for #{inspect(provider)}"
      end
    end

    test "every preset's provider round-trips through for_provider/1" do
      for preset <- ProviderPresets.all() do
        assert ProviderPresets.for_provider(preset.provider) != []
        assert ProviderPresets.for_provider(Atom.to_string(preset.provider)) != []
      end
    end
  end

  describe "canonical parseability (EvoGit.PeakHours contracts)" do
    test "every peak_hours list validates" do
      for preset <- ProviderPresets.all() do
        assert {:ok, canonical} = PeakHours.validate_windows(preset.schedule["peak_hours"]),
               "invalid peak_hours in #{preset.id}"

        assert length(canonical) == length(preset.schedule["peak_hours"])
      end
    end

    test "every window days list validates" do
      for preset <- ProviderPresets.all(),
          window <- preset.schedule["peak_hours"],
          Map.has_key?(window, "days") do
        assert {:ok, days} = PeakHours.validate_days(window["days"]),
               "invalid window days in #{preset.id}"

        assert days != []
        assert Enum.all?(days, &(&1 in [:mon, :tue, :wed, :thu, :fri, :sat, :sun]))
      end
    end

    test "every off_peak_days list validates" do
      presets = Enum.filter(ProviderPresets.all(), &Map.has_key?(&1.schedule, "off_peak_days"))
      assert presets != []

      for preset <- presets, not is_nil(preset.schedule["off_peak_days"]) do
        assert {:ok, days} = PeakHours.validate_days(preset.schedule["off_peak_days"]),
               "invalid off_peak_days in #{preset.id}"

        assert days != []
      end
    end

    test "concurrency values are non-negative integers" do
      for preset <- ProviderPresets.all() do
        for key <- ["concurrency", "peak_concurrency"],
            Map.has_key?(preset.schedule, key) do
          value = preset.schedule[key]
          assert is_integer(value) and value >= 0, "bad #{key} in #{preset.id}: #{inspect(value)}"
        end
      end
    end

    test "timezones are valid IANA names against the boot-configured database" do
      for preset <- ProviderPresets.all() do
        assert :ok = PeakHours.validate_timezone(preset.schedule["timezone"]),
               "invalid timezone in #{preset.id}"
      end
    end

    test "timezone validation without a database reports :no_time_zone_database" do
      # Explicit db arg — this module is async: true, so the global tz
      # database must not be mutated.
      for preset <- ProviderPresets.all() do
        assert {:error, :no_time_zone_database} =
                 PeakHours.validate_timezone(
                   preset.schedule["timezone"],
                   Calendar.UTCOnlyTimeZoneDatabase
                 )
      end
    end

    test "presets drive effective_concurrency/3 end to end" do
      deepseek = ProviderPresets.get("deepseek-standard")

      # The schedule payload is merged into a provider account VERBATIM — that
      # is exactly what a dashboard pre-fill does.
      profile = %{
        concurrency: deepseek.schedule["concurrency"],
        peak_concurrency: deepseek.schedule["peak_concurrency"],
        peak_hours: deepseek.schedule["peak_hours"],
        off_peak_days: deepseek.schedule["off_peak_days"]
      }

      # 2025-01-15 is a Wednesday. 02:00 UTC is inside 01:00-04:00 UTC.
      assert PeakHours.effective_concurrency(profile, ~U[2025-01-15 02:00:00Z], "UTC") == 2
      # 05:00 UTC is between the two peak windows.
      assert PeakHours.effective_concurrency(profile, ~U[2025-01-15 05:00:00Z], "UTC") == 4
      # 2025-01-18 is a Saturday → off-peak the whole day.
      assert PeakHours.effective_concurrency(profile, ~U[2025-01-18 02:00:00Z], "UTC") == 4
    end
  end
end
