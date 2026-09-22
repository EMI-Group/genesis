defmodule EvoDashWeb.AgentsLive.CommitGraph do
  @moduledoc """
  Pure view-model assembly for the Agents page's TEMPORAL (git commit history)
  view — a HORIZONTAL AGENT SWIMLANE: one row per agent, one column per commit,
  oldest on the left, newest on the right.

  The module is deliberately PURE — no I/O, no socket, no processes — mirroring
  the sibling support modules (`HistoryGate`, `OptimisticMessages`,
  `PendingEvents`). It is fed:

    - `raw_by_repo` — the per-repo commit graph fetched by the node-aware
      commit RPC (`%{repo_key => %{commits: [commit], refs: %{sha => [name]}}}`),
      with `commits` in `git log` order; each commit is an atom-keyed map
      (`:sha, :short_sha, :message, :author_name, :date, :parents`, where
      `:parents` is the full SHA list, `[]` for a root); and
    - `agents` — the page's already-loaded rich agent maps
      (`EvoDashWeb.AgentsLive.LoadData.build_agents/2`).

  Every commit/agent field is read through `Map.get/2` and every function is
  TOTAL: odd input shapes degrade to empty columns and lanes instead of raising.

  ## Columns (the horizontal time axis)

  The columns are the UNION of every agent's first-parent progress path, so the
  timeline shows exactly the commits the agents worked on, shared between them.
  They are ordered OLDEST → NEWEST (left → right) by the chronological key
  `{rank, date_unix, sha}` ASCENDING:

    - `rank` is a memoized TOPOLOGICAL rank over the FETCHED parents: a commit
      with no fetched parent ranks `0`, otherwise `1 + max(rank(parent))` over
      its fetched parents. A memoized DFS carrying a `visiting` set makes a
      malformed parent cycle terminate — a revisit returns the memoized rank
      when there is one, else `0`.
    - `date_unix` is the commit date in Unix seconds (`0` when absent or not a
      `%DateTime{}`).
    - `sha` is the deterministic final tie-break.

  Ranking rather than the fetch order matters: the fetch concatenates one
  `git log` per agent range, so the input list is not globally newest-first,
  and `%DateTime{}` structs must never be compared directly (term order looks
  at `day` before `month`/`year`).

  ## Lanes (the vertical agent axis)

  One lane per agent, ordered by `{depth, id}` ASCENDING so the row order
  matches the agent tree. A lane's `markers` are its progress-path commits that
  are also columns, ascending by column: each carries the commit metadata plus
  `tip?: true` for the agent's own `current_commit`. `from_column`/`to_column`
  span the markers (nil when the lane has none) and `tip_column` is the
  `current_commit`'s column (nil when that commit is not a column).

  ## Progress path (first-parent walk)

  Each agent's path is a first-parent walk from its `current_commit` backwards,
  stopping at (excluding) its `base_commit`, at a sha absent from the fetched
  graph, or at an already-seen sha (cycle guard); the result is
  NEWEST → OLDEST.

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
        column_count: non_neg_integer(), commit_count: non_neg_integer(),
        columns: [%{sha:, short_sha:, message:, author_name:, date:, refs:}],
        lanes: [%{agent: %{id:, task_local_id:, status:, depth:, color:},
                  from_column:, to_column:, tip_column:, markers: [...]}]
      }

  `columns` is ordered OLDEST → NEWEST (left → right) and `message` is the
  commit message's first line only; `lanes` is ordered by `{depth, id}`
  ascending (rows top → bottom).
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoGit.Platform
  alias EvoDashWeb.ThemeColor

  # Marker radii, still consumed by the SVG renderer.
  @dot_r 4.5
  @ring_r 8.5

  @doc "Commit-dot radius — the single source of truth for the SVG renderer."
  @spec dot_r :: float()
  def dot_r, do: @dot_r

  @doc "Agent-tip ring radius — the single source of truth for the SVG renderer."
  @spec ring_r :: float()
  def ring_r, do: @ring_r

  @typedoc """
  One chronological column (commit) of the timeline, ordered OLDEST → NEWEST
  (left → right).
  """
  @type column_view :: %{
          sha: String.t(),
          short_sha: String.t(),
          message: String.t(),
          author_name: String.t() | nil,
          date: DateTime.t() | nil,
          refs: [String.t()]
        }

  @typedoc """
  One agent marker on the timeline. `column` is its index into
  `repo_view.columns`; `tip?: true` marks the agent's own `current_commit`.
  """
  @type marker_view :: %{
          column: non_neg_integer(),
          sha: String.t(),
          short_sha: String.t(),
          message: String.t(),
          author_name: String.t() | nil,
          date: DateTime.t() | nil,
          refs: [String.t()],
          tip?: boolean()
        }

  @typedoc """
  One agent row of the swimlane. `from_column`/`to_column` bound the lane's
  markers (nil when it has none), `tip_column` is the column of the agent's
  `current_commit` (nil when that commit is not a column), and `markers` is
  ascending by `:column`.
  """
  @type lane_view :: %{
          agent: %{
            id: term(),
            task_local_id: term(),
            status: term(),
            depth: non_neg_integer(),
            color: String.t()
          },
          from_column: non_neg_integer() | nil,
          to_column: non_neg_integer() | nil,
          tip_column: non_neg_integer() | nil,
          markers: [marker_view()]
        }

  @typedoc """
  The swimlane view model for one repository group, ready to render.
  """
  @type repo_view :: %{
          repo_key: term(),
          repo_dom_id: String.t(),
          repo_name: String.t(),
          column_count: non_neg_integer(),
          commit_count: non_neg_integer(),
          columns: [column_view()],
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
  Builds the per-repo swimlane view model.

  `raw_by_repo` maps a repo grouping key to the fetched commit graph
  (`%{commits: [commit], refs: %{sha => [name]}}`); a key that is absent (or a
  repo whose fetch failed) yields empty columns and lanes.

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
    # Filtered to ADDRESSABLE commits (a map with a non-empty binary :sha) and
    # de-duplicated by sha — git log never returns duplicates, but a malformed
    # payload must not produce ambiguous lookups either.
    commits = addressable_commits(raw)
    lookup = commit_lookup(commits)
    refs = refs_map(raw)

    ordered = ordered_agents(repo_agents)

    paths =
      Enum.map(ordered, fn agent ->
        walk(
          Map.get(agent, :current_commit),
          Map.get(agent, :base_commit),
          lookup,
          MapSet.new()
        )
      end)

    columns = build_columns(paths, lookup, refs)
    index = column_index(columns)

    lanes =
      ordered
      |> Enum.zip(paths)
      |> Enum.map(fn {agent, path} -> lane_view(agent, path, lookup, refs, index) end)

    %{
      repo_key: repo_key,
      repo_dom_id: repo_dom_id(repo_key),
      repo_name: repo_display_name(repo_key),
      column_count: length(columns),
      commit_count: length(columns),
      columns: columns,
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
  # page sorts them in — so the row order and every color/lane assignment stay
  # deterministic across refreshes.
  defp ordered_agents(repo_agents) do
    Enum.sort_by(List.wrap(repo_agents), fn agent ->
      {normalize_depth(Map.get(agent, :depth)), Map.get(agent, :id)}
    end)
  end

  # --- Columns (chronological union of the agents' progress paths) ----------

  defp build_columns(paths, lookup, refs) do
    ranks = ranks(lookup)

    paths
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort_by(fn sha ->
      {Map.get(ranks, sha, 0), date_unix(Map.get(lookup, sha)), sha}
    end)
    |> Enum.map(fn sha -> column_view(Map.get(lookup, sha), sha, refs) end)
  end

  defp column_index(columns) do
    columns
    |> Enum.with_index()
    |> Map.new(fn {column, index} -> {column.sha, index} end)
  end

  defp column_view(commit, sha, refs) do
    %{
      sha: sha,
      short_sha: short_sha(commit, sha),
      message: first_line(Map.get(commit, :message)),
      author_name: author_name(commit),
      date: date_of(commit),
      refs: refs_for(refs, sha)
    }
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

  # --- Lanes (one row per agent) --------------------------------------------

  defp lane_view(agent, path, lookup, refs, index) do
    depth = normalize_depth(Map.get(agent, :depth))
    current = Map.get(agent, :current_commit)

    markers =
      path
      |> Enum.flat_map(fn sha ->
        case Map.fetch(index, sha) do
          {:ok, column} ->
            commit = Map.get(lookup, sha)
            [marker_view(commit, sha, column, refs, current)]

          :error ->
            []
        end
      end)
      |> Enum.sort_by(& &1.column)

    %{
      agent: %{
        id: Map.get(agent, :id),
        task_local_id: Map.get(agent, :task_local_id),
        status: Map.get(agent, :status),
        depth: depth,
        color: depth_color(depth)
      },
      from_column: min_column(markers),
      to_column: max_column(markers),
      tip_column: column_of(index, current),
      markers: markers
    }
  end

  defp marker_view(commit, sha, column, refs, current) do
    %{
      column: column,
      sha: sha,
      short_sha: short_sha(commit, sha),
      message: first_line(Map.get(commit, :message)),
      author_name: author_name(commit),
      date: date_of(commit),
      refs: refs_for(refs, sha),
      tip?: sha == current
    }
  end

  defp min_column([]), do: nil
  defp min_column(markers), do: markers |> Enum.map(& &1.column) |> Enum.min()

  defp max_column([]), do: nil
  defp max_column(markers), do: markers |> Enum.map(& &1.column) |> Enum.max()

  defp column_of(index, sha) do
    case Map.fetch(index, sha) do
      {:ok, column} -> column
      :error -> nil
    end
  end

  # --- Commit metadata --------------------------------------------------------

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
