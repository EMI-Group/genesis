defmodule EvoDashWeb.SystemLive.Charts do
  @moduledoc """
  Pure helpers and chart-card components for the SystemLive scheduler-status
  charts (server-rendered SVG).

  ## Charting approach

  Charts are hand-rolled, server-rendered SVG — no JS plotting library is
  added to the bundle (the dashboard ships no package.json/npm workflow and
  the vendored asset set is fixed). Pure Elixir functions here turn a ring
  buffer of samples into polyline/area paths; the SVG is emitted directly in
  HEEx with `preserveAspectRatio="none"` + `vector-effect="non-scaling-stroke"`
  so strokes stay crisp at any width.

  ## Data semantics (must stay truthful)

  Samples arrive PRE-AGGREGATED from the `:evo_git` system sampler on the
  `"system"` PubSub topic (`{:system_sample, node, seq, sample}`, one every
  3 seconds). Each sample map carries the keys the series builders read:
  `llm_used, llm_waiting, llm_capacity, tool_used, tool_waiting, tool_capacity,
  agents_total, agents_running, agents_blocked, agents_waiting, agents_pending,
  scheduler_alive`. The sampler computes the values with the same semantics
  the old dashboard-side aggregation used ("in use" = live slot-holder counts,
  "waiting" = agents blocked on a slot), and `scheduler_alive: false` samples
  (zero capacities) drive the dead-scheduler rendering — no LiveView-side
  special-casing is needed.
  """

  use Phoenix.Component
  use Gettext, backend: EvoDashWeb.Gettext
  import EvoDashWeb.CoreComponents, only: [icon: 1]

  @sample_capacity 60
  @width 300
  @height 100

  # Series colors — CSS-variable references into the `--chart-*` series
  # (defined per theme in app.css: light + dark Adwaita palettes), so chart
  # colors adapt with the theme. Applied via inline `style` attributes
  # (`var()` does not work in SVG presentation attributes like stroke/fill).
  @capacity_color "var(--chart-capacity)"
  @in_use_color "var(--chart-llm)"
  @in_use_tool_color "var(--chart-tool)"
  @waiting_color "var(--chart-waiting)"
  @total_color "var(--chart-agents)"
  @agents_waiting_color "var(--chart-agents-waiting)"
  @agents_pending_color "var(--chart-pending)"

  # ── Ring buffer ──────────────────────────────────────────────────

  @doc """
  Appends a sample to the ring buffer, keeping at most `capacity` samples
  (oldest dropped). Default capacity is 60 samples ≈ 3 minutes at 3s ticks.
  """
  def push(buffer, sample, capacity \\ @sample_capacity) when is_list(buffer) do
    (buffer ++ [sample]) |> Enum.take(-capacity)
  end

  # ── Series derivation (pure) ─────────────────────────────────────

  @doc "LLM-slot chart series: capacity (static reference line), in use (running proxy), waiting."
  def llm_series(samples) when is_list(samples) do
    [
      %{
        name: gettext("Capacity"),
        color: @capacity_color,
        values: values(samples, :llm_capacity),
        static: true
      },
      %{name: gettext("In use"), color: @in_use_color, values: values(samples, :llm_used)},
      %{name: gettext("Waiting"), color: @waiting_color, values: values(samples, :llm_waiting)}
    ]
  end

  @doc "Tool-slot chart series: capacity (static reference line), in use (running proxy), waiting."
  def tool_series(samples) when is_list(samples) do
    [
      %{
        name: gettext("Capacity"),
        color: @capacity_color,
        values: values(samples, :tool_capacity),
        static: true
      },
      %{name: gettext("In use"), color: @in_use_tool_color, values: values(samples, :tool_used)},
      %{name: gettext("Waiting"), color: @waiting_color, values: values(samples, :tool_waiting)}
    ]
  end

  @doc "Agents chart series: total (area) plus running/blocked/waiting/pending."
  def agents_series(samples) when is_list(samples) do
    [
      %{
        name: gettext("Total"),
        color: @total_color,
        values: values(samples, :agents_total),
        area: true
      },
      %{name: gettext("Running"), color: @in_use_color, values: values(samples, :agents_running)},
      %{
        name: gettext("Blocked"),
        color: @waiting_color,
        values: values(samples, :agents_blocked)
      },
      %{
        name: gettext("Waiting"),
        color: @agents_waiting_color,
        values: values(samples, :agents_waiting)
      },
      %{
        name: gettext("Pending"),
        color: @agents_pending_color,
        values: values(samples, :agents_pending)
      }
    ]
  end

  defp values(samples, key), do: Enum.map(samples, &Map.fetch!(&1, key))

  # ── Scale / geometry (pure) ──────────────────────────────────────

  @doc """
  Y-axis maximum for a list of series: max(capacity, observed) × 1.2 headroom,
  with a floor of 4 so the scale can never be zero (no div-by-zero).
  """
  def y_max(series) when is_list(series) do
    observed =
      series
      |> Enum.flat_map(& &1.values)
      |> Enum.max(fn -> 0 end)

    max(4, ceil(observed * 1.2))
  end

  @doc """
  Y position for a value within the fixed chart height, clamped to the top at
  `y_max` (guarded ≥ 1 so the scale can never divide by zero). Used both for
  polyline points (`path_for/2`) and the static capacity reference line.
  """
  def y_for(v, y_max) when is_number(v) and is_number(y_max) do
    y_max = max(y_max, 1)
    @height - min(v, y_max) / y_max * @height
  end

  @doc """
  Converts a series' values into SVG path `d` strings: `:line` is the polyline
  and `:area` the same polyline closed down to the bottom of the chart.

  Values are left-padded with zeros up to the sample capacity (see
  `pad_to_capacity/2`), so a fresh chart grows left-to-right as samples
  accumulate.
  """
  def path_for(values, y_max) when is_list(values) and is_number(y_max) do
    values = pad_to_capacity(values)
    y_max = max(y_max, 1)
    n = length(values)

    points =
      values
      |> Enum.with_index()
      |> Enum.map(fn {v, i} ->
        x = x_for(i, n)
        y = y_for(v, y_max)
        {num(x), num(y)}
      end)

    line = "M " <> Enum.map_join(points, " L ", fn {x, y} -> "#{x} #{y}" end)

    area =
      case points do
        [] ->
          ""

        _ ->
          {first_x, _} = hd(points)
          {last_x, _} = List.last(points)

          "M #{first_x} #{@height} L " <>
            Enum.map_join(points, " L ", fn {x, y} -> "#{x} #{y}" end) <>
            " L #{last_x} #{@height} Z"
      end

    %{line: line, area: area}
  end

  @doc "Left-pads a values list with zeros up to the sample capacity."
  def pad_to_capacity(values, capacity \\ @sample_capacity) when is_list(values) do
    missing = capacity - length(values)
    if missing > 0, do: List.duplicate(0, missing) ++ values, else: values
  end

  defp x_for(_i, 1), do: @width / 2
  defp x_for(i, n), do: i * @width / (n - 1)

  defp num(v), do: v |> Float.round(2) |> Float.to_string()

  # ── Components ───────────────────────────────────────────────────

  attr(:samples, :list, default: [])
  attr(:paused, :boolean, default: false)

  @doc "The full charts section: header row + grid of the three chart cards."
  def charts_section(assigns) do
    llm = llm_series(assigns.samples)
    tools = tool_series(assigns.samples)
    agents = agents_series(assigns.samples)

    assigns =
      assign(assigns,
        llm: llm,
        tools: tools,
        agents: agents,
        llm_max: y_max(llm),
        tools_max: y_max(tools),
        agents_max: y_max(agents)
      )

    ~H"""
    <div class="mt-4">
      <div class="p-4 border-b border-base-300">
        <div class="flex items-center gap-3">
          <.icon name="hero-chart-bar" class="size-5 text-info shrink-0" />
          <div class="flex-1 min-w-0">
            <h2 class="font-bold text-base">{gettext("Scheduler Status")}</h2>
            <p class="text-sm text-base-content/60">
              {gettext(
                "LLM slots, tool slots, and agent activity — sampled every 3 seconds over the last 3 minutes."
              )}
            </p>
          </div>
          <%= if @paused do %>
            <span class="badge badge-warning badge-sm gap-1 shrink-0">
              <.icon name="hero-pause" class="size-3" />
              {gettext("Scheduler Paused")}
            </span>
          <% end %>
        </div>
      </div>
      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 p-4">
        <.chart_card
          title={gettext("LLM Slots")}
          icon="hero-sparkles"
          description={
            gettext(
              "Capacity: total model-profile concurrency. In use: running agents (slot-use proxy — slot holders are not exposed)."
            )
          }
          samples={@samples}
          series={@llm}
          y_max={@llm_max}
        />
        <.chart_card
          title={gettext("Tool Slots")}
          icon="hero-wrench-screwdriver"
          description={
            gettext(
              "Capacity: max_tool_concurrency. In use: running agents (slot-use proxy — slot holders are not exposed)."
            )
          }
          samples={@samples}
          series={@tools}
          y_max={@tools_max}
        />
        <.chart_card
          title={gettext("Agents")}
          icon="hero-user-group"
          description={
            gettext(
              "Total agents with running, blocked (waiting for a slot), waiting, and pending counts."
            )
          }
          samples={@samples}
          series={@agents}
          y_max={@agents_max}
        />
      </div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:description, :string, required: true)
  attr(:samples, :list, default: [])
  attr(:series, :list, required: true)
  attr(:y_max, :integer, required: true)

  @doc """
  One chart card: legend row with last values + a server-rendered SVG
  sparkline. Renders a gettext placeholder while no samples exist yet (static
  mount before the first tick).
  """
  def chart_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-100 p-4">
      <div class="flex items-center gap-2 mb-1">
        <.icon name={@icon} class="size-4 text-base-content/50 shrink-0" />
        <h3 class="font-semibold text-sm">{@title}</h3>
      </div>
      <p class="text-xs text-base-content/60 mb-3">{@description}</p>

      <%= if @samples == [] do %>
        <div class="h-24 flex items-center justify-center text-xs text-base-content/40">
          {gettext("Collecting data…")}
        </div>
      <% else %>
        <div class="flex flex-wrap gap-x-4 gap-y-1 mb-2">
          <%= for s <- @series do %>
            <span class="flex items-center gap-1.5 text-xs">
              <span class="size-2 rounded-full shrink-0" style={"background-color: #{s.color}"} />
              <span class="text-base-content/70">{s.name}</span>
              <span class="font-semibold text-base-content/90">{List.last(s.values) || 0}</span>
            </span>
          <% end %>
        </div>
        <svg viewBox="0 0 300 100" preserveAspectRatio="none" class="w-full h-24 block">
          <%= for g <- 1..3 do %>
            <line
              x1="0"
              x2="300"
              y1={g * 25}
              y2={g * 25}
              style="stroke: var(--color-base-content)"
              stroke-opacity="0.08"
              stroke-width="1"
            />
          <% end %>
          <%= for s <- @series do %>
            <%= if s[:static] do %>
              <% y = y_for(List.last(s.values) || 0, @y_max) %>
              <line
                x1="0"
                x2="300"
                y1={y}
                y2={y}
                style={"stroke: #{s.color}"}
                stroke-width="1.5"
                vector-effect="non-scaling-stroke"
                stroke-dasharray="4 3"
              />
            <% else %>
              <% path = path_for(s.values, @y_max) %>
              <path d={path.area} style={"fill: #{s.color}"} fill-opacity="0.12" />
              <path
                d={path.line}
                fill="none"
                style={"stroke: #{s.color}"}
                stroke-width="1.5"
                vector-effect="non-scaling-stroke"
                stroke-linejoin="round"
                stroke-linecap="round"
              />
            <% end %>
          <% end %>
        </svg>
        <div class="mt-1 flex items-center justify-between text-[10px] text-base-content/40">
          <span>{gettext("Scale 0–%{max}", max: @y_max)}</span>
          <span>{gettext("Last 3 minutes")}</span>
        </div>
      <% end %>
    </div>
    """
  end
end
