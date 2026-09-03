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
    test "appends a sample to an empty buffer" do
      assert Charts.push([], %{a: 1}) == [%{a: 1}]
    end

    test "appends samples in order" do
      assert Charts.push([1, 2], 3) == [1, 2, 3]
    end

    test "trims to the default capacity of 60, keeping the newest" do
      buffer = Enum.to_list(1..60)

      assert Charts.push(buffer, 61) == Enum.to_list(2..61)
      assert length(Charts.push(buffer, 61)) == 60
    end

    test "trims to a custom capacity" do
      assert Charts.push([1, 2, 3], 4, 3) == [2, 3, 4]
      assert length(Charts.push([1, 2, 3], 4, 3)) == 3
    end

    test "keeps the newest samples when the capacity is smaller than the buffer" do
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

  describe "llm_series/2 and tool_series/1" do
    test "capacity series is marked static and keeps per-sample values" do
      samples = [sample_map(tool_used: 1)]

      # gettext returns the source string "Capacity" in the default locale;
      # the LLM capacity now comes from the selected model's llm_slots entry
      llm_capacity = Enum.find(Charts.llm_series(samples, "alpha"), &(&1.name == "Capacity"))
      assert llm_capacity.static == true
      assert llm_capacity.values == [4]

      # tool/agents series stay AGGREGATED (driven by the 12 aggregate keys)
      tool_capacity = Enum.find(Charts.tool_series(samples), &(&1.name == "Capacity"))
      assert tool_capacity.static == true
      assert tool_capacity.values == [2]

      tool_used = Enum.find(Charts.tool_series(samples), &(&1.name == "In use"))
      assert tool_used.values == [1]

      agents_total = Enum.find(Charts.agents_series(samples), &(&1.name == "Total"))
      assert agents_total.values == [0]

      # Non-capacity series stay dynamic (no static marker)
      refute Enum.any?(
               Charts.llm_series(samples, "alpha"),
               &(&1.name != "Capacity" and &1[:static])
             )
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
      beta = Map.new(Charts.llm_series(samples, "beta"), &{&1.name, &1})
      assert beta["Capacity"].values == [0, 6]
      assert beta["In use"].values == [0, 5]
      assert beta["Waiting"].values == [3, 0]

      alpha = Map.new(Charts.llm_series(samples, "alpha"), &{&1.name, &1})
      assert alpha["Capacity"].values == [4, 4]
      assert alpha["In use"].values == [2, 3]
      assert alpha["Waiting"].values == [1, 2]
    end

    test "llm_series/2 reads defensively: missing :llm_slots or model key yields zeros" do
      legacy = Map.delete(sample_map(), :llm_slots)

      samples = [
        sample_map(llm_slots: %{"alpha" => %{used: 2, waiting: 1, capacity: 4}}),
        # legacy sample without :llm_slots → zeros, no crash
        legacy,
        # sample whose llm_slots lacks the "alpha" key → zeros
        sample_map(llm_slots: %{"beta" => %{used: 9, waiting: 9, capacity: 9}})
      ]

      by_name = Map.new(Charts.llm_series(samples, "alpha"), &{&1.name, &1})
      assert by_name["Capacity"].values == [4, 0, 0]
      assert by_name["In use"].values == [2, 0, 0]
      assert by_name["Waiting"].values == [1, 0, 0]
    end

    test "llm_series/2 with a nil model_id yields an all-zero series without crashing" do
      by_name = Map.new(Charts.llm_series([sample_map(), sample_map()], nil), &{&1.name, &1})
      assert by_name["Capacity"].values == [0, 0]
      assert by_name["In use"].values == [0, 0]
      assert by_name["Waiting"].values == [0, 0]

      # empty buffer: series exist with no values
      assert Enum.all?(Charts.llm_series([], nil), &(&1.values == []))
    end
  end

  describe "llm_model_ids/1" do
    test "returns [] for an empty buffer" do
      assert Charts.llm_model_ids([]) == []
    end

    test "returns [] when every sample is legacy (no :llm_slots)" do
      samples = [Map.delete(sample_map(), :llm_slots), Map.delete(sample_map(), :llm_slots)]
      assert Charts.llm_model_ids(samples) == []
    end

    test "returns [] when llm_slots maps are empty" do
      samples = [sample_map(llm_slots: %{}), sample_map(llm_slots: %{})]
      assert Charts.llm_model_ids(samples) == []
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

  describe "y_max/1" do
    test "has a floor of 4 so the scale can never be zero" do
      assert Charts.y_max([]) == 4
      assert Charts.y_max([%{values: [0, 0]}]) == 4
      assert Charts.y_max([%{values: [3]}]) == 4
    end

    test "applies 1.2x headroom with ceiling" do
      assert Charts.y_max([%{values: [5]}]) == 6
      assert Charts.y_max([%{values: [7]}]) == 9
      assert Charts.y_max([%{values: [10]}]) == 12
    end

    test "takes the max across multiple series" do
      series = [%{values: [1, 2]}, %{values: [10, 4]}]
      assert Charts.y_max(series) == 12
    end
  end

  describe "pad_to_capacity/2" do
    test "left-pads zeros up to the default capacity of 60" do
      assert Charts.pad_to_capacity([1, 2, 3]) == List.duplicate(0, 57) ++ [1, 2, 3]
      assert length(Charts.pad_to_capacity([1, 2, 3])) == 60
    end

    test "empty list pads to 60 zeros" do
      assert Charts.pad_to_capacity([]) == List.duplicate(0, 60)
    end

    test "is a no-op at or over capacity" do
      full = Enum.to_list(1..60)
      over = Enum.to_list(1..70)

      assert Charts.pad_to_capacity(full) == full
      assert Charts.pad_to_capacity(over) == over
    end

    test "honors a custom capacity" do
      assert Charts.pad_to_capacity([1], 3) == [0, 0, 1]
    end
  end

  describe "path_for/2 geometry" do
    test "produces 60 points after zero padding" do
      path = Charts.path_for([1, 2, 3], 10)

      # line: "M p0" + 59 × " L pN"; area: "M bottom" + 60 × " L pN" + " L bottom Z"
      assert length(String.split(path.line, " L ")) == 60
      assert length(String.split(path.area, " L ")) == 62
    end

    test "line starts at x=0 and ends at x=300" do
      path = Charts.path_for([1], 10)

      assert String.starts_with?(path.line, "M 0")
      # The last point's x coordinate is 300.0 (its y depends on the last value)
      assert path.line |> String.split(" L ") |> List.last() |> String.starts_with?("300.0")
    end

    test "value 0 maps to the bottom of the chart (y=100)" do
      path = Charts.path_for([0], 10)

      assert String.ends_with?(path.line, "300.0 100.0")
    end

    test "value above y_max is clamped to the top of the chart (y=0)" do
      path = Charts.path_for([100], 10)

      assert String.ends_with?(path.line, "300.0 0.0")
    end

    test "area closes back down to the bottom with Z" do
      path = Charts.path_for([1, 2], 10)

      # The area opens at the bottom-left corner: the opening y is the raw
      # `@height` integer (100), while the point coordinates go through num/1.
      assert String.starts_with?(path.area, "M 0.0 100")
      assert String.ends_with?(path.area, "Z")
    end

    test "empty values input does not crash" do
      path = Charts.path_for([], 10)

      assert length(String.split(path.line, " L ")) == 60
    end
  end

  describe "chart_card/1 component" do
    test "renders the collecting-data placeholder with no svg when samples are empty" do
      html =
        render_component(&Charts.chart_card/1,
          title: "LLM Slots",
          icon: "hero-sparkles",
          description: "desc",
          samples: [],
          series: Charts.llm_series([], nil),
          y_max: 4
        )

      assert html =~ "Collecting data…"
      refute html =~ "<svg"
      refute html =~ "Scale 0–"
      # no in-card model selector while no model ids are known yet
      refute html =~ "role=\"group\""
      refute html =~ "select_llm_model"
      refute html =~ "aria-pressed"
    end

    test "renders the svg chart with legend entries and scale footer when samples exist" do
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

      # The card plots the SELECTED model ("alpha"); beta's numbers never
      # reach the legend.
      series = Charts.llm_series(samples, "alpha")

      html =
        render_component(&Charts.chart_card/1,
          title: "LLM Slots",
          icon: "hero-sparkles",
          description: "desc",
          samples: samples,
          series: series,
          y_max: Charts.y_max(series)
        )

      assert html =~ "<svg"
      # Legend: series names + last values (capacity 4 / in use 2 / waiting 0)
      assert html =~ "Capacity"
      assert html =~ "In use"
      assert html =~ "Waiting"
      assert html =~ "4"
      assert html =~ "2"
      # Footer
      assert html =~ "Scale 0–"
      assert html =~ "Last 3 minutes"
    end

    test "renders the static capacity series as a dashed horizontal line, not a path" do
      samples = [sample_map(), sample_map()]

      series = Charts.llm_series(samples, "alpha")

      html =
        render_component(&Charts.chart_card/1,
          title: "LLM Slots",
          icon: "hero-sparkles",
          description: "desc",
          samples: samples,
          series: series,
          y_max: Charts.y_max(series)
        )

      doc = Floki.parse_document!(html)

      # Static capacity: ONE full-width horizontal dashed line (y1 == y2),
      # stroked with the capacity color. Colors are CSS-variable references in
      # inline style attributes (var() is invalid in SVG presentation
      # attributes like stroke), so no stroke attribute is present.
      [line] = Floki.find(doc, "line[stroke-dasharray='4 3']")
      assert Floki.attribute(line, "x1") == ["0"]
      assert Floki.attribute(line, "x2") == ["300"]
      [y1] = Floki.attribute(line, "y1")
      [y2] = Floki.attribute(line, "y2")
      assert y1 == y2
      assert Floki.attribute(line, "style") == ["stroke: var(--chart-capacity)"]

      # No path is rendered for the capacity series: only the 2 non-static
      # series (in use, waiting) each render an area + line path
      assert length(Floki.find(doc, "path")) == 4

      refute Enum.any?(
               Floki.find(doc, "path"),
               &(Floki.attribute(&1, "style") == ["stroke: var(--chart-capacity)"])
             )

      # The capacity color appears only in the legend dot (background-color)
      # and the static line (stroke) — two elements carrying the CSS var
      assert length(Floki.find(doc, ~s|[style*="var(--chart-capacity)"]|)) == 2
      assert length(Floki.find(doc, ~s|line[style*="var(--chart-capacity)"]|)) == 1
    end

    test "renders a static muted single-model label when exactly one model id is known" do
      samples = [sample_map(llm_slots: %{"alpha" => %{used: 2, waiting: 1, capacity: 4}})]
      series = Charts.llm_series(samples, "alpha")

      html =
        render_component(&Charts.chart_card/1,
          title: "LLM Slots",
          icon: "hero-sparkles",
          description: "desc",
          samples: samples,
          series: series,
          y_max: Charts.y_max(series),
          model_ids: ["alpha"],
          selected_model: "alpha"
        )

      # the muted pill (dot + id), NOT the interactive dropdown
      assert html =~ "rounded-full bg-primary/60"
      assert html =~ "alpha"
      refute html =~ "role=\"group\""
      refute html =~ "select_llm_model"
      refute html =~ "<select"
      refute html =~ "aria-pressed"
    end

    test "renders a compact dropdown selector when multiple model ids are known" do
      # alpha + beta present
      samples = [sample_map()]
      series = Charts.llm_series(samples, "alpha")

      html =
        render_component(&Charts.chart_card/1,
          title: "LLM Slots",
          icon: "hero-sparkles",
          description: "desc",
          samples: samples,
          series: series,
          y_max: Charts.y_max(series),
          model_ids: ["alpha", "beta"],
          selected_model: "alpha"
        )

      assert html =~ ~s(phx-change="select_llm_model")
      assert html =~ ~s(aria-label="Model")
      assert html =~ "select-sm"

      doc = Floki.parse_document!(html)
      selects = Floki.find(doc, ~s(select[name="model"][phx-change="select_llm_model"]))
      assert length(selects) == 1

      options = Floki.find(doc, "option")
      assert length(options) == 2
      assert Enum.map(options, &Floki.attribute(&1, "value")) == [["alpha"], ["beta"]]

      # The option equal to `selected_model` ("alpha") is preselected.
      alpha_opt = Enum.find(options, &(Floki.attribute(&1, "value") == ["alpha"]))
      beta_opt = Enum.find(options, &(Floki.attribute(&1, "value") == ["beta"]))
      assert Floki.attribute(alpha_opt, "selected") == ["selected"]
      assert Floki.attribute(beta_opt, "selected") == []
      refute html =~ "role=\"group\""
      refute html =~ "aria-pressed"
    end

    test "renders no in-card model selector when no model ids are known" do
      samples = [sample_map(llm_slots: %{})]
      series = Charts.llm_series(samples, nil)

      html =
        render_component(&Charts.chart_card/1,
          title: "LLM Slots",
          icon: "hero-sparkles",
          description: "desc",
          samples: samples,
          series: series,
          y_max: Charts.y_max(series)
        )

      assert html =~ "<svg"
      # no control at all: neither the dropdown nor the single-model pill
      refute html =~ "select_llm_model"
      refute html =~ "<select"
      refute html =~ "rounded-full bg-primary/60"
    end
  end
end
