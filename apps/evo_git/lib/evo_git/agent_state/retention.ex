defmodule EvoGit.AgentState.Retention do
  @moduledoc """
  Pure retention math for the durable agent-state store.

  A COMPLETED run is pruned once `completed_at` is older than
  `retention_days`; a run that never completed (crash/abandoned) is pruned
  once `updated_at` is older than `retention_days * 2`. The two windows are
  returned as ISO8601 second-precision strings so plain string comparison in
  SQL implements the ordering (see `EvoGit.AgentState.Record.now_iso8601/0`).

  No I/O, no clock reads beyond the injected `now` — the server passes the
  real clock, tests pass a fixed one.
  """

  @default_days 7
  @default_prune_interval_ms 3_600_000

  @doc "The retention window (days) used when neither opts nor app env set one."
  @spec default_days() :: pos_integer()
  def default_days, do: @default_days

  @doc "The hourly prune cadence used when no `:prune_interval` seam is given."
  @spec default_prune_interval() :: pos_integer()
  def default_prune_interval, do: @default_prune_interval_ms

  @doc """
  Resolves the retention window: `:retention_days` opt →
  `:agent_state_retention_days` app env → `default_days/0`.
  """
  @spec configured_days(keyword()) :: non_neg_integer()
  def configured_days(opts) do
    days =
      Keyword.get(opts, :retention_days) ||
        Application.get_env(:evo_git, :agent_state_retention_days, @default_days)

    normalize_days(days)
  end

  @doc "Normalizes a retention window; anything but a non-negative integer falls back."
  @spec normalize_days(term()) :: non_neg_integer()
  def normalize_days(days) when is_integer(days) and days >= 0, do: days
  def normalize_days(_days), do: @default_days

  @doc """
  Resolves the prune timer interval from the `:prune_interval` seam (ms).

  Anything but a positive integer falls back to `default_prune_interval/0`.
  """
  @spec prune_interval(keyword()) :: pos_integer()
  def prune_interval(opts) do
    case Keyword.get(opts, :prune_interval) do
      interval when is_integer(interval) and interval > 0 -> interval
      _other -> @default_prune_interval_ms
    end
  end

  @doc """
  The two cutoffs for one prune pass.

  A row is eligible when its `completed_at` is before `:completed_before`
  (completed runs) or — for a row that never completed — its `updated_at` is
  before `:stale_before`; either way the row must also have `updated_at`
  before `:completed_before`, so a live/recently-touched row is never pruned.
  """
  @spec cutoffs(non_neg_integer(), DateTime.t()) :: %{
          completed_before: String.t(),
          stale_before: String.t()
        }
  def cutoffs(days, now \\ DateTime.utc_now()) do
    days = normalize_days(days)

    %{
      completed_before: iso_before(now, days),
      stale_before: iso_before(now, days * 2)
    }
  end

  defp iso_before(now, days) do
    now
    |> DateTime.add(-days * 86_400, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
