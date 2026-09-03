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
  3 seconds). Each sample map carries:

  - a per-model `llm_slots` map (`%{model_id => %{used:, waiting:, capacity:}}`
    — model ids are config-profile id STRINGS, inner keys are atoms) — the ONLY
    source for the LLM Slots chart, which plots ONE selected model. The chart
    reads it DEFENSIVELY (a `Map.get` chain: a sample missing `:llm_slots`, a
    missing model key, or a missing inner key all contribute 0 for that
    sample) so sparklines stay continuous while the sampler key is rolled out.
    Model SELECTION is dashboard-side (see `llm_model_ids/1` + the
    `selected_llm_model` / `model_ids` attrs).
  - the 12 aggregate keys (`llm_used, llm_waiting, llm_capacity, tool_used,
    tool_waiting, tool_capacity, agents_total, agents_running, agents_blocked,
    agents_waiting, agents_pending, scheduler_alive`) — still consumed by the
    tool/agents series builders (`values/2` is Map.fetch!-based, those keys
    always exist); the legacy `llm_*` aggregates NO LONGER drive the LLM chart.

  The sampler computes the tool/agents values with the same semantics the old
  dashboard-side aggregation used ("in use" = live slot-holder counts,
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

  @doc """
  LLM-slot chart series for ONE model profile: capacity (static reference line
  rendered at the latest per-sample capacity), in use (live slot holders),
  waiting (agents queued for a slot). Each series' values derive from each
  sample's `llm_slots[model_id]` map, read DEFENSIVELY (missing `:llm_slots`
  key on the sample, missing model key, or missing inner key ⇒ 0 for that
  sample — see `llm_values/3`). `model_id` may be nil (no model ids in the
  buffer yet / legacy sampler without `llm_slots`): the defensive chain then
  yields an all-zero series, so the chart renders without raising.
  """
  def llm_series(samples, model_id) when is_list(samples) do
    [
      %{
        name: gettext("Capacity"),
        color: @capacity_color,
        values: llm_values(samples, model_id, :capacity),
        static: true
      },
      %{
        name: gettext("In use"),
        color: @in_use_color,
        values: llm_values(samples, model_id, :used)
      },
      %{
        name: gettext("Waiting"),
        color: @waiting_color,
        values: llm_values(samples, model_id, :waiting)
      }
    ]
  end

  @doc """
  Sorted unique model-profile ids present across the samples' `llm_slots`
  maps: the union of `Map.keys(Map.get(sample, :llm_slots, %{}))` per sample.
  Samples without the `:llm_slots` key (legacy sampler / pre-merge builds)
  contribute nothing; `[]` for an empty buffer or a dead scheduler.
  """
  def llm_model_ids(samples) when is_list(samples) do
    samples
    |> Enum.flat_map(fn sample -> Map.keys(Map.get(sample, :llm_slots, %{})) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Per-sample defensive extraction of one metric for one model profile. The
  # `Map.get` chain never raises: a sample without `:llm_slots`, a slots map
  # without the model id, or a model map without the inner key all yield 0 for
  # that sample, keeping sparklines continuous across rollout gaps.
  defp llm_values(samples, model_id, key) do
    Enum.map(samples, fn sample ->
      slots = Map.get(sample, :llm_slots, %{})
      model_slots = Map.get(slots, model_id, %{})
      Map.get(model_slots, key, 0)
    end)
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
  attr(:selected_llm_model, :string, default: nil)

  @doc """
  The full charts section: header row + grid of the three chart cards.

  The LLM Slots card plots ONE model profile. The resolved model follows the
  SAME deterministic rule as the LiveView-side `resolve_selected_llm_model/2`:
  keep `selected_llm_model` when it is present in the samples' model ids,
  otherwise fall back to the first id (`nil` when no ids are known yet — the
  series renders all-zero). Model ids + the resolved selection are threaded
  into the card as `model_ids` / `selected_model` for the in-card selector.
  """
  def charts_section(assigns) do
    llm_ids = llm_model_ids(assigns.samples)

    llm_selected =
      if assigns.selected_llm_model in llm_ids,
        do: assigns.selected_llm_model,
        else: List.first(llm_ids)

    llm = llm_series(assigns.samples, llm_selected)
    tools = tool_series(assigns.samples)
    agents = agents_series(assigns.samples)

    assigns =
      assign(assigns,
        llm: llm,
        tools: tools,
        agents: agents,
        llm_max: y_max(llm),
        tools_max: y_max(tools),
        agents_max: y_max(agents),
        llm_ids: llm_ids,
        llm_selected: llm_selected
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
            # zh_CN: 该卡片描述所选模型的槽位：容量=该模型当前生效并发数（峰谷暂停窗口为0），使用中=正在占用槽位的智能体，等待中=排队等待槽位的智能体
            gettext(
              "Capacity: the selected model's effective concurrency. In use: live slot holders. Waiting: agents queued for a slot."
            )
          }
          samples={@samples}
          series={@llm}
          y_max={@llm_max}
          model_ids={@llm_ids}
          selected_model={@llm_selected}
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
  attr(:model_ids, :list, default: [])
  attr(:selected_model, :string, default: nil)

  @doc """
  One chart card: legend row with last values + a server-rendered SVG
  sparkline. Renders a gettext placeholder while no samples exist yet (static
  mount before the first tick).

  Optional in-card model selector (used by the LLM Slots card): when
  `model_ids` is non-empty, a compact control renders between the description
  and the samples body — a static muted single-model label when exactly one
  model id is known, otherwise a wrap-safe segmented chip set dispatching
  `select_llm_model` (chips carry the raw user-config model id, never
  gettext-ed). When `model_ids == []` (no samples yet / legacy sampler without
  `llm_slots`) no control renders.
  """
  def chart_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 p-4">
      <div class="flex items-center gap-2 mb-1">
        <.icon name={@icon} class="size-4 text-base-content/50 shrink-0" />
        <h3 class="font-semibold text-sm">{@title}</h3>
      </div>
      <p class="text-xs text-base-content/60 mb-3">{@description}</p>

      <%= if @model_ids != [] do %>
        <%= if length(@model_ids) == 1 do %>
          <div class="mb-3">
            <span class="inline-flex items-center gap-1.5 rounded-md border border-base-300 bg-base-100 px-2 py-0.5 text-xs text-base-content/60">
              <span class="size-1.5 rounded-full bg-primary/60" />
              {hd(@model_ids)}
            </span>
          </div>
        <% else %>
          <div class="flex flex-wrap gap-1.5 mb-3" role="group" aria-label={gettext("Model")}>
            <%= for id <- @model_ids do %>
              <button
                type="button"
                phx-click="select_llm_model"
                phx-value-model={id}
                aria-pressed={to_string(id == @selected_model)}
                class={"inline-flex items-center rounded-md border px-2 py-0.5 text-xs transition-colors #{if id == @selected_model, do: "border-primary/40 bg-primary/10 text-primary font-medium", else: "border-base-200 text-base-content/60 hover:border-base-300 hover:text-base-content/80 hover:bg-base-200/40"}"}
              >
                {id}
              </button>
            <% end %>
          </div>
        <% end %>
      <% end %>

      <%= if @samples == [] do %>
        <div class="h-24 flex items-center justify-center text-xs text-base-content/70">
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
        <div class="mt-1 flex items-center justify-between text-xs text-base-content/70">
          <span>{gettext("Scale 0–%{max}", max: @y_max)}</span>
          <span>{gettext("Last 3 minutes")}</span>
        </div>
      <% end %>
    </div>
    """
  end
end
