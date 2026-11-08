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

  - a per-POOL `llm_slots` map (`%{pool_id => %{used:, waiting:, capacity:}}`
    — `pool_id` is the PROVIDER PROFILE (account) id STRING, i.e. the
    `[[llm.providers]]` entry id, and inner keys are atoms) — the ONLY source
    for the LLM Slots chart, which plots ONE selected pool. Pools are provider
    profiles, NOT models: every model configured under one profile shares that
    profile's slots, capacity, backoff and peak schedule (see
    `EvoGit.AgentScheduler.get_llm_slot_status/0`). The chart reads it
    DEFENSIVELY (a `Map.get` chain: a sample missing `:llm_slots`, a missing
    pool key, or a missing inner key all contribute 0 for that sample) so
    sparklines stay continuous while the sampler key is rolled out.
    Pool SELECTION is dashboard-side (see `llm_model_ids/1` + the
    `selected_llm_model` / `model_ids` attrs).
  - an OPTIONAL `llm_pools` map (`%{pool_id => %{label: String.t() | nil,
    models: [String.t()]}}`) carrying the display label of the provider
    profile and the bare configured model ids that share its pool. It is
    presentation-only metadata for the in-card selector and is read
    DEFENSIVELY (`llm_pool_options/1`): a sample missing the key (legacy
    sampler), a non-map value, a missing/non-map per-pool entry, a blank or
    non-binary `label`, or a non-list/non-binary `models` all fall back to the
    raw pool id with no model suffix. Ids, labels and model names are
    user-config STRINGS — never atomized, never gettext-ed.
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
  LLM-slot chart series for ONE provider-profile pool: capacity (static
  reference line rendered at the latest per-sample capacity), in use (live
  slot holders), waiting (agents queued for a slot). Each series' values derive
  from each sample's `llm_slots[pool_id]` map, read DEFENSIVELY (missing
  `:llm_slots` key on the sample, missing pool key, or missing inner key ⇒ 0
  for that sample — see `llm_values/3`). `pool_id` may be nil (no pool ids in
  the buffer yet / legacy sampler without `llm_slots`): the defensive chain
  then yields an all-zero series, so the chart renders without raising.
  """
  def llm_series(samples, pool_id) when is_list(samples) do
    [
      %{
        name: gettext("Capacity"),
        color: @capacity_color,
        values: llm_values(samples, pool_id, :capacity),
        static: true
      },
      %{
        name: gettext("In use"),
        color: @in_use_color,
        values: llm_values(samples, pool_id, :used)
      },
      %{
        name: gettext("Waiting"),
        color: @waiting_color,
        values: llm_values(samples, pool_id, :waiting)
      }
    ]
  end

  @doc """
  Sorted unique provider-profile (LLM pool) ids present across the samples'
  `llm_slots` maps: the union of `Map.keys(Map.get(sample, :llm_slots, %{}))`
  per sample. Samples without the `:llm_slots` key (legacy sampler /
  pre-merge builds) contribute nothing; `[]` for an empty buffer or a dead
  scheduler. This list ALSO defines the order of `llm_pool_options/1`.
  """
  def llm_model_ids(samples) when is_list(samples) do
    samples
    |> Enum.flat_map(fn sample -> Map.keys(Map.get(sample, :llm_slots, %{})) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Display options for the in-card LLM pool selector, ONE entry per pool id
  reported by `llm_model_ids/1` (so the order follows that list):

      [%{id: pool_id, label: display_label, models: [model_id]}]

  `label` is the already-formatted option text from `format_pool_label/1`;
  `models` are the bare configured model ids that share that pool (`[]` when
  unknown). The metadata comes from the samples' OPTIONAL `llm_pools` map —
  `%{pool_id => %{label: String.t() | nil, models: [String.t()]}}` — and is
  taken from the NEWEST sample carrying a map entry for that id (samples are
  oldest→newest). Everything is read defensively: a missing `:llm_pools` /
  `"llm_pools"` key, a non-map value, a missing or non-map entry for an id, a
  blank/non-binary `label`, or a non-list/non-binary `models` degrades to
  `%{id: pool_id, label: pool_id, models: []}` — i.e. exactly the pre-`llm_pools`
  rendering. `[]` for an empty buffer or a legacy sampler.
  """
  def llm_pool_options(samples) when is_list(samples) do
    Enum.map(llm_model_ids(samples), fn pool_id ->
      {label, models} = newest_pool_metadata(samples, pool_id)

      %{
        id: pool_id,
        label: format_pool_label(%{id: pool_id, label: label, models: models}),
        models: models
      }
    end)
  end

  @doc """
  The single formatting point for a pool option label (`%{id:, label:, models:}`,
  `label` optional and user-config — never gettext-ed):

    * label + models → `"<label> — <m1, m2>"` (em dash, `", "`-joined models)
    * label only → `"<label>"`
    * models only → `"<pool_id> — <m1, m2>"`
    * neither → `"<pool_id>"`
  """
  def format_pool_label(%{id: id} = pool) when is_binary(id) do
    prefix =
      case Map.get(pool, :label) do
        label when is_binary(label) and label != "" -> label
        _ -> id
      end

    case Map.get(pool, :models) do
      [_ | _] = models -> prefix <> " — " <> Enum.join(models, ", ")
      _ -> prefix
    end
  end

  # Newest sample carrying a usable (map) `llm_pools` entry for `pool_id` wins.
  # `Enum.find_value/3` returns the first TRUTHY result while walking
  # newest→oldest, so a newer entry with unusable fields (`{nil, []}`) still
  # wins over an older, richer one — the sampler emits one shape per build.
  defp newest_pool_metadata(samples, pool_id) do
    samples
    |> Enum.reverse()
    |> Enum.find_value({nil, []}, fn sample ->
      case pool_entry(sample, pool_id) do
        nil ->
          nil

        entry ->
          {normalize_pool_label(Map.get(entry, :label) || Map.get(entry, "label")),
           normalize_pool_models(Map.get(entry, :models) || Map.get(entry, "models"))}
      end
    end)
  end

  # `llm_pools` is optional and may arrive atom- or string-keyed; anything that
  # is not a map carrying a map entry for the id yields nil (⇒ raw-id fallback).
  defp pool_entry(sample, pool_id) when is_map(sample) do
    pools = Map.get(sample, :llm_pools) || Map.get(sample, "llm_pools")

    with true <- is_map(pools),
         entry when is_map(entry) <- Map.get(pools, pool_id) do
      entry
    else
      _ -> nil
    end
  end

  defp pool_entry(_sample, _pool_id), do: nil

  defp normalize_pool_label(label) when is_binary(label) and label != "", do: label
  defp normalize_pool_label(_label), do: nil

  defp normalize_pool_models([_ | _] = models) do
    if Enum.all?(models, &is_binary/1), do: models, else: []
  end

  defp normalize_pool_models(_models), do: []

  # Per-sample defensive extraction of one metric for one provider-profile pool.
  # The `Map.get` chain never raises: a sample without `:llm_slots`, a slots
  # map without the pool id, or a pool map without the inner key all yield 0
  # for that sample, keeping sparklines continuous across rollout gaps.
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

  # Option/label lookup for the in-card pool control: the formatted label from
  # `llm_pool_options/1` when the option list has the pool id, else the raw
  # pool id (legacy sampler without `llm_pools`, or a stale option list).
  defp pool_label(pool_options, pool_id) when is_list(pool_options) do
    case Enum.find(pool_options, &match?(%{id: ^pool_id}, &1)) do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> pool_id
    end
  end

  defp pool_label(_pool_options, pool_id), do: pool_id

  # ── Components ───────────────────────────────────────────────────

  attr(:samples, :list, default: [])
  attr(:paused, :boolean, default: false)
  attr(:selected_llm_model, :string, default: nil)

  @doc """
  The full charts section: header row + grid of the three chart cards.

  The LLM Slots card plots ONE provider-profile POOL (one `[[llm.providers]]`
  account — its models share the pool). The resolved pool follows the SAME
  deterministic rule as the LiveView-side `resolve_selected_llm_model/2`: keep
  `selected_llm_model` when it is present in the samples' pool ids, otherwise
  fall back to the first id (`nil` when no ids are known yet — the series
  renders all-zero). Pool ids, the resolved selection and the display options
  (`llm_pool_options/1`) are threaded into the card as `model_ids` /
  `selected_model` / `pool_options` for the in-card selector.
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
        llm_selected: llm_selected,
        llm_pool_options: llm_pool_options(assigns.samples)
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
            # zh_CN: 该卡片描述所选「供应商配置档案」（[[llm.providers]] 账户）的槽位：容量=该档案当前生效并发数（峰谷暂停窗口为0），使用中=正在占用槽位的智能体，等待中=排队等待槽位的智能体；每个档案一个槽位池，同一档案下的多个模型共用这些槽位
            gettext(
              "Capacity: the selected provider profile's effective concurrency. In use: live slot holders. Waiting: agents queued for a slot. One pool per provider profile — the models of a profile share its slots."
            )
          }
          samples={@samples}
          series={@llm}
          y_max={@llm_max}
          model_ids={@llm_ids}
          selected_model={@llm_selected}
          pool_options={@llm_pool_options}
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
  attr(:pool_options, :list, default: [])

  @doc """
  One chart card: legend row with last values + a server-rendered SVG
  sparkline. Renders a gettext placeholder while no samples exist yet (static
  mount before the first tick).

  Optional in-card POOL selector (used by the LLM Slots card): when
  `model_ids` (provider-profile pool ids) is non-empty, a compact control
  renders between the description and the samples body — a static muted
  single-pool label when exactly one pool id is known, otherwise a compact
  dropdown `<select>` (DaisyUI `select-sm`) listing every pool id, the
  currently selected pool preselected, dispatching `select_llm_model` on
  change. Option TEXT is the formatted provider-profile label from
  `pool_options` (`llm_pool_options/1`), falling back to the raw pool id when
  that list lacks the id (legacy sampler without `llm_pools`); option VALUE
  stays the raw pool id, so the `%{"model" => pool_id}` wire shape is
  unchanged. Both control shapes are followed by a one-line muted note that
  slots are pooled per provider profile. When `model_ids == []` (no samples
  yet / legacy sampler without `llm_slots`) no control renders. Pool ids,
  labels and model names are user-config strings — never gettext-ed.
  """
  def chart_card(assigns) do
    ~H"""
    <div class="flex flex-col rounded-lg border border-base-300 bg-base-100 p-4">
      <div class="flex items-center gap-2 mb-1">
        <.icon name={@icon} class="size-4 text-base-content/50 shrink-0" />
        <h3 class="font-semibold text-sm">{@title}</h3>
      </div>
      <p class="text-xs text-base-content/60 mb-3">{@description}</p>

      <%= if @model_ids != [] do %>
        <div class="mb-3 space-y-1">
          <%= if length(@model_ids) == 1 do %>
            <div>
              <span class="inline-flex items-center gap-1.5 rounded-md border border-base-300 bg-base-100 px-2 py-0.5 text-xs text-base-content/60">
                <span class="size-1.5 rounded-full bg-primary/60" />
                {pool_label(@pool_options, hd(@model_ids))}
              </span>
            </div>
          <% else %>
            <%!-- Multiple provider-profile pools → a compact dropdown. The
                 select sits in a minimal form (no submit button, inert — no
                 implicit submission from a lone select): LiveView change
                 events only fire from inputs inside a form. The select itself
                 carries phx-change, so only its own field ("model") is
                 serialized — the event params land as `%{"model" => pool_id}`,
                 matching the existing `select_llm_model` handler. --%>
            <form>
              <select
                name="model"
                phx-change="select_llm_model"
                aria-label={gettext("Provider profile")}
                class="select select-sm select-bordered rounded-md w-full"
              >
                <%= for id <- @model_ids do %>
                  <option value={id} selected={id == @selected_model}>
                    {pool_label(@pool_options, id)}
                  </option>
                <% end %>
              </select>
            </form>
          <% end %>
          <p class="text-[11px] leading-snug text-base-content/70">
            {gettext(
              "Slots are pooled per provider profile — the models of one profile share its slots."
            )}
          </p>
        </div>
      <% end %>

      <%= if @samples == [] do %>
        <div class="mt-auto h-24 flex items-center justify-center text-xs text-base-content/70">
          {gettext("Collecting data…")}
        </div>
      <% else %>
        <div class="mt-auto flex flex-wrap gap-x-4 gap-y-1 mb-2">
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
