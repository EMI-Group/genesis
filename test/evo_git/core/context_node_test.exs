defmodule EvoGit.Core.ContextNodeTest do
  use ExUnit.Case
  alias EvoGit.Core.ContextNode

  @moduletag :tmp_dir

  test "hier_context/2 returns nodes from root to leaf", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "CONTEXT.md"), "Root Context")
    File.mkdir!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "Lib Context")
    File.write!(Path.join(tmp_dir, "lib/my_module.ex"), "defmodule MyModule do end")

    target_path = Path.join(tmp_dir, "lib/my_module.ex")
    hierarchy = ContextNode.hier_context(target_path, tmp_dir)

    assert length(hierarchy) == 3
  end

  test "hier_context/2 handles missing intermediate contexts", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "nested/deep"))
    target_path = Path.join(tmp_dir, "nested/deep/file.txt")

    hierarchy = ContextNode.hier_context(target_path, tmp_dir)

    assert length(hierarchy) == 4
  end

  test "hier_context/2 raises on invalid root", %{tmp_dir: tmp_dir} do
    assert_raise ArgumentError, fn ->
      ContextNode.hier_context("/etc/passwd", tmp_dir)
    end
  end

  test "hier_context/2 with dot relative path", %{tmp_dir: tmp_dir} do
    # we need to be inside a valid hierarchy for . to work or use an absolute path
    # But since "." resolves to File.cwd!(), which is not inside tmp_dir, it correctly raises ArgumentError
    assert_raise ArgumentError, fn ->
      ContextNode.hier_context(".", tmp_dir)
    end
  end

  test "hier_context/2 with absolute root path", %{tmp_dir: tmp_dir} do
    hierarchy = ContextNode.hier_context(tmp_dir, tmp_dir)
    assert length(hierarchy) == 1
    assert Enum.at(hierarchy, 0).path == tmp_dir
  end

  test "hier_context/2 with path outside root returns ArgumentError", %{tmp_dir: tmp_dir} do
    assert_raise ArgumentError, fn ->
      ContextNode.hier_context("../outside", tmp_dir)
    end
  end
end
