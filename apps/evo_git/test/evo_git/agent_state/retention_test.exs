defmodule EvoGit.AgentState.RetentionTest do
  @moduledoc """
  Pure math for `EvoGit.AgentState.Retention` — no database, no clock read, no
  app-env mutation.

  A COMPLETED run is pruned once `completed_at` is older than `retention_days`;
  a run that never completed is pruned once `updated_at` is older than
  `retention_days * 2`. `cutoffs/2` takes an injected `now`, so the exact
  ISO8601 second-precision strings are assertable.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentState.Retention

  @now ~U[2024-05-05 05:05:05Z]

  describe "defaults" do
    test "the retention window defaults to 7 days" do
      assert Retention.default_days() == 7
    end

    test "the prune cadence defaults to one hour" do
      assert Retention.default_prune_interval() == 3_600_000
    end
  end

  describe "normalize_days/1" do
    test "non-negative integers pass through unchanged, including 0" do
      for days <- [0, 1, 7, 30, 365] do
        assert Retention.normalize_days(days) == days
      end
    end

    test "anything that is not a non-negative integer falls back to the default" do
      for invalid <- [-1, -7, 7.0, 7.5, "7", nil, :seven, %{}, []] do
        assert Retention.normalize_days(invalid) == Retention.default_days()
      end
    end
  end

  describe "configured_days/1" do
    test "an explicit retention_days opt wins, including 0" do
      assert Retention.configured_days(retention_days: 3) == 3
      assert Retention.configured_days(retention_days: 0) == 0
      assert Retention.configured_days(retention_days: 365) == 365
    end

    test "an invalid retention_days opt falls back to the default" do
      assert Retention.configured_days(retention_days: -2) == Retention.default_days()
      assert Retention.configured_days(retention_days: 1.5) == Retention.default_days()
      assert Retention.configured_days(retention_days: "3") == Retention.default_days()
    end

    test "an absent (or nil) opt falls back to the default" do
      # The `:agent_state_retention_days` app env is deliberately NOT set here
      # (and no suite sets it): absent opt → default_days/0.
      assert Retention.configured_days([]) == Retention.default_days()
      assert Retention.configured_days(retention_days: nil) == Retention.default_days()
    end
  end

  describe "prune_interval/1" do
    test "a positive integer interval passes through" do
      assert Retention.prune_interval(prune_interval: 1) == 1
      assert Retention.prune_interval(prune_interval: 25) == 25
      assert Retention.prune_interval(prune_interval: 3_600_000) == 3_600_000
    end

    test "zero, negatives, non-integers and an absent opt fall back to the default" do
      default = Retention.default_prune_interval()

      assert Retention.prune_interval(prune_interval: 0) == default
      assert Retention.prune_interval(prune_interval: -1) == default
      assert Retention.prune_interval(prune_interval: 1.0) == default
      assert Retention.prune_interval(prune_interval: "1000") == default
      assert Retention.prune_interval(prune_interval: nil) == default
      assert Retention.prune_interval([]) == default
    end
  end

  describe "cutoffs/2" do
    test "the completed window is `days` and the stale window is `2 * days`" do
      assert Retention.cutoffs(7, @now) == %{
               completed_before: "2024-04-28T05:05:05Z",
               stale_before: "2024-04-21T05:05:05Z"
             }
    end

    test "a 0-day window makes both cutoffs exactly `now`" do
      assert Retention.cutoffs(0, @now) == %{
               completed_before: "2024-05-05T05:05:05Z",
               stale_before: "2024-05-05T05:05:05Z"
             }
    end

    test "an invalid day count is normalized before the math" do
      assert Retention.cutoffs(-3, @now) == Retention.cutoffs(Retention.default_days(), @now)
      assert Retention.cutoffs(nil, @now) == Retention.cutoffs(7, @now)
    end

    test "cutoffs are second-precision ISO8601 strings (string order = time order)" do
      %{completed_before: completed_before, stale_before: stale_before} =
        Retention.cutoffs(7, @now)

      assert {:ok, completed_at, 0} = DateTime.from_iso8601(completed_before)
      assert {:ok, stale_at, 0} = DateTime.from_iso8601(stale_before)
      assert completed_at.microsecond == {0, 0}
      assert stale_at.microsecond == {0, 0}
      assert DateTime.compare(stale_at, completed_at) == :lt
    end
  end
end
