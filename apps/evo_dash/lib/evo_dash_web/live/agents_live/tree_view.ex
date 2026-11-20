defmodule EvoDashWeb.AgentsLive.TreeView do
  @moduledoc """
  Spatial tree assembly for the Agents page.
  It groups the agent list per repository and builds each repository's
  context-path tree, so the LiveView never repeats the tree work.
  The repository grouping key and its display name delegate to the pure
  `EvoDashWeb.AgentsLive.CommitGraph` module, which the temporal commit-graph
  view shares, so both views name a repo identically.
  Every function is TOTAL over the shapes the agent list actually carries: a
  row without a context path is placed at the "./" root.
  """

  alias EvoDashWeb.AgentsLive.CommitGraph

  @doc """
  Builds the rendered `[{display_name, tree}]` repository list, sorted by
  display name.
  """
  @spec build_repo_trees([map()]) :: [{String.t(), [map()]}]
  def build_repo_trees(agents) do
    agents
    |> Enum.group_by(&grouping_key/1)
    |> Enum.map(fn {key, repo_agents} ->
      display_name = repo_display_name(key)
      tree = build_path_tree(repo_agents)
      # Rename the "." root node to the repo display name so each repo has a distinct root
      tree = rename_root(tree, display_name)
      {display_name, tree}
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  # Repo grouping / display naming lives in the pure CommitGraph module (shared
  # with the temporal commit-graph view); keep these delegates so the tree path is
  # unchanged.
  defp grouping_key(agent), do: CommitGraph.grouping_key(agent)

  defp repo_display_name(key), do: CommitGraph.repo_display_name(key)

  defp rename_root(nodes, new_name) do
    Enum.map(nodes, fn
      %{name: "."} = node -> %{node | name: new_name}
      node -> node
    end)
  end

  defp build_path_tree(agents) do
    tree =
      Enum.reduce(agents, %{}, fn agent, acc ->
        path = agent.context_path || "./"
        path = if path == "/", do: "./", else: path

        segments =
          path
          |> Path.split()
          |> case do
            ["." | rest] -> ["." | rest]
            other -> ["." | other]
          end

        insert_into_tree(acc, segments, [], agent)
      end)

    sort_tree(tree)
  end

  defp insert_into_tree(tree, [], _acc_segments, _agent), do: tree

  defp insert_into_tree(tree, [segment | rest], acc_segments, agent) do
    current_segments = acc_segments ++ [segment]
    current_path = Path.join(current_segments)

    node = Map.get(tree, segment, %{name: segment, path: current_path, agents: [], children: %{}})

    if rest == [] do
      node = %{node | agents: [agent | node.agents]}
      Map.put(tree, segment, node)
    else
      node = %{node | children: insert_into_tree(node.children, rest, current_segments, agent)}
      Map.put(tree, segment, node)
    end
  end

  defp sort_tree(tree) do
    tree
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn node ->
      %{node | children: sort_tree(node.children), agents: Enum.sort_by(node.agents, & &1.id)}
    end)
  end
end
