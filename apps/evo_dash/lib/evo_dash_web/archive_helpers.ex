defmodule EvoDashWeb.ArchiveHelpers do
  @moduledoc """
  Shared archive tree helpers for building agent hierarchies from archive metadata.

  The dashboard reads a task's archive ONE PAGE AT A TIME (100 entries per page, `include_results: false`), and each record's heavy `"result"` is absent unless results were explicitly requested, so every builder here operates on a PARTIAL page of records.
  A record whose `parent_id` matches no record in the loaded slice is PROMOTED to a top-level node (after the real roots) instead of being silently dropped, so every record in the slice renders exactly once.
  `result_loaded?/1` distinguishes "result not fetched yet" (key absent) from "fetched and empty" (key present, `nil`/`""`), and `merge_entry/2` folds a lazily fetched full entry back into the already-loaded page.
  Render sites use the capped builders, which normalize and group ONLY the slice they render:

    * `build_tree_capped/2` — `%{agent:, children:}` node maps (dashboard shape)
    * `build_review_tree_capped/2` — `{agent, children}` tuple nodes (review shape)

  Both cap the record list BEFORE any key normalization / grouping, preferring
  root records so the rendered slice still contains a renderable tree.
  Accumulated pages are bounded by a RETENTION WINDOW: `max_retained/0` (500 = 5 pages) is the most entries one render keeps, `retain_window/2,3` slides that window over the accumulated list (evicting the OLDEST entries and returning the running dropped count), `retained_page_bounds/3` reports the 1-based span of the RETAINED slice inside the whole loaded span, and `more_pages?/3` is the authoritative "can another page still be fetched" test.
  `page_bounds/2` is the no-eviction case of `retained_page_bounds/3`.
  `archive_opt?/1` is the single definition of "this task opted into archiving" (`opts[:archive]`).
  """

  # Default cap for the capped tree builders below. Chosen so a single render
  # stays bounded (~100 nodes × a capped preview each) while still showing the
  # whole hierarchy of a normal multi-agent task.
  @default_max_records 100

  # Retention bound for the accumulated archive pages held by one LiveView.
  # 500 = 5 pages of the 100-entry archive page size: enough for every agent of
  # a normal (≤500-agent) task to stay scrollable without eviction, while still
  # bounding the archive heap of a multi-thousand-agent task.
  @max_retained 500

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

  # ---------------------------------------------------------------------------
  # Partial-page helpers — result presence, lazy per-agent result folding,
  # and the "showing X–Y of Z" bounds of what is loaded.
  # ---------------------------------------------------------------------------

  @doc """
  True iff the record CARRIES a `result` key (atom or string keyed).

  Presence — not truthiness — is the discriminator: a paged archive read omits
  the key entirely until results are requested (`include_results: true`), so
  `nil`/`""` on a present key means "fetched, and genuinely empty". Non-map
  input is `false`.
  """
  def result_loaded?(record) when is_map(record),
    do: Map.has_key?(record, :result) or Map.has_key?(record, "result")

  def result_loaded?(_record), do: false

  @doc """
  Replaces the entry matching `full_entry`'s `agent_id` with `full_entry`, in
  place, preserving list order.

  `agent_id` is read through `agent_key/2`, so atom- and string-keyed pages
  interoperate. The list is returned unchanged when no entry matches, when
  `full_entry` has no usable `agent_id`, or when either argument is not a
  list/map. Never raises.
  """
  def merge_entry(entries, full_entry) when is_list(entries) and is_map(full_entry) do
    agent_id = agent_key(full_entry, :agent_id)

    if agent_id in [nil, ""] do
      entries
    else
      Enum.map(entries, fn
        entry when is_map(entry) ->
          if agent_key(entry, :agent_id) == agent_id, do: full_entry, else: entry

        entry ->
          entry
      end)
    end
  end

  def merge_entry(entries, _full_entry), do: entries

  # ---------------------------------------------------------------------------
  # Archive opt-in — the single definition of "this task archived".
  # ---------------------------------------------------------------------------

  @doc """
  True iff `opts` opted into archiving: `[archive: true]` (the dashboard) or
  `[archive: "true"]` (the CLI / task data plane).

  `opts[:archive]` is the ONLY opt-in signal — the summary map cannot say
  whether records actually exist, so this only decides whether the lazy archive
  disclosure renders at all. Anything else (non-list, no `:archive` key, another
  value) is false.
  """
  def archive_opt?(opts) when is_list(opts) do
    Enum.find_value(opts, false, fn
      {:archive, value} -> value in [true, "true"]
      _ -> nil
    end)
  end

  def archive_opt?(_opts), do: false

  # ---------------------------------------------------------------------------
  # Retention window — bounded accumulation of paged archive entries.
  # ---------------------------------------------------------------------------

  @doc """
  The most accumulated archive entries a single render keeps (`500`, i.e. 5
  pages of the 100-entry archive page size).

  It bounds a LiveView's archive heap for a multi-thousand-agent task while
  still letting every agent of a normal (≤500-agent) task stay scrollable
  without eviction.
  """
  def max_retained, do: @max_retained

  @doc """
  Slides the retention window over an accumulated entry list.

  Returns `{retained, dropped_total}`: when `entries` is a list longer than
  `max`, keeps the most RECENT `max` entries and adds the evicted (oldest) count
  to the running `dropped`; otherwise returns the list unchanged with the same
  `dropped_total`. `max` 0 is legal (keep nothing). TOTAL: a non-list `entries`
  yields `{[], dropped_total}`, a negative/garbage `dropped` counts as 0, and a
  negative/garbage `max` falls back to `max_retained/0`.
  """
  def retain_window(entries, dropped \\ 0, max \\ @max_retained)

  def retain_window(entries, dropped, max) when is_list(entries) do
    dropped_total = non_neg_count(dropped)
    limit = retention_limit(max)

    if length(entries) > limit do
      evicted = length(entries) - limit
      {Enum.take(entries, -limit), dropped_total + evicted}
    else
      {entries, dropped_total}
    end
  end

  def retain_window(_entries, dropped, _max), do: {[], non_neg_count(dropped)}

  @doc """
  1-based inclusive `{first, last}` bounds of the RETAINED slice inside the
  whole loaded span, accounting for entries evicted by the retention window.

  `first = dropped + 1` and `last = min(dropped + retained_count, total)`; both
  are `0` when nothing is retained (`retained_count <= 0`, `total <= 0`) or when
  `last` would precede `first`. TOTAL — negative/garbage arguments count as 0 and
  it never raises.
  """
  def retained_page_bounds(retained_count, dropped, total) do
    retained = non_neg_count(retained_count)
    skipped = non_neg_count(dropped)
    loaded_total = non_neg_count(total)
    first = skipped + 1
    last = min(skipped + retained, loaded_total)

    if retained == 0 or loaded_total == 0 or last < first do
      {0, 0}
    else
      {first, last}
    end
  end

  @doc """
  True iff more archive pages can still be fetched: `dropped + retained_count <
  total`.

  This is THE formula render sites use for "is a pager needed" — `length(retained)
  < total` is wrong once entries have been evicted. TOTAL: negative/garbage
  arguments count as 0.
  """
  def more_pages?(retained_count, dropped, total) do
    non_neg_count(dropped) + non_neg_count(retained_count) < non_neg_count(total)
  end

  @doc """
  1-based inclusive `{first, last}` bounds of the records loaded so far, for a
  "showing 1–100 of 7 149" label.

  This is `retained_page_bounds/3` with no eviction (`dropped = 0`): `last` is
  clamped to `total`, so a fully loaded page reports `{1, total}`; nothing loaded
  (or a negative/garbage count) reports `{0, 0}`.
  Pure — the label text is formatted by the render site.
  """
  def page_bounds(loaded_count, total), do: retained_page_bounds(loaded_count, 0, total)

  defp non_neg_count(count) when is_integer(count) and count > 0, do: count
  defp non_neg_count(_count), do: 0

  defp retention_limit(limit) when is_integer(limit) and limit >= 0, do: limit
  defp retention_limit(_limit), do: @max_retained

  # ---------------------------------------------------------------------------
  # Capped builders — bounded work per render (normalize/group ONLY the slice)
  # ---------------------------------------------------------------------------

  @doc """
  Builds a bounded dashboard tree (`%{agent:, children:}` node maps).

  Returns `%{tree: nodes, total: n, shown: n, truncated?: boolean}` where:

    * `total` — the true number of records in `records` (`0` for a non-list;
      non-map entries are not records and are ignored)
    * `shown` — the number of nodes actually PRESENT in the built tree,
      counted once after building (promoted orphans count; only non-map entries
      and records without an `agent_id` are not shown)
    * `truncated?` — true iff records were dropped by the cap

  Only the capped slice is key-normalized and grouped; the raw list is merely
  partitioned so root records (`parent_id` nil / `""` / non-binary) fill the
  slice first and the rendered tree stays renderable. Records in the slice whose
  parent was not loaded are promoted to top-level nodes. Non-map entries are
  skipped, and a negative/garbage `max_records` falls back to the default.
  """
  def build_tree_capped(records, max_records \\ @default_max_records)

  def build_tree_capped(records, max_records), do: capped_tree(records, max_records, :map)

  @doc """
  Builds a bounded review tree (`{agent, children}` tuple nodes).

  Same contract as `build_tree_capped/2`; only the node shape differs
  (`{agent, children}` tuples instead of `%{agent:, children:}` maps).
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

    roots =
      by_parent
      |> Map.get(nil, [])
      |> Enum.filter(&renderable_agent?/1)
      |> Enum.map(&build_capped_node(&1, by_parent, MapSet.new()))

    promote_orphans(agents, roots, by_parent, &build_capped_node/3)
  end

  # Orphan tolerance + cycle safety for every builder.
  #
  # A record that the root walk never reached is its own top-level node: either
  # its parent lives on a page that is not loaded (or is a broken record), or it
  # sits in a parent cycle with no root at all. Promotion runs AFTER the capped
  # slice is chosen (it only iterates what is already there), keeps input order,
  # and threads the already-rendered id set into each promoted subtree so a
  # self-parenting or cyclic record renders exactly ONCE.
  defp promote_orphans(records, root_nodes, by_parent, build_node) do
    initial_seen = nodes_ids(root_nodes)

    {promoted, _seen} =
      Enum.reduce(records, {[], initial_seen}, fn record, {acc, seen} ->
        id = agent_key(record, :agent_id)

        if id in [nil, ""] or MapSet.member?(seen, id) do
          {acc, seen}
        else
          node = build_node.(record, by_parent, seen)
          {[node | acc], MapSet.union(seen, nodes_ids([node]))}
        end
      end)

    root_nodes ++ Enum.reverse(promoted)
  end

  defp nodes_ids(nodes) do
    Enum.reduce(nodes, MapSet.new(), fn %{agent: agent, children: children}, acc ->
      acc
      |> MapSet.put(agent_key(agent, :agent_id))
      |> MapSet.union(nodes_ids(children))
    end)
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
end
