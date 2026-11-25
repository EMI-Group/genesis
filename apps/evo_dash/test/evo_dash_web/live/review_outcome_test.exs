# Pure unit pins for EvoDashWeb.ReviewLive.Outcome — the ONE total decision
# surface that tells the review page how much of its machinery a terminal
# outcome may use. No fixtures, no repo, no store: every function is total
# (it accepts any term), so this module is `async: true` with nothing to
# isolate. The PAGE-level consequences (banner, withheld actions, per-repo
# wording) are pinned in review_live_test.exs's outcome module.
defmodule EvoDashWeb.ReviewLive.OutcomeTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.ReviewLive.Outcome

  describe "classify/1" do
    test "maps the three dedicated terminal outcomes to themselves" do
      assert Outcome.classify(:completed) == :completed
      assert Outcome.classify(:failed) == :failed
      assert Outcome.classify(:cancelled) == :cancelled
    end

    test "any other status is :other (nil, non-terminal, unknown, non-atom)" do
      assert Outcome.classify(nil) == :other
      assert Outcome.classify(:running) == :other
      assert Outcome.classify(:pending) == :other
      assert Outcome.classify(:cancelling) == :other
      assert Outcome.classify(:pausing) == :other
      assert Outcome.classify(:paused) == :other
      assert Outcome.classify(:awaiting_input) == :other
      assert Outcome.classify(:finalizing) == :other
      assert Outcome.classify(:finished) == :other
      # A STRING status is never coerced into a class.
      assert Outcome.classify("completed") == :other
      assert Outcome.classify("failed") == :other
      assert Outcome.classify(42) == :other
      assert Outcome.classify(%{status: :failed}) == :other
    end
  end

  describe "actions_allowed?/1" do
    test "a failed task withholds the action surface" do
      refute Outcome.actions_allowed?(:failed)
    end

    test "every other outcome keeps the action surface (cancelled stays mergeable)" do
      assert Outcome.actions_allowed?(:completed)
      assert Outcome.actions_allowed?(:cancelled)
      assert Outcome.actions_allowed?(:other)
    end
  end

  describe "dismissable?/2" do
    test "ONLY a completed task with no changes anywhere is dismissable" do
      assert Outcome.dismissable?(:completed, true)
    end

    test "a completed task WITH changes is not dismissed as 'no changes'" do
      refute Outcome.dismissable?(:completed, false)
    end

    test "failed and cancelled tasks are never dismissed as 'no changes'" do
      refute Outcome.dismissable?(:failed, true)
      refute Outcome.dismissable?(:failed, false)
      refute Outcome.dismissable?(:cancelled, true)
      refute Outcome.dismissable?(:cancelled, false)
      refute Outcome.dismissable?(:other, true)
      refute Outcome.dismissable?(:other, false)
    end
  end

  describe "show_stats?/2" do
    test "completed and other outcomes always show the stat row" do
      for stats <- [
            %{files_count: 0, commits_count: 0},
            %{"files_count" => 0, "commits_count" => 0},
            %{files_count: 2, commits_count: 1},
            nil,
            :garbage
          ] do
        assert Outcome.show_stats?(stats, :completed)
        assert Outcome.show_stats?(stats, :other)
        assert Outcome.show_stats?(stats, nil)
      end
    end

    test "failed/cancelled hide the row only when NO diff data exists" do
      for outcome <- [:failed, :cancelled] do
        refute Outcome.show_stats?(%{files_count: 0, commits_count: 0}, outcome)
        refute Outcome.show_stats?(%{"files_count" => 0, "commits_count" => 0}, outcome)
        # Absent keys read as 0, so a bare/empty stats map is "no data".
        refute Outcome.show_stats?(%{}, outcome)
        refute Outcome.show_stats?(nil, outcome)

        assert Outcome.show_stats?(%{files_count: 1, commits_count: 0}, outcome)
        assert Outcome.show_stats?(%{files_count: 0, commits_count: 2}, outcome)
        assert Outcome.show_stats?(%{"files_count" => 3, "commits_count" => 4}, outcome)
        # Mixed key shapes are read from BOTH forms, per key.
        assert Outcome.show_stats?(%{"commits_count" => 1, files_count: 0}, outcome)
      end
    end

    test "non-numeric values read as 0 and floats are truncated (never raise)" do
      refute Outcome.show_stats?(%{files_count: "many", commits_count: nil}, :failed)
      refute Outcome.show_stats?(%{files_count: :zero, commits_count: []}, :cancelled)
      assert Outcome.show_stats?(%{files_count: 1.9, commits_count: 0}, :failed)
      refute Outcome.show_stats?(%{files_count: 0.4, commits_count: 0}, :failed)
    end
  end
end
