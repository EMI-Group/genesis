defmodule EvoDashWeb.DashboardLiveTest do
  use EvoDashWeb.ConnCase
  import Phoenix.LiveViewTest

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit_test_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      # Clean up the recent project entry to prevent DETS pollution
      # (belt-and-suspenders with the XDG_DATA_HOME redirect in test_helper.exs)
      try do
        EvoDash.TaskRegistry.remove_recent_project(tmp_dir)
      rescue
        _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  describe "dashboard without active project" do
    test "renders the dashboard page with Open a Project", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "EvoGit"
      assert html =~ "Open a Project"
    end

    test "does not show Project Settings button when no project is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "Project Settings"
    end

    test "shows All Tasks header when no project is open", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # When no project is active, the section header says "All Tasks"
      assert html =~ "All Tasks"
    end
  end

  describe "dashboard with active project" do
    test "shows Project Settings button after opening a project", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      # Initially no project settings button
      html = render(view)
      refute html =~ "Project Settings"

      # Open a project using the initial open project form
      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: tmp_dir})

      # Now project settings button should appear
      assert html =~ "Project Settings"
    end

    test "shows active and recent task sections after opening project", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      html = render(view)

      # Should show the empty state (no running or recent tasks yet)
      assert html =~ "No tasks yet"
      # Should show task form for the project
      assert html =~ "Configure Task"
    end

    test "detects genesis_new mode for empty directory", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: tmp_dir})

      # Should show a flash message about the detected mode
      assert html =~ "genesis" or html =~ "Genesis"
    end
  end

  describe "project settings panel toggle" do
    test "can toggle project settings panel open and closed", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open a project first
      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # Click toggle to show settings
      html = render_click(view, "toggle_project_settings", %{})

      # Should show evogit.toml configuration section
      assert html =~ "evogit.toml"
      # Should show project root
      assert html =~ tmp_dir
      # Should show Foreign Repositories section
      assert html =~ "Foreign Repositories"

      # Click again to hide
      html = render_click(view, "toggle_project_settings", %{})
      refute html =~ "evogit.toml"
    end

    test "project settings shows config file status", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open a project
      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # Toggle settings open
      html = render_click(view, "toggle_project_settings", %{})

      # Empty directory has no evogit.toml
      assert html =~ "Not found"
    end

    test "project settings shows worktree init script status", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open a project
      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # Toggle settings open
      html = render_click(view, "toggle_project_settings", %{})

      # No worktree script configured
      assert html =~ "Not configured"
    end

    test "project settings shows no foreign repos by default", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open a project
      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # Toggle settings open
      html = render_click(view, "toggle_project_settings", %{})

      # No foreign repos registered (scheduler likely not running in tests)
      assert html =~ "No repositories registered"
    end
  end

  describe "project settings button hides when project is closed" do
    test "closing the active project removes Project Settings button", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open a project
      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      html = render(view)
      assert html =~ "Project Settings"

      # Close the project
      html = render_click(view, "close_project", %{"path" => tmp_dir})
      refute html =~ "Project Settings"
      # Back to no-project state
      assert html =~ "Open a Project"
    end
  end

  describe "removed /settings/project route" do
    test "/settings/project returns 404", %{conn: conn} do
      conn = get(conn, "/settings/project")
      assert conn.status == 404
    end
  end

  describe "settings page no longer has project settings link" do
    test "settings page has no Project Settings link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      refute html =~ "Project Settings"
      refute html =~ "Foreign Repos"
    end
  end

  describe "opening invalid directory" do
    test "shows error for non-existent directory", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: "/nonexistent/directory/path"})

      assert html =~ "Directory does not exist"
    end
  end
end
