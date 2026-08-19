defmodule EvoGit.PeakHoursTest do
  use ExUnit.Case, async: true

  alias EvoGit.PeakHours

  doctest EvoGit.PeakHours

  # Canonical windows used across tests.
  # 09:00-12:00
  @morning [%{start: 540, end: 720}]
  # 09:00-12:00, 14:00-18:00
  @morning_afternoon [%{start: 540, end: 720}, %{start: 840, end: 1080}]
  # 22:00-06:00
  @overnight [%{start: 1320, end: 360}]

  describe "parse_time/1" do
    test "parses valid 24h times to minute-of-day" do
      assert PeakHours.parse_time("00:00") == {:ok, 0}
      assert PeakHours.parse_time("00:01") == {:ok, 1}
      assert PeakHours.parse_time("09:30") == {:ok, 570}
      assert PeakHours.parse_time("12:00") == {:ok, 720}
      assert PeakHours.parse_time("23:59") == {:ok, 1439}
    end

    test "rejects out-of-range and malformed times" do
      assert PeakHours.parse_time("24:00") == :error
      assert PeakHours.parse_time("23:60") == :error
      assert PeakHours.parse_time("9:00") == :error
      assert PeakHours.parse_time("09:0") == :error
      assert PeakHours.parse_time("0900") == :error
      assert PeakHours.parse_time("09:00:00") == :error
      assert PeakHours.parse_time("") == :error
      assert PeakHours.parse_time(" 09:00") == :error
      assert PeakHours.parse_time("09:00 ") == :error
    end

    test "rejects non-string input" do
      assert PeakHours.parse_time(nil) == :error
      assert PeakHours.parse_time(900) == :error
      assert PeakHours.parse_time(:morning) == :error
      assert PeakHours.parse_time(%{}) == :error
    end
  end

  describe "parse_window/1" do
    test "parses atom-keyed windows" do
      assert PeakHours.parse_window(%{start: "09:00", end: "12:00"}) ==
               {:ok, %{start: 540, end: 720}}
    end

    test "parses string-keyed windows (TOML decoding)" do
      assert PeakHours.parse_window(%{"start" => "09:00", "end" => "12:00"}) ==
               {:ok, %{start: 540, end: 720}}
    end

    test "parses overnight windows (start > end)" do
      assert PeakHours.parse_window(%{start: "22:00", end: "06:00"}) ==
               {:ok, %{start: 1320, end: 360}}
    end

    test "rejects non-map entries" do
      assert PeakHours.parse_window("09:00") == {:error, {:invalid_window, "09:00"}}
      assert PeakHours.parse_window(123) == {:error, {:invalid_window, 123}}
      assert PeakHours.parse_window(nil) == {:error, {:invalid_window, nil}}
    end

    test "rejects missing keys" do
      w = %{start: "09:00"}
      assert PeakHours.parse_window(w) == {:error, {:invalid_format, w}}

      w2 = %{end: "12:00"}
      assert PeakHours.parse_window(w2) == {:error, {:invalid_format, w2}}
    end

    test "rejects invalid time formats and non-string values" do
      w = %{start: "9:00", end: "12:00"}
      assert PeakHours.parse_window(w) == {:error, {:invalid_format, w}}

      w2 = %{start: "09:00", end: "24:00"}
      assert PeakHours.parse_window(w2) == {:error, {:invalid_format, w2}}

      w3 = %{start: "09:00", end: 720}
      assert PeakHours.parse_window(w3) == {:error, {:invalid_format, w3}}
    end

    test "rejects zero-length windows (start == end)" do
      w = %{start: "09:00", end: "09:00"}
      assert PeakHours.parse_window(w) == {:error, {:zero_length, w}}

      w2 = %{"start" => "22:00", "end" => "22:00"}
      assert PeakHours.parse_window(w2) == {:error, {:zero_length, w2}}
    end
  end

  describe "validate_windows/1" do
    test "nil and empty list mean disabled" do
      assert PeakHours.validate_windows(nil) == {:ok, []}
      assert PeakHours.validate_windows([]) == {:ok, []}
    end

    test "accepts a single window" do
      assert PeakHours.validate_windows([%{start: "09:00", end: "12:00"}]) ==
               {:ok, [%{start: 540, end: 720}]}
    end

    test "accepts two same-day non-overlapping periods (motivating example)" do
      hours = [
        %{start: "09:00", end: "12:00"},
        %{start: "14:00", end: "18:00"}
      ]

      assert PeakHours.validate_windows(hours) ==
               {:ok, [%{start: 540, end: 720}, %{start: 840, end: 1080}]}
    end

    test "accepts adjacent windows (end == next start, half-open)" do
      hours = [
        %{start: "09:00", end: "12:00"},
        %{start: "12:00", end: "15:00"}
      ]

      assert {:ok, [%{start: 540, end: 720}, %{start: 720, end: 900}]} =
               PeakHours.validate_windows(hours)
    end

    test "accepts an overnight window plus a disjoint same-day window" do
      hours = [
        %{start: "22:00", end: "06:00"},
        %{start: "09:00", end: "12:00"}
      ]

      assert {:ok, [%{start: 1320, end: 360}, %{start: 540, end: 720}]} =
               PeakHours.validate_windows(hours)
    end

    test "accepts string-keyed windows" do
      hours = [%{"start" => "09:00", "end" => "12:00"}]
      assert {:ok, [%{start: 540, end: 720}]} = PeakHours.validate_windows(hours)
    end

    test "rejects overlapping same-day windows" do
      hours = [
        %{start: "09:00", end: "12:00"},
        %{start: "11:00", end: "14:00"}
      ]

      assert {:error, {:overlap, _, _}} = PeakHours.validate_windows(hours)
    end

    test "rejects identical windows as overlapping" do
      hours = [
        %{start: "09:00", end: "12:00"},
        %{start: "09:00", end: "12:00"}
      ]

      assert {:error, {:overlap, _, _}} = PeakHours.validate_windows(hours)
    end

    test "rejects overnight-vs-overnight overlaps" do
      hours = [
        %{start: "22:00", end: "06:00"},
        %{start: "23:00", end: "01:00"}
      ]

      assert {:error, {:overlap, _, _}} = PeakHours.validate_windows(hours)
    end

    test "rejects overnight-vs-same-day overlaps" do
      hours = [
        %{start: "22:00", end: "06:00"},
        %{start: "05:00", end: "07:00"}
      ]

      assert {:error, {:overlap, _, _}} = PeakHours.validate_windows(hours)
    end

    test "overlap error carries the raw window maps" do
      hours = [
        %{start: "22:00", end: "06:00"},
        %{start: "23:00", end: "01:00"}
      ]

      assert {:error, {:overlap, w1, w2}} = PeakHours.validate_windows(hours)
      assert w1 == %{start: "22:00", end: "06:00"} or w2 == %{start: "22:00", end: "06:00"}
    end

    test "returns the first validation error for malformed windows" do
      hours = [
        %{start: "09:00", end: "12:00"},
        %{start: "bad", end: "12:00"}
      ]

      assert {:error, {:invalid_format, %{start: "bad", end: "12:00"}}} =
               PeakHours.validate_windows(hours)
    end

    test "rejects non-list input" do
      w = %{start: "09:00", end: "12:00"}
      assert PeakHours.validate_windows(w) == {:error, {:invalid_windows, w}}
      assert PeakHours.validate_windows("09:00") == {:error, {:invalid_windows, "09:00"}}
    end
  end

  describe "in_peak?/2" do
    test "empty windows are never in peak" do
      assert PeakHours.in_peak?([], ~N[2025-01-15 10:00:00]) == false
    end

    test "same-day single window" do
      assert PeakHours.in_peak?(@morning, ~N[2025-01-15 08:59:00]) == false
      assert PeakHours.in_peak?(@morning, ~N[2025-01-15 09:00:00]) == true
      assert PeakHours.in_peak?(@morning, ~N[2025-01-15 10:00:00]) == true
      assert PeakHours.in_peak?(@morning, ~N[2025-01-15 11:59:00]) == true
      assert PeakHours.in_peak?(@morning, ~N[2025-01-15 11:59:59]) == true
      assert PeakHours.in_peak?(@morning, ~N[2025-01-15 12:00:00]) == false
      assert PeakHours.in_peak?(@morning, ~N[2025-01-15 12:00:01]) == false
      assert PeakHours.in_peak?(@morning, ~N[2025-01-15 15:00:00]) == false
    end

    test "two same-day periods (the motivating example)" do
      assert PeakHours.in_peak?(@morning_afternoon, ~N[2025-01-15 08:00:00]) == false
      assert PeakHours.in_peak?(@morning_afternoon, ~N[2025-01-15 10:00:00]) == true
      assert PeakHours.in_peak?(@morning_afternoon, ~N[2025-01-15 12:30:00]) == false
      assert PeakHours.in_peak?(@morning_afternoon, ~N[2025-01-15 15:00:00]) == true
      assert PeakHours.in_peak?(@morning_afternoon, ~N[2025-01-15 18:00:00]) == false
      assert PeakHours.in_peak?(@morning_afternoon, ~N[2025-01-15 20:00:00]) == false
    end

    test "overnight window wraps midnight" do
      assert PeakHours.in_peak?(@overnight, ~N[2025-01-15 21:59:00]) == false
      assert PeakHours.in_peak?(@overnight, ~N[2025-01-15 22:00:00]) == true
      assert PeakHours.in_peak?(@overnight, ~N[2025-01-15 23:59:00]) == true
      assert PeakHours.in_peak?(@overnight, ~N[2025-01-16 00:00:00]) == true
      assert PeakHours.in_peak?(@overnight, ~N[2025-01-16 05:59:00]) == true
      assert PeakHours.in_peak?(@overnight, ~N[2025-01-16 06:00:00]) == false
      assert PeakHours.in_peak?(@overnight, ~N[2025-01-16 06:01:00]) == false
    end

    test "half-open boundaries: start inclusive, end exclusive" do
      assert PeakHours.in_peak?(@morning, ~N[2025-01-15 09:00:00]) == true
      assert PeakHours.in_peak?(@morning, ~N[2025-01-15 11:59:00]) == true
      assert PeakHours.in_peak?(@morning, ~N[2025-01-15 12:00:00]) == false
    end
  end

  describe "next_transition/2" do
    test "empty windows return nil" do
      assert PeakHours.next_transition([], ~N[2025-01-15 10:00:00]) == nil
    end

    test "outside a window → next start" do
      assert PeakHours.next_transition(@morning, ~N[2025-01-15 08:00:00]) ==
               ~N[2025-01-15 09:00:00]

      assert PeakHours.next_transition(@morning, ~N[2025-01-15 08:59:59]) ==
               ~N[2025-01-15 09:00:00]
    end

    test "inside a window → its end" do
      assert PeakHours.next_transition(@morning, ~N[2025-01-15 09:00:00]) ==
               ~N[2025-01-15 12:00:00]

      assert PeakHours.next_transition(@morning, ~N[2025-01-15 11:59:59]) ==
               ~N[2025-01-15 12:00:00]
    end

    test "after a window → next-day start" do
      assert PeakHours.next_transition(@morning, ~N[2025-01-15 12:00:00]) ==
               ~N[2025-01-16 09:00:00]

      assert PeakHours.next_transition(@morning, ~N[2025-01-15 23:00:00]) ==
               ~N[2025-01-16 09:00:00]
    end

    test "two windows: earliest boundary wins" do
      assert PeakHours.next_transition(@morning_afternoon, ~N[2025-01-15 08:00:00]) ==
               ~N[2025-01-15 09:00:00]

      assert PeakHours.next_transition(@morning_afternoon, ~N[2025-01-15 10:00:00]) ==
               ~N[2025-01-15 12:00:00]

      assert PeakHours.next_transition(@morning_afternoon, ~N[2025-01-15 12:30:00]) ==
               ~N[2025-01-15 14:00:00]

      assert PeakHours.next_transition(@morning_afternoon, ~N[2025-01-15 15:00:00]) ==
               ~N[2025-01-15 18:00:00]

      assert PeakHours.next_transition(@morning_afternoon, ~N[2025-01-15 18:00:00]) ==
               ~N[2025-01-16 09:00:00]
    end

    test "overnight window at various times" do
      assert PeakHours.next_transition(@overnight, ~N[2025-01-15 23:00:00]) ==
               ~N[2025-01-16 06:00:00]

      assert PeakHours.next_transition(@overnight, ~N[2025-01-15 05:00:00]) ==
               ~N[2025-01-15 06:00:00]

      assert PeakHours.next_transition(@overnight, ~N[2025-01-15 06:30:00]) ==
               ~N[2025-01-15 22:00:00]

      assert PeakHours.next_transition(@overnight, ~N[2025-01-15 21:59:00]) ==
               ~N[2025-01-15 22:00:00]

      assert PeakHours.next_transition(@overnight, ~N[2025-01-15 22:00:00]) ==
               ~N[2025-01-16 06:00:00]

      assert PeakHours.next_transition(@overnight, ~N[2025-01-15 06:00:00]) ==
               ~N[2025-01-15 22:00:00]
    end

    test "overnight window crossing month/year boundary" do
      assert PeakHours.next_transition(@overnight, ~N[2025-12-31 23:30:00]) ==
               ~N[2026-01-01 06:00:00]
    end

    test "overnight + same-day window interplay" do
      # 22:00-06:00, 09:00-12:00
      windows = [%{start: 1320, end: 360}, %{start: 540, end: 720}]

      assert PeakHours.next_transition(windows, ~N[2025-01-15 05:00:00]) ==
               ~N[2025-01-15 06:00:00]

      assert PeakHours.next_transition(windows, ~N[2025-01-15 06:30:00]) ==
               ~N[2025-01-15 09:00:00]

      assert PeakHours.next_transition(windows, ~N[2025-01-15 10:00:00]) ==
               ~N[2025-01-15 12:00:00]

      assert PeakHours.next_transition(windows, ~N[2025-01-15 23:00:00]) ==
               ~N[2025-01-16 06:00:00]
    end
  end

  describe "effective_concurrency/2" do
    @profile %{concurrency: 4, peak_concurrency: 2, peak_hours: [%{start: "09:00", end: "12:00"}]}

    test "in peak with peak_concurrency → peak_concurrency" do
      assert PeakHours.effective_concurrency(@profile, ~N[2025-01-15 10:00:00]) == 2
    end

    test "in peak without peak_concurrency → concurrency (legal no-op)" do
      profile = %{concurrency: 4, peak_hours: [%{start: "09:00", end: "12:00"}]}
      assert PeakHours.effective_concurrency(profile, ~N[2025-01-15 10:00:00]) == 4
    end

    test "out of peak → concurrency" do
      assert PeakHours.effective_concurrency(@profile, ~N[2025-01-15 08:00:00]) == 4
      assert PeakHours.effective_concurrency(@profile, ~N[2025-01-15 13:00:00]) == 4
    end

    test "no peak_hours → concurrency" do
      profile = %{concurrency: 4, peak_concurrency: 2}
      assert PeakHours.effective_concurrency(profile, ~N[2025-01-15 10:00:00]) == 4
    end

    test "empty peak_hours → concurrency" do
      profile = %{concurrency: 4, peak_concurrency: 2, peak_hours: []}
      assert PeakHours.effective_concurrency(profile, ~N[2025-01-15 10:00:00]) == 4
    end

    test "invalid peak_hours → concurrency" do
      profile = %{
        concurrency: 4,
        peak_concurrency: 2,
        peak_hours: [%{start: "oops", end: "12:00"}]
      }

      assert PeakHours.effective_concurrency(profile, ~N[2025-01-15 10:00:00]) == 4

      profile2 = %{concurrency: 4, peak_concurrency: 2, peak_hours: "09:00-12:00"}
      assert PeakHours.effective_concurrency(profile2, ~N[2025-01-15 10:00:00]) == 4
    end

    test "missing concurrency → nil" do
      assert PeakHours.effective_concurrency(%{peak_concurrency: 2}, ~N[2025-01-15 10:00:00]) ==
               nil
    end

    test "accepts already-canonical integer windows" do
      profile = %{concurrency: 4, peak_concurrency: 2, peak_hours: [%{start: 540, end: 720}]}
      assert PeakHours.effective_concurrency(profile, ~N[2025-01-15 10:00:00]) == 2
      assert PeakHours.effective_concurrency(profile, ~N[2025-01-15 13:00:00]) == 4
    end

    test "string-keyed windows in peak_hours" do
      profile = %{
        concurrency: 4,
        peak_concurrency: 2,
        peak_hours: [%{"start" => "09:00", "end" => "12:00"}]
      }

      assert PeakHours.effective_concurrency(profile, ~N[2025-01-15 10:00:00]) == 2
    end

    test "overnight peak_hours wrap" do
      profile = %{
        concurrency: 4,
        peak_concurrency: 2,
        peak_hours: [%{start: "22:00", end: "06:00"}]
      }

      assert PeakHours.effective_concurrency(profile, ~N[2025-01-15 23:00:00]) == 2
      assert PeakHours.effective_concurrency(profile, ~N[2025-01-16 05:00:00]) == 2
      assert PeakHours.effective_concurrency(profile, ~N[2025-01-16 07:00:00]) == 4
    end

    test "peak_concurrency of zero is honored (not treated as absent)" do
      profile = %{
        concurrency: 4,
        peak_concurrency: 0,
        peak_hours: [%{start: "09:00", end: "12:00"}]
      }

      assert PeakHours.effective_concurrency(profile, ~N[2025-01-15 10:00:00]) == 0
      assert PeakHours.effective_concurrency(profile, ~N[2025-01-15 13:00:00]) == 4
    end
  end

  describe "validate_timezone/1,2" do
    test "accepts nil and empty string (absent/disabled)" do
      assert PeakHours.validate_timezone(nil) == :ok
      assert PeakHours.validate_timezone("") == :ok
    end

    test "accepts valid IANA names against the configured db" do
      # The app configures Tzdata.TimeZoneDatabase at boot, so the no-arg
      # form resolves real IANA names.
      assert PeakHours.validate_timezone("Asia/Shanghai") == :ok
      assert PeakHours.validate_timezone("America/New_York") == :ok
      assert PeakHours.validate_timezone("UTC") == :ok
    end

    test "rejects garbage and unknown-but-wellformed names" do
      assert {:error, :time_zone_not_found} = PeakHours.validate_timezone("Not/AZone")
      assert {:error, :time_zone_not_found} = PeakHours.validate_timezone("abc")
      assert {:error, :time_zone_not_found} = PeakHours.validate_timezone("GMT+8")
      assert {:error, :time_zone_not_found} = PeakHours.validate_timezone("Mars/Olympus")
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_timezone} = PeakHours.validate_timezone(123)
      assert {:error, :invalid_timezone} = PeakHours.validate_timezone(%{})
      assert {:error, :invalid_timezone} = PeakHours.validate_timezone(:utc)
    end

    test "no time zone database configured → :no_time_zone_database" do
      # Explicit db arg — the module is async: true, so we must NOT mutate the
      # global time zone database.
      assert {:error, :no_time_zone_database} =
               PeakHours.validate_timezone("Asia/Shanghai", Calendar.UTCOnlyTimeZoneDatabase)

      assert {:error, :no_time_zone_database} =
               PeakHours.validate_timezone("UTC", Calendar.UTCOnlyTimeZoneDatabase)
    end
  end

  describe "wall_clock_in/2" do
    test "resolves a fixed-offset zone" do
      assert PeakHours.wall_clock_in("Asia/Shanghai", ~U[2025-01-15 08:00:00Z]) ==
               {:ok, ~N[2025-01-15 16:00:00]}
    end

    test "DST-aware resolution (US Eastern, DST starts 2025-03-09 at 07:00Z)" do
      # 06:30Z is still EST (-5): 06:30 - 5 = 01:30 (before the 07:00Z flip)
      assert PeakHours.wall_clock_in("America/New_York", ~U[2025-03-09 06:30:00Z]) ==
               {:ok, ~N[2025-03-09 01:30:00]}

      # 07:00Z is the transition instant itself → already EDT (-4): 07:00 - 4 = 03:00
      assert PeakHours.wall_clock_in("America/New_York", ~U[2025-03-09 07:00:00Z]) ==
               {:ok, ~N[2025-03-09 03:00:00]}

      # 08:00Z is EDT (-4): 08:00 - 4 = 04:00
      assert PeakHours.wall_clock_in("America/New_York", ~U[2025-03-09 08:00:00Z]) ==
               {:ok, ~N[2025-03-09 04:00:00]}
    end

    test "rejects an unknown time zone name" do
      assert {:error, :time_zone_not_found} =
               PeakHours.wall_clock_in("Not/AZone", ~U[2025-01-15 08:00:00Z])
    end

    test "rejects non-binary timezone and non-DateTime input" do
      assert {:error, :invalid_timezone} = PeakHours.wall_clock_in(nil, ~U[2025-01-15 08:00:00Z])
      assert {:error, :invalid_timezone} = PeakHours.wall_clock_in(123, ~U[2025-01-15 08:00:00Z])

      assert {:error, :invalid_datetime} =
               PeakHours.wall_clock_in("Asia/Shanghai", ~N[2025-01-15 08:00:00])
    end
  end

  describe "effective_concurrency/3 (tz-aware)" do
    @tz_profile %{
      concurrency: 4,
      peak_concurrency: 2,
      peak_hours: [%{start: "09:00", end: "12:00"}],
      timezone: "Asia/Shanghai"
    }

    test "resolves the profile's wall clock from the utc instant" do
      # 2025-01-15 01:00:00Z = 09:00 Shanghai → in peak → peak_concurrency
      assert PeakHours.effective_concurrency(
               @tz_profile,
               ~U[2025-01-15 01:00:00Z],
               "Asia/Shanghai"
             ) ==
               2

      # 2025-01-15 00:00:00Z = 08:00 Shanghai → off peak → concurrency
      assert PeakHours.effective_concurrency(
               @tz_profile,
               ~U[2025-01-15 00:00:00Z],
               "Asia/Shanghai"
             ) ==
               4
    end

    test "peak_concurrency 0 is honored in a tz profile" do
      profile = %{
        concurrency: 4,
        peak_concurrency: 0,
        peak_hours: [%{start: "09:00", end: "12:00"}],
        timezone: "Asia/Shanghai"
      }

      assert PeakHours.effective_concurrency(profile, ~U[2025-01-15 01:00:00Z], "Asia/Shanghai") ==
               0

      assert PeakHours.effective_concurrency(profile, ~U[2025-01-15 00:00:00Z], "Asia/Shanghai") ==
               4
    end

    test "falls back to concurrency on timezone resolution error" do
      profile = %{@tz_profile | timezone: "Not/AZone"}
      assert PeakHours.effective_concurrency(profile, ~U[2025-01-15 01:00:00Z], "Not/AZone") == 4
    end

    test "missing concurrency → nil" do
      profile = %{
        peak_concurrency: 2,
        peak_hours: [%{start: "09:00", end: "12:00"}],
        timezone: "Asia/Shanghai"
      }

      assert PeakHours.effective_concurrency(profile, ~U[2025-01-15 01:00:00Z], "Asia/Shanghai") ==
               nil
    end
  end
end
