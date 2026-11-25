defmodule EvoDashWeb.ProjectsWorkbenchWorkspaceTest do
  # The async ProjectsLive suite clears the shared VCT registry. This test
  # needs its actual registered mounts to survive the LiveView's async read.
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EvoDashWeb.TestHelpers, only: [flush_loading: 4]

  alias EvoGit.VCT

  @async_wait_budget_ms 30_000

  test "workspace navigation keeps its VCT point while the selected member scopes the workbench",
       %{
         conn: conn
       } do
    EvoDash.Test.ConfigDir.isolate!("workbench_workspace_config")
    EvoGit.Config.VersionState.complete_onboarding()
    conn = Plug.Test.init_test_session(conn, %{})

    token = "workbench-workspace-#{System.pid()}-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), token)
    File.mkdir!(root)
    on_exit(fn -> EvoDash.Test.FsCleanup.rm_rf!(root) end)

    first = member!(root, "#{token}-first")
    second = member!(root, "#{token}-second")

    assert {:ok, workspace} =
             VCT.create_workspace(token, Enum.map([first, second], &%{"point" => &1.point}))

    on_exit(fn -> VCT.forget(workspace.point) end)

    {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: workspace.point}}")

    flush_loading(
      view,
      "data-overview-no-member",
      "workspace members did not resolve",
      @async_wait_budget_ms
    )

    assert has_element?(view, "#workbench-project-overview[data-overview-kind=workspace]")
    assert has_element?(view, "[data-overview-point]", workspace.point)
    assert_member_scope(view, workspace.point, first.path)

    view
    |> form("#overview-member-form", %{"overview_member" => second.point})
    |> render_change()

    assert has_element?(view, "[data-overview-execution-member]", second.path)
    assert_member_scope(view, workspace.point, second.path)

    render_patch(view, ~p"/projects?#{%{project: workspace.point, wb_home: "1"}}")

    assert_member_scope(view, workspace.point, second.path)

    assert has_element?(
             view,
             "#workbench-idle [data-workbench-idle-window]:not([hidden])",
             "No window selected"
           )

    refute has_element?(view, "#workbench-project-overview")
    refute has_element?(view, "#task-form")
  end

  defp member!(root, name) do
    path = Path.join(root, name)
    File.mkdir!(path)
    assert {:ok, mount} = VCT.mount(path, name: name)
    on_exit(fn -> VCT.forget(mount.point) end)
    mount
  end

  defp assert_member_scope(view, workspace, member) do
    assert has_element?(view, ~s(#app-layout[data-workbench-project="#{member}"]))

    assert has_element?(
             view,
             ~s(#dashboard-root[data-project="#{member}"][data-task-draft-project="#{workspace}"][data-workbench-compose=false])
           )

    assert has_element?(
             view,
             ~s(#workbench-history-project-filter option[selected][value="#{member}"])
           )

    assert has_element?(view, "#workbench-git-toggle")
  end
end
