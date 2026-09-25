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
      so the fork/tip dot stays readable where the connector leaves its lane.

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

  # Full geometry for ONE edge: the resolved endpoint grid cells (`from` /
  # `to`, each `%{col, row, x, y}`) and the routed `d` string (`nil` when the
  # endpoints collapse onto each other — the renderer drops such an edge).
  def edge_geo(edge, positions) do
    kind = edge_kind(edge)
    from = endpoint(edge, :from, positions)
    to = endpoint(edge, :to, positions)
    # An agent-level connector departs BELOW its source dot.
    fy = if agent_level?(kind), do: from.y + @node_r + @exit_gap, else: from.y

    %{kind: kind, from: from, to: to, d: route(from.x, fy, to.x, to.y)}
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
  # the span so the corners can never overlap). Returns nil when the endpoints
  # collapse.
  defp route(fx, fy, tx, ty) do
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
          my = (fy + ty) / 2
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
