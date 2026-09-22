defmodule EvoDashWeb.AgentsLive.CommitGraph do
  @moduledoc """
  Pure graph assembly for the Agents page's TEMPORAL (git commit history) view
  — a CLASSIC git graph, `git log --graph` style: SVG dots arranged on lanes,
  connected by straight/cubic edges, with refs and an agent-progress overlay
  (colored dots/edges + rings at agent tips).

  The module is deliberately PURE — no I/O, no socket, no processes — mirroring
  the sibling support modules (`HistoryGate`, `OptimisticMessages`,
  `PendingEvents`). It is fed:

    - `raw_by_repo` — the per-repo commit graph fetched by the node-aware
      commit RPC (`%{repo_key => %{commits: [commit], refs: %{sha => [name]}}}`),
      with `commits` NEWEST-FIRST (git log order); each commit is an
      atom-keyed map (`:sha, :short_sha, :message, :author_name, :date,
      :parents`, where `:parents` is the full SHA list, `[]` for a root); and
    - `agents` — the page's already-loaded rich agent maps
      (`EvoDashWeb.AgentsLive.LoadData.build_agents/2`).

  Every commit/agent field is read through `Map.get/2` and every function is
  TOTAL: odd input shapes degrade to empty graphs instead of raising.

  ## Direction

  OLDEST commit at the TOP, NEWEST at the BOTTOM: the output `commits` list is
  ordered top → bottom (oldest first) and `row`/`y` grow downwards, so new
  commits append at the bottom — the shape LiveView's keyed patching and the
  enter animations need.

  ## Lane assignment (classic first-available-lane)

  The fetched commits are processed in input order (NEWEST → OLDEST) against a
  `slots` list — an ordered list where each slot is either free (`nil`) or
  holds the parent SHA that lane expects next:

    1. A commit takes the FIRST slot already waiting on its sha; else the
       first FREE slot; else a brand-new slot appended at the end. That slot
       index is the commit's `lane`.
    2. EVERY slot waiting on the commit's sha is then freed — the matched one
       plus any duplicates. This is how merge commits fold redundant lanes
       back together.
    3. The commit's parents THAT ARE PRESENT in the fetched graph reserve
       slots: the first (in listed order) continues in the commit's own lane;
       each extra parent (a merge's 2nd..nth) claims its own
       first-free-or-appended slot.
    4. A commit whose parents are all absent from the fetch (history truncated
       by the fetch limit) leaves its slot free — its lane simply ends.

  Only the row axis is flipped afterwards: a commit processed at 0-based index
  `r` renders at `row = total_rows - 1 - r`, so the newest commit gets the
  largest `y`.

  ## Geometry

  Constants (module attributes): `lane_width 24`, `row_height 26`, `pad_left
  12`, `pad_top 14`, `pad_bottom 14`, `right_gutter 150` (room for the ref
  chips + agent markers rendered right of the dots), `dot_r 4.5`, `ring_r 8.5`
  (the two radii are consumed by the SVG renderer — they live here as the
  single source of truth).

      x(lane) = pad_left + lane * lane_width + lane_width / 2   (dot CENTER x)
      y(row)  = pad_top  + row  * row_height  + row_height / 2  (dot CENTER y)
      width   = pad_left + lane_count * lane_width + right_gutter
      height  = pad_top  + rows * row_height + pad_bottom

  Edges — one per (child, parent) pair where BOTH ends are in the fetched
  graph; the child is NEWER so it renders BELOW its parent:

      same lane:  "M x,yc L x,yp"
      different:  "M xc,yc C xc,mid xp,mid xp,yp"   with mid = (yc + yp) / 2

  Parents absent from the fetch produce NO edge (the history is truncated by
  the fetch limit).

  ## Depth → hue

  `color(depth) = EvoDashWeb.ThemeColor.hsl_to_hex(hue, 70, 54)` where
  `hue = Integer.mod(round(depth * 137.508) + 265, 360)` — golden-angle step
  137.508° per depth level (deterministic, maximally spread hues), +265°
  offset so depth 0 lands on blue-violet and common shallow depths stay away
  from the status colors (red/green/amber), saturation 70 / lightness 54
  identical to `ThemeColor`'s project accents. The existing public
  `EvoDashWeb.ThemeColor.hsl_to_hex/3` is reused — HSL→hex is NOT
  reimplemented here. Non-integer/nil/negative depth → 0.

  ## Agent overlay

  Agents are processed in ascending `{depth, id}` order (mirroring how the
  page sorts agents) so color conflicts resolve deterministically — the FIRST
  agent to cover a dot/edge wins.

  Each agent's progress path is a first-parent walk from its `current_commit`
  backwards, stopping at (excluding) its `base_commit`, at a sha not in the
  fetched graph, or at an already-seen sha (cycle guard). Every commit on that
  path gets the agent's depth-hue as `highlight_color`; every edge between
  consecutive path commits — PLUS the edge from the oldest path commit up to
  its first parent (== base, when base is in the graph) — is covered by that
  agent's color. An agent whose `current_commit` is present in the fetched
  graph contributes a RING at that commit's position.

  ## Output shape

  `build/2` returns one map per repository group, sorted by
  `{repo_name, repo_dom_id}`:

      %{
        repo_key: term(), repo_dom_id: String.t(), repo_name: String.t(),
        width: float(), height: float(),
        lane_count: non_neg_integer(), commit_count: non_neg_integer(),
        commits: [%{sha:, short_sha:, message:, parents:, lane:, row:, x:, y:,
                    refs:, highlight_color:, agent:}],
        edges: [%{id:, d:, color:}],
        rings: [%{agent_id:, task_local_id:, status:, depth:, color:, x:, y:}]
      }

  `commits` is ordered TOP → BOTTOM (oldest first); `message` is the commit
  message's first line only. Edge ids are the stable DOM ids
  `"commit-edge-<repo_dom_id>-<child_sha>-<parent_sha>"`. `commits[].agent`
  is the click/select target for that dot: the TIP agent (`tip?: true`) when
  the commit is some agent's `current_commit`, otherwise the first
  path-covering agent (`tip?: false`), `nil` for commits no agent maps to.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoGit.Platform
  alias EvoDashWeb.ThemeColor

  # --- Geometry constants (single source of truth for the SVG renderer) ------

  @lane_width 24
  @row_height 26
  @pad_left 12
  @pad_top 14
  @pad_bottom 14
  @right_gutter 150
  @dot_r 4.5
  @ring_r 8.5

  @doc "Commit-dot radius — the single source of truth for the SVG renderer."
  @spec dot_r :: float()
  def dot_r, do: @dot_r

  @doc "Agent-tip ring radius — the single source of truth for the SVG renderer."
  @spec ring_r :: float()
  def ring_r, do: @ring_r

  @typedoc """
  One rendered commit (a dot). `row` is the RENDER row (top-based, oldest
  commit = row 0); `x`/`y` are the dot CENTER coordinates.
  """
  @type commit_view :: %{
          sha: String.t(),
          short_sha: String.t(),
          message: String.t(),
          parents: [String.t()],
          lane: non_neg_integer(),
          row: non_neg_integer(),
          x: float(),
          y: float(),
          refs: [String.t()],
          highlight_color: String.t() | nil,
          agent: agent_view() | nil
        }

  @typedoc """
  The click/select target attached to a dot: the TIP agent (`tip?: true`)
  when the commit is some agent's `current_commit`, otherwise the first
  path-covering agent (`tip?: false`).
  """
  @type agent_view :: %{
          id: term(),
          task_local_id: term(),
          status: term(),
          depth: non_neg_integer(),
          color: String.t(),
          tip?: boolean()
        }

  @typedoc """
  One edge. `d` is a ready-to-render SVG path; `id` is the stable DOM id
  `"commit-edge-<repo_dom_id>-<child_sha>-<parent_sha>"`; `color` is the
  covering agent's depth-hue or nil.
  """
  @type edge_view :: %{
          id: String.t(),
          d: String.t(),
          color: String.t() | nil
        }

  @typedoc "An agent tip ring, positioned exactly on its `current_commit` dot."
  @type ring_view :: %{
          agent_id: term(),
          task_local_id: term(),
          status: term(),
          depth: non_neg_integer(),
          color: String.t(),
          x: float(),
          y: float()
        }

  @typedoc """
  All geometry + overlay data for one repository group, ready to render as a
  single SVG.
  """
  @type repo_view :: %{
          repo_key: term(),
          repo_dom_id: String.t(),
          repo_name: String.t(),
          width: float(),
          height: float(),
          lane_count: non_neg_integer(),
          commit_count: non_neg_integer(),
          commits: [commit_view()],
          edges: [edge_view()],
          rings: [ring_view()]
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
  Builds the per-repo classic git-graph view.

  `raw_by_repo` maps a repo grouping key to the fetched commit graph
  (`%{commits: [commit], refs: %{sha => [name]}}`); a key that is absent (or a
  repo whose fetch failed) yields an empty graph (zero commits, zero lanes).

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
    # Newest-first, filtered to ADDRESSABLE commits (a map with a non-empty
    # binary :sha) and de-duplicated by sha — git log never returns duplicates,
    # but a malformed payload must not produce duplicate DOM ids either.
    commits = addressable_commits(raw)
    lookup = commit_lookup(commits)
    refs = refs_map(raw)
    dom_id = repo_dom_id(repo_key)

    layout = layout_commits(commits, lookup)
    overlay = agent_overlay(repo_agents, lookup, layout)

    rows = length(commits)
    lane_count = layout.lane_count

    %{
      repo_key: repo_key,
      repo_dom_id: dom_id,
      repo_name: repo_display_name(repo_key),
      width: (@pad_left + lane_count * @lane_width + @right_gutter) * 1.0,
      height: (@pad_top + rows * @row_height + @pad_bottom) * 1.0,
      lane_count: lane_count,
      commit_count: rows,
      commits: commit_views(commits, layout, refs, overlay),
      edges: edge_views(commits, lookup, layout, dom_id, overlay),
      rings: Enum.reverse(overlay.rings)
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

  defp parents_list(commit) do
    case Map.get(commit, :parents) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # A commit's parents that are present in the fetched graph (order preserved,
  # de-duplicated so a malformed repeated parent never emits two identical
  # edges / reservations).
  defp present_parents(commit, lookup) do
    parents_list(commit) |> Enum.uniq() |> Enum.filter(&Map.has_key?(lookup, &1))
  end

  defp first_parent(commit) do
    case parents_list(commit) do
      [first | _] -> first
      [] -> nil
    end
  end

  defp short_sha(commit, sha) do
    case Map.get(commit, :short_sha) do
      short when is_binary(short) and short != "" -> short
      _ -> String.slice(sha, 0, 8)
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

  # --- Layout: lanes + rows ---------------------------------------------------

  # Runs the classic first-available-lane slot machine over the NEWEST-FIRST
  # commit list (see the moduledoc), then flips the row axis so the OLDEST
  # commit renders at row 0 (top) and the NEWEST at row total-1 (bottom).
  defp layout_commits(commits, lookup) do
    total = length(commits)
    {lanes, slots} = assign_lanes(commits, lookup)

    rows =
      commits
      |> Enum.with_index()
      |> Map.new(fn {commit, r} -> {Map.get(commit, :sha), total - 1 - r} end)

    %{lanes: lanes, rows: rows, lane_count: length(slots)}
  end

  defp assign_lanes(commits, lookup) do
    Enum.reduce(commits, {%{}, []}, fn commit, {lanes, slots} ->
      sha = Map.get(commit, :sha)

      # 1. First slot waiting on this sha, else first free slot, else a new one.
      idx = find_slot(slots, sha)
      slots = ensure_slot(slots, idx)

      # 2. Free EVERY slot waiting on this sha — merge commits fold redundant
      #    lanes back together here.
      slots = clear_sha_slots(slots, sha)

      # 3./4. Reserve slots for the parents present in the fetch; a commit
      #       with none leaves its slot free (its lane ends).
      slots =
        case present_parents(commit, lookup) do
          [] ->
            slots

          [first | extras] ->
            slots = put_slot(slots, idx, first)

            Enum.reduce(extras, slots, fn parent, slots ->
              extra_idx = free_slot(slots)
              slots = ensure_slot(slots, extra_idx)
              put_slot(slots, extra_idx, parent)
            end)
        end

      {Map.put(lanes, sha, idx), slots}
    end)
  end

  # The slot index for a commit: the first lane already waiting on its sha,
  # else the first free lane, else a brand-new lane appended at the end.
  defp find_slot(slots, sha) do
    case Enum.find_index(slots, fn s -> s == sha end) do
      idx when is_integer(idx) -> idx
      nil -> free_slot(slots)
    end
  end

  # The first free (nil) slot index, or `length(slots)` when none is free.
  defp free_slot(slots) do
    case Enum.find_index(slots, &is_nil/1) do
      idx when is_integer(idx) -> idx
      nil -> length(slots)
    end
  end

  # Grows the slot list so index `idx` exists (new lanes are appended as nil).
  defp ensure_slot(slots, idx) when idx < length(slots), do: slots

  defp ensure_slot(slots, idx), do: slots ++ List.duplicate(nil, idx - length(slots) + 1)

  defp put_slot(slots, idx, sha), do: List.replace_at(slots, idx, sha)

  defp clear_sha_slots(slots, sha) do
    Enum.map(slots, fn s -> if s == sha, do: nil, else: s end)
  end

  # --- Geometry ----------------------------------------------------------------

  defp dot_x(lane), do: @pad_left + lane * @lane_width + @lane_width / 2
  defp dot_y(row), do: @pad_top + row * @row_height + @row_height / 2

  defp lane_of(layout, sha), do: Map.get(layout.lanes, sha, 0)
  defp row_of(layout, sha), do: Map.get(layout.rows, sha, 0)

  # Compact SVG number formatting: drops the trailing ".0" of whole floats
  # (`24.0` → `"24"`) while keeping fractional values intact.
  defp num(v) when is_float(v) do
    s = Float.to_string(v)
    if String.ends_with?(s, ".0"), do: binary_part(s, 0, byte_size(s) - 2), else: s
  end

  # --- Commit views -------------------------------------------------------------

  # The output list is ordered TOP → BOTTOM (oldest first) — the reverse of the
  # newest-first processing order.
  defp commit_views(commits, layout, refs, overlay) do
    commits
    |> Enum.reverse()
    |> Enum.map(fn commit ->
      sha = Map.get(commit, :sha)
      lane = lane_of(layout, sha)
      row = row_of(layout, sha)

      %{
        sha: sha,
        short_sha: short_sha(commit, sha),
        message: first_line(Map.get(commit, :message)),
        parents: parents_list(commit),
        lane: lane,
        row: row,
        x: dot_x(lane),
        y: dot_y(row),
        refs: refs_for(refs, sha),
        highlight_color: Map.get(overlay.dots, sha),
        agent: Map.get(overlay.agents, sha)
      }
    end)
  end

  # --- Edge views ---------------------------------------------------------------

  # One edge per (child, parent) pair with both ends in the fetched graph.
  # Emitted in top → bottom (oldest commit first) order, parents in listed
  # order — deterministic across refreshes.
  defp edge_views(commits, lookup, layout, dom_id, overlay) do
    commits
    |> Enum.reverse()
    |> Enum.flat_map(fn commit ->
      sha = Map.get(commit, :sha)

      present_parents(commit, lookup)
      |> Enum.map(fn parent ->
        %{
          id: "commit-edge-#{dom_id}-#{sha}-#{parent}",
          d: edge_d(sha, parent, layout),
          color: Map.get(overlay.edges, {sha, parent})
        }
      end)
    end)
  end

  # The child is NEWER than the parent, so it renders BELOW it (yc > yp):
  # the path is always drawn from the child dot UP into the parent's lane.
  defp edge_d(child_sha, parent_sha, layout) do
    child_lane = lane_of(layout, child_sha)
    parent_lane = lane_of(layout, parent_sha)
    xc = dot_x(child_lane)
    yc = dot_y(row_of(layout, child_sha))
    xp = dot_x(parent_lane)
    yp = dot_y(row_of(layout, parent_sha))

    if child_lane == parent_lane do
      "M #{num(xc)},#{num(yc)} L #{num(xc)},#{num(yp)}"
    else
      mid = (yc + yp) / 2

      "M #{num(xc)},#{num(yc)} C #{num(xc)},#{num(mid)} #{num(xp)},#{num(mid)} #{num(xp)},#{num(yp)}"
    end
  end

  # --- Agent overlay --------------------------------------------------------------

  # Covers dots/edges with each agent's depth-hue and collects the tip rings.
  # Agents are folded in ascending {depth, id} order and every write is
  # first-write-wins, so overlay conflicts resolve deterministically.
  #
  # A dot's `agent` target has TWO tiers: the tip tier (an agent whose
  # `current_commit` IS that dot — `tip?: true`) beats any path-covering tier
  # (`tip?: false`), regardless of {depth, id} order; within a tier the first
  # agent in {depth, id} order wins.
  defp agent_overlay(repo_agents, lookup, layout) do
    ordered =
      Enum.sort_by(repo_agents, fn agent ->
        {normalize_depth(Map.get(agent, :depth)), Map.get(agent, :id)}
      end)

    acc =
      Enum.reduce(ordered, empty_overlay(), fn agent, acc ->
        depth = normalize_depth(Map.get(agent, :depth))
        color = depth_color(depth)
        base = Map.get(agent, :base_commit)
        current = Map.get(agent, :current_commit)
        tip? = is_binary(current) and Map.has_key?(lookup, current)

        acc
        |> put_ring(agent, depth, color, current, layout, tip?)
        |> put_tip(current, agent, depth, color, tip?)
        |> put_path(base, current, lookup, agent, depth, color)
      end)

    # Tip targets override path-covering targets on the same dot.
    %{acc | agents: Map.merge(acc.cover_agents, acc.tip_agents)}
  end

  defp empty_overlay,
    do: %{dots: %{}, edges: %{}, cover_agents: %{}, tip_agents: %{}, agents: %{}, rings: []}

  # An agent whose current_commit is in the fetched graph contributes a ring
  # at that commit's position (accumulated reversed; build_repo flips once).
  defp put_ring(acc, _agent, _depth, _color, _current, _layout, false), do: acc

  defp put_ring(acc, agent, depth, color, current, layout, true) do
    ring = %{
      agent_id: Map.get(agent, :id),
      task_local_id: Map.get(agent, :task_local_id),
      status: Map.get(agent, :status),
      depth: depth,
      color: color,
      x: dot_x(lane_of(layout, current)),
      y: dot_y(row_of(layout, current))
    }

    %{acc | rings: [ring | acc.rings]}
  end

  # Records the agent as the dot's TIP target (`tip?: true`) — first agent in
  # {depth, id} order wins among tips pointing at the same commit.
  defp put_tip(acc, _current, _agent, _depth, _color, false), do: acc

  defp put_tip(acc, current, agent, depth, color, true) do
    %{
      acc
      | tip_agents: Map.put_new(acc.tip_agents, current, agent_view(agent, depth, color, true))
    }
  end

  # Colors the agent's progress path (dots + consecutive edges), records the
  # agent as the PATH-COVERING target for every dot on the path, and covers
  # the edge linking the oldest path commit back into its base when the base
  # is in the fetched graph.
  defp put_path(acc, base, current, lookup, agent, depth, color) do
    path = walk(current, base, lookup, MapSet.new())
    view = agent_view(agent, depth, color, false)

    acc =
      Enum.reduce(path, acc, fn sha, acc ->
        acc
        |> Map.update!(:dots, &Map.put_new(&1, sha, color))
        |> Map.update!(:cover_agents, &Map.put_new(&1, sha, view))
      end)

    cover_edges(acc, path, base, lookup, color)
  end

  defp agent_view(agent, depth, color, tip?) do
    %{
      id: Map.get(agent, :id),
      task_local_id: Map.get(agent, :task_local_id),
      status: Map.get(agent, :status),
      depth: depth,
      color: color,
      tip?: tip?
    }
  end

  defp cover_edges(acc, path, base, lookup, color) do
    # Edges between consecutive path commits (child → first parent).
    acc =
      path
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(acc, fn [child, parent], acc ->
        put_edge(acc, child, parent, color)
      end)

    # Plus the edge from the OLDEST path commit up to its first parent — that
    # parent is the agent's base_commit exactly when the walk stopped on the
    # base condition, and the edge only exists when the base is in the graph.
    case List.last(path) do
      nil ->
        acc

      oldest ->
        parent = lookup |> Map.get(oldest) |> first_parent()

        if parent == base and is_binary(base) and Map.has_key?(lookup, base) do
          put_edge(acc, oldest, base, color)
        else
          acc
        end
    end
  end

  defp put_edge(acc, child, parent, color) do
    %{acc | edges: Map.put_new(acc.edges, {child, parent}, color)}
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

  # Total key → string conversion (never raises on unexpected terms).
  defp stringify(key) when is_binary(key), do: key
  defp stringify(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify(key) when is_integer(key), do: Integer.to_string(key)
  defp stringify(key), do: inspect(key)
end
