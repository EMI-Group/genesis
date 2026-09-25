defmodule EvoDashWeb.AgentsLive.CommitGraph.Interleave do
  @moduledoc """
  Layout internals of `EvoDashWeb.AgentsLive.CommitGraph`: the cycle-safe
  topological LAYERS, the no-op stubs and the global row / lane layout.

  The parent builder first turns every future node into an ENTRY — the final
  view fields plus the layout keys `layer`, `date_unix` and `owner_index` —
  then hands the entries here:

    - `layers/1` computes `sha → L` over the FETCHED commits: `L = 0` for a
      node with no present parents (roots), else `max(L(parent)) + 1`. The
      walk is a memoized DFS whose `visiting` set makes a malformed parent
      CYCLE terminate instead of recursing forever;
    - `noop_stubs/4` synthesizes one stub per NO-OP child agent (resolvable
      parent agent + binary base + EMPTY progress path) so an agent that
      forked but committed nothing still owns a row;
    - `layout/3` positions everything: each entry's owner resolves to its
      LANE (the owner's agent-order index shifted right by one when unowned
      nodes exist; a nil owner → the NEUTRAL lane 0), then ALL entries are
      globally sorted ascending by `{L, date_unix, sha}` and numbered `row`
      `0 .. n - 1` — parents strictly above children, parallel agents
      interleaved by date instead of forming per-agent blocks.

  Pure and total like the parent module: `Map.get/2` reads, no I/O, no
  socket, no processes; odd shapes degrade to empty instead of raising.
  """

  alias EvoDashWeb.AgentsLive.CommitGraph

  @typedoc """
  A synthesized no-op stub: `%{sha, agent_index, layer}`. `sha` is
  `"noop-" <> agent_key` (synthetic — it can never collide with a hex git
  sha), `agent_index` the child's agent-order index (the stub's owner) and
  `layer` one below the fork node's layer so the stub lands just under it.
  """
  @type stub :: %{sha: String.t(), agent_index: non_neg_integer(), layer: non_neg_integer()}

  # --- Layers -----------------------------------------------------------------

  @doc """
  Topological layers over the PRESENT parents: `L = 0` for a sha with no
  parents in the lookup, else `1 + max(L(parent))`.

  Ranking rather than trusting the fetch order matters: the fetch concatenates
  one `git log` per agent range, so the input list is not globally
  newest-first. `%DateTime{}` structs are never compared (term order looks at
  `day` before `month`/`year`).
  """
  @spec layers(map()) :: %{optional(term()) => non_neg_integer()}
  def layers(lookup) when is_map(lookup) do
    lookup
    |> Map.keys()
    |> Enum.reduce(%{}, fn sha, memo ->
      {memo, _layer} = layer(sha, lookup, memo, MapSet.new())
      memo
    end)
  end

  def layers(_lookup), do: %{}

  # Memoized DFS. A revisit inside the current walk (a malformed parent cycle)
  # returns 0 for the loop-closing edge, so every cycle terminates while the
  # acyclic majority of the graph still gets exact layers.
  defp layer(sha, lookup, memo, visiting) do
    case Map.fetch(memo, sha) do
      {:ok, layer} ->
        {memo, layer}

      :error ->
        if MapSet.member?(visiting, sha) do
          {memo, 0}
        else
          parents = present_parents(Map.get(lookup, sha), lookup)
          visiting = MapSet.put(visiting, sha)

          {memo, {max_parent_layer, parent_count}} =
            Enum.reduce(parents, {memo, {0, 0}}, fn parent, {memo, {max, count}} ->
              {memo, parent_layer} = layer(parent, lookup, memo, visiting)
              {memo, {max(max, parent_layer), count + 1}}
            end)

          layer = if parent_count == 0, do: 0, else: 1 + max_parent_layer
          {Map.put(memo, sha, layer), layer}
        end
    end
  end

  # The commit's parents that are themselves part of the fetched graph — only
  # those can be drawn, so only those shape the layer.
  defp present_parents(commit, lookup) do
    commit
    |> CommitGraph.parents_list()
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(lookup, &1))
  end

  # --- No-op stubs --------------------------------------------------------------

  @doc """
  One stub per NO-OP child agent: a child whose parent agent resolves within
  the same repo group, whose `:base_commit` is a usable sha and whose progress
  path is EMPTY (it forked but committed nothing — `current_commit` nil, equal
  to its base, or absent from the fetch).

  Without a stub such an agent would be invisible: it owns no node, so its
  lane would have no row. The stub sits at `fork layer + 1`, just below the
  fork it grew from (it IS the child's only row).
  """
  @spec noop_stubs([map()], [term()], map(), map()) :: [stub()]
  def noop_stubs(ordered, paths, parent_indices, layers) do
    ordered
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.flat_map(fn {agent, index} ->
      base = CommitGraph.sha_or_nil(Map.get(agent, :base_commit))
      path = path_at(paths, index)

      if is_integer(Map.get(parent_indices, index)) and base != nil and path == [] do
        [
          %{
            sha: "noop-" <> CommitGraph.stringify(Map.get(agent, :id)),
            agent_index: index,
            layer: Map.get(layers, base, 0) + 1
          }
        ]
      else
        []
      end
    end)
  end

  defp path_at(paths, index) do
    case Enum.at(List.wrap(paths), index) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # --- Layout -------------------------------------------------------------------

  @doc """
  Positions the entries into the final `nodes` list.

  Owner resolution first: an integer `owner_index` reads `{id, depth}` from
  the agent meta and takes LANE `owner_index + shift`; a nil owner is UNOWNED
  — the NEUTRAL lane 0, never shifted (the shift moves the AGENT lanes right
  to free lane 0 for exactly these nodes). Then one global sort ascending by
  `{layer, date_unix, sha}` (a missing date counts as 0) numbers the rows
  `0 .. n - 1`, every row unique — so `row_count == node_count`, parents sit
  strictly above children and a fork point sits above the child's first row.
  """
  @spec layout([map()], [{term(), non_neg_integer()}], non_neg_integer()) :: [map()]
  def layout(entries, meta, shift) do
    entries
    |> List.wrap()
    |> Enum.map(&position(&1, meta, shift))
    |> Enum.sort_by(&{&1.layer, &1.date_unix, &1.sha})
    |> Enum.with_index()
    |> Enum.map(fn {entry, row} -> node_view(entry, row) end)
  end

  defp position(entry, meta, shift) do
    case Map.get(entry, :owner_index) do
      index when is_integer(index) and index >= 0 ->
        {id, depth} = owner_meta(meta, index)

        entry
        |> Map.put(:owner_id, id)
        |> Map.put(:depth, depth)
        |> Map.put(:column, index + shift)

      _ ->
        entry
        |> Map.put(:owner_id, nil)
        |> Map.put(:depth, 0)
        |> Map.put(:column, 0)
    end
  end

  # `{agent_id, depth}` per agent-order index, so a node reads its owner's id
  # and depth without rescanning the agent list.
  defp owner_meta(meta, index) do
    case Enum.at(List.wrap(meta), index) do
      {id, depth} when is_integer(depth) and depth >= 0 -> {id, depth}
      _ -> {nil, 0}
    end
  end

  defp node_view(entry, row) do
    %{
      sha: entry.sha,
      short_sha: entry.short_sha,
      message: entry.message,
      author_name: entry.author_name,
      date: entry.date,
      refs: entry.refs,
      row: row,
      column: entry.column,
      depth: entry.depth,
      kind: entry.kind,
      owner_id: entry.owner_id,
      start_ids: entry.start_ids,
      end_ids: entry.end_ids
    }
  end
end
