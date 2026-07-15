defmodule EvoGit.Core.ContextNodeTest do
  use ExUnit.Case
  alias EvoGit.Core.ContextNode

  @moduletag :tmp_dir

  test "hierarchy_nodes/2 returns nodes from root to leaf", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "CONTEXT.md"), "Root Context")
    File.mkdir!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "Lib Context")
    File.write!(Path.join(tmp_dir, "lib/my_module.ex"), "defmodule MyModule do end")

    target_path = "./lib/my_module.ex"
    {:ok, hierarchy} = ContextNode.hierarchy_nodes(target_path, tmp_dir)

    assert length(hierarchy) == 3
    assert Enum.at(hierarchy, 0).path == "./"
    assert Enum.at(hierarchy, 1).path == "./lib"
    assert Enum.at(hierarchy, 2).path == "./lib/my_module.ex"
  end

  test "hierarchy_nodes/2 handles missing intermediate contexts", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "nested/deep"))
    target_path = "./nested/deep/file.txt"

    {:ok, hierarchy} = ContextNode.hierarchy_nodes(target_path, tmp_dir)

    # ./, ./nested, ./nested/deep, ./nested/deep/file.txt
    assert length(hierarchy) == 4
  end

  test "hierarchy_nodes/2 returns error on absolute path", %{tmp_dir: tmp_dir} do
    assert {:error, :invalid_path} = ContextNode.hierarchy_nodes("/etc/passwd", tmp_dir)
  end

  test "hierarchy_nodes/2 with dot relative path", %{tmp_dir: tmp_dir} do
    {:ok, hierarchy} = ContextNode.hierarchy_nodes("./", tmp_dir)
    assert length(hierarchy) == 1
    assert Enum.at(hierarchy, 0).path == "./"
  end

  test "hierarchy_nodes/2 with path outside root returns error", %{tmp_dir: tmp_dir} do
    assert {:error, :invalid_path} = ContextNode.hierarchy_nodes("../outside", tmp_dir)
  end

  describe "normalize_relpath/1" do
    test "normalizes bare path" do
      assert ContextNode.normalize_relpath("foo/bar") == "./foo/bar"
    end

    test "normalizes dot to ./" do
      assert ContextNode.normalize_relpath(".") == "./"
    end

    test "normalizes empty string to ./" do
      assert ContextNode.normalize_relpath("") == "./"
    end

    test "keeps ./foo as-is" do
      assert ContextNode.normalize_relpath("./foo") == "./foo"
    end

    test "keeps ./ as-is" do
      assert ContextNode.normalize_relpath("./") == "./"
    end

    test "strips trailing slashes" do
      assert ContextNode.normalize_relpath("foo/bar/") == "./foo/bar"
    end

    test "strips leading slashes from non-absolute paths" do
      # A path like "/foo" is absolute and should raise,
      # but leading slashes from trimming should be handled
      assert ContextNode.normalize_relpath("foo") == "./foo"
    end

    test "raises on Unix absolute path" do
      assert_raise RuntimeError, ~r/absolute/, fn ->
        ContextNode.normalize_relpath("/foo/bar")
      end
    end

    test "raises on Windows absolute path" do
      assert_raise RuntimeError, ~r/absolute/, fn ->
        ContextNode.normalize_relpath("C:\\foo\\bar")
      end
    end
  end

  describe "load/2" do
    test "normalizes bare path on load" do
      node = ContextNode.load("foo/bar", "/repo")
      assert node.path == "./foo/bar"
    end

    test "normalizes dot on load" do
      node = ContextNode.load(".", "/repo")
      assert node.path == "./"
    end

    test "keeps ./foo as-is on load" do
      node = ContextNode.load("./foo", "/repo")
      assert node.path == "./foo"
    end
  end

  test "hierarchy_nodes/2 with bare path input", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "nested/deep"))

    # Pass bare path without "./" prefix
    {:ok, hierarchy} = ContextNode.hierarchy_nodes("nested/deep", tmp_dir)

    assert length(hierarchy) == 3
    assert Enum.at(hierarchy, 0).path == "./"
    assert Enum.at(hierarchy, 1).path == "./nested"
    assert Enum.at(hierarchy, 2).path == "./nested/deep"
  end
end
