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

  describe "status_counts/1" do
    test "empty list yields all zeros" do
      assert Charts.status_counts([]) == %{
               total: 0,
               running: 0,
               blocked: 0,
               waiting: 0,
               pending: 0,
               ready: 0
             }
    end

    test "counts agents per status" do
      agents = [
        %{status: :running},
        %{status: :running},
        %{status: :blocked},
        %{status: :waiting},
        %{status: :pending},
        %{status: :ready}
      ]

      assert Charts.status_counts(agents) == %{
               total: 6,
               running: 2,
               blocked: 1,
               waiting: 1,
               pending: 1,
               ready: 1
             }
    end

    test "agents with a missing status key are counted safely (no crash)" do
      assert Charts.status_counts([%{}, %{status: :running}]) == %{
               total: 2,
               running: 1,
               blocked: 0,
               waiting: 0,
               pending: 0,
               ready: 0
             }
    end

    test "unknown status atoms are counted safely (not crashed)" do
      counts = Charts.status_counts([%{status: :weird}, %{status: :running}])

      assert counts.total == 2
      assert counts.running == 1
      assert counts.blocked == 0
    end
  end

  describe "config_totals/1" do
    test "sums model-profile concurrency and max_tool_concurrency" do
      config = %{
        model_profiles: [%{concurrency: 2}, %{concurrency: 3}],
        max_tool_concurrency: 4
      }

      assert Charts.config_totals(config) == %{llm_capacity: 5, tool_capacity: 4}
    end

    test "nil or missing concurrency values count as zero" do
      config = %{
        model_profiles: [%{concurrency: nil}, %{}, %{concurrency: 2}],
        max_tool_concurrency: nil
      }

      assert Charts.config_totals(config) == %{llm_capacity: 2, tool_capacity: 0}
    end

    test "empty config map yields zero capacities (RPC-failure fallback)" do
      assert Charts.config_totals(%{}) == %{llm_capacity: 0, tool_capacity: 0}
    end

    test "non-map arg yields zero capacities" do
      assert Charts.config_totals(nil) == %{llm_capacity: 0, tool_capacity: 0}
    end
  end

  describe "build_sample/2" do
    test "running feeds llm/tool used, blocked feeds waiting, totals threaded through" do
      agents = [
        %{status: :running},
        %{status: :running},
        %{status: :blocked},
        %{status: :waiting},
        %{status: :pending}
      ]

      totals = %{llm_capacity: 4, tool_capacity: 2}

      assert Charts.build_sample(agents, totals) == %{
               llm_used: 2,
               llm_waiting: 1,
               llm_capacity: 4,
               tool_used: 2,
               tool_waiting: 1,
               tool_capacity: 2,
               agents_total: 5,
               agents_running: 2,
               agents_blocked: 1,
               agents_waiting: 1,
               agents_pending: 1
             }
    end

    test "empty agents with zero totals yield a zero sample" do
      sample = Charts.build_sample([], %{llm_capacity: 0, tool_capacity: 0})

      assert sample.llm_used == 0
      assert sample.tool_used == 0
      assert sample.llm_capacity == 0
      assert sample.tool_capacity == 0
      assert sample.agents_total == 0
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
          series: Charts.llm_series([]),
          y_max: 4
        )

      assert html =~ "Collecting data…"
      refute html =~ "<svg"
      refute html =~ "Scale 0–"
    end

    test "renders the svg chart with legend entries and scale footer when samples exist" do
      samples = [
        Charts.build_sample([%{status: :running}, %{status: :blocked}], %{
          llm_capacity: 4,
          tool_capacity: 2
        }),
        Charts.build_sample([%{status: :running}, %{status: :running}], %{
          llm_capacity: 4,
          tool_capacity: 2
        })
      ]

      series = Charts.llm_series(samples)

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
  end
end
