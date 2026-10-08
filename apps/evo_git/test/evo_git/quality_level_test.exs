defmodule EvoGit.QualityLevelTest do
  @moduledoc """
  Tests for `EvoGit.QualityLevel` — the pure source of truth for the
  per-task `:quality_level` (SPEED ↔ QUALITY) option.

  The module is pure (no I/O), so no DB/Store setup is needed.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.QualityLevel

  describe "values/0" do
    test "returns the recognised strings in order" do
      assert QualityLevel.values() == ["fast", "balanced", "high_quality"]
    end
  end

  describe "default/0" do
    test "returns \"balanced\"" do
      assert QualityLevel.default() == "balanced"
    end
  end

  describe "normalize/1" do
    test "returns the default silently for nil" do
      log =
        capture_log(fn ->
          assert QualityLevel.normalize(nil) == "balanced"
        end)

      assert log == ""
    end

    test "returns the default silently for an empty string" do
      log =
        capture_log(fn ->
          assert QualityLevel.normalize("") == "balanced"
        end)

      assert log == ""
    end

    test "passes through each recognised value" do
      for value <- QualityLevel.values() do
        log =
          capture_log(fn ->
            assert QualityLevel.normalize(value) == value
          end)

        assert log == ""
      end
    end

    test "warns and falls back to the default for an unknown string" do
      log =
        capture_log(fn ->
          assert QualityLevel.normalize("turbo") == "balanced"
        end)

      assert log =~ "turbo"
      assert log =~ "balanced"
      assert log =~ "quality_level"
    end

    test "warns and falls back to the default for a non-binary value" do
      log =
        capture_log(fn ->
          assert QualityLevel.normalize(:fast) == "balanced"
        end)

      assert log =~ ":fast"
      assert log =~ "balanced"

      log =
        capture_log(fn ->
          assert QualityLevel.normalize(42) == "balanced"
        end)

      assert log =~ "42"
      assert log =~ "balanced"
    end

    test "never raises for arbitrary terms" do
      assert QualityLevel.normalize(%{a: 1}) == "balanced"
      assert QualityLevel.normalize([:fast]) == "balanced"
      assert QualityLevel.normalize({:fast}) == "balanced"
    end
  end

  describe "guidance/1" do
    @fast """
          ## Task mode: FAST (speed over verification)
          This task is configured for **speed**. Prioritise SPEED:
          - Trust the CONTEXT.md tree and your own routing/investigation — do not re-verify what the context tree already tells you.
          - Delegate quickly and decisively; avoid redundant double-checks.
          - Minimise verification work: run far fewer tests and skip unnecessary compilation/build checks.
          """
          |> String.trim_trailing()

    @high_quality """
                  ## Task mode: HIGH QUALITY (verification over speed)
                  This task is configured for **high quality**. Prioritise CORRECTNESS:
                  - Verify context-tree claims against the actual code before relying on them.
                  - Run the relevant tests for your changes.
                  - Run compilation/build checks to confirm the code builds.
                  - Double-check critical paths before completing.
                  """
                  |> String.trim_trailing()

    test "returns the exact FAST block for \"fast\"" do
      guidance = QualityLevel.guidance("fast")

      assert guidance != ""
      assert guidance =~ "FAST"
      assert guidance == @fast
    end

    test "returns the exact HIGH QUALITY block for \"high_quality\"" do
      guidance = QualityLevel.guidance("high_quality")

      assert guidance != ""
      assert guidance =~ "HIGH QUALITY"
      assert guidance == @high_quality
    end

    test "returns an empty string for balanced, nil, and unknown values" do
      assert QualityLevel.guidance("balanced") == ""
      assert QualityLevel.guidance(nil) == ""
      assert QualityLevel.guidance("") == ""
      assert QualityLevel.guidance("turbo") == ""
      assert QualityLevel.guidance(:fast) == ""
    end
  end
end
