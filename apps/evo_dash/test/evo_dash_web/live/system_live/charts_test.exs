defmodule EvoDashWeb.SystemLive.ChartsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SystemLive.Charts

  # Pure unit + component tests for the scheduler-status chart helpers and
  # components (`EvoDashWeb.SystemLive.Charts`). All helpers are pure list/map
  # functions (no Application env), so `async: true` is safe; the component
  # smoke tests use `render_component/2` (same pattern as
  # project_components_test.exs).

  describe "push/2,3" do
    test "appends samples in order and trims to the newest N" do
      assert Charts.push([], %{a: 1}) == [%{a: 1}]
      assert Charts.push([1, 2], 3) == [1, 2, 3]

      # default capacity 60, a custom capacity, and a capacity below the buffer
      assert Charts.push(Enum.to_list(1..60), 61) == Enum.to_list(2..61)
      assert Charts.push([1, 2, 3], 4, 3) == [2, 3, 4]
      assert Charts.push([1, 2, 3, 4, 5], 6, 2) == [5, 6]
    end
  end

  # A sample map as emitted by the evo_git system sampler (the "system"
  # topic contract): the 12 aggregate keys (still driving the tool/agents
  # series) plus the per-model `llm_slots` map (the ONLY source for the LLM
  # Slots chart, which plots one selected model). Overrides let tests vary
  # individual keys — pass `llm_slots: %{...}` to replace the whole map.
  defp sample_map, do: sample_map(%{})

  defp sample_map(overrides) do
    Map.merge(
      %{
        llm_used: 0,
        llm_waiting: 0,
        llm_capacity: 4,
        llm_slots: %{
          "alpha" => %{used: 2, waiting: 1, capacity: 4},
          "beta" => %{used: 0, waiting: 3, capacity: 0}
        },
        tool_used: 0,
        tool_waiting: 0,
        tool_capacity: 2,
        agents_total: 0,
        agents_running: 0,
        agents_blocked: 0,
        agents_waiting: 0,
        agents_pending: 0,
        scheduler_alive: true
      },
      Map.new(overrides)
    )
  end

  defp series_by_name(series), do: Map.new(series, &{&1.name, &1})

  defp render_llm_card(samples, opts \\ []) do
    series = Charts.llm_series(samples, Keyword.get(opts, :model, "alpha"))

    render_component(
      &Charts.chart_card/1,
      [
        title: "LLM Slots",
        icon: "hero-sparkles",
        description: "desc",
        samples: samples,
        series: series,
        y_max: Charts.y_max(series)
      ] ++ Keyword.take(opts, [:model_ids, :selected_model])
    )
  end

  describe "llm_series/2 and tool_series/1" do
    test "capacity series are static reference lines; tool/agents series stay aggregated" do
      samples = [sample_map(tool_used: 1)]

      # gettext returns the source string "Capacity" in the default locale;
      # the LLM capacity comes from the selected model's llm_slots entry.
      llm = Charts.llm_series(samples, "alpha")
      llm_capacity = Enum.find(llm, &(&1.name == "Capacity"))
      assert llm_capacity.static == true
      assert llm_capacity.values == [4]

      # tool/agents series stay AGGREGATED (driven by the 12 aggregate keys)
      tool_capacity = Enum.find(Charts.tool_series(samples), &(&1.name == "Capacity"))
      assert tool_capacity.static == true
      assert tool_capacity.values == [2]

      assert Enum.find(Charts.tool_series(samples), &(&1.name == "In use")).values == [1]
      assert Enum.find(Charts.agents_series(samples), &(&1.name == "Total")).values == [0]

      # Non-capacity series stay dynamic (no static marker)
      refute Enum.any?(llm, &(&1.name != "Capacity" and &1[:static]))
    end

    test "llm_series/2 plots only the requested model's llm_slots numbers, never a sum" do
      samples = [
        sample_map(
          llm_slots: %{
            "alpha" => %{used: 2, waiting: 1, capacity: 4},
            "beta" => %{used: 0, waiting: 3, capacity: 0}
          }
        ),
        sample_map(
          llm_slots: %{
            "alpha" => %{used: 3, waiting: 2, capacity: 4},
            "beta" => %{used: 5, waiting: 0, capacity: 6}
          }
        )
      ]

      # beta's series carry beta's numbers — NOT a sum with alpha
      for {model, expected} <- [
            {"beta", {[0, 6], [0, 5], [3, 0]}},
            {"alpha", {[4, 4], [2, 3], [1, 2]}}
          ] do
        by_name = series_by_name(Charts.llm_series(samples, model))

        assert {by_name["Capacity"].values, by_name["In use"].values, by_name["Waiting"].values} ==
                 expected,
               "expected #{model}-only values"
      end
    end

    test "llm_series/2 reads defensively: missing :llm_slots, missing model key, or nil model → zeros" do
      samples = [
        sample_map(llm_slots: %{"alpha" => %{used: 2, waiting: 1, capacity: 4}}),
        # legacy sample without :llm_slots → zeros, no crash
        Map.delete(sample_map(), :llm_slots),
        # sample whose llm_slots lacks the "alpha" key → zeros
        sample_map(llm_slots: %{"beta" => %{used: 9, waiting: 9, capacity: 9}})
      ]

      values = fn series -> Enum.map(series, & &1.values) end

      assert values.(Charts.llm_series(samples, "alpha")) == [[4, 0, 0], [2, 0, 0], [1, 0, 0]]

      # nil model_id → all-zero series without crashing
      assert values.(Charts.llm_series([sample_map(), sample_map()], nil)) ==
               [[0, 0], [0, 0], [0, 0]]

      # empty buffer: series exist with no values
      assert Enum.all?(Charts.llm_series([], nil), &(&1.values == []))
    end
  end

  describe "llm_model_ids/1" do
    test "returns [] for an empty buffer, legacy samples, or empty slot maps" do
      assert Charts.llm_model_ids([]) == []

      legacy = [Map.delete(sample_map(), :llm_slots), Map.delete(sample_map(), :llm_slots)]
      assert Charts.llm_model_ids(legacy) == []

      assert Charts.llm_model_ids([sample_map(llm_slots: %{}), sample_map(llm_slots: %{})]) == []
    end

    test "returns sorted unique ids from the union across samples" do
      samples = [
        sample_map(
          llm_slots: %{
            "beta" => %{used: 1, waiting: 0, capacity: 2},
            "alpha" => %{used: 0, waiting: 0, capacity: 1}
          }
        ),
        sample_map(
          llm_slots: %{
            "alpha" => %{used: 0, waiting: 0, capacity: 1},
            "gamma" => %{used: 0, waiting: 0, capacity: 3}
          }
        )
      ]

      assert Charts.llm_model_ids(samples) == ["alpha", "beta", "gamma"]
    end
  end

  describe "scale helpers" do
    test "floors at 4, applies 1.2x headroom with ceiling, and takes the max across series" do
      cases = [
        # floor of 4 so the scale can never be zero
        {[], 4},
        {[%{values: [0, 0]}], 4},
        {[%{values: [3]}], 4},
        # 1.2x headroom
        {[%{values: [5]}], 6},
        {[%{values: [7]}], 9},
        {[%{values: [10]}], 12},
        # max across multiple series
        {[%{values: [1, 2]}, %{values: [10, 4]}], 12}
      ]

      for {series, expected} <- cases do
        assert Charts.y_max(series) == expected,
               "expected y_max(#{inspect(series)}) == #{expected}"
      end
    end

    test "pad_to_capacity/2 left-pads zeros up to the default capacity of 60" do
      assert Charts.pad_to_capacity([1, 2, 3]) == List.duplicate(0, 57) ++ [1, 2, 3]
      assert Charts.pad_to_capacity([]) == List.duplicate(0, 60)
    end

    test "is a no-op at or over capacity and honors a custom capacity" do
      full = Enum.to_list(1..60)
      over = Enum.to_list(1..70)

      assert Charts.pad_to_capacity(full) == full
      assert Charts.pad_to_capacity(over) == over
      assert Charts.pad_to_capacity([1], 3) == [0, 0, 1]
    end
  end

  describe "path_for/2 geometry" do
    test "pads to 60 points spanning x=0..300 and clamps values to the chart" do
      # line: "M p0" + 59 × " L pN"; area: "M bottom" + 60 × " L pN" + " L bottom Z"
      path = Charts.path_for([1, 2, 3], 10)
      assert length(String.split(path.line, " L ")) == 60
      assert length(String.split(path.area, " L ")) == 62

      path = Charts.path_for([1], 10)
      assert String.starts_with?(path.line, "M 0")
      # The last point's x coordinate is 300.0 (its y depends on the last value)
      assert path.line |> String.split(" L ") |> List.last() |> String.starts_with?("300.0")

      # value 0 → bottom of the chart; a value above y_max is clamped to the top
      assert String.ends_with?(Charts.path_for([0], 10).line, "300.0 100.0")
      assert String.ends_with?(Charts.path_for([100], 10).line, "300.0 0.0")

      # empty values input does not crash
      assert length(String.split(Charts.path_for([], 10).line, " L ")) == 60

      # the area opens at the bottom-left corner (the opening y is the raw
      # `@height` integer, 100, while point coordinates go through num/1) and
      # closes back down with Z
      area = Charts.path_for([1, 2], 10).area
      assert String.starts_with?(area, "M 0.0 100")
      assert String.ends_with?(area, "Z")
    end
  end

  describe "chart_card/1 component" do
    test "renders the collecting-data placeholder with no svg when samples are empty" do
      html = render_llm_card([], model: nil)

      assert html =~ "Collecting data…"
      refute html =~ "<svg"
      refute html =~ "Scale 0–"

      # no in-card model selector while no model ids are known yet
      for absent <- ["role=\"group\"", "select_llm_model", "aria-pressed"] do
        refute html =~ absent
      end
    end

    test "renders the svg chart with legend entries, a static dashed capacity line, and the scale footer" do
      samples = [
        sample_map(
          llm_slots: %{
            "alpha" => %{used: 1, waiting: 1, capacity: 4},
            "beta" => %{used: 0, waiting: 0, capacity: 0}
          }
        ),
        sample_map(
          llm_slots: %{
            "alpha" => %{used: 2, waiting: 0, capacity: 4},
            "beta" => %{used: 3, waiting: 2, capacity: 2}
          }
        )
      ]

      # The card plots the SELECTED model ("alpha"); beta's numbers never reach
      # the legend. Legend rows carry names + last values (capacity 4 / in use
      # 2 / waiting 0).
      html = render_llm_card(samples)

      assert html =~ "<svg"

      for text <- ["Capacity", "In use", "Waiting", "4", "2"] do
        assert html =~ text
      end

      assert html =~ "Scale 0–"
      assert html =~ "Last 3 minutes"

      doc = Floki.parse_document!(html)

      # Static capacity: ONE full-width horizontal dashed line (y1 == y2),
      # stroked with the capacity color via an inline style (colors are CSS
      # variable references — var() is invalid in SVG presentation attributes
      # like stroke, so no stroke attribute is present).
      [line] = Floki.find(doc, "line[stroke-dasharray='4 3']")
      assert Floki.attribute(line, "x1") == ["0"]
      assert Floki.attribute(line, "x2") == ["300"]
      [y1] = Floki.attribute(line, "y1")
      [y2] = Floki.attribute(line, "y2")
      assert y1 == y2
      assert Floki.attribute(line, "style") == ["stroke: var(--chart-capacity)"]

      # No path is rendered for the capacity series: only the 2 non-static
      # series (in use, waiting) each render an area + line path.
      assert length(Floki.find(doc, "path")) == 4

      refute Enum.any?(
               Floki.find(doc, "path"),
               &(Floki.attribute(&1, "style") == ["stroke: var(--chart-capacity)"])
             )

      # The capacity color appears only in the legend dot (background-color)
      # and the static line (stroke) — two elements carrying the CSS var.
      assert length(Floki.find(doc, ~s|[style*="var(--chart-capacity)"]|)) == 2
      assert length(Floki.find(doc, ~s|line[style*="var(--chart-capacity)"]|)) == 1
    end

    test "renders the in-card model selector in each model-id state" do
      # Exactly one model id → the muted pill (dot + id), NOT the interactive dropdown.
      single = [sample_map(llm_slots: %{"alpha" => %{used: 2, waiting: 1, capacity: 4}})]
      html = render_llm_card(single, model_ids: ["alpha"], selected_model: "alpha")

      assert html =~ "rounded-full bg-primary/60"
      assert html =~ "alpha"

      for absent <- ["role=\"group\"", "select_llm_model", "<select", "aria-pressed"] do
        refute html =~ absent
      end

      # Multiple model ids → a compact dropdown listing every id, the selected one preselected.
      html =
        render_llm_card([sample_map()], model_ids: ["alpha", "beta"], selected_model: "alpha")

      assert html =~ ~s(phx-change="select_llm_model")
      assert html =~ ~s(aria-label="Model")
      assert html =~ "select-sm"

      doc = Floki.parse_document!(html)
      assert length(Floki.find(doc, ~s(select[name="model"][phx-change="select_llm_model"]))) == 1

      options = Floki.find(doc, "option")
      assert Enum.map(options, &Floki.attribute(&1, "value")) == [["alpha"], ["beta"]]

      alpha_opt = Enum.find(options, &(Floki.attribute(&1, "value") == ["alpha"]))
      beta_opt = Enum.find(options, &(Floki.attribute(&1, "value") == ["beta"]))
      assert Floki.attribute(alpha_opt, "selected") == ["selected"]
      assert Floki.attribute(beta_opt, "selected") == []

      refute html =~ "role=\"group\""
      refute html =~ "aria-pressed"

      # No model ids known → no control at all: neither the dropdown nor the pill.
      html = render_llm_card([sample_map(llm_slots: %{})], model: nil)

      assert html =~ "<svg"

      for absent <- ["select_llm_model", "<select", "rounded-full bg-primary/60"] do
        refute html =~ absent
      end
    end
  end
end
