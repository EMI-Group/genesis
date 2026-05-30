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

    test "raises on absolute path" do
      assert_raise RuntimeError, ~r/absolute/, fn ->
        ContextNode.normalize_relpath("/foo/bar")
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

  describe "get_hierarchy_skills/2" do
    test "returns skills from root CONTEXT.md", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CONTEXT.md"), """
      ---
      skills:
        - skill-a
        - skill-b
      ---
      # Root context
      """)

      assert {:ok, skills} = ContextNode.get_hierarchy_skills("./", tmp_dir)
      assert Enum.sort(skills) == ["skill-a", "skill-b"]
    end

    test "returns union of skills from root to node", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CONTEXT.md"), """
      ---
      skills:
        - root-skill
      ---
      # Root context
      """)

      child_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(child_dir)
      File.write!(Path.join(child_dir, "CONTEXT.md"), """
      ---
      skills:
        - child-skill
      ---
      # Child context
      """)

      assert {:ok, skills} = ContextNode.get_hierarchy_skills("./lib", tmp_dir)
      assert Enum.sort(skills) == ["child-skill", "root-skill"]
    end

    test "returns empty list when no CONTEXT.md has skills", %{tmp_dir: tmp_dir} do
      assert {:ok, skills} = ContextNode.get_hierarchy_skills("./", tmp_dir)
      assert skills == []
    end

    test "returns empty list when CONTEXT.md has no front matter", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CONTEXT.md"), "# Just markdown, no front matter")
      assert {:ok, skills} = ContextNode.get_hierarchy_skills("./", tmp_dir)
      assert skills == []
    end

    test "filters out non-string skill entries", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CONTEXT.md"), """
      ---
      skills:
        - valid-skill
        - 123
        - true
      ---
      # Root context
      """)

      assert {:ok, skills} = ContextNode.get_hierarchy_skills("./", tmp_dir)
      assert skills == ["valid-skill"]
    end

    test "deduplicates skills across hierarchy levels", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CONTEXT.md"), """
      ---
      skills:
        - shared-skill
      ---
      # Root context
      """)

      child_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(child_dir)
      File.write!(Path.join(child_dir, "CONTEXT.md"), """
      ---
      skills:
        - shared-skill
      ---
      # Child context with same skill
      """)

      assert {:ok, skills} = ContextNode.get_hierarchy_skills("./lib", tmp_dir)
      assert skills == ["shared-skill"]
    end

    test "returns error on invalid path", %{tmp_dir: tmp_dir} do
      assert {:error, :invalid_path} = ContextNode.get_hierarchy_skills("../outside", tmp_dir)
    end

    test "handles non-existent intermediate directories gracefully", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CONTEXT.md"), """
      ---
      skills:
        - root-skill
      ---
      # Root context
      """)

      # ./nested doesn't exist as a directory in the filesystem, so it won't have a CONTEXT.md
      assert {:ok, skills} = ContextNode.get_hierarchy_skills("./nested/deep", tmp_dir)
      assert skills == ["root-skill"]
    end
  end

  describe "build_context strips YAML front matter" do
    test "strips front matter from CONTEXT.md in context output", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CONTEXT.md"), """
      ---
      skills:
        - some-skill
      ---
      # Root context
      This is the actual body.
      """)

      {:ok, context} = ContextNode.build_context("./", tmp_dir)
      # Should contain the body content
      assert context =~ "This is the actual body"
      # Should NOT contain the front matter
      refute context =~ "some-skill"
      refute context =~ "skills:"
    end

    test "context without front matter works as before", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CONTEXT.md"), "# Just markdown\n\nNo front matter here.")
      {:ok, context} = ContextNode.build_context("./", tmp_dir)
      assert context =~ "No front matter here"
      assert context =~ "# Just markdown"
    end
  end
end
