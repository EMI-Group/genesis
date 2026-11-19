defmodule EvoGit.PeakHours.HolidaysTest do
  use ExUnit.Case, async: true

  alias EvoGit.PeakHours.Holidays

  describe "calendars/0 and known?/1" do
    test "exposes the CN calendar identifier" do
      assert Holidays.calendars() == ["CN"]
    end

    test "known?/1 accepts atoms and strings case-insensitively" do
      assert Holidays.known?("CN")
      assert Holidays.known?("cn")
      assert Holidays.known?(" Cn ")
      assert Holidays.known?(:CN)
      assert Holidays.known?(:cn)
    end

    test "known?/1 rejects unknown identifiers and non-string input" do
      refute Holidays.known?("US")
      refute Holidays.known?(:us)
      refute Holidays.known?("")
      refute Holidays.known?(nil)
      refute Holidays.known?(123)
      refute Holidays.known?(%{})
      refute Holidays.known?(["CN"])
    end
  end

  describe "supported_years/0 and provisional_years/0" do
    test "covers 2025 through 2027 with no provisional year today" do
      assert Holidays.supported_years() == [2025, 2026, 2027]
      assert Holidays.provisional_years() == []
    end

    test "provisional years are always a subset of supported years" do
      assert Holidays.provisional_years() -- Holidays.supported_years() == []
    end
  end

  describe "holiday?/1" do
    test "recognizes a holiday in each supported year" do
      assert Holidays.holiday?(~D[2025-01-01])
      assert Holidays.holiday?(~D[2026-02-17])
      assert Holidays.holiday?(~D[2027-06-09])
    end

    test "covers every day of a contiguous block, not just the first" do
      assert Holidays.holiday?(~D[2025-01-28])
      assert Holidays.holiday?(~D[2025-02-04])
      refute Holidays.holiday?(~D[2025-02-05])

      assert Holidays.holiday?(~D[2026-02-15])
      assert Holidays.holiday?(~D[2026-02-23])
      refute Holidays.holiday?(~D[2026-02-24])

      assert Holidays.holiday?(~D[2027-10-01])
      assert Holidays.holiday?(~D[2027-10-07])
      refute Holidays.holiday?(~D[2027-10-08])
    end

    test "an ordinary weekday is not a holiday" do
      refute Holidays.holiday?(~D[2026-03-10])
    end

    test "answers false outside the table years" do
      refute Holidays.holiday?(~D[2031-03-04])
      refute Holidays.holiday?(~D[2019-01-01])
    end
  end

  describe "make_up_workday?/1" do
    test "a make-up workday on a weekend is a WORKING day" do
      date = ~D[2026-02-14]

      assert Date.day_of_week(date) == 6
      assert Holidays.weekend?(date)
      assert Holidays.make_up_workday?(date)
      refute Holidays.holiday?(date)
      refute Holidays.non_working_day?(date)
    end

    test "make-up workdays exist in every supported year" do
      assert Holidays.make_up_workday?(~D[2025-01-26])
      assert Date.day_of_week(~D[2025-01-26]) == 7

      assert Holidays.make_up_workday?(~D[2026-10-10])
      assert Date.day_of_week(~D[2026-10-10]) == 6

      assert Holidays.make_up_workday?(~D[2027-10-09])
      assert Date.day_of_week(~D[2027-10-09]) == 6
    end

    test "ordinary days are not make-up workdays" do
      refute Holidays.make_up_workday?(~D[2026-03-10])
      refute Holidays.make_up_workday?(~D[2026-02-15])
      refute Holidays.make_up_workday?(~D[2031-03-04])
    end
  end

  describe "non_working_day?/1 precedence" do
    test "a holiday that falls on a weekend is still non-working" do
      date = ~D[2025-04-05]

      assert Date.day_of_week(date) == 6
      assert Holidays.holiday?(date)
      refute Holidays.make_up_workday?(date)
      assert Holidays.non_working_day?(date)
    end

    test "a make-up workday adjacent to a weekend holiday is a working day" do
      # 2026 Spring Festival runs 2026-02-15 .. 2026-02-23; 2026-02-14 (Sat) is worked.
      assert Holidays.holiday?(~D[2026-02-15])
      assert Holidays.non_working_day?(~D[2026-02-15])

      assert Date.diff(~D[2026-02-15], ~D[2026-02-14]) == 1
      assert Holidays.make_up_workday?(~D[2026-02-14])
      refute Holidays.non_working_day?(~D[2026-02-14])
    end

    test "the 2025 Qingming block is non-working while its Labour Day make-up is not" do
      assert Holidays.non_working_day?(~D[2025-04-04])
      assert Holidays.non_working_day?(~D[2025-04-05])
      assert Holidays.non_working_day?(~D[2025-04-06])

      assert Holidays.make_up_workday?(~D[2025-04-27])
      refute Holidays.non_working_day?(~D[2025-04-27])
    end

    test "plain weekend days are non-working" do
      assert Holidays.non_working_day?(~D[2026-03-07])
      assert Holidays.non_working_day?(~D[2026-03-08])
    end

    test "a plain Tuesday is a working day" do
      refute Holidays.non_working_day?(~D[2026-03-10])
    end

    test "a working weekday that is neither a holiday nor a make-up day answers false everywhere" do
      date = ~D[2026-03-10]

      refute Holidays.holiday?(date)
      refute Holidays.make_up_workday?(date)
      refute Holidays.non_working_day?(date)
      assert Holidays.holiday_name(date) == nil
    end

    test "dates outside the table years answer false everywhere without raising" do
      for date <- [~D[2031-03-04], ~D[2019-01-01]] do
        refute Holidays.holiday?(date)
        refute Holidays.make_up_workday?(date)
        refute Holidays.non_working_day?(date)
        assert Holidays.holiday_name(date) == nil
      end
    end
  end

  describe "holiday_name/1" do
    test "returns the Chinese holiday name" do
      assert Holidays.holiday_name(~D[2025-01-01]) == "元旦"
      assert Holidays.holiday_name(~D[2025-10-06]) == "国庆节、中秋节"
      assert Holidays.holiday_name(~D[2026-02-17]) == "春节"
      assert Holidays.holiday_name(~D[2027-09-15]) == "中秋节"
    end

    test "returns nil for non-holidays and out-of-table years" do
      assert Holidays.holiday_name(~D[2026-03-10]) == nil
      assert Holidays.holiday_name(~D[2026-02-14]) == nil
      assert Holidays.holiday_name(~D[2031-03-04]) == nil
    end
  end

  describe "NaiveDateTime and garbage input" do
    test "a NaiveDateTime delegates to its date" do
      assert Holidays.holiday?(~N[2025-10-01 09:30:00])
      assert Holidays.non_working_day?(~N[2025-10-01 09:30:00])
      assert Holidays.holiday_name(~N[2025-10-01 09:30:00]) == "国庆节、中秋节"
      assert Holidays.weekend?(~N[2026-03-07 12:00:00])

      assert Holidays.make_up_workday?(~N[2026-02-14 23:59:59])
      refute Holidays.non_working_day?(~N[2026-02-14 23:59:59])

      refute Holidays.holiday?(~N[2026-03-10 00:00:00])
    end

    test "garbage input returns false / nil instead of raising" do
      for garbage <- [nil, "2025-10-01", 20_251_001, %{}, [], :nope] do
        refute Holidays.holiday?(garbage)
        refute Holidays.make_up_workday?(garbage)
        refute Holidays.non_working_day?(garbage)
        refute Holidays.weekend?(garbage)
        assert Holidays.holiday_name(garbage) == nil
      end
    end
  end

  describe "table integrity" do
    test "holidays are sorted, unique and contain named entries" do
      entries = Holidays.holidays()
      dates = Enum.map(entries, &elem(&1, 0))

      assert dates == Enum.sort(dates, Date)
      assert dates == Enum.uniq(dates)
      assert Enum.all?(entries, fn {_date, name} -> is_binary(name) and name != "" end)
    end

    test "holidays only cover supported years" do
      years = Holidays.holidays() |> Enum.map(fn {date, _} -> date.year end) |> Enum.uniq()

      assert Enum.sort(years) == Enum.sort(Holidays.supported_years())
    end

    test "each supported year carries the published number of holiday days" do
      counts = Enum.frequencies_by(Holidays.holidays(), fn {date, _name} -> date.year end)

      assert counts == %{2025 => 28, 2026 => 33, 2027 => 29}
    end

    test "make-up workdays are sorted, unique, on a weekend and never holidays" do
      days = Holidays.make_up_workdays()

      assert days == Enum.sort(days, Date)
      assert days == Enum.uniq(days)

      for date <- days do
        assert Holidays.weekend?(date), "expected #{date} to fall on a Saturday/Sunday"
        refute Holidays.holiday?(date)
      end
    end

    test "every supported year has at least one holiday and one make-up workday" do
      for year <- Holidays.supported_years() do
        assert Enum.any?(Holidays.holidays(), fn {date, _} -> date.year == year end)
        assert Enum.any?(Holidays.make_up_workdays(), &(&1.year == year))
      end
    end
  end
end
