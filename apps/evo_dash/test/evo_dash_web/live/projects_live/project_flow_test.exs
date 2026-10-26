defmodule EvoDashWeb.ProjectsLive.ProjectFlowTest do
  @moduledoc """
  Pure unit tests for the Windows project-open path fix and the cross-OS
  remote-project-path fix: `ProjectFlow.normalize_project_path/1` (the guard
  that stops relative input from being `Path.expand`-joined against the BEAM
  cwd), `normalize_remote_project_path/2` (absolute remote paths pass through
  verbatim, tilde input expands via the injectable `:remote_path_expand_runner`
  seam), `absolute_path_for_node?/2`, the node-aware foreign-repo seams
  `build_foreign_repo/4` / `repos_from_task_data/2` (local node →
  `ForeignRepo.new/3`; remote node → RAW root, no local `Path.expand`),
  `Project.load_foreign_repos/3`, and `Project.path_suggestions/2,3`.

  Pure functions — no LiveView harness or DB setup. Tests run on Linux CI but
  pin the REMOTE behavior regardless of host OS, so the remote branches use a
  fake non-local node atom.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.ProjectsLive.Project
  alias EvoDashWeb.ProjectsLive.ProjectFlow
  alias EvoGit.Core.ForeignRepo

  # Differs from `node()` (:nonode@nohost) so the remote branches run; the
  # tests never connect to it.
  @remote_node :"genesis_remote@127.0.0.1"

  describe "normalize_project_path/1" do
    test "rejects blank, whitespace-only, and relative input" do
      for blank <- ["", "   ", "\t\n "] do
        assert {:error, :blank} = ProjectFlow.normalize_project_path(blank)
      end

      # A bare project name ("Test") must never be cwd-joined into the Tauri
      # install dir; "~foo" never expands on any platform; volume-relative
      # ("D:Test") and root-relative ("\\Test") are relative.
      for relative <- ["Test", "D:Test", "\\Test", "~foo", "  Test  "] do
        assert {:error, :relative} = ProjectFlow.normalize_project_path(relative),
               "expected #{inspect(relative)} to be rejected"
      end
    end

    test "accepts Windows drive-letter, UNC/WSL and POSIX absolutes (shape only)" do
      # On Linux CI `Path.expand("D:\\Test")` cwd-joins/mangles — fine: the guard
      # is platform-independent, the filesystem isn't. Never touch the
      # filesystem with Windows paths.
      for windows_path <- ["D:\\Test", "D:/Test", "C:\\foo"] do
        assert {:ok, _expanded} = ProjectFlow.normalize_project_path(windows_path)
      end

      for unc_path <- ["//wsl.localhost/Ubuntu-22.04/home/user/proj", "\\\\server\\share\\proj"] do
        assert {:ok, expanded} = ProjectFlow.normalize_project_path(unc_path)

        # The double-separator UNC prefix must survive (never collapsed).
        assert String.starts_with?(expanded, "//") or String.starts_with?(expanded, "\\\\"),
               "UNC prefix corrupted for #{inspect(unc_path)}: got #{inspect(expanded)}"
      end

      # POSIX absolutes are idempotent, with surrounding whitespace trimmed.
      for posix <- ["/tmp/foo", "  /tmp/foo  "] do
        assert {:ok, "/tmp/foo"} = ProjectFlow.normalize_project_path(posix)
      end
    end

    test "expands a genuine tilde path against the home dir, never the BEAM cwd" do
      assert {:ok, expanded} = ProjectFlow.normalize_project_path("~/foo")
      assert String.starts_with?(expanded, Path.expand("~"))
      assert String.starts_with?(expanded, System.user_home!())

      refute String.contains?(expanded, File.cwd!()),
             "tilde expansion must not be cwd-joined"
    end
  end

  describe "path_suggestions/2" do
    test "relative input and relative recent-project entries never surface" do
      assert Project.path_suggestions("Test", []) == []
      # A stale cwd-joined recents entry (from the pre-fix behavior) must not
      # render in the palette.
      assert Project.path_suggestions("Test", [%{path: "Test"}]) == []
    end

    test "absolute recent entries match once, relative entries are filtered" do
      # `/tmp` also triggers filesystem suggestions — assert membership and
      # uniqueness rather than exact equality (recents win on dedup).
      result =
        Project.path_suggestions("/tmp", [
          %{path: "/tmp", name: "tmp"},
          %{path: "Test"}
        ])

      assert "/tmp" in result
      assert Enum.count(result, &(&1 == "/tmp")) == 1
      refute "Test" in result
    end

    @tag :tmp_dir
    test "absolute input yields only absolute suggestions; a trailing slash lists contents",
         %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "alpha")
      File.mkdir_p!(subdir)

      # The tmp dir's own basename appears in its parent listing, so the
      # suggestions are non-empty; every entry must be absolute.
      result = Project.path_suggestions(tmp_dir, [])
      assert result != []
      assert Enum.all?(result, &EvoGit.Platform.absolute_path?/1)

      # A trailing slash lists the directory's OWN contents immediately.
      slash_result = Project.path_suggestions(tmp_dir <> "/", [])
      assert subdir in slash_result
      assert Enum.all?(slash_result, &String.starts_with?(&1, tmp_dir <> "/"))
      refute tmp_dir in slash_result
    end

    test "bare tilde lists the home directory's entries" do
      home = Path.expand("~")

      result = Project.path_suggestions("~", [])

      # Children of home only — home itself must NOT appear (the pre-fix behavior
      # listed the PARENT of home filtered by the home basename). Vacuous-pass on
      # an empty HOME is acceptable: the pin is that home itself never appears.
      assert Enum.all?(result, &String.starts_with?(&1, home <> "/"))
      refute home in result
    end

    test "recent projects match by substring of the full path" do
      result =
        Project.path_suggestions("proj", [%{path: "/home/test/sources/project", name: "project"}])

      assert result == ["/home/test/sources/project"]
    end
  end

  describe "normalize_remote_project_path/2" do
    test "passes POSIX and Windows-absolute paths through verbatim" do
      # `==` equality proves the EXACT input round-tripped: no cwd-join and no
      # drive-letter rewrite by the dashboard's local OS. Shape-only assertions —
      # the function never touches the filesystem.
      for path <- ["/home/user/proj", "C:\\Users\\me\\proj", "D:/stuff", "\\\\server\\share"] do
        assert {:ok, ^path} = ProjectFlow.normalize_remote_project_path(@remote_node, path)
      end
    end

    test "accepts UNC/WSL paths verbatim without corrupting the prefix" do
      for unc_path <- ["//wsl.localhost/Ubuntu-22.04/home/user/proj", "\\\\server\\share\\proj"] do
        assert {:ok, expanded} =
                 ProjectFlow.normalize_remote_project_path(@remote_node, unc_path)

        # `\\` may be normalized to `//`, but never collapsed to one separator.
        assert String.starts_with?(expanded, "//") or String.starts_with?(expanded, "\\\\"),
               "UNC prefix corrupted for #{inspect(unc_path)}: got #{inspect(expanded)}"
      end
    end

    test "rejects blank/relative input and trims surrounding whitespace" do
      for blank <- ["", "   ", "\t\n "] do
        assert {:error, :blank} = ProjectFlow.normalize_remote_project_path(@remote_node, blank)
      end

      # Bare names, relative paths, drive-relative (D:Test), root-relative
      # (\Test) and non-expandable tilde (~foo / off-Windows ~\foo) inputs must
      # never be cwd-joined or locally expanded.
      for relative <- ["foo/bar", "Test", "D:Test", "\\Test", "~foo", "~\\foo", "  foo/bar  "] do
        assert {:error, :relative} =
                 ProjectFlow.normalize_remote_project_path(@remote_node, relative),
               "expected #{inspect(relative)} to be rejected"
      end

      assert {:ok, "/home/user/proj"} =
               ProjectFlow.normalize_remote_project_path(@remote_node, "  /home/user/proj  ")
    end

    test "tilde input is expanded through the injectable remote expand runner" do
      test_pid = self()

      install_expand_runner(fn node, path ->
        send(test_pid, {:expand_called, node, path})
        {:ok, "/remote/home" <> path}
      end)

      assert {:ok, "/remote/home~/proj"} =
               ProjectFlow.normalize_remote_project_path(@remote_node, "  ~/proj  ")

      # The seam receives the node and the TRIMMED input — expansion is fully
      # delegated to the remote runner, never performed against the local home.
      assert_received {:expand_called, @remote_node, "~/proj"}

      # A bare tilde delegates too.
      assert {:ok, "/remote/home~"} =
               ProjectFlow.normalize_remote_project_path(@remote_node, "~")

      assert_received {:expand_called, @remote_node, "~"}
    end

    test "tilde input falls back to the trimmed input when the runner cannot expand" do
      for bad_result <- [{:error, :noconnection}, {:ok, 42}, :ok, {:ok, ["not", "a", "binary"]}] do
        install_expand_runner(fn _node, _path -> bad_result end)

        assert {:ok, "~/proj"} =
                 ProjectFlow.normalize_remote_project_path(@remote_node, "~/proj"),
               "expected the trimmed-input fallback for #{inspect(bad_result)}"
      end
    end

    test "default runner expands tilde via the node-aware RPC chain" do
      # No seam installed → default_remote_path_expand/2 →
      # NodeContext.call_remote(node, Path, :expand, [path]). With the LOCAL node
      # that call executes directly, pinning the end-to-end delegation shape.
      assert {:ok, expanded} = ProjectFlow.normalize_remote_project_path(node(), "~/proj")
      assert expanded == Path.expand("~/proj")
    end
  end

  describe "absolute_path_for_node?/2" do
    test "local node keeps the local Platform.absolute_path?/1 semantics" do
      for path <- ["/home/user/proj", "C:\\work\\repo", "\\\\server\\share"] do
        assert ProjectFlow.absolute_path_for_node?(node(), path)
      end

      for relative <- ["foo/bar", "D:Test", "\\Test", ""] do
        refute ProjectFlow.absolute_path_for_node?(node(), relative)
      end

      for non_binary <- [nil, 42, %{path: "/tmp"}, ["/tmp"]] do
        refute ProjectFlow.absolute_path_for_node?(node(), non_binary)
      end
    end

    test "remote node is host-OS independent and rejects relative/non-binary input" do
      # A Windows dashboard would classify `/home/...` as :volumerelative and a
      # POSIX dashboard would reject `C:\...`.
      for path <- ["/home/user/proj", "/", "C:\\Users\\me\\proj", "D:/stuff", "\\\\server\\share"] do
        assert ProjectFlow.absolute_path_for_node?(@remote_node, path),
               "expected #{inspect(path)} to be absolute for a remote node"
      end

      for relative <- ["foo/bar", "Test", "D:Test", "\\Test", "~foo", ""] do
        refute ProjectFlow.absolute_path_for_node?(@remote_node, relative),
               "expected #{inspect(relative)} to be rejected for a remote node"
      end

      for non_binary <- [nil, 42, %{path: "/tmp"}, ["/tmp"]] do
        refute ProjectFlow.absolute_path_for_node?(@remote_node, non_binary)
      end
    end
  end

  describe "build_foreign_repo/4 — node-aware foreign-repo construction" do
    test "local (and nil) node delegates to ForeignRepo.new/3, inheriting its coercion" do
      assert ProjectFlow.build_foreign_repo(node(), "original", "~/work/repo",
               description: "original"
             ) ==
               ForeignRepo.new("original", "~/work/repo", description: "original")

      assert ProjectFlow.build_foreign_repo(nil, "x", "/tmp/foo", description: "d") ==
               ForeignRepo.new("x", "/tmp/foo", description: "d")

      # Literal `true` / non-blank sha survive untouched.
      opts = [writable: true, base_sha: "abc123"]

      assert ProjectFlow.build_foreign_repo(node(), "x", "/abs/repo", opts) ==
               ForeignRepo.new("x", "/abs/repo", opts)

      assert %ForeignRepo{writable: true, base_sha: "abc123"} =
               ProjectFlow.build_foreign_repo(node(), "x", "/abs/repo", opts)

      # ForeignRepo.new/3 coercion rules: only the literal `true` is writable,
      # blank shas become nil — the local branch must inherit exactly that.
      assert %ForeignRepo{writable: false} =
               ProjectFlow.build_foreign_repo(node(), "x", "/abs/repo", writable: "true")

      assert %ForeignRepo{base_sha: nil} =
               ProjectFlow.build_foreign_repo(node(), "x", "/abs/repo", base_sha: "")

      assert %ForeignRepo{writable: false, base_sha: nil} =
               ProjectFlow.build_foreign_repo(node(), "x", "/abs/repo")
    end

    test "remote node stores POSIX, Windows and UNC roots verbatim (never cwd-joined)" do
      for {id, root} <- [
            {"posix", "/home/user/repo"},
            {"win", "D:\\stuff\\repo"},
            {"unc", "\\\\server\\share"}
          ] do
        repo = ProjectFlow.build_foreign_repo(@remote_node, id, root, description: "d")

        # `==` proves the EXACT input round-tripped: no cwd-join and no
        # drive-letter rewrite by the dashboard's local OS.
        assert {repo.id, repo.root, repo.description} == {id, root, "d"},
               "root rewritten for #{inspect(root)}"
      end
    end

    test "remote node carries writable/base_sha raw (no coercion), defaulting false/nil" do
      repo =
        ProjectFlow.build_foreign_repo(@remote_node, "r", "D:\\stuff\\repo",
          writable: true,
          base_sha: "abc123"
        )

      assert {repo.writable, repo.base_sha} == {true, "abc123"}
      assert repo.root == "D:\\stuff\\repo"

      # Keyword.get/3 directly — a string `"true"` is kept verbatim, never run
      # through ForeignRepo.new/3's writable?/1.
      uncoerced =
        ProjectFlow.build_foreign_repo(@remote_node, "r", "/home/user/repo",
          writable: "true",
          base_sha: "abc123"
        )

      assert {uncoerced.writable, uncoerced.base_sha} == {"true", "abc123"}

      defaults = ProjectFlow.build_foreign_repo(@remote_node, "r", "/home/user/repo", [])

      assert {defaults.writable, defaults.base_sha, defaults.root} ==
               {false, nil, "/home/user/repo"}
    end
  end

  describe "repos_from_task_data/2 — node-aware conversion of persisted task repos" do
    # Converts `task.opts[:foreign_repos]` (post-Codec round trip or a remote task
    # read: %ForeignRepo{} structs and/or string-/atom-keyed maps) into structs
    # via build_foreign_repo/4. Unlike a RAW remote build call (which keeps a
    # string "true" verbatim), repos_from_task_data normalizes "true" → true
    # BEFORE delegating, so both tolerant inputs land as boolean writable.
    test "keeps roots verbatim, threads writable/base_sha, sorts primary-first, drops junk" do
      repos =
        ProjectFlow.repos_from_task_data(@remote_node, [
          %{
            "id" => "win",
            "root" => "D:\\stuff\\repo",
            "description" => "w",
            "writable" => "true",
            "base_sha" => "abc123"
          },
          %{"id" => "posix", "path" => "/srv/repo2", "writable" => true}
        ])

      # Sorted primary-first-then-id: posix < win.
      assert [
               %ForeignRepo{
                 id: "posix",
                 root: "/srv/repo2",
                 writable: true,
                 base_sha: nil,
                 description: nil
               },
               %ForeignRepo{
                 id: "win",
                 root: "D:\\stuff\\repo",
                 writable: true,
                 base_sha: "abc123",
                 description: "w"
               }
             ] = repos

      struct_repo = %ForeignRepo{id: "primary", root: "/a/b", description: "p"}
      assert ProjectFlow.repos_from_task_data(@remote_node, [struct_repo]) == [struct_repo]

      assert ProjectFlow.repos_from_task_data(@remote_node, [
               %{"id" => "b", "root" => "/b"},
               %{"id" => "primary", "root" => "/p"}
             ])
             |> Enum.map(& &1.id) == ["primary", "b"]

      # Unparseable entries are dropped.
      assert ProjectFlow.repos_from_task_data(@remote_node, [
               %{"id" => "x", "root" => 42},
               "junk",
               %{}
             ]) == []

      assert ProjectFlow.repos_from_task_data(@remote_node, []) == []
    end
  end

  describe "Project.load_foreign_repos/3 — node-aware genesis.toml loading" do
    test "remote node keeps POSIX and Windows roots verbatim; nil config yields []" do
      config = %{
        "foreign_repos" => %{
          "original" => %{"path" => "/Source/original-proj", "description" => "legacy"},
          "win" => %{"path" => "D:\\stuff\\repo"}
        }
      }

      assert [
               %{id: "original", root: "/Source/original-proj", description: "legacy"},
               %{id: "win", root: "D:\\stuff\\repo", description: nil}
             ] = Project.load_foreign_repos(@remote_node, "/ignored/repo_path", config)

      assert Project.load_foreign_repos(@remote_node, "/ignored/repo_path", nil) == []
    end

    test "local node keeps the existing behavior (delegates to load_foreign_repos/2)" do
      config = %{
        "foreign_repos" => %{
          "original" => %{"path" => "/Source/original-proj", "description" => "legacy"}
        }
      }

      assert Project.load_foreign_repos(node(), "/ignored/repo_path", config) ==
               Project.load_foreign_repos("/ignored/repo_path", config)
    end
  end

  describe "path_suggestions/3 — node-aware recents filter" do
    test "remote node keeps absolute recents, drops relative ones, matches by substring" do
      recents = [
        %{path: "/home/user/proj", name: "proj"},
        %{path: "C:\\work\\repo", name: "repo"},
        %{path: "relative/repo", name: "rel"},
        %{path: "D:Test", name: "vol"}
      ]

      # Remote filesystem suggestions degrade to [] (no real daemon answers the
      # RPC against the fake node), so the result IS the filtered recents.
      result = Project.path_suggestions(@remote_node, "", recents)

      assert "/home/user/proj" in result
      assert "C:\\work\\repo" in result
      refute "relative/repo" in result
      refute "D:Test" in result

      # Empty query matches ALL recents.
      assert Project.path_suggestions(@remote_node, "", [
               %{path: "/home/a", name: "a"},
               %{path: "/home/b", name: "b"}
             ]) == ["/home/a", "/home/b"]

      # Case-insensitive infix match on the full path.
      for query <- ["proj", "Proj", "test/sources"] do
        assert Project.path_suggestions(@remote_node, query, [
                 %{path: "/home/test/sources/project", name: "project"}
               ]) == ["/home/test/sources/project"]
      end
    end

    test "local node recents filtering is unchanged" do
      # Empty input produces no filesystem suggestions on either branch, so the
      # result is exactly the locally-filtered recents.
      result =
        Project.path_suggestions(node(), "", [
          %{path: "/tmp", name: "tmp"},
          %{path: "relative/repo", name: "rel"}
        ])

      assert "/tmp" in result
      refute "relative/repo" in result
    end
  end

  # Installs a fake for the `:evo_dash, :remote_path_expand_runner` app-env seam
  # (read at CALL time by `normalize_remote_project_path/2`) and restores the
  # previous value in on_exit. The seam receives `(node, path)` and must return
  # `{:ok, binary}` for its result to be used.
  defp install_expand_runner(fun) do
    original = Application.get_env(:evo_dash, :remote_path_expand_runner)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:evo_dash, :remote_path_expand_runner)
      else
        Application.put_env(:evo_dash, :remote_path_expand_runner, original)
      end
    end)

    Application.put_env(:evo_dash, :remote_path_expand_runner, fun)
  end
end
