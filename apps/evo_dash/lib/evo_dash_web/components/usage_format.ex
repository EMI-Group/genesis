defmodule EvoDashWeb.Components.UsageFormat do
  @moduledoc """
  ONE derivation of the cache-hit PERCENTAGE behind a usage progress bar.

  `EvoDashWeb.Helpers.format_cache_hit_rate/1` owns the user-visible *text*
  ("12.3%"); this module owns the *bar value* that three usage surfaces used to
  hand-roll inline (`min(round(cached / input * 100), 100)`), so the text and the
  bar can never disagree about the formula and a nil/garbage usage map yields the
  same `0` everywhere instead of raising on arithmetic.

  Pure and total: no I/O, no processes, never raises.
  """

  @doc """
  The cache-hit percentage as an integer in `0..100` for a `<progress>` `value`
  (or any other bar); `0` when the map has no usable token counts.
  """
  def cache_hit_percent(usage) when is_map(usage) do
    input = Map.get(usage, :input_tokens, 0)
    cached = Map.get(usage, :cached_tokens, 0)

    if is_integer(input) and input > 0 and is_integer(cached) and cached > 0 do
      min(round(cached / input * 100), 100)
    else
      0
    end
  end

  def cache_hit_percent(_usage), do: 0
end
