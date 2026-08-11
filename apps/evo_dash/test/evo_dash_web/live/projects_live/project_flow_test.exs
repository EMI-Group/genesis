defmodule EvoDashWeb.ProjectsLive.ProjectFlowTest do
  @moduledoc """
  Pure unit tests for the Windows project-open path fix.

  Covers `EvoDashWeb.ProjectsLive.ProjectFlow.normalize_project_path/1` (the
  guard that stops relative input from being `Path.expand`-joined against the
  BEAM cwd — on the Windows desktop app that cwd is the Tauri install dir) and
  the public `EvoDashWeb.ProjectsLive.Project.path_suggestions/2,3` (which
  delegates to the private `filesystem_suggestions/1` on the local node).

  No LiveView harness or DB setup is required — these are pure functions.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.ProjectsLive.Project
  alias EvoDashWeb.ProjectsLive.ProjectFlow

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
  end
end
