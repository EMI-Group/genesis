defmodule EvoDashWeb.AgentsLive.ContextMeterTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.AgentsLive.ContextMeter — the geometry,
  labels and zone derivation behind the Agents page's Context meter.

  These functions take plain summary/agent maps — no LiveView, socket, ETS or
  DB setup is required. The meter's contract is TOTAL (never raises), so the
  malformed-input cases below pin the degradation, not error handling.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.ContextMeter

  # The canonical fixture the page test uses too: a 126_272-token compression
  # threshold inside a 200_000-token model context window.
  @threshold 126_272
  @window 200_000

  # The canonical agent summary key set.
  defp agent(overrides \\ []) do
    Map.merge(
      %{
        total_tokens: 0,
        compression_threshold: @threshold,
        context_window: @window,
        compression_count: 0
      },
      Map.new(overrides)
    )
  end

  describe "build/1 — window-relative fill and threshold tick" do
    test "the canonical fixture renders an empty fill with a 63.1% threshold tick" do
      assert ContextMeter.build(agent()) == %{
               fill_pct: 0.0,
               fill_label: "0.0",
               tick_pct: 63.1,
               tick_label: "63.1",
               zone: :success,
               fill_class: "bg-success",
               tick_class: "bg-base-content",
               current_tokens: 0,
               threshold_tokens: @threshold,
               window_tokens: @window,
               compression_count: 0
             }
    end

    test "fill, one-decimal label, zone and fill class track the window at every sampled token count" do
      # The zone is derived from CURRENT tokens vs the THRESHOLD (126_272), so
      # 100_000 (< 80%) is still :success while 110_000 (> 80%, < 100%) is
      # :warning. The tick never moves — it is the threshold's window-relative
      # position — and the numeric field and the string are derived from the SAME
      # rounded float, so a CSS width and a data-* attribute can never disagree.
      rows = [
        {0, 0.0, "0.0", :success, "bg-success"},
        {100_000, 50.0, "50.0", :success, "bg-success"},
        {110_000, 55.0, "55.0", :warning, "bg-warning"},
        {126_272, 63.1, "63.1", :error, "bg-error"},
        {300_000, 100.0, "100.0", :error, "bg-error"}
      ]

      for {tokens, fill, label, zone, class} <- rows do
        meter = ContextMeter.build(agent(total_tokens: tokens))

        assert {meter.fill_pct, meter.fill_label, to_string(meter.fill_pct), meter.zone,
                meter.fill_class, meter.tick_pct, meter.current_tokens} ===
                 {fill, label, label, zone, class, 63.1, tokens},
               "meter for #{tokens} tokens"
      end
    end

    test "the zone boundaries are exact (80% is :warning, 100% is :error)" do
      # Threshold 100_000 so the boundaries are readable integers.
      for {tokens, zone} <- [
            {79_999, :success},
            {80_000, :warning},
            {99_999, :warning},
            {100_000, :error},
            {150_000, :error}
          ] do
        meter = ContextMeter.build(agent(total_tokens: tokens, compression_threshold: 100_000))

        assert meter.zone == zone, "zone for #{tokens} tokens"
      end
    end

    test "compression_count passes through; nil and negative degrade to 0" do
      for {count, expected} <- [{3, 3}, {nil, 0}, {-1, 0}] do
        assert ContextMeter.build(agent(compression_count: count)).compression_count == expected
      end
    end
  end

  describe "build/1 — tick hidden when the threshold is unknown" do
    test "absent, nil, non-positive and non-integer thresholds hide the tick" do
      # The fill and window are INDEPENDENT of the threshold, and an unknown
      # threshold is never "close to compression".
      inputs = [
        agent(compression_threshold: nil, total_tokens: 110_000),
        Map.delete(agent(total_tokens: 110_000), :compression_threshold)
        | for(
            threshold <- [0, -1, 12.5, "126272", :unknown],
            do: agent(compression_threshold: threshold, total_tokens: 110_000)
          )
      ]

      for input <- inputs do
        meter = ContextMeter.build(input)

        assert {meter.tick_pct, meter.tick_label, meter.threshold_tokens, meter.fill_pct,
                meter.window_tokens, meter.zone} === {nil, nil, nil, 55.0, @window, :success}
      end
    end
  end

  describe "context_window_from/1, window fallbacks and clamping" do
    test "default_context_window/0 is the core's 200_000 default" do
      assert ContextMeter.default_context_window() == 200_000
    end

    test "only a POSITIVE INTEGER window is accepted; everything else falls back" do
      for window <- [nil, 0, -1, 12.5, "200000", :window] do
        assert ContextMeter.context_window_from(%{context_window: window}) == 200_000,
               "window for #{inspect(window)}"
      end

      for {input, expected} <- [
            {%{}, 200_000},
            {%{context_window: 128_000}, 128_000},
            {%{"context_window" => 64_000}, 64_000}
          ] do
        assert ContextMeter.context_window_from(input) == expected
      end
    end

    test "the window drives the fill and both percentages clamp to 0..100" do
      rows = [
        # A custom window is honored: 64_000 of 128_000 fills half the bar.
        {[total_tokens: 64_000, context_window: 128_000],
         {128_000, 50.0, "50.0", 98.7, :success}},
        # Window smaller than BOTH the total and the threshold → both clamp.
        {[total_tokens: 250_000, compression_threshold: 200_000, context_window: 100_000],
         {100_000, 100.0, "100.0", 100.0, :error}},
        # 25_000 >= the 10_000 threshold; the tick sits at the bar's edge.
        {[total_tokens: 25_000, compression_threshold: 10_000, context_window: 10_000],
         {10_000, 100.0, "100.0", 100.0, :error}}
      ]

      for {overrides, expected} <- rows do
        meter = ContextMeter.build(agent(overrides))

        assert {meter.window_tokens, meter.fill_pct, meter.fill_label, meter.tick_pct, meter.zone} ===
                 expected
      end
    end
  end

  describe "build/1 — defensive field reads" do
    test "string-keyed agent maps read the same fields as their atom-keyed twin" do
      atom = agent(total_tokens: 110_000, compression_count: 2)
      string = for {key, value} <- atom, into: %{}, do: {Atom.to_string(key), value}

      assert ContextMeter.build(string) == ContextMeter.build(atom)
    end

    test "the atom key wins when a map carries both key shapes" do
      meter = %{"total_tokens" => 90_000, total_tokens: 10_000} |> ContextMeter.build()

      assert {meter.current_tokens, meter.fill_pct} === {10_000, 5.0}
    end

    test "negative and non-integer total_tokens degrade to 0" do
      for tokens <- [-1, -100_000, 12.5, "5000", :many, nil] do
        meter = ContextMeter.build(agent(total_tokens: tokens))

        assert {meter.current_tokens, meter.fill_pct} === {0, 0.0},
               "current_tokens for #{inspect(tokens)}"
      end
    end

    test "nil and non-map inputs never raise" do
      for input <- [nil, :agent, "agent", 123, []] do
        meter = ContextMeter.build(input)

        assert {meter.fill_pct, meter.fill_label, meter.tick_pct, meter.tick_label, meter.zone,
                meter.current_tokens, meter.threshold_tokens, meter.window_tokens,
                meter.compression_count} === {0.0, "0.0", nil, nil, :success, 0, nil, 200_000, 0}
      end
    end

    test "build/1 returns exactly the documented 11-key view model" do
      assert agent() |> ContextMeter.build() |> Map.keys() |> Enum.sort() ==
               [
                 :compression_count,
                 :current_tokens,
                 :fill_class,
                 :fill_label,
                 :fill_pct,
                 :threshold_tokens,
                 :tick_class,
                 :tick_label,
                 :tick_pct,
                 :window_tokens,
                 :zone
               ]
    end
  end
end
