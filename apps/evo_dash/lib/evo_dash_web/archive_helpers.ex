defmodule EvoDashWeb.ArchiveHelpers do
  @moduledoc """
  Shared archive tree helpers for building agent hierarchies from archive metadata.

  `build_archive_tree/1` / `build_archive_tree_for_review/1` build the FULL tree
  (they normalize and group every record), which is unbounded work on a huge
  archive blob (a single task can carry 100k records). Render sites should use
  the capped builders instead:

    * `build_tree_capped/2` — `%{agent:, children:}` node maps (dashboard shape)
    * `build_review_tree_capped/2` — `{agent, children}` tuple nodes (review shape)

  Both cap the record list BEFORE any key normalization / grouping, preferring
  root records so the rendered slice still contains a renderable tree.
  """

  # Default cap for the capped tree builders below. Chosen so a single render
  # stays bounded (~100 nodes × a capped preview each) while still showing the
  # whole hierarchy of a normal multi-agent task.
  @default_max_records 100

  @known_agent_keys %{
    "agent_id" => :agent_id,
    "parent_id" => :parent_id,
    "depth" => :depth,
    "started_at" => :started_at,
    "completed_at" => :completed_at,
    "objective" => :objective,
    "result" => :result,
    "base_commit" => :base_commit,
    "final_commit" => :final_commit,
    "archive_ref_start" => :archive_ref_start,
    "archive_ref_final" => :archive_ref_final,
    "branch_name" => :branch_name,
    "usage" => :usage,
    "input_tokens" => :input_tokens,
    "output_tokens" => :output_tokens,
    "total_tokens" => :total_tokens,
    "model" => :model,
    "spec" => :spec
  }

  # Real keys the core writes into each per-agent archive record's nested usage
  # map (EvoGit agent/tools/complete_task.ex `format_usage_for_archive/1`).
  # There is deliberately NO plain "cost" key — cost lives in
  # input_cost/output_cost/total_cost (cache_hit_rate is also written).
  @usage_keys %{
    "input_tokens" => :input_tokens,
    "output_tokens" => :output_tokens,
    "total_tokens" => :total_tokens,
    "cached_tokens" => :cached_tokens,
    "cache_creation_tokens" => :cache_creation_tokens,
    "input_cost" => :input_cost,
    "output_cost" => :output_cost,
    "total_cost" => :total_cost,
    "cache_hit_rate" => :cache_hit_rate
  }

  @doc "Read a value from an agent map regardless of whether keys are atoms or strings."
  def agent_key(agent, key) when is_atom(key) do
    case Map.fetch(agent, key) do
      {:ok, v} -> v
      :error -> Map.get(agent, Atom.to_string(key))
    end
  end

  @doc "Normalize top-level string keys to atoms using the known keys whitelist."
  def normalize_agent_keys(agent) when is_map(agent) do
    Map.new(agent, fn
      {key, value} when is_atom(key) ->
        {key, normalize_usage_value(key, value)}

      {key, value} when is_binary(key) ->
        {Map.get(@known_agent_keys, key, key), normalize_usage_value(key, value)}
    end)
  end

  def normalize_agent_keys(agent), do: agent

  # The nested per-agent `usage` sub-map also arrives string-keyed after the DB
  # round-trip (plain Jason encode/decode, no key re-atomization in the core).
  # Atomize its keys via the usage whitelist so render sites can read
  # `usage[:input_tokens]` / `usage[:total_cost]` etc.; unknown keys are
  # preserved as-is (never bare `String.to_atom`). Atom-keyed and non-map
  # usage values pass through unchanged.
  defp normalize_usage_value(key, value) when key in [:usage, "usage"] and is_map(value),
    do: normalize_usage_keys(value)

  defp normalize_usage_value(_key, value), do: value

  @doc "Normalize a usage sub-map's string keys to atoms via the usage whitelist."
  def normalize_usage_keys(usage) when is_map(usage) do
    Map.new(usage, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {Map.get(@usage_keys, key, key), value}
    end)
  end

  def normalize_usage_keys(usage), do: usage

  @doc "Build nested tree for dashboard components (returns %{agent:, children:} maps)"
  def build_archive_tree(agents) when is_list(agents) do
    agents = Enum.map(agents, &normalize_agent_keys/1)
    by_parent = Enum.group_by(agents, &agent_key(&1, :parent_id))

    by_parent
    |> Map.get(nil, [])
    |> Enum.filter(&(agent_key(&1, :agent_id) not in [nil, ""]))
    |> Enum.map(fn agent -> build_archive_node(agent, by_parent, MapSet.new()) end)
  end

  @doc "Build nested tree for review components (returns {agent, children} tuples)"
  def build_archive_tree_for_review(agents) do
    agents = Enum.map(agents, &normalize_agent_keys/1)

    by_parent =
      Enum.group_by(
        agents,
        fn agent ->
          case agent_key(agent, :parent_id) do
            nil -> nil
            id when is_binary(id) -> id
            _ -> nil
          end
        end
      )

    build_children = fn parent_id, visited, recurse ->
      (by_parent[parent_id] || [])
      |> Enum.filter(fn agent ->
        id = agent_key(agent, :agent_id)
        id not in [nil, ""] and not MapSet.member?(visited, id)
      end)
      |> Enum.map(fn agent ->
        id = agent_key(agent, :agent_id)
        {agent, recurse.(id, MapSet.put(visited, id), recurse)}
      end)
    end

    build_children.(nil, MapSet.new(), build_children)
  end

  # ---------------------------------------------------------------------------
  # Capped builders — bounded work per render (normalize/group ONLY the slice)
  # ---------------------------------------------------------------------------

  @doc """
  Builds a bounded dashboard tree (`%{agent:, children:}` node maps).

  Returns `%{tree: nodes, total: n, shown: n, truncated?: boolean}` where:

    * `total` — the true number of records in `records` (`0` for a non-list;
      non-map entries are not records and are ignored)
    * `shown` — the number of nodes actually PRESENT in the built tree (counted
      once, after building — records dropped as orphans/non-maps are not shown)
    * `truncated?` — true iff records were dropped by the cap

  Only the capped slice is key-normalized and grouped; the raw list is merely
  partitioned so root records (`parent_id` nil / `""` / non-binary) fill the
  slice first and the rendered tree stays renderable. Non-map entries are
  skipped, and a negative/garbage `max_records` falls back to the default.
  """
  def build_tree_capped(records, max_records \\ @default_max_records)

  def build_tree_capped(records, max_records), do: capped_tree(records, max_records, :map)

  @doc """
  Builds a bounded review tree (`{agent, children}` tuple nodes).

  Same contract as `build_tree_capped/2`; only the node shape differs.
  """
  def build_review_tree_capped(records, max_records \\ @default_max_records)

  def build_review_tree_capped(records, max_records),
    do: capped_tree(records, max_records, :tuple)

  # The single tree-building core shared by both capped builders. It receives
  # the ALREADY capped + normalized slice, so its cost is bounded by the cap.
  defp capped_tree(records, max_records, node_shape) when is_list(records) do
    limit = max_records_or_default(max_records)
    records = Enum.filter(records, &is_map/1)
    total = length(records)
    slice = capped_slice(records, limit)
    nodes = slice |> Enum.map(&normalize_agent_keys/1) |> build_capped_nodes()

    %{
      tree: shape_nodes(nodes, node_shape),
      total: total,
      shown: count_nodes(nodes),
      truncated?: length(slice) < total
    }
  end

  defp capped_tree(_records, _max_records, _node_shape),
    do: %{tree: [], total: 0, shown: 0, truncated?: false}

  # Roots first, then the remaining records in original order; never more than
  # `limit` entries. A shallow partition only — no per-record normalization.
  defp capped_slice(records, limit) do
    {roots, others} = Enum.split_with(records, &root_record?/1)
    Enum.take(roots ++ others, limit)
  end

  defp root_record?(record) do
    case raw_agent_value(record, :parent_id) do
      nil -> true
      "" -> true
      id when is_binary(id) -> false
      _other -> true
    end
  end

  # Atom-or-string-key read on a RAW (not yet normalized) record.
  defp raw_agent_value(record, key) when is_map(record) do
    case Map.fetch(record, key) do
      {:ok, value} -> value
      :error -> Map.get(record, Atom.to_string(key))
    end
  end

  defp raw_agent_value(_record, _key), do: nil

  # Grouping key: a record whose parent_id is missing/nil/""/non-binary is a
  # ROOT (mirrors `root_record?/1`, so the cap's root preference is honored).
  defp parent_key(agent) do
    case agent_key(agent, :parent_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp build_capped_nodes(agents) do
    by_parent = Enum.group_by(agents, &parent_key/1)

    by_parent
    |> Map.get(nil, [])
    |> Enum.filter(&renderable_agent?/1)
    |> Enum.map(&build_capped_node(&1, by_parent, MapSet.new()))
  end

  defp build_capped_node(agent, by_parent, visited) do
    id = agent_key(agent, :agent_id)

    children =
      if id in [nil, ""] do
        []
      else
        new_visited = MapSet.put(visited, id)

        by_parent
        |> Map.get(id, [])
        |> Enum.filter(fn child ->
          renderable_agent?(child) and
            not MapSet.member?(new_visited, agent_key(child, :agent_id))
        end)
        |> Enum.map(&build_capped_node(&1, by_parent, new_visited))
      end

    %{agent: agent, children: children}
  end

  defp renderable_agent?(agent), do: agent_key(agent, :agent_id) not in [nil, ""]

  defp shape_nodes(nodes, :map), do: nodes

  defp shape_nodes(nodes, :tuple),
    do: Enum.map(nodes, fn node -> {node.agent, shape_nodes(node.children, :tuple)} end)

  defp count_nodes(nodes), do: Enum.reduce(nodes, 0, &(1 + count_nodes(&1.children) + &2))

  defp max_records_or_default(max_records) when is_integer(max_records) and max_records >= 0,
    do: max_records

  defp max_records_or_default(_max_records), do: @default_max_records

  defp build_archive_node(agent, by_parent, visited) do
    id = agent_key(agent, :agent_id)

    children =
      if id in [nil, ""] do
        []
      else
        new_visited = MapSet.put(visited, id)

        by_parent
        |> Map.get(id, [])
        |> Enum.filter(fn child ->
          child_id = agent_key(child, :agent_id)
          child_id not in [nil, ""] and not MapSet.member?(new_visited, child_id)
        end)
        |> Enum.map(fn child -> build_archive_node(child, by_parent, new_visited) end)
      end

    %{agent: agent, children: children}
  end
end
