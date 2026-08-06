defmodule EvoDashWeb.TasksLive.DirtyTrackerTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.TasksLive.DirtyTracker.

  The tracker is a side-effect-free state machine over `updated_at` baselines
  (fixed-precision ISO strings) — no LiveView, Phoenix socket, or DB setup is
  required.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.TasksLive.DirtyTracker

  describe "new/1" do
    test "defaults to full_resync_every 10 and unseeded state" do
      tracker = DirtyTracker.new()

      assert tracker.full_resync_every == 10
      assert tracker.node == nil
      assert tracker.last_seen_updated_at == nil
      assert tracker.ticks_since_full_resync == 0
    end

    test "accepts a full_resync_every override" do
      assert DirtyTracker.new(full_resync_every: 2).full_resync_every == 2
      assert DirtyTracker.new(full_resync_every: 1).full_resync_every == 1
    end
  end

  describe "seed/3" do
    test "binds the node and advances the baseline to the max updated_at" do
      summaries = [
        %{id: "a", updated_at: "2026-01-01T00:00:00.000000Z"},
        %{id: "b", updated_at: "2026-01-01T00:05:00.000000Z"},
        %{id: "c", updated_at: "2026-01-01T00:02:00.000000Z"}
      ]

      tracker = DirtyTracker.seed(DirtyTracker.new(), :remote_node, summaries)

      assert tracker.node == :remote_node
      assert tracker.last_seen_updated_at == "2026-01-01T00:05:00.000000Z"
      assert tracker.ticks_since_full_resync == 0
    end

    test "empty summaries set the \"\" sentinel baseline" do
      tracker = DirtyTracker.seed(DirtyTracker.new(), :remote_node, [])

      assert tracker.node == :remote_node
      assert tracker.last_seen_updated_at == ""
      assert tracker.ticks_since_full_resync == 0
    end

    test "resets ticks_since_full_resync" do
      tracker = %{DirtyTracker.new() | ticks_since_full_resync: 7}

      tracker =
        DirtyTracker.seed(tracker, :remote_node, [
          %{id: "a", updated_at: "2026-01-01T00:00:00.000000Z"}
        ])

      assert tracker.ticks_since_full_resync == 0
    end

    test "preserves full_resync_every from new/1 opts" do
      tracker = DirtyTracker.seed(DirtyTracker.new(full_resync_every: 2), :remote_node, [])
      assert tracker.full_resync_every == 2
    end
  end

  describe "max_updated_at/1" do
    test "returns the max updated_at string (lexicographic = chronological)" do
      tasks = [
        %{id: "a", updated_at: "2026-01-02T00:00:00.000000Z"},
        %{id: "b", updated_at: "2026-01-03T00:00:00.000000Z"},
        %{id: "c", updated_at: "2026-01-01T00:00:00.000000Z"}
      ]

      assert DirtyTracker.max_updated_at(tasks) == "2026-01-03T00:00:00.000000Z"
    end

    test "empty list returns the \"\" sentinel" do
      assert DirtyTracker.max_updated_at([]) == ""
    end

    test "ignores maps without an updated_at key" do
      tasks = [%{id: "a"}, %{id: "b", updated_at: "2026-01-01T00:00:00.000000Z"}]

      assert DirtyTracker.max_updated_at(tasks) == "2026-01-01T00:00:00.000000Z"
    end
  end

  describe "evaluate/2" do
    test "reloads, advances baseline to max changed, and resets the tick counter" do
      tracker =
        DirtyTracker.seed(DirtyTracker.new(), :remote_node, [
          %{id: "a", updated_at: "2026-01-01T00:00:00.000000Z"}
        ])

      changed = [
        %{id: "b", updated_at: "2026-01-01T00:01:00.000000Z"},
        %{id: "c", updated_at: "2026-01-01T00:02:00.000000Z"}
      ]

      {action, tracker} = DirtyTracker.evaluate(tracker, changed)

      assert action == :reload
      assert tracker.last_seen_updated_at == "2026-01-01T00:02:00.000000Z"
      assert tracker.ticks_since_full_resync == 0
      assert tracker.node == :remote_node
    end

    test "noop increments the tick counter without advancing the baseline" do
      tracker =
        DirtyTracker.seed(DirtyTracker.new(), :remote_node, [
          %{id: "a", updated_at: "2026-01-01T00:00:00.000000Z"}
        ])

      {action, tracker} = DirtyTracker.evaluate(tracker, [])

      assert action == :noop
      assert tracker.ticks_since_full_resync == 1
      assert tracker.last_seen_updated_at == "2026-01-01T00:00:00.000000Z"
    end

    test "resync fires exactly at full_resync_every noop ticks and resets the counter" do
      tracker =
        DirtyTracker.seed(DirtyTracker.new(full_resync_every: 3), :remote_node, [
          %{id: "a", updated_at: "2026-01-01T00:00:00.000000Z"}
        ])

      # Ticks 1 and 2: noop, counter advances.
      {action, tracker} = DirtyTracker.evaluate(tracker, [])
      assert action == :noop
      assert tracker.ticks_since_full_resync == 1

      {action, tracker} = DirtyTracker.evaluate(tracker, [])
      assert action == :noop
      assert tracker.ticks_since_full_resync == 2

      # Tick 3: 2 + 1 >= 3 → resync, counter resets.
      {action, tracker} = DirtyTracker.evaluate(tracker, [])
      assert action == :resync
      assert tracker.ticks_since_full_resync == 0

      # Counter continues from 0 after the resync.
      {action, tracker} = DirtyTracker.evaluate(tracker, [])
      assert action == :noop
      assert tracker.ticks_since_full_resync == 1
    end

    test "a change between noop ticks resets the resync counter" do
      tracker =
        DirtyTracker.seed(DirtyTracker.new(full_resync_every: 3), :remote_node, [
          %{id: "a", updated_at: "2026-01-01T00:00:00.000000Z"}
        ])

      {_action, tracker} = DirtyTracker.evaluate(tracker, [])
      {_action, tracker} = DirtyTracker.evaluate(tracker, [])

      {action, tracker} =
        DirtyTracker.evaluate(tracker, [%{id: "b", updated_at: "2026-01-01T00:01:00.000000Z"}])

      assert action == :reload
      assert tracker.ticks_since_full_resync == 0
    end

    test "unseeded tracker with changes seeds from changed and reloads" do
      changed = [%{id: "a", updated_at: "2026-01-01T00:00:00.000000Z"}]

      {action, tracker} = DirtyTracker.evaluate(DirtyTracker.new(), changed)

      assert action == :reload
      assert tracker.last_seen_updated_at == "2026-01-01T00:00:00.000000Z"
      assert tracker.ticks_since_full_resync == 0
    end

    test "unseeded tracker with no changes noops" do
      {action, tracker} = DirtyTracker.evaluate(DirtyTracker.new(), [])

      assert action == :noop
      assert tracker.last_seen_updated_at == nil
    end
  end
end
