# Dashboard LiveView test suite.
#
# NOTE: this file is intentionally long — it is the comprehensive test suite
# for the full dashboard UX, including the remote-node contexts (node-aware
# render gate, palette, per-node state persistence) from the `aa4605cc`
# workstream.
defmodule EvoDashWeb.DashboardLiveTest do
  use EvoDashWeb.ConnCase
  import Phoenix.LiveViewTest

  alias EvoGit.TaskInfo

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

  # Inserts a task directly into the shared SQLite store (bypassing the async
  # task spawn that `start_task/2` triggers) and registers on_exit cleanup so
  # the fixture never leaks into other tests in this file (the shared store
  # persists across tests). Returns the inserted %TaskInfo{}.
  defp insert_task_fixture!(overrides) do
    id = "fixture_#{System.unique_integer([:positive])}"

    task =
      %TaskInfo{
        id: id,
        type: :genesis,
        status: :completed,
        opts: Keyword.merge([path: "/tmp/test"], Keyword.get(overrides, :opts, [])),
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }
      |> Map.merge(Enum.into(overrides, %{}))

    EvoGit.Store.put_task(EvoGit.Store, task)

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.Store.delete_task(EvoGit.Store, id)
      rescue
        _ -> :ok
      end
    end)

    task
  end

  # Saves a unique remote connection target under the test's isolated
  # XDG_CONFIG_HOME (set_onboarding_completed isolates it per test) and
  # registers cleanup. Returns the target id. Each test uses a unique id so the
  # TOML file never has colliding entries across tests.
  defp save_target!(name \\ "Test Target") do
    id = "test-target-#{System.unique_integer([:positive])}"

    {:ok, _target} =
      EvoGit.RemoteConnections.save(%{ssh_target: "user@host", id: id, name: name})

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.RemoteConnections.delete(id)
      rescue
        _ -> :ok
      end
    end)

    id
  end

  # The Phoenix.LiveViewTest View struct exposes no assigns accessor in this
  # version, so read the LiveView socket assigns directly from the process
  # state (same pattern as welcome_live_test.exs / settings_live_test.exs).
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

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

      # Task form is always visible, but the launch panel is hidden
      # without an active project
      refute html =~ "hero-rocket-launch"
      # Empty-state hint overlay is shown when the launch panel is hidden
      assert html =~ "Open a project to get started"
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

    test "task form shows empty-state hint when no project is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # The launch panel (mode select + launch button + model select) is
      # hidden entirely without an active project
      refute html =~ "hero-rocket-launch"
      # The empty-state hint overlay is shown instead
      assert html =~ "Open a project to get started"
    end

    test "renders example task help block when no project is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # Explanation heading + how-it-works text
      assert html =~ "New to Genesis? Start with an example"
      assert html =~ "Set an end goal, launch, and Genesis builds it"
      # Example objective is rendered (from EvoDashWeb.ExampleTask)
      assert html =~ "Build a simulated, web-based Windows desktop environment"
      # Prefill + copy actions are present
      assert html =~ "Use this example"
      assert html =~ "example-task-copy"
      # Hidden RCDATA holder for the prefill JS is present
      assert html =~ "example-task-objective"
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
      assert html =~ "hero-rocket-launch"
      # Project settings should show config info
      assert html =~ "Foreign Repositories"
      # Example-task help block hides once a project is open
      refute html =~ "example-task-objective"
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
      assert html =~ "hero-rocket-launch"
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

  describe "task notifications" do
    setup do
      clear_recent_projects()
      :ok
    end

    test "no notification for a task already terminal before mount", %{conn: conn} do
      insert_task_fixture!(status: :completed)

      {:ok, view, _html} = live(conn, ~p"/")

      # The mount seed pre-notifies terminal ids, so a reload must not push a
      # browser notification for them.
      send(view.pid, :node_aware_reload_tasks)
      html = render(view)

      refute_push_event(view, "task_notification", %{})
      # No active project in this describe (recent projects cleared, fixture
      # inserted directly into the store), so the launch panel is hidden
      refute html =~ "hero-rocket-launch"
    end

    test "notification fires only for newly-terminal ids with matching content", %{conn: conn} do
      # Terminal before mount -> part of the mount seed -> never notified
      insert_task_fixture!(status: :completed, opts: [prompt: "old task"])

      {:ok, view, _html} = live(conn, ~p"/")

      # Becomes terminal after mount -> newly-terminal -> notification pushed
      new_task =
        insert_task_fixture!(
          status: :completed,
          opts: [prompt: "notify me"],
          result: {:ok, %{pr_title: "PR title"}}
        )

      send(view.pid, :node_aware_reload_tasks)
      render(view)

      {title, body} = EvoDashWeb.DashboardLive.Project.task_notification_content(new_task)
      assert_push_event(view, "task_notification", %{title: ^title, body: ^body})
    end

    test "user-initiated delete_task does not notify", %{conn: conn} do
      task = insert_task_fixture!(status: :running)

      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "delete_task", %{"task_id" => task.id})

      # delete_task is a cast — give the registry time to process the store
      # deletion before the reload snapshot.
      Process.sleep(50)

      send(view.pid, :node_aware_reload_tasks)
      render(view)

      refute_push_event(view, "task_notification", %{})
    end

    test "user-initiated clear_task_history does not notify", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Terminal AFTER mount — would be newly-terminal on reload if the user
      # had not cleared the history.
      insert_task_fixture!(status: :completed, opts: [prompt: "cleared task"])

      render_hook(view, "clear_task_history", %{})

      send(view.pid, :node_aware_reload_tasks)
      render(view)

      refute_push_event(view, "task_notification", %{})
    end
  end

  describe "remote node contexts" do
    setup do
      clear_recent_projects()
      :ok
    end

    test "node switch clears local form state before rendering the remote gate", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.DashboardLiveTest.ConnectionManager, {id, %{phase: :connecting, node: nil}}}
      )

      {:ok, view, _html} = live(conn, ~p"/")

      # Open a local project and fill in form state
      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      render_change(view, "task_prompt_change", %{"prompt" => "some objective"})
      render_click(view, "toggle_advanced", %{})

      assert assigns(view)[:task_prompt] == "some objective"
      assert assigns(view)[:show_advanced] == true
      assert assigns(view)[:active_project] != nil

      # Switch to the remote node context: handle_params re-runs and clears all
      # persisted/project state (each node context owns its own session state).
      html = render_patch(view, "/?node=" <> id)

      assert assigns(view)[:current_node_id] == id
      assert assigns(view)[:task_prompt] == ""
      assert assigns(view)[:show_advanced] == false
      assert assigns(view)[:active_project] == nil
      assert assigns(view)[:active_project_path] == nil
      assert assigns(view)[:recent_projects] == []

      # The connecting gate renders — no local form/project data leaks through
      assert html =~ ~s(data-node-id="#{id}")
      assert html =~ ~s(class="loading loading-spinner loading-lg text-info")
      assert html =~ "Connecting to Test Target"
      refute html =~ ~s(id="prompt")
      refute html =~ "hero-rocket-launch"
      refute html =~ "Recent Projects"
    end

    test "connected remote view renders remote chrome and no local task form", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.DashboardLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/?node=" <> id)

      # NOTE: the committed handle_params derives `remote?` from the socket
      # BEFORE `assign_node` re-assigns `current_node`, so the very first
      # render after mounting at a connected `?node=` URL still falls through
      # to the error gate. The connected branch is reached on the NEXT
      # handle_params run — in production that re-run is the NodeAware
      # push_patch triggered when a connection completes/broadcasts; here we
      # simulate it with a patch to the same URL.
      html = render_patch(view, "/?node=" <> id)

      assert assigns(view)[:current_node_id] == id
      assert assigns(view)[:current_node] == :"genesis_remote@127.0.0.1"
      assert assigns(view)[:remote?] == true
      # erpc to the fake BEAM node fails fast — no agents/recents, no hang risk
      assert assigns(view)[:remote_agents] == []
      assert assigns(view)[:recent_projects] == []

      # Remote top bar: data-remote present (boolean attrs serialize as a bare
      # attribute via the test DOM) + target-name badge; the Configure dropdown
      # and its toggle button are local-only
      assert html =~ ~s(class="dashboard-topbar)
      assert html =~ "data-remote"
      assert html =~ "Test Target"
      refute html =~ ~s(phx-click="toggle_configure_dropdown")

      # Connected-remote info banner; the error gate is gone
      assert html =~ "Remote Node"
      assert html =~ "Active Agents"
      refute html =~ "Cannot connect"

      # data-node-id on the root element
      assert html =~ ~s(data-node-id="#{id}")

      # No local task form, launch button, or example-task block
      refute html =~ ~s(id="prompt")
      refute html =~ "hero-rocket-launch"
      refute html =~ "example-task-objective"

      # Remote palette: Open by Path yes, Create New Project hidden
      html = render_click(view, "open_project_palette", %{})
      assert html =~ "Open Project by Path"
      refute html =~ "Create New Project"
    end

    test "error-phase remote context renders the error gate with actions", %{conn: conn} do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.DashboardLiveTest.ConnectionManager,
         {id, %{phase: :error, last_error: "boom", node: nil}}}
      )

      {:ok, view, html} = live(conn, "/?node=" <> id)

      assert html =~ "Cannot connect to Test Target"
      assert html =~ "boom"
      assert html =~ ~s(phx-click="retry_remote_connection")
      # Manage Connections href carries NO ?node= param (connection management
      # is a local dashboard concern)
      assert html =~ ~s(href="/settings?category=remote_connections")
      refute html =~ ~s(href="/settings?category=remote_connections?node=)
      assert html =~ ~s(phx-click="switch_to_local")

      # No local project data / task form leaks into the error state
      refute html =~ ~s(id="prompt")
      refute html =~ "hero-rocket-launch"
      refute html =~ "Recent Projects"

      # Retry calls the (fake) connection manager and deliberately ignores the
      # result — no crash, error state stays rendered
      html = render_click(view, "retry_remote_connection", %{})
      assert html =~ "boom"
      assert html =~ ~s(phx-click="retry_remote_connection")
    end

    test "saved target with no connection manager shows the generic error", %{conn: conn} do
      id = save_target!()

      {:ok, view, html} = live(conn, "/?node=" <> id)

      # No fake manager registered → status degrades to the disconnected default
      assert assigns(view)[:current_node_id] == id
      assert %{phase: :disconnected} = assigns(view)[:remote_status]

      assert html =~ "Connection lost or failed"
      assert html =~ ~s(phx-click="switch_to_local")
      refute html =~ ~s(id="prompt")
      refute html =~ "hero-rocket-launch"
    end

    test "switch to local patches back to the local UI without the ?node= param", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.DashboardLiveTest.ConnectionManager,
         {id, %{phase: :error, last_error: "boom", node: nil}}}
      )

      {:ok, view, _html} = live(conn, "/?node=" <> id)

      render_click(view, "switch_to_local", %{})

      # handle_node_selected push_patches to the current path WITHOUT ?node=
      assert_patch(view, "/")

      html = render(view)

      assert assigns(view)[:current_node_id] == nil
      # Local UI is back: the task form renders again
      assert html =~ ~s(id="prompt")
      assert html =~ "Open a project to get started"
    end

    test "connecting-phase remote context renders the spinner with the target name", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.DashboardLiveTest.ConnectionManager, {id, %{phase: :connecting, node: nil}}}
      )

      {:ok, view, html} = live(conn, "/?node=" <> id)

      assert assigns(view)[:current_node_id] == id
      assert %{phase: :connecting} = assigns(view)[:remote_status]

      assert html =~ ~s(class="loading loading-spinner loading-lg text-info")
      assert html =~ "Connecting to Test Target"
      assert html =~ ~s(data-node-id="#{id}")

      # No local data / task form during the pending gate
      refute html =~ ~s(id="prompt")
      refute html =~ "hero-rocket-launch"
      refute html =~ "Recent Projects"
    end

    test "remote open_project validates the path on the remote node", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.DashboardLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/?node=" <> id)

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      # NOTE: the remote success path (dir? RPC → true → push_patch carrying
      # `&node=`) is UNREACHABLE in tests — there is no real remote daemon to
      # answer the dir? RPC, and the fake BEAM node fails it fast. Remote URL
      # behavior is therefore covered by this error path (proves the node-aware
      # validation branch ran) plus the switch_to_local inverse (patches
      # WITHOUT `?node=`) in the test above.
      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: tmp_dir})

      assert html =~ "Directory does not exist on the remote node: #{tmp_dir}"

      # The failed remote validation must NOT register the path in the LOCAL
      # recent-project list (proves the remote branch ran, not the local one)
      refute Enum.any?(EvoGit.TaskRegistry.list_recent_projects(), &(&1.path == tmp_dir))
    end

    test "foreign repo path input carries autocomplete wiring and a datalist", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open a real local project, then expand settings + the add-repo form
      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      render_click(view, "toggle_project_settings", %{"project" => tmp_dir})
      render_click(view, "toggle_add_foreign_repo_form", %{})
      html = render(view)

      assert html =~ ~s(id="foreign-repo-path-input")
      assert html =~ ~s(phx-hook="PathAutocomplete")
      assert html =~ ~s(list="foreign-repo-path-suggestions")
      assert html =~ ~s(phx-change="foreign_repo_path_input")
      assert html =~ ~s(phx-debounce="150")
      assert html =~ ~s(<datalist id="foreign-repo-path-suggestions">)
    end

    test "restore_state from a different node context is ignored", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "restore_state", %{
        "node" => "some-remote",
        "task_prompt" => "leak",
        "task_resume_from" => "abc",
        "project" => tmp_dir
      })

      # Gate: saved node ("some-remote") != current node ("local") → nothing restored
      assert assigns(view)[:task_prompt] == ""
      assert assigns(view)[:task_resume_from] == ""
      assert assigns(view)[:active_project] == nil
    end

    test "restore_state tagged with the local node restores persisted values", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "restore_state", %{
        "node" => "local",
        "task_prompt" => "my objective",
        "task_resume_from" => "task-123",
        "project" => tmp_dir
      })

      assert assigns(view)[:task_prompt] == "my objective"
      assert assigns(view)[:task_resume_from] == "task-123"
      assert assigns(view)[:active_project] != nil
    end

    test "restore_state tagged local never leaks into a remote pending context", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.DashboardLiveTest.ConnectionManager, {id, %{phase: :connecting, node: nil}}}
      )

      {:ok, view, _html} = live(conn, "/?node=" <> id)

      render_hook(view, "restore_state", %{
        "node" => "local",
        "task_prompt" => "leak",
        "task_resume_from" => "abc",
        "project" => "/nonexistent"
      })

      # Gate: saved node ("local") != current node (remote id) → nothing restored
      assert assigns(view)[:task_prompt] == ""
      assert assigns(view)[:task_resume_from] == ""
      assert assigns(view)[:active_project] == nil
    end

    test "local render carries data-node-id=local on the dashboard root", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-node-id="local")
    end
  end
end

# A minimal GenServer standing in for a real remote connection manager in
# `EvoGit.RemoteConnection.Registry` (same pattern as
# EvoDashWeb.NodeAwareTest.ConnectionManager). `connect/1` on the real manager
# resolves the registered pid via the Registry and calls `:connect`; the fake
# answers with an error so `retry_remote_connection` never starts real SSH
# machinery. The process dies (and its Registry entry is auto-removed) at test
# end via `start_supervised!`.
defmodule EvoDashWeb.DashboardLiveTest.ConnectionManager do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init({target_id, status}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)
    {:ok, status}
  end

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}

  @impl true
  def handle_call(:connect, _from, status), do: {:reply, {:error, :fake_connect}, status}
end
