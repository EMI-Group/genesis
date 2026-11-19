defmodule EvoGit.VCT.TableWorkspaceTest do
  @moduledoc """
  Pure, BEAM-global-free: exercises the mount-LIST rules for WORKSPACE mounts
  (predicates, cap, upsert, membership resolution) without a process, a data
  directory or a store, so `async: true`.
  """
  use ExUnit.Case, async: true

  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Path
  alias EvoGit.VCT.Table

  @ws_point "vct:///workspaces/frontend"
  @now ~U[2026-05-01 00:00:00Z]

  defp git_mount(point, path, opened \\ nil), do: Mount.new(point, path, last_opened_at: opened)

  defp workspace(point \\ @ws_point, members \\ [], description \\ nil) do
    Mount.new(point, nil,
      kind: "workspace",
      members: members,
      description: description,
      last_opened_at: @now
    )
  end

  describe "workspace_point?/1" do
    test "is true for a workspace point as a string or a %Path{}" do
      assert Table.workspace_point?(@ws_point)
      assert Table.workspace_point?("vct:///workspaces/frontend/")
      assert Table.workspace_point?("vct:///workspaces/deep/nested")
      assert Table.workspace_point?(%Path{segments: ["workspaces", "frontend"]})
      assert Table.workspace_point?(Path.parse!(@ws_point))
    end

    test "is false for everything else — never raising" do
      for other <- [
            nil,
            :nope,
            123,
            %{},
            "",
            "garbage",
            "vct://host/workspaces/frontend",
            "vct:///workspaces",
            "vct:///",
            "vct:///projects/foo",
            "vct:///projects",
            "vct:///genesis-source",
            %Path{segments: []},
            %Path{segments: ["projects", "foo"]},
            %Path{segments: ["workspaces"]}
          ] do
        refute Table.workspace_point?(other), "expected false for #{inspect(other)}"
      end
    end
  end

  describe "workspace_mount?/1 and workspace_mounts/1" do
    test "workspace_mount?/1 is the point-based spelling of workspace_point?/1" do
      assert Table.workspace_mount?(@ws_point)
      refute Table.workspace_mount?("vct:///projects/foo")
      refute Table.workspace_mount?(nil)
    end

    test "workspace_mounts/1 keeps workspace mounts only, preserving order" do
      first = workspace("vct:///workspaces/a")
      project = git_mount("vct:///projects/p", "/p")
      second = workspace("vct:///workspaces/b")

      assert Table.workspace_mounts([first, project, second]) == [first, second]
      assert Table.workspace_mounts([project]) == []
      assert Table.workspace_mounts([]) == []
      assert Table.workspace_mounts(:nope) == []
    end
  end

  describe "reserved?/1 and project_mount?/1" do
    test "a workspace point is neither a project mount nor reserved" do
      refute Table.project_mount?(@ws_point)
      refute Table.reserved?(@ws_point)
      refute Table.reserved?(%Path{segments: ["workspaces", "frontend"]})
    end

    test "project and reserved points keep their old classification" do
      assert Table.project_mount?("vct:///projects/foo")
      refute Table.reserved?("vct:///projects/foo")

      assert Table.reserved?("vct:///genesis-source")
      assert Table.reserved?("vct:///")
      assert Table.reserved?("vct:///projects")
      refute Table.project_mount?("vct:///genesis-source")
    end

    test "garbage is neither reserved nor a project mount" do
      for other <- [nil, "garbage", 42, %{}] do
        refute Table.reserved?(other)
        refute Table.project_mount?(other)
      end
    end
  end

  describe "enforce_cap/2 — workspaces are spared" do
    test "the cap counts projects only, so a workspace survives and keeps its position" do
      oldest = git_mount("vct:///projects/oldest", "/p/oldest", ~U[2020-01-01 00:00:00Z])
      ws = workspace()
      middle = git_mount("vct:///projects/middle", "/p/middle", ~U[2022-01-01 00:00:00Z])
      newest = git_mount("vct:///projects/newest", "/p/newest", ~U[2024-01-01 00:00:00Z])

      mounts = [oldest, ws, middle, newest]

      assert Table.enforce_cap(mounts, 1) == [ws, newest]
      assert Table.enforce_cap(mounts, 2) == [ws, middle, newest]
      assert Table.enforce_cap(mounts, 10) == mounts
    end

    test "workspaces alone are never evicted" do
      one = workspace("vct:///workspaces/one")
      two = workspace("vct:///workspaces/two")

      assert Table.enforce_cap([one, two], 1) == [one, two]
      assert Table.enforce_cap([one, two], 0) == [one, two]
    end
  end

  describe "upsert_workspace/6" do
    test "appends a new workspace and never applies the cap" do
      a = git_mount("vct:///projects/a", "/p/a", ~U[2024-01-01 00:00:00Z])
      b = git_mount("vct:///projects/b", "/p/b", ~U[2024-02-01 00:00:00Z])

      assert {:ok, mounts, mount} =
               Table.upsert_workspace(
                 [a, b],
                 @ws_point,
                 "Frontend",
                 [%{path: "/p/a"}],
                 "desc",
                 @now
               )

      assert Enum.map(mounts, & &1.point) == ["vct:///projects/a", "vct:///projects/b", @ws_point]
      assert mount.point == @ws_point
      assert mount.kind == "workspace"
      assert mount.path == nil
      assert mount.name == "Frontend"
      assert mount.description == "desc"
      assert mount.last_opened_at == @now
      assert mount.members == [%{"point" => nil, "path" => "/p/a"}]
      assert Mount.workspace?(mount)
    end

    test "replaces the row at the point IN PLACE, keeping its list position" do
      first = git_mount("vct:///projects/first", "/p/first")
      old_ws = workspace(@ws_point, [%{path: "/p/first"}], "Old")
      last = git_mount("vct:///projects/last", "/p/last")

      later = ~U[2026-06-01 00:00:00Z]

      assert {:ok, mounts, mount} =
               Table.upsert_workspace(
                 [first, old_ws, last],
                 @ws_point,
                 "New name",
                 [%{point: "vct:///projects/last"}, %{path: "/p/first/"}],
                 "New description",
                 later
               )

      assert Enum.map(mounts, & &1.point) ==
               ["vct:///projects/first", @ws_point, "vct:///projects/last"]

      assert Enum.at(mounts, 1) == mount
      assert mount.name == "New name"
      assert mount.description == "New description"
      assert mount.last_opened_at == later

      assert mount.members == [
               %{"point" => "vct:///projects/last", "path" => nil},
               %{"point" => nil, "path" => "/p/first"}
             ]
    end

    test "defaults the timestamp to now and drops a blank name/description" do
      assert {:ok, _mounts, mount} = Table.upsert_workspace([], @ws_point, "  ", [], "   ")
      assert %DateTime{} = mount.last_opened_at
      assert mount.name == nil
      assert mount.description == nil
      assert mount.members == []
    end

    test "refuses a non-workspace or invalid point" do
      for point <- ["vct:///projects/foo", "vct:///workspaces", "nope", nil] do
        assert Table.upsert_workspace([], point, "X", [], nil, @now) == {:error, :invalid_point}
      end
    end

    test "refuses invalid members and a non-list mount list" do
      assert Table.upsert_workspace([], @ws_point, "X", [%{path: "relative"}], nil, @now) ==
               {:error, {:invalid_member, %{path: "relative"}}}

      assert Table.upsert_workspace([], @ws_point, "X", [%{point: "vct:///workspaces/o"}], nil) ==
               {:error, {:member_is_workspace, "vct:///workspaces/o"}}

      assert Table.upsert_workspace([], @ws_point, "X", :nope, nil) ==
               {:error, :invalid_members}

      assert Table.upsert_workspace(:nope, @ws_point, "X", [], nil) == {:error, :invalid_mounts}
    end

    test "does not affect git mounts and leaves the input list untouched" do
      a = git_mount("vct:///projects/a", "/p/a")
      mounts = [a]

      assert {:ok, updated, _ws} = Table.upsert_workspace(mounts, @ws_point, "WS", [], nil, @now)
      assert mounts == [a]
      assert Enum.at(updated, 0) == a
    end
  end

  describe "member_mount/2" do
    test "resolves point-first, so a stale path never wins" do
      stale = git_mount("vct:///projects/stale", "/old/path")
      fresh = git_mount("vct:///projects/fresh", "/new/path")

      assert Table.member_mount([stale, fresh], %{
               point: "vct:///projects/fresh",
               path: "/old/path"
             }) == {:ok, fresh}
    end

    test "falls back to the exact normalized OS path when the point does not resolve" do
      offline = git_mount("vct:///projects/offline", "/src/offline")

      assert Table.member_mount([offline], %{point: "vct:///projects/gone", path: "/src/offline/"}) ==
               {:ok, offline}

      assert Table.member_mount([offline], %{path: "/src/offline"}) == {:ok, offline}
    end

    test "is :missing when nothing resolves (existence is never required)" do
      mounts = [git_mount("vct:///projects/a", "/p/a")]

      assert Table.member_mount(mounts, %{path: "/does/not/exist"}) == :missing
      assert Table.member_mount(mounts, %{point: "vct:///projects/nope"}) == :missing
      assert Table.member_mount([], %{path: "/p/a"}) == :missing
    end

    test "is :nested when the member resolves to a workspace" do
      mounts = [workspace("vct:///workspaces/other", [%{path: "/p/a"}])]

      assert Table.member_mount(mounts, %{point: "vct:///workspaces/other"}) == :nested
    end

    test "is :missing for an invalid member ref and for a non-list" do
      assert Table.member_mount([], %{}) == :missing
      assert Table.member_mount([], "nope") == :missing
      assert Table.member_mount(:nope, %{path: "/p/a"}) == :missing
    end
  end

  describe "workspaces_containing/3" do
    setup do
      project = git_mount("vct:///projects/foo", "/p/foo")
      offline = git_mount("vct:///projects/offline", "/p/offline")

      by_point = workspace("vct:///workspaces/by-point", [%{point: "vct:///projects/foo"}])
      by_path = workspace("vct:///workspaces/by-path", [%{path: "/p/foo/"}])
      by_resolution = workspace("vct:///workspaces/by-resolution", [%{path: "/p/offline"}])
      unrelated = workspace("vct:///workspaces/unrelated", [%{point: "vct:///projects/other"}])

      %{
        mounts: [by_point, project, by_path, offline, by_resolution, unrelated],
        by_point: by_point,
        by_path: by_path,
        by_resolution: by_resolution
      }
    end

    test "matches a member point and a member path", %{mounts: mounts} = ctx do
      assert Table.workspaces_containing(mounts, "vct:///projects/foo", nil) ==
               [ctx.by_point, ctx.by_path]

      assert Table.workspaces_containing(mounts, "vct:///projects/foo", "/p/foo") ==
               [ctx.by_point, ctx.by_path]
    end

    test "matches a path-only member whose mount resolves to the point",
         %{mounts: mounts} = ctx do
      assert Table.workspaces_containing(mounts, "vct:///projects/offline", nil) ==
               [ctx.by_resolution]
    end

    test "preserves input order and ignores nil inputs", %{mounts: mounts} = ctx do
      assert Table.workspaces_containing(mounts, nil, nil) == []

      forward = Table.workspaces_containing(mounts, "vct:///projects/foo", nil)
      reversed = Table.workspaces_containing(Enum.reverse(mounts), "vct:///projects/foo", nil)

      assert forward == [ctx.by_point, ctx.by_path]
      assert reversed == Enum.reverse(forward)
    end

    test "is [] when nothing matches or the list is not a list", %{mounts: mounts} do
      assert Table.workspaces_containing(mounts, "vct:///projects/nowhere", "/nowhere") == []
      assert Table.workspaces_containing(:nope, "vct:///projects/foo", "/p/foo") == []
    end

    test "returns WORKSPACE mounts only", %{mounts: mounts} do
      assert Enum.all?(
               Table.workspaces_containing(mounts, "vct:///projects/foo", "/p/foo"),
               &Mount.workspace?/1
             )
    end
  end

  describe "find_by_os_path/2 and mount_for_path/2 — nil-path workspaces" do
    test "ignore a workspace without raising" do
      ws = workspace()
      project = git_mount("vct:///projects/foo", "/src/foo")

      assert Table.find_by_os_path([ws, project], "/src/foo") == project
      assert Table.find_by_os_path([ws, project], "/elsewhere") == nil
      assert Table.find_by_os_path([ws], "/src/foo") == nil

      assert Table.mount_for_path([ws, project], "/src/foo/src/auth.ex") == project
      assert Table.mount_for_path([ws, project], "/elsewhere") == nil
      assert Table.mount_for_path([ws], "/src/foo") == nil
    end

    test "keep the longest-prefix rule for git mounts" do
      outer = git_mount("vct:///projects/outer", "/src")
      inner = git_mount("vct:///projects/inner", "/src/inner")
      ws = workspace()

      mounts = [ws, outer, inner]

      assert Table.mount_for_path(mounts, "/src/inner/deep/file.ex") == inner
      assert Table.mount_for_path(mounts, "/src/other/file.ex") == outer
      assert Table.mount_for_path(mounts, "/srcinner") == nil
    end
  end

  describe "ensure_mount/4 — workspace points are refused" do
    test "a workspace point is never a file mount" do
      assert Table.ensure_mount([], @ws_point, "/src/foo", nil) == {:error, :invalid_point}

      assert Table.ensure_mount([], "vct:///workspaces/deep/one", "/src/foo", nil) ==
               {:error, :invalid_point}
    end
  end
end
