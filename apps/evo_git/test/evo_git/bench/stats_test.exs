defmodule EvoGit.Bench.StatsTest do
  @moduledoc """
  Tests for `EvoGit.Bench.Stats` — pure microsecond sample statistics.

  Every function is total over its inputs (empty sample sets and a zero total
  yield zeros rather than raising), so the suite covers the empty/degenerate
  arms alongside the arithmetic. No I/O, no timers, no global state:
  `async: true`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Bench.Stats

  describe "percentile/2 (nearest rank)" do
    test "returns the value at ceil(p / 100 * n) for an odd count" do
      # n = 5: rank 5 of 5 for p95, rank 3 at the median.
      assert Stats.percentile([1, 2, 3, 4, 5], 95) == 5
      assert Stats.percentile([1, 2, 3, 4, 5], 50) == 3
      assert Stats.percentile([1, 2, 3, 4, 5], 1) == 1
    end

    test "returns the nearest-rank value for an even count" do
      # n = 4: ceil(0.5 * 4) = 2, ceil(0.75 * 4) = 3, ceil(0.95 * 4) = 4.
      assert Stats.percentile([1, 2, 3, 4], 50) == 2
      assert Stats.percentile([10, 20, 30, 40], 75) == 30
      assert Stats.percentile([1, 2, 3, 4], 95) == 4
    end

    test "sorts its input" do
      assert Stats.percentile([30, 10, 20], 50) == 20
      assert Stats.percentile([30, 10, 20], 100) == 30
    end

    test "clamps p to 0..100" do
      assert Stats.percentile([1, 2, 3], 0) == 1
      assert Stats.percentile([1, 2, 3], -50) == 1
      assert Stats.percentile([1, 2, 3], 100) == 3
      assert Stats.percentile([1, 2, 3], 1_000) == 3
    end

    test "returns 0 for an empty sample set" do
      assert Stats.percentile([], 95) == 0
      assert Stats.percentile([], 0) == 0
    end

    test "returns the single sample for every percentile" do
      assert Stats.percentile([7], 0) == 7
      assert Stats.percentile([7], 50) == 7
      assert Stats.percentile([7], 100) == 7
    end
  end

  describe "summarize/1" do
    test "summarizes an odd count with the middle value as the median" do
      summary = Stats.summarize([30, 10, 20])

      assert summary.n == 3
      assert summary.total_us == 60
      assert summary.mean_us == 20.0
      assert summary.median_us == 20
      assert summary.p95_us == 30
      assert summary.min_us == 10
      assert summary.max_us == 30
    end

    test "summarizes an even count with the mean of the two middle values" do
      summary = Stats.summarize([10, 20, 30, 40])

      assert summary.n == 4
      assert summary.total_us == 100
      assert summary.mean_us == 25.0
      assert is_float(summary.median_us)
      assert summary.median_us == 25.0
      assert summary.p95_us == 40
      assert summary.min_us == 10
      assert summary.max_us == 40
    end

    test "rounds the mean to one decimal while keeping totals exact" do
      summary = Stats.summarize([1, 2, 2])

      assert summary.mean_us == 1.7
      assert summary.total_us == 5
      assert summary.median_us == 2
    end

    test "returns zeros and n: 0 for an empty sample set" do
      assert Stats.summarize([]) == %{
               n: 0,
               total_us: 0,
               mean_us: 0.0,
               median_us: 0.0,
               p95_us: 0,
               min_us: 0,
               max_us: 0
             }
    end

    test "summarizes a single sample" do
      summary = Stats.summarize([7])

      assert summary == %{
               n: 1,
               total_us: 7,
               mean_us: 7.0,
               median_us: 7,
               p95_us: 7,
               min_us: 7,
               max_us: 7
             }
    end

    test "handles all-zero samples" do
      summary = Stats.summarize([0, 0])

      assert summary.n == 2
      assert summary.total_us == 0
      assert summary.mean_us == 0.0
      assert summary.median_us == 0.0
      assert summary.min_us == 0
      assert summary.max_us == 0
    end
  end

  describe "ops_per_sec/2" do
    test "computes count per second from a microsecond total" do
      assert Stats.ops_per_sec(10, 2_000_000) == 5.0
      assert Stats.ops_per_sec(2, 1_000_000) == 2.0
      assert_in_delta Stats.ops_per_sec(1, 3_000), 333.333, 0.001
    end

    test "returns 0.0 when the total is zero" do
      assert Stats.ops_per_sec(0, 0) == 0.0
      assert Stats.ops_per_sec(10, 0) == 0.0
      assert is_float(Stats.ops_per_sec(10, 0))
    end
  end

  describe "duration_ms/1" do
    test "converts microseconds to milliseconds with one decimal" do
      assert Stats.duration_ms(182_400) == 182.4
      assert Stats.duration_ms(1_234) == 1.2
      assert Stats.duration_ms(1_000) == 1.0
      assert Stats.duration_ms(0) == 0.0
      assert is_float(Stats.duration_ms(0))
    end
  end

  describe "format_duration_us/1" do
    test "formats whole microseconds below one millisecond" do
      assert Stats.format_duration_us(812) == "812 µs"
      assert Stats.format_duration_us(0) == "0 µs"
      assert Stats.format_duration_us(999) == "999 µs"
      assert Stats.format_duration_us(812.6) == "813 µs"
    end

    test "formats milliseconds with one decimal" do
      assert Stats.format_duration_us(182_400) == "182.4 ms"
      assert Stats.format_duration_us(1_000) == "1.0 ms"
      assert Stats.format_duration_us(999_999) == "1000.0 ms"
    end

    test "formats seconds with two decimals" do
      assert Stats.format_duration_us(1_420_000) == "1.42 s"
      assert Stats.format_duration_us(1_000_000) == "1.00 s"
      assert Stats.format_duration_us(60_000_000) == "60.00 s"
    end
  end
end
