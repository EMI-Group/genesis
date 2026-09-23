defmodule EvoDashWeb.AgentsLive.CommitGraph do
  @moduledoc """
  Pure view-model assembly for the Agents page's TEMPORAL (git commit history)
  view — a COMMIT-CENTRIC HORIZONTAL DAG: one node per commit, one edge per
  child → parent link present in the fetched graph, ancestry flowing
  left → right, with one horizontal LANE (band) per agent.

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
  TOTAL: odd input shapes degrade to empty nodes/edges/lanes instead of raising.

  ## Nodes (the horizontal time axis)

  One node per ADDRESSABLE fetched commit (a map with a non-empty binary
  `:sha`), de-duplicated by sha, PLUS one synthesized node per distinct agent
  `:base_commit` absent from the fetched commits.

  A node's `x` is its grid COLUMN (left → right, oldest → newest):

    - a real commit's `x` is a memoized TOPOLOGICAL rank over the FETCHED
      parents: a commit with no fetched parent ranks `0`, otherwise
      `1 + max(rank(parent))`. A memoized DFS carrying a `visiting` set makes a
      malformed parent cycle terminate — a revisit returns the memoized rank
      when there is one, else `0`. Ranking rather than the fetch order matters:
      the fetch concatenates one `git log` per agent range, so the input list is
      not globally newest-first, and `%DateTime{}` structs must never be
      compared directly (term order looks at `day` before `month`/`year`).
    - a synthesized base node gets `x = min_real_rank - 1` — one column left of
      the oldest real commits (`-1` when the repo has no real commits).

  A node's `y` is its grid ROW: the index of the agent LANE it belongs to.

  ## Base synthesis

  The fetch covers `git log base..tip` per agent, which EXCLUDES the base
  commit, so a fork point no agent committed on has no fetched commit to hang
  an edge on. Every distinct agent `:base_commit` absent from the fetched
  commits is therefore synthesized as a `kind: :base` node (`message: ""`, no
  author, no date, no refs), so the child → parent edge into the fork point can
  be drawn. A fetched commit that equals some agent's `:base_commit` stays a
  NORMAL `:commit` node — it is never duplicated.

  ## Edges (child → parent)

  For every real commit node and every one of its `:parents` present in the
  node set (fetched commits ∪ synthesized base shas), one edge is emitted from
  the child to that parent: `kind: :parent` for the FIRST present parent in the
  commit's `:parents` order (the first-parent lineage) and `kind: :merge` for
  every other present parent (a folded side branch). Parents absent from the
  node set produce no edge; identical `{from_sha, to_sha}` edges are
  de-duplicated. A base node has no parents, so it is always an edge target.

  ## Lanes (the vertical agent axis)

  One lane per agent, ordered by `{depth, id}` ASCENDING so the row order
  matches the agent tree; a lane's `y` is its index. Each lane reports the span
  of the nodes it OWNS (`x_start`/`x_end`, nil when it owns none), how many
  nodes it owns (`node_count`) and its `start_sha` (`:base_commit`) /
  `end_sha` (`:current_commit`).

  Node ownership (`node.owner_id` + `node.y`):

    - a commit on at least one agent's progress path belongs to the agent with
      the MAXIMUM depth (ties broken by the SMALLEST lane index), so a shared
      commit lands in the deepest lane that worked on it;
    - a fetched commit on NO path (a merged-in side commit) inherits the owner
      of the commit it is the FIRST parent of — the deepest such child, ties by
      smallest lane index — falling back to the first lane when it has no owned
      child. Commits are resolved in DESCENDING rank order, so children are
      owned before their parents;
    - a synthesized base node belongs to the agent with the SMALLEST
      `{depth, lane index}` among the agents forked from it, so a shared task
      base lands in the shallowest root lane.

  A repo without agents has no lanes and therefore no nodes, edges or spans.

  ## Progress path (first-parent walk)

  Each agent's path is a first-parent walk from its `current_commit` backwards,
  stopping at (excluding) its `base_commit`, at a sha absent from the fetched
  graph, or at an already-seen sha (cycle guard); the result is
  NEWEST → OLDEST.

  ## Start / end annotations

  Every node carries the agent ids that fork from it (`start_ids`, from
  `:base_commit`) and the agent ids that tip at it (`end_ids`, from
  `:current_commit`), in lane order, so a lane's endpoints can be marked without
  re-scanning the agent list. A node can be a start for one agent and an end for
  another.

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
        lane_count: non_neg_integer(), row_count: non_neg_integer(),
        max_x: integer(),
        nodes: [%{sha:, short_sha:, message:, author_name:, date:, refs:,
                  x:, y:, kind:, owner_id:, start_ids:, end_ids:}],
        edges: [%{from_sha:, to_sha:, from:, to:, kind:, owner_id:}],
        lanes: [%{agent_id:, task_local_id:, status:, depth:, color:, y:,
                  x_start:, x_end:, node_count:, start_sha:, end_sha:}]
      }

  `nodes` is sorted by `{x, y, sha}`, `edges` by `{from_sha, to_sha}` and
  `lanes` by `{depth, id}` — all deterministic, so LiveView can patch the graph
  incrementally instead of re-rendering it on every refresh. The module emits no
  rendering concerns: no DOM ids beyond `repo_dom_id`, no colors beyond
  `lane.color`, no SVG geometry.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoGit.Platform
  alias EvoDashWeb.ThemeColor

  @typedoc """
  One commit of the graph — a fetched commit (`kind: :commit`) or a synthesized
  fork point (`kind: :base`). `x` is the grid column (the topological rank),
  `y` the owning lane's row, `owner_id` the owning agent's id, and
  `start_ids`/`end_ids` the agent ids that fork from / tip at this sha.
  """
  @type node_view :: %{
          sha: String.t(),
          short_sha: String.t(),
          message: String.t(),
          author_name: String.t() | nil,
          date: DateTime.t() | nil,
          refs: [String.t()],
          x: integer(),
          y: non_neg_integer(),
          kind: :commit | :base,
          owner_id: term() | nil,
          start_ids: [term()],
          end_ids: [term()]
        }

  @typedoc """
  One child → parent edge. `from`/`to` are the `{x, y}` grid coordinates of the
  child/parent nodes and `kind` is `:parent` for the first present parent,
  `:merge` for every other present parent.
  """
  @type edge_view :: %{
          from_sha: String.t(),
          to_sha: String.t(),
          from: {integer(), non_neg_integer()},
          to: {integer(), non_neg_integer()},
          kind: :parent | :merge,
          owner_id: term() | nil
        }

  @typedoc """
  One agent lane (a horizontal band of the graph). `y` is the lane index,
  `x_start`/`x_end` bound the nodes the lane owns (nil when it owns none), and
  `start_sha`/`end_sha` are the agent's `:base_commit`/`:current_commit`.
  """
  @type lane_view :: %{
          agent_id: term(),
          task_local_id: term(),
          status: term(),
          depth: non_neg_integer(),
          color: String.t(),
          y: non_neg_integer(),
          x_start: integer() | nil,
          x_end: integer() | nil,
          node_count: non_neg_integer(),
          start_sha: String.t() | nil,
          end_sha: String.t() | nil
        }

  @typedoc """
  The commit-DAG view model for one repository group, ready to render.
  """
  @type repo_view :: %{
          repo_key: term(),
          repo_dom_id: String.t(),
          repo_name: String.t(),
          node_count: non_neg_integer(),
          edge_count: non_neg_integer(),
          lane_count: non_neg_integer(),
          row_count: non_neg_integer(),
          max_x: integer(),
          nodes: [node_view()],
          edges: [edge_view()],
          lanes: [lane_view()]
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
  Builds the per-repo commit-DAG view model.

  `raw_by_repo` maps a repo grouping key to the fetched commit graph
  (`%{commits: [commit], refs: %{sha => [name]}}`); a key that is absent (or a
  repo whose fetch failed) yields empty nodes, edges and lanes.

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

  # No agents means no lanes, and a lane is the only thing that can own a node —
  # so a repo without agents has no graph at all.
  defp empty_body do
    %{
      node_count: 0,
      edge_count: 0,
      lane_count: 0,
      row_count: 0,
      max_x: 0,
      nodes: [],
      edges: [],
      lanes: []
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
    lanes = build_lanes(ordered, nodes)

    x_values = Enum.map(nodes, & &1.x)

    %{
      node_count: length(nodes),
      edge_count: length(edges),
      lane_count: length(lanes),
      row_count: length(lanes),
      max_x: if(x_values == [], do: 0, else: Enum.max(x_values)),
      nodes: nodes,
      edges: edges,
      lanes: lanes
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

  # Agents are folded in ascending `{depth, id}` order — the same order the
  # page sorts them in — so the lane order and every color/ownership assignment
  # stay deterministic across refreshes.
  defp ordered_agents(repo_agents) do
    Enum.sort_by(List.wrap(repo_agents), fn agent ->
      {normalize_depth(Map.get(agent, :depth)), Map.get(agent, :id)}
    end)
  end

  # Per-lane ownership scores, keyed by lane index: `{-depth, index}` sorts the
  # deepest lane first and breaks ties on the smallest lane index.
  defp index_scores(ordered) do
    ordered
    |> Enum.with_index()
    |> Map.new(fn {agent, index} ->
      {index, {-normalize_depth(Map.get(agent, :depth)), index}}
    end)
  end

  # --- Nodes ---

  defp build_nodes(graph, ordered) do
    base_x = min_real_x(graph.ranks) - 1

    real =
      Enum.map(graph.commits, fn commit ->
        sha = Map.get(commit, :sha)
        index = Map.get(graph.owners, sha, 0)

        %{
          sha: sha,
          short_sha: short_sha(commit, sha),
          message: first_line(Map.get(commit, :message)),
          author_name: author_name(commit),
          date: date_of(commit),
          refs: refs_for(graph.refs, sha),
          x: Map.get(graph.ranks, sha, 0),
          y: index,
          kind: :commit,
          owner_id: owner_id(ordered, index),
          start_ids: Map.get(graph.start_ids, sha, []),
          end_ids: Map.get(graph.end_ids, sha, [])
        }
      end)

    base =
      Enum.map(graph.base_shas, fn sha ->
        index = Map.get(graph.base_owners, sha, 0)

        %{
          sha: sha,
          short_sha: String.slice(sha, 0, 8),
          message: "",
          author_name: nil,
          date: nil,
          refs: [],
          x: base_x,
          y: index,
          kind: :base,
          owner_id: owner_id(ordered, index),
          start_ids: Map.get(graph.start_ids, sha, []),
          end_ids: Map.get(graph.end_ids, sha, [])
        }
      end)

    Enum.sort_by(real ++ base, fn node -> {node.x, node.y, node.sha} end)
  end

  # The minimum topological rank over the FETCHED commits — `0` when the repo
  # has no real commit at all, which puts a lone base node at `x = -1`.
  defp min_real_x(ranks) do
    ranks |> Map.values() |> Enum.min(fn -> 0 end)
  end

  defp owner_id(ordered, index) do
    case Enum.at(ordered, index) do
      %{} = agent -> Map.get(agent, :id)
      _ -> nil
    end
  end

  # --- Edges (child → parent) -----------------------------------------------

  defp build_edges(commits, nodes) do
    coords = Map.new(nodes, fn node -> {node.sha, {node.x, node.y}} end)
    owners = Map.new(nodes, fn node -> {node.sha, node.owner_id} end)

    commits
    |> Enum.flat_map(fn commit ->
      sha = Map.get(commit, :sha)

      commit
      |> parents_list()
      |> Enum.uniq()
      |> Enum.filter(&Map.has_key?(coords, &1))
      |> Enum.with_index()
      |> Enum.map(fn {parent_sha, position} ->
        %{
          from_sha: sha,
          to_sha: parent_sha,
          from: Map.get(coords, sha),
          to: Map.get(coords, parent_sha),
          kind: if(position == 0, do: :parent, else: :merge),
          owner_id: Map.get(owners, sha)
        }
      end)
    end)
    |> Enum.uniq_by(fn edge -> {edge.from_sha, edge.to_sha} end)
    |> Enum.sort_by(fn edge -> {edge.from_sha, edge.to_sha} end)
  end

  # --- Lanes (one row per agent) --------------------------------------------

  defp build_lanes(ordered, nodes) do
    owned = Enum.group_by(nodes, & &1.y)

    ordered
    |> Enum.with_index()
    |> Enum.map(fn {agent, index} ->
      depth = normalize_depth(Map.get(agent, :depth))
      lane_nodes = Map.get(owned, index, [])
      xs = Enum.map(lane_nodes, & &1.x)

      %{
        agent_id: Map.get(agent, :id),
        task_local_id: Map.get(agent, :task_local_id),
        status: Map.get(agent, :status),
        depth: depth,
        color: depth_color(depth),
        y: index,
        x_start: if(xs == [], do: nil, else: Enum.min(xs)),
        x_end: if(xs == [], do: nil, else: Enum.max(xs)),
        node_count: length(lane_nodes),
        start_sha: sha_or_nil(Map.get(agent, :base_commit)),
        end_sha: sha_or_nil(Map.get(agent, :current_commit))
      }
    end)
  end

  # --- Ownership ------------------------------------------------------------

  # sha → the lane index that owns it: the deepest lane whose progress path
  # contains the commit, plus — for merged-in side commits — the lane inherited
  # from the first child.
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

  # Walks every agent's progress path, keeping the lane with the best ownership
  # score (deepest, ties on the smallest lane index).
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
  # parent of — the deepest such child (ties on the smallest lane index) — and
  # falls back to the first lane when no owned child claims it.
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

  # The SHALLOWEST lane forked from a synthesized base wins it, so a shared task
  # base lands in the root lane rather than in a deep child lane.
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

  # sha → the agent ids that fork from (start) / tip at (end) it, in lane order.
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
  # otherwise 1 + max(rank(parent)). The `visiting` set makes a malformed parent
  # cycle terminate — a revisit returns the memoized rank when there is one,
  # else 0 — so a cyclic payload can never recurse forever.
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
