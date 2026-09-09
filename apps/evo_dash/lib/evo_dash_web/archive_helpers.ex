defmodule EvoDashWeb.ArchiveHelpers do
  @moduledoc """
  Shared archive tree helpers for building agent hierarchies from archive metadata.
  """

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
