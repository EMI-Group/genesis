defmodule EvoDashWeb.AgentsLive.CommitGraph.Edges do
  @moduledoc """
  Edge derivation for `EvoDashWeb.AgentsLive.CommitGraph`: the commit →
  parent edges plus the agent-level `:spawn` / `:merge_back` edges, all
  positioned from the FINAL node layout produced by
  `CommitGraph.Interleave.layout/3`.

  Two edge families come out, in this order:

    - COMMIT EDGES — for every real commit node and every one of its
      `:parents` present in the node set, one edge from the child to that
      parent: `kind: :parent` for the FIRST present parent (the first-parent
      lineage), `kind: :merge` for every other (a folded side branch).
      Identical `{from_sha, to_sha}` pairs are de-duplicated and the list
      sorts by `{from_sha, to_sha}`. DROP RULE: any commit edge whose
      UNORDERED sha pair equals an agent-level edge's unordered pair is
      dropped — the agent-level edge replaces it visually (a child's
      oldest-commit → fork `:parent` yields to the dashed `:spawn` edge; a
      fast-forward continuation → tip `:parent` yields to the
      `:merge_back`).

    - AGENT-LEVEL EDGES — per CHILD agent whose parent agent resolves within
      the same repo group; a child without a resolvable parent contributes
      none. `:spawn` branches out from the fork node (the child's
      `:base_commit`) into the child's lane — to the child's OLDEST
      progress-path commit, or to its no-op stub when it committed nothing.
      `:merge_back` returns the child's tip (or stub) into the parent's
      lane, targeting the TOPMOST parent-owned node strictly BELOW the
      source row, or a VIRTUAL landing (`to_sha: nil` with authoritative
      `to_column` = the parent's lane and `to_row` = the source's own row)
      when the parent lane has nothing below yet. A REAL merge (a commit
      listing the child tip among its 2nd+ parents) is already drawn by the
      dashed `:merge` edge, so no `:merge_back` duplicates it. The list
      sorts by `{kind, owner_key, from_sha, to_sha}`.

  Pure and total like the parent module: `Map.get/2` reads, no I/O, no
  socket, no processes; odd shapes degrade to empty edge lists.
  """

  alias EvoDashWeb.AgentsLive.CommitGraph

  @doc """
  Derives the full edge list from the layout context
  (`%{commits, nodes, ordered, paths, parent_indices, stubs, lane_shift}`):

    - `commits` — the repo's addressable fetched commits (parent links);
    - `nodes` — the FINAL positioned node views (row-sorted);
    - `ordered` — the repo's agents in agent order;
    - `paths` — each agent's progress path, newest → oldest, agent order;
    - `parent_indices` — agent-order index → parent agent's index (nil when
      the parent does not resolve in this repo group);
    - `stubs` — agent-order index → the agent's no-op stub;
    - `lane_shift` — 1 when unowned nodes exist (agent lanes shift right).
  """
  @spec derive(map()) :: [map()]
  def derive(ctx) do
    commits = list(Map.get(ctx, :commits))
    nodes = list(Map.get(ctx, :nodes))
    ordered = list(Map.get(ctx, :ordered))
    paths = list(Map.get(ctx, :paths))
    parent_indices = map_of(Map.get(ctx, :parent_indices))
    stubs = map_of(Map.get(ctx, :stubs))
    shift = non_neg(Map.get(ctx, :lane_shift))

    coords = Map.new(nodes, fn node -> {Map.get(node, :sha), node_position(node)} end)
    owners = Map.new(nodes, fn node -> {Map.get(node, :sha), Map.get(node, :owner_id)} end)
    ids = Enum.map(ordered, &Map.get(&1, :id))
    merged_tips = merged_tips(commits)

    agent_edges =
      agent_edges(ordered, paths, parent_indices, stubs, coords, nodes, ids, shift, merged_tips)

    pairs = agent_pairs(agent_edges)

    commit_edges =
      commits
      |> Enum.flat_map(&commit_edges(&1, coords, owners))
      |> Enum.uniq_by(&{&1.from_sha, &1.to_sha})
      |> Enum.reject(&superseded?(&1, pairs))
      |> Enum.sort_by(&{&1.from_sha, &1.to_sha})

    sorted_agent_edges =
      Enum.sort_by(agent_edges, fn edge ->
        {edge.kind, CommitGraph.stringify(edge.owner_id), edge.from_sha, edge.to_sha}
      end)

    commit_edges ++ sorted_agent_edges
  end

  # --- Commit → parent edges ---------------------------------------------------

  # One edge per PRESENT parent of a fetched commit. Absent parents produce
  # no edge (nothing to anchor the stroke on); duplicates collapse; the drop
  # rule then removes the pairs an agent-level edge replaces.
  defp commit_edges(commit, coords, owners) do
    sha = Map.get(commit, :sha)

    case Map.fetch(coords, sha) do
      {:ok, from} ->
        commit
        |> CommitGraph.parents_list()
        |> Enum.uniq()
        |> Enum.filter(&Map.has_key?(coords, &1))
        |> Enum.with_index()
        |> Enum.map(fn {parent_sha, position} ->
          to = Map.fetch!(coords, parent_sha)

          %{
            from_sha: sha,
            to_sha: parent_sha,
            from_column: elem(from, 0),
            from_row: elem(from, 1),
            to_column: elem(to, 0),
            to_row: elem(to, 1),
            kind: if(position == 0, do: :parent, else: :merge),
            owner_id: Map.get(owners, sha)
          }
        end)

      :error ->
        []
    end
  end

  # The shas some fetched commit lists among its 2nd+ parents — every one of
  # them already has a dashed `:merge` edge drawn into it, so a
  # `:merge_back` from that tip would double-draw the same return.
  defp merged_tips(commits) do
    commits
    |> Enum.flat_map(fn commit ->
      commit |> CommitGraph.parents_list() |> Enum.drop(1)
    end)
    |> MapSet.new()
  end

  # An agent-level edge pair {min(sha), max(sha)}; a virtual landing (nil
  # `to_sha`) can never collide with a commit edge, so it contributes none.
  defp agent_pairs(agent_edges) do
    MapSet.new(agent_edges, fn edge -> unordered_pair(edge.from_sha, edge.to_sha) end)
  end

  defp unordered_pair(from_sha, to_sha) when is_binary(from_sha) and is_binary(to_sha) do
    if from_sha <= to_sha, do: {from_sha, to_sha}, else: {to_sha, from_sha}
  end

  defp unordered_pair(_from_sha, _to_sha), do: :no_pair

  defp superseded?(edge, pairs) do
    MapSet.member?(pairs, unordered_pair(edge.from_sha, edge.to_sha))
  end

  # --- Agent-level edges ---------------------------------------------------------

  # Per child agent with a resolvable parent agent: the `:spawn` branch-out
  # from the fork into the child's lane and the `:merge_back` return into the
  # parent's lane. Everything else (root agents, cross-repo / unknown
  # parents) contributes nothing.
  defp agent_edges(ordered, paths, parent_indices, stubs, coords, nodes, ids, shift, merged_tips) do
    ordered
    |> Enum.with_index()
    |> Enum.flat_map(fn {agent, index} ->
      parent_index = Map.get(parent_indices, index)

      if is_integer(parent_index) and parent_index >= 0 do
        child_edges(
          agent,
          index,
          parent_index,
          paths,
          stubs,
          coords,
          nodes,
          ids,
          shift,
          merged_tips
        )
      else
        []
      end
    end)
  end

  defp child_edges(
         agent,
         index,
         parent_index,
         paths,
         stubs,
         coords,
         nodes,
         ids,
         shift,
         merged_tips
       ) do
    base = CommitGraph.sha_or_nil(Map.get(agent, :base_commit))
    fork = Map.get(coords, base)
    path = path_at(paths, index)
    stub = Map.get(stubs, index)

    spawn_to = spawn_target(path, stub, coords)
    source = merge_source(agent, path, stub, coords, merged_tips)
    child_id = Map.get(agent, :id)

    cond do
      # No usable fork node (nil / non-binary base, or absent from the node
      # set) — nothing to branch out from, so no agent-level edges at all.
      fork == nil ->
        []

      # The fork exists but there is nothing to connect it to (a no-op child
      # without its stub, or a vanished spawn target).
      spawn_to == nil ->
        []

      # The tip cannot land (not a node, or a real `:merge` already draws the
      # return) — only the spawn survives.
      source == nil ->
        [edge(base, fork, spawn_sha(path, stub), spawn_to, :spawn, child_id)]

      true ->
        parent_id = Enum.at(ids, parent_index)

        landing =
          landing(nodes, parent_id, elem(source, 1), parent_index + shift)

        [
          edge(base, fork, spawn_sha(path, stub), spawn_to, :spawn, child_id),
          merge_back_edge(source, landing, child_id)
        ]
    end
  end

  # The `:spawn` target: the child's OLDEST progress-path commit, or its
  # no-op stub when the path is empty.
  defp spawn_target(path, stub, coords) do
    case spawn_sha(path, stub) do
      nil -> nil
      sha -> Map.get(coords, sha)
    end
  end

  defp spawn_sha([], %{sha: sha}) when is_binary(sha), do: sha
  defp spawn_sha([], _stub), do: nil
  defp spawn_sha(path, _stub) when is_list(path), do: List.last(path)
  defp spawn_sha(_path, _stub), do: nil

  # The `:merge_back` source: the child's TIP node, or its no-op stub. A tip
  # that some commit already merges among its 2nd+ parents has its return
  # drawn by the dashed `:merge` edge, so it sources nothing here.
  defp merge_source(_agent, [], %{sha: sha}, coords, _merged_tips) when is_binary(sha) do
    Map.get(coords, sha)
  end

  defp merge_source(_agent, [], _stub, _coords, _merged_tips), do: nil

  defp merge_source(agent, path, _stub, coords, merged_tips) when is_list(path) do
    case CommitGraph.sha_or_nil(Map.get(agent, :current_commit)) do
      nil ->
        nil

      tip ->
        if MapSet.member?(merged_tips, tip), do: nil, else: Map.get(coords, tip)
    end
  end

  # Where the child's work lands in the parent's lane: the TOPMOST (min-row)
  # parent-owned node strictly below the source row — the nodes list is
  # row-sorted, so the first hit IS the topmost. When the parent lane has
  # nothing below yet, a VIRTUAL landing anchors on the parent's lane at the
  # source's own row (the renderer's endpoint fallback reads the column/row).
  # A nil parent id owns no node (unowned nodes carry owner_id nil too), so
  # it can only ever get the virtual landing.
  defp landing(nodes, parent_id, source_row, parent_lane) do
    case Enum.find(nodes, fn node ->
           parent_id != nil and Map.get(node, :owner_id) == parent_id and
             Map.get(node, :row, 0) > source_row
         end) do
      nil ->
        %{sha: nil, column: parent_lane, row: source_row}

      node ->
        %{sha: Map.get(node, :sha), column: Map.get(node, :column), row: Map.get(node, :row)}
    end
  end

  defp edge(from_sha, from, to_sha, to, kind, owner_id) do
    %{
      from_sha: from_sha,
      to_sha: to_sha,
      from_column: elem(from, 0),
      from_row: elem(from, 1),
      to_column: elem(to, 0),
      to_row: elem(to, 1),
      kind: kind,
      owner_id: owner_id
    }
  end

  defp merge_back_edge(source, landing, owner_id) do
    %{
      from_sha: elem(source, 2),
      to_sha: landing.sha,
      from_column: elem(source, 0),
      from_row: elem(source, 1),
      to_column: landing.column,
      to_row: landing.row,
      kind: :merge_back,
      owner_id: owner_id
    }
  end

  # --- Shape readers --------------------------------------------------------------

  # {column, row, sha} — the sha rides along so the merge_back source can
  # fill `from_sha` from its own position tuple.
  defp node_position(node) do
    {Map.get(node, :column), Map.get(node, :row), Map.get(node, :sha)}
  end

  defp path_at(paths, index) do
    case Enum.at(paths, index) do
      path when is_list(path) -> path
      _ -> []
    end
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp map_of(value) when is_map(value), do: value
  defp map_of(_value), do: %{}

  defp non_neg(value) when is_integer(value) and value >= 0, do: value
  defp non_neg(_value), do: 0
end
