defmodule EvoGit.Util.Time do
  @moduledoc """
  The shared clock reads for timing and for display timestamps.

  Two distinct clocks, deliberately kept apart:

    * `now_ms/0` is MONOTONIC — the right source for durations, deadlines and
      cache ages, because it never jumps backwards when the wall clock is
      adjusted.
    * `now_iso8601/0` is the UTC wall clock rendered as ISO-8601 — the right
      value to persist or show, never to subtract.
  """

  @doc """
  The monotonic clock in milliseconds.

  Only differences between two readings are meaningful; the absolute value has
  no epoch relation to wall time.
  """
  @spec now_ms() :: integer()
  def now_ms do
    System.monotonic_time(:millisecond)
  end

  @doc """
  The current UTC time as an ISO-8601 string (`"2026-11-21T02:29:00.000000Z"`).
  """
  @spec now_iso8601() :: String.t()
  def now_iso8601 do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
