defmodule EvoDashWeb.ProjectsLive.ProjectFlowTest do
  @moduledoc """
  Pure unit tests for the Windows project-open path fix and the cross-OS
  remote-project-path fix.

  Covers `EvoDashWeb.ProjectsLive.ProjectFlow.normalize_project_path/1` (the
  guard that stops relative input from being `Path.expand`-joined against the
  BEAM cwd — on the Windows desktop app that cwd is the Tauri install dir),
  `normalize_remote_project_path/2` (remote-aware normalization: absolute
  remote paths pass through verbatim, tilde input expands via the injectable
  `:remote_path_expand_runner` seam), `absolute_path_for_node?/2` (the shared
  node-aware path predicate), the node-aware foreign-repo construction seam
  `ProjectFlow.build_foreign_repo/4` (local node → `ForeignRepo.new/3`;
  remote node → RAW root, no local `Path.expand`),
  `Project.load_foreign_repos/3` (node-aware genesis.toml foreign-repo
  loading), and the public
  `EvoDashWeb.ProjectsLive.Project.path_suggestions/2,3` (which delegates to
  the private `filesystem_suggestions/1` on the local node and applies the
  node-aware recents filter).

  No LiveView harness or DB setup is required — these are pure functions.

  NOTE: the tests run on Linux CI but must pin the NEW remote behavior
  regardless of host OS. The remote branches are therefore exercised with a
  fake non-local node atom so the dashboard's host-OS semantics never leak in.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.ProjectsLive.Project
  alias EvoDashWeb.ProjectsLive.ProjectFlow
  alias EvoGit.Core.ForeignRepo

  # A fake remote BEAM node name. The tests never connect to it — it only has
  # to differ from `node()` so the remote branches of the node-aware
  # functions run (the test VM node is `:nonode@nohost`).
  @remote_node :"genesis_remote@127.0.0.1"

  describe "normalize_project_path/1" do
    test "rejects blank and whitespace-only input" do
      assert {:error, :blank} = ProjectFlow.normalize_project_path("")
      assert {:error, :blank} = ProjectFlow.normalize_project_path("   ")
      assert {:error, :blank} = ProjectFlow.normalize_project_path("\t\n ")
    end

    test "rejects a bare project name (the core bug vector)" do
      # "Test" must never be cwd-joined into the Tauri install dir.
      assert {:error, :relative} = ProjectFlow.normalize_project_path("Test")
    end

    test "rejects volume-relative paths" do
      assert {:error, :relative} = ProjectFlow.normalize_project_path("D:Test")
    end

    test "rejects root-relative paths" do
      assert {:error, :relative} = ProjectFlow.normalize_project_path("\\Test")
    end

    test "rejects ~foo (not a genuine tilde expansion)" do
      # "~foo" NEVER expands on any platform — it must fall through to the
      # relative branch instead of being cwd-joined.
      assert {:error, :relative} = ProjectFlow.normalize_project_path("~foo")
    end

    test "accepts Windows drive-letter absolute paths (shape only, no filesystem access)" do
      # On Linux CI `Path.expand("D:\\Test")` cwd-joins/mangles — which is
      # fine: the guard is platform-independent, the filesystem isn't. Assert
      # the SHAPE ONLY and never touch the filesystem with Windows paths.
      for windows_path <- ["D:\\Test", "D:/Test", "C:\\foo"] do
        assert {:ok, _expanded} = ProjectFlow.normalize_project_path(windows_path)
      end
    end

    test "accepts an absolute Unix path idempotently" do
      assert {:ok, expanded} = ProjectFlow.normalize_project_path("/tmp/foo")
      assert expanded == "/tmp/foo"
    end

    test "expands a genuine tilde path against the home dir, never the BEAM cwd" do
      assert {:ok, expanded} = ProjectFlow.normalize_project_path("~/foo")
      assert String.starts_with?(expanded, Path.expand("~"))
      assert String.starts_with?(expanded, System.user_home!())

      refute String.contains?(expanded, File.cwd!()),
             "tilde expansion must not be cwd-joined"
    end

    test "trims surrounding whitespace before evaluating" do
      assert {:error, :relative} = ProjectFlow.normalize_project_path("  Test  ")
      assert {:ok, expanded} = ProjectFlow.normalize_project_path("  /tmp/foo  ")
      assert expanded == "/tmp/foo"
    end
  end

  describe "path_suggestions/2,3" do
    test "relative input yields no filesystem suggestions" do
      assert Project.path_suggestions("Test", []) == []
    end

    test "relative recent-project entries are filtered out and never surface" do
      # A stale cwd-joined recents entry (from the pre-fix behavior) must not
      # render in the palette.
      assert Project.path_suggestions("Test", [%{path: "Test"}]) == []
    end

    test "absolute recent entries match, with no duplicate from the filesystem" do
      # `/tmp` also triggers filesystem suggestions — assert membership and
      # uniqueness rather than exact equality (recents win on dedup).
      result = Project.path_suggestions("/tmp", [%{path: "/tmp", name: "tmp"}])
      assert "/tmp" in result
      assert Enum.count(result, &(&1 == "/tmp")) == 1
    end

    @tag :tmp_dir
    test "absolute input with no recents produces only absolute filesystem suggestions",
         %{tmp_dir: tmp_dir} do
      # The tmp dir's own basename appears in its parent listing, so the
      # suggestions are non-empty; every entry must be absolute — no
      # cwd-anchored entries allowed.
      result = Project.path_suggestions(tmp_dir, [])
      assert result != []
      assert Enum.all?(result, &EvoGit.Platform.absolute_path?/1)
    end

    test "mixed recents: duplicate absolute entry appears once, relative entry filtered" do
      result =
        Project.path_suggestions("/tmp", [
          %{path: "/tmp", name: "tmp"},
          %{path: "Test"}
        ])

      assert Enum.count(result, &(&1 == "/tmp")) == 1
      refute "Test" in result
    end

    @tag :tmp_dir
    test "trailing slash lists the directory's own contents immediately", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "alpha")
      File.mkdir_p!(subdir)

      result = Project.path_suggestions(tmp_dir <> "/", [])

      assert subdir in result
      assert Enum.all?(result, &String.starts_with?(&1, tmp_dir <> "/"))
      refute tmp_dir in result
    end

    test "bare tilde lists the home directory's entries" do
      home = Path.expand("~")

      result = Project.path_suggestions("~", [])

      # Children of home only — home itself must NOT appear (the pre-fix behavior
      # listed the PARENT of home filtered by the home basename). Vacuous-pass on an
      # empty HOME is acceptable: the regression pin is that home itself never
      # appears.
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
    test "passes a POSIX absolute path through verbatim (no local Path.expand)" do
      path = "/home/user/proj"

      assert {:ok, expanded} = ProjectFlow.normalize_remote_project_path(@remote_node, path)

      # `==` equality proves the EXACT input round-tripped: no cwd-join and no
      # drive-letter rewrite by the dashboard's local OS. (Pre-fix, a Windows
      # dashboard classified this as relative and `Path.expand`ed it.)
      assert expanded == path
    end

    test "passes Windows-style absolute paths through verbatim" do
      # Shape-only assertions — the function never touches the filesystem.
      for windows_path <- ["C:\\Users\\me\\proj", "D:/stuff", "\\\\server\\share"] do
        assert {:ok, expanded} =
                 ProjectFlow.normalize_remote_project_path(@remote_node, windows_path)

        assert expanded == windows_path
      end
    end

    test "rejects blank and whitespace-only input" do
      assert {:error, :blank} = ProjectFlow.normalize_remote_project_path(@remote_node, "")
      assert {:error, :blank} = ProjectFlow.normalize_remote_project_path(@remote_node, "   ")
      assert {:error, :blank} = ProjectFlow.normalize_remote_project_path(@remote_node, "\t\n ")
    end

    test "rejects relative input" do
      # Bare names, relative paths, drive-relative (D:Test), root-relative
      # (\Test) and non-expandable tilde (~foo / off-Windows ~\foo) inputs
      # must never be cwd-joined or locally expanded.
      for relative <- ["foo/bar", "Test", "D:Test", "\\Test", "~foo", "~\\foo"] do
        assert {:error, :relative} =
                 ProjectFlow.normalize_remote_project_path(@remote_node, relative)
      end
    end

    test "trims surrounding whitespace before evaluating" do
      assert {:error, :relative} =
               ProjectFlow.normalize_remote_project_path(@remote_node, "  foo/bar  ")

      assert {:ok, expanded} =
               ProjectFlow.normalize_remote_project_path(@remote_node, "  /home/user/proj  ")

      assert expanded == "/home/user/proj"
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
      # delegated to the remote runner, never performed against the local
      # dashboard's home dir.
      assert_received {:expand_called, @remote_node, "~/proj"}
    end

    test "bare tilde input is delegated to the runner" do
      install_expand_runner(fn node, path ->
        assert node == @remote_node
        assert path == "~"
        {:ok, "/remote/home"}
      end)

      assert {:ok, "/remote/home"} =
               ProjectFlow.normalize_remote_project_path(@remote_node, "~")
    end

    test "tilde input falls back to the trimmed input when the runner fails" do
      install_expand_runner(fn _node, _path -> {:error, :noconnection} end)

      assert {:ok, "~/proj"} =
               ProjectFlow.normalize_remote_project_path(@remote_node, "~/proj")
    end

    test "tilde input falls back to the trimmed input on a non-binary runner result" do
      for bad_result <- [{:ok, 42}, :ok, {:ok, ["not", "a", "binary"]}] do
        install_expand_runner(fn _node, _path -> bad_result end)

        assert {:ok, "~/proj"} =
                 ProjectFlow.normalize_remote_project_path(@remote_node, "~/proj")
      end
    end

    test "default runner expands tilde via the node-aware RPC chain" do
      # No seam installed → default_remote_path_expand/2 →
      # NodeContext.call_remote(node, Path, :expand, [path]). With the LOCAL
      # node that call executes directly, pinning the end-to-end delegation
      # shape (local home expansion, not a hardcoded path).
      assert {:ok, expanded} = ProjectFlow.normalize_remote_project_path(node(), "~/proj")
      assert expanded == Path.expand("~/proj")
    end
  end

  describe "absolute_path_for_node?/2" do
    test "local node keeps the local Platform.absolute_path?/1 semantics" do
      # Linux CI: POSIX absolute accepted via Path.type/1.
      assert ProjectFlow.absolute_path_for_node?(node(), "/home/user/proj")
      # Windows-style absolutes are platform-independent (regex-based).
      assert ProjectFlow.absolute_path_for_node?(node(), "C:\\work\\repo")
      assert ProjectFlow.absolute_path_for_node?(node(), "\\\\server\\share")

      refute ProjectFlow.absolute_path_for_node?(node(), "foo/bar")
      refute ProjectFlow.absolute_path_for_node?(node(), "D:Test")
      refute ProjectFlow.absolute_path_for_node?(node(), "\\Test")
      refute ProjectFlow.absolute_path_for_node?(node(), "")
    end

    test "local node rejects non-binary input" do
      refute ProjectFlow.absolute_path_for_node?(node(), nil)
      refute ProjectFlow.absolute_path_for_node?(node(), 42)
      refute ProjectFlow.absolute_path_for_node?(node(), %{path: "/tmp"})
      refute ProjectFlow.absolute_path_for_node?(node(), ["/tmp"])
    end

    test "remote node accepts POSIX and Windows-style absolute paths" do
      # The remote node's paths must NOT be judged by the dashboard's host OS:
      # a Windows dashboard would classify `/home/...` as :volumerelative and
      # a POSIX dashboard would reject `C:\...`.
      for path <- ["/home/user/proj", "/", "C:\\Users\\me\\proj", "D:/stuff", "\\\\server\\share"] do
        assert ProjectFlow.absolute_path_for_node?(@remote_node, path),
               "expected #{inspect(path)} to be absolute for a remote node"
      end
    end

    test "remote node rejects relative paths" do
      for relative <- ["foo/bar", "Test", "D:Test", "\\Test", "~foo", ""] do
        refute ProjectFlow.absolute_path_for_node?(@remote_node, relative),
               "expected #{inspect(relative)} to be rejected for a remote node"
      end
    end

    test "remote node rejects non-binary input" do
      refute ProjectFlow.absolute_path_for_node?(@remote_node, nil)
      refute ProjectFlow.absolute_path_for_node?(@remote_node, 42)
      refute ProjectFlow.absolute_path_for_node?(@remote_node, %{path: "/tmp"})
      refute ProjectFlow.absolute_path_for_node?(@remote_node, ["/tmp"])
    end
  end

  describe "build_foreign_repo/4 — node-aware foreign-repo construction" do
    test "local node (node()) delegates to ForeignRepo.new/3 (exact local semantics)" do
      opts = [description: "original"]

      assert ProjectFlow.build_foreign_repo(node(), "original", "~/work/repo", opts) ==
               ForeignRepo.new("original", "~/work/repo", opts)

      assert ProjectFlow.build_foreign_repo(node(), "x", "/tmp/foo", []) ==
               ForeignRepo.new("x", "/tmp/foo", [])
    end

    test "nil node is treated as local and delegates to ForeignRepo.new/3" do
      assert ProjectFlow.build_foreign_repo(nil, "x", "/tmp/foo", description: "d") ==
               ForeignRepo.new("x", "/tmp/foo", description: "d")
    end

    test "remote node stores the POSIX root verbatim (no local Path.expand)" do
      repo =
        ProjectFlow.build_foreign_repo(@remote_node, "posix", "/home/user/repo",
          description: "posix repo"
        )

      assert repo.id == "posix"
      # `==` equality proves the EXACT input round-tripped: no cwd-join and no
      # drive-letter rewrite by the dashboard's local OS.
      assert repo.root == "/home/user/repo"
      assert repo.description == "posix repo"
    end

    test "remote node stores the Windows root verbatim (never cwd-joined)" do
      repo = ProjectFlow.build_foreign_repo(@remote_node, "win", "D:\\stuff\\repo", [])

      assert repo.id == "win"
      # Pre-fix, a POSIX dashboard's ForeignRepo.new/3 cwd-joined this path.
      assert repo.root == "D:\\stuff\\repo"
      assert repo.description == nil
    end

    test "remote node stores a UNC root verbatim" do
      repo = ProjectFlow.build_foreign_repo(@remote_node, "unc", "\\\\server\\share", [])

      assert repo.root == "\\\\server\\share"
    end

    test "local node threads writable/base_sha through ForeignRepo.new/3 coercion" do
      # Literal `true` / non-blank sha survive the coercion untouched — the
      # local branch must remain byte-for-byte identical to ForeignRepo.new/3.
      opts = [writable: true, base_sha: "abc123"]

      assert ProjectFlow.build_foreign_repo(node(), "x", "/abs/repo", opts) ==
               ForeignRepo.new("x", "/abs/repo", opts)

      assert %ForeignRepo{writable: true, base_sha: "abc123"} =
               ProjectFlow.build_foreign_repo(node(), "x", "/abs/repo", opts)
    end

    test "local node coerces non-boolean writable and blank base_sha" do
      # ForeignRepo.new/3 coercion rules: only the literal `true` is writable,
      # blank shas become nil — the local branch must inherit exactly that.
      assert %ForeignRepo{writable: false} =
               ProjectFlow.build_foreign_repo(node(), "x", "/abs/repo", writable: "true")

      assert %ForeignRepo{base_sha: nil} =
               ProjectFlow.build_foreign_repo(node(), "x", "/abs/repo", base_sha: "")

      assert %ForeignRepo{writable: false, base_sha: nil} =
               ProjectFlow.build_foreign_repo(node(), "x", "/abs/repo")
    end

    test "remote node carries writable/base_sha raw in the struct" do
      repo =
        ProjectFlow.build_foreign_repo(@remote_node, "r", "/home/user/repo",
          writable: true,
          base_sha: "abc123"
        )

      assert repo.writable == true
      assert repo.base_sha == "abc123"
      # Verbatim — no local Path.expand/rewrite of the root either.
      assert repo.root == "/home/user/repo"
    end

    test "remote node does not coerce writable/base_sha (no-coercion contract)" do
      # The remote branch uses Keyword.get/3 directly — a string `"true"` is
      # kept verbatim, never run through ForeignRepo.new/3's writable?/1.
      repo =
        ProjectFlow.build_foreign_repo(@remote_node, "r", "/home/user/repo",
          writable: "true",
          base_sha: "abc123"
        )

      assert repo.writable == "true"
      assert repo.base_sha == "abc123"
    end

    test "remote node defaults writable to false and base_sha to nil" do
      repo = ProjectFlow.build_foreign_repo(@remote_node, "r", "/home/user/repo", [])

      assert repo.writable == false
      assert repo.base_sha == nil
      assert repo.root == "/home/user/repo"
    end

    test "remote node never locally rewrites base_sha or Windows roots" do
      repo =
        ProjectFlow.build_foreign_repo(@remote_node, "r", "D:\\stuff\\repo",
          writable: true,
          base_sha: "abc123"
        )

      assert repo.writable == true
      assert repo.base_sha == "abc123"
      # The Windows root survives verbatim even with writable/base_sha set —
      # no local Path.expand, no drive-letter rewrite.
      assert repo.root == "D:\\stuff\\repo"
    end
  end

  describe "Project.load_foreign_repos/3 — node-aware genesis.toml loading" do
    test "remote node keeps the POSIX root verbatim (host-OS independent)" do
      config = %{
        "foreign_repos" => %{
          "original" => %{"path" => "/Source/original-proj", "description" => "legacy"}
        }
      }

      assert [%{id: "original", root: "/Source/original-proj", description: "legacy"}] =
               Project.load_foreign_repos(@remote_node, "/ignored/repo_path", config)

      # `==` equality proves the EXACT input round-tripped: no local
      # Path.expand (which would mangle it on a Windows dashboard).
      assert hd(Project.load_foreign_repos(@remote_node, "/ignored/repo_path", config)).root ==
               "/Source/original-proj"
    end

    test "remote node keeps a Windows root verbatim" do
      config = %{"foreign_repos" => %{"win" => %{"path" => "D:\\stuff\\repo"}}}

      assert [%{id: "win", root: "D:\\stuff\\repo", description: nil}] =
               Project.load_foreign_repos(@remote_node, "/ignored/repo_path", config)
    end

    test "remote node returns [] for a nil config" do
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
    test "remote node keeps POSIX/Windows-absolute recents and drops relative ones" do
      recents = [
        %{path: "/home/user/proj", name: "proj"},
        %{path: "C:\\work\\repo", name: "repo"},
        %{path: "relative/repo", name: "rel"},
        %{path: "D:Test", name: "vol"}
      ]

      # Remote filesystem suggestions degrade to [] (no real daemon answers
      # the RPC against the fake node), so the result IS the filtered recents —
      # pinning the shared node-aware predicate the remote palette path uses.
      result = Project.path_suggestions(@remote_node, "", recents)

      assert Enum.any?(result, &(&1 == "/home/user/proj"))
      assert Enum.any?(result, &(&1 == "C:\\work\\repo"))
      refute Enum.any?(result, &(&1 == "relative/repo"))
      refute Enum.any?(result, &(&1 == "D:Test"))
    end

    test "local node recents filtering is unchanged" do
      recents = [
        %{path: "/tmp", name: "tmp"},
        %{path: "relative/repo", name: "rel"}
      ]

      # Empty input produces no filesystem suggestions on either branch, so
      # the result is exactly the locally-filtered recents.
      result = Project.path_suggestions(node(), "", recents)

      assert Enum.any?(result, &(&1 == "/tmp"))
      refute Enum.any?(result, &(&1 == "relative/repo"))
    end

    test "recent projects match by case-insensitive substring (infix)" do
      recents = [%{path: "/home/test/sources/project", name: "project"}]

      # Remote filesystem suggestions degrade to [] (no real daemon answers the
      # RPC against the fake node), so the result IS the filtered recents.
      for query <- ["proj", "Proj", "test/sources"] do
        assert Project.path_suggestions(@remote_node, query, recents) ==
                 ["/home/test/sources/project"]
      end
    end

    test "empty query matches all recents" do
      recents = [
        %{path: "/home/a", name: "a"},
        %{path: "/home/b", name: "b"}
      ]

      result = Project.path_suggestions(@remote_node, "", recents)
      assert "/home/a" in result
      assert "/home/b" in result
    end
  end

  # Installs a fake for the `:evo_dash, :remote_path_expand_runner` app-env
  # seam (read at CALL time by `normalize_remote_project_path/2`) and restores
  # the previous value in on_exit. The seam function receives `(node, path)`
  # and must return `{:ok, binary}` for its result to be used.
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
