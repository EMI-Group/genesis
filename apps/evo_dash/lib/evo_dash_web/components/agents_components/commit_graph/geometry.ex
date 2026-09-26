defmodule EvoDashWeb.AgentsComponents.CommitGraphView.Geometry do
  @moduledoc """
  Pure grid → pixel geometry, edge ROUTING and lane planning for
  `CommitGraphView` — the TEMPORAL commit-graph renderer of the Agents page.

  This module owns every gutter geometry CONSTANT and ALL coordinate math; the
  renderer (the HEEx half, `commit_graph_view.ex`) only consumes the results.
  It is pure: no HEEx, no socket, no I/O, and every model read is TOTAL
  (`Map.get/2`, non-integer grid values folded to `0`) so malformed model data
  degrades instead of raising.

  ## Geometry constants (px; SVG user units == CSS pixels via the matched viewBox)

      @row_h       44   # fixed row height — the rows and the gutter align to this
      @col_w       24   # LANE width (one agent lane = one gutter column)
      @gutter_pad  12   # padding kept on each side of the lanes
      @node_r       6   # commit dot radius
      @base_r       4   # synthesized :base / :noop stub radius (drawn hollow)
      @bend_r       7   # rounded-corner radius of cross-lane routes
      @exit_gap     2   # clearance an agent-level connector keeps below its source dot
      @jog_clear    8   # clearance a STAGGERED jog keeps from an interior row's dot

  Lane `c`'s center sits at `x = @gutter_pad + c * @col_w + @col_w / 2`; row
  `r`'s center at `y = r * @row_h + @row_h / 2`. The gutter is
  `@gutter_pad * 2 + column_count * @col_w` wide (all coordinates integer) and
  covers `max(node_count, highest edge row + 1)` rows — a VIRTUAL
  `:merge_back` landing point (`to_sha: nil`) may sit BELOW the last node.

  ## Edge routing

  Endpoints are resolved NODE-first (a rendered node's position wins, so a dot
  and its edges can never drift), falling back to the edge's own
  `{column, row}` pair when the node is absent from the model — the NORMAL
  case for a virtual `:merge_back` landing.

    * a SAME-lane edge (`from_column == to_column`) is a plain straight
      vertical line — no bends;
    * a CROSS-lane edge is an orthogonal route (vertical → horizontal →
      vertical) whose TWO corners are rounded with quadratic (`Q`)
      quarter-turns of radius `@bend_r` — a sharp `L x y L x y` 90° corner is
      never emitted;
    * an agent-level connector (`:spawn` / `:merge_back`) departs BELOW its
      source dot (`y + @node_r + @exit_gap`) and lands on the target's center,
      so the fork/tip dot stays readable where the connector leaves its lane;
    * CONCURRENT cross-lane edges — several edges sharing the same
      UNORDERED lane pair (multiple `:spawn`s from one fork, or a `:spawn`
      overlapping its `:merge_back`) — would otherwise collapse onto the
      identical midpoint jog and read as ONE line. The batch-aware
      `edge_geo/3` STAGGERS them: the pair's first edge (in the edge list's
      stable order) keeps the canonical midpoint route; every later edge
      gets a jog y placed deterministically outward from the midpoint,
      always inside the from/to span, `@jog_clear` clear of both span ends
      and of every interior row's dot band, and `@jog_clear` from every jog
      already placed. A span too short to fit another distinct jog clamps
      back to the canonical midpoint route. The per-edge `edge_geo/2`
      always routes the canonical midpoint (a single edge between a lane
      pair is therefore pixel-identical under both).

  ## Lane planning

  `lane_chips/2` derives the per-lane header plan: ONE entry per AGENT lane
  (read from `agents[].lane`, even when that agent owns no nodes) plus the
  NEUTRAL lane 0 when no agent claims it and unowned nodes exist (the
  "pre-task" commits that predate the task's agents).
  """

  @row_h 44
  @col_w 24
  @gutter_pad 12
  @node_r 6
  @base_r 4
  @bend_r 7
  @exit_gap 2
  @jog_clear 8

  # Lane-header chip staggering: adjacent lanes are only @col_w apart while a
  # chip is wider, so chips alternate between TWO header rows (even lanes on
  # the top row, odd lanes on the bottom one) — same-row neighbours are then
  # 2 lanes (48px) apart and never collide. One header row is 18px tall.
  @chip_row_h 18

  # The agent-level edge kinds — dashed connectors between LANES (agents),
  # as opposed to the commit → parent kinds (:parent / :merge).
  @agent_kinds [:spawn, :merge_back]

  # --- constants (the renderer reads them through these accessors; module
  # attributes are NOT reachable from another module) -------------------------

  def row_h, do: @row_h
  def col_w, do: @col_w
  def gutter_pad, do: @gutter_pad
  def node_r, do: @node_r
  def base_r, do: @base_r
  def bend_r, do: @bend_r
  def chip_row_h, do: @chip_row_h

  # --- graph geometry ---------------------------------------------------------

  def geom(repo, nodes, edges, agents) do
    cols = column_count(repo, nodes, agents)

    %{
      col_count: cols,
      gutter_w: @gutter_pad * 2 + cols * @col_w,
      total_h: row_count(nodes, edges) * @row_h
    }
  end

  # Lane `col`'s dot center x / row `row`'s dot center y (integer px).
  def dot_x(col), do: @gutter_pad + col(col) * @col_w + div(@col_w, 2)
  def dot_y(row), do: max(int(row), 0) * @row_h + div(@row_h, 2)

  # `%{sha => %{col: , row: }}` for every emitted node, `row` = its INDEX in
  # the rendered top → bottom order (the model sorts by ascending `row` and the
  # rows are exactly `0..node_count-1`, so index == model row; using the index
  # keeps the gutter aligned with the DOM even for odd model data).
  def positions(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {node, index}, acc ->
      case Map.get(node, :sha) do
        nil -> acc
        sha -> Map.put_new(acc, sha, %{col: col(Map.get(node, :column)), row: index})
      end
    end)
  end

  # `column_count` — the model hint when usable, else derived from the NODES
  # and the AGENT LANES (a lane with no nodes still needs its gutter column),
  # never below `1`.
  defp column_count(repo, nodes, agents) do
    from_nodes =
      if nodes == [], do: 0, else: Enum.max(Enum.map(nodes, &col(Map.get(&1, :column)))) + 1

    lane_rows =
      agents
      |> Enum.map(&Map.get(&1, :lane))
      |> Enum.filter(&(is_integer(&1) and &1 >= 0))

    from_agents = if lane_rows == [], do: 0, else: Enum.max(lane_rows) + 1

    hint =
      case Map.get(repo, :column_count) do
        n when is_integer(n) and n > 0 -> n
        _ -> 0
      end

    max(max(from_nodes, from_agents) |> max(hint), 1)
  end

  # Rows the gutter must cover: one per node, extended for the edges' landing
  # rows (a virtual `:merge_back` landing may sit below the last node).
  defp row_count(nodes, edges) do
    edge_rows =
      Enum.flat_map(edges, fn edge ->
        [int(Map.get(edge, :from_row)), int(Map.get(edge, :to_row))]
      end)

    edge_max =
      case edge_rows do
        [] -> 0
        rows -> rows |> Enum.map(&max(&1, 0)) |> Enum.max()
      end

    max(max(length(nodes), edge_max + 1), 1)
  end

  # --- edges ------------------------------------------------------------------

  def edge_kind(edge) do
    case Map.get(edge, :kind) do
      :merge -> :merge
      :spawn -> :spawn
      :merge_back -> :merge_back
      _ -> :parent
    end
  end

  def agent_level?(kind), do: kind in @agent_kinds

  # Full geometry for ONE edge (the CANONICAL route): the resolved endpoint
  # grid cells (`from` / `to`, each `%{col, row, x, y}`) and the routed `d`
  # string (`nil` when the endpoints collapse onto each other — the renderer
  # drops such an edge). A cross-lane edge's horizontal jog sits at the
  # vertical MIDPOINT of its span.
  def edge_geo(edge, positions) do
    kind = edge_kind(edge)
    from = endpoint(edge, :from, positions)
    to = endpoint(edge, :to, positions)
    # An agent-level connector departs BELOW its source dot.
    fy = if agent_level?(kind), do: from.y + @node_r + @exit_gap, else: from.y

    %{kind: kind, from: from, to: to, d: route(from.x, fy, to.x, to.y)}
  end

  # Batch-aware variant: pass the repo's FULL edge list and concurrent
  # cross-lane edges sharing the same UNORDERED lane pair (multiple `:spawn`s
  # from one fork, or a `:spawn` overlapping its `:merge_back`) are STAGGERED
  # so the group never collapses onto identical pixels. The pair's FIRST edge
  # (in list order) keeps the canonical midpoint route — pixel-identical to
  # `edge_geo/2`; every later edge walks its jog y outward from its own
  # midpoint in `@jog_clear` steps (below the midpoint first), staying inside
  # the from/to span (`@jog_clear` clear of both ends), `@jog_clear` clear of
  # every interior row's dot and of every jog the group already placed. A
  # span with no room left clamps back to the canonical midpoint route.
  # Placement is DETERMINISTIC from the edge list's stable order. Same-lane
  # and horizontal edges are never staggered (they have no jog segment).
  def edge_geo(edge, positions, edges) when is_list(edges) do
    kind = edge_kind(edge)
    from = endpoint(edge, :from, positions)
    to = endpoint(edge, :to, positions)
    # An agent-level connector departs BELOW its source dot.
    fy = if agent_level?(kind), do: from.y + @node_r + @exit_gap, else: from.y

    jog_y =
      if from.col != to.col,
        do: staggered_jog_y(edge, positions, edges, from, to),
        else: nil

    %{kind: kind, from: from, to: to, d: route(from.x, fy, to.x, to.y, jog_y)}
  end

  def edge_geo(edge, positions, _edges), do: edge_geo(edge, positions)

  # --- jog staggering ---------------------------------------------------------

  # The staggered jog y for `edge` (nil = route the canonical midpoint):
  # `edge`'s index within its lane-pair group decides whether it is staggered
  # at all (index 0 — a lone edge between the pair — is always canonical).
  defp staggered_jog_y(edge, positions, edges, from, to) do
    pair = {min(from.col, to.col), max(from.col, to.col)}

    group =
      Enum.filter(edges, fn e ->
        if is_map(e) do
          ef = endpoint(e, :from, positions)
          et = endpoint(e, :to, positions)
          ef.col != et.col and {min(ef.col, et.col), max(ef.col, et.col)} == pair
        else
          false
        end
      end)

    case Enum.find_index(group, &(&1 == edge)) do
      idx when idx > 0 -> lane_pair_jog(edge, group, idx, positions)
      _ -> nil
    end
  end

  # The jog y for `edge` at group position `idx`: REPLAY the placement of
  # every earlier member of the lane-pair group (so each member's jog is the
  # same no matter which member asks), then place this one.
  defp lane_pair_jog(edge, group, idx, positions) do
    placed =
      group
      |> Enum.with_index()
      |> Enum.take_while(fn {_e, i} -> i < idx end)
      |> Enum.reduce([], fn {e, i}, placed ->
        {_shape, y} = member_jog(e, positions, placed, i > 0)
        [y | placed]
      end)

    case member_jog(edge, positions, placed, true) do
      {:jog, y} -> y
      {:canonical, _mid} -> nil
    end
  end

  # ONE group member's jog y within its OWN span, keeping `@jog_clear` from
  # every already-placed jog. `{:canonical, mid}` = not staggered or no room
  # left (the member routes at its own midpoint, which still counts as placed
  # for later members).
  defp member_jog(edge, positions, placed, stagger?) do
    kind = edge_kind(edge)
    from = endpoint(edge, :from, positions)
    to = endpoint(edge, :to, positions)
    fy = if agent_level?(kind), do: from.y + @node_r + @exit_gap, else: from.y
    mid = (fy + to.y) / 2

    if stagger? and from.col != to.col and fy != to.y do
      zlo = min(fy, to.y) + @jog_clear
      zhi = max(fy, to.y) - @jog_clear
      interior = interior_dot_centers(from, to)

      case jog_position(zlo, zhi, mid, interior, placed) do
        nil -> {:canonical, mid}
        y -> {:jog, y}
      end
    else
      {:canonical, mid}
    end
  end

  # The first VALID jog y walking outward from the span midpoint in
  # `@jog_clear` steps (below the midpoint first, then above): inside the
  # clamped zone, `@jog_clear` clear of every interior row's dot and of every
  # already-placed jog. nil when nothing fits (the caller routes the
  # canonical midpoint).
  defp jog_position(zlo, zhi, mid, interior, placed) do
    steps = max(ceil((zhi - mid) / @jog_clear), 1)

    Enum.find_value(1..steps, fn m ->
      offset = m * @jog_clear

      Enum.find_value([mid - offset, mid + offset], fn y ->
        if jog_fits?(y, zlo, zhi, interior, placed), do: y
      end)
    end)
  end

  defp jog_fits?(y, zlo, zhi, interior, placed) do
    y >= zlo and y <= zhi and
      Enum.all?(interior, &(abs(y - &1) >= @jog_clear)) and
      Enum.all?(placed, &(abs(y - &1) >= @jog_clear))
  end

  # Dot centers of the rows STRICTLY between the endpoints — a staggered jog
  # keeps `@jog_clear` clear of them so the horizontal segment never crosses
  # a neighbouring row's commit dot. (The endpoint rows' own dots are already
  # cleared by the zone clamp on the span ends.)
  defp interior_dot_centers(from, to) do
    lo = min(from.row, to.row)
    hi = max(from.row, to.row)

    if hi - lo < 2, do: [], else: Enum.map((lo + 1)..(hi - 1), &dot_y/1)
  end

  # An edge endpoint: prefer the NODE position, falling back to the edge's own
  # `{column, row}` when the node is absent from the model (a virtual
  # `:merge_back` landing has `to_sha: nil` and ALWAYS takes the fallback).
  defp endpoint(edge, side, positions) do
    case Map.fetch(positions, Map.get(edge, sha_field(side))) do
      {:ok, %{col: c, row: r}} ->
        %{col: c, row: r, x: dot_x(c), y: dot_y(r)}

      _ ->
        c = col(Map.get(edge, col_field(side)))
        r = max(int(Map.get(edge, row_field(side))), 0)
        %{col: c, row: r, x: dot_x(c), y: dot_y(r)}
    end
  end

  defp sha_field(:from), do: :from_sha
  defp sha_field(:to), do: :to_sha
  defp col_field(:from), do: :from_column
  defp col_field(:to), do: :to_column
  defp row_field(:from), do: :from_row
  defp row_field(:to), do: :to_row

  # A ROUNDED route between two points: same-x → a straight vertical line;
  # otherwise an orthogonal vertical → horizontal → vertical route whose two
  # corners are quadratic (`Q`) quarter-turns of radius `r` (clamped to half
  # the span so the corners can never overlap). `jog_y` overrides the
  # horizontal segment's y (the staggered case) and is ALWAYS clamped into
  # the from/to span — never closer than `r` to either endpoint, so the
  # rounded corners stay well-formed. Returns nil when the endpoints
  # collapse.
  defp route(fx, fy, tx, ty, jog_y \\ nil) do
    cond do
      fx == tx and fy == ty ->
        nil

      fx == tx ->
        "M #{n(fx)} #{n(fy)} L #{n(fx)} #{n(ty)}"

      fy == ty ->
        "M #{n(fx)} #{n(fy)} L #{n(tx)} #{n(ty)}"

      true ->
        r = @bend_r |> min(abs(tx - fx) / 2) |> min(abs(ty - fy) / 2)

        if r < 0.5 do
          "M #{n(fx)} #{n(fy)} L #{n(tx)} #{n(ty)}"
        else
          lo = min(fy, ty)
          hi = max(fy, ty)
          my = clamp_jog(jog_y, lo + r, hi - r) || (fy + ty) / 2
          sx = if tx > fx, do: 1, else: -1
          sy = if ty > fy, do: 1, else: -1

          "M #{n(fx)} #{n(fy)} " <>
            "L #{n(fx)} #{n(my - sy * r)} " <>
            "Q #{n(fx)} #{n(my)} #{n(fx + sx * r)} #{n(my)} " <>
            "L #{n(tx - sx * r)} #{n(my)} " <>
            "Q #{n(tx)} #{n(my)} #{n(tx)} #{n(my + sy * r)} " <>
            "L #{n(tx)} #{n(ty)}"
        end
    end
  end

  # Clamp a staggered jog y into `[lo, hi]` (the span ± the bend radius);
  # `nil` when the range is degenerate (no room to clamp into).
  defp clamp_jog(nil, _lo, _hi), do: nil

  defp clamp_jog(y, lo, hi) when lo <= hi, do: y |> max(lo) |> min(hi)

  defp clamp_jog(_y, _lo, _hi), do: nil

  # --- lane planning ----------------------------------------------------------

  # The per-lane header plan, ordered by lane index: one entry per AGENT lane
  # (`agent` set — even when the agent owns no nodes) plus the NEUTRAL lane 0
  # (`agent: nil`) when no agent claims lane 0 and unowned nodes exist. `x` is
  # the lane's dot center x (the chip's anchor); `chip_row` staggers chips over
  # TWO header rows (even lanes / odd lanes) so adjacent chips never collide.
  def lane_chips(nodes, agents) do
    lanes =
      Enum.reduce(agents, %{}, fn agent, acc ->
        case Map.get(agent, :lane) do
          lane when is_integer(lane) and lane >= 0 -> Map.put_new(acc, lane, agent)
          _ -> acc
        end
      end)

    neutral? = not Map.has_key?(lanes, 0) and Enum.any?(nodes, &(Map.get(&1, :owner_id) == nil))

    chips =
      if neutral? do
        [%{lane: 0, agent: nil} | agent_chip_plan(lanes)]
      else
        agent_chip_plan(lanes)
      end

    Enum.map(chips, fn chip ->
      chip
      |> Map.put(:x, dot_x(chip.lane))
      |> Map.put(:chip_row, rem(chip.lane, 2))
    end)
  end

  defp agent_chip_plan(lanes) do
    lanes
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn lane -> %{lane: lane, agent: Map.get(lanes, lane)} end)
  end

  # --- total reads ------------------------------------------------------------

  # A gutter COLUMN index — non-integer shapes fold to `0`.
  defp col(value), do: max(int(value), 0)

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: 0

  # Compact SVG number: `210.0` → `"210"`, `33.5` → `"33.5"`.
  defp n(value) when is_number(value) do
    rounded = Float.round(value * 1.0, 2)

    if rounded == Float.round(rounded) do
      Integer.to_string(trunc(rounded))
    else
      Float.to_string(rounded)
    end
  end
end
