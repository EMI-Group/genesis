defmodule EvoDashWeb.AgentsComponents.CommitGraphView.Fold do
  @moduledoc """
  Row-DETAIL half of the commit-graph renderer
  (`EvoDashWeb.AgentsComponents.CommitGraphView`): the folded-commit ("hidden
  run") presentation, the per-repo fold controls, the row's agent/ref tag
  chips, the tooltip text and the shared agent / DOM-key lookups both halves
  use.

  ## Folded runs

  The builder collapses an agent lane's runs of hidden intermediate commits
  into ONE synthetic node per run — `kind: :gap`, `sha: "gap-" <> fold_key`,
  `hidden_count: n` (an integer ≥ 2: a hidden run of ONE entry never folds),
  `fold_key`, `expanded: boolean`,
  empty `start_ids` / `end_ids` / `refs` — and reports `fold_count` per repo
  (read TOTALLY: absent → `0`). A gap node is emitted in BOTH states:

    * collapsed (`expanded: false`) — the gap row stands in for the hidden
      commits as a dashed "… N commits" runner and the gutter draws a small
      HOLLOW dashed dot, so the lane's continuity reads as a dashed segment
      through the fold;
    * expanded (`expanded: true`) — the run's commits are ALSO rendered as
      normal rows/nodes, and the same gap row becomes that run's collapse
      control (chevron-up).

  A gap row fires `toggle_commit_fold` with `phx-value-fold-key`; while the
  repo has any fold its header offers `expand_all_commit_folds` /
  `collapse_all_commit_folds`. The row also publishes its RAW run key as
  `data-cg-fold-key` (omitted when the model has no such binary), so the
  client hook's delegated keyboard activation can tell a gap row apart from a
  commit row and toggle that run instead of selecting the agent. Nothing here
  is stateful — `expanded` comes from the model.

  A gap node is never a `:base` / `:noop` stub: it never renders start/end
  markers, selection rings or agent/ref tags.

  ## Also here

  `row_tags/1` (the `start` / `end` agent chips + the ref chips of one row),
  the node/row tooltip text (`node_title/1`, `meta_text/1`) with its formatting
  helpers, the shared agent lookups (`agent_index/1`, `agent_for/2`,
  `agent_color/2`, `agent_label/2`, `agent_status/1`, `agent_ended?/1`) and the
  DOM-key sanitizers (`safe_string/1`, `dom_key/1`) — so the renderer keeps
  only the graph layout, the states and the selection marking.

  Everything is TOTAL: every model read is `Map.get/2`, odd shapes degrade to
  an empty label / base ink / no chip, and there is no `try/rescue`.
  """

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.AgentsComponents.CommitGraphView.Geometry

  # zh_CN glossary for the strings rendered here:
  #   %{count} commit / %{count} commits → "… N 个提交"（折叠的中间提交数，单复数同形）,
  #   %{count} hidden commits → "N 个隐藏提交",
  #   Expand all → "全部展开", Collapse all → "全部收起",
  #   start → "起始", end → "结束", terminated → "已终止",
  #   base → "基线", no-op → "空提交"

  # ---------------------------------------------------------------------------
  # Folded-run model reads (all TOTAL)
  # ---------------------------------------------------------------------------

  # A node is a folded run marker only when the model says `kind: :gap`.
  def gap?(node) when is_map(node), do: Map.get(node, :kind) == :gap
  def gap?(_node), do: false

  # How many commits this fold hides — a non-integer / non-positive value folds
  # to `0` (the row still renders; only the count text degenerates).
  def hidden_count(node) when is_map(node) do
    case Map.get(node, :hidden_count) do
      n when is_integer(n) and n > 0 -> n
      _ -> 0
    end
  end

  def hidden_count(_node), do: 0

  # The run's own identity, used for `phx-value-fold-key` and the row id slice.
  def fold_key(node) when is_map(node), do: safe_string(Map.get(node, :fold_key))
  def fold_key(_node), do: ""

  # `expanded: true` means the run's commits are rendered alongside this marker,
  # so the marker is then the run's COLLAPSE control.
  def expanded?(node) when is_map(node), do: Map.get(node, :expanded) == true
  def expanded?(_node), do: false

  # How many folds this repo has (drives the per-repo fold controls). Absent /
  # odd values fold to `0`, so the controls simply do not render.
  def fold_count(repo) when is_map(repo) do
    case Map.get(repo, :fold_count) do
      n when is_integer(n) and n > 0 -> n
      _ -> 0
    end
  end

  def fold_count(_repo), do: 0

  # ---------------------------------------------------------------------------
  # gap_row/1 — the compact dashed row standing in for a hidden run.
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:node, :map, required: true)

  def gap_row(assigns) do
    ~H"""
    <div
      id={"commit-gap-row-" <> @dom <> "-" <> dom_key(fold_key(@node))}
      class="cg-row cg-gap-row flex items-center gap-2 px-2 rounded border-l-2 border-dashed border-base-300 text-base-content/60 cursor-pointer hover:bg-base-200/60"
      style={"height: #{Geometry.row_h()}px"}
      data-commit-graph-anim="row"
      data-cg-sha={Map.get(@node, :sha)}
      data-cg-agent-id={Map.get(@node, :owner_id)}
      data-cg-fold-key={raw_fold_key(@node)}
      title={hidden_label(@node)}
      role="button"
      tabindex="0"
      phx-click="toggle_commit_fold"
      phx-value-fold-key={fold_key(@node)}
    >
      <.icon name={fold_icon(@node)} class="size-3.5 shrink-0" />
      <span class="cg-gap-label inline-flex items-center gap-1 rounded border border-dashed border-base-300 px-1.5 py-0.5 text-[10px] font-mono whitespace-nowrap">
        <span aria-hidden="true">…</span>
        <span>{hidden_label(@node)}</span>
      </span>
    </div>
    """
  end

  defp fold_icon(node) do
    if expanded?(node), do: "hero-chevron-up", else: "hero-chevron-down"
  end

  # The run's identity as published for the client hook (`data-cg-fold-key`):
  # the RAW `fold_key` model string, NOT the DOM-sanitized form, so the hook can
  # match the row against the run it toggles. Absent / non-binary → nil, which
  # makes HEEx omit the attribute entirely (the hook treats a missing key as a
  # no-op) rather than inventing a value.
  defp raw_fold_key(node) do
    case Map.get(node, :fold_key) do
      key when is_binary(key) -> key
      _ -> nil
    end
  end

  defp hidden_label(node) do
    count = hidden_count(node)

    ngettext("%{count} commit", "%{count} commits", count, count: count)
  end

  # ---------------------------------------------------------------------------
  # gap_node/1 — the fold's marker in the gutter, drawn through the EXISTING
  # node scheme (`g.cg-node` + a small hollow dashed dot) so the lane's
  # continuity reads as a dashed segment through the hidden run.
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:node, :map, required: true)
  attr(:positions, :map, required: true)

  def gap_node(assigns) do
    ~H"""
    <% {cx, cy} = gap_point(@node, @positions) %>
    <g
      id={"commit-node-" <> @dom <> "-" <> dom_key(Map.get(@node, :sha))}
      class="cg-node cg-gap-node"
      data-commit-graph-anim="node"
      data-cg-sha={Map.get(@node, :sha)}
      data-cg-agent-id={Map.get(@node, :owner_id)}
    >
      <title>{hidden_label(@node)}</title>
      <circle
        class="cg-node-dot"
        cx={cx}
        cy={cy}
        r={Geometry.base_r()}
        stroke-width="1.5"
        stroke-dasharray="2 2"
        style="fill: none; fill-opacity: 1; stroke: var(--color-base-content)"
      />
    </g>
    """
  end

  # The gap dot sits on its lane / row like any other node; an odd position
  # folds to lane 0 / row 0 rather than raising.
  defp gap_point(node, positions) do
    pos = Map.get(positions, Map.get(node, :sha), %{col: 0, row: 0})
    {Geometry.dot_x(Map.get(pos, :col)), Geometry.dot_y(Map.get(pos, :row))}
  end

  # ---------------------------------------------------------------------------
  # fold_controls/1 — the per-repo Expand all / Collapse all pair in the repo
  # header. Rendered only while the repo has folds (`fold_count > 0`).
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:fold_count, :integer, required: true)

  def fold_controls(assigns) do
    ~H"""
    <div class="ml-auto flex items-center gap-1 shrink-0">
      <button
        id={"cg-fold-" <> @dom <> "-expand-all"}
        type="button"
        class="btn btn-ghost btn-xs"
        title={gettext("Expand all")}
        phx-click="expand_all_commit_folds"
      >
        <.icon name="hero-chevron-double-down" class="size-3.5" />
        <span>{gettext("Expand all")}</span>
      </button>
      <button
        id={"cg-fold-" <> @dom <> "-collapse-all"}
        type="button"
        class="btn btn-ghost btn-xs"
        title={gettext("Collapse all")}
        phx-click="collapse_all_commit_folds"
      >
        <.icon name="hero-chevron-double-up" class="size-3.5" />
        <span>{gettext("Collapse all")}</span>
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # row_tags/1 — a row's second line: one chip per agent that STARTS here (its
  # fork point) and per agent that TIPS here, then one chip per ref.
  # ---------------------------------------------------------------------------

  attr(:dom, :string, required: true)
  attr(:node, :map, required: true)
  attr(:agents_index, :map, required: true)
  attr(:start_ids, :list, default: [])
  attr(:end_ids, :list, default: [])

  def row_tags(assigns) do
    ~H"""
    <div
      :if={@start_ids != [] or @end_ids != [] or ref_list(Map.get(@node, :refs)) != []}
      class="flex items-center gap-1 flex-wrap min-w-0"
    >
      <button
        :for={id <- @start_ids}
        :key={"start-" <> dom_key(id)}
        id={"commit-agent-tag-" <> @dom <> "-" <> dom_key(Map.get(@node, :sha)) <> "-start-" <> dom_key(id)}
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
        :for={id <- @end_ids}
        :key={"end-" <> dom_key(id)}
        id={"commit-agent-tag-" <> @dom <> "-" <> dom_key(Map.get(@node, :sha)) <> "-end-" <> dom_key(id)}
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
        id={"commit-ref-tag-" <> @dom <> "-" <> dom_key(Map.get(@node, :sha)) <> "-" <> dom_key(ref)}
        class="cg-ref-tag inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-mono bg-base-200 text-base-content/70"
        title={ref}
      >
        {ref}
      </span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Tooltips / row text
  # ---------------------------------------------------------------------------

  # The node/row tooltip: an optional `base` / `no-op` prefix, then the
  # message's first line · short sha · author · date · refs.
  def node_title(node) do
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
  def meta_text(node) do
    [author(node), commit_date(node)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  def first_line(message) when is_binary(message) do
    message |> String.split("\n", parts: 2) |> hd()
  end

  def first_line(_message), do: ""

  def short_sha(sha) do
    case sha do
      sha when is_binary(sha) and sha != "" -> String.slice(sha, 0, 8)
      _ -> nil
    end
  end

  def commit_short_sha(commit) do
    case Map.get(commit, :short_sha) do
      sha when is_binary(sha) and sha != "" -> sha
      _ -> nil
    end
  end

  def ref_list(refs) when is_list(refs), do: refs |> Enum.flat_map(&ref_name/1) |> Enum.uniq()
  def ref_list(_refs), do: []

  defp ref_name(ref) when is_binary(ref) and ref != "", do: [ref]

  defp ref_name(%{} = ref) do
    case Map.get(ref, :name) || Map.get(ref, "name") do
      name when is_binary(name) and name != "" -> [name]
      _ -> []
    end
  end

  defp ref_name(ref) when is_atom(ref) and not is_nil(ref), do: [Atom.to_string(ref)]
  defp ref_name(_ref), do: []

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

  # ---------------------------------------------------------------------------
  # Shared agent lookups — ONE index for colours, labels and ended-state.
  # ---------------------------------------------------------------------------

  # `%{agent_id => agent}`. Agents without an id are skipped (`owner_id` /
  # `agent_id` are compared as the RAW model terms).
  def agent_index(agents) when is_list(agents) do
    Enum.reduce(agents, %{}, fn agent, acc ->
      case Map.get(agent, :agent_id) do
        nil -> acc
        id -> Map.put_new(acc, id, agent)
      end
    end)
  end

  def agent_index(_agents), do: %{}

  def agent_for(index, id) when is_map(index) and not is_nil(id), do: Map.get(index, id)
  def agent_for(_index, _id), do: nil

  def agent_color(index, id) do
    case agent_for(index, id) do
      nil -> "var(--color-base-content)"
      agent -> agent_color_of(agent)
    end
  end

  def agent_color_of(agent) when is_map(agent) do
    case Map.get(agent, :color) do
      color when is_binary(color) and color != "" -> color
      _ -> "var(--color-base-content)"
    end
  end

  def agent_color_of(_agent), do: "var(--color-base-content)"

  def agent_status(agent) when is_map(agent), do: Map.get(agent, :status)
  def agent_status(_agent), do: nil

  # An agent is ENDED only when the model explicitly flags it (`ended: true`).
  # OPTIONAL and read TOTALLY — an agent without it (or with any non-`true`
  # value) renders exactly like a live agent.
  def agent_ended?(agent) when is_map(agent), do: Map.get(agent, :ended) == true
  def agent_ended?(_agent), do: false

  # `T<task_local_id>`, falling back to the raw agent id.
  def agent_label(index, id) do
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

  # ---------------------------------------------------------------------------
  # DOM keys — one sanitizer shared by the rows, the gutter and the gap markers.
  # ---------------------------------------------------------------------------

  def safe_string(value) when is_binary(value), do: value
  def safe_string(value) when is_atom(value), do: Atom.to_string(value)
  def safe_string(value) when is_integer(value), do: Integer.to_string(value)
  def safe_string(value), do: inspect(value)

  # A DOM-safe fragment: the term stringified, then anything outside
  # `[A-Za-z0-9_-]` folded to `-` (a raw agent id / sha / fold key may be any
  # term).
  def dom_key(value), do: value |> safe_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
end
