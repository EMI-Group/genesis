defmodule EvoDashWeb.AgentsLive.CommitGraph do
  @moduledoc """
  Pure view-model assembly for the Agents page's TEMPORAL (git commit history)
  view — a VERTICAL, commit-centric DAG: ONE VISIBLE ROW per commit, ordered
  top → bottom by agent depth, plus a left GUTTER COLUMN per node so the
  renderer can draw the child → parent edges between the rows (the
  GitKraken/GitLen-style graph shape).

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
      `:base_commit` and `:current_commit`.

  Every commit/agent field is read through `Map.get/2` and every function is
  TOTAL: odd input shapes degrade to empty nodes/edges/agents instead of raising.

  ## Nodes (one row per commit)

  One node per ADDRESSABLE fetched commit (a map with a non-empty binary
  `:sha`), de-duplicated by sha, PLUS one synthesized `kind: :base` node per
  distinct agent `:base_commit` absent from the fetched commits (see
  "Base synthesis" below).

  ## Rows — the vertical order

  `nodes` is ordered TOP → BOTTOM (ascending `row`, `0` = top) and every `row`
  is UNIQUE, so `row_count == node_count` and the rows are exactly
  `0 .. node_count - 1`.

  Rows are grouped by OWNING AGENT: every node an agent owns is CONTIGUOUS and
  the groups appear in the agent order, so the owner depth is NON-DECREASING
  down the rows.

  The agent order — shared with the `agents` list — is ascending
  `{depth, task_local_id, agent_id}`: `depth` is normalized (nil/negative/
  non-integer → `0`, for both the sort and the emitted value), `task_local_id`
  is the agent's slot id (it may be `nil` for odd maps — Erlang term order
  places `nil` after every integer, which stays deterministic) and the
  `agent_id` term is the FINAL tie-break, so the order never flaps between
  refreshes.

  Within one agent's group the owned nodes are ordered along ANCESTRY:

    1. a synthesized `:base` node first — it is the group's fork point, older
       than anything the agent built — then
    2. the agent's real commits by ascending first-parent topological rank
       (oldest → newest), ties broken by `sha`.

  Along a first-parent progress path the rank increases monotonically in a
  linear history, so this is exactly that path oldest → newest; merged-in side
  commits and the inherited fork point land at their own rank. `row` is the
  node's absolute 0-based position in this flattened sequence.

  ## Gutter columns

  A node's `column` is its GUTTER COLUMN (left → right, `0` = leftmost). The
  assignment is `column = depth` — the NODE's depth, i.e. its OWNER agent's
  normalized depth. Every node owned by an agent of the same depth therefore
  shares a column, so a root agent's chain sits in the leftmost column and each
  deeper recursion step shifts one column right (a staircase). Columns may be
  SPARSE: a depth that owns no node leaves its column empty. `column_count` is
  `max(column) + 1` over the emitted nodes, and `1` when the repo has no nodes.

  There is deliberately NO one-column-per-agent / per-agent band concept:
  columns carry the graph geometry, the row grouping carries agent ownership.
  The renderer ROUTES the line/curve between edge endpoints — the model only
  supplies the integers.

  ## Base synthesis

  The fetch covers `git log base..tip` per agent, which EXCLUDES the base
  commit, so a fork point no agent committed on has no fetched commit to hang
  an edge on. Every distinct agent `:base_commit` absent from the fetched
  commits is therefore synthesized as a `kind: :base` node (`message: ""`, no
  author, no date, no refs), so the child → parent edge into the fork point can
  be drawn. A fetched commit that equals some agent's `:base_commit` stays a
  NORMAL `:commit` node — it is never duplicated.

  ## Edges (child → parent)

  For every real commit node and every one of its `:parents` present in the node
  set (fetched commits ∪ synthesized base shas), one edge is emitted from the
  child to that parent, carrying both endpoints' `{column, row}`: `kind: :parent`
  for the FIRST present parent in the commit's `:parents` order (the first-parent
  lineage) and `kind: :merge` for every other present parent (a folded side
  branch). Parents absent from the node set produce no edge; identical
  `{from_sha, to_sha}` edges are de-duplicated; the `owner_id` is the CHILD
  node's owner. A base node has no parents, so it is always an edge target.
  Edges are sorted by `{from_sha, to_sha}` so the list is stable between
  refreshes.

  ## Ownership (a single owner per node)

  A node's `depth` is its OWNER's depth, and owner groups are depth-ordered, so
  the depth is monotonic down the rows. Ownership keeps ONE owner per node:

    - a commit on at least one agent's progress path belongs to the agent with
      the MAXIMUM depth (ties broken by the SMALLEST agent-order index), so a
      shared commit lands with the deepest agent that worked on it;
    - a fetched commit on NO path (a merged-in side commit) inherits the owner
      of the commit it is the FIRST parent of — the deepest such child, ties by
      smallest index — falling back to the first agent when it has no owned
      child. Commits are resolved in DESCENDING rank order, so children are
      owned before their parents;
    - a synthesized base node belongs to the agent with the SMALLEST
      `{depth, index}` among the agents forked from it, so a shared task base
      lands with the shallowest root agent.

  A repo without agents has no owners and therefore no nodes, edges or agents.

  ## Progress path (first-parent walk)

  Each agent's path is a first-parent walk from its `current_commit` backwards,
  stopping at (excluding) its `base_commit`, at a sha absent from the fetched
  graph, or at an already-seen sha (cycle guard); the result is
  NEWEST → OLDEST.

  ## Start / end annotations

  Every node carries the agent ids that fork from it (`start_ids`, from
  `:base_commit`) and the agent ids that tip at it (`end_ids`, from
  `:current_commit`), in agent order, so a group's endpoints can be marked
  without re-scanning the agent list. A node can be a start for one agent and an
  end for another.

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
        agents: [%{agent_id:, task_local_id:, status:, depth:, color:,
                   start_sha:, end_sha:, ended:}]
      }

  `nodes` is sorted top → bottom (ascending `row`), `edges` by
  `{from_sha, to_sha}` and `agents` by `{depth, task_local_id, agent_id}` — all
  deterministic, so LiveView can patch the graph incrementally instead of
  re-rendering it on every refresh. The module emits no rendering concerns: no
  DOM ids beyond `repo_dom_id`, no colors beyond `agent.color`, no SVG geometry.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoGit.Platform
  alias EvoDashWeb.ThemeColor

  @typedoc """
  One commit ROW of the vertical graph — a fetched commit (`kind: :commit`) or a
  synthesized fork point (`kind: :base`). `row` is the unique top → bottom
  position, `column` the gutter column, `depth` the OWNER agent's depth,
  `owner_id` the owning agent's id and `start_ids`/`end_ids` the agent ids that
  fork from / tip at this sha.
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
          kind: :commit | :base,
          owner_id: term() | nil,
          start_ids: [term()],
          end_ids: [term()]
        }

  @typedoc """
  One child → parent edge. The `from_*` fields are the child node's gutter
  position, the `to_*` fields the parent's; `kind` is `:parent` for the first
  present parent, `:merge` for every other present parent, and `owner_id` is
  the CHILD node's owner.
  """
  @type edge_view :: %{
          from_sha: String.t(),
          to_sha: String.t(),
          from_column: non_neg_integer(),
          from_row: non_neg_integer(),
          to_column: non_neg_integer(),
          to_row: non_neg_integer(),
          kind: :parent | :merge,
          owner_id: term() | nil
        }

  @typedoc """
  One agent of the graph — metadata only (there are no per-agent row bands).
  `depth` is normalized, `color` the depth hue, `start_sha`/`end_sha` the
  agent's `:base_commit`/`:current_commit`, and `ended` is true for an in-session
  retained agent that is no longer live.
  """
  @type agent_view :: %{
          agent_id: term(),
          task_local_id: term(),
          status: term(),
          depth: non_neg_integer(),
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
    ranks = ranks(lookup)

    paths =
      Enum.map(ordered, fn agent ->
        walk(
          Map.get(agent, :current_commit),
          Map.get(agent, :base_commit),
          lookup,
          MapSet.new()
        )
      end)

    {start_ids, end_ids} = annotations(ordered)

    graph = %{
      commits: commits,
      refs: refs,
      ranks: ranks,
      base_shas: base_shas(ordered, lookup),
      owners: node_owners(commits, ordered, paths, ranks),
      base_owners: base_owners(ordered, lookup),
      start_ids: start_ids,
      end_ids: end_ids
    }

    nodes = build_nodes(graph, ordered)
    edges = build_edges(commits, nodes)
    columns = Enum.map(nodes, & &1.column)

    %{
      node_count: length(nodes),
      edge_count: length(edges),
      row_count: length(nodes),
      column_count: if(columns == [], do: 1, else: Enum.max(columns) + 1),
      nodes: nodes,
      edges: edges,
      agents: build_agents(ordered)
    }
  end

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

  # --- Agents ---------------------------------------------------------------

  # Agents are folded in ascending `{depth, task_local_id, id}` order — the
  # order the `agents` list and every row group use — so ownership, columns and
  # colors stay deterministic across refreshes.
  defp ordered_agents(repo_agents) do
    Enum.sort_by(List.wrap(repo_agents), fn agent ->
      {normalize_depth(Map.get(agent, :depth)), Map.get(agent, :task_local_id),
       Map.get(agent, :id)}
    end)
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
  # and depth (which is also its gutter column) without rescanning the list.
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

  # --- Nodes (one row per commit) -------------------------------------------

  defp build_nodes(graph, ordered) do
    meta = index_meta(ordered)

    real =
      Enum.map(graph.commits, fn commit ->
        sha = Map.get(commit, :sha)

        internal_node(
          sha: sha,
          short_sha: short_sha(commit, sha),
          message: first_line(Map.get(commit, :message)),
          author_name: author_name(commit),
          date: date_of(commit),
          refs: refs_for(graph.refs, sha),
          kind: :commit,
          rank: Map.get(graph.ranks, sha, 0),
          owner_index: Map.get(graph.owners, sha, 0),
          start_ids: Map.get(graph.start_ids, sha, []),
          end_ids: Map.get(graph.end_ids, sha, []),
          meta: meta
        )
      end)

    base =
      Enum.map(graph.base_shas, fn sha ->
        internal_node(
          sha: sha,
          short_sha: String.slice(sha, 0, 8),
          message: "",
          author_name: nil,
          date: nil,
          refs: [],
          kind: :base,
          # A fork point predates every real commit, so it always sorts first in
          # its agent's group.
          rank: -1,
          owner_index: Map.get(graph.base_owners, sha, 0),
          start_ids: Map.get(graph.start_ids, sha, []),
          end_ids: Map.get(graph.end_ids, sha, []),
          meta: meta
        )
      end)

    owned = Enum.group_by(real ++ base, & &1.owner_index)

    ordered
    |> Enum.with_index()
    |> Enum.flat_map(fn {_agent, index} ->
      owned |> Map.get(index, []) |> Enum.sort_by(& &1.order_key)
    end)
    |> Enum.with_index()
    |> Enum.map(fn {node, row} -> node_view(node, row) end)
  end

  defp internal_node(opts) do
    {owner_id, depth} = owner_meta(Keyword.fetch!(opts, :meta), opts[:owner_index])
    kind = Keyword.fetch!(opts, :kind)
    sha = Keyword.fetch!(opts, :sha)

    %{
      sha: sha,
      short_sha: Keyword.fetch!(opts, :short_sha),
      message: Keyword.fetch!(opts, :message),
      author_name: Keyword.fetch!(opts, :author_name),
      date: Keyword.fetch!(opts, :date),
      refs: Keyword.fetch!(opts, :refs),
      kind: kind,
      owner_id: owner_id,
      owner_index: opts[:owner_index],
      depth: depth,
      # Base nodes first (kind_rank 0), then ascending ancestry rank, then sha.
      order_key: {kind_rank(kind), Keyword.fetch!(opts, :rank), sha},
      start_ids: Keyword.fetch!(opts, :start_ids),
      end_ids: Keyword.fetch!(opts, :end_ids)
    }
  end

  defp kind_rank(:base), do: 0
  defp kind_rank(_kind), do: 1

  # The gutter column IS the node's depth (its owner's depth).
  defp node_view(node, row) do
    %{
      sha: node.sha,
      short_sha: node.short_sha,
      message: node.message,
      author_name: node.author_name,
      date: node.date,
      refs: node.refs,
      row: row,
      column: node.depth,
      depth: node.depth,
      kind: node.kind,
      owner_id: node.owner_id,
      start_ids: node.start_ids,
      end_ids: node.end_ids
    }
  end

  # --- Edges (child → parent) -----------------------------------------------

  defp build_edges(commits, nodes) do
    coords = Map.new(nodes, fn node -> {node.sha, {node.column, node.row}} end)
    owners = Map.new(nodes, fn node -> {node.sha, node.owner_id} end)

    commits
    |> Enum.flat_map(fn commit ->
      sha = Map.get(commit, :sha)

      case Map.fetch(coords, sha) do
        {:ok, {from_column, from_row}} ->
          commit
          |> parents_list()
          |> Enum.uniq()
          |> Enum.filter(&Map.has_key?(coords, &1))
          |> Enum.with_index()
          |> Enum.map(fn {parent_sha, position} ->
            {to_column, to_row} = Map.fetch!(coords, parent_sha)

            %{
              from_sha: sha,
              to_sha: parent_sha,
              from_column: from_column,
              from_row: from_row,
              to_column: to_column,
              to_row: to_row,
              kind: if(position == 0, do: :parent, else: :merge),
              owner_id: Map.get(owners, sha)
            }
          end)

        :error ->
          []
      end
    end)
    |> Enum.uniq_by(fn edge -> {edge.from_sha, edge.to_sha} end)
    |> Enum.sort_by(fn edge -> {edge.from_sha, edge.to_sha} end)
  end

  # --- Agents view ----------------------------------------------------------

  defp build_agents(ordered) do
    Enum.map(ordered, fn agent ->
      depth = normalize_depth(Map.get(agent, :depth))

      %{
        agent_id: Map.get(agent, :id),
        task_local_id: Map.get(agent, :task_local_id),
        status: Map.get(agent, :status),
        depth: depth,
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

  # sha → the agent-order index that owns it: the deepest agent whose progress
  # path contains the commit, plus — for merged-in side commits — the index
  # inherited from the first child.
  defp node_owners(commits, ordered, paths, ranks) do
    owned = path_owners(ordered, paths)
    children = children_index(commits)
    scores = index_scores(ordered)

    commits
    |> Enum.reject(fn commit -> Map.has_key?(owned, Map.get(commit, :sha)) end)
    |> Enum.sort_by(fn commit ->
      {Map.get(ranks, Map.get(commit, :sha), 0), date_unix(commit), Map.get(commit, :sha)}
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
  # parent of — the deepest such child (ties on the smallest index) — and falls
  # back to the first agent when no owned child claims it.
  defp inherited_index(children, commit, owners, scores) do
    children
    |> Map.get(Map.get(commit, :sha), [])
    |> Enum.flat_map(fn child ->
      case Map.fetch(owners, child) do
        {:ok, index} -> [Map.get(scores, index, {0, index})]
        :error -> []
      end
    end)
    |> case do
      [] -> 0
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

  # --- Ranks ------------------------------------------------------------------

  # Memoized topological ranks over the FETCHED parents: no fetched parent → 0,
  # otherwise 1 + max(rank(parent)). Ranking rather than the fetch order matters:
  # the fetch concatenates one `git log` per agent range, so the input list is
  # not globally newest-first, and `%DateTime{}` structs must never be compared
  # directly (term order looks at `day` before `month`/`year`). The `visiting`
  # set makes a malformed parent cycle terminate — a revisit returns the
  # memoized rank when there is one, else 0 — so a cyclic payload can never
  # recurse forever.
  defp ranks(lookup) do
    lookup
    |> Map.keys()
    |> Enum.reduce(%{}, fn sha, memo ->
      {memo, _rank} = rank(sha, lookup, memo, MapSet.new())
      memo
    end)
  end

  defp rank(sha, lookup, memo, visiting) do
    case Map.fetch(memo, sha) do
      {:ok, rank} ->
        {memo, rank}

      :error ->
        if MapSet.member?(visiting, sha) do
          {memo, 0}
        else
          parents = present_parents(Map.get(lookup, sha), lookup)
          visiting = MapSet.put(visiting, sha)

          {memo, {max_parent_rank, parent_count}} =
            Enum.reduce(parents, {memo, {0, 0}}, fn parent, {memo, {max, count}} ->
              {memo, parent_rank} = rank(parent, lookup, memo, visiting)
              {memo, {max(max, parent_rank), count + 1}}
            end)

          rank = if parent_count == 0, do: 0, else: 1 + max_parent_rank
          {Map.put(memo, sha, rank), rank}
        end
    end
  end

  defp present_parents(commit, lookup) do
    parents_list(commit) |> Enum.uniq() |> Enum.filter(&Map.has_key?(lookup, &1))
  end

  defp parents_list(commit) do
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

  # --- Commit metadata --------------------------------------------------------

  defp sha_or_nil(sha) when is_binary(sha) and sha != "", do: sha
  defp sha_or_nil(_sha), do: nil

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

  # Total key → string conversion (never raises on unexpected terms).
  defp stringify(key) when is_binary(key), do: key
  defp stringify(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify(key) when is_integer(key), do: Integer.to_string(key)
  defp stringify(key), do: inspect(key)
end
