defmodule EvoGit.Bench.Stats do
  @moduledoc """
  Pure statistics helpers for microsecond benchmark sample sets.

  Every function is total: empty inputs yield zero values instead of raising,
  so a benchmark phase that produced no samples still renders. Rounding is
  presentation-oriented (mean to one decimal, durations formatted for humans),
  while the raw `total_us` and `samples_us` stay exact.
  """

  @typedoc "Aggregate summary of a microsecond sample set."
  @type summary :: %{
          n: non_neg_integer(),
          total_us: non_neg_integer(),
          mean_us: float(),
          median_us: number(),
          p95_us: non_neg_integer(),
          min_us: non_neg_integer(),
          max_us: non_neg_integer()
        }

  @doc """
  Summarizes a list of microsecond samples.

  Returns `n`, `total_us`, `mean_us` (rounded to one decimal), `median_us`
  (the middle value for an odd count, the average of the two middle values —
  a float — for an even count), `p95_us` (via `percentile/2`), `min_us` and
  `max_us`. An empty list returns all zeros with `n: 0` and never raises.
  """
  @spec summarize([non_neg_integer()]) :: summary()
  def summarize(samples_us) when is_list(samples_us) do
    case length(samples_us) do
      0 ->
        %{n: 0, total_us: 0, mean_us: 0.0, median_us: 0.0, p95_us: 0, min_us: 0, max_us: 0}

      n ->
        sorted = Enum.sort(samples_us)
        total = Enum.sum(samples_us)

        %{
          n: n,
          total_us: total,
          mean_us: Float.round(total / n, 1),
          median_us: median(sorted, n),
          p95_us: percentile(samples_us, 95),
          min_us: hd(sorted),
          max_us: List.last(sorted)
        }
    end
  end

  @doc """
  Nearest-rank percentile of a microsecond sample set.

  Sorts ascending, computes `rank = ceil(p / 100 * n)`, clamps `p` to `0..100`
  and the rank to `1..n`, and returns the value at `rank - 1`. An empty list
  returns `0`.
  """
  @spec percentile([non_neg_integer()], number()) :: non_neg_integer()
  def percentile([], _p), do: 0

  def percentile(samples_us, p) when is_list(samples_us) and is_number(p) do
    n = length(samples_us)
    clamped_p = p |> max(0) |> min(100)
    rank = ceil(clamped_p * n / 100) |> clamp(1, n)

    samples_us
    |> Enum.sort()
    |> Enum.at(rank - 1)
  end

  @doc """
  Operations per second for `count` operations that took `total_us`
  microseconds. Returns `0.0` when `total_us` is zero.
  """
  @spec ops_per_sec(non_neg_integer(), non_neg_integer()) :: float()
  def ops_per_sec(_count, 0), do: 0.0
  def ops_per_sec(count, total_us), do: count * 1_000_000 / total_us

  @doc """
  Converts microseconds to milliseconds rounded to one decimal.
  """
  @spec duration_ms(number()) :: float()
  def duration_ms(us) when is_number(us), do: round(us / 1000 * 10) / 10

  @doc """
  Formats microseconds for human display: `"1.42 s"` at or above one second
  (two decimals), `"182.4 ms"` at or above one millisecond (one decimal), and
  an integer `"812 µs"` below that.
  """
  @spec format_duration_us(number()) :: String.t()
  def format_duration_us(us) when us >= 1_000_000 do
    :erlang.float_to_binary(us / 1_000_000, decimals: 2) <> " s"
  end

  def format_duration_us(us) when us >= 1000 do
    :erlang.float_to_binary(us / 1000, decimals: 1) <> " ms"
  end

  def format_duration_us(us), do: "#{round(us)} µs"

  defp median(sorted, n) when rem(n, 2) == 0 do
    midpoint = div(n, 2)
    (Enum.at(sorted, midpoint - 1) + Enum.at(sorted, midpoint)) / 2
  end

  defp median(sorted, n), do: Enum.at(sorted, div(n, 2))

  defp clamp(value, min_value, max_value), do: value |> max(min_value) |> min(max_value)
end
