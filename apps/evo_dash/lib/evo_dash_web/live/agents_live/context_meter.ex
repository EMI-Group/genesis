defmodule EvoDashWeb.AgentsLive.ContextMeter do
  @moduledoc """
  Pure geometry and label derivation for the Agents page's Context tile.

  The tile renders ONE bar whose full width is the model's CONTEXT WINDOW
  (`:context_window` summary key — optional; the core defaults to 200_000).
  The bar's fill is the agent's current context size (`:total_tokens`, the
  provider-reported tokens of the last turn) and a vertical TICK marks the
  compression THRESHOLD (`:compression_threshold`) — the point at which the
  core triggers a context compression. The previous design used a
  threshold-relative `progress` element, which saturated at 100% exactly when
  compression fired and could never show the remaining headroom.

  Everything here is TOTAL: no I/O, no processes, no try/rescue, never
  raises. Missing / malformed / negative values degrade to 0 or the core
  default, and a zero or non-positive window can never produce a division by
  zero or a NaN/Infinity percentage.

  ## Rounding contract

  Every percentage is rounded to EXACTLY ONE decimal place and rendered as a
  string with that place always present (`"0.0"`, `"63.1"`, `"100.0"`). The
  numeric `fill_pct` / `tick_pct` and the `fill_label` / `tick_label` strings
  are derived from the SAME rounded float, so a CSS width and a `data-*`
  attribute can never disagree.

  ## Zones

  The zone is derived from the CURRENT tokens relative to the THRESHOLD (not
  the window), so it tracks how close the agent is to a compression:
  `< 80%` → `:success`, `< 100%` → `:warning`, `>= 100%` → `:error`. An
  unknown (nil/non-positive) threshold means `:success`.
  """

  alias EvoDashWeb.Helpers

  # The core's default context window, used when the (optional) summary key is
  # absent — remote daemons and older summaries do not carry it.
  @default_context_window 200_000

  # The tick's contrasting theme token (the bar track is base-300, the fill is
  # a semantic token). Never a raw color literal.
  @tick_class "bg-base-content"

  @type zone :: :success | :warning | :error

  @typedoc """
  The meter view model: percentages (rounded to one decimal), their string
  rendering, the zone + its daisyUI classes, the raw token counts and the
  tick's tooltip text.
  """
  @type meter :: %{
          fill_pct: float(),
          fill_label: String.t(),
          tick_pct: float() | nil,
          tick_label: String.t() | nil,
          zone: zone(),
          fill_class: String.t(),
          tick_class: String.t(),
          current_tokens: non_neg_integer(),
          threshold_tokens: pos_integer() | nil,
          window_tokens: pos_integer(),
          compression_count: non_neg_integer(),
          tick_title: String.t() | nil
        }

  @doc """
  Builds the Context-tile view model from an agent map (or a summary map).

  Reads `:total_tokens` (nil / negative / non-integer → 0), the optional
  `:compression_threshold` (nil / non-positive / non-integer → tick hidden),
  the optional `:context_window` (see `context_window_from/1`) and
  `:compression_count` (nil → 0). Keys may be atoms or strings; total — never
  raises.
  """
  @spec build(map() | nil) :: meter()
  def build(agent) do
    current_tokens = non_negative_integer(field(agent, :total_tokens))
    window_tokens = context_window_from(agent)
    threshold_tokens = positive_integer(field(agent, :compression_threshold))
    compression_count = non_negative_integer(field(agent, :compression_count))

    fill_pct = percent(current_tokens, window_tokens)
    tick_pct = threshold_tokens && percent(threshold_tokens, window_tokens)
    zone = zone(current_tokens, threshold_tokens)

    %{
      fill_pct: fill_pct,
      fill_label: percent_label(fill_pct),
      tick_pct: tick_pct,
      tick_label: tick_pct && percent_label(tick_pct),
      zone: zone,
      fill_class: fill_class(zone),
      tick_class: @tick_class,
      current_tokens: current_tokens,
      threshold_tokens: threshold_tokens,
      window_tokens: window_tokens,
      compression_count: compression_count,
      tick_title: threshold_tokens && tick_title(threshold_tokens)
    }
  end

  @doc """
  Reads the agent's CONTEXT WINDOW from a summary/agent map defensively.

  Accepts the `:context_window` atom key or its string form, and only a
  POSITIVE INTEGER is accepted — anything else (absent, nil, 0, negative,
  float, string) falls back to the core default of 200_000. Never raises.
  """
  @spec context_window_from(map() | nil) :: pos_integer()
  def context_window_from(agent) do
    case field(agent, :context_window) do
      window when is_integer(window) and window > 0 -> window
      _ -> @default_context_window
    end
  end

  @doc """
  The core's default context window (200_000 tokens), used when a summary
  does not carry a usable `:context_window`.
  """
  @spec default_context_window() :: pos_integer()
  def default_context_window, do: @default_context_window

  @doc """
  The daisyUI fill class for a zone: `bg-success` / `bg-warning` / `bg-error`.
  """
  @spec fill_class(zone()) :: String.t()
  def fill_class(:success), do: "bg-success"
  def fill_class(:warning), do: "bg-warning"
  def fill_class(:error), do: "bg-error"

  @doc """
  The tick's daisyUI class (a contrasting theme token, `bg-base-content`).
  """
  @spec tick_class() :: String.t()
  def tick_class, do: @tick_class

  # Percent of `value` over `window`, rounded to one decimal and clamped to
  # 0..100. `window` is always a positive integer (context_window_from/1), so
  # this can never divide by zero.
  defp percent(value, window) do
    (value / window * 100)
    |> Float.round(1)
    |> min(100.0)
    |> max(0.0)
  end

  # The deterministic one-decimal label ("0.0", "63.1", "100.0") — derived
  # from the rounded float so it always agrees with the numeric field.
  defp percent_label(pct) when is_float(pct), do: :erlang.float_to_binary(pct, decimals: 1)

  # Close to compression: integer math so the 80% boundary is exact
  # (current * 5 < threshold * 4  <=>  current < 0.8 * threshold).
  defp zone(current_tokens, threshold_tokens)
       when is_integer(threshold_tokens) and threshold_tokens > 0 do
    cond do
      current_tokens * 5 < threshold_tokens * 4 -> :success
      current_tokens < threshold_tokens -> :warning
      true -> :error
    end
  end

  defp zone(_current_tokens, _threshold_tokens), do: :success

  defp tick_title(threshold_tokens) do
    "Compression triggers at #{Helpers.format_number(threshold_tokens)} tokens"
  end

  # Atom key preferred, string key as a defensive fallback (a JSON-shaped
  # summary). Total — a non-map agent yields nil.
  defp field(agent, key) when is_map(agent) do
    case Map.get(agent, key) do
      nil -> Map.get(agent, Atom.to_string(key))
      value -> value
    end
  end

  defp field(_agent, _key), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
end
