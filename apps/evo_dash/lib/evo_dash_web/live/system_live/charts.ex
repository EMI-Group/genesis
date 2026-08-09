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

  Live "used slot" holder counts are NOT observable from the dashboard: slot
  holders live only in the `EvoGit.AgentScheduler` GenServer loop state, are
  not mirrored to the `:evogit_sched_meta` ETS table, and are not exposed via
  `RemoteAPI`. "In use" is therefore a clearly-labeled proxy — the count of
  agents in `:running` status (the agents that acquire/hold slots) — and
  `:blocked` (agents waiting for a slot) is the saturation signal. Capacities
  come from the resolved config: Σ model-profile `concurrency` for LLM slots,
  `max_tool_concurrency` for tool slots.
  """

  use Phoenix.Component
  use Gettext, backend: EvoDashWeb.Gettext
  import EvoDashWeb.CoreComponents, only: [icon: 1]

  @sample_capacity 60
  @width 300
  @height 100

  # Series colors (Tailwind palette hex values)
  @capacity_color "#94a3b8"       # slate-400
  @in_use_color "#10b981"         # emerald-500
  @in_use_tool_color "#0ea5e9"    # sky-500
  @waiting_color "#f59e0b"        # amber-500
  @total_color "#6366f1"          # indigo-500
  @agents_waiting_color "#8b5cf6" # violet-500
  @agents_pending_color "#94a3b8" # slate-400

  # ── Ring buffer ──────────────────────────────────────────────────

  @doc """
  Appends a sample to the ring buffer, keeping at most `capacity` samples
  (oldest dropped). Default capacity is 60 samples ≈ 3 minutes at 3s ticks.
  """
  def push(buffer, sample, capacity \\ @sample_capacity) when is_list(buffer) do
    (buffer ++ [sample]) |> Enum.take(-capacity)
  end

  # ── Sample building (pure) ───────────────────────────────────────

  @doc """
  Builds one chart sample from the agent summary list and config totals
  (`%{llm_capacity: int, tool_capacity: int}` — see `config_totals/1`).

  "Used" is the `:running` agent count (slot-use proxy — see moduledoc) and
  `:blocked` (agents waiting for a slot) is the "waiting" count, for both the
  LLM and tool charts.
  """
  def build_sample(agents, totals) when is_list(agents) and is_map(totals) do
    counts = status_counts(agents)

    %{
      llm_used: counts.running,
      llm_waiting: counts.blocked,
      llm_capacity: totals.llm_capacity,
      tool_used: counts.running,
      tool_waiting: counts.blocked,
      tool_capacity: totals.tool_capacity,
      agents_total: counts.total,
      agents_running: counts.running,
      agents_blocked: counts.blocked,
      agents_waiting: counts.waiting,
      agents_pending: counts.pending
    }
  end

  @doc "Per-status agent counts. Missing/unknown statuses count as `:unknown`."
  def status_counts(agents) when is_list(agents) do
    counts = Enum.frequencies_by(agents, fn agent -> Map.get(agent, :status, :unknown) end)

    %{
      total: length(agents),
      running: Map.get(counts, :running, 0),
      blocked: Map.get(counts, :blocked, 0),
      waiting: Map.get(counts, :waiting, 0),
      pending: Map.get(counts, :pending, 0),
      ready: Map.get(counts, :ready, 0)
    }
  end

  @doc """
  Extracts slot capacities from a resolved config map. Missing/unknown keys
  or a non-map (e.g. the `%{}` RPC-failure fallback) yield zero capacities.
  """
  def config_totals(config) when is_map(config) do
    llm =
      Enum.reduce(Map.get(config, :model_profiles, []), 0, fn profile, acc ->
        acc + (Map.get(profile, :concurrency) || 0)
      end)

    %{llm_capacity: llm, tool_capacity: Map.get(config, :max_tool_concurrency) || 0}
  end

  def config_totals(_), do: %{llm_capacity: 0, tool_capacity: 0}

  # ── Series derivation (pure) ─────────────────────────────────────

  @doc "LLM-slot chart series: capacity, in use (running proxy), waiting."
  def llm_series(samples) when is_list(samples) do
    [
      %{name: gettext("Capacity"), color: @capacity_color, values: values(samples, :llm_capacity)},
      %{name: gettext("In use"), color: @in_use_color, values: values(samples, :llm_used)},
      %{name: gettext("Waiting"), color: @waiting_color, values: values(samples, :llm_waiting)}
    ]
  end

  @doc "Tool-slot chart series: capacity, in use (running proxy), waiting."
  def tool_series(samples) when is_list(samples) do
    [
      %{name: gettext("Capacity"), color: @capacity_color, values: values(samples, :tool_capacity)},
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
      %{name: gettext("Blocked"), color: @waiting_color, values: values(samples, :agents_blocked)},
      %{
        name: gettext("Waiting"),
        color: @agents_waiting_color,
        values: values(samples, :agents_waiting)
      },
      %{name: gettext("Pending"), color: @agents_pending_color, values: values(samples, :agents_pending)}
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
        y = @height - min(v, y_max) / y_max * @height
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
      <div class="p-4 border-b border-slate-200 dark:border-slate-800">
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
      <div class="grid grid-cols-1 md:grid-cols-2 gap-3 p-4">
        <.chart_card
          title={gettext("LLM Slots")}
          icon="hero-sparkles"
          description={gettext(
            "Capacity: total model-profile concurrency. In use: running agents (slot-use proxy — slot holders are not exposed)."
          )}
          samples={@samples}
          series={@llm}
          y_max={@llm_max}
        />
        <.chart_card
          title={gettext("Tool Slots")}
          icon="hero-wrench-screwdriver"
          description={gettext(
            "Capacity: max_tool_concurrency. In use: running agents (slot-use proxy — slot holders are not exposed)."
          )}
          samples={@samples}
          series={@tools}
          y_max={@tools_max}
        />
        <.chart_card
          title={gettext("Agents")}
          icon="hero-user-group"
          description={gettext(
            "Total agents with running, blocked (waiting for a slot), waiting, and pending counts."
          )}
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
              stroke="currentColor"
              stroke-opacity="0.08"
              stroke-width="1"
            />
          <% end %>
          <%= for s <- @series do %>
            <% path = path_for(s.values, @y_max) %>
            <path d={path.area} fill={s.color} fill-opacity="0.12" />
            <path
              d={path.line}
              fill="none"
              stroke={s.color}
              stroke-width="1.5"
              vector-effect="non-scaling-stroke"
              stroke-linejoin="round"
              stroke-linecap="round"
            />
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
