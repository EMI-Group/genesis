defmodule EvoGit.VCTWorkspaceRPCTest do
  @moduledoc """
  Tests for the WORKSPACE half of the VCT node RPC surface:

    * `EvoGit.AgentScheduler.RemoteAPI` — the direct per-node functions
      (`workspaces/0`, `create_workspace/3`, `workspace_members/1`,
      `workspaces_for/1`).
    * `EvoGit.RemoteNode` — the node-first wrappers (the local path delegates to
      RemoteAPI; the remote branch is exercised through the unreachable-node
      `call_remote/4` failure path, same pattern as custom_agents_rpc_test.exs
      and remote_node_test.exs).

  `async: true` — every case starts its OWN isolated `EvoGit.Store` +
  `EvoGit.VCT` + `Phoenix.PubSub` stack (`EvoGit.VCTTest.Helpers`) and binds the
  `:evogit_vct_server` process-dictionary seam, so both RPC layers (which
  execute in the calling test process on the local path) hit that stack and
  never the app-global singletons.
  """

  use ExUnit.Case, async: true

  import EvoGit.VCTTest.Helpers

  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.RemoteNode
  alias EvoGit.VCT.Mount

  @moduletag :tmp_dir

  # A node name that definitely does not exist on this machine (same pattern as
  # remote_node_test.exs). On a non-distributed local node, :erpc.call to a
  # foreign node fails immediately with {:erpc, :noconnection} — no TCP
  # timeout wait.
  @fake_remote :"nonexistent@127.0.0.1"

  # A registered-name candidate nothing listens on, so `EvoGit.VCT`'s call
  # wrapper exits with :noproc and answers its documented degraded value —
  # exactly what an absent VCT server does.
  @absent_vct :evogit_vct_absent_for_workspace_rpc_test

  describe "RemoteAPI.create_workspace/3" do
    test "creates a real workspace mount with ordered members and a description",
         %{tmp_dir: tmp} do
      start_stack(tmp)
      a = dir!(Path.join(tmp, "app-a"))
      b = dir!(Path.join(tmp, "app-b"))

      assert {:ok, %Mount{} = workspace} =
               RemoteAPI.create_workspace(
                 "Frontend",
                 [
                   %{"point" => "vct:///projects/web"},
                   %{"path" => a},
                   %{"point" => "vct:///projects/api", "path" => b}
                 ],
                 description: "  Web apps  "
               )

      assert workspace.point == "vct:///workspaces/Frontend"
      assert workspace.kind == "workspace"
      assert workspace.path == nil
      assert workspace.name == "Frontend"
      assert workspace.description == "Web apps"
      assert %DateTime{} = workspace.last_opened_at

      assert workspace.members == [
               %{"point" => "vct:///projects/web", "path" => nil},
               %{"point" => nil, "path" => a},
               %{"point" => "vct:///projects/api", "path" => b}
             ]

      # A workspace is neither a project mount nor an OS artifact.
      assert RemoteAPI.projects() == []
      refute File.exists?(workspace.point)
    end

    test "propagates validation errors verbatim", %{tmp_dir: tmp} do
      start_stack(tmp)

      assert {:error, :invalid_name} = RemoteAPI.create_workspace("  ", [], [])

      assert {:error, {:invalid_member, _ref}} =
               RemoteAPI.create_workspace("Broken", [%{}], [])

      assert {:ok, inner} = RemoteAPI.create_workspace("Inner", [], [])

      assert {:error, {:member_is_workspace, point}} =
               RemoteAPI.create_workspace("Outer", [%{"point" => inner.point}], [])

      assert point == inner.point
    end
  end

  describe "RemoteAPI.workspaces/0" do
    test "lists the created workspace, newest first", %{tmp_dir: tmp} do
      start_stack(tmp)
      assert RemoteAPI.workspaces() == []

      assert {:ok, first} = RemoteAPI.create_workspace("First", [], [])
      assert {:ok, second} = RemoteAPI.create_workspace("Second", [], [])

      # `last_opened_at` has millisecond wire precision in the table; two
      # creates in the same millisecond would make recency ambiguous, so only
      # the pair is asserted.
      assert Enum.sort(points(RemoteAPI.workspaces())) ==
               Enum.sort([first.point, second.point])

      # Workspaces are neither project mounts nor reserved mounts, so the
      # project listing never returns them.
      assert RemoteAPI.projects() == []
    end
  end

  describe "RemoteAPI.workspace_members/1" do
    test "resolves members and reports an unresolvable ref as missing", %{tmp_dir: tmp} do
      start_stack(tmp)
      a = dir!(Path.join(tmp, "app-a"))
      {:ok, app_a} = RemoteAPI.mount_project(a, nil)

      assert {:ok, workspace} =
               RemoteAPI.create_workspace(
                 "Mixed",
                 [
                   %{"point" => app_a.point},
                   %{"point" => "vct:///projects/never-existed"}
                 ],
                 []
               )

      assert {:ok, resolution} = RemoteAPI.workspace_members(workspace.point)

      assert %{
               workspace: %Mount{point: workspace_point},
               members: [member],
               missing: missing,
               nested: []
             } = resolution

      assert workspace_point == workspace.point
      assert member.point == app_a.point

      assert missing == [
               %{"point" => "vct:///projects/never-existed", "path" => nil}
             ]

      # The same workspace by BARE name.
      assert {:ok, ^resolution} = RemoteAPI.workspace_members("Mixed")
    end

    test "rejects a non-workspace point", %{tmp_dir: tmp} do
      start_stack(tmp)
      a = dir!(Path.join(tmp, "app-a"))
      {:ok, app_a} = RemoteAPI.mount_project(a, nil)

      assert {:error, :not_a_workspace} = RemoteAPI.workspace_members(app_a.point)
      assert {:error, :not_found} = RemoteAPI.workspace_members("Ghost")
    end
  end

  describe "RemoteAPI.workspaces_for/1" do
    test "matches a project from its point", %{tmp_dir: tmp} do
      start_stack(tmp)
      a = dir!(Path.join(tmp, "app-a"))
      {:ok, app_a} = RemoteAPI.mount_project(a, nil)

      assert RemoteAPI.workspaces_for(app_a.point) == []

      assert {:ok, workspace} =
               RemoteAPI.create_workspace("Group", [%{"point" => app_a.point}], [])

      assert [%Mount{point: point}] = RemoteAPI.workspaces_for(app_a.point)
      assert point == workspace.point

      # A project nothing covers answers [].
      assert RemoteAPI.workspaces_for("vct:///projects/uncovered") == []
    end
  end

  # ── Degradations: VCT absent ───────────────────────────────────────

  describe "RemoteAPI workspace reads with the VCT unavailable" do
    setup do
      # No stack: the seam names an unregistered process, so every read takes
      # its documented degraded value.
      Process.put(:evogit_vct_server, @absent_vct)
      :ok
    end

    test "list reads degrade to []" do
      assert RemoteAPI.workspaces() == []
      assert RemoteAPI.workspaces_for("vct:///projects/anything") == []
    end

    test "workspace_members/1 degrades to {:error, :not_found}" do
      assert RemoteAPI.workspace_members("vct:///workspaces/anything") ==
               {:error, :not_found}
    end

    test "create_workspace/3 degrades to {:error, :vct_unavailable}" do
      assert RemoteAPI.create_workspace("Group", [], []) == {:error, :vct_unavailable}
    end
  end

  # ── RemoteNode wrappers (local node) ───────────────────────────────

  describe "RemoteNode workspace wrappers on the local node" do
    test "delegate to RemoteAPI", %{tmp_dir: tmp} do
      start_stack(tmp)
      a = dir!(Path.join(tmp, "app-a"))
      {:ok, app_a} = RemoteAPI.mount_project(a, nil)

      assert RemoteNode.workspaces(node()) == []

      assert {:ok, %Mount{} = workspace} =
               RemoteNode.create_workspace(
                 node(),
                 "Frontend",
                 [%{"point" => app_a.point}],
                 description: "Web apps"
               )

      assert workspace.point == "vct:///workspaces/Frontend"
      assert workspace.description == "Web apps"

      assert [listed] = RemoteNode.workspaces(node())
      assert listed.point == workspace.point

      assert {:ok, resolution} = RemoteNode.workspace_members(node(), workspace.point)
      assert resolution.workspace.point == workspace.point
      assert Enum.map(resolution.members, & &1.point) == [app_a.point]
      assert resolution.missing == []
      assert resolution.nested == []

      assert [covered] = RemoteNode.workspaces_for(node(), app_a.point)
      assert covered.point == workspace.point
      assert RemoteNode.workspaces_for(node(), "vct:///projects/uncovered") == []
    end

    test "surface RemoteAPI's degradation on the local path" do
      Process.put(:evogit_vct_server, @absent_vct)

      assert RemoteNode.workspaces(node()) == []
      assert RemoteNode.workspaces_for(node(), "vct:///projects/x") == []
      assert RemoteNode.workspace_members(node(), "Group") == {:error, :not_found}

      assert RemoteNode.create_workspace(node(), "Group", [], []) ==
               {:error, :vct_unavailable}
    end
  end

  # ── RemoteNode wrappers (unreachable remote node) ──────────────────
  #
  # The list reads degrade to [], the user-action RPCs surface the failure as
  # {:error, {kind, reason}}.

  describe "RemoteNode workspace wrappers on an unreachable remote node" do
    test "list reads degrade to []" do
      assert RemoteNode.workspaces(@fake_remote) == []
      assert RemoteNode.workspaces_for(@fake_remote, "vct:///projects/x") == []
    end

    test "create_workspace/4 surfaces the RPC failure" do
      assert {:error, {_kind, _reason}} =
               RemoteNode.create_workspace(@fake_remote, "Group", [], [])
    end

    test "workspace_members/2 surfaces the RPC failure" do
      assert {:error, {_kind, _reason}} =
               RemoteNode.workspace_members(@fake_remote, "Group")
    end
  end
end
