defmodule EvoGit.QualityLevel do
  @moduledoc """
  Pure source of truth for the per-task `:quality_level` option — a
  SPEED ↔ QUALITY trade-off.

  A task may carry a `:quality_level` opt whose value is one of the
  recognised STRING values listed by `values/0` (`"fast" | "balanced" |
  "high_quality"`). The value is normalised leniently (`normalize/1`: an
  unknown value logs a warning and falls back to `"balanced"`) and the
  ROOT agent receives a short guidance block in its first-user context
  (`guidance/1`) telling it whether to prioritise speed or correctness.

  This module performs no I/O and never raises.
  """

  require Logger

  @values ["fast", "balanced", "high_quality"]
  @default "balanced"

  @fast_guidance """
                 ## Task mode: FAST (speed over verification)
                 This task is configured for **speed**. Prioritise SPEED:
                 - Trust the CONTEXT.md tree and your own routing/investigation — do not re-verify what the context tree already tells you.
                 - Delegate quickly and decisively; avoid redundant double-checks.
                 - Minimise verification work: run far fewer tests and skip unnecessary compilation/build checks.
                 """
                 |> String.trim_trailing()

  @high_quality_guidance """
                         ## Task mode: HIGH QUALITY (verification over speed)
                         This task is configured for **high quality**. Prioritise CORRECTNESS:
                         - Verify context-tree claims against the actual code before relying on them.
                         - Run the relevant tests for your changes.
                         - Run compilation/build checks to confirm the code builds.
                         - Double-check critical paths before completing.
                         """
                         |> String.trim_trailing()

  @doc """
  The recognised `:quality_level` STRING values, in order.
  """
  @spec values() :: [String.t()]
  def values, do: @values

  @doc """
  The default `:quality_level` value (`"balanced"`).
  """
  @spec default() :: String.t()
  def default, do: @default

  @doc """
  Leniently normalises a raw `:quality_level` value into one of the
  canonical strings from `values/0`.

  `nil` and `""` silently return the default (`"balanced"`). A recognised
  value is returned unchanged. ANY other value (unknown string, non-binary,
  …) logs a warning naming the bad value and falls back to `"balanced"`.
  Never raises and never calls `String.to_atom/1` on the input.
  """
  @spec normalize(term()) :: String.t()
  def normalize(nil), do: @default
  def normalize(""), do: @default
  def normalize(value) when value in @values, do: value

  def normalize(other) do
    Logger.warning(
      "Unknown quality_level #{inspect(other)}; falling back to #{inspect(@default)}"
    )

    @default
  end

  @doc """
  Returns the ROOT-agent guidance block for a normalised `:quality_level`
  value, or `""` when no extra guidance applies.

  `"fast"` → the FAST block, `"high_quality"` → the HIGH QUALITY block,
  anything else (`"balanced"`, `nil`, absent, unknown) → `""`. Total —
  never raises.
  """
  @spec guidance(term()) :: String.t()
  def guidance("fast"), do: @fast_guidance
  def guidance("high_quality"), do: @high_quality_guidance
  def guidance(_), do: ""
end
