defmodule EvoDashWeb.AgentsLive.FileTreeTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.FileTree

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "evo_file_tree_test_#{System.unique_integer([:positive])}"
      )

    # demo/fast/agent_1, demo/fast/agent_2, demo/slow/agent_1, docs, .git, .genesis
    for rel <- [
          "demo/fast/agent_1",
          "demo/fast/agent_2",
          "demo/slow/agent_1",
          "docs",
          ".git",
          ".genesis/workers"
        ] do
      File.mkdir_p!(Path.join(root, rel))
    end

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp names(nodes), do: Enum.map(nodes, & &1.name)

  defp find(nodes, name), do: Enum.find(nodes, &(&1.name == name))

  defp child(node, name), do: find(node.children, name)

  test "scan mirrors the real directory tree, skipping hidden/build dirs", %{root: root} do
    [root_node] = FileTree.scan(root)

    assert root_node.name == "."
    assert names(root_node.children) == ["demo", "docs"]

    demo = find(root_node.children, "demo")
    assert names(demo.children) == ["fast", "slow"]

    fast = find(demo.children, "fast")
    assert names(fast.children) == ["agent_1", "agent_2"]

    slow = find(demo.children, "slow")
    assert names(slow.children) == ["agent_1"]

    # No agents attached yet, hidden/build dirs excluded
    refute find(root_node.children, ".git")
    refute find(root_node.children, ".genesis")
    assert Enum.all?(root_node.children, &(&1.agents == []))
  end

  test "build_tree overlays agents onto their context_path nodes", %{root: root} do
    agents = [
      %{id: 13, context_path: "demo/fast/agent_2"},
      %{id: 6, context_path: "demo/slow/agent_1"},
      %{id: 1, context_path: "./"}
    ]

    [root_node] = root |> FileTree.scan() |> FileTree.build_tree(agents)

    assert [agent] = root_node.agents
    assert agent.id == 1

    demo = find(root_node.children, "demo")
    fast = find(demo.children, "fast")
    slow = find(demo.children, "slow")

    assert [%{id: 13}] = find(fast.children, "agent_2").agents
    assert find(fast.children, "agent_1").agents == []
    assert [%{id: 6}] = find(slow.children, "agent_1").agents
  end

  test "agents with paths missing on disk are appended as extra branches", %{root: root} do
    agents = [%{id: 9, context_path: "demo/fast/agent_7"}]

    [root_node] = root |> FileTree.scan() |> FileTree.build_tree(agents)

    fast = root_node.children |> find("demo") |> child("fast")
    assert names(fast.children) == ["agent_1", "agent_2", "agent_7"]
    assert [%{id: 9}] = find(fast.children, "agent_7").agents
  end

  test "build_tree with nil scan falls back to the agent-driven tree" do
    agents = [
      %{id: 2, context_path: "demo/slow/agent_1"},
      %{id: 1, context_path: "demo/fast/agent_1"}
    ]

    [root_node] = FileTree.build_tree(nil, agents)

    demo = find(root_node.children, "demo")
    assert names(demo.children) == ["fast", "slow"]
    assert [%{id: 1}] = demo.children |> find("fast") |> child("agent_1") |> Map.get(:agents)
    assert [%{id: 2}] = demo.children |> find("slow") |> child("agent_1") |> Map.get(:agents)
  end

  test "agents are sorted by id within a node" do
    agents = [
      %{id: 5, context_path: "demo/fast/agent_1"},
      %{id: 3, context_path: "demo/fast/agent_1"}
    ]

    [root_node] = FileTree.build_tree(nil, agents)

    node =
      root_node.children |> find("demo") |> child("fast") |> child("agent_1")

    assert [%{id: 3}, %{id: 5}] = node.agents
  end
end
