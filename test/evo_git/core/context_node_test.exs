defmodule EvoGit.Core.ContextNodeTest do
  use ExUnit.Case
  alias EvoGit.Core.ContextNode

  @moduletag :tmp_dir

  test "hierarchy_nodes/2 returns nodes from root to leaf", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "CONTEXT.md"), "Root Context")
    File.mkdir!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "Lib Context")
    File.write!(Path.join(tmp_dir, "lib/my_module.ex"), "defmodule MyModule do end")

    target_path = "lib/my_module.ex"
    {:ok, hierarchy} = ContextNode.hierarchy_nodes(target_path, tmp_dir)

    assert length(hierarchy) == 3
    assert Enum.at(hierarchy, 0).path == "."
    assert Enum.at(hierarchy, 1).path == "lib"
    assert Enum.at(hierarchy, 2).path == "lib/my_module.ex"
  end

  test "hierarchy_nodes/2 handles missing intermediate contexts", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "nested/deep"))
    target_path = "nested/deep/file.txt"

    {:ok, hierarchy} = ContextNode.hierarchy_nodes(target_path, tmp_dir)

    # Missing leaf node (file.txt) shouldn't be loaded, meaning length is 3 (., nested, nested/deep)
    assert length(hierarchy) == 3
  end

  test "hierarchy_nodes/2 returns error on absolute path", %{tmp_dir: tmp_dir} do
    assert {:error, :invalid_path} = ContextNode.hierarchy_nodes("/etc/passwd", tmp_dir)
  end

  test "hierarchy_nodes/2 with dot relative path", %{tmp_dir: tmp_dir} do
    {:ok, hierarchy} = ContextNode.hierarchy_nodes(".", tmp_dir)
    assert length(hierarchy) == 1
    assert Enum.at(hierarchy, 0).path == "."
  end

  test "hierarchy_nodes/2 with path outside root returns error", %{tmp_dir: tmp_dir} do
    assert {:error, :invalid_path} = ContextNode.hierarchy_nodes("../outside", tmp_dir)
  end
end