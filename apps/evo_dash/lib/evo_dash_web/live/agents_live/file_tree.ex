defmodule EvoDashWeb.AgentsLive.FileTree do
  @moduledoc """
  Builds the repo file tree for the Agents page.

  The tree mirrors the actual filesystem under the repo root (one node per
  directory) and agents are attached to the node matching their
  `context_path`. Directories without agents still appear, so the tree
  corresponds 1:1 with the file tree on disk; agent paths that do not exist
  on disk (stale or not-yet-created) are appended as extra branches.

  When the repo root is not a readable local directory (remote nodes, foreign
  repos), falls back to an agent-driven tree built from context paths only.
  """

  @skip_dirs ~w(.git .genesis node_modules deps _build .elixir_ls assets)
  @max_depth 6
  @max_dirs 800

  @type tree_node :: %{
          name: String.t(),
          path: String.t(),
          agents: list(),
          children: [tree_node]
        }

  @doc """
  Scans `repo_root` and returns the root node list (`[%{name: ".", ...}]`)
  with no agents attached. Pure filesystem read — result is meant to be
  cached per repo root.
  """
  @spec scan(String.t()) :: [tree_node]
  def scan(repo_root) do
    {children, _count} = scan_dir(repo_root, ".", 0, 0)
    [%{name: ".", path: ".", agents: [], children: children}]
  end

  @doc """
  Attaches agents to a scanned tree (or builds an agent-driven tree when
  `scanned` is nil) and returns the sorted root node list.
  """
  @spec build_tree([tree_node] | nil, [map]) :: [tree_node]
  def build_tree(scanned, agents)

  def build_tree(nil, agents) do
    agents
    |> Enum.reduce(%{name: ".", path: ".", agents: [], children: []}, fn agent, root ->
      put_into_root(root, segments(agent_path(agent)), agent)
    end)
    |> List.wrap()
    |> sort_tree()
  end

  def build_tree(scanned, agents) do
    scanned
    |> Enum.map(fn
      %{name: "."} = root ->
        Enum.reduce(agents, root, fn agent, r ->
          put_into_root(r, segments(agent_path(agent)), agent)
        end)

      other ->
        other
    end)
    |> sort_tree()
  end

  # ── Filesystem scan ──────────────────────────────────────────────────────

  defp scan_dir(abs, rel, depth, count) do
    if depth >= @max_depth or count >= @max_dirs do
      {[], count}
    else
      case File.ls(abs) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&File.dir?(Path.join(abs, &1)))
          |> Enum.reject(&(&1 in @skip_dirs or String.starts_with?(&1, ".")))
          |> Enum.sort()
          |> Enum.reduce({[], count}, fn entry, {nodes, c} ->
            c = c + 1
            child_rel = Path.join(rel, entry)
            {children, c} = scan_dir(Path.join(abs, entry), child_rel, depth + 1, c)
            node = %{name: entry, path: child_rel, agents: [], children: children}
            {[node | nodes], c}
          end)
          |> then(fn {nodes, c} -> {Enum.reverse(nodes), c} end)

        {:error, _} ->
          {[], count}
      end
    end
  end

  # ── Agent attachment ─────────────────────────────────────────────────────

  defp agent_path(agent) do
    path = Map.get(agent, :context_path) || "."
    if path == "/", do: ".", else: path
  end

  # "./demo/fast" → ["demo", "fast"]; "." / "./" → []
  defp segments(path) do
    path
    |> Path.split()
    |> Enum.reject(&(&1 in [".", "", "/"]))
  end

  defp put_into_root(node, [], agent), do: %{node | agents: [agent | node.agents]}

  defp put_into_root(node, segs, agent),
    do: %{node | children: put_agent(node.children, segs, agent)}

  defp put_agent([node | rest], [seg | segs], agent) do
    if node.name == seg do
      node =
        if segs == [] do
          %{node | agents: [agent | node.agents]}
        else
          %{node | children: put_agent(node.children, segs, agent)}
        end

      [node | rest]
    else
      [node | put_agent(rest, [seg | segs], agent)]
    end
  end

  defp put_agent([], [seg | segs], agent) do
    # Agent's context path does not exist on disk — append the branch so the
    # agent still shows up (marked by simply being an extra node).
    node = %{name: seg, path: seg, agents: [], children: []}
    put_agent([node], [seg | segs], agent)
  end

  # ── Sorting ──────────────────────────────────────────────────────────────

  defp sort_tree(nodes) do
    nodes
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn node ->
      %{
        node
        | children: sort_tree(node.children),
          agents: Enum.sort_by(node.agents, &Map.get(&1, :id, 0))
      }
    end)
  end
end
