defmodule EvoGit.Agent.Tools.WorkspaceCommandsTest do
  @moduledoc """
  Tests for the read-only WORKSPACE command handlers
  `EvoGit.Agent.Tools.ListWorkspaces` (`ListWorkspaces.list_workspaces`) and
  `EvoGit.Agent.Tools.ShowWorkspace` (`ShowWorkspace.workspace_members`), plus
  their `EvoGit.CommandShell` registry entries.

  Each test runs against the isolated `EvoGit.Store` + `EvoGit.VCT` +
  `EvoGit.TaskRegistry` trio from `EvoGit.TaskRegistryCase`, so no app-global
  or reserved mount is created, changed or forgotten; `async: true` is safe
  because the module mutates no BEAM-global state (the isolated VCT's
  `{:vct_updated, node}` broadcast reaches the app-global `EvoGit.PubSub`,
  which no concurrently running test asserts on).
  """

  use EvoGit.TaskRegistryCase, async: true

  @moduletag :tmp_dir

  alias EvoGit.Agent.Tools.ListWorkspaces
  alias EvoGit.Agent.Tools.ShowWorkspace
  alias EvoGit.CommandShell

  # A member ref that no mount can resolve: the VCT stores it verbatim and
  # reports it as MISSING, which is exactly the diagnostic this test pins.
  @missing_path "/nonexistent/legacy-app"

  describe "ListWorkspaces" do
    test "lists a workspace with its point, name, ordered members and description", %{
      vct: vct
    } do
      project = mount_project!("/proj/web", "Web App")
      workspace = create_workspace!("Web Suite", project.point, "Frontend apps")
      forget_on_exit(workspace, vct)

      assert ListWorkspaces.execute(%{}, nil, nil) ==
               "#{workspace.point} | name: Web Suite | " <>
                 "members: #{project.point}, #{@missing_path} | description: Frontend apps"
    end

    test "renders a missing description and an empty member list as '-'", %{vct: vct} do
      assert {:ok, workspace} = EvoGit.VCT.create_workspace("Bare", [])
      forget_on_exit(workspace, vct)

      assert ListWorkspaces.execute(%{}, nil, nil) ==
               "#{workspace.point} | name: Bare | members: - | description: -"
    end

    test "returns No workspaces found for an empty workspace table" do
      # The isolated VCT starts with no mounts at all, so the listing is empty.
      assert ListWorkspaces.execute(%{}, nil, nil) == "No workspaces found."
    end
  end

  describe "ShowWorkspace" do
    test "shows the header, the resolved member and a MISSING line per unresolved ref", %{
      vct: vct
    } do
      project = mount_project!("/proj/web", "Web App")
      workspace = create_workspace!("Web Suite", project.point, "Frontend apps")
      forget_on_exit(workspace, vct)

      # A BARE name resolves too, and members stay in STORED order.
      assert ShowWorkspace.execute(%{"workspace" => "Web Suite"}, nil, nil) ==
               "#{workspace.point} | Web Suite | Frontend apps\n" <>
                 "#{project.point} | Web App | /proj/web\n" <>
                 "MISSING: #{@missing_path}"
    end

    test "accepts the workspace point as the key", %{vct: vct} do
      project = mount_project!("/proj/api", "API")
      workspace = create_workspace!("API Suite", project.point, nil)
      forget_on_exit(workspace, vct)

      assert ShowWorkspace.execute(%{"workspace" => workspace.point}, nil, nil) ==
               "#{workspace.point} | API Suite | -\n" <>
                 "#{project.point} | API | /proj/api\n" <>
                 "MISSING: #{@missing_path}"
    end

    test "rejects a non-workspace key", %{vct: vct} do
      project = mount_project!("/proj/web", "Web App")
      workspace = create_workspace!("Web Suite", project.point, "Frontend apps")
      forget_on_exit(workspace, vct)

      assert {:error, message} =
               ShowWorkspace.execute(%{"workspace" => project.point}, nil, nil)

      assert message =~ "Not a workspace"
      assert message =~ project.point
      assert message =~ "not a workspace"
    end

    test "reports an unknown workspace key" do
      assert ShowWorkspace.execute(%{"workspace" => "ghost"}, nil, nil) ==
               {:error, "Workspace not found: ghost"}
    end

    test "reports an unusable key" do
      assert ShowWorkspace.execute(%{"workspace" => "/abs/path"}, nil, nil) ==
               {:error, "Invalid workspace point: /abs/path"}
    end

    test "requires a nonblank workspace argument" do
      assert ShowWorkspace.execute(%{}, nil, nil) ==
               {:error, "Missing required argument 'workspace'. Please provide a valid value."}

      assert ShowWorkspace.execute(%{"workspace" => "   "}, nil, nil) ==
               {:error, "Missing required argument 'workspace'. Please provide a valid value."}

      assert ShowWorkspace.execute(nil, nil, nil) == {:error, "Arguments must be a map/object"}
    end
  end

  describe "CommandShell dispatch" do
    test "ListWorkspaces.list_workspaces is a level-1 command returning the listing", %{
      vct: vct
    } do
      project = mount_project!("/proj/web", "Web App")
      workspace = create_workspace!("Web Suite", project.point, "Frontend apps")
      forget_on_exit(workspace, vct)

      assert CommandShell.security_level("ListWorkspaces.list_workspaces") == 1

      assert CommandShell.execute("ListWorkspaces.list_workspaces") ==
               {:ok,
                "#{workspace.point} | name: Web Suite | " <>
                  "members: #{project.point}, #{@missing_path} | description: Frontend apps"}
    end

    test "ShowWorkspace.workspace_members is level 1 and takes the workspace positional", %{
      vct: vct
    } do
      project = mount_project!("/proj/web", "Web App")
      workspace = create_workspace!("WebSuite", project.point, "Frontend apps")
      forget_on_exit(workspace, vct)

      assert CommandShell.security_level("ShowWorkspace.workspace_members") == 1

      # The bare display name resolves too (quoted when it contains a space).
      assert CommandShell.execute(~s|ShowWorkspace.workspace_members "WebSuite"|) ==
               {:ok,
                "#{workspace.point} | WebSuite | Frontend apps\n" <>
                  "#{project.point} | Web App | /proj/web\n" <>
                  "MISSING: #{@missing_path}"}

      assert CommandShell.execute("ShowWorkspace.workspace_members #{workspace.point}") ==
               {:ok,
                "#{workspace.point} | WebSuite | Frontend apps\n" <>
                  "#{project.point} | Web App | /proj/web\n" <>
                  "MISSING: #{@missing_path}"}
    end

    test "a second positional argument is rejected" do
      assert CommandShell.execute(~s|ShowWorkspace.workspace_members "Web Suite" "API Suite"|) ==
               {:error,
                "Too many positional arguments for 'ShowWorkspace.workspace_members': " <>
                  "expected at most 1."}
    end

    test "the handler's error tuple propagates as a shell error" do
      assert CommandShell.execute("ShowWorkspace.workspace_members ghost") ==
               {:error, "Workspace not found: ghost"}
    end
  end

  # --- Fixtures ---
  defp mount_project!(path, name) do
    assert {:ok, mount} = EvoGit.VCT.mount(path, name: name)
    mount
  end

  # ONE resolved project member (by point) plus ONE deliberately unresolvable
  # path member, so every output pins both the resolved and the missing branch.
  defp create_workspace!(name, project_point, description) do
    members = [%{"point" => project_point}, %{"path" => @missing_path}]
    opts = if description, do: [description: description], else: []

    assert {:ok, workspace} = EvoGit.VCT.create_workspace(name, members, opts)
    workspace
  end

  # `on_exit/1` runs OUTSIDE the test process, so the isolated-instance seam has
  # to be re-installed there — without it the call would reach the APP-GLOBAL
  # `EvoGit.VCT`. The instance (and its per-test SQLite file) is normally
  # already stopped by then, so the outcome is deliberately ignored.
  defp forget_on_exit(workspace, vct_name) do
    on_exit(fn ->
      Process.put(:evogit_vct_server, vct_name)
      _ = EvoGit.VCT.forget(workspace.point)
    end)
  end
end
