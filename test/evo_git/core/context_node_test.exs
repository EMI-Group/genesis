defmodule EvoGit.Core.ContextNodeTest do
  use ExUnit.Case
  alias EvoGit.Core.ContextNode

  @moduletag :tmp_dir

  test "hier_context/2 returns nodes from root to leaf", %{tmp_dir: tmp_dir} do
    # Setup structure
    # tmp_dir/
    # ├── CONTEXT.md (Root context)
    # └── lib/
    #     ├── CONTEXT.md (Lib context)
    #     └── my_module.ex

    File.write!(Path.join(tmp_dir, "CONTEXT.md"), "Root Context")
    File.mkdir!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "Lib Context")
    File.write!(Path.join(tmp_dir, "lib/my_module.ex"), "defmodule MyModule do end")

    target_path = Path.join(tmp_dir, "lib/my_module.ex")
    hierarchy = ContextNode.hier_context(target_path, tmp_dir)

    assert length(hierarchy) == 3

    [root_node, lib_node, file_node] = hierarchy

    assert root_node.type == :directory
    assert root_node.context_contract == "Root Context"
    assert root_node.path == tmp_dir

    assert lib_node.type == :directory
    assert lib_node.context_contract == "Lib Context"
    assert lib_node.path == Path.join(tmp_dir, "lib")

    assert file_node.type == :file
    assert file_node.context_contract == nil
    assert file_node.path == target_path
  end

  test "hier_context/2 handles missing intermediate contexts", %{tmp_dir: tmp_dir} do
    # tmp_dir/
    # └── nested/
    #     └── deep/
    #         └── file.txt

    File.mkdir_p!(Path.join(tmp_dir, "nested/deep"))
    target_path = Path.join(tmp_dir, "nested/deep/file.txt")
    # We don't create file, see if load handles it (it should treat as file)

    hierarchy = ContextNode.hier_context(target_path, tmp_dir)

    # root, nested, deep, file
    assert length(hierarchy) == 4

    assert Enum.at(hierarchy, 0).path == tmp_dir
    assert Enum.at(hierarchy, 1).path == Path.join(tmp_dir, "nested")
    assert Enum.at(hierarchy, 1).context_contract == nil
    assert Enum.at(hierarchy, 3).path == target_path
    assert Enum.at(hierarchy, 3).type == :file
  end

  test "hier_context/2 raises on invalid root", %{tmp_dir: tmp_dir} do
    assert_raise ArgumentError, fn ->
      ContextNode.hier_context("/etc/passwd", tmp_dir)
    end
  end
end
