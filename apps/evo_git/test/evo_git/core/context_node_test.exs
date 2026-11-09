defmodule EvoGit.Core.ContextNodeTest do
  @moduledoc """
  Pure/tmp-dir-isolated: exercises `ContextNode` path/normalization helpers plus
  `@moduletag :tmp_dir` fixtures only — no BEAM-global mutation — so `async: true`.

  The VCT-backed cases (`vct_path`, global context) each start their OWN
  `EvoGit.VCT` instance with a unique registered name and `data_dir: tmp_dir`,
  then point the CALLING test process at it through the `:evogit_vct_server`
  process-dictionary seam, so the app-global singleton is never touched and the
  unique names keep the cases concurrent.
  """
  use ExUnit.Case, async: true
  alias EvoGit.Core.ContextNode
  alias EvoGit.VCT

  @moduletag :tmp_dir

  ## Helpers

  # Isolated VCT instance whose data dir (and therefore its `vct/CONTEXT.md`
  # global context) lives under this test's tmp_dir.
  defp start_vct(tmp_dir, opts \\ []) do
    name = :"vct_context_node_#{System.unique_integer([:positive])}"

    start_args =
      Keyword.merge([name: name, data_dir: tmp_dir], opts)

    Process.put(:evogit_vct_server, name)
    start_supervised!({VCT, start_args}, id: name)

    %{name: name, vct_dir: Path.join(tmp_dir, "vct")}
  end

  defp fence_count(output), do: length(:binary.matches(output, "```"))

  defp write_global_context!(%{vct_dir: vct_dir}, content) do
    File.mkdir_p!(vct_dir)
    File.write!(Path.join(vct_dir, "CONTEXT.md"), content)
  end

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

    test "keeps a UNC repo root intact" do
      node = ContextNode.load("src/foo", "//wsl.localhost/Ubuntu-22.04/home/user/proj")
      assert node.repo == "//wsl.localhost/Ubuntu-22.04/home/user/proj"
      assert node.path == "./src/foo"

      bs_node = ContextNode.load("src/foo", "\\\\wsl.localhost\\Ubuntu-22.04\\home\\user\\proj")
      assert bs_node.repo == "\\\\wsl.localhost\\Ubuntu-22.04\\home\\user\\proj"
      assert bs_node.path == "./src/foo"
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

  test "hierarchy_nodes/3 keeps a UNC repo root on every node" do
    unc_root = "//wsl.localhost/Ubuntu-22.04/home/user/proj"

    {:ok, nodes} = ContextNode.hierarchy_nodes("./src/a.ex", unc_root, "primary")

    assert length(nodes) == 3
    assert Enum.map(nodes, & &1.path) == ["./", "./src", "./src/a.ex"]
    assert Enum.all?(nodes, &(&1.repo == unc_root))
    assert Enum.all?(nodes, &(&1.repo_id == "primary"))
  end

  describe "vct_path" do
    test "is the canonical VCT URL when the repo root is mounted", %{tmp_dir: tmp_dir} do
      start_vct(tmp_dir)
      proj_root = Path.join(tmp_dir, "proj")
      File.mkdir_p!(proj_root)

      assert {:ok, mount} = VCT.mount(proj_root, name: "proj")
      assert mount.point == "vct:///projects/proj"

      node = ContextNode.load("src/auth", proj_root)

      # `path` stays the byte-identical in-repo relative string.
      assert node.path == "./src/auth"
      assert node.repo == proj_root
      assert node.repo_id == "primary"
      assert node.vct_path == "vct:///projects/proj/src/auth"

      assert ContextNode.load(".", proj_root).path == "./"
      assert ContextNode.load(".", proj_root).vct_path == "vct:///projects/proj"

      assert ContextNode.load("./", proj_root).vct_path == "vct:///projects/proj"
    end

    test "every hierarchy node carries its own VCT path", %{tmp_dir: tmp_dir} do
      start_vct(tmp_dir)
      proj_root = Path.join(tmp_dir, "proj")
      File.mkdir_p!(proj_root)

      assert {:ok, _mount} = VCT.mount(proj_root, name: "proj")

      assert {:ok, nodes} = ContextNode.hierarchy_nodes("src/auth", proj_root, "primary")

      assert Enum.map(nodes, & &1.path) == ["./", "./src", "./src/auth"]

      assert Enum.map(nodes, & &1.vct_path) == [
               "vct:///projects/proj",
               "vct:///projects/proj/src",
               "vct:///projects/proj/src/auth"
             ]
    end

    test "is nil for an unmounted repository", %{tmp_dir: tmp_dir} do
      # No mount at all in this isolated VCT.
      start_vct(tmp_dir)
      repo = Path.join(tmp_dir, "not-mounted")

      assert ContextNode.load("src/auth", repo).vct_path == nil
      assert ContextNode.load(".", repo).vct_path == nil

      assert {:ok, nodes} = ContextNode.hierarchy_nodes("src/auth", repo, "primary")
      assert Enum.all?(nodes, &is_nil(&1.vct_path))
    end

    test "a foreign repo_id does not change path/vct_path semantics", %{tmp_dir: tmp_dir} do
      start_vct(tmp_dir)
      proj_root = Path.join(tmp_dir, "proj")
      File.mkdir_p!(proj_root)

      assert {:ok, _mount} = VCT.mount(proj_root, name: "proj")

      node = ContextNode.load("src/auth", proj_root, "api")

      assert node.repo_id == "api"
      assert node.path == "./src/auth"
      assert node.vct_path == "vct:///projects/proj/src/auth"
      assert node.repo == proj_root

      assert {:ok, nodes} = ContextNode.hierarchy_nodes("./", proj_root, "api")
      assert Enum.all?(nodes, &(&1.repo_id == "api"))
      assert [%{vct_path: "vct:///projects/proj"}] = nodes
    end
  end

  describe "build_context/2 stages" do
    defp build_repo!(tmp_dir, files) do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)

      Enum.each(files, fn {relative, content} ->
        path = Path.join(repo, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
      end)

      repo
    end

    defp stages_of(output) do
      [stages, _location] = String.split(output, "Current Repository (worktree):", parts: 2)
      stages
    end

    test "prepends the VCT global context as global/CONTEXT.md", %{tmp_dir: tmp_dir} do
      vct = start_vct(tmp_dir)
      write_global_context!(vct, "# Global\nGlobal rules\n")

      repo =
        build_repo!(tmp_dir, [
          {"CONTEXT.md", "# Root\nroot body\n"},
          {"lib/CONTEXT.md", "# Lib\nlib body\n"}
        ])

      assert {:ok, output} = ContextNode.build_context("./lib", repo)

      # Global first, then the in-repo chain in hierarchy order.
      {global_at, _} = :binary.match(output, "File: global/CONTEXT.md")
      {root_at, _} = :binary.match(output, "File: ./CONTEXT.md")
      {lib_at, _} = :binary.match(output, "File: ./lib/CONTEXT.md")

      assert global_at < root_at
      assert root_at < lib_at

      assert String.starts_with?(
               output,
               "# Context Tree\nFile: global/CONTEXT.md\n```\n# Global\nGlobal rules\n```\n\n"
             )

      assert output =~ "root body"
      assert output =~ "lib body"

      # The global stage is labelled `global/CONTEXT.md` only — never the VCT
      # URL and never an OS path.
      refute stages_of(output) =~ "vct:///"
      refute stages_of(output) =~ tmp_dir
      refute output =~ "vct:///"
    end

    test "skips a directory stage whose CONTEXT.md is absent", %{tmp_dir: tmp_dir} do
      start_vct(tmp_dir)
      repo = build_repo!(tmp_dir, [{"CONTEXT.md", "# Root\nroot body\n"}])

      # `lib` exists but carries no CONTEXT.md.
      File.mkdir_p!(Path.join(repo, "lib"))

      assert {:ok, output} = ContextNode.build_context("./lib", repo)

      assert output =~ "File: ./CONTEXT.md"
      refute output =~ "File: ./lib/CONTEXT.md"
      # Exactly one rendered stage -> one opening + one closing fence.
      assert fence_count(output) == 2
    end

    test "skips a front-matter-only CONTEXT.md", %{tmp_dir: tmp_dir} do
      start_vct(tmp_dir)

      repo =
        build_repo!(tmp_dir, [
          {"CONTEXT.md", "---\nname: x\n---\n"},
          {"lib/CONTEXT.md", "# Lib\nlib body\n"}
        ])

      assert {:ok, output} = ContextNode.build_context("./lib", repo)

      refute output =~ "File: ./CONTEXT.md"
      assert output =~ "File: ./lib/CONTEXT.md"
      assert output =~ "lib body"
      assert fence_count(output) == 2
    end

    test "falls back to the location-only output when nothing renders", %{tmp_dir: tmp_dir} do
      start_vct(tmp_dir)

      repo = build_repo!(tmp_dir, [{"src/mod.ex", "defmodule Mod do end\n"}])

      assert {:ok, output} = ContextNode.build_context("./src", repo)

      refute output =~ "# Context Tree"
      refute output =~ "```"
      assert String.starts_with?(output, "Current Repository (worktree)")
      assert output =~ "Current Assigned Node: './src'"
    end

    test "blank or front-matter-only global context contributes nothing", %{tmp_dir: tmp_dir} do
      vct = start_vct(tmp_dir)
      repo = build_repo!(tmp_dir, [{"CONTEXT.md", "# Root\nroot body\n"}])

      write_global_context!(vct, "   \n\t\n")
      assert {:ok, blank_output} = ContextNode.build_context("./", repo)
      refute blank_output =~ "File: global/CONTEXT.md"

      write_global_context!(vct, "---\nname: x\n---\n")
      assert {:ok, fm_output} = ContextNode.build_context("./", repo)
      refute fm_output =~ "File: global/CONTEXT.md"

      # Only the repo's own root stage renders.
      assert fm_output == blank_output
      assert fence_count(fm_output) == 2
    end

    test "no global context file at all renders the in-repo chain unchanged", %{tmp_dir: tmp_dir} do
      start_vct(tmp_dir)

      repo =
        build_repo!(tmp_dir, [
          {"CONTEXT.md", "# Root\nroot body\n"},
          {"lib/CONTEXT.md", "# Lib\nlib body\n"}
        ])

      assert {:ok, output} = ContextNode.build_context("./lib", repo)

      assert String.starts_with?(output, "# Context Tree\nFile: ./CONTEXT.md\n")
      refute output =~ "File: global/CONTEXT.md"
      assert fence_count(output) == 4
    end
  end
end
