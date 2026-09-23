defmodule EvoDashWeb.AgentsComponents.CommitGraphView do
  @moduledoc """
  TEMPORAL (git commit history) view for the Agents page left panel — an SVG
  COMMIT-CENTRIC HORIZONTAL DAG (GitKraken-style): commits are nodes on a grid
  (one COLUMN per ancestry step, time flowing LEFT → RIGHT — the repository's
  base/fork node sits one column left of the oldest commit), connected by
  child → parent edges, with one LANE ROW per agent (row order = the model's
  `{depth, id}` order) whose band spans that agent's own progress range.

  `commit_graph_view/1` is purely presentational: it consumes the fully
  prepared per-repo graph model built by the pure
  `EvoDashWeb.AgentsLive.CommitGraph.build/2` (nodes / edges / lanes carrying
  GRID coordinates `x`/`y`) and does NO data assembly, NO I/O and never touches
  the socket. THIS module owns the grid → pixel mapping and the initial
  viewport: each repo's `<svg class="cg-svg">` gets a `viewBox` equal to the
  content bounds plus `20` user units of padding, and the client hook
  (`assets/js/hooks/commit_graph.js`) pans/zooms by mutating that `viewBox`
  (never a group transform) — `fit` recomputes it from
  `.cg-viewport.getBBox()`.

  Colours: a node is filled with its OWNER lane's depth hue, or with
  `EvoDashWeb.Helpers.agent_status_svg_color/1` when `owner_id ∈ node.end_ids`
  (the owner's END commit); an edge is stroked with the child owner's depth hue
  (looked up by `edge.owner_id`) and a `:merge` edge is dashed; a lane band and
  its `T<id>` label are tinted with that lane's depth hue. Status colours are
  NEVER mapped locally — always through that shared helper.

  Every read is TOTAL (`Map.get/2`, lists filtered to maps, grid values folded
  to `0`, non-map/odd shapes dropped) so malformed data degrades to a
  smaller/empty graph instead of raising. No `try/rescue`.

  Frozen DOM markers (consumed by the client-side `CommitGraph` hook / CSS
  animation in the assets subtree): `#commit-graph` + `phx-hook="CommitGraph"`,
  `#commit-graph-body-<node_key>`, the per-repo wrapper whose id IS
  `repo_dom_id` (the assembly already emits it `commit-graph-repo-<slug>-<hash>`
  shaped — NO prefix is added here), then `.cg-graph` → the zoom buttons
  (`data-cg-action="zoom-in" | "zoom-out" | "fit"`) → `<svg class="cg-svg">`
  whose SOLE child is `<g class="cg-viewport">` holding all edges, then all
  nodes, then all lane bands (DOM order = paint order). Edges are
  `<path class="cg-edge" data-commit-graph-anim="edge">`, nodes are
  `<g class="cg-node" data-commit-graph-anim="node" data-cg-agent-id data-cg-sha>`,
  lanes are `<g class="cg-lane" data-commit-graph-anim="lane" data-cg-agent-id>`
  (with the stable anchor id `#commit-agent-row-<repo_dom_id>-<agent_id>`).
  `data-commit-graph-anim` takes EXACTLY those three values; the animation
  classes (`commit-node-enter` / `commit-lane-enter`) are added by the JS, never
  emitted here. Every element carries a stable, unique DOM id, so LiveView's
  patcher (morphdom) reuses existing nodes by id — no `phx-update` mode anywhere.
  """

  # zh_CN glossary used in this module:
  #   Commit history → "提交历史", Repository → "仓库",
  #   Loading → "加载中", No commit history yet → "暂无提交历史",
  #   Zoom in → "放大", Zoom out → "缩小", Fit to view → "适应视图"

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  # --- Grid → pixel layout constants ----------------------------------------
  # One grid COLUMN (one ancestry step) and one grid ROW (one agent lane).
  @col_w 150
  @row_h 46
  # Left gutter INSIDE the plot, reserved for the `T<id>` lane labels so a lane
  # label never covers the nodes/edges of its own row.
  @gutter 132
  # Commit node radius; an agent's END node keeps this fill and wears a ring.
  @node_r 7
  # Base (fork-point) nodes draw smaller + hollow so the oldest column reads
  # differently from real commits.
  @base_r 5
  # Lane band height, vertically centered on its lane row.
  @band_h 18
  # Padding the initial `viewBox` keeps around the content bounds (all sides).
  @vpad 20
  # Extra top strip reserved for the selection readout (only while an agent of
  # this repo is selected) so the readout never overlaps the first lane row.
  @readout_h 24
  # The intrinsic SVG box: never narrower than @min_w / taller than @max_h — a
  # taller graph is scaled down by `preserveAspectRatio` (the hook's `fit`).
  @min_w 320
  @min_h 140
  @max_h 640
  # Horizontal breathing room a lane band keeps beyond its first/last node.
  @band_pad 12

  # ---------------------------------------------------------------------------
  # commit_graph_view/1
  # ---------------------------------------------------------------------------

  attr(:repos, :list, required: true)
  attr(:selected_id, :any, default: nil)
  attr(:loading, :boolean, default: false)
  attr(:error, :any, default: nil)
  attr(:node_key, :string, default: "local")

  def commit_graph_view(assigns) do
    ~H"""
    <div id="commit-graph" phx-hook="CommitGraph">
      <%!-- Node-scoped wrapper: a node switch changes this id, so LiveView
           replaces the previous node's graph subtree entirely. --%>
      <div id={"commit-graph-body-" <> @node_key} class="space-y-4">
        <%= case view_state(@repos, @loading, @error) do %>
          <% :loading -> %>
            <.loading_state />
          <% :empty -> %>
            <.empty_state />
          <% :error -> %>
            <.error_state />
          <% :repos -> %>
            <%= if @error != nil do %>
              <.stale_warning />
            <% end %>
            <.repo_section :for={repo <- repo_list(@repos)} repo={repo} selected_id={@selected_id} />
        <% end %>
      </div>
    </div>
    """
  end

  defp view_state([], true, _error), do: :loading
  defp view_state([], false, nil), do: :empty
  defp view_state([], false, _error), do: :error
  defp view_state(_repos, _loading, _error), do: :repos

  # ---------------------------------------------------------------------------
  # States — loading / empty / error mirror the agent tree's states.
  # ---------------------------------------------------------------------------

  defp loading_state(assigns) do
    ~H"""
    <div class="text-center py-16 bg-base-200/40 rounded-xl">
      <.icon name="hero-arrow-path" class="size-20 mx-auto mb-4 text-base-content/40 animate-spin" />
      <%!-- 加载中提示：提交历史从当前节点异步拉取时的占位加载态 --%>
      <p class="text-lg text-base-content">{gettext("Loading commit history…")}</p>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="text-center py-16">
      <.icon name="hero-server" class="size-20 mx-auto mb-4 text-base-content/40 animate-float" />
      <%!-- 空态：当前节点还没有任何可展示的智能体提交记录 --%>
      <p class="text-lg text-base-content">{gettext("No commit history yet.")}</p>
      <p class="text-sm mt-2 text-base-content/60">
        {gettext("Start a task from the dashboard to see the commit graph here.")}
      </p>
    </div>
    """
  end

  defp error_state(assigns) do
    ~H"""
    <div
      id="commit-graph-error"
      class="flex items-center gap-2 rounded-lg border border-error/20 bg-error/10 px-3 py-2 text-sm text-error"
    >
      <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
      <%!-- 错误提示：拉取提交历史失败，且没有任何已缓存的数据可展示 --%>
      <span class="min-w-0">{gettext("Could not load commit history.")}</span>
    </div>
    """
  end

  defp stale_warning(assigns) do
    ~H"""
    <div
      id="commit-graph-stale-warning"
      class="flex items-center gap-2 rounded-lg border border-warning/20 bg-warning/10 px-3 py-1.5 text-xs text-warning"
    >
      <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
      <%!-- 数据可能已过期：刷新失败，展示上一次成功获取的提交图 --%>
      <span class="min-w-0">{gettext("Showing the last loaded commit graph — refresh failed.")}</span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # repo_section/1 — one repository block (header + its SVG DAG).
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp repo_section(assigns) do
    ~H"""
    <%!-- The wrapper id IS `repo_dom_id` verbatim: the builder already emits a
         `commit-graph-repo-<slug>-<hash>`-shaped id, so prefixing it here would
         double the prefix. --%>
    <div id={repo_dom_id(@repo)} class="space-y-1">
      <div class="flex items-center gap-2 mb-2 pb-1 border-b border-base-300">
        <.icon
          name="hero-server-stack"
          class="size-5 text-primary-content p-1.5 rounded-lg bg-primary"
        />
        <span
          class="font-bold text-base text-base-content truncate min-w-0"
          title={repo_name(@repo)}
        >
          {repo_name(@repo)}
        </span>
      </div>
      <.graph_block repo={@repo} selected_id={@selected_id} />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # graph_block/1 — the `.cg-graph` block: zoom toolbar + the SVG DAG.
  #
  # The `<svg class="cg-svg">` has exactly ONE child, `<g class="cg-viewport">`,
  # which holds — in DOM order (paint order) — every edge, then every node, then
  # every lane band, and finally the optional selection readout annotation.
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp graph_block(assigns) do
    ~H"""
    <% dom = repo_dom_id(@repo) %>
    <% geom = geom(@repo, @selected_id) %>
    <% lanes_index = lane_index(@repo) %>
    <% readout = selection_readout_data(@repo, @selected_id) %>
    <div class="cg-graph" data-cg-repo-id={dom}>
      <.zoom_toolbar dom={dom} />

      <svg
        id={"cg-svg-" <> dom}
        class="cg-svg"
        viewBox={view_box(@repo, @selected_id)}
        width="100%"
        height={svg_height(@repo, @selected_id)}
        preserveAspectRatio="xMinYMin meet"
        role="img"
        aria-label={graph_aria_label()}
      >
        <g id={"cg-viewport-" <> dom} class="cg-viewport">
          <.edge_path
            :for={edge <- entry_list(@repo, :edges)}
            dom={dom}
            edge={edge}
            geom={geom}
            lanes_index={lanes_index}
          />
          <.node_group
            :for={node <- entry_list(@repo, :nodes)}
            dom={dom}
            node={node}
            geom={geom}
            lanes_index={lanes_index}
            selected_id={@selected_id}
          />
          <.lane_group
            :for={lane <- entry_list(@repo, :lanes)}
            dom={dom}
            lane={lane}
            geom={geom}
            selected_id={@selected_id}
          />
          <%= if readout do %>
            <.selection_readout dom={dom} geom={geom} readout={readout} />
          <% end %>
        </g>
      </svg>

      <%= if entry_list(@repo, :nodes) == [] and entry_list(@repo, :lanes) == [] do %>
        <%!-- 空态：该仓库没有任何可展示的提交（例如智能体尚未在该仓库产生提交） --%>
        <p class="cg-empty-note text-xs text-base-content/60 py-3">
          {gettext("No commit history for this repository.")}
        </p>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # zoom_toolbar/1 — the buttons the client hook binds to (pan/zoom by mutating
  # the sibling `<svg class="cg-svg">` viewBox; `fit` recomputes it from
  # `.cg-viewport.getBBox()`). The readout span is intentionally EMPTY — the
  # hook writes the current zoom level into it.
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)

  defp zoom_toolbar(assigns) do
    ~H"""
    <div class="cg-toolbar flex items-center gap-1 mb-1">
      <button
        id={"cg-zoom-in-" <> @dom}
        type="button"
        class="cg-zoom-btn btn btn-ghost btn-xs btn-square"
        data-cg-action="zoom-in"
        title={gettext("Zoom in")}
        aria-label={gettext("Zoom in")}
      >
        <.icon name="hero-magnifying-glass-plus" class="size-3.5" />
      </button>
      <button
        id={"cg-zoom-out-" <> @dom}
        type="button"
        class="cg-zoom-btn btn btn-ghost btn-xs btn-square"
        data-cg-action="zoom-out"
        title={gettext("Zoom out")}
        aria-label={gettext("Zoom out")}
      >
        <.icon name="hero-magnifying-glass-minus" class="size-3.5" />
      </button>
      <button
        id={"cg-zoom-fit-" <> @dom}
        type="button"
        class="cg-zoom-btn btn btn-ghost btn-xs btn-square"
        data-cg-action="fit"
        title={gettext("Fit to view")}
        aria-label={gettext("Fit to view")}
      >
        <.icon name="hero-arrows-pointing-out" class="size-3.5" />
      </button>
      <span
        id={"cg-zoom-readout-" <> @dom}
        class="cg-zoom-readout text-xs text-base-content/60 font-mono"
        aria-live="polite"
      ></span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # edge_path/1 — one child → parent connector. The curve is a horizontal
  # cubic bezier (control points at the horizontal midpoint) so same-row edges
  # read as straight lines and lane crossings sweep gently; a `:merge` edge is
  # DASHED so merges read distinctly. The stroke is the CHILD owner's depth hue
  # (edges without an owning lane stay muted base ink).
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:edge, :map, required: true)
  attr(:geom, :map, required: true)
  attr(:lanes_index, :map, default: %{})

  defp edge_path(assigns) do
    ~H"""
    <%= if d = edge_d(@edge, @geom) do %>
      <% merge? = Map.get(@edge, :kind) == :merge %>
      <path
        id={
          "commit-edge-" <>
            @dom <> "-" <> sha_key(@edge, :from_sha) <> "-" <> sha_key(@edge, :to_sha)
        }
        class="cg-edge"
        data-commit-graph-anim="edge"
        d={d}
        fill="none"
        stroke-linecap="round"
        stroke-width={if merge?, do: "1.6", else: "2"}
        stroke-dasharray={if merge?, do: "4 3", else: nil}
        style={"stroke: #{edge_color(@edge, @lanes_index)}; stroke-opacity: #{edge_opacity(@edge, @lanes_index)}"}
      />
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # node_group/1 — one commit (or base/fork) node. The click contract lives on
  # the GROUP (omitted entirely when the node has no owning agent), the native
  # `<title>` carries the commit tooltip, and the circle is filled with the
  # owner lane's depth hue — or the shared STATUS color when this node is its
  # owner's END commit.
  #
  # Selection: the selected agent's START node wears a solid primary ring (+ a
  # `start` tag BELOW the node) and its END node a DASHED primary ring (+ an
  # `end` tag ABOVE the node) — both inline-styled, so they read without CSS.
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:node, :map, required: true)
  attr(:geom, :map, required: true)
  attr(:lanes_index, :map, default: %{})
  attr(:selected_id, :any, default: nil)

  defp node_group(assigns) do
    ~H"""
    <% v = node_view(@node, @lanes_index, @selected_id, @geom) %>
    <g
      id={"commit-node-" <> @dom <> "-" <> sha_key(@node, :sha)}
      class="cg-node"
      data-commit-graph-anim="node"
      data-cg-agent-id={v.owner}
      data-cg-sha={Map.get(@node, :sha)}
      phx-click={if v.owner != nil, do: "select_agent"}
      phx-value-id={v.owner}
    >
      <title>{node_title(@node)}</title>

      <circle
        class="cg-node-dot"
        cx={v.cx}
        cy={v.cy}
        r={v.r}
        stroke-width="1.5"
        style={"fill: #{v.fill}; fill-opacity: #{v.fill_opacity}; stroke: #{v.stroke}"}
      />

      <%= if Map.get(@node, :kind) == :base do %>
        <%!-- zh_CN：合成基线节点（无提交信息/日期）额外显示可见的短 SHA 标签 --%>
        <text
          id={"commit-base-label-" <> @dom <> "-" <> sha_key(@node, :sha)}
          class="cg-base-label font-mono"
          x={v.cx}
          y={v.cy + node_r() + 11}
          font-size="9"
          text-anchor="middle"
          style="fill: var(--color-primary-standalone)"
        >
          {commit_short_sha(@node) || short_sha(Map.get(@node, :sha))}
        </text>
      <% end %>

      <%= if v.start? do %>
        <circle
          class="cg-selection-start"
          cx={v.cx}
          cy={v.cy}
          r={node_r() + 3.5}
          stroke-width="2"
          style="fill: none; stroke: var(--color-primary)"
        />
        <text
          class="cg-selection-tag font-mono"
          x={v.cx}
          y={v.cy + node_r() + 13}
          font-size="9"
          text-anchor="middle"
          style="fill: var(--color-primary)"
        >
          <%!-- zh_CN：选中智能体的“起始提交”标注（图上小标签） --%>
          {gettext("start")}
        </text>
      <% end %>

      <%= if v.end? do %>
        <circle
          class="cg-selection-end"
          cx={v.cx}
          cy={v.cy}
          r={node_r() + 3.5}
          stroke-dasharray="3 2"
          stroke-width="2"
          style="fill: none; stroke: var(--color-primary)"
        />
        <text
          class="cg-selection-tag font-mono"
          x={v.cx}
          y={v.cy - node_r() - 6}
          font-size="9"
          text-anchor="middle"
          style="fill: var(--color-primary)"
        >
          <%!-- zh_CN：选中智能体的“结束提交”标注（图上小标签） --%>
          {gettext("end")}
        </text>
      <% end %>
    </g>
    """
  end

  # ---------------------------------------------------------------------------
  # lane_group/1 — one agent lane: a subtle depth-hue band spanning the lane's
  # own `x_start` → `x_end` grid range at its row, plus the `T<task_local_id>`
  # label in the left gutter. The click contract lives on the group (reusing
  # `select_agent`), and the band is `pointer-events="none"` so it never
  # swallows a click meant for a node painted under it.
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:lane, :map, required: true)
  attr(:geom, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp lane_group(assigns) do
    ~H"""
    <% agent_id = Map.get(@lane, :agent_id) %>
    <% color = lane_color(@lane) %>
    <% selected? = agent_id != nil and agent_id == @selected_id %>
    <g
      id={"commit-agent-row-" <> @dom <> "-" <> agent_key(agent_id)}
      class="cg-lane"
      data-commit-graph-anim="lane"
      data-cg-agent-id={agent_id}
      phx-click={if agent_id != nil, do: "select_agent"}
      phx-value-id={agent_id}
    >
      <title>{lane_title(@lane)}</title>

      <%= if band = lane_band(@lane, @geom) do %>
        <rect
          id={"commit-lane-" <> @dom <> "-" <> agent_key(agent_id)}
          class="cg-lane-band"
          x={band.x}
          y={band.y}
          width={band.w}
          height={band.h}
          rx="6"
          pointer-events="none"
          stroke-width="1"
          style={"fill: #{color}; fill-opacity: #{if selected?, do: "0.2", else: "0.12"}; stroke: #{if selected?, do: "var(--color-primary)", else: color}; stroke-opacity: #{if selected?, do: "0.9", else: "0.35"}"}
        />
      <% end %>

      <text
        id={"commit-lane-label-" <> @dom <> "-" <> agent_key(agent_id)}
        class="cg-lane-label font-mono"
        x={@geom.ox}
        y={py(Map.get(@lane, :y), @geom) + 4}
        font-size="11"
        style={"fill: #{color}"}
      >
        {lane_label(@lane)}
      </text>
    </g>
    """
  end

  # ---------------------------------------------------------------------------
  # selection_readout/1 — the on-graph annotation naming the selected agent
  # (`T<task_local_id>`) with its start → end short SHAs, rendered in the top
  # strip (`@readout_h`) reserved by `top_offset/2` while a selection exists.
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:geom, :map, required: true)
  attr(:readout, :map, required: true)

  defp selection_readout(assigns) do
    ~H"""
    <text
      id={"cg-selection-readout-" <> @dom}
      class="cg-selection-readout font-mono"
      x={@geom.ox}
      y={@geom.top - 9}
      font-size="11"
      style="fill: var(--color-primary)"
    >
      {readout_text(@readout)}
    </text>
    """
  end

  # ---------------------------------------------------------------------------
  # Geometry — grid (x = ancestry column, y = lane row) → pixels. The initial
  # `viewBox` is the content bounds grown by `@vpad` on every side.
  # ---------------------------------------------------------------------------

  defp geom(repo, selected_id) do
    {min_x, _max_x} = grid_bounds(repo)

    %{
      ox: @vpad,
      oy: @vpad,
      gutter: @gutter,
      col_w: @col_w,
      row_h: @row_h,
      min_x: min_x,
      top: top_offset(repo, selected_id)
    }
  end

  defp top_offset(repo, selected_id) do
    if selection_readout_data(repo, selected_id), do: @readout_h, else: 0
  end

  # The grid is drawn MIN-OFFSET aware: the leftmost grid column of the actual
  # content (`min_x`) maps to the plot origin, so the SYNTHESIZED BASE node —
  # which the model places at `x = min_real_rank - 1`, i.e. one column LEFT of
  # the oldest real commit — is rendered as its own leftmost column instead of
  # collapsing onto column `0` (which would overlap it with the commit at
  # `x = 0` and drop its edge as zero-length). Never clamp a per-coordinate `x`.
  defp px(x, geom), do: geom.ox + geom.gutter + (column(x) - geom.min_x) * geom.col_w

  defp py(y, geom), do: geom.oy + geom.top + row(y) * geom.row_h + geom.row_h / 2

  # Grid `x` folds to `0` for any non-integer shape and keeps its sign — the
  # base column is legitimately negative. `y` (a lane row) is always ≥ 0.
  defp column(x), do: int(x)
  defp row(y), do: max(int(y), 0)

  defp content_size(repo, selected_id) do
    geom = geom(repo, selected_id)
    cols = grid_columns(repo)
    rows = grid_rows(repo)
    w = max(@min_w, geom.ox * 2 + geom.gutter + cols * geom.col_w + @node_r)
    h = geom.oy * 2 + geom.top + rows * geom.row_h
    {w, h}
  end

  defp view_box(repo, selected_id) do
    {w, h} = content_size(repo, selected_id)
    "0 0 #{n(w)} #{n(h)}"
  end

  defp svg_height(repo, selected_id) do
    {_w, h} = content_size(repo, selected_id)
    h |> max(@min_h) |> min(@max_h)
  end

  # The grid's horizontal bounds `{min_x, max_x}` derived from the ACTUAL
  # content — node columns, edge endpoints and lane `x_start`/`x_end` ranges.
  # The model's `:max_x` is only a WIDTH HINT and is deliberately ignored, so a
  # stale hint can never shift or clip the graph. Missing/non-integer values are
  # skipped; an empty repo folds to `{0, 0}`.
  defp grid_bounds(repo) do
    xs =
      node_grid_xs(repo) ++
        edge_grid_xs(repo) ++
        lane_grid_xs(repo)

    case xs do
      [] -> {0, 0}
      xs -> {Enum.min(xs), Enum.max(xs)}
    end
  end

  defp node_grid_xs(repo) do
    repo
    |> entry_list(:nodes)
    |> Enum.map(&grid_x(Map.get(&1, :x)))
    |> Enum.reject(&is_nil/1)
  end

  defp edge_grid_xs(repo) do
    repo
    |> entry_list(:edges)
    |> Enum.flat_map(fn edge ->
      [grid_x(point_x(Map.get(edge, :from))), grid_x(point_x(Map.get(edge, :to)))]
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp lane_grid_xs(repo) do
    repo
    |> entry_list(:lanes)
    |> Enum.flat_map(fn lane ->
      [grid_x(Map.get(lane, :x_start)), grid_x(Map.get(lane, :x_end))]
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp point_x({x, _y}) when is_integer(x), do: x
  defp point_x(_point), do: nil

  # An integer grid coordinate, or nil (a non-integer shape is skipped rather
  # than folded to `0`, which would widen the bounds with a phantom column).
  defp grid_x(value) when is_integer(value), do: value
  defp grid_x(_value), do: nil

  # The grid's COLUMN COUNT — `(max_x - min_x + 1)`, i.e. the full span
  # INCLUDING the leftmost (base) column, at least 1.
  defp grid_columns(repo) do
    {min_x, max_x} = grid_bounds(repo)
    max(max_x - min_x + 1, 1)
  end

  # The lane ROW COUNT (highest zero-based row index + 1), at least 1.
  defp grid_rows(repo) do
    from_lanes = Enum.map(entry_list(repo, :lanes), &row(Map.get(&1, :y)))
    from_nodes = Enum.map(entry_list(repo, :nodes), &row(Map.get(&1, :y)))

    hint =
      case Map.get(repo, :row_count) do
        n when is_integer(n) and n > 0 -> [n - 1]
        _ -> []
      end

    Enum.max(from_lanes ++ from_nodes ++ hint ++ [0]) + 1
  end

  # --- edges -----------------------------------------------------------------

  defp edge_d(edge, geom) do
    with {fx, fy} when is_number(fx) <- point(Map.get(edge, :from), geom),
         {tx, ty} when is_number(tx) <- point(Map.get(edge, :to), geom) do
      if fx == tx and fy == ty do
        nil
      else
        cx = (fx + tx) / 2
        "M #{n(fx)} #{n(fy)} C #{n(cx)} #{n(fy)}, #{n(cx)} #{n(ty)}, #{n(tx)} #{n(ty)}"
      end
    else
      _ -> nil
    end
  end

  defp point({x, y}, geom), do: {px(x, geom), py(y, geom)}
  defp point(_point, _geom), do: nil

  defp edge_color(edge, lanes_index) do
    case lane_for(lanes_index, Map.get(edge, :owner_id)) do
      nil -> "var(--color-base-content)"
      lane -> lane_color(lane)
    end
  end

  defp edge_opacity(edge, lanes_index) do
    if lane_for(lanes_index, Map.get(edge, :owner_id)) != nil, do: "0.75", else: "0.3"
  end

  # --- nodes -----------------------------------------------------------------

  defp node_view(node, lanes_index, selected_id, geom) do
    owner = Map.get(node, :owner_id)
    lane = lane_for(lanes_index, owner)
    base? = Map.get(node, :kind) == :base
    end_ids = id_list(node, :end_ids)
    start_ids = id_list(node, :start_ids)
    {fill, fill_opacity} = node_paint(owner, lane, end_ids, base?)

    %{
      owner: owner,
      cx: px(Map.get(node, :x), geom),
      cy: py(Map.get(node, :y), geom),
      r: if(base?, do: @base_r, else: @node_r),
      fill: fill,
      fill_opacity: fill_opacity,
      stroke: if(base?, do: "var(--color-base-content)", else: fill),
      start?: selected_id != nil and selected_id in start_ids,
      end?: selected_id != nil and selected_id in end_ids
    }
  end

  # Base/fork nodes are hollow; an agent's END commit takes the shared STATUS
  # color; every other owned node takes its owner lane's depth hue; an
  # unowned node stays muted base ink.
  defp node_paint(owner, lane, end_ids, base?) do
    cond do
      base? -> {"none", "1"}
      owner != nil and owner in end_ids -> {agent_status_svg_color(lane_status(lane)), "1"}
      lane != nil -> {lane_color(lane), "1"}
      true -> {"var(--color-base-content)", "0.55"}
    end
  end

  # --- lanes -----------------------------------------------------------------

  # A lane band spans its `x_start` → `x_end` grid range plus `@band_pad` on
  # each side (so the band's ends clear the first/last node circles). Reversed
  # bounds are tolerated (sorted); missing/non-integer bounds drop the band and
  # leave the lane label + tooltip (the lane group still selects on click).
  defp lane_band(lane, geom) do
    with xs when is_integer(xs) <- Map.get(lane, :x_start),
         xe when is_integer(xe) <- Map.get(lane, :x_end) do
      lo = min(column(xs), column(xe))
      hi = max(column(xs), column(xe))
      y = py(Map.get(lane, :y), geom)

      %{
        x: n(px(lo, geom) - @band_pad),
        y: n(y - @band_h / 2),
        w: n((hi - lo) * geom.col_w + @band_pad * 2),
        h: n(@band_h)
      }
    else
      _ -> nil
    end
  end

  # --- selection --------------------------------------------------------------

  # The on-graph readout for the selected agent, or nil when nothing is
  # selected / the selection is not one of THIS repo's lanes.
  defp selection_readout_data(repo, selected_id) do
    with id when not is_nil(id) <- selected_id,
         lane when is_map(lane) <- lane_for(lane_index(repo), id) do
      %{
        label: lane_label(lane),
        start_sha: short_sha(Map.get(lane, :start_sha)),
        end_sha: short_sha(Map.get(lane, :end_sha))
      }
    else
      _ -> nil
    end
  end

  defp readout_text(readout) do
    range =
      [readout.start_sha, readout.end_sha]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" → ")

    if range == "" do
      # zh_CN：图中选中智能体的标注读数（起止提交未知时只显示智能体名）
      gettext("Selected %{agent}", agent: readout.label)
    else
      # zh_CN：图中选中智能体的标注读数 —— "Selected T7 · a1b2c3d4 → e5f6a7b8"
      gettext("Selected %{agent} · %{range}", agent: readout.label, range: range)
    end
  end

  # --- lane index / lookups ---------------------------------------------------

  # `%{agent_id => lane}` — the ONE lookup used to colour nodes, edges and
  # selection markers by their owning lane. Lanes without an id are skipped
  # (`owner_id`/`agent_id` are compared as the RAW model terms).
  defp lane_index(repo) do
    Enum.reduce(entry_list(repo, :lanes), %{}, fn lane, acc ->
      case Map.get(lane, :agent_id) do
        nil -> acc
        id -> Map.put_new(acc, id, lane)
      end
    end)
  end

  defp lane_for(index, id) when is_map(index) and not is_nil(id), do: Map.get(index, id)
  defp lane_for(_index, _id), do: nil

  defp lane_color(lane) do
    case Map.get(lane, :color) do
      color when is_binary(color) and color != "" -> color
      _ -> "var(--color-base-content)"
    end
  end

  defp lane_status(lane) when is_map(lane), do: Map.get(lane, :status)
  defp lane_status(_lane), do: nil

  defp lane_label(lane) do
    "T" <> safe_string(Map.get(lane, :task_local_id) || Map.get(lane, :agent_id))
  end

  # ---------------------------------------------------------------------------
  # Tooltips
  # ---------------------------------------------------------------------------

  defp node_title(node) do
    parts =
      [
        base_label(node),
        first_line(Map.get(node, :message)),
        commit_short_sha(node) || short_sha(Map.get(node, :sha)),
        author(node),
        commit_date(node)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    case ref_list(Map.get(node, :refs)) do
      [] -> Enum.join(parts, " · ")
      refs -> Enum.join(parts ++ [Enum.join(refs, ", ")], " · ")
    end
  end

  # zh_CN：基线节点（智能体的分叉起点）在悬浮提示里的前缀标签
  defp base_label(node) do
    if Map.get(node, :kind) == :base, do: gettext("base"), else: nil
  end

  defp lane_title(lane) do
    [lane_label(lane), agent_status_label(lane_status(lane))]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # ---------------------------------------------------------------------------
  # Total reads — odd shapes degrade instead of raising.
  # ---------------------------------------------------------------------------

  defp repo_list(repos) when is_list(repos), do: Enum.filter(repos, &is_map/1)
  defp repo_list(_repos), do: []

  defp entry_list(container, key) when is_map(container) do
    case Map.get(container, key) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  defp entry_list(_container, _key), do: []

  # `end_ids` / `start_ids` are the agent ids for which this node is the END /
  # START commit; any non-list shape folds to `[]`.
  defp id_list(%{} = node, key) do
    case Map.get(node, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp repo_dom_id(repo) do
    case Map.get(repo, :repo_dom_id) do
      id when is_binary(id) -> id
      id when is_atom(id) and not is_nil(id) -> Atom.to_string(id)
      id when is_integer(id) -> Integer.to_string(id)
      _ -> ""
    end
  end

  defp repo_name(repo) do
    case Map.get(repo, :repo_name) do
      name when is_binary(name) -> name
      _ -> ""
    end
  end

  # A DOM-safe fragment for an element id: the term stringified, then anything
  # outside `[A-Za-z0-9_-]` folded to `-` (a raw agent id may be any term).
  defp agent_key(id) do
    id |> safe_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
  end

  defp sha_key(container, key) do
    container |> Map.get(key) |> safe_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
  end

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_string(value), do: inspect(value)

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: 0

  # Compact SVG number: `210.0` → `"210"`, `33.33` → `"33.33"`. Every call site
  # feeds a value already folded through `column/1`, `row/1` or arithmetic on
  # them, so only numbers reach this.
  defp n(value) when is_number(value) do
    rounded = Float.round(value * 1.0, 2)

    if rounded == Float.round(rounded) do
      Integer.to_string(trunc(rounded))
    else
      Float.to_string(rounded)
    end
  end

  defp short_sha(sha) do
    case sha do
      sha when is_binary(sha) and sha != "" -> String.slice(sha, 0, 8)
      _ -> nil
    end
  end

  defp commit_short_sha(commit) do
    case Map.get(commit, :short_sha) do
      sha when is_binary(sha) and sha != "" -> sha
      _ -> nil
    end
  end

  defp author(commit) do
    case Map.get(commit, :author_name) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp commit_date(commit) do
    case Map.get(commit, :date) do
      date when is_binary(date) -> format_datetime(date)
      %DateTime{} = date -> format_datetime(date)
      %NaiveDateTime{} = date -> format_datetime(date)
      _ -> nil
    end
  end

  defp first_line(message) when is_binary(message) do
    message |> String.split("\n", parts: 2) |> hd()
  end

  defp first_line(_message), do: ""

  defp ref_list(refs) when is_list(refs), do: refs |> Enum.flat_map(&ref_name/1) |> Enum.uniq()
  defp ref_list(_refs), do: []

  defp ref_name(ref) when is_binary(ref) and ref != "", do: [ref]

  defp ref_name(%{} = ref) do
    case Map.get(ref, :name) || Map.get(ref, "name") do
      name when is_binary(name) and name != "" -> [name]
      _ -> []
    end
  end

  defp ref_name(ref) when is_atom(ref) and not is_nil(ref), do: [Atom.to_string(ref)]
  defp ref_name(_ref), do: []

  # --- attributes mirrored for the template (module attributes are NOT
  # reachable from HEEx — an `@name` there reads the assign of that name) -----

  defp node_r, do: @node_r

  # The SVG's accessible name (kept next to its meaning anchor).
  defp graph_aria_label do
    # zh_CN：无障碍标签 —— 整个 git 提交历史 SVG 图形的朗读名称
    gettext("Git commit history graph")
  end
end
