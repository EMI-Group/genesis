defmodule EvoDashWeb.AgentsComponents.CommitGraphView do
  @moduledoc """
  TEMPORAL (git commit history) view for the Agents page left panel — a
  CLASSIC git graph (`git log --graph` style) rendered as SVG.

  `commit_graph_view/1` draws the fully-prepared view models built by the pure
  `EvoDashWeb.AgentsLive.CommitGraph` module: commits are DOTS arranged on
  lanes and connected by bezier edges; refs render as small mono chips in the
  right gutter; agent activity overlays the graph — each agent's progress path
  is tinted with its depth hue (dot fill + edge stroke) and its tip commit
  wears a status-colored RING plus a tiny `T<id>` marker. Clicking a dot that
  maps to an agent (or any ring) fires the EXISTING `select_agent` event.

  The component is purely presentational — no data assembly, no I/O, never
  touches the socket. ALL geometry (dot/edge positions, lane math, edge paths)
  is owned by the assembly module; its public `dot_r/0` / `ring_r/0` are the
  single source of truth for the two radii, and this renderer only DRAWS the
  prepared `x`/`y`/`d` values.

  The frozen DOM markers (`#commit-graph` + `phx-hook="CommitGraph"`,
  `#commit-graph-body-<node_key>`, `#commit-graph-repo-<repo_dom_id>`,
  `#commit-dot-<repo_dom_id>-<sha>` and `#commit-ring-<repo_dom_id>-<agent_id>`
  both with `data-commit-graph-anim="node"`, and the edge
  `#commit-edge-<repo_dom_id>-<child>-<parent>` ids with
  `data-commit-graph-anim="edge"`) are the contract consumed by the
  client-side `CommitGraph` hook / CSS animation, which live in the assets
  subtree. Every element carries a stable, unique DOM id, so LiveView's
  patcher (morphdom) reuses existing nodes by id and inserts only genuinely
  new ones — incremental patching without any `phx-update` mode.
  """

  # zh_CN glossary used in this module:
  #   Commit history → "提交历史", Repository → "仓库",
  #   Loading → "加载中", No commit history yet → "暂无提交历史"

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.AgentsLive.CommitGraph

  # Estimated width of one mono glyph at font-size 8, plus the inner padding
  # of a ref-chip background rect. Close enough for the mono face.
  @ref_char_w 4.6
  @ref_chip_pad 8.0
  # Horizontal gap between stacked ref chips / before an agent tip marker.
  @ref_chip_gap 3.0
  # Full height of a ref-chip background rect (font-size 8 + breathing room).
  @ref_chip_h 12.0
  # Left edge of the right gutter (the assembly reserves a 150px gutter right
  # of the lane area; the chips keep a small inner margin from the lane edge).
  @gutter_margin 146

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
            <.repo_section :for={repo <- @repos} repo={repo} selected_id={@selected_id} />
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
  # repo_section/1 — one repository block (header + its SVG graph).
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp repo_section(assigns) do
    ~H"""
    <div id={"commit-graph-repo-" <> @repo.repo_dom_id} class="space-y-1">
      <div class="flex items-center gap-2 mb-2 pb-1 border-b border-base-300">
        <.icon
          name="hero-server-stack"
          class="size-5 text-primary-content p-1.5 rounded-lg bg-primary"
        />
        <span class="font-bold text-base text-base-content truncate min-w-0" title={@repo.repo_name}>
          {@repo.repo_name}
        </span>
      </div>
      <.commit_graph_svg repo={@repo} selected_id={@selected_id} />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # commit_graph_svg/1 — the classic git graph: edges, dots, rings.
  #
  # Draw order (bottom → top): edges, commit dots (each with its ref chips +
  # agent tip marker), then the agent rings on top of the dots they encircle.
  # The SVG scales to the wrapper width but never below its natural (viewBox)
  # width, so a narrow panel scrolls the wrapper horizontally instead of
  # squashing the lanes; tall graphs are bounded by the wrapper's max-height
  # and scroll vertically inside it.
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp commit_graph_svg(assigns) do
    ~H"""
    <% show_refs = repo_has_refs?(@repo) %>
    <div class="overflow-auto max-h-[32rem]">
      <svg
        viewBox={"0 0 #{fmt(dim(@repo, :width))} #{fmt(dim(@repo, :height))}"}
        width="100%"
        preserveAspectRatio="xMinYMin meet"
        role="img"
        aria-label={graph_aria_label()}
        style={"min-width: #{fmt(dim(@repo, :width))}px"}
        class="block select-none"
      >
        <.graph_edge :for={edge <- edges(@repo)} edge={edge} />
        <.commit_dot
          :for={commit <- commits(@repo)}
          repo={@repo}
          commit={commit}
          selected_id={@selected_id}
          show_refs={show_refs}
        />
        <.agent_ring :for={ring <- rings(@repo)} repo={@repo} ring={ring} selected_id={@selected_id} />
      </svg>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # graph_edge/1 — one child→parent connector. Uncolored edges use the muted
  # base ink at low opacity; agent-covered edges carry the agent's depth hue
  # at full opacity and a slightly heavier stroke.
  # ---------------------------------------------------------------------------

  attr(:edge, :map, required: true)

  defp graph_edge(assigns) do
    ~H"""
    <path
      id={Map.get(@edge, :id)}
      data-commit-graph-anim="edge"
      d={Map.get(@edge, :d)}
      fill="none"
      stroke-linecap="round"
      stroke-width={if edge_color(@edge), do: 2.25, else: 1.75}
      stroke-opacity={if edge_color(@edge), do: nil, else: "0.35"}
      style={"stroke: #{edge_color(@edge) || "var(--color-base-content)"}"}
    />
    """
  end

  # ---------------------------------------------------------------------------
  # commit_dot/1 — one commit: the dot circle, its native tooltip, its
  # selection halo, and its decorations (right-gutter ref chips + the agent
  # tip marker). Only the circle is clickable (when the commit maps to an
  # agent); the id + animation marker live on the wrapping group so morphdom
  # matches the whole commit as one unit.
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:commit, :map, required: true)
  attr(:selected_id, :any, default: nil)
  attr(:show_refs, :boolean, default: false)

  defp commit_dot(assigns) do
    ~H"""
    <% refs = if @show_refs, do: commit_refs(@commit, gutter_x(@repo)), else: [] %>
    <% tip = tip_marker(@commit, refs) %>
    <g
      id={"commit-dot-" <> @repo.repo_dom_id <> "-" <> Map.get(@commit, :sha)}
      data-commit-graph-anim="node"
    >
      <title>{dot_title(@commit)}</title>

      <%= if dot_selected?(@commit, @selected_id) do %>
        <%!-- Selection halo: a faint primary ring just outside the dot. --%>
        <circle
          cx={Map.get(@commit, :x)}
          cy={Map.get(@commit, :y)}
          r={CommitGraph.ring_r() + 3.5}
          fill="none"
          stroke-width="1.5"
          stroke-opacity="0.9"
          style="stroke: var(--color-primary)"
        />
      <% end %>

      <circle
        cx={Map.get(@commit, :x)}
        cy={Map.get(@commit, :y)}
        r={CommitGraph.dot_r()}
        fill-opacity={dot_fill_opacity(@commit, @selected_id)}
        stroke-width="1.5"
        class={[
          "transition-[fill,stroke] duration-300 motion-reduce:transition-none",
          agent_id(@commit) != nil && "cursor-pointer"
        ]}
        style={dot_style(@commit, @selected_id)}
        phx-click={if agent_id(@commit) != nil, do: "select_agent"}
        phx-value-id={agent_id(@commit)}
      />

      <%= for chip <- refs do %>
        <g>
          <rect
            x={chip.x}
            y={chip.y - ref_chip_h() / 2}
            width={chip.w}
            height={ref_chip_h()}
            rx="4"
            stroke-width="1"
            style="fill: var(--color-base-200); stroke: var(--color-base-300)"
          />
          <text
            x={chip.tx}
            y={chip.y + 3}
            font-size="8"
            class="font-mono"
            style="fill: var(--color-base-content)"
          >
            {chip.name}
          </text>
        </g>
      <% end %>

      <%= if tip do %>
        <text
          x={tip.x}
          y={tip.y}
          font-size="8"
          opacity="0.7"
          class="font-mono"
          style="fill: var(--color-base-content)"
        >
          {tip.label}
        </text>
      <% end %>
    </g>
    """
  end

  # ---------------------------------------------------------------------------
  # agent_ring/1 — an agent's tip marker: a status-colored ring on the
  # agent's current commit, with a subtle same-color glow band behind it.
  # Status colors come from the shared `agent_status_svg_color/1` helper —
  # never re-implemented here.
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:ring, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp agent_ring(assigns) do
    ~H"""
    <g
      id={"commit-ring-" <> @repo.repo_dom_id <> "-" <> to_string(Map.get(@ring, :agent_id))}
      data-commit-graph-anim="node"
    >
      <title>{ring_title(@ring)}</title>

      <%!-- Subtle same-color glow band behind the ring. --%>
      <circle
        cx={Map.get(@ring, :x)}
        cy={Map.get(@ring, :y)}
        r={CommitGraph.ring_r() + 2}
        fill="none"
        stroke-width="4"
        stroke-opacity="0.15"
        style={"stroke: #{ring_color(@ring)}"}
      />

      <%= if Map.get(@ring, :agent_id) == @selected_id do %>
        <%!-- Selection halo: a faint primary ring just outside the glow. --%>
        <circle
          cx={Map.get(@ring, :x)}
          cy={Map.get(@ring, :y)}
          r={CommitGraph.ring_r() + 3.5}
          fill="none"
          stroke-width="1.5"
          stroke-opacity="0.9"
          style="stroke: var(--color-primary)"
        />
      <% end %>

      <circle
        cx={Map.get(@ring, :x)}
        cy={Map.get(@ring, :y)}
        r={CommitGraph.ring_r()}
        fill="none"
        stroke-width="2"
        class="cursor-pointer transition-[stroke] duration-300 motion-reduce:transition-none"
        style={"stroke: #{ring_color(@ring)}"}
        phx-click="select_agent"
        phx-value-id={Map.get(@ring, :agent_id)}
      />
    </g>
    """
  end

  # ---------------------------------------------------------------------------
  # Pure helpers — all TOTAL against missing / malformed data.
  # ---------------------------------------------------------------------------

  defp commits(repo) do
    case Map.get(repo, :commits) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp edges(repo) do
    case Map.get(repo, :edges) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp rings(repo) do
    case Map.get(repo, :rings) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # A repo dimension (width/height) — any non-numeric shape degrades to 0 so
  # the viewBox/style interpolations never raise.
  defp dim(repo, key) do
    case Map.get(repo, key) do
      value when is_number(value) -> value
      _ -> 0
    end
  end

  # Compact SVG number formatting: drops the trailing ".0" of whole floats
  # (`210.0` → `"210"`) while keeping fractional values intact. Mirrors the
  # assembly module's own `num/1` — the renderer's copy exists only for the
  # viewBox/min-width interpolations (the x/y/d values arrive pre-formatted
  # inside `edge.d` and raw for the circles, where the extra ".0" is harmless).
  # Only numbers reach it: `dim/2` already degrades odd shapes to `0`.
  defp fmt(value) when is_float(value) do
    s = Float.to_string(value)
    if String.ends_with?(s, ".0"), do: binary_part(s, 0, byte_size(s) - 2), else: s
  end

  defp fmt(value) when is_integer(value), do: Integer.to_string(value)

  # Full height of a ref-chip background rect — exposed as a function because
  # module attributes are NOT visible inside HEEx templates (an `@name` there
  # reads the assign of that name).
  defp ref_chip_h, do: @ref_chip_h

  defp repo_has_refs?(repo) do
    Enum.any?(commits(repo), &(ref_list(Map.get(&1, :refs)) != []))
  end

  # The left edge of the right gutter (ref chips + agent markers live here).
  defp gutter_x(repo), do: dim(repo, :width) - @gutter_margin

  # A coordinate readied for SVG arithmetic — non-numeric shapes degrade to 0
  # so the chip/tip positioning math never raises on malformed data.
  defp num(value) when is_number(value), do: value
  defp num(_value), do: 0

  # Prepared ref chips for one commit — `%{name:, x:, w:, tx:, y:}` stacked
  # left → right from the gutter's left edge with a small gap between chips.
  defp commit_refs(commit, gutter) do
    y = num(Map.get(commit, :y))

    {chips, _next_x} =
      commit
      |> Map.get(:refs)
      |> ref_list()
      |> Enum.reduce({[], gutter}, fn ref, {acc, x} ->
        w = String.length(ref) * @ref_char_w + @ref_chip_pad
        chip = %{name: ref, x: x, w: w, tx: x + @ref_chip_pad / 2, y: y}
        {[chip | acc], x + w + @ref_chip_gap}
      end)

    Enum.reverse(chips)
  end

  # The `T<id>` text marker for an agent's TIP commit, right of the dot —
  # after any ref chips on that commit, else just outside the ring.
  defp tip_marker(commit, refs) do
    case Map.get(commit, :agent) do
      agent when is_map(agent) ->
        if Map.get(agent, :tip?) == true do
          x =
            case List.last(refs) do
              nil -> num(Map.get(commit, :x)) + CommitGraph.ring_r() + 4
              chip -> chip.x + chip.w + @ref_chip_gap
            end

          %{
            label: "T" <> to_string(Map.get(agent, :task_local_id) || Map.get(agent, :id)),
            x: x,
            y: num(Map.get(commit, :y)) + 3
          }
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp agent_id(commit) do
    case Map.get(commit, :agent) do
      agent when is_map(agent) -> Map.get(agent, :id)
      _ -> nil
    end
  end

  defp dot_selected?(commit, selected_id) do
    id = agent_id(commit)
    id != nil and id == selected_id
  end

  # Uncolored dots render at reduced opacity; a highlight color or the
  # selection bumps the dot to full prominence.
  defp dot_fill_opacity(commit, selected_id) do
    cond do
      dot_selected?(commit, selected_id) -> 1.0
      highlight_color(commit) != nil -> 1.0
      true -> 0.55
    end
  end

  defp dot_style(commit, selected_id) do
    fill = highlight_color(commit) || "var(--color-base-content)"

    if dot_selected?(commit, selected_id) do
      "fill: #{fill}; stroke: var(--color-primary)"
    else
      "fill: #{fill}"
    end
  end

  defp highlight_color(commit) do
    case Map.get(commit, :highlight_color) do
      color when is_binary(color) and color != "" -> color
      _ -> nil
    end
  end

  defp edge_color(edge) do
    case Map.get(edge, :color) do
      color when is_binary(color) and color != "" -> color
      _ -> nil
    end
  end

  defp ring_color(ring), do: agent_status_svg_color(Map.get(ring, :status))

  defp dot_title(commit) do
    [
      first_line(Map.get(commit, :message)),
      short_sha(commit),
      author(commit),
      commit_date(commit)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp ring_title(ring) do
    id = Map.get(ring, :task_local_id) || Map.get(ring, :agent_id)

    ["T" <> to_string(id), agent_status_label(Map.get(ring, :status))]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp short_sha(commit) do
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

  # The SVG's accessible name (kept here so the gettext call sits next to its
  # meaning anchor).
  defp graph_aria_label do
    # zh_CN: 无障碍标签 —— 整个 git 提交历史 SVG 图形的朗读名称
    gettext("Git commit history graph")
  end
end
