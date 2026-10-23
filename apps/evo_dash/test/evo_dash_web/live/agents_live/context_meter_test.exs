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
      meter = ContextMeter.build(agent())

      assert meter.fill_pct === 0.0
      assert meter.fill_label == "0.0"
      assert meter.tick_pct === 63.1
      assert meter.tick_label == "63.1"
      assert meter.zone == :success
      assert meter.fill_class == "bg-success"
      assert meter.tick_class == "bg-base-content"
      assert meter.current_tokens == 0
      assert meter.threshold_tokens == @threshold
      assert meter.window_tokens == @window
      assert meter.compression_count == 0
    end

    test "fill tracks the context window at every sampled token count" do
      # {total_tokens, window-relative fill %, zone} — the zone is derived from
      # CURRENT tokens vs the THRESHOLD (126_272), so 100_000 (< 80%) is still
      # :success while 110_000 (> 80%, < 100%) is :warning.
      for {tokens, fill, zone} <- [
            {0, 0.0, :success},
            {100_000, 50.0, :success},
            {110_000, 55.0, :warning},
            {126_272, 63.1, :error},
            {300_000, 100.0, :error}
          ] do
        meter = ContextMeter.build(agent(total_tokens: tokens))

        assert meter.fill_pct === fill, "fill for #{tokens} tokens"
        assert meter.current_tokens == tokens
        # The tick never moves — it is the threshold's window-relative position.
        assert meter.tick_pct === 63.1
        assert meter.zone == zone, "zone for #{tokens} tokens"
      end
    end

    test "the fill label always carries exactly one decimal place" do
      for {tokens, label} <- [
            {0, "0.0"},
            {100_000, "50.0"},
            {110_000, "55.0"},
            {126_272, "63.1"},
            {300_000, "100.0"}
          ] do
        meter = ContextMeter.build(agent(total_tokens: tokens))

        assert meter.fill_label == label
        # The numeric field and the string are derived from the SAME rounded
        # float, so a CSS width and a data-* attribute can never disagree.
        assert to_string(meter.fill_pct) == label
      end
    end

    test "compression_count passes through; nil and negative degrade to 0" do
      assert ContextMeter.build(agent(compression_count: 3)).compression_count == 3
      assert ContextMeter.build(agent(compression_count: nil)).compression_count == 0
      assert ContextMeter.build(agent(compression_count: -1)).compression_count == 0
    end

    test "fill_class maps each zone to its daisyUI token" do
      assert ContextMeter.build(agent(total_tokens: 0)).fill_class == "bg-success"

      assert ContextMeter.build(agent(total_tokens: 110_000)).fill_class == "bg-warning"

      assert ContextMeter.build(agent(total_tokens: 126_272)).fill_class == "bg-error"
    end

    test "the zone boundaries are exact (80% is :warning, 100% is :error)" do
      # Threshold 100_000 so the boundaries are readable integers.
      at = fn tokens ->
        ContextMeter.build(agent(total_tokens: tokens, compression_threshold: 100_000)).zone
      end

      assert at.(79_999) == :success
      assert at.(80_000) == :warning
      assert at.(99_999) == :warning
      assert at.(100_000) == :error
      assert at.(150_000) == :error
    end

    test "fill and tick are clamped to 0..100" do
      # Window smaller than both the total and the threshold → both clamp.
      meter =
        ContextMeter.build(
          agent(total_tokens: 250_000, compression_threshold: 200_000, context_window: 100_000)
        )

      assert meter.fill_pct === 100.0
      assert meter.tick_pct === 100.0
      assert meter.zone == :error
    end
  end

  describe "build/1 — tick hidden when the threshold is unknown" do
    test "absent, nil, non-positive and non-integer thresholds hide the tick" do
      for threshold <- [nil, 0, -1, 12.5, "126272", :unknown] do
        meter = ContextMeter.build(agent(compression_threshold: threshold, total_tokens: 110_000))

        assert meter.tick_pct == nil, "tick_pct for #{inspect(threshold)}"
        assert meter.tick_label == nil, "tick_label for #{inspect(threshold)}"
        assert meter.threshold_tokens == nil
        # The fill and window are INDEPENDENT of the threshold.
        assert meter.fill_pct === 55.0
        assert meter.window_tokens == @window
        # An unknown threshold is never "close to compression".
        assert meter.zone == :success
      end
    end

    test "a map with no :compression_threshold key at all hides the tick" do
      meter =
        %{total_tokens: 110_000, context_window: @window, compression_count: 0}
        |> ContextMeter.build()

      assert meter.tick_pct == nil
      assert meter.tick_label == nil
      assert meter.threshold_tokens == nil
      assert meter.fill_label == "55.0"
      assert meter.zone == :success
    end
  end

  describe "context_window_from/1 and the window fallbacks" do
    test "default_context_window/0 is the core's 200_000 default" do
      assert ContextMeter.default_context_window() == 200_000
    end

    test "only a POSITIVE INTEGER window is accepted; everything else falls back" do
      for window <- [nil, 0, -1, 12.5, "200000", :window] do
        assert ContextMeter.context_window_from(%{context_window: window}) == 200_000,
               "window for #{inspect(window)}"
      end

      assert ContextMeter.context_window_from(%{}) == 200_000
      assert ContextMeter.context_window_from(%{context_window: 128_000}) == 128_000
      assert ContextMeter.context_window_from(%{"context_window" => 64_000}) == 64_000
    end

    test "the window drives the fill; a custom window is honored" do
      meter = ContextMeter.build(agent(total_tokens: 64_000, context_window: 128_000))

      assert meter.window_tokens == 128_000
      assert meter.fill_pct === 50.0
      assert meter.tick_pct === 98.7
    end

    test "a window smaller than the total clamps the fill to 100.0" do
      meter =
        ContextMeter.build(
          agent(total_tokens: 25_000, compression_threshold: 10_000, context_window: 10_000)
        )

      assert meter.window_tokens == 10_000
      assert meter.fill_pct === 100.0
      assert meter.fill_label == "100.0"
      # 25_000 >= the 10_000 threshold, and the tick sits at the bar's edge.
      assert meter.tick_pct === 100.0
      assert meter.zone == :error
    end
  end

  describe "build/1 — defensive field reads" do
    test "string-keyed agent maps read the same fields" do
      meter =
        ContextMeter.build(%{
          "total_tokens" => 110_000,
          "compression_threshold" => @threshold,
          "context_window" => @window,
          "compression_count" => 2
        })

      assert meter.fill_pct === 55.0
      assert meter.tick_pct === 63.1
      assert meter.zone == :warning
      assert meter.compression_count == 2
      assert meter.current_tokens == 110_000
      assert meter.threshold_tokens == @threshold
      assert meter.window_tokens == @window
    end

    test "the atom key wins when a map carries both key shapes" do
      meter = %{"total_tokens" => 90_000, total_tokens: 10_000} |> ContextMeter.build()

      assert meter.current_tokens == 10_000
      assert meter.fill_pct === 5.0
    end

    test "negative and non-integer total_tokens degrade to 0" do
      for tokens <- [-1, -100_000, 12.5, "5000", :many, nil] do
        meter = ContextMeter.build(agent(total_tokens: tokens))

        assert meter.current_tokens == 0, "current_tokens for #{inspect(tokens)}"
        assert meter.fill_pct === 0.0
      end
    end

    test "nil and non-map inputs never raise" do
      for input <- [nil, :agent, "agent", 123, []] do
        meter = ContextMeter.build(input)

        assert meter.fill_pct === 0.0
        assert meter.fill_label == "0.0"
        assert meter.tick_pct == nil
        assert meter.tick_label == nil
        assert meter.zone == :success
        assert meter.current_tokens == 0
        assert meter.threshold_tokens == nil
        assert meter.window_tokens == 200_000
        assert meter.compression_count == 0
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
