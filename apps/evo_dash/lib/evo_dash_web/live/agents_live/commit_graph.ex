defmodule EvoDashWeb.AgentsLive.CommitGraph do
  @moduledoc """
  Pure view-model assembly for the Agents page's TEMPORAL (git commit history)
  view — a VERTICAL, commit-centric DAG: ONE VISIBLE ROW per commit, GLOBALLY
  interleaved across agents, plus a left GUTTER LANE per node so the renderer
  can draw the commit → parent edges and the agent-level spawn / merge-back
  edges between the rows (the GitKraken/GitLen-style graph shape).

  The module is deliberately PURE — no I/O, no socket, no processes — mirroring
  the sibling support modules (`HistoryGate`, `OptimisticMessages`,
  `PendingEvents`). It is fed:

    - `raw_by_repo` — the per-repo commit graph fetched by the node-aware
      commit RPC (`%{repo_key => %{commits: [commit], refs: %{sha => [name]}}}`),
      with `commits` in `git log` order; each commit is an atom-keyed map
      (`:sha, :short_sha, :message, :author_name, :date, :parents`, where
      `:parents` is the full SHA list, `[]` for a root); and
    - `agents` — the page's already-loaded rich agent maps
      (`EvoDashWeb.AgentsLive.LoadData.build_agents/2`), carrying at least
      `:id`, `:task_local_id`, `:status`, `:depth`, `:repo_root`/`:repo_id`,
      `:parent_id`, `:base_commit` and `:current_commit`.

  Every commit/agent field is read through `Map.get/2` and every function is
  TOTAL: odd input shapes degrade to empty nodes/edges/agents instead of raising.

  The layout internals live in `CommitGraph.Interleave` (topological layers,
  the global row order, lanes, no-op stubs) and the edge derivation in
  `CommitGraph.Edges`. They share three total shape readers exposed here as
  undocumented functions: `parents_list/1`, `sha_or_nil/1` and `stringify/1`.

  ## Nodes (one row per commit)

  One node per ADDRESSABLE fetched commit (a map with a non-empty binary
  `:sha`), de-duplicated by sha, PLUS one synthesized `kind: :base` node per
  distinct agent `:base_commit` absent from the fetched commits (see
  "Base synthesis"), PLUS one synthesized `kind: :noop` stub node per no-op
  child agent (see "No-op stubs").

  ## Lanes (one per agent)

  Agents are ordered by a DFS / SUBTREE-CONTIGUOUS walk: starting from the
  ROOTS (a nil `parent_id`, or one that matches no agent of the repo group —
  the same resolution rule the agent-level edges use), each root's subtree is
  visited pre-order, its children recursively in stable
  `{task_local_id, agent_id}` order (`task_local_id` is the agent's slot id;
  it may be `nil` for odd maps — Erlang term order places `nil` after every
  integer, which stays deterministic — and the `agent_id` term is the FINAL
  tie-break). Every parent's subtree therefore occupies CONSECUTIVE lanes:
  children of different parents never interleave across the gutter, so the
  agent-level `:spawn` / `:merge_back` connectors of one subtree do not weave
  through unrelated lanes and cross other subtrees' edges. A malformed parent
  CYCLE cannot loop the walk (a visited set stops re-entry) and its members
  still get exactly one lane each — agents no root reaches are appended as
  fallback roots in the same stable order. `depth` is no longer an ordering
  key (it still drives the per-agent hue and the ownership tie-breaks).

  Every agent owns ONE lane: its index in that order, SHIFTED RIGHT BY 1 when
  the repo has at least one UNOWNED node. Lane 0 is then the NEUTRAL lane —
  pre-task / disconnected commits that no agent claims sit in it
  (`owner_id: nil`) instead of being misattributed to the root agent. A node's
  `column` is its owner's lane (the neutral lane 0 for unowned nodes), so
  parallel sibling agents never share a gutter lane even at the same recursion
  depth. `column_count` is `max(max(node.column) + 1, max(agent.lane) + 1, 1)`
  — a lane that owns no node still counts, so its header chip renders.

  ## Rows — global interleaving

  `nodes` is ordered TOP → BOTTOM (ascending `row`, `0` = top) and every `row`
  is UNIQUE, so `row_count == node_count` and the rows are exactly
  `0 .. node_count - 1`.

  Every node carries a topological LAYER `L` over its PRESENT parents (parents
  that are nodes of this repo): `L = 0` for a node with no present parents
  (roots, synthesized base and no-op stub nodes), else `max(L(parent)) + 1` —
  a cycle-safe memoized DFS. The global row order is ALL nodes sorted ascending
  by `{L, date_unix, sha}` (a missing date counts as 0). `L` strictly increases
  along every edge, so parents sit above children and a fork point sits above
  the child's first commit — and commits of parallel agents INTERLEAVE by date
  instead of forming per-agent blocks.

  ## Edges (commit → parent, and agent-level)

  For every real commit node and every one of its `:parents` present in the
  node set (fetched commits ∪ synthesized base shas), one edge is emitted from
  the child to that parent, carrying both endpoints' `{column, row}`: `kind:
  :parent` for the FIRST present parent in the commit's `:parents` order (the
  first-parent lineage) and `kind: :merge` for every other present parent (a
  folded side branch). Parents absent from the node set produce no edge;
  identical `{from_sha, to_sha}` edges are de-duplicated; the `owner_id` is the
  CHILD node's owner. DROP RULE: a commit → parent edge whose UNORDERED sha
  pair equals an agent-level edge's unordered pair is dropped — the agent-level
  edge replaces it visually (e.g. a child's oldest-commit → fork `:parent` edge
  yields to the dashed `:spawn` edge, and a fast-forward continuation → tip
  `:parent` edge yields to the `:merge_back` edge).

  AGENT-LEVEL edges are emitted per CHILD agent C whose parent agent P is
  resolvable within the same repo group (`P.id == C.parent_id`); a child
  without a resolvable parent contributes none:

    - `:spawn` — the dashed branch-out from the fork commit into the child's
      lane. `from_sha` is the fork node (the child's `:base_commit` — a
      fetched commit node or the synthesized `:base` node; skipped when the
      base is nil/non-binary) and `to_sha` the child's OLDEST progress-path
      commit. `owner_id` is the CHILD's agent id (the stroke is child-colored).

    - `:merge_back` — the dashed return of the child's work into the parent's
      lane, from the child's tip. When the child produced commits the source
      is the node whose sha is the child's `current_commit` (skipped when that
      is not a node); when it produced nothing the source is its no-op stub
      (see "No-op stubs"). The target is the TOPMOST (min-row) node owned by P
      strictly BELOW the source row; when the parent lane has nothing below
      yet, a VIRTUAL landing is emitted — `to_sha: nil` with authoritative
      `to_column` (the parent's lane) and `to_row` (the source's own row) for
      the renderer's endpoint fallback. A REAL merge (a parent-lane commit
      listing the child tip among its 2nd+ parents) is already covered by the
      dashed `:merge` edge, so no `:merge_back` is emitted for it.

  Commit → parent edges sort by `{from_sha, to_sha}`; agent-level edges sort by
  `{kind, owner_key, from_sha, to_sha}` (owner_key = the owner id stringified
  deterministically); the `edges` list is commit edges ++ agent edges.

  ## Base synthesis

  The fetch covers `git log base..tip` per agent, which EXCLUDES the base
  commit, so a fork point no agent committed on has no fetched commit to hang
  an edge on. Every distinct agent `:base_commit` absent from the fetched
  commits is therefore synthesized as a `kind: :base` node (`message: ""`, no
  author, no date, no refs), so the child → parent edge into the fork point can
  be drawn. A fetched commit that equals some agent's `:base_commit` stays a
  NORMAL `:commit` node — it is never duplicated. Base synthesis is ONLY that
  fallback: a covered fork point is never re-synthesized.

  ## No-op stubs

  A child agent whose progress path is EMPTY (it forked but committed nothing —
  `current_commit` nil, equal to its base, or absent from the fetch) would be
  invisible: it owns no node, so its lane would have no row. When its parent
  agent is resolvable in the same repo group and its fork point is usable, ONE
  stub node `kind: :noop` is synthesized: `message: ""`, no author/date/refs,
  `sha = "noop-" <> agent_key` (a synthetic sha that can never collide with a
  hex git sha), `start_ids: []`, `end_ids: [child_id]`, owned by the child, on
  the child's lane, at layer `fork layer + 1` so it lands just below the fork.
  The child's agent-level edges then hang off the stub (`:spawn` fork → stub,
  `:merge_back` stub → parent lane).

  ## Ownership (a single owner per node)

  Ownership keeps ONE owner per node:

    - a commit on at least one agent's progress path belongs to the agent with
      the MAXIMUM depth (ties broken by the SMALLEST agent-order index), so a
      shared commit lands with the deepest agent that worked on it;
    - a fetched commit on NO path (a merged-in side commit, a pre-task root)
      inherits the owner of the commit it is the FIRST parent of — the deepest
      such child, ties by smallest index. When NO owned child claims it, the
      commit is UNOWNED (`owner_id: nil`, neutral lane 0). Commits are resolved
      in DESCENDING layer order, so children are owned before their parents;
    - a synthesized base node belongs to the agent with the SMALLEST
      `{depth, index}` among the agents forked from it, so a shared task base
      lands with the shallowest root agent;
    - a no-op stub belongs to its child agent by construction.

  A repo without agents has no owners and therefore no nodes, edges or agents.

  ## Progress path (first-parent walk)

  Each agent's path is a first-parent walk from its `current_commit` backwards,
  stopping at (excluding) its `base_commit`, at a sha absent from the fetched
  graph, or at an already-seen sha (cycle guard); the result is
  NEWEST → OLDEST.

  ## Start / end annotations

  Every node carries the agent ids that fork from it (`start_ids`, from
  `:base_commit`) and the agent ids that tip at it (`end_ids`, from
  `:current_commit`), in agent order, so a lane's endpoints can be marked
  without re-scanning the agent list. A node can be a start for one agent and
  an end for another; a no-op stub is only ever an END (of its child).

  ## Depth → hue

  `color(depth) = EvoDashWeb.ThemeColor.hsl_to_hex(hue, 70, 54)` where
  `hue = Integer.mod(round(depth * 137.508) + 265, 360)` — golden-angle step
  137.508° per depth level (deterministic, maximally spread hues), +265°
  offset so depth 0 lands on blue-violet and common shallow depths stay away
  from the status colors (red/green/amber), saturation 70 / lightness 54
  identical to `ThemeColor`'s project accents. The existing public
  `EvoDashWeb.ThemeColor.hsl_to_hex/3` is reused — HSL→hex is NOT
  reimplemented here. Non-integer/nil/negative depth → 0.

  ## Output shape

  `build/2` returns one map per repository group, sorted by
  `{repo_name, repo_dom_id}`:

      %{
        repo_key: term(), repo_dom_id: String.t(), repo_name: String.t(),
        node_count: non_neg_integer(), edge_count: non_neg_integer(),
        row_count: non_neg_integer(), column_count: non_neg_integer(),
        nodes: [%{sha:, short_sha:, message:, author_name:, date:, refs:,
                  row:, column:, depth:, kind:, owner_id:, start_ids:, end_ids:}],
        edges: [%{from_sha:, to_sha:, from_column:, from_row:, to_column:,
                  to_row:, kind:, owner_id:}],
        agents: [%{agent_id:, task_local_id:, status:, depth:, lane:,
                   parent_id:, color:, start_sha:, end_sha:, ended:}]
      }

  `nodes` is sorted top → bottom (ascending `row`), `agents` by the DFS
  subtree-contiguous agent order (see "Lanes (one per agent)"), and repos by
  `{repo_name, repo_dom_id}` — all deterministic, so LiveView can patch the
  graph incrementally instead of re-rendering it on every refresh. The module
  emits no rendering concerns: no DOM ids beyond `repo_dom_id`, no colors
  beyond `agent.color`, no SVG geometry.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias __MODULE__.Edges
  alias __MODULE__.Interleave

  alias EvoDashWeb.ThemeColor
  alias EvoGit.Platform

  @typedoc """
  One commit ROW of the vertical graph — a fetched commit (`kind: :commit`), a
  synthesized fork point (`kind: :base`) or a synthesized no-op child stub
  (`kind: :noop`). `row` is the unique top → bottom position, `column` the
  owner's lane (the neutral lane 0 for unowned nodes), `depth` the OWNER
  agent's depth, `owner_id` the owning agent's id (nil for unowned nodes) and
  `start_ids`/`end_ids` the agent ids that fork from / tip at this sha.
  """
  @type node_view :: %{
          sha: String.t(),
          short_sha: String.t(),
          message: String.t(),
          author_name: String.t() | nil,
          date: DateTime.t() | nil,
          refs: [String.t()],
          row: non_neg_integer(),
          column: non_neg_integer(),
          depth: non_neg_integer(),
          kind: :commit | :base | :noop,
          owner_id: term() | nil,
          start_ids: [term()],
          end_ids: [term()]
        }

  @typedoc """
  One edge of the vertical graph. The `from_*` fields are the child node's
  gutter position, the `to_*` fields the parent's; `kind` is `:parent` for a
  first present parent, `:merge` for every other present parent, `:spawn` for
  an agent-level fork → child-oldest branch-out and `:merge_back` for an
  agent-level child-tip → parent-lane return. `owner_id` is the CHILD node's
  owner (the child agent for agent-level edges). A VIRTUAL landing carries
  `to_sha: nil` with authoritative `to_column`/`to_row`.
  """
  @type edge_view :: %{
          from_sha: String.t(),
          to_sha: String.t() | nil,
          from_column: non_neg_integer(),
          from_row: non_neg_integer(),
          to_column: non_neg_integer(),
          to_row: non_neg_integer(),
          kind: :parent | :merge | :spawn | :merge_back,
          owner_id: term() | nil
        }

  @typedoc """
  One agent of the graph — metadata only (rows are interleaved globally, so
  there are no per-agent row bands). `depth` is normalized, `lane` the agent's
  gutter lane (its DFS-order index shifted right by 1 when unowned nodes
  exist), `parent_id` the RAW parent agent id from the input map (nil for root
  agents), `color` the depth hue, `start_sha`/`end_sha` the agent's
  `:base_commit`/`:current_commit`, and `ended` is true for an in-session
  retained agent that is no longer live.
  """
  @type agent_view :: %{
          agent_id: term(),
          task_local_id: term(),
          status: term(),
          depth: non_neg_integer(),
          lane: non_neg_integer(),
          parent_id: term(),
          color: String.t(),
          start_sha: String.t() | nil,
          end_sha: String.t() | nil,
          ended: boolean()
        }

  @typedoc """
  The vertical commit-graph view model for one repository group, ready to
  render.
  """
  @type repo_view :: %{
          repo_key: term(),
          repo_dom_id: String.t(),
          repo_name: String.t(),
          node_count: non_neg_integer(),
          edge_count: non_neg_integer(),
          row_count: non_neg_integer(),
          column_count: non_neg_integer(),
          nodes: [node_view()],
          edges: [edge_view()],
          agents: [agent_view()]
        }

  # --- Public API -----------------------------------------------------------

  @doc """
  The grouping key used to bucket agents by repository.

  Mirrors the tree's grouping (`AgentsLive.grouping_key/1`): the agent's
  `repo_root` (an absolute path) when present, otherwise its `repo_id`
  (defaulting to `"primary"`).
  """
  @spec grouping_key(map()) :: term()
  def grouping_key(agent) do
    Map.get(agent, :repo_root) || Map.get(agent, :repo_id)
  end

  @doc """
  Human-readable name for a repository grouping key.

  Identical to the agent tree's naming: the primary repo, the basename of an
  absolute path, `"Repo: <id>"` for any other id, and `"Unknown Repo"` for
  anything else.
  """
  @spec repo_display_name(term()) :: String.t()
  def repo_display_name("primary"), do: gettext("Primary Repo")
  def repo_display_name(:primary), do: gettext("Primary Repo")
  def repo_display_name(nil), do: gettext("Primary Repo")

  # An absolute path on any platform (Unix /foo or Windows C:\foo) — use the basename.
  def repo_display_name(key) when is_binary(key) do
    if Platform.absolute_path?(key) do
      Path.basename(key)
    else
      gettext("Repo: %{repo_id}", repo_id: key)
    end
  end

  def repo_display_name(_), do: gettext("Unknown Repo")

  @doc """
  Builds the per-repo VERTICAL commit-graph view model.

  `raw_by_repo` maps a repo grouping key to the fetched commit graph
  (`%{commits: [commit], refs: %{sha => [name]}}`); a key that is absent (or a
  repo whose fetch failed) yields empty nodes, edges and agents.

  Agents are grouped by `grouping_key/1` — exactly like the tree — and the
  resulting `repo_view`s are sorted by `repo_name` ascending (ties broken by
  the stable `repo_dom_id`, so the DOM order never flaps between refreshes).
  """
  @spec build(map(), [map()]) :: [repo_view()]
  def build(raw_by_repo, agents) do
    agents
    |> List.wrap()
    |> Enum.group_by(&grouping_key/1)
    |> Enum.map(fn {repo_key, repo_agents} ->
      build_repo(repo_key, repo_agents, raw_for(raw_by_repo, repo_key))
    end)
    |> Enum.sort_by(fn repo -> {repo.repo_name, repo.repo_dom_id} end)
  end

  # --- Repo assembly --------------------------------------------------------

  defp build_repo(repo_key, repo_agents, raw) do
    body =
      case ordered_agents(repo_agents) do
        [] -> empty_body()
        ordered -> graph_body(ordered, raw)
      end

    Map.merge(
      %{
        repo_key: repo_key,
        repo_dom_id: repo_dom_id(repo_key),
        repo_name: repo_display_name(repo_key)
      },
      body
    )
  end

  # No agents means no owners, and an owner is the only thing that can claim a
  # node — so a repo without agents has no graph at all.
  defp empty_body do
    %{
      node_count: 0,
      edge_count: 0,
      row_count: 0,
      column_count: 1,
      nodes: [],
      edges: [],
      agents: []
    }
  end

  defp graph_body(ordered, raw) do
    # Filtered to ADDRESSABLE commits (a map with a non-empty binary :sha) and
    # de-duplicated by sha — git log never returns duplicates, but a malformed
    # payload must not produce ambiguous lookups either.
    commits = addressable_commits(raw)
    lookup = commit_lookup(commits)
    refs = refs_map(raw)

    base_shas = base_shas(ordered, lookup)
    base_owners = base_owners(ordered, lookup)

    # Synthesized fork points join the layer walk as parentless pseudo
    # commits: a child's oldest commit usually still LISTS its fork sha as a
    # parent, so counting the fork as present keeps `L` strictly increasing
    # along that edge — the fork row stays strictly above the child's first
    # row instead of tying at layer 0 and letting the sha tie-break decide.
    layers = Interleave.layers(layer_lookup(lookup, base_shas))

    paths =
      Enum.map(ordered, fn agent ->
        walk(
          Map.get(agent, :current_commit),
          Map.get(agent, :base_commit),
          lookup,
          MapSet.new()
        )
      end)

    owners = node_owners(commits, ordered, paths, layers)
    parent_indices = parent_indices(ordered)

    stubs = Interleave.noop_stubs(ordered, paths, parent_indices, layers)

    {start_ids, end_ids} = annotations(ordered)

    # Lane 0 is the NEUTRAL lane: it exists only when some fetched commit is
    # unowned, in which case every agent lane shifts right by one.
    shift = if Enum.any?(Map.values(owners), &is_nil/1), do: 1, else: 0

    entries =
      commit_entries(commits, layers, owners, refs, start_ids, end_ids) ++
        base_entries(base_shas, base_owners, start_ids, end_ids) ++
        stub_entries(stubs, ordered)

    nodes = Interleave.layout(entries, index_meta(ordered), shift)
    agents = build_agents(ordered, shift)

    edges =
      Edges.derive(%{
        commits: commits,
        nodes: nodes,
        ordered: ordered,
        paths: paths,
        parent_indices: parent_indices,
        stubs: Map.new(stubs, &{&1.agent_index, &1}),
        lane_shift: shift
      })

    %{
      node_count: length(nodes),
      edge_count: length(edges),
      row_count: length(nodes),
      column_count: column_count(nodes, agents),
      nodes: nodes,
      edges: edges,
      agents: agents
    }
  end

  # max(max(node.column) + 1, max(agent.lane) + 1, 1) — a lane with no nodes
  # still counts, so its header chip renders even while the lane is empty.
  defp column_count(nodes, agents) do
    columns = Enum.map(nodes, & &1.column)
    lanes = Enum.map(agents, & &1.lane)
    max(boundary(columns), boundary(lanes))
  end

  defp boundary([]), do: 1
  defp boundary(list), do: Enum.max(list) + 1

  # Fetches a repo's raw graph. Any shape that is not a map (missing repo, a
  # failed fetch, garbage) degrades to an empty graph rather than raising.
  defp raw_for(raw_by_repo, repo_key) when is_map(raw_by_repo) do
    case Map.get(raw_by_repo, repo_key) do
      raw when is_map(raw) -> raw
      _ -> %{}
    end
  end

  defp raw_for(_raw_by_repo, _repo_key), do: %{}

  defp addressable_commits(raw) do
    case Map.get(raw, :commits) do
      list when is_list(list) ->
        list
        |> Enum.filter(&is_map/1)
        |> Enum.filter(fn commit ->
          case Map.get(commit, :sha) do
            sha when is_binary(sha) and sha != "" -> true
            _ -> false
          end
        end)
        |> Enum.uniq_by(&Map.get(&1, :sha))

      _ ->
        []
    end
  end

  # The per-repo sha → commit lookup. Only addressable commits are in it, so
  # presence in the lookup is exactly "part of the fetched graph".
  defp commit_lookup(commits) do
    Enum.reduce(commits, %{}, fn commit, acc ->
      Map.put_new(acc, Map.get(commit, :sha), commit)
    end)
  end

  defp refs_map(raw) do
    case Map.get(raw, :refs) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  # The layer walk's lookup: the fetched commits PLUS the synthesized fork
  # points (as parentless pseudo commits). Only the presence of their shas
  # matters — the walk never reads their fields beyond `:parents` (absent →
  # a layer-0 root).
  defp layer_lookup(lookup, base_shas) do
    Enum.reduce(base_shas, lookup, fn sha, acc -> Map.put_new(acc, sha, %{}) end)
  end

  # --- Agents ---------------------------------------------------------------

  # Agents are folded in DFS / SUBTREE-CONTIGUOUS order — the order the
  # `agents` list, the lanes and every ownership decision use — so a parent's
  # subtree occupies consecutive lanes (its `:spawn` / `:merge_back` connectors
  # never weave through unrelated subtrees) while everything stays
  # deterministic across refreshes.
  defp ordered_agents(repo_agents) do
    # Index-tag every agent: the visited set keys on the index, so even a
    # duplicate identical agent map keeps its own lane.
    agents = repo_agents |> List.wrap() |> Enum.with_index()

    by_id =
      Map.new(agents, fn {agent, index} ->
        {Map.get(agent, :id), index}
      end)

    # parent id -> children, in stable {task_local_id, id} order per parent.
    children =
      agents
      |> Enum.reject(fn {agent, _index} -> Map.get(agent, :parent_id) == nil end)
      |> Enum.group_by(fn {agent, _index} -> Map.get(agent, :parent_id) end, fn {agent, index} ->
        {agent, index}
      end)
      |> Map.new(fn {parent_id, kids} -> {parent_id, stable_sort(kids)} end)

    # Roots: a nil parent, or one that matches no agent of THIS repo group
    # (the same resolution rule the agent-level edges use — an unresolvable
    # parent strands the child, so it anchors its own subtree).
    roots =
      agents
      |> Enum.reject(fn {agent, _index} ->
        parent_id = Map.get(agent, :parent_id)
        parent_id != nil and Map.has_key?(by_id, parent_id)
      end)
      |> stable_sort()

    {reversed, visited} = dfs_order(roots, children, [], MapSet.new())

    # Cycle safety: an agent no root reached (its parent chain loops) is
    # appended as a fallback root in the stable order, exactly one lane each.
    stranded =
      agents
      |> Enum.reject(fn {_agent, index} -> index in visited end)
      |> stable_sort()

    # `reversed` accumulates pre-order backwards (O(1) prepends); ONE reverse
    # at the top yields the pre-order DFS sequence.
    ordered = Enum.reverse(reversed)

    Enum.map(ordered ++ stranded, fn {agent, _index} -> agent end)
  end

  # Stable per-sibling order: {task_local_id, id} (nil sorts after every
  # integer in Erlang term order — deterministic).
  defp stable_sort(agents) do
    Enum.sort_by(agents, fn {agent, _index} ->
      {Map.get(agent, :task_local_id), Map.get(agent, :id)}
    end)
  end

  # Pre-order DFS: each root, then its subtree, before the next root. The
  # `visited` index set stops a malformed parent cycle from re-entering a
  # subtree. `acc` is the pre-order sequence accumulated BACKWARDS.
  defp dfs_order([], _children, acc, visited), do: {acc, visited}

  defp dfs_order([{agent, index} | rest], children, acc, visited) do
    if index in visited do
      dfs_order(rest, children, acc, visited)
    else
      acc = [{agent, index} | acc]
      visited = MapSet.put(visited, index)

      kids =
        children
        |> Map.get(Map.get(agent, :id), [])
        |> Enum.reject(fn {_kid, kid_index} -> kid_index in visited end)

      {acc, visited} = dfs_order(kids, children, acc, visited)
      dfs_order(rest, children, acc, visited)
    end
  end

  # Per-agent ownership scores, keyed by agent-order index: `{-depth, index}`
  # sorts the deepest agent first and breaks ties on the smallest index.
  defp index_scores(ordered) do
    ordered
    |> Enum.with_index()
    |> Map.new(fn {agent, index} ->
      {index, {-normalize_depth(Map.get(agent, :depth)), index}}
    end)
  end

  # `{agent_id, depth}` per agent-order index, so a node can read its owner's id
  # and depth without rescanning the list.
  defp index_meta(ordered) do
    Enum.map(ordered, fn agent ->
      {Map.get(agent, :id), normalize_depth(Map.get(agent, :depth))}
    end)
  end

  defp owner_meta(meta, index) do
    case Enum.at(meta, index) do
      {id, depth} -> {id, depth}
      _ -> {nil, 0}
    end
  end

  # agent-order index → the parent agent's agent-order index, for the
  # agent-level (:spawn / :merge_back) edges. Only a NON-NIL parent id that
  # matches an agent id IN THE SAME repo group resolves; everything else is
  # nil and the child contributes no agent-level edges at all.
  defp parent_indices(ordered) do
    ids =
      Map.new(Enum.with_index(ordered), fn {agent, index} ->
        {Map.get(agent, :id), index}
      end)

    Map.new(Enum.with_index(ordered), fn {agent, index} ->
      {index, parent_index(ids, Map.get(agent, :parent_id))}
    end)
  end

  defp parent_index(_ids, nil), do: nil

  defp parent_index(ids, parent_id) when is_map(ids),
    do: Map.get(ids, parent_id)

  # --- Node entries (pre-layout) --------------------------------------------

  # Every node starts as an ENTRY: the final view fields plus the layout keys
  # (`layer`, `date_unix`, `owner_index`). `CommitGraph.Interleave` turns the
  # entries into positioned nodes.

  defp commit_entries(commits, layers, owners, refs, start_ids, end_ids) do
    Enum.map(commits, fn commit ->
      sha = Map.get(commit, :sha)

      %{
        sha: sha,
        short_sha: short_sha(commit, sha),
        message: first_line(Map.get(commit, :message)),
        author_name: author_name(commit),
        date: date_of(commit),
        date_unix: date_unix(commit),
        refs: refs_for(refs, sha),
        kind: :commit,
        layer: Map.get(layers, sha, 0),
        owner_index: Map.get(owners, sha),
        start_ids: Map.get(start_ids, sha, []),
        end_ids: Map.get(end_ids, sha, [])
      }
    end)
  end

  defp base_entries(base_shas, base_owners, start_ids, end_ids) do
    Enum.map(base_shas, fn sha ->
      %{
        sha: sha,
        short_sha: String.slice(sha, 0, 8),
        message: "",
        author_name: nil,
        date: nil,
        date_unix: 0,
        refs: [],
        kind: :base,
        # A synthesized fork point has no parents of its own: layer 0.
        layer: 0,
        owner_index: Map.get(base_owners, sha, 0),
        start_ids: Map.get(start_ids, sha, []),
        end_ids: Map.get(end_ids, sha, [])
      }
    end)
  end

  defp stub_entries(stubs, ordered) do
    meta = index_meta(ordered)

    Enum.map(stubs, fn stub ->
      {id, _depth} = owner_meta(meta, stub.agent_index)

      %{
        sha: stub.sha,
        short_sha: String.slice(stub.sha, 0, 8),
        message: "",
        author_name: nil,
        date: nil,
        date_unix: 0,
        refs: [],
        kind: :noop,
        # Just below the fork it grew from (the stub IS the child's only row).
        layer: stub.layer,
        owner_index: stub.agent_index,
        start_ids: [],
        end_ids: [id]
      }
    end)
  end

  # --- Agents view ----------------------------------------------------------

  defp build_agents(ordered, shift) do
    ordered
    |> Enum.with_index()
    |> Enum.map(fn {agent, index} ->
      depth = normalize_depth(Map.get(agent, :depth))

      %{
        agent_id: Map.get(agent, :id),
        task_local_id: Map.get(agent, :task_local_id),
        status: Map.get(agent, :status),
        depth: depth,
        lane: index + shift,
        parent_id: Map.get(agent, :parent_id),
        color: depth_color(depth),
        start_sha: sha_or_nil(Map.get(agent, :base_commit)),
        end_sha: sha_or_nil(Map.get(agent, :current_commit)),
        # Retained (ended) agents still appear so their START/END markers survive
        # agent recycling; live agents are never marked.
        ended: Map.get(agent, :ended) == true
      }
    end)
  end

  # --- Ownership ------------------------------------------------------------

  # sha → the agent-order index that owns it (nil = UNOWNED, neutral lane):
  # the deepest agent whose progress path contains the commit, plus — for
  # merged-in side commits — the index inherited from the first child.
  defp node_owners(commits, ordered, paths, layers) do
    owned = path_owners(ordered, paths)
    children = children_index(commits)
    scores = index_scores(ordered)

    commits
    |> Enum.reject(fn commit -> Map.has_key?(owned, Map.get(commit, :sha)) end)
    |> Enum.sort_by(fn commit ->
      {Map.get(layers, Map.get(commit, :sha), 0), date_unix(commit), Map.get(commit, :sha)}
    end)
    |> Enum.reverse()
    |> Enum.reduce(owned, fn commit, acc ->
      index = inherited_index(children, commit, acc, scores)
      Map.put_new(acc, Map.get(commit, :sha), index)
    end)
  end

  # Walks every agent's progress path, keeping the index with the best ownership
  # score (deepest, ties on the smallest agent-order index).
  defp path_owners(ordered, paths) do
    ordered
    |> Enum.with_index()
    |> Enum.zip(paths)
    |> Enum.reduce(%{}, fn {{agent, index}, path}, acc ->
      score = {-normalize_depth(Map.get(agent, :depth)), index}

      Enum.reduce(path, acc, fn sha, acc ->
        Map.update(acc, sha, score, &min(&1, score))
      end)
    end)
    |> Map.new(fn {sha, {_depth, index}} -> {sha, index} end)
  end

  # sha → the shas of the fetched commits whose FIRST parent is that sha (the
  # children along the first-parent lineage).
  defp children_index(commits) do
    Enum.reduce(commits, %{}, fn commit, acc ->
      case first_parent(commit) do
        sha when is_binary(sha) ->
          child = Map.get(commit, :sha)
          Map.update(acc, sha, [child], &[child | &1])

        _ ->
          acc
      end
    end)
  end

  # A merged-in side commit inherits the owner of the commit it is the FIRST
  # parent of — the deepest such child (ties on the smallest index). A child
  # that is itself unowned has no owner to pass on, so only OWNED children
  # count as claimants; when none does, the commit is UNOWNED (nil).
  defp inherited_index(children, commit, owners, scores) do
    children
    |> Map.get(Map.get(commit, :sha), [])
    |> Enum.flat_map(fn child ->
      case Map.fetch(owners, child) do
        {:ok, index} when is_integer(index) -> [Map.get(scores, index, {0, index})]
        _ -> []
      end
    end)
    |> case do
      [] -> nil
      candidates -> candidates |> Enum.min() |> elem(1)
    end
  end

  # Distinct agent base commits the fetch does not cover — `git log base..tip`
  # excludes the base, so a fork point no agent committed on has no fetched
  # commit to hang an edge on.
  defp base_shas(ordered, lookup) do
    ordered
    |> Enum.flat_map(fn agent ->
      case sha_or_nil(Map.get(agent, :base_commit)) do
        nil -> []
        sha -> if Map.has_key?(lookup, sha), do: [], else: [sha]
      end
    end)
    |> Enum.uniq()
  end

  # The SHALLOWEST agent forked from a synthesized base wins it, so a shared
  # task base lands with the root agent rather than a deep child.
  defp base_owners(ordered, lookup) do
    ordered
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {agent, index}, acc ->
      case sha_or_nil(Map.get(agent, :base_commit)) do
        nil ->
          acc

        sha ->
          if Map.has_key?(lookup, sha) do
            acc
          else
            score = {normalize_depth(Map.get(agent, :depth)), index}
            Map.update(acc, sha, score, &min(&1, score))
          end
      end
    end)
    |> Map.new(fn {sha, {_depth, index}} -> {sha, index} end)
  end

  # sha → the agent ids that fork from (start) / tip at (end) it, in agent order.
  defp annotations(ordered) do
    Enum.reduce(ordered, {%{}, %{}}, fn agent, {starts, ends} ->
      id = Map.get(agent, :id)

      {annotate(starts, Map.get(agent, :base_commit), id),
       annotate(ends, Map.get(agent, :current_commit), id)}
    end)
  end

  defp annotate(acc, sha, id) do
    case sha_or_nil(sha) do
      nil -> acc
      sha -> Map.update(acc, sha, [id], &(&1 ++ [id]))
    end
  end

  # --- Commit metadata --------------------------------------------------------

  @doc false
  def sha_or_nil(sha) when is_binary(sha) and sha != "", do: sha
  @doc false
  def sha_or_nil(_sha), do: nil

  defp short_sha(commit, sha) do
    case Map.get(commit, :short_sha) do
      short when is_binary(short) and short != "" -> short
      _ -> String.slice(sha, 0, 8)
    end
  end

  defp author_name(commit) do
    case Map.get(commit, :author_name) do
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  defp date_of(commit) do
    case Map.get(commit, :date) do
      %DateTime{} = date -> date
      _ -> nil
    end
  end

  defp date_unix(commit) do
    case Map.get(commit, :date) do
      %DateTime{} = date -> DateTime.to_unix(date)
      _ -> 0
    end
  end

  defp refs_for(refs, sha) when is_map(refs) do
    case Map.get(refs, sha) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp refs_for(_refs, _sha), do: []

  defp first_line(message) when is_binary(message) do
    message |> String.split("\n", parts: 2) |> hd()
  end

  defp first_line(_message), do: ""

  @doc false
  def parents_list(commit) do
    case Map.get(commit, :parents) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp first_parent(commit) do
    case parents_list(commit) do
      [first | _] -> first
      [] -> nil
    end
  end

  # Follows first parents from `sha` towards the root, collecting shas in
  # NEWEST → OLDEST order.
  #
  # The walk stops without collecting the current sha when:
  #   * it is not a binary (nil/garbage — agent has no usable commits),
  #   * it is the agent's exclusive `base_commit` (the fork point it grew from),
  #   * it was already seen within this same walk (defensive cycle guard), or
  #   * it is absent from the fetched graph (shallow/partial fetch).
  defp walk(sha, base, lookup, seen) do
    cond do
      not is_binary(sha) ->
        []

      sha == base ->
        []

      MapSet.member?(seen, sha) ->
        []

      not Map.has_key?(lookup, sha) ->
        []

      true ->
        seen = MapSet.put(seen, sha)
        parent = lookup |> Map.get(sha) |> first_parent()
        [sha | walk(parent, base, lookup, seen)]
    end
  end

  # --- Depth → hue ---------------------------------------------------------------

  # Only non-negative integer depths pass through; nil/floats/negative/garbage
  # all fold to 0 so the hue stays deterministic for odd agent maps.
  defp normalize_depth(depth) when is_integer(depth) and depth >= 0, do: depth
  defp normalize_depth(_), do: 0

  defp depth_color(depth) do
    hue = Integer.mod(round(depth * 137.508) + 265, 360)
    ThemeColor.hsl_to_hex(hue, 70, 54)
  end

  # --- DOM ids ---------------------------------------------------------------------

  # A deterministic, DOM-safe id derived ONLY from the repo key: the key
  # sanitized to `[A-Za-z0-9_-]` plus a stable hash suffix that disambiguates
  # keys which sanitize to the same slug (or share a display name). Never
  # random, never counter-based — the id is identical across refreshes, so
  # LiveView can patch the graph incrementally.
  defp repo_dom_id(repo_key) do
    slug =
      repo_key
      |> stringify()
      |> String.replace(~r/[^A-Za-z0-9_-]/, "-")

    "commit-graph-repo-" <> slug <> "-" <> Integer.to_string(:erlang.phash2(repo_key))
  end

  # Total key → string conversion (never raises on unexpected terms). Shared
  # with the `CommitGraph.Interleave` / `CommitGraph.Edges` helpers (used for
  # no-op stub shas and the agent-edge sort key).
  @doc false
  def stringify(key) when is_binary(key), do: key
  @doc false
  def stringify(key) when is_atom(key), do: Atom.to_string(key)
  @doc false
  def stringify(key) when is_integer(key), do: Integer.to_string(key)
  @doc false
  def stringify(key), do: inspect(key)
end
