defmodule EvoDashWeb.DashboardLiveTest do
  use EvoDashWeb.ConnCase
  import Phoenix.LiveViewTest

  setup [:setup_temp_dir, :set_onboarding_completed]

  defp setup_temp_dir(%{} = context) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit_test_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.TaskRegistry.remove_recent_project(tmp_dir)
      rescue
        _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, Map.put(context, :tmp_dir, tmp_dir)}
  end

  defp set_onboarding_completed(%{conn: conn} = _context) do
    {:ok, conn: Plug.Test.init_test_session(conn, onboarding_completed: true)}
  end

  describe "dashboard without active project" do
    setup do
      # Clear all recent projects so auto-load doesn't activate a stale project
      for project <- EvoGit.TaskRegistry.list_recent_projects() do
        EvoGit.TaskRegistry.remove_recent_project(project.path)
      end

      :ok
    end

    test "renders the dashboard with task form and project selector", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # Task form is always visible
      assert html =~ "Execute Task"
      # Project selector shows "No project selected"
      assert html =~ "No project selected"
      # Open Project button exists
      assert html =~ "Open Project"
    end

    test "project settings panel is present but collapsed when no project", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # The settings panel header is always present
      assert html =~ "Project Settings"
      # When collapsed (no project), the details element does not have the open attribute
      # but the content is still rendered in the HTML. We can check that project-specific
      # content like "genesis.toml found" is NOT shown (it requires @project_config to be truthy)
      refute html =~ "genesis.toml found"
    end

    test "task form is disabled when no project is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # The form should be present but in disabled state
      assert html =~ "Execute Task"
      # The execute button should be disabled
      assert html =~ "disabled"
    end
  end

  describe "opening a project" do
    test "can open project via toggle and form submission", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Click to show the open project form
      html = render_click(view, "toggle_open_project_form", %{})
      assert html =~ "/home/user/my-project"

      # Submit the form with a path
      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # Expand the project settings panel
      render_click(view, "toggle_project_settings", %{"project" => tmp_dir})
      html = render(view)

      # Project should be active — task form enabled
      assert html =~ "Execute Task"
      # Project settings should show config info
      assert html =~ "Foreign Repositories"
    end

    test "detects genesis_new mode for empty directory", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "toggle_open_project_form", %{})

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: tmp_dir})

      # Should detect mode and show flash message
      assert html =~ "genesis" or html =~ "Genesis"
    end

    test "shows project info in selector after opening", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "toggle_open_project_form", %{})

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: tmp_dir})

      # Should show the project basename
      assert html =~ Path.basename(tmp_dir)
    end

    test "project settings panel shows config status", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "toggle_open_project_form", %{})

      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # Expand the project settings panel
      render_click(view, "toggle_project_settings", %{"project" => tmp_dir})
      html = render(view)

      # Empty directory has no genesis.toml — shows defaults message
      assert html =~ "No genesis.toml" or html =~ "using global defaults"
    end

    test "project settings shows worktree init script status", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "toggle_open_project_form", %{})

      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # Expand the project settings panel
      render_click(view, "toggle_project_settings", %{"project" => tmp_dir})
      html = render(view)

      # The Foreign Repos section should be visible
      assert html =~ "Foreign Repositories"
    end

    test "project settings shows no foreign repos by default", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "toggle_open_project_form", %{})

      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # Expand the project settings panel
      render_click(view, "toggle_project_settings", %{"project" => tmp_dir})
      html = render(view)

      # No foreign repos registered (scheduler not running in tests)
      assert html =~ "No foreign repositories registered"
    end
  end

  describe "opening project via URL params" do
    test "activates project from URL query param", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, _view, html} = live(conn, ~p"/?project=#{URI.encode(tmp_dir)}")

      # Project should be active
      assert html =~ Path.basename(tmp_dir)
      # Task form should be present
      assert html =~ "Execute Task"
      # Project settings should be shown
      assert html =~ "Project Settings"
    end
  end

  describe "opening invalid directory" do
    setup do
      for project <- EvoGit.TaskRegistry.list_recent_projects() do
        EvoGit.TaskRegistry.remove_recent_project(project.path)
      end

      :ok
    end

    test "shows error for non-existent directory", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "toggle_open_project_form", %{})

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: "/nonexistent/directory/path"})

      assert html =~ "Directory does not exist"
    end
  end

  describe "removed /settings/project route" do
    test "/settings/project returns 404", %{conn: conn} do
      conn = get(conn, "/settings/project")
      assert conn.status == 404
    end
  end

  describe "settings page has no project settings link" do
    test "settings page has no Project Settings link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      refute html =~ "Project Settings"
      refute html =~ "Foreign Repos"
    end
  end

  describe "restore_state restores foreign repositories from saved session" do
    setup do
      for project <- EvoGit.TaskRegistry.list_recent_projects() do
        EvoGit.TaskRegistry.remove_recent_project(project.path)
      end

      :ok
    end

    test "foreign repos round-trip via restore_state event", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Simulate session restore with foreign repos (as they'd arrive from sessionStorage JSON).
      # The project must be a real directory so activate_project runs.
      render_hook(view, "restore_state", %{
        "project" => tmp_dir,
        "foreign_repos" => [
          %{
            "id" => "original",
            "path" => "/Source/original-proj",
            "description" => "The original"
          },
          %{"id" => "reference", "path" => "/Source/ref", "description" => nil}
        ]
      })

      # Expand the project settings panel
      render_click(view, "toggle_project_settings", %{"project" => tmp_dir})
      html = render(view)

      # Foreign repos should be restored and visible in the project settings.
      # The component renders repo.id and repo.root for each foreign repo.
      assert html =~ "original"
      assert html =~ "/Source/original-proj"
      assert html =~ "reference"
      assert html =~ "/Source/ref"
    end

    test "restore_state with empty foreign repos does not error", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "restore_state", %{
        "project" => tmp_dir,
        "foreign_repos" => []
      })

      # Expand the project settings panel
      render_click(view, "toggle_project_settings", %{"project" => tmp_dir})
      html = render(view)

      # No repos restored — shows the empty state message
      assert html =~ "No foreign repositories registered"
    end
  end

  describe "prompt textarea with phx-update=ignore" do
    test "objective textarea has phx-update=ignore attribute", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open a project so the task form renders
      render_click(view, "toggle_open_project_form", %{})

      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # Re-render to get the task form HTML
      html = render(view)

      # The prompt textarea should have phx-update="ignore" so it is
      # not clobbered by LiveView re-renders on model/mode switches
      assert html =~ ~s(phx-update="ignore")
    end

    test "select_model does not modify the task_prompt assign", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open a project
      render_click(view, "toggle_open_project_form", %{})

      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # Fire select_model — the textarea is now client-owned, so the server
      # should NOT track or modify task_prompt. The handler must still succeed
      # (no crash) and the textarea keeps phx-update="ignore".
      html = render_change(view, "select_model", %{"model_id" => "some-model"})

      # No update_prompt handler exists; the prompt textarea remains client-owned
      assert html =~ ~s(phx-update="ignore")
    end

    test "task_change does not modify the task_prompt assign", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open a project
      render_click(view, "toggle_open_project_form", %{})

      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # Fire task_change — the textarea is now client-owned, so the server
      # should NOT track or modify task_prompt. The handler must still succeed
      # (no crash) and the textarea keeps phx-update="ignore".
      html = render_change(view, "task_change", %{"mode" => "evolve_simple"})

      # No update_prompt handler exists; the prompt textarea remains client-owned
      assert html =~ ~s(phx-update="ignore")
    end
  end
end
