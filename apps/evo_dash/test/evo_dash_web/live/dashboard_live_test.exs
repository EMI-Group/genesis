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

  # The DashboardLive mount redirects first-time users to /welcome via
  # server-based detection (EvoGit.Config.VersionState.onboarding_needed?/0,
  # which is true when no version-state file exists). To keep the dashboard
  # tests deterministic regardless of host state, isolate the config dir to a
  # temp directory and mark onboarding complete by writing a version-state
  # file there. This mirrors WelcomeLiveTest's XDG isolation approach.
  defp set_onboarding_completed(%{conn: conn} = _context) do
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_dashboard_test_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_config)
    original = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)

    # Create the version-state file so onboarding_needed?/0 returns false.
    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end

    on_exit(fn ->
      if original do
        System.put_env("XDG_CONFIG_HOME", original)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_config)
    end)

    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  # Clears all recent projects from the shared SQLite store so tests are
  # deterministic regardless of what other tests in this file inserted.
  defp clear_recent_projects do
    for project <- EvoGit.TaskRegistry.list_recent_projects() do
      EvoGit.TaskRegistry.remove_recent_project(project.path)
    end

    :ok
  end

  # Seeds a recent project via the public TaskRegistry API and registers
  # on_exit cleanup so it never leaks into other tests (the shared SQLite
  # store persists across tests in this file).
  defp seed_recent_project(path, name) do
    EvoGit.TaskRegistry.add_recent_project(path, name)

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.TaskRegistry.remove_recent_project(path)
      rescue
        _ -> :ok
      end
    end)
  end

  # Extracts the inner HTML of the edit-mode path-suggestion datalist so
  # option ordering/uniqueness can be asserted precisely.
  defp path_suggestions_datalist(html) do
    case Regex.run(~r{<datalist id="path-suggestions">(.*?)</datalist>}s, html) do
      [_, inner] -> inner
      _ -> ""
    end
  end

  # Returns the byte index of the first occurrence of `pattern` in `string`,
  # or nil if it is not present.
  defp string_index(string, pattern) do
    case :binary.match(string, pattern) do
      {idx, _len} -> idx
      :nomatch -> nil
    end
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
      assert html =~ "🚀 Launch"
      # Command palette trigger shows the placeholder when no project is active
      assert html =~ "Open a project..."
    end

    test "project settings panel is present but collapsed when no project", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # The Configure dropdown is always present
      assert html =~ "Configure"
      # Project-specific content like "genesis.toml found" is NOT shown
      # (it requires @project_config to be truthy)
      refute html =~ "genesis.toml found"
    end

    test "task form is disabled when no project is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # The form should be present but in disabled state
      assert html =~ "🚀 Launch"
      # The execute button should be disabled
      assert html =~ "disabled"
    end
  end

  describe "opening a project" do
    test "can open project via palette and form submission", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open the palette and switch to open-path mode
      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      # Submit the form with a path
      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # Expand the project settings panel
      render_click(view, "toggle_project_settings", %{"project" => tmp_dir})
      html = render(view)

      # Project should be active — task form enabled
      assert html =~ "🚀 Launch"
      # Project settings should show config info
      assert html =~ "Foreign Repositories"
    end

    test "detects genesis_new mode for empty directory", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: tmp_dir})

      # Should detect mode and show flash message
      assert html =~ "genesis" or html =~ "Genesis"
    end

    test "shows project info in selector after opening", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: tmp_dir})

      # Should show the project basename
      assert html =~ Path.basename(tmp_dir)
    end

    test "project settings panel shows config status", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

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

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

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

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

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
      assert html =~ "🚀 Launch"
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

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

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
      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

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
      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

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
      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

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

  describe "configure dropdown" do
    setup do
      clear_recent_projects()
    end

    test "toggle_configure_dropdown opens and closes the dropdown", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      # The dropdown content is ALWAYS in the DOM (hidden via CSS when closed)...
      assert html =~ "Task Options"
      # ...but the click-catcher overlay only renders while open
      refute html =~ ~s(phx-click="close_configure_dropdown")

      html = render_click(view, "toggle_configure_dropdown", %{})
      assert html =~ ~s(phx-click="close_configure_dropdown")
      assert html =~ ~s(class="fixed inset-0 z-40")

      html = render_click(view, "toggle_configure_dropdown", %{})
      refute html =~ ~s(phx-click="close_configure_dropdown")
    end

    test "close_configure_dropdown closes an open dropdown", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "toggle_configure_dropdown", %{})

      html = render_click(view, "close_configure_dropdown", %{})
      refute html =~ ~s(phx-click="close_configure_dropdown")
    end
  end

  describe "project palette" do
    setup do
      clear_recent_projects()
    end

    test "open_project_palette opens and close_project_palette closes it", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      # Closed: the search input and backdrop are not rendered
      assert html =~ "Open a project..."
      refute html =~ ~s(id="palette-search-input")

      html = render_click(view, "open_project_palette", %{})
      assert html =~ ~s(id="palette-search-input")
      assert html =~ ~s(phx-click="close_project_palette")

      html = render_click(view, "close_project_palette", %{})
      refute html =~ ~s(id="palette-search-input")
      assert html =~ "Open a project..."
    end

    test "palette_mode switches to open_path mode showing the path input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_project_palette", %{})

      html = render_click(view, "palette_mode", %{"mode" => "open_path"})
      assert html =~ ~s(id="project-path-input")
      assert html =~ ~s(<datalist id="path-suggestions">)
    end

    test "entering open_path mode seeds the datalist with recent project paths", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      recent_a = Path.join(tmp_dir, "recent-alpha")
      recent_b = Path.join(tmp_dir, "recent-beta")
      File.mkdir_p!(recent_a)
      File.mkdir_p!(recent_b)
      seed_recent_project(recent_a, "recent-alpha")
      seed_recent_project(recent_b, "recent-beta")

      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_project_palette", %{})
      html = render_click(view, "palette_mode", %{"mode" => "open_path"})

      datalist = path_suggestions_datalist(html)
      assert datalist =~ ~s(<option value="#{recent_a}"></option>)
      assert datalist =~ ~s(<option value="#{recent_b}"></option>)
    end

    test "palette_menu shows recent projects as clickable items", %{conn: conn, tmp_dir: tmp_dir} do
      project_a = Path.join(tmp_dir, "my-alpha")
      File.mkdir_p!(project_a)
      seed_recent_project(project_a, "my-alpha")

      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "open_project_palette", %{})
      assert html =~ "my-alpha"
      assert html =~ ~s(phx-click="select_project")
      assert html =~ ~s(phx-value-path="#{project_a}")
    end

    test "palette_menu shows Create New Project and Open by Path actions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "open_project_palette", %{})
      assert html =~ "Open Project by Path"
      assert html =~ "Create New Project"
    end

    test "palette_mode switches to new_project mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_project_palette", %{})

      html = render_click(view, "palette_mode", %{"mode" => "new_project"})
      assert html =~ ~s(id="new-project-location-input")
    end

    test "palette_search filters recent projects by name", %{conn: conn, tmp_dir: tmp_dir} do
      project_a = Path.join(tmp_dir, "my-alpha")
      project_b = Path.join(tmp_dir, "my-beta")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)
      seed_recent_project(project_a, "my-alpha")
      seed_recent_project(project_b, "my-beta")

      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_project_palette", %{})

      html =
        render_change(view, "palette_search", %{
          "palette_search" => "alpha",
          "_target" => ["palette_search"]
        })

      # Filtered: alpha shows as a clickable select_project item
      assert html =~ "my-alpha"
      # beta's path should NOT appear as a select_project target in the palette
      refute html =~ ~s(phx-value-path="#{project_b}")
    end

    test "palette_keydown ArrowDown/ArrowUp updates selected index", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      project_a = Path.join(tmp_dir, "aaa-project")
      project_b = Path.join(tmp_dir, "bbb-project")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)
      seed_recent_project(project_a, "aaa-project")
      seed_recent_project(project_b, "bbb-project")

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_project_palette", %{})

      # Initial: index 0 is selected (the first project)
      html = render(view)
      assert html =~ ~s(data-selected)

      # ArrowDown x4: 0→1→2→3 (clamped at 3, the max for 2 projects + 2 actions)
      render_click(view, "palette_keydown", %{"key" => "ArrowDown"})
      render_click(view, "palette_keydown", %{"key" => "ArrowDown"})
      render_click(view, "palette_keydown", %{"key" => "ArrowDown"})
      render_click(view, "palette_keydown", %{"key" => "ArrowDown"})

      # ArrowUp: back to index 2
      html = render_click(view, "palette_keydown", %{"key" => "ArrowUp"})
      assert html =~ ~s(data-selected)
    end

    test "palette_keydown Escape closes the palette", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_project_palette", %{})

      html = render_click(view, "palette_keydown", %{"key" => "Escape"})
      refute html =~ ~s(id="palette-search-input")
    end

    test "palette_keydown Enter activates selected project", %{conn: conn, tmp_dir: tmp_dir} do
      project = Path.join(tmp_dir, "enter-project")
      File.mkdir_p!(project)
      seed_recent_project(project, "enter-project")

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_project_palette", %{})

      # Enter on index 0 (the only recent project) selects it
      html = render_click(view, "palette_keydown", %{"key" => "Enter"})
      assert html =~ "enter-project"
    end
  end

  describe "path input suggestions" do
    setup do
      clear_recent_projects()
    end

    test "path_input lists matching recent projects before filesystem suggestions", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      recent_path = Path.join(tmp_dir, "alpha")
      fs_only_path = Path.join(tmp_dir, "alpha-extra")
      File.mkdir_p!(recent_path)
      File.mkdir_p!(fs_only_path)
      seed_recent_project(recent_path, "alpha")

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      html = render_change(view, "path_input", %{"path" => recent_path})

      datalist = path_suggestions_datalist(html)

      # (a) the recent project path (which is also a real directory) is
      # suggested, and so is the filesystem-only sibling
      assert datalist =~ ~s(<option value="#{recent_path}"></option>)
      assert datalist =~ ~s(<option value="#{fs_only_path}"></option>)

      # (c) exact ordering from the rendered HTML: the recent match comes first
      recent_idx = string_index(datalist, ~s(value="#{recent_path}"))
      fs_idx = string_index(datalist, ~s(value="#{fs_only_path}"))
      assert recent_idx != nil and fs_idx != nil
      assert recent_idx < fs_idx
    end

    test "path_input deduplicates paths present in both recents and filesystem", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      recent_path = Path.join(tmp_dir, "alpha")
      File.mkdir_p!(recent_path)
      seed_recent_project(recent_path, "alpha")

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      html = render_change(view, "path_input", %{"path" => recent_path})

      datalist = path_suggestions_datalist(html)

      # (b) the path exists in recents AND on disk (a filesystem suggestion),
      # but the datalist renders it exactly once
      assert datalist =~ ~s(<option value="#{recent_path}"></option>)
      assert length(String.split(datalist, ~s(value="#{recent_path}"))) == 2
    end
  end

  describe "select_project" do
    setup do
      clear_recent_projects()
    end

    test "activates the selected project", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "select_project", %{"path" => tmp_dir})

      # The palette trigger shows the selected project basename
      assert html =~ Path.basename(tmp_dir)
    end

    test "shows an error for a non-existent path", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "select_project", %{"path" => "/nonexistent/select/project"})

      assert html =~ "Directory does not exist"
    end
  end

  describe "create_project" do
    setup do
      clear_recent_projects()
    end

    test "creates and activates a new project", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "new_project"})

      full_path = Path.join(tmp_dir, "my-brand-new-project")

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.TaskRegistry.remove_recent_project(full_path)
        rescue
          _ -> :ok
        end
      end)

      html =
        view
        |> element("form[phx-submit='create_project']")
        |> render_submit(%{location: tmp_dir, name: "my-brand-new-project"})

      # Flash confirms creation
      assert html =~ "Project created"
      # The project bar shows the new project name
      assert html =~ "my-brand-new-project"
      # The new project is registered in the recent list
      assert Enum.any?(EvoGit.TaskRegistry.list_recent_projects(), &(&1.path == full_path))
    end
  end
end
