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

  # Isolated VCT instance whose mount table lives in THIS test's own SQLite
  # store (`:store`) and whose data dir (and therefore its `vct/CONTEXT.md`
  # global context) lives under this test's tmp_dir.
  #
  # The `:store` binding is load-bearing: `EvoGit.VCT` persists its mount list
  # through the store and READS it back at `init/1`, so an instance left on the
  # default `EvoGit.Store` would see the app-global mount table - every earlier
  # test's mounts, and point collisions such as `vct:///projects/proj-2`.
  defp start_vct(tmp_dir, opts \\ []) do
    unique = System.unique_integer([:positive])
    store_name = :"vct_context_node_store_#{unique}"
    db_path = Path.join(tmp_dir, "tasks.sqlite")
    # A byte copy of the schema-complete template: the seven migrations' DDL is
    # paid once per BEAM, not once per test.
    EvoGit.TestSupport.StoreTemplate.new!().(db_path)

    start_supervised!(
      Supervisor.child_spec({EvoGit.Store, data_dir: db_path, name: store_name}, id: store_name)
    )

    name = :"vct_context_node_#{unique}"

    start_args =
      Keyword.merge([name: name, data_dir: tmp_dir, store: store_name], opts)

    Process.put(:evogit_vct_server, name)
    Process.put(:evogit_test_store, store_name)
    start_supervised!({VCT, start_args}, id: name)

    %{name: name, store: store_name, vct_dir: Path.join(tmp_dir, "vct")}
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

  # Two-scope (`Shared` / `Local`) rendering: the VCT global stage and every
  # ANCESTOR stage render `:shared` only, the ASSIGNED node (the LAST node of the
  # hierarchy) renders `:all`. Reuses the private builders defined in the
  # `"build_context/2 stages"` describe above (they are module-level functions).
  describe "build_context/2 scopes (Shared vs Local)" do
    @local_marker "<!-- genesis:local -->"

    # HARD backward-compatibility pin: a chain with NO divider renders
    # BYTE-IDENTICALLY to the pre-scope renderer (every existing prompt stays
    # stable). The literal below is the WHOLE expected output, not a fragment.
    test "a divider-less chain renders byte-identically to the pre-scope output", %{
      tmp_dir: tmp_dir
    } do
      start_vct(tmp_dir)

      repo =
        build_repo!(tmp_dir, [
          {"CONTEXT.md", "# Root\nroot body\n"},
          {"lib/CONTEXT.md", "# Lib\nlib body\n"}
        ])

      assert {:ok, output} = ContextNode.build_context("./lib", repo)

      assert output ==
               "# Context Tree\nFile: ./CONTEXT.md\n```\n# Root\nroot body\n```\n\n" <>
                 "File: ./lib/CONTEXT.md\n```\n# Lib\nlib body\n```\n\n" <>
                 "Current Repository (worktree): '#{repo}'. The current working directory (cwd) is also set to the repository path.\n" <>
                 "Current Assigned Node: './lib'. You should be focusing on the context and files under this node.\n" <>
                 "IMPORTANT: The worktree path is fixed for this agent's lifetime and the cwd is set to it. Always use relative paths when referring to files in this repository.\n" <>
                 "IMPORTANT: Subagents you spawn each get their OWN isolated worktree with cwd automatically set correctly. Never include worktree paths or `cd` commands in subagent objectives — just tell them what to do (e.g., \"run `mix test`\")."
    end

    test "an ANCESTOR renders its Shared scope only", %{tmp_dir: tmp_dir} do
      start_vct(tmp_dir)

      repo =
        build_repo!(tmp_dir, [
          {"CONTEXT.md", "# Root\nshared rules\n" <> @local_marker <> "\nroot ops only\n"},
          {"lib/CONTEXT.md", "# Lib\nlib body\n"}
        ])

      assert {:ok, output} = ContextNode.build_context("./lib", repo)

      assert output =~ "shared rules"
      refute output =~ "root ops only"
      # The divider line itself is never content and never rendered.
      refute output =~ @local_marker
    end

    test "the ASSIGNED node renders BOTH scopes", %{tmp_dir: tmp_dir} do
      start_vct(tmp_dir)

      repo =
        build_repo!(tmp_dir, [
          {"CONTEXT.md", "# Root\nroot body\n"},
          {"lib/CONTEXT.md", "# Lib\nshared lib\n" <> @local_marker <> "\nlib ops\n"}
        ])

      assert {:ok, output} = ContextNode.build_context("./lib", repo)

      assert output =~ "shared lib"
      assert output =~ "lib ops"
      refute output =~ @local_marker
    end

    test "the VCT global stage renders its Shared scope only", %{tmp_dir: tmp_dir} do
      vct = start_vct(tmp_dir)

      write_global_context!(
        vct,
        "# Global\nshared global rules\n" <> @local_marker <> "\nglobal ops only\n"
      )

      repo = build_repo!(tmp_dir, [{"CONTEXT.md", "# Root\nroot body\n"}])

      assert {:ok, output} = ContextNode.build_context("./", repo)

      assert output =~ "File: global/CONTEXT.md"
      assert output =~ "shared global rules"
      refute output =~ "global ops only"
      refute output =~ @local_marker
    end

    test "an ancestor that is BLANK after scope selection is skipped", %{tmp_dir: tmp_dir} do
      start_vct(tmp_dir)

      # An all-Local ancestor: its Shared scope is empty, so it contributes NO
      # stage and NO empty fenced block.
      repo =
        build_repo!(tmp_dir, [
          {"CONTEXT.md", @local_marker <> "\nroot ops only\n"},
          {"lib/CONTEXT.md", "# Lib\nlib body\n"}
        ])

      assert {:ok, output} = ContextNode.build_context("./lib", repo)

      refute output =~ "File: ./CONTEXT.md"
      refute output =~ "root ops only"
      assert output =~ "File: ./lib/CONTEXT.md"
      # One stage only -> one opening + one closing fence.
      assert fence_count(output) == 2
    end

    test "an all-Local ASSIGNED node still renders exactly ONE stage", %{tmp_dir: tmp_dir} do
      start_vct(tmp_dir)

      repo =
        build_repo!(tmp_dir, [
          {"CONTEXT.md", "# Root\nroot body\n"},
          {"lib/CONTEXT.md", @local_marker <> "\nlib ops only\n"}
        ])

      assert {:ok, output} = ContextNode.build_context("./lib", repo)

      assert output =~ "File: ./lib/CONTEXT.md"
      assert output =~ "lib ops only"
      assert length(:binary.matches(output, "File: ./lib/CONTEXT.md")) == 1
      assert fence_count(output) == 4
    end

    test "build_context(\"./\", repo) renders the root's FULL file (both scopes)", %{
      tmp_dir: tmp_dir
    } do
      start_vct(tmp_dir)

      repo =
        build_repo!(tmp_dir, [
          {"CONTEXT.md", "# Root\nshared root\n" <> @local_marker <> "\nroot ops\n"}
        ])

      assert {:ok, output} = ContextNode.build_context("./", repo)

      # The root IS the assigned node here, so its Local scope renders too.
      assert output =~ "File: ./CONTEXT.md"
      assert output =~ "shared root"
      assert output =~ "root ops"
      refute output =~ @local_marker
    end

    test "front matter belongs to the Shared part and is stripped from it", %{tmp_dir: tmp_dir} do
      start_vct(tmp_dir)

      # Scope selection runs on the RAW content FIRST, so the front matter stays
      # in the Shared scope and `strip_front_matter/1` then removes it.
      repo =
        build_repo!(tmp_dir, [
          {"CONTEXT.md",
           "---\nskill: [ui-density]\n---\n# Root\nshared body\n" <>
             @local_marker <> "\nroot ops\n"},
          {"lib/CONTEXT.md", "# Lib\nlib body\n"}
        ])

      assert {:ok, output} = ContextNode.build_context("./lib", repo)

      assert output =~ "# Root\nshared body"
      refute output =~ "ui-density"
      refute output =~ "root ops"
    end
  end
end
