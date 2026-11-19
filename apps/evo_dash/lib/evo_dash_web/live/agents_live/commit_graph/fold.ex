defmodule EvoDashWeb.AgentsLive.CommitGraph.Fold do
  @moduledoc """
  Collapsing of per-agent commit runs for
  `EvoDashWeb.AgentsLive.CommitGraph`.

  The temporal view exists to show the AGENT DAG (fork → work → merge-back),
  not a GitLens-style commit list, so each lane's INTERIOR commits fold away by
  default and leave ONE synthetic gap row per run, toggled per run through the
  run's stable `fold_key`.

  A FOLDABLE RUN is a maximal stretch of HIDDEN entries inside ONE agent's
  lane (runs never cross lanes and never merge across an anchor). An entry is
  HIDDEN when it is a fetched commit (`kind: :commit`), it has an owner
  (unowned / neutral-lane nodes are never hidden) and it is not an ANCHOR. A
  run folds at length ≥ 1.

  ANCHORS are always visible:

    - every `kind: :base` / `kind: :noop` synthesized node;
    - every node carrying non-empty `refs`;
    - every node that is a fork point or a tip of ANY agent (a non-empty
      `start_ids` or `end_ids`);
    - the lane owner's own START (its OLDEST progress-path commit) and END
      (its tip) node.

  ## Fold keys

  `fold_key = "<agent_key>|<above_key>|<below_key>"`, where `agent_key` is the
  run owner's agent id (stringified) and `above_key`/`below_key` are the shas
  of the nearest VISIBLE (necessarily anchored) node of the same lane above and
  below the run, with `"^"` (nothing above) and `"$"` (nothing below)
  sentinels. The key therefore depends only on the commit set and the anchors,
  never on a rebuild's status/depth/usage figures, so a metadata refresh cannot
  reset a user's expansion.

  ## Gap nodes

  Every run emits EXACTLY ONE gap entry in BOTH states:

      %{sha: "gap-" <> fold_key, short_sha: "", message: "", author_name: nil,
        date: nil, date_unix: run head's, refs: [], kind: :gap, layer: run
        head's, sort_sha: run head's sha, owner_index: run owner,
        start_ids: [], end_ids: [], fold_key: fold_key,
        hidden_count: count(entries), expanded: boolean()}

  `sort_sha` keeps the gap in the run HEAD's row slot (the layout sorts by
  `{layer, date_unix, sha}`; the gap keeps its position without inventing a
  git-looking sha). When the run is EXPANDED the hidden entries are emitted
  too (original fields and order preserved) and the gap stays as the per-run
  COLLAPSE control.

  `fold/3` also returns the ALIAS MAP (`hidden sha → its run's gap sha`) for the
  COLLAPSED runs only, so `CommitGraph.Edges` can re-derive every edge over the
  FINAL visible node set: an inter-lane connector lands on a visible gap row
  instead of running into empty space, and an edge whose two endpoints alias to
  the same node is dropped by the edge derivation.

  Pure and total like the parent module: `Map.get/2` reads, no I/O, no socket,
  no processes; odd shapes degrade to "nothing hidden" instead of raising.
  """

  alias EvoDashWeb.AgentsLive.CommitGraph

  @above_sentinel "^"
  @below_sentinel "$"

  @typedoc """
  One foldable run: `%{fold_key, agent_index, head_sha, layer, date_unix,
  entries}`. `entries` are the run's hidden entries in layout order (the head
  is `List.first/1`), `agent_index` the owner's agent-order index and
  `layer`/`date_unix` the run HEAD's layout keys.
  """
  @type run :: %{
          fold_key: String.t(),
          agent_index: non_neg_integer(),
          head_sha: String.t(),
          layer: non_neg_integer(),
          date_unix: integer(),
          entries: [map()]
        }

  @doc """
  Detects the foldable runs of one repo.

  `entries` are the pre-layout node entries (fetched commits + synthesized base
  / no-op stub entries), `ordered` the repo's agents in agent order and `paths`
  each agent's progress path (newest → oldest, agent order). The result is
  sorted deterministically by `{agent_index, layer, date_unix, head_sha}`;
  every run is returned regardless of any expansion state, so the plan is the
  same in both states.
  """
  @spec plan([map()], [map()], [term()]) :: [run()]
  def plan(entries, ordered, paths) do
    anchors = anchors(entries, ordered, paths)

    entries
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&sort_key/1)
    |> Enum.reduce(%{}, fn entry, acc -> accumulate(entry, anchors, acc) end)
    |> Enum.flat_map(fn {lane, state} -> flush_lane(lane, state, ordered) end)
    |> Enum.sort_by(&{&1.agent_index, &1.layer, &1.date_unix, &1.head_sha})
  end

  @doc """
  The fold keys of `plan/3`'s runs — the "Expand all" driver.
  """
  @spec keys([run()]) :: MapSet.t(String.t())
  def keys(runs) do
    runs
    |> List.wrap()
    |> Enum.reduce(MapSet.new(), fn run, acc ->
      case Map.get(run, :fold_key) do
        key when is_binary(key) -> MapSet.put(acc, key)
        _ -> acc
      end
    end)
  end

  @doc """
  Folds `entries` for the `expanded` key set.

  Returns `{entries, aliases}`: the entries to lay out (collapsed runs replaced
  by their gap entry, expanded runs keeping both the gap and their hidden
  entries) and the collapsed-run alias map `hidden sha → gap sha` for the edge
  derivation. An `expanded` key that matches no run is simply ignored.
  """
  @spec fold([map()], [run()], MapSet.t(String.t())) ::
          {[map()], %{optional(term()) => String.t()}}
  def fold(entries, runs, expanded) do
    entries = entries |> List.wrap() |> Enum.filter(&is_map/1)
    runs = runs |> List.wrap() |> Enum.filter(&is_map/1)
    collapsed = Enum.reject(runs, &expanded?(&1, expanded))

    gap_by_head =
      Map.new(runs, fn run ->
        {Map.get(run, :head_sha), gap_entry(run, expanded?(run, expanded))}
      end)

    hidden_shas =
      collapsed
      |> Enum.flat_map(&run_entries/1)
      |> MapSet.new(fn entry -> Map.get(entry, :sha) end)

    aliases =
      Enum.reduce(collapsed, %{}, fn run, acc ->
        Enum.reduce(run_entries(run), acc, fn entry, acc ->
          case Map.get(entry, :sha) do
            sha when is_binary(sha) -> Map.put(acc, sha, gap_sha(run))
            _ -> acc
          end
        end)
      end)

    folded =
      Enum.flat_map(entries, fn entry ->
        sha = Map.get(entry, :sha)

        case Map.fetch(gap_by_head, sha) do
          {:ok, gap} ->
            if MapSet.member?(hidden_shas, sha), do: [gap], else: [gap, entry]

          :error ->
            if MapSet.member?(hidden_shas, sha), do: [], else: [entry]
        end
      end)

    {folded, aliases}
  end

  # --- Run detection -------------------------------------------------------

  defp accumulate(entry, anchors, acc) do
    lane = Map.get(entry, :owner_index)
    state = Map.get(acc, lane, %{above: @above_sentinel, pending: [], runs: []})

    if hidden?(entry, anchors) do
      Map.put(acc, lane, %{state | pending: [entry | state.pending]})
    else
      state = flush(state, Map.get(entry, :sha))
      Map.put(acc, lane, %{state | above: Map.get(entry, :sha), runs: state.runs})
    end
  end

  defp flush(%{pending: []} = state, _below), do: state

  defp flush(state, below) do
    run = %{above: state.above, below: below, entries: Enum.reverse(state.pending)}
    %{state | pending: [], runs: [run | state.runs]}
  end

  defp flush_lane(lane, state, ordered) do
    state = flush(state, @below_sentinel)
    agent_key = agent_key(ordered, lane)

    state.runs
    |> Enum.reverse()
    |> Enum.map(fn run ->
      head = List.first(run.entries)

      %{
        fold_key: agent_key <> "|" <> run.above <> "|" <> run.below,
        agent_index: lane,
        head_sha: Map.get(head, :sha),
        layer: entry_layer(head),
        date_unix: entry_date(head),
        entries: run.entries
      }
    end)
  end

  defp hidden?(entry, anchors) do
    Map.get(entry, :kind) == :commit and is_integer(Map.get(entry, :owner_index)) and
      not MapSet.member?(anchors, Map.get(entry, :sha))
  end

  defp run_entries(run) do
    case Map.get(run, :entries) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp expanded?(run, expanded) do
    case Map.get(run, :fold_key) do
      key when is_binary(key) -> MapSet.member?(expanded, key)
      _ -> false
    end
  end

  defp agent_key(ordered, lane) do
    ordered
    |> List.wrap()
    |> Enum.at(lane || -1)
    |> case do
      agent when is_map(agent) -> CommitGraph.stringify(Map.get(agent, :id))
      _ -> "?"
    end
  end

  # --- Anchors -------------------------------------------------------------

  defp anchors(entries, ordered, paths) do
    declared =
      entries
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(MapSet.new(), fn entry, acc ->
        sha = Map.get(entry, :sha)

        if is_binary(sha) and anchor_entry?(entry) do
          MapSet.put(acc, sha)
        else
          acc
        end
      end)

    ordered
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.reduce(declared, fn {_agent, index}, acc ->
      paths
      |> path_at(index)
      |> lane_endpoints()
      |> Enum.reduce(acc, &MapSet.put(&2, &1))
    end)
  end

  defp anchor_entry?(entry) do
    Map.get(entry, :kind) in [:base, :noop] or
      ids(entry, :refs) != [] or
      ids(entry, :start_ids) != [] or
      ids(entry, :end_ids) != []
  end

  defp lane_endpoints([]), do: []

  defp lane_endpoints(path) do
    path
    |> Enum.filter(&is_binary/1)
    |> then(fn shas ->
      case shas do
        [] -> []
        _ -> [List.first(shas), List.last(shas)] |> Enum.uniq()
      end
    end)
  end

  defp ids(entry, key) do
    case Map.get(entry, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # --- Gap entries ---------------------------------------------------------

  defp gap_entry(run, expanded?) do
    %{
      sha: gap_sha(run),
      short_sha: "",
      message: "",
      author_name: nil,
      date: nil,
      date_unix: Map.get(run, :date_unix, 0),
      refs: [],
      kind: :gap,
      layer: Map.get(run, :layer, 0),
      # Keeps the gap in the run HEAD's row slot even though its own sha is
      # synthetic and would sort elsewhere.
      sort_sha: Map.get(run, :head_sha),
      owner_index: Map.get(run, :agent_index),
      start_ids: [],
      end_ids: [],
      fold_key: Map.get(run, :fold_key),
      hidden_count: length(run_entries(run)),
      expanded: expanded?
    }
  end

  defp gap_sha(run) do
    case Map.get(run, :fold_key) do
      key when is_binary(key) -> "gap-" <> key
      _ -> "gap-?"
    end
  end

  # --- Shape readers -------------------------------------------------------

  defp path_at(paths, index) do
    case Enum.at(List.wrap(paths), index) do
      path when is_list(path) -> path
      _ -> []
    end
  end

  defp sort_key(entry) do
    {entry_layer(entry), entry_date(entry), Map.get(entry, :sha)}
  end

  defp entry_layer(entry) do
    case Map.get(entry, :layer) do
      layer when is_integer(layer) -> layer
      _ -> 0
    end
  end

  defp entry_date(entry) do
    case Map.get(entry, :date_unix) do
      date when is_integer(date) -> date
      _ -> 0
    end
  end
end
