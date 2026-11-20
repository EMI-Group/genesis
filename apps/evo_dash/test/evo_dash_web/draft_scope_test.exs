defmodule EvoDashWeb.DraftScopeTest do
  use ExUnit.Case, async: true
  alias EvoDashWeb.DraftScope
  alias EvoGit.VCT.Mount

  # Draft scope identity is `{node, token}`: the selected project's VCT point, or
  # the raw OS path when the project has no point yet. These are pure unit tests —
  # no store, no mounts table, no filesystem.
  describe "token/1" do
    test "a project mount's point wins over its path" do
      mount = %Mount{point: "vct:///projects/foo", path: "/repo"}
      assert DraftScope.token(mount) == "vct:///projects/foo"
    end

    test "two points over the same OS path produce different tokens" do
      one = %Mount{point: "vct:///projects/one", path: "/repo"}
      two = %Mount{point: "vct:///projects/two", path: "/repo"}

      assert DraftScope.token(one) == "vct:///projects/one"
      assert DraftScope.token(two) == "vct:///projects/two"
      assert DraftScope.token(one) != DraftScope.token(two)
    end

    test "string-keyed maps and the vct_path spelling resolve the same point" do
      assert DraftScope.token(%{"point" => "vct:///projects/foo", "path" => "/repo"}) ==
               "vct:///projects/foo"

      assert DraftScope.token(%{"vct_path" => "vct:///projects/foo", "path" => "/repo"}) ==
               "vct:///projects/foo"
    end

    test "a blank point falls back to the path verbatim" do
      assert DraftScope.token(%Mount{point: "", path: "/repo"}) == "/repo"
      assert DraftScope.token(%{point: nil, path: "/repo"}) == "/repo"
      assert DraftScope.token(%{point: "   ", path: "/repo"}) == "/repo"
      assert DraftScope.token("/repo") == "/repo"
    end

    test "a path is never expanded, trimmed or mangled" do
      assert DraftScope.token(%{path: "/repo/../repo/./sub"}) == "/repo/../repo/./sub"
      assert DraftScope.token("~/projects/mine") == "~/projects/mine"
      assert DraftScope.token("C:\\repo") == "C:\\repo"
    end

    test "a bare VCT point is its own token" do
      assert DraftScope.token("vct:///projects/foo") == "vct:///projects/foo"
    end
  end

  describe "project/1 and workspace/1" do
    test "a project mount is a project, not a workspace" do
      mount = %Mount{point: "vct:///projects/foo", path: "/repo"}
      assert DraftScope.project(mount) == "vct:///projects/foo"
      assert DraftScope.workspace(mount) == nil
    end

    test "a workspace mount is a workspace, never a project" do
      workspace = %Mount{point: "vct:///workspaces/foobar", path: nil, kind: "workspace"}
      assert DraftScope.workspace(workspace) == "vct:///workspaces/foobar"
      assert DraftScope.project(workspace) == nil
    end

    test "workspace and project tokens differ for the same underlying repo" do
      workspace = %Mount{point: "vct:///workspaces/foobar", path: nil, kind: "workspace"}
      project = %Mount{point: "vct:///projects/foo", path: "/repo"}

      assert DraftScope.token(workspace) != DraftScope.token(project)
    end

    test "a bare path belongs to no workspace" do
      assert DraftScope.project("/repo") == "/repo"
      assert DraftScope.workspace("/repo") == nil
    end
  end

  describe "point?/1" do
    test "true for vct points only" do
      assert DraftScope.point?("vct:///projects/foo")
      assert DraftScope.point?("vct:///workspaces/foobar")
      refute DraftScope.point?(%Mount{point: "vct:///projects/foo"})
      refute DraftScope.point?("/repo")
      refute DraftScope.point?(nil)
    end
  end

  describe "path/1" do
    test "returns the OS path of a mounted project" do
      assert DraftScope.path(%Mount{point: "vct:///projects/foo", path: "/repo"}) == "/repo"
      assert DraftScope.path(%{"path" => "/repo"}) == "/repo"
      assert DraftScope.path("/repo") == "/repo"
    end

    test "never returns a vct: value" do
      assert DraftScope.path(%Mount{point: "vct:///projects/foo", path: nil}) == nil

      assert DraftScope.path(%Mount{
               point: "vct:///workspaces/foobar",
               path: nil,
               kind: "workspace"
             }) ==
               nil

      assert DraftScope.path("vct:///projects/foo") == nil
      assert DraftScope.path(%{"vct_path" => "vct:///projects/foo"}) == nil
    end

    test "is total for garbage" do
      assert DraftScope.path(nil) == nil
      assert DraftScope.path(%{path: 42}) == nil
      assert DraftScope.path([{:path, "/repo"}]) == nil
    end
  end

  describe "store_key/2" do
    test "a path token reproduces the legacy browser key byte for byte" do
      assert DraftScope.store_key("local", "/repo") == ~S(dashboard_state:["local","/repo"])
      assert DraftScope.store_key(nil, "/repo") == ~S(dashboard_state:["local","/repo"])
      assert DraftScope.store_key("remote-a", "/repo") == ~S(dashboard_state:["remote-a","/repo"])
    end

    test "a VCT point is used verbatim as the key segment" do
      assert DraftScope.store_key("local", "vct:///projects/foo") ==
               ~S(dashboard_state:["local","vct:///projects/foo"])
    end

    test "a nil or blank token is the un-scoped legacy key" do
      assert DraftScope.store_key("local", nil) == "dashboard_state"
      assert DraftScope.store_key("remote-a", "") == "dashboard_state"
      assert DraftScope.store_key("local", %Mount{}) == "dashboard_state"
    end
  end

  describe "legacy_store_key/2" do
    test "is the path-keyed key a VCT-scoped entry may be migrated from" do
      mount = %Mount{point: "vct:///projects/foo", path: "/repo"}

      assert DraftScope.legacy_store_key("local", mount) ==
               DraftScope.store_key("local", "/repo")
    end

    test "is nil without an OS path" do
      assert DraftScope.legacy_store_key("local", "vct:///projects/foo") == nil
      assert DraftScope.legacy_store_key("local", nil) == nil
    end
  end
end
