defmodule EvoDashWeb.AgentsComponents.CommitGraphView do
  @moduledoc """
  TEMPORAL (git commit history) view for the Agents page left panel — a
  VERTICAL, GitLens/GitKraken-style PER-AGENT-LANE commit graph: ONE ROW per
  commit (globally interleaved, top → bottom), ONE LANE per agent in the left
  gutter, with rounded cross-lane edge routing, dashed spawn / merge-back
  connectors and sticky per-lane header chips.

  `commit_graph_view/1` is purely presentational: it consumes the fully
  prepared per-repo graph model (the view-model contract documented on
  `EvoDashWeb.AgentsLive.CommitGraph`) and does NO data assembly, NO I/O and
  never touches the socket. All grid → pixel mapping, edge routing and lane
  planning live in the pure `Geometry` submodule; this module owns the markup
  and the selection marking. It never raises and never uses `try/rescue`;
  every model read is TOTAL (`Map.get/2`, lists filtered to maps, grid values
  folded to `0`, non-map/odd shapes dropped).

  ## Layout

  One repository block per `repos` entry: a header (hero-server-stack icon in a
  `bg-primary` chip + the repo name) followed by the vertical commit list. The
  list sits inside ONE scroll wrapper (`#cg-scroll-<dom>`; the `.cg-scroll`
  rule in app.css owns `overflow: auto` on BOTH axes plus a bounded
  `max-height`), so WIDE lane gutters scroll as one unit with the rows and the
  lane headers, and the vertical list scrolls INSIDE the panel — the bounded
  height makes `.cg-scroll` a real VERTICAL scroller, which is what the lane
  header's `position: sticky` resolves against (before, it was inert: a set
  overflow-x computes overflow-y to `auto`, and an auto-height box never
  scrolls). There is NO pan/zoom, no viewBox mutation.

  Inside the wrapper (top → bottom):

    1. the sticky LANE-HEADER bar (`position: sticky; top: 0`), ONE chip per
       lane, anchored at its lane's x — agent lanes get a clickable `T<n>` chip
       in the agent's depth hue with a status dot (dimmed when the agent
       ended), the neutral lane 0 (present only when unowned "pre-task" nodes
       exist) a plain "Pre-task" span. It pins ABOVE the rows inside the
       `.cg-scroll` vertical scroller;
    2. the `relative` commit list: an absolutely-positioned `<svg.cg-gutter>`
       spanning the whole list height plus the `.cg-rows` container
       left-padded by the gutter width so the svg and the row content never
       overlap.

  Alignment (`Geometry`): lane `c`'s dot center sits at
  `x = 12 + c * 24 + 12`; row `r`'s at `y = r * 44 + 22`.

  ## Gutter paint

  The gutter `<svg>` holds, in DOM order (paint order), every edge then every
  node.

    * EDGES: a same-lane edge is a straight vertical line; a cross-lane edge
      routes orthogonally with BOTH corners rounded by quadratic (`Q`)
      quarter-turns (radius 7) — a sharp 90° corner is never emitted. `:parent`
      edges are solid (width 2); `:merge`, `:spawn` and `:merge_back` edges
      are DASHED (`stroke-dasharray "4 3"`, width 1.6). The agent-level
      connectors `:spawn` / `:merge_back` join LANES: a spawn departs BELOW
      its fork dot and lands on the child's oldest commit; a merge-back runs
      from the child's tip back into the parent's lane — its `to_sha` may be
      `nil` for a VIRTUAL landing point, in which case the edge's own
      `to_column`/`to_row` are the authoritative coordinates and the path
      simply ends there. Edges are stroked with the owner's depth hue
      (`agents[].color` by `edge.owner_id` — the CHILD agent for agent-level
      kinds).
    * NODES: CIRCULAR dots (`<circle class="cg-node-dot">`, radius 6) filled
      with the OWNER agent's depth hue, EXCEPT a commit that is an END commit
      for its owner (`owner_id ∈ node.end_ids`) which uses
      `EvoDashWeb.Helpers.agent_status_svg_color/1` (status colours are NEVER
      mapped locally). A `:base` / `:noop` node is drawn smaller (radius 4),
      hollow, in base ink. An agent that `ended: true` renders DIM: its own
      nodes drop to half fill opacity and its edges to a lower stroke opacity.

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
  `phx-value-id={node.owner_id}`, both omitted when `owner_id` is nil); an
  owned row is also KEYBOARD-REACHABLE (`role="button"`, `tabindex="0"` and
  Enter / Space activation via the `CommitGraph` hook — the same
  `select_agent` event, no new server event). A selected agent's START node
  wears a solid primary RING and its END node a dashed primary ring (circular,
  `r = dot r + 3`), plus a primary-tinted row accent and a `start`/`end`
  marker. A small `Selected <agent> · <start>→<end>` readout renders above the
  list while the selection is one of THIS repo's agents. The selected agent's
  id rides `data-cg-selected-id` on the `#commit-graph` root so the hook can
  scroll it into view when (and only when) the selection CHANGES.

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
    * `#cg-scroll-<repo_dom_id>` (`cg-scroll`) — the scroll wrapper (BOTH
      axes; the `.cg-scroll` rule in app.css owns `overflow: auto` + the
      bounded `max-height`) hosting lane headers + gutter + rows as ONE unit.
    * `#cg-lane-header-<repo_dom_id>` (`cg-lane-header`) — the sticky lane
      header bar; per-lane chips `#cg-lane-<repo_dom_id>-<lane_index>`
      (`cg-lane-chip`; agent lanes are `button`s with the `select_agent`
      contract, the neutral lane a `span`).
    * `#cg-list-<repo_dom_id>` — the `relative` list wrapper (carries
      `data-cg-repo-id`).
    * `svg.cg-gutter#cg-gutter-<repo_dom_id>` — the absolute gutter overlay
      (`left: 0; top: 0`, `pointer-events: none`); its `<title>`-less children
      are `path.cg-edge` then `g.cg-node`.
    * `path.cg-edge[data-commit-graph-anim="edge"]`. Commit → parent edges
      (`:parent` / `:merge`) keep the stable id
      `#commit-edge-<repo_dom_id>-<from_sha>-<to_sha>`. The agent-level kinds
      (`:spawn` / `:merge_back`) use their OWN scheme to avoid nil-sha
      collisions:
      `#commit-edge-<repo_dom_id>-<kind>-<owner_key>-<from_key>-<to_key>`
      where `to_key` is `"l<col>r<row>"` when `to_sha` is nil (a virtual
      landing).
    * `g.cg-node[data-commit-graph-anim="node"]` with the stable id
      `#commit-node-<repo_dom_id>-<sha>`, plus `data-cg-sha` / `data-cg-agent-id`
      and an inner `<title>` tooltip. The node's circle (`circle.cg-node-dot`)
      is the ONLY pointer-active part of the gutter (hover sync + its native
      tooltip); everything else stays `pointer-events: none`.
    * `div.cg-row[data-commit-graph-anim="row"]` with the stable id
      `#commit-row-<repo_dom_id>-<sha>`, plus `data-cg-sha` / `data-cg-agent-id`,
      the row `select_agent` contract, a native `title` (the same
      message · sha · author · date · refs tooltip the gutter node carries —
      the gutter `<title>` is unreachable under `pointer-events: none`) and,
      for owned rows, `role="button"` + `tabindex="0"` (Enter / Space fire
      `select_agent` via the hook).
    * agent tags `button.cg-agent-tag` with ids
      `#commit-agent-tag-<repo_dom_id>-<sha>-<start|end>-<agent_key>`; ref tags
      `span.cg-ref-tag` with ids
      `#commit-ref-tag-<repo_dom_id>-<sha>-<ref_key>`.
    * `data-commit-graph-anim` takes EXACTLY the values `"row"`, `"node"` or
      `"edge"`; the animation classes (`commit-row-enter` / `commit-node-enter` /
      `commit-edge-enter`) are added by the JS, never emitted here.

  Every element carries a stable, unique DOM id, so LiveView's patcher reuses
  existing nodes by id — no `phx-update` mode anywhere.

  ### Geometry constants (see `Geometry`)

      @row_h      44   # fixed row height (px) — the gutter aligns to this
      @col_w      24   # LANE width (px) — one agent lane = one gutter column
      @gutter_pad 12   # padding on each side of the lanes (px)
      @node_r      6   # commit dot radius (px)
      @base_r      4   # synthesized :base / :noop stub radius (px, hollow)
      @bend_r      7   # rounded-corner radius of cross-lane routes (px)
      @exit_gap    2   # clearance an agent-level connector keeps below its source dot

  Gutter width (`@gutter_pad * 2 + column_count * @col_w` = `24 + 24 * count`)
  and total height (rows × `@row_h`, extended for virtual landing rows) are
  derived from the model; the gutter `<svg>` carries a matched `viewBox`, so
  SVG user units equal CSS pixels 1:1.
  """

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.AgentsComponents.CommitGraphView.Geometry

  # zh_CN glossary used in this module:
  #   Commit history → "提交历史", Loading → "加载中",
  #   No commit history yet → "暂无提交历史", base → "基线",
  #   no-op → "空提交", Pre-task → "任务前",
  #   start → "起始", end → "结束", terminated → "已终止"

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
    <%!-- `data-cg-selected-id` carries the selection VERBATIM: LiveView
         stringifies it exactly like the rows' `data-cg-agent-id` (both are the
         raw model term), so the JS hook can string-compare them to find the
         selected agent's rows. --%>
    <div id="commit-graph" phx-hook="CommitGraph" data-cg-selected-id={@selected_id}>
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
  # commit_list/1 — the optional selection readout + the horizontal-scroll
  # wrapper hosting (top → bottom) the sticky lane-header bar and the relative
  # list (gutter svg + rows). Everything inside the wrapper scrolls as ONE
  # unit horizontally.
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp commit_list(assigns) do
    ~H"""
    <% dom = repo_dom_id(@repo) %>
    <% nodes = entry_list(@repo, :nodes) %>
    <% agents = entry_list(@repo, :agents) %>
    <% agents_index = agent_index(agents) %>
    <% positions = Geometry.positions(nodes) %>
    <% edges = entry_list(@repo, :edges) %>
    <% geom = Geometry.geom(@repo, nodes, edges, agents) %>
    <% chips = Geometry.lane_chips(nodes, agents) %>
    <% readout = selection_readout_data(agents_index, @selected_id) %>

    <%= if readout do %>
      <div
        id={"cg-selection-readout-" <> dom}
        class="flex items-center gap-1.5 text-xs text-primary font-mono py-0.5"
      >
        <.icon name="hero-cursor-arrow-rays" class="size-3.5 shrink-0" />
        <span class="truncate">{readout_text(readout)}</span>
      </div>
    <% end %>

    <%!-- `.cg-scroll` (app.css) owns BOTH scroll axes + the bounded max-height:
         gutter + rows + lane header scroll as ONE unit horizontally, and the
         list scrolls vertically INSIDE the panel — which is what makes the
         lane header's `sticky top-0` actually stick (a set overflow-x computes
         overflow-y to `auto`, so this wrapper is the nearest scroll container
         in both axes; bounding its height turns that into the real vertical
         scroller instead of an inert never-scrolling one). --%>
    <div id={"cg-scroll-" <> dom} class="cg-scroll">
      <%= if nodes == [] do %>
        <%!-- 空态：该仓库没有任何可展示的提交（例如智能体尚未在该仓库产生提交） --%>
        <p class="cg-empty-note text-xs text-base-content/60 py-3">
          {gettext("No commit history for this repository.")}
        </p>
      <% else %>
        <.lane_header :if={chips != []} dom={dom} chips={chips} header_w={geom.gutter_w} />

        <div id={"cg-list-" <> dom} class="cg-list relative" data-cg-repo-id={dom}>
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
              :for={edge <- edges}
              dom={dom}
              edge={edge}
              positions={positions}
              agents_index={agents_index}
            />
            <.node_dot
              :for={node <- nodes}
              dom={dom}
              node={node}
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
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # lane_header/1 — the sticky per-lane header bar. ONE chip per lane, anchored
  # at the lane's dot x so lane ownership is visible at a glance. Chips are
  # staggered over TWO rows (even lanes / odd lanes — neighbours on the same
  # chip row are 48px apart) so they stay readable at high lane counts; the bar
  # itself is `position: sticky; top: 0` and sized to the gutter width so it
  # scrolls in sync with the gutter inside the horizontal-scroll wrapper.
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:chips, :list, required: true)
  attr(:header_w, :integer, required: true)

  defp lane_header(assigns) do
    ~H"""
    <div
      id={"cg-lane-header-" <> @dom}
      class="cg-lane-header sticky top-0 z-10 mb-1 bg-base-100/95 backdrop-blur-sm"
      style={"width: #{@header_w}px"}
    >
      <div class="relative" style={"height: #{chip_rows(@chips) * Geometry.chip_row_h()}px"}>
        <%!-- Each stagger row is a full-width strip; its chips are absolutely
             positioned at their lane's x inside it (so the strip never affects
             their stacking order). --%>
        <div
          :for={row <- 0..(chip_rows(@chips) - 1)}
          class="absolute inset-x-0 flex items-center"
          style={"top: #{row * Geometry.chip_row_h()}px; height: #{Geometry.chip_row_h()}px"}
        >
          <.lane_chip
            :for={chip <- Enum.filter(@chips, &(&1.chip_row == row))}
            dom={@dom}
            chip={chip}
          />
        </div>
      </div>
    </div>
    """
  end

  # One lane chip, absolutely positioned at its lane's dot-x and CENTERED on it
  # via `translateX(-50%)` (the chip width is unknown at template time). The
  # neutral lane renders a plain span; an agent lane a clickable button in the
  # agent's depth hue with a status dot, dimmed when the agent ended.
  defp lane_chip(assigns) do
    ~H"""
    <%= if @chip.agent == nil do %>
      <%!-- zh_CN：中性泳道（任务开始前的“前置提交”）标签 --%>
      <span
        id={"cg-lane-" <> @dom <> "-" <> Integer.to_string(@chip.lane)}
        class="cg-lane-chip cg-lane-chip-neutral inline-flex items-center gap-1 rounded bg-base-200 px-1.5 py-0.5 text-[10px] font-mono text-base-content/70 whitespace-nowrap"
        style={"position: absolute; left: #{@chip.x}px; transform: translateX(-50%)"}
        title={gettext("Pre-task")}
      >
        {gettext("Pre-task")}
      </span>
    <% else %>
      <% agent = @chip.agent %>
      <% color = agent_color_of(agent) %>
      <button
        id={"cg-lane-" <> @dom <> "-" <> Integer.to_string(@chip.lane)}
        type="button"
        class="cg-lane-chip inline-flex items-center gap-1 rounded border px-1.5 py-0.5 text-[10px] font-mono whitespace-nowrap"
        style={"position: absolute; left: #{@chip.x}px; transform: translateX(-50%); border-color: #{color}; color: #{color}; opacity: #{if agent_ended?(agent), do: "0.5", else: "1"}"}
        title={lane_chip_title(agent)}
        phx-click="select_agent"
        phx-value-id={Map.get(agent, :agent_id)}
      >
        <span
          class="inline-block size-1.5 rounded-full shrink-0"
          style={"background-color: #{agent_status_svg_color(agent_status(agent))}"}
        ></span>
        <span>{lane_chip_label(agent)}</span>
      </button>
    <% end %>
    """
  end

  # `T<task_local_id>` (falling back to the raw agent id), matching the row tags.
  defp lane_chip_label(agent) do
    "T" <> safe_string(Map.get(agent, :task_local_id) || Map.get(agent, :agent_id) || "")
  end

  # The number of staggered chip rows the header needs (1 or 2).
  defp chip_rows(chips) do
    chips
    |> Enum.map(&Map.get(&1, :chip_row, 0))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp lane_chip_title(agent) do
    label = lane_chip_label(agent)
    status = agent_status_label(agent_status(agent))

    if agent_ended?(agent) do
      "#{label} · #{status} · #{gettext("terminated")}"
    else
      "#{label} · #{status}"
    end
  end

  # ---------------------------------------------------------------------------
  # edge_path/1 — one connector in the gutter. Commit → parent edges
  # (`:parent` solid width 2 / `:merge` dashed width 1.6) keep the
  # `<from_sha>-<to_sha>` id; the agent-level `:spawn` / `:merge_back`
  # connectors (both dashed) use their own id scheme because a merge-back's
  # `to_sha` may be nil (a VIRTUAL landing — the path simply ends at the
  # edge's own `to_column`/`to_row` coordinates). Routing lives in `Geometry`.
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:edge, :map, required: true)
  attr(:positions, :map, required: true)
  attr(:agents_index, :map, default: %{})

  defp edge_path(assigns) do
    ~H"""
    <% geo = Geometry.edge_geo(@edge, @positions) %>
    <% dashed? = geo.kind != :parent %>
    <path
      :if={geo.d}
      id={edge_id(@dom, @edge, geo)}
      class="cg-edge"
      data-commit-graph-anim="edge"
      d={geo.d}
      fill="none"
      stroke-linecap="round"
      stroke-width={if dashed?, do: "1.6", else: "2"}
      stroke-dasharray={if dashed?, do: "4 3", else: nil}
      style={"stroke: #{edge_color(@edge, @agents_index)}; stroke-opacity: #{edge_opacity(@edge, @agents_index)}"}
    />
    """
  end

  # The frozen commit→parent id, or the agent-level scheme
  # `<kind>-<owner_key>-<from_key>-<to_key>` (`to_key` = "l<col>r<row>" when
  # the landing sha is nil).
  defp edge_id(dom, edge, geo) do
    if Geometry.agent_level?(geo.kind) do
      to_key =
        case Map.get(edge, :to_sha) do
          nil -> "l#{geo.to.col}r#{geo.to.row}"
          sha -> sanitize_key(sha)
        end

      "commit-edge-" <>
        dom <>
        "-" <>
        kind_key(geo.kind) <>
        "-" <>
        sanitize_key(Map.get(edge, :owner_id)) <>
        "-" <> sanitize_key(Map.get(edge, :from_sha)) <> "-" <> to_key
    else
      "commit-edge-" <>
        dom <> "-" <> sha_key_of(edge, :from_sha) <> "-" <> sha_key_of(edge, :to_sha)
    end
  end

  defp kind_key(:spawn), do: "spawn"
  defp kind_key(:merge_back), do: "merge_back"
  defp kind_key(_kind), do: "parent"

  defp sanitize_key(id), do: id |> safe_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")

  # ---------------------------------------------------------------------------
  # node_dot/1 — one gutter commit dot: a CIRCLE for commits (radius 6, filled
  # with the owner's depth hue; an end commit takes the owner's STATUS colour),
  # smaller + hollow (radius 4, base ink) for a synthesized `:base` / `:noop`
  # stub. The click contract lives on the ROW, so the gutter stays
  # `pointer-events: none`. Selection marks a START node with a SOLID primary
  # ring and an END node with a DASHED primary ring (r = dot r + 3).
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:node, :map, required: true)
  attr(:positions, :map, required: true)
  attr(:agents_index, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp node_dot(assigns) do
    ~H"""
    <% v = dot_view(@node, @positions, @agents_index, @selected_id) %>
    <g
      id={"commit-node-" <> @dom <> "-" <> sha_key_of(@node, :sha)}
      class="cg-node"
      data-commit-graph-anim="node"
      data-cg-sha={Map.get(@node, :sha)}
      data-cg-agent-id={v.owner}
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
      <circle
        :if={v.start? or v.end?}
        class="cg-node-ring"
        cx={v.cx}
        cy={v.cy}
        r={v.ring_r}
        stroke-width="2"
        stroke-dasharray={if(v.end?, do: "3 2", else: nil)}
        style="fill: none; stroke: var(--color-primary)"
      />
    </g>
    """
  end

  defp dot_view(node, positions, agents_index, selected_id) do
    owner = Map.get(node, :owner_id)
    agent = agent_for(agents_index, owner)
    end_ids = id_list(node, :end_ids)
    start_ids = id_list(node, :start_ids)
    stub? = Map.get(node, :kind) in [:base, :noop]

    pos = Map.get(positions, Map.get(node, :sha), %{col: 0, row: 0})
    {fill, fill_opacity} = dot_paint(owner, agent, end_ids, stub?)
    r = if(stub?, do: Geometry.base_r(), else: Geometry.node_r())

    %{
      owner: owner,
      cx: n(Geometry.dot_x(pos.col)),
      cy: n(Geometry.dot_y(pos.row)),
      r: n(r),
      ring_r: n(r + 3),
      fill: fill,
      fill_opacity: fill_opacity,
      stroke: if(stub?, do: "var(--color-base-content)", else: fill),
      start?: selected_id != nil and selected_id in start_ids,
      end?: selected_id != nil and selected_id in end_ids
    }
  end

  # Stub nodes are hollow; an agent's END commit takes the shared STATUS
  # color; every other owned node takes its owner agent's depth hue; an unowned
  # node stays muted base ink. A node owned by an ENDED agent is painted at
  # half fill opacity (the hue/status color itself is unchanged).
  defp dot_paint(owner, agent, end_ids, stub?) do
    cond do
      stub? ->
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
      style={"height: #{Geometry.row_h()}px"}
      data-commit-graph-anim="row"
      data-cg-sha={Map.get(@node, :sha)}
      data-cg-agent-id={v.owner}
      title={node_title(@node)}
      role={if v.owner != nil, do: "button"}
      tabindex={if v.owner != nil, do: "0"}
      phx-click={if v.owner != nil, do: "select_agent"}
      phx-value-id={v.owner}
    >
      <div class="flex items-center gap-2 min-w-0">
        <span class="cg-row-sha font-mono text-xs text-base-content/60 shrink-0">
          {commit_short_sha(@node) || short_sha(Map.get(@node, :sha))}
        </span>
        <%= if stub_kind(@node) do %>
          <%!-- zh_CN：合成桩节点（智能体的分叉起点/虚拟落点，无提交信息/日期） --%>
          <span class="cg-base-label inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-mono bg-base-200 text-base-content/60 shrink-0">
            {stub_label(@node)}
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

  # A synthesized `:base` (fork-point) or `:noop` (no-op-child) stub renders the
  # chip instead of a message; anything else shows the message.
  defp stub_kind(node), do: Map.get(node, :kind) in [:base, :noop]

  defp stub_label(node) do
    case Map.get(node, :kind) do
      :noop -> gettext("no-op")
      _ -> gettext("base")
    end
  end

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

  # `%{agent_id => agent}` — the ONE lookup used to colour nodes, edges, tags
  # and lane chips by their owning agent. Agents without an id are skipped
  # (`owner_id` / `agent_id` are compared as the RAW model terms).
  defp agent_index(agents) do
    Enum.reduce(agents, %{}, fn agent, acc ->
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

  # Edge stroke = the owner's depth hue (for agent-level kinds the CHILD agent).
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

  # --- selection --------------------------------------------------------------

  # The readout data for the selected agent, or nil when nothing is selected /
  # the selection is not one of THIS repo's agents.
  defp selection_readout_data(agents_index, selected_id) do
    with id when not is_nil(id) <- selected_id,
         agent when is_map(agent) <- agent_for(agents_index, id) do
      %{
        label: agent_label(agents_index, id),
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
        stub_label_title(node),
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

  # zh_CN：桩节点（基线/空提交）在悬浮提示里的前缀标签
  defp stub_label_title(node) do
    case Map.get(node, :kind) do
      :base -> gettext("base")
      :noop -> gettext("no-op")
      _ -> nil
    end
  end

  # `author · date`, or "" when the node carries neither (a stub node).
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

  # The repo attr is `:map`-typed, so a plain `Map.get/2` is total here; the
  # LIST payloads inside are still read defensively (non-list → [], non-map
  # entries dropped).
  defp entry_list(container, key) do
    case Map.get(container, key) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

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

  # Compact SVG number: `210.0` → `"210"`, `33.33` → `"33.33"`. Every call site
  # feeds a value already folded through `Geometry`'s integer math.
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
