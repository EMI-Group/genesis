defmodule EvoDashWeb.AgentsComponents.CommitGraphView do
  @moduledoc """
  TEMPORAL (git commit history) view for the Agents page left panel — a compact
  HORIZONTAL AGENT-SWIMLANE: one row per agent lane, time flowing LEFT → RIGHT,
  lanes stacked TOP → BOTTOM by recursion depth (the builder orders them by
  `{depth, id}`). Plain HTML/CSS (divs + flex) — no SVG.

  `commit_graph_view/1` consumes the fully-prepared view models built by the pure
  `EvoDashWeb.AgentsLive.CommitGraph` module. Each lane carries its agent (id,
  task_local_id, status, depth, and `color` = the depth hue) plus that agent's
  marker commits. A lane row is a fixed-width left gutter (status dot +
  `T<task_local_id || id>`) and a `flex-1` timeline track; everything inside the
  track is absolutely positioned by PERCENTAGE of the track width —
  `left = column / column_count * 100` — so identical tracks line up and a commit
  shared by several agents lands in the same visual column. The agent's progress
  renders as ONE horizontal bar (`from_column` → `to_column`, tinted with the
  depth hue) and each marker renders as ONE dot (depth hue, or the status color
  when it is the agent's tip — `marker.tip?`). Clicking the row (marker or lane)
  fires the EXISTING `select_agent` event — no new event.

  The component is purely presentational — no data assembly, no I/O, never
  touches the socket; ALL column math is owned by the assembly. Every read is
  TOTAL (`Map.get/2` + pattern-matched normalization), so odd shapes degrade
  instead of raising.

  Frozen DOM markers (consumed by the client-side `CommitGraph` hook / CSS
  animation in the assets subtree): `#commit-graph` + `phx-hook="CommitGraph"`,
  `#commit-graph-body-<node_key>`, the per-repo section whose id IS `repo_dom_id`
  (the assembly already emits it `commit-graph-repo-<slug>-<hash>`-shaped — no
  prefix is added here), the lane progress element
  `#commit-lane-<repo_dom_id>-<agent_id>` with `data-commit-graph-anim="lane"`,
  and one marker element per commit per lane
  `#commit-marker-<repo_dom_id>-<agent_id>-<sha>` with
  `data-commit-graph-anim="node"`. There is no `edge` marker. Every element
  carries a stable, unique DOM id, so LiveView's patcher (morphdom) reuses
  existing nodes by id and inserts only genuinely new ones — incremental
  patching without any `phx-update` mode.
  """

  # zh_CN glossary used in this module:
  #   Commit history → "提交历史", Repository → "仓库",
  #   Loading → "加载中", No commit history yet → "暂无提交历史"

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

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
  # repo_section/1 — one repository block (header + its swimlane rows).
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp repo_section(assigns) do
    ~H"""
    <% repo = as_map(@repo) %>
    <%!-- The section id IS `repo_dom_id` verbatim: the builder already emits
         a `commit-graph-repo-<slug>-<hash>`-shaped id, so prefixing it here
         would double the prefix. --%>
    <div id={Map.get(repo, :repo_dom_id)} class="space-y-1">
      <div class="flex items-center gap-2 mb-2 pb-1 border-b border-base-300">
        <.icon
          name="hero-server-stack"
          class="size-5 text-primary-content p-1.5 rounded-lg bg-primary"
        />
        <span
          class="font-bold text-base text-base-content truncate min-w-0"
          title={Map.get(repo, :repo_name)}
        >
          {Map.get(repo, :repo_name)}
        </span>
      </div>
      <.lane_list repo={repo} selected_id={@selected_id} />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # lane_list/1 — one swimlane row per agent lane, stacked top → bottom.
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp lane_list(assigns) do
    ~H"""
    <div class="space-y-0.5">
      <.lane_row :for={lane <- lanes(@repo)} repo={@repo} lane={lane} selected_id={@selected_id} />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # lane_row/1 — a fixed-width left gutter (agent label) + a `flex-1` timeline
  # track. The click binding lives on the ROW so both the lane bar and its
  # markers select the agent (their clicks bubble up to the row).
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:lane, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp lane_row(assigns) do
    ~H"""
    <% agent = lane_agent(@lane) %>
    <% agent_id = agent_id(agent) %>
    <% selected? = agent_id != nil and agent_id == @selected_id %>
    <% column_count = column_count(@repo) %>
    <div
      id={"commit-agent-row-" <> repo_dom_id(@repo) <> "-" <> to_string(agent_id)}
      phx-click="select_agent"
      phx-value-id={agent_id}
      title={row_title(agent)}
      class={[
        "flex items-center gap-2 rounded-md px-1 py-0.5 cursor-pointer transition-colors",
        "hover:bg-base-200/50",
        selected? && "bg-primary/5"
      ]}
    >
      <%!-- Left gutter: status dot + `T<task_local_id || id>`. --%>
      <div class="w-28 shrink-0 flex items-center gap-1.5 min-w-0">
        <span
          class="size-2 rounded-full shrink-0"
          style={"background-color: #{agent_status_svg_color(agent_status(agent))}"}
        />
        <span class="font-mono text-xs text-base-content/80 truncate" title={agent_label(agent)}>
          {agent_label(agent)}
        </span>
      </div>

      <%!-- Timeline track: percentage-positioned rail, lane bar and markers. --%>
      <div class="relative flex-1 h-6 min-w-0">
        <div class="absolute inset-x-0 top-1/2 -translate-y-1/2 h-px bg-base-300/50" />

        <%= if bar = lane_bar(@lane, column_count) do %>
          <% {left, width} = bar %>
          <div
            id={"commit-lane-" <> repo_dom_id(@repo) <> "-" <> to_string(agent_id)}
            data-commit-graph-anim="lane"
            class="absolute top-1/2 -translate-y-1/2 h-1 rounded-full"
            style={"left: #{left}%; width: #{width}%; background-color: #{depth_color(agent)}"}
          />
        <% end %>

        <.lane_marker
          :for={marker <- lane_markers(@lane)}
          repo={@repo}
          agent={agent}
          marker={marker}
          column_count={column_count}
          selected_id={@selected_id}
        />
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # lane_marker/1 — ONE commit marker per commit per lane. Its fill is the
  # agent's depth hue, or the shared status color on the agent's tip commit.
  # Selection is a style change on this SAME element (a primary ring on the tip
  # marker) — never a stacked extra element.
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:agent, :map, required: true)
  attr(:marker, :map, required: true)
  attr(:column_count, :integer, required: true)
  attr(:selected_id, :any, default: nil)

  defp lane_marker(assigns) do
    ~H"""
    <% tip? = Map.get(@marker, :tip?) == true %>
    <% selected? = agent_id(@agent) != nil and agent_id(@agent) == @selected_id %>
    <span
      id={"commit-marker-" <> repo_dom_id(@repo) <> "-" <> to_string(agent_id(@agent)) <> "-" <> marker_sha(@marker)}
      data-commit-graph-anim="node"
      title={marker_title(@marker)}
      class={[
        "absolute top-1/2 -translate-x-1/2 -translate-y-1/2 rounded-full",
        if(tip?, do: "size-3", else: "size-2.5"),
        tip? && selected? && "ring-2 ring-primary-standalone"
      ]}
      style={"left: #{marker_left(@marker, @column_count)}%; background-color: #{marker_color(@agent, @marker)}"}
    />
    """
  end

  # ---------------------------------------------------------------------------
  # Position math — everything is a PERCENTAGE of the (identical-width) track.
  # ---------------------------------------------------------------------------

  # The agent's progress bar spans whole columns: `from_column` → `to_column`
  # inclusive. Rendered only for a positive column count and integer bounds.
  defp lane_bar(lane, column_count) do
    with true <- is_integer(column_count) and column_count > 0,
         from when is_integer(from) <- Map.get(lane, :from_column),
         to when is_integer(to) <- Map.get(lane, :to_column) do
      left = from / column_count * 100
      width = max(to - from + 1, 1) / column_count * 100
      {pct(left), pct(width)}
    else
      _ -> nil
    end
  end

  # Markers sit at the CENTER of their column: `(column + 0.5) / count * 100`.
  defp marker_left(marker, column_count) when is_integer(column_count) and column_count > 0 do
    pct((int(Map.get(marker, :column)) + 0.5) / column_count * 100)
  end

  defp marker_left(_marker, _column_count), do: "0"

  # Compact percentage string ("50", "33.333") — trims a whole value's ".0".
  defp pct(value) when is_number(value) do
    rounded = Float.round(value * 1.0, 3)

    if rounded == Float.round(rounded) do
      Integer.to_string(trunc(rounded))
    else
      Float.to_string(rounded)
    end
  end

  # ---------------------------------------------------------------------------
  # Colour sources — the depth hue arrives from the DATA; a tip marker's fill is
  # ALWAYS the shared status color helper (`agent_status_svg_color/1` — never
  # re-implement the mapping).
  # ---------------------------------------------------------------------------

  defp marker_color(agent, marker) do
    if Map.get(marker, :tip?) == true do
      agent_status_svg_color(agent_status(agent))
    else
      depth_color(agent)
    end
  end

  defp depth_color(agent) do
    case Map.get(agent, :color) do
      color when is_binary(color) and color != "" -> color
      _ -> "var(--color-base-content)"
    end
  end

  # ---------------------------------------------------------------------------
  # Tooltips
  # ---------------------------------------------------------------------------

  defp row_title(agent) do
    [agent_label(agent), agent_status_label(agent_status(agent))]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp marker_title(marker) do
    parts =
      [
        first_line(Map.get(marker, :message)),
        short_sha(marker),
        author(marker),
        commit_date(marker)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    case ref_list(Map.get(marker, :refs)) do
      [] -> Enum.join(parts, " · ")
      refs -> Enum.join(parts ++ [Enum.join(refs, ", ")], " · ")
    end
  end

  # ---------------------------------------------------------------------------
  # Total reads — odd shapes degrade instead of raising.
  # ---------------------------------------------------------------------------

  defp as_map(value) when is_map(value), do: value
  defp as_map(_value), do: %{}

  defp repo_dom_id(repo) do
    case Map.get(repo, :repo_dom_id) do
      id when is_binary(id) -> id
      id when is_atom(id) and not is_nil(id) -> Atom.to_string(id)
      _ -> ""
    end
  end

  defp lanes(repo) do
    case Map.get(repo, :lanes) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  defp lane_markers(lane) do
    case Map.get(lane, :markers) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  defp lane_agent(lane), do: as_map(Map.get(lane, :agent))

  defp column_count(repo) do
    case Map.get(repo, :column_count) do
      count when is_integer(count) and count > 0 -> count
      _ -> 0
    end
  end

  defp agent_id(agent), do: Map.get(agent, :id)

  defp agent_label(agent) do
    "T" <> to_string(Map.get(agent, :task_local_id) || Map.get(agent, :id))
  end

  defp agent_status(agent), do: Map.get(agent, :status)

  defp marker_sha(marker) do
    case Map.get(marker, :sha) do
      sha when is_binary(sha) -> sha
      sha when is_atom(sha) and not is_nil(sha) -> Atom.to_string(sha)
      sha when is_integer(sha) -> Integer.to_string(sha)
      _ -> ""
    end
  end

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: 0

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
end
