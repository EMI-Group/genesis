defmodule EvoDashWeb.AgentsLive.CommitGraph do
  @moduledoc """
  Pure graph-assembly logic for the Agents page's git-commit-history (temporal)
  view.

  The Agents page already renders the SPATIAL dimension — the recursive agent
  tree grouped by repository (`AgentsLive.build_repo_trees/1`). This module
  assembles the TEMPORAL counterpart from the same agent maps: for every
  repository group it produces one "lane" per agent carrying the commits that
  agent produced, so the renderer can draw how the agents forked off one
  another.

  The module is deliberately PURE — no I/O, no socket, no process — mirroring
  the sibling support modules (`HistoryGate`, `OptimisticMessages`,
  `PendingEvents`). It is fed:

    - `agents` — the page's already-loaded agent maps
      (`EvoDashWeb.AgentsLive.LoadData.build_agents/2`), and
    - `raw_by_repo` — the per-repo commit graph fetched by the node-aware
      commit RPC (`%{repo_key => %{commits: [commit], refs: %{sha => [name]}}}`).

  Every commit field is read defensively through `Map.get/2` (a commit may be a
  struct or a plain map), so the functions are TOTAL: odd input shapes never
  raise.

  ## Lane ordering

  Lanes are ordered DEPTH-FIRST, a parent before its children, and children in
  ascending agent `id` order — the same shape as the agent tree. An agent is a
  root of its repo group when its `parent_id` is nil or when its parent lives
  in ANOTHER repo group. A visited set makes the traversal cycle-safe: agents
  the root pass never reaches (e.g. a malformed parent cycle) are still given a
  lane by a second pass.

  ## Commit ownership (fork-point resolution)

  Commits are mapped onto lanes in lane order. For each lane we walk from the
  agent's `current_commit` backwards along first parents, stopping at the
  agent's `base_commit` (exclusive), at a sha the fetched graph does not
  contain, or at a sha already claimed. Each visited commit is OWNED by the
  first lane that reaches it, tracked by a per-repo `claimed` set — shared
  history is therefore never duplicated across lanes, and a lane that joins an
  already-claimed history simply owns no commits (its agent produced none of
  its own yet).

  A commit carries `has_parent_in_lane?`: whether its FIRST parent is owned by
  the SAME lane. When it is false the renderer knows the lane's history
  continues in another lane (at the fork point) and can draw the connector.

  Lane commits are stored OLDEST → NEWEST, so the lane's tip is last and the
  renderer appends new commits at the end.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoGit.Platform

  @typedoc """
  A single commit as rendered inside a lane.

  `short_sha` falls back to the first 8 characters of `sha`; `message` is the
  commit message truncated to its first line; `refs` are the ref names pointing
  at this sha (only shas present in the fetched graph carry refs).
  """
  @type commit_view :: %{
          sha: String.t(),
          short_sha: String.t(),
          message: String.t(),
          author_name: String.t() | nil,
          date: DateTime.t() | nil,
          parents: [String.t()],
          refs: [String.t()],
          has_parent_in_lane?: boolean()
        }

  @typedoc """
  One agent's lane within a repo group.

  `lane_index` is the 0-based position of the lane in the repo's `lanes` list
  (DOM order). `parent_lane_index` is the lane index of the agent's parent when
  the parent is in the SAME repo group, else nil; `connects?` is true exactly
  when `parent_lane_index != nil`.
  """
  @type lane :: %{
          agent_id: term(),
          lane_index: non_neg_integer(),
          depth: non_neg_integer(),
          parent_agent_id: term(),
          parent_lane_index: non_neg_integer() | nil,
          connects?: boolean(),
          task_local_id: term(),
          status: term(),
          agent_module: term(),
          model_id: term(),
          base_commit: String.t() | nil,
          current_commit: String.t() | nil,
          commits: [commit_view()]
        }

  @typedoc "All lanes for one repository group, plus its display name and stable DOM id."
  @type repo_view :: %{
          repo_key: term(),
          repo_dom_id: String.t(),
          repo_name: String.t(),
          lanes: [lane()]
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
  Builds the per-repo commit-graph view.

  `raw_by_repo` maps a repo grouping key to the fetched commit graph
  (`%{commits: [commit], refs: %{sha => [name]}}`); a key that is absent (or a
  repo whose fetch failed) yields lanes with empty commit lists.

  Agents are grouped by `grouping_key/1` — exactly like the tree — and the
  resulting `repo_view`s are sorted by `repo_name` ascending (ties broken by the
  stable `repo_dom_id`, so the DOM order never flaps between refreshes).
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
    commits = commits_list(raw)
    lookup = commit_lookup(commits)
    refs = refs_map(raw)

    %{
      repo_key: repo_key,
      repo_dom_id: repo_dom_id(repo_key),
      repo_name: repo_display_name(repo_key),
      lanes: build_lanes(repo_agents, lookup, refs)
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

  defp commits_list(raw) do
    case Map.get(raw, :commits) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  # The per-repo sha → commit lookup used by the parent walk. A commit without a
  # non-empty binary `:sha` is not addressable (and is skipped from the view).
  defp commit_lookup(commits) do
    Enum.reduce(commits, %{}, fn commit, acc ->
      case Map.get(commit, :sha) do
        sha when is_binary(sha) and sha != "" -> Map.put(acc, sha, commit)
        _ -> acc
      end
    end)
  end

  defp refs_map(raw) do
    case Map.get(raw, :refs) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  # --- Lanes ----------------------------------------------------------------

  defp build_lanes(repo_agents, lookup, refs) do
    ordered = order_agents(repo_agents)
    lane_index_by_id = lane_index_by_id(ordered)

    {lanes, _claimed} =
      ordered
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, fn {agent, lane_index}, {lanes, claimed} ->
        parent_lane_index = parent_lane_index(agent, lane_index_by_id)
        {shas, claimed} = lane_commit_shas(agent, lookup, claimed)

        lane = build_lane(agent, lane_index, parent_lane_index, shas, lookup, refs)
        {[lane | lanes], claimed}
      end)

    Enum.reverse(lanes)
  end

  # Maps agent ids to lane indices so a parent's lane can be resolved in O(1).
  # An agent whose parent lives in another repo group (or a nil parent) simply
  # has no entry here and therefore gets `parent_lane_index: nil`.
  defp lane_index_by_id(ordered) do
    ordered
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {agent, lane_index}, acc ->
      Map.put(acc, agent_id(agent), lane_index)
    end)
  end

  defp parent_lane_index(agent, lane_index_by_id) do
    case Map.get(agent, :parent_id) do
      nil -> nil
      parent_id -> Map.get(lane_index_by_id, parent_id)
    end
  end

  defp build_lane(agent, lane_index, parent_lane_index, shas, lookup, refs) do
    lane_shas = MapSet.new(shas)

    commits =
      Enum.map(shas, fn sha ->
        build_commit(sha, Map.get(lookup, sha), refs, lane_shas)
      end)

    %{
      agent_id: agent_id(agent),
      lane_index: lane_index,
      depth: Map.get(agent, :depth) || 0,
      parent_agent_id: Map.get(agent, :parent_id),
      parent_lane_index: parent_lane_index,
      connects?: parent_lane_index != nil,
      task_local_id: Map.get(agent, :task_local_id),
      status: Map.get(agent, :status),
      agent_module: Map.get(agent, :agent_module),
      model_id: Map.get(agent, :model_id),
      base_commit: Map.get(agent, :base_commit),
      current_commit: Map.get(agent, :current_commit),
      commits: commits
    }
  end

  defp build_commit(sha, commit, refs, lane_shas) do
    parents = parents_of(commit)

    %{
      sha: sha,
      short_sha: short_sha(commit, sha),
      message: first_line(Map.get(commit, :message)),
      author_name: Map.get(commit, :author_name),
      date: Map.get(commit, :date),
      parents: parents,
      refs: refs_for(refs, sha),
      has_parent_in_lane?: first_parent_in?(parents, lane_shas)
    }
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

  defp parents_of(commit) do
    case Map.get(commit, :parents) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp first_parent_in?(parents, lane_shas) do
    case List.first(parents) do
      sha when is_binary(sha) -> MapSet.member?(lane_shas, sha)
      _ -> false
    end
  end

  defp first_line(message) when is_binary(message) do
    message |> String.split("\n", parts: 2) |> hd()
  end

  defp first_line(_message), do: ""

  # --- Commit → lane mapping ------------------------------------------------

  # The commit shas owned by one agent's lane, OLDEST → NEWEST.
  #
  # Walking is skipped entirely when the agent has no usable base/current
  # commit (nil or non-binary) or when both are the same sha (no commits were
  # produced since the base).
  defp lane_commit_shas(agent, lookup, claimed) do
    base = Map.get(agent, :base_commit)
    current = Map.get(agent, :current_commit)

    if is_binary(base) and is_binary(current) and base != current do
      # walk/5 collects NEWEST → OLDEST, the lane stores the reverse.
      {newest_first, claimed} = walk(current, base, lookup, claimed, MapSet.new())
      {Enum.reverse(newest_first), claimed}
    else
      {[], claimed}
    end
  end

  # Follows first parents from `sha` towards the root, collecting shas in
  # NEWEST → OLDEST order while claiming each one for this lane.
  #
  # The walk stops without collecting the current sha when:
  #   * it is the lane's exclusive `base_commit` (the fork point it grew from),
  #   * it was already claimed by an earlier lane (shared history is never
  #     duplicated; a lane joining claimed history owns nothing),
  #   * it was already seen within this same walk (defensive cycle guard), or
  #   * it is absent from the fetched graph (shallow/partial fetch).
  defp walk(sha, base, lookup, claimed, seen) do
    cond do
      not is_binary(sha) ->
        {[], claimed}

      sha == base ->
        {[], claimed}

      MapSet.member?(claimed, sha) ->
        {[], claimed}

      MapSet.member?(seen, sha) ->
        {[], claimed}

      not Map.has_key?(lookup, sha) ->
        {[], claimed}

      true ->
        seen = MapSet.put(seen, sha)
        claimed = MapSet.put(claimed, sha)
        first_parent = lookup |> Map.get(sha) |> parents_of() |> List.first()
        {older, claimed} = walk(first_parent, base, lookup, claimed, seen)
        {[sha | older], claimed}
    end
  end

  # --- Agent ordering (depth-first, parents before children) ----------------

  defp order_agents(repo_agents) do
    by_id =
      Enum.reduce(repo_agents, %{}, fn agent, acc ->
        Map.put(acc, agent_id(agent), agent)
      end)

    children_by_parent = Enum.group_by(repo_agents, fn agent -> Map.get(agent, :parent_id) end)

    roots =
      repo_agents
      |> Enum.filter(fn agent -> root_of_group?(agent, by_id) end)
      |> Enum.sort_by(&agent_id/1)

    {reversed, visited} =
      Enum.reduce(roots, {[], MapSet.new()}, fn root, {acc, visited} ->
        visit(root, children_by_parent, visited, acc)
      end)

    # Cycle safety net: an agent whose parent chain never reaches a root (e.g. a
    # malformed A<->B parent cycle) is unreachable from the root pass. Give it a
    # lane too, still in ascending id order, so every agent in the group is
    # represented exactly once.
    leftovers =
      repo_agents
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.sort_by(&agent_id/1)

    {reversed, _visited} =
      Enum.reduce(leftovers, {reversed, visited}, fn agent, {acc, visited} ->
        visit(agent, children_by_parent, visited, acc)
      end)

    Enum.reverse(reversed)
  end

  # An agent is a root of its group when it has no parent, or when its parent is
  # not part of this repo group (the tree starts a new root per group).
  defp root_of_group?(agent, by_id) do
    case Map.get(agent, :parent_id) do
      nil -> true
      parent_id -> not Map.has_key?(by_id, parent_id)
    end
  end

  # Depth-first pre-order visit, accumulating in REVERSE order (a prepend is
  # O(1); `order_agents/1` reverses once at the end). The visited set holds the
  # agent maps themselves, which makes the traversal cycle-safe even for agents
  # with a nil or duplicated id. Agents with no usable id expose no children —
  # looking them up under a nil parent key would otherwise cross-link unrelated
  # roots.
  defp visit(agent, children_by_parent, visited, acc) do
    if MapSet.member?(visited, agent) do
      {acc, visited}
    else
      visited = MapSet.put(visited, agent)
      acc = [agent | acc]

      children =
        case agent_id(agent) do
          nil ->
            []

          id ->
            children_by_parent
            |> Map.get(id, [])
            |> Enum.sort_by(&agent_id/1)
        end

      Enum.reduce(children, {acc, visited}, fn child, {acc, visited} ->
        visit(child, children_by_parent, visited, acc)
      end)
    end
  end

  defp agent_id(agent), do: Map.get(agent, :id)

  # --- DOM ids --------------------------------------------------------------

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
