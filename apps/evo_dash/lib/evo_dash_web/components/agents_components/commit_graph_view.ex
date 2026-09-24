defmodule EvoDashWeb.AgentsComponents.CommitGraphView do
  @moduledoc """
  TEMPORAL (git commit history) view for the Agents page left panel — a
  VERTICAL, GitLen/GitKraken-style commit graph: ONE ROW per commit, ordered
  top → bottom by agent depth, with a fixed-width left GUTTER drawing the
  commit DOTS and the child → parent EDGES between the rows.

  `commit_graph_view/1` is purely presentational: it consumes the fully
  prepared per-repo graph model built by the pure
  `EvoDashWeb.AgentsLive.CommitGraph.build/2` (a vertical model carrying
  `row`/`column` per node and `{column, row}` per edge endpoint) and does NO
  data assembly, NO I/O and never touches the socket. THIS module owns the
  grid → pixel mapping (the gutter geometry constants below), the row markup
  and the selection marking. It never raises and never uses `try/rescue`;
  every model read is TOTAL (`Map.get/2`, lists filtered to maps, grid values
  folded to `0`, non-map/odd shapes dropped).

  ## Layout

  One repository block per `repos` entry: a header (hero-server-stack icon in a
  `bg-primary` chip + the repo name) followed by the vertical commit list. The
  list is a `position: relative` column; an absolutely-positioned `<svg
  class="cg-gutter">` spans the whole list height and is aligned so that:

    * commit at row `i` sits at `y = i * @row_h + @row_h / 2`;
    * gutter column `c` sits at `x = @gutter_pad + c * @col_w + @col_w / 2`.

  The rows themselves are left-padded by the gutter width
  (`@gutter_pad * 2 + column_count * @col_w`) so the svg and the row content
  never overlap. Vertical scrolling is native (the page scrolls) — there is NO
  pan/zoom.

  ## Gutter paint

  The gutter `<svg>` holds, in DOM order (paint order), every edge then every
  node. An edge is an ORTHOGONAL (right-angle) route whose corner sits at the
  vertical midpoint between the two rows, stroked with the CHILD owner's depth
  hue (`agents[].color`, looked up by `edge.owner_id`); a `:merge` edge is
  dashed. A node is a SQUARE filled with its OWNER agent's depth hue, EXCEPT a
  commit that is an END commit for its owner (`owner_id ∈ node.end_ids`) which
  uses `EvoDashWeb.Helpers.agent_status_svg_color/1` (status colours are NEVER
  mapped locally); a `:base` node is drawn smaller + hollow and an unowned node
  in muted base ink. An agent that `ended: true` (terminated / recycled but
  retained in-session) renders DIM: its own nodes drop to half fill opacity and
  its edges to a lower stroke opacity.

  ## Rows, tags and selection

  Each row shows the short sha (mono), the first-line message (truncated to one
  line), `author · date`, and — on a second line — its TAGS:

    * AGENT tags: one chip per agent that STARTS at this commit
      (`node.start_ids` — its fork point) and per agent that TIPS here
      (`node.end_ids`). Each chip is labelled `T<task_local_id>` in that agent's
      depth hue and carries a `start`/`end` marker (solid vs dashed border);
      every agent chip is clickable (`phx-click="select_agent"`).
    * REF tags: one mono chip per entry in `node.refs` (non-clickable).

  Clicking a ROW selects its owner (`phx-click="select_agent"` +
  `phx-value-id={node.owner_id}`, both omitted when `owner_id` is nil). A
  selected agent's START node wears a solid primary ring and its END node a
  dashed primary ring on the gutter dot, plus a primary-tinted row accent and a
  `start`/`end` marker. A small `Selected <agent> · <start>→<end>` readout
  renders above the list while the selection is one of THIS repo's agents.

  ## Frozen DOM contract

  Consumed by the client-side `CommitGraph` hook (enter animations) and the
  component tests — do NOT rename or drop these ids/classes/`data-*` values:

    * `#commit-graph` + `phx-hook="CommitGraph"` — rendered ONCE per page,
      persists across node switches.
    * `#commit-graph-body-<node_key>` — node-scoped wrapper (its id changes on a
      node switch, so LiveView replaces the subtree).
    * one repo wrapper `div` whose id IS `repo_dom_id` VERBATIM (the builder
      already emits a `commit-graph-repo-<slug>-<hash>` id — no prefix added
      here).
    * `#cg-selection-readout-<repo_dom_id>` — the optional selected-agent
      readout above the list.
    * `#cg-list-<repo_dom_id>` — the `relative` list wrapper (carries
      `data-cg-repo-id`).
    * `svg.cg-gutter#cg-gutter-<repo_dom_id>` — the absolute gutter overlay
      (`left: 0; top: 0`, `pointer-events: none`); its `<title>`-less children
      are `path.cg-edge` then `g.cg-node`.
    * `path.cg-edge[data-commit-graph-anim="edge"]` with the stable id
      `#commit-edge-<repo_dom_id>-<from_sha>-<to_sha>` (merge edges carry
      `stroke-dasharray`).
    * `g.cg-node[data-commit-graph-anim="node"]` with the stable id
      `#commit-node-<repo_dom_id>-<sha>`, plus `data-cg-sha` / `data-cg-agent-id`
      and an inner `<title>` tooltip.
    * `div.cg-row[data-commit-graph-anim="row"]` with the stable id
      `#commit-row-<repo_dom_id>-<sha>`, plus `data-cg-sha` / `data-cg-agent-id`
      and the row `select_agent` contract.
    * agent tags `button.cg-agent-tag` with ids
      `#commit-agent-tag-<repo_dom_id>-<sha>-<start|end>-<agent_key>`; ref tags
      `span.cg-ref-tag` with ids
      `#commit-ref-tag-<repo_dom_id>-<sha>-<ref_key>`.
    * `data-commit-graph-anim` takes EXACTLY the values `"row"`, `"node"` or
      `"edge"`; the animation classes (`commit-row-enter` / `commit-node-enter` /
      `commit-edge-enter`) are added by the JS, never emitted here.

  Every element carries a stable, unique DOM id, so LiveView's patcher reuses
  existing nodes by id — no `phx-update` mode anywhere.

  ### Geometry constants

      @row_h      44   # fixed row height (px) — the gutter aligns to this
      @col_w      16   # gutter column width (px)
      @gutter_pad 12   # padding on each side of the gutter columns (px)
      @node_r      6   # commit node half-size (px) — square side is 2x this
      @base_r      4   # synthesized base node half-size (px)

  Gutter width (`@gutter_pad * 2 + column_count * @col_w`) and total height
  (`node_count * @row_h`) are derived from the model; the gutter `<svg>` carries
  a matched `viewBox`, so SVG user units equal CSS pixels 1:1.
  """

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  # zh_CN glossary used in this module:
  #   Commit history → "提交历史", Loading → "加载中",
  #   No commit history yet → "暂无提交历史", base → "基线",
  #   start → "起始", end → "结束", terminated → "已终止"

  # --- Gutter geometry (px; SVG user units == CSS pixels via the matched viewBox) ---

  # Fixed row height — every row is EXACTLY this tall so the gutter can align.
  @row_h 44
  # Gutter column width (one depth level = one column).
  @col_w 16
  # Padding kept on each side of the gutter columns (dot radius + edge room).
  @gutter_pad 12
  # Commit node radius; a synthesized base node is smaller + hollow.
  @node_r 6
  @base_r 4

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
  # repo_section/1 — one repository block (header + its vertical commit list).
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp repo_section(assigns) do
    ~H"""
    <%!-- The wrapper id IS `repo_dom_id` verbatim: the builder already emits a
         `commit-graph-repo-<slug>-<hash>`-shaped id, so prefixing it here would
         double the prefix. --%>
    <div id={repo_dom_id(@repo)} class="space-y-1" data-cg-repo-id={repo_dom_id(@repo)}>
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
      <.commit_list repo={@repo} selected_id={@selected_id} />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # commit_list/1 — the optional selection readout + the relative list wrapper
  # (rows) with the absolute gutter overlay.
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp commit_list(assigns) do
    ~H"""
    <% dom = repo_dom_id(@repo) %>
    <% nodes = entry_list(@repo, :nodes) %>
    <% agents_index = agent_index(@repo) %>
    <% positions = positions(nodes) %>
    <% geom = geom(@repo, nodes) %>
    <% readout = selection_readout_data(@repo, @selected_id) %>

    <%= if readout do %>
      <div
        id={"cg-selection-readout-" <> dom}
        class="flex items-center gap-1.5 text-xs text-primary font-mono py-0.5"
      >
        <.icon name="hero-cursor-arrow-rays" class="size-3.5 shrink-0" />
        <span class="truncate">{readout_text(readout)}</span>
      </div>
    <% end %>

    <div id={"cg-list-" <> dom} class="cg-list relative">
      <%= if nodes == [] do %>
        <%!-- 空态：该仓库没有任何可展示的提交（例如智能体尚未在该仓库产生提交） --%>
        <p class="cg-empty-note text-xs text-base-content/60 py-3">
          {gettext("No commit history for this repository.")}
        </p>
      <% else %>
        <svg
          id={"cg-gutter-" <> dom}
          class="cg-gutter absolute left-0 top-0 pointer-events-none"
          width={geom.gutter_w}
          height={geom.total_h}
          viewBox={"0 0 #{geom.gutter_w} #{geom.total_h}"}
          role="img"
          aria-label={graph_aria_label()}
        >
          <.edge_path
            :for={edge <- entry_list(@repo, :edges)}
            dom={dom}
            edge={edge}
            geom={geom}
            positions={positions}
            agents_index={agents_index}
          />
          <.node_dot
            :for={node <- nodes}
            dom={dom}
            node={node}
            geom={geom}
            positions={positions}
            agents_index={agents_index}
            selected_id={@selected_id}
          />
        </svg>

        <div class="cg-rows" style={"padding-left: #{geom.gutter_w}px"}>
          <.commit_row
            :for={node <- nodes}
            dom={dom}
            node={node}
            agents_index={agents_index}
            selected_id={@selected_id}
          />
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # edge_path/1 — one child → parent connector. The route is ORTHOGONAL
  # (right-angle straight segments) with its corner at the vertical midpoint
  # between the two rows, so same-column edges read as straight vertical lines
  # and cross-column edges step across crisply; a `:merge` edge is DASHED so
  # merges read distinctly. The stroke is the CHILD owner's depth hue (edges
  # without an owning agent stay muted).
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:edge, :map, required: true)
  attr(:geom, :map, required: true)
  attr(:positions, :map, required: true)
  attr(:agents_index, :map, default: %{})

  defp edge_path(assigns) do
    ~H"""
    <% d = edge_d(@edge, @positions, @geom) %>
    <% merge? = edge_kind(@edge) == :merge %>
    <path
      :if={d}
      id={
        "commit-edge-" <>
          @dom <> "-" <> sha_key_of(@edge, :from_sha) <> "-" <> sha_key_of(@edge, :to_sha)
      }
      class="cg-edge"
      data-commit-graph-anim="edge"
      d={d}
      fill="none"
      stroke-linecap="round"
      stroke-width={if merge?, do: "1.6", else: "2"}
      stroke-dasharray={if merge?, do: "4 3", else: nil}
      style={"stroke: #{edge_color(@edge, @agents_index)}; stroke-opacity: #{edge_opacity(@edge, @agents_index)}"}
    />
    """
  end

  # ---------------------------------------------------------------------------
  # node_dot/1 — one gutter commit dot. The click contract lives on the ROW, so
  # the gutter stays `pointer-events: none`. Selection marks a START node with a
  # SOLID primary ring and an END node with a DASHED primary ring.
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:node, :map, required: true)
  attr(:geom, :map, required: true)
  attr(:positions, :map, required: true)
  attr(:agents_index, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp node_dot(assigns) do
    ~H"""
    <% v = dot_view(@node, @positions, @agents_index, @selected_id, @geom) %>
    <g
      id={"commit-node-" <> @dom <> "-" <> sha_key_of(@node, :sha)}
      class="cg-node"
      data-commit-graph-anim="node"
      data-cg-sha={Map.get(@node, :sha)}
      data-cg-agent-id={v.owner}
    >
      <title>{node_title(@node)}</title>
      <rect
        class="cg-node-dot"
        x={v.x}
        y={v.y}
        width={v.side}
        height={v.side}
        rx="0"
        ry="0"
        stroke-width="1.5"
        style={"fill: #{v.fill}; fill-opacity: #{v.fill_opacity}; stroke: #{v.stroke}"}
      />
      <rect
        :if={v.start? or v.end?}
        class="cg-node-ring"
        x={v.ring_x}
        y={v.ring_y}
        width={v.ring_side}
        height={v.ring_side}
        rx="0"
        ry="0"
        stroke-width="2"
        stroke-dasharray={if(v.end?, do: "3 2", else: nil)}
        style="fill: none; stroke: var(--color-primary)"
      />
    </g>
    """
  end

  # ---------------------------------------------------------------------------
  # commit_row/1 — one commit ROW: sha + message + meta on the first line, its
  # agent/ref tags on the second. The row carries the `select_agent` contract
  # (omitted entirely when the node has no owning agent).
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:node, :map, required: true)
  attr(:agents_index, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp commit_row(assigns) do
    ~H"""
    <% v = row_view(@node, @agents_index, @selected_id) %>
    <% tags? = v.start_ids != [] or v.end_ids != [] or ref_list(Map.get(@node, :refs)) != [] %>
    <div
      id={"commit-row-" <> @dom <> "-" <> sha_key_of(@node, :sha)}
      class={[
        "cg-row flex flex-col justify-center gap-0.5 px-2 rounded",
        v.owner != nil && "cursor-pointer hover:bg-base-200/60",
        v.selected? && "bg-primary/10",
        (v.start? or v.end?) && "ring-1 ring-inset ring-primary/40",
        v.ended? && "opacity-50"
      ]}
      style={"height: #{row_h()}px"}
      data-commit-graph-anim="row"
      data-cg-sha={Map.get(@node, :sha)}
      data-cg-agent-id={v.owner}
      phx-click={if v.owner != nil, do: "select_agent"}
      phx-value-id={v.owner}
    >
      <div class="flex items-center gap-2 min-w-0">
        <span class="cg-row-sha font-mono text-xs text-base-content/60 shrink-0">
          {commit_short_sha(@node) || short_sha(Map.get(@node, :sha))}
        </span>
        <%= if Map.get(@node, :kind) == :base do %>
          <%!-- zh_CN：合成基线节点（智能体的分叉起点，无提交信息/日期） --%>
          <span class="cg-base-label inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-mono bg-base-200 text-base-content/60 shrink-0">
            {gettext("base")}
          </span>
        <% else %>
          <span class="cg-row-message truncate text-sm text-base-content">
            {first_line(Map.get(@node, :message))}
          </span>
        <% end %>
        <span
          :if={v.start?}
          class="cg-row-marker shrink-0 inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-mono bg-primary/15 text-primary"
        >
          <%!-- zh_CN：选中智能体的“起始提交”行标记 --%>
          {gettext("start")}
        </span>
        <span
          :if={v.end?}
          class="cg-row-marker shrink-0 inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-mono bg-primary/15 text-primary"
        >
          <%!-- zh_CN：选中智能体的“结束提交”行标记 --%>
          {gettext("end")}
        </span>
        <span
          :if={meta_text(@node) != ""}
          class="cg-row-meta ml-auto text-xs text-base-content/50 font-mono truncate shrink-0"
        >
          {meta_text(@node)}
        </span>
      </div>

      <div :if={tags?} class="flex items-center gap-1 flex-wrap min-w-0">
        <button
          :for={id <- v.start_ids}
          :key={"start-" <> agent_key(id)}
          id={"commit-agent-tag-" <> @dom <> "-" <> sha_key_of(@node, :sha) <> "-start-" <> agent_key(id)}
          type="button"
          class="cg-agent-tag cg-agent-tag-start inline-flex items-center gap-1 rounded border border-solid px-1.5 py-0.5 text-[10px] font-mono"
          style={"border-color: #{agent_color(@agents_index, id)}; color: #{agent_color(@agents_index, id)}"}
          title={agent_tag_title(@agents_index, id, "start")}
          phx-click="select_agent"
          phx-value-id={id}
        >
          <span>{agent_label(@agents_index, id)}</span>
          <span class="opacity-70">{gettext("start")}</span>
        </button>

        <button
          :for={id <- v.end_ids}
          :key={"end-" <> agent_key(id)}
          id={"commit-agent-tag-" <> @dom <> "-" <> sha_key_of(@node, :sha) <> "-end-" <> agent_key(id)}
          type="button"
          class="cg-agent-tag cg-agent-tag-end inline-flex items-center gap-1 rounded border border-dashed px-1.5 py-0.5 text-[10px] font-mono"
          style={"border-color: #{agent_color(@agents_index, id)}; color: #{agent_color(@agents_index, id)}"}
          title={agent_tag_title(@agents_index, id, "end")}
          phx-click="select_agent"
          phx-value-id={id}
        >
          <span>{agent_label(@agents_index, id)}</span>
          <span class="opacity-70">{gettext("end")}</span>
        </button>

        <span
          :for={ref <- ref_list(Map.get(@node, :refs))}
          :key={"ref-" <> ref}
          id={"commit-ref-tag-" <> @dom <> "-" <> sha_key_of(@node, :sha) <> "-" <> ref_key(ref)}
          class="cg-ref-tag inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-mono bg-base-200 text-base-content/70"
          title={ref}
        >
          {ref}
        </span>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Geometry — grid (column, row) → pixels. SVG user units == CSS pixels.
  # ---------------------------------------------------------------------------

  defp geom(repo, nodes) do
    cols = column_count(repo, nodes)

    %{
      col_w: @col_w,
      row_h: @row_h,
      pad: @gutter_pad,
      col_count: cols,
      gutter_w: @gutter_pad * 2 + cols * @col_w,
      total_h: length(nodes) * @row_h
    }
  end

  defp dot_x(c, geom), do: geom.pad + c * geom.col_w + geom.col_w / 2
  defp dot_y(r, geom), do: r * geom.row_h + geom.row_h / 2

  # --- attribute mirrored for the template (module attributes are NOT
  # reachable from HEEx — an `@name` there reads the assign of that name) ------

  defp row_h, do: @row_h

  # `%{sha => %{col, row}}` for every emitted node, row = its INDEX in the
  # rendered top → bottom order (the model already sorts by ascending `row`, and
  # the rows are exactly `0..node_count-1`, so index == model row; using the
  # index keeps the gutter aligned with the DOM even for odd model data).
  defp positions(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {node, index}, acc ->
      case Map.get(node, :sha) do
        nil -> acc
        sha -> Map.put_new(acc, sha, %{col: col(Map.get(node, :column)), row: index})
      end
    end)
  end

  # A gutter COLUMN index — non-integer shapes fold to `0`.
  defp col(value), do: max(int(value), 0)

  # `column_count` — the model hint when usable, else derived from the nodes,
  # never below `1`. (The builder emits `max(column) + 1`.)
  defp column_count(repo, nodes) do
    from_nodes =
      if nodes == [], do: 0, else: Enum.max(Enum.map(nodes, &col(Map.get(&1, :column)))) + 1

    hint =
      case Map.get(repo, :column_count) do
        n when is_integer(n) and n > 0 -> n
        _ -> 0
      end

    max(max(from_nodes, hint), 1)
  end

  # --- edges -----------------------------------------------------------------

  # An ORTHOGONAL (right-angle) route of straight segments
  # `M fx fy L fx my L tx my L tx ty` with the corner at the vertical midpoint
  # between the two rows, or nil when the endpoints collapse onto each other.
  # The full 4-point form is used uniformly: a same-column edge (`fx == tx`)
  # renders as a straight vertical line because its horizontal segment is
  # zero-length.
  defp edge_d(edge, positions, geom) do
    {fx, fy} = endpoint(edge, :from, positions, geom)
    {tx, ty} = endpoint(edge, :to, positions, geom)

    if fx == tx and fy == ty do
      nil
    else
      my = (fy + ty) / 2
      "M #{n(fx)} #{n(fy)} L #{n(fx)} #{n(my)} L #{n(tx)} #{n(my)} L #{n(tx)} #{n(ty)}"
    end
  end

  # An edge endpoint in px: prefer the NODE position (so a dot and its edges can
  # never drift), falling back to the edge's own `{column, row}` when the node
  # is absent from the model.
  defp endpoint(edge, side, positions, geom) do
    sha = Map.get(edge, sha_field(side))

    case Map.fetch(positions, sha) do
      {:ok, %{col: c, row: r}} ->
        {dot_x(c, geom), dot_y(r, geom)}

      _ ->
        c = col(Map.get(edge, col_field(side)))
        r = max(int(Map.get(edge, row_field(side))), 0)
        {dot_x(c, geom), dot_y(r, geom)}
    end
  end

  defp sha_field(:from), do: :from_sha
  defp sha_field(:to), do: :to_sha
  defp col_field(:from), do: :from_column
  defp col_field(:to), do: :to_column
  defp row_field(:from), do: :from_row
  defp row_field(:to), do: :to_row

  defp edge_kind(edge) do
    case Map.get(edge, :kind) do
      :merge -> :merge
      _ -> :parent
    end
  end

  # Edge stroke = the CHILD owner's depth hue (looked up by `edge.owner_id`).
  defp edge_color(edge, agents_index) do
    case agent_for(agents_index, Map.get(edge, :owner_id)) do
      nil -> "var(--color-base-content)"
      agent -> agent_color_of(agent)
    end
  end

  defp edge_opacity(edge, agents_index) do
    case agent_for(agents_index, Map.get(edge, :owner_id)) do
      nil -> "0.3"
      agent -> if(agent_ended?(agent), do: "0.4", else: "0.75")
    end
  end

  # --- dots ------------------------------------------------------------------

  defp dot_view(node, positions, agents_index, selected_id, geom) do
    owner = Map.get(node, :owner_id)
    agent = agent_for(agents_index, owner)
    end_ids = id_list(node, :end_ids)
    start_ids = id_list(node, :start_ids)
    base? = Map.get(node, :kind) == :base

    pos = Map.get(positions, Map.get(node, :sha), %{col: 0, row: 0})
    {fill, fill_opacity} = dot_paint(owner, agent, end_ids, base?)
    cx = dot_x(pos.col, geom)
    cy = dot_y(pos.row, geom)
    r = if(base?, do: @base_r, else: @node_r)
    ring_r = r + 3

    %{
      owner: owner,
      x: n(cx - r),
      y: n(cy - r),
      side: n(2 * r),
      ring_x: n(cx - ring_r),
      ring_y: n(cy - ring_r),
      ring_side: n(2 * ring_r),
      fill: fill,
      fill_opacity: fill_opacity,
      stroke: if(base?, do: "var(--color-base-content)", else: fill),
      start?: selected_id != nil and selected_id in start_ids,
      end?: selected_id != nil and selected_id in end_ids
    }
  end

  # Base/fork nodes are hollow; an agent's END commit takes the shared STATUS
  # color; every other owned node takes its owner agent's depth hue; an unowned
  # node stays muted base ink. A node owned by an ENDED agent is painted at half
  # fill opacity (the hue/status color itself is unchanged).
  defp dot_paint(owner, agent, end_ids, base?) do
    cond do
      base? ->
        {"none", "1"}

      owner != nil and owner in end_ids ->
        {agent_status_svg_color(agent_status(agent)), agent_node_opacity(agent)}

      agent != nil ->
        {agent_color_of(agent), agent_node_opacity(agent)}

      true ->
        {"var(--color-base-content)", "0.55"}
    end
  end

  defp agent_node_opacity(agent), do: if(agent_ended?(agent), do: "0.5", else: "1")

  # --- rows ------------------------------------------------------------------

  defp row_view(node, agents_index, selected_id) do
    owner = Map.get(node, :owner_id)
    start_ids = id_list(node, :start_ids)
    end_ids = id_list(node, :end_ids)
    agent = agent_for(agents_index, owner)

    %{
      owner: owner,
      start_ids: start_ids,
      end_ids: end_ids,
      selected?: owner != nil and owner == selected_id,
      start?: selected_id != nil and selected_id in start_ids,
      end?: selected_id != nil and selected_id in end_ids,
      ended?: agent_ended?(agent)
    }
  end

  # --- agents index / lookups -------------------------------------------------

  # `%{agent_id => agent}` — the ONE lookup used to colour nodes, edges and tags
  # by their owning agent. Agents without an id are skipped (`owner_id` /
  # `agent_id` are compared as the RAW model terms).
  defp agent_index(repo) do
    Enum.reduce(entry_list(repo, :agents), %{}, fn agent, acc ->
      case Map.get(agent, :agent_id) do
        nil -> acc
        id -> Map.put_new(acc, id, agent)
      end
    end)
  end

  defp agent_for(index, id) when is_map(index) and not is_nil(id), do: Map.get(index, id)
  defp agent_for(_index, _id), do: nil

  defp agent_color(index, id) do
    case agent_for(index, id) do
      nil -> "var(--color-base-content)"
      agent -> agent_color_of(agent)
    end
  end

  defp agent_color_of(agent) when is_map(agent) do
    case Map.get(agent, :color) do
      color when is_binary(color) and color != "" -> color
      _ -> "var(--color-base-content)"
    end
  end

  defp agent_color_of(_agent), do: "var(--color-base-content)"

  defp agent_status(agent) when is_map(agent), do: Map.get(agent, :status)
  defp agent_status(_agent), do: nil

  # An agent is ENDED only when the model explicitly flags it (`ended: true`).
  # The key is OPTIONAL and read TOTALLY — an agent without it (or with any
  # non-`true` value) renders exactly like a live agent.
  defp agent_ended?(agent) when is_map(agent), do: Map.get(agent, :ended) == true
  defp agent_ended?(_agent), do: false

  defp agent_label(index, id) do
    case agent_for(index, id) do
      nil ->
        "T" <> safe_string(id)

      agent ->
        "T" <> safe_string(Map.get(agent, :task_local_id) || Map.get(agent, :agent_id) || id)
    end
  end

  defp agent_tag_title(index, id, kind) do
    label = agent_label(index, id)

    case agent_for(index, id) do
      nil ->
        label

      agent ->
        marker = if(kind == "end", do: gettext("end"), else: gettext("start"))
        ended = if(agent_ended?(agent), do: [gettext("terminated")], else: [])

        [label, marker, agent_status_label(agent_status(agent)) | ended]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" · ")
    end
  end

  # --- selection --------------------------------------------------------------

  # The readout data for the selected agent, or nil when nothing is selected /
  # the selection is not one of THIS repo's agents.
  defp selection_readout_data(repo, selected_id) do
    with id when not is_nil(id) <- selected_id,
         agent when is_map(agent) <- agent_for(agent_index(repo), id) do
      %{
        label: agent_label(agent_index(repo), id),
        start_sha: short_sha(Map.get(agent, :start_sha)),
        end_sha: short_sha(Map.get(agent, :end_sha))
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

  # `author · date`, or "" when the node carries neither (a base node).
  defp meta_text(node) do
    [author(node), commit_date(node)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # The SVG's accessible name.
  defp graph_aria_label do
    # zh_CN：无障碍标签 —— 整个 git 提交历史图形的朗读名称
    gettext("Git commit history graph")
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

  # `start_ids` / `end_ids` are the agent ids that fork from / tip at this node;
  # any non-list shape folds to `[]`.
  defp id_list(node, key) do
    case Map.get(node, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp repo_dom_id(repo) do
    case Map.get(repo, :repo_dom_id) do
      id when is_binary(id) -> id
      id when is_integer(id) -> Integer.to_string(id)
      id when is_atom(id) and not is_nil(id) -> Atom.to_string(id)
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
  # outside `[A-Za-z0-9_-]` folded to `-` (a raw agent id / sha may be any term).
  defp agent_key(id) do
    id |> safe_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
  end

  defp sha_key_of(container, key) do
    container |> Map.get(key) |> safe_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
  end

  # A DOM-safe fragment for a ref chip id.
  defp ref_key(ref), do: ref |> safe_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_string(value), do: inspect(value)

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: 0

  # Compact SVG number: `210.0` → `"210"`, `33.33` → `"33.33"`. Every call site
  # feeds a value already folded through `col/1`, `int/1` or arithmetic on them.
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
end
