defmodule EvoDashWeb.SimpleLive.HomeTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # Isolate config like WelcomeLiveTest: XDG_CONFIG_HOME → empty temp dir so
  # no config.toml/credentials.toml leak in from the host.
  setup do
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_simple_home_test_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_config)
    original = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)
    # Windows: EvoGit.Config.config_dir/0 honours APPDATA instead of XDG.
    original_appdata = System.get_env("APPDATA")
    System.put_env("APPDATA", tmp_config)

    on_exit(fn ->
      if original do
        System.put_env("XDG_CONFIG_HOME", original)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      if original_appdata do
        System.put_env("APPDATA", original_appdata)
      else
        System.delete_env("APPDATA")
      end

      File.rm_rf!(tmp_config)
    end)

    :ok
  end

  defp complete_onboarding do
    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end
  end

  defp write_model_config do
    config_path = EvoGit.Config.config_path()
    File.mkdir_p!(Path.dirname(config_path))

    File.write!(config_path, """
    [[llm.models]]
    id = "profile-1"
    model = {provider = "anthropic", id = "claude-sonnet-5"}
    concurrency = 3
    """)

    on_exit(fn -> File.rm(config_path) end)
  end

  defp make_project_dir do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit_simple_home_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      try do
        EvoGit.TaskRegistry.remove_recent_project(tmp_dir)
      rescue
        _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    tmp_dir
  end

  describe "first-run redirect" do
    test "redirects to /welcome when onboarding is needed", %{conn: conn} do
      # Fresh XDG dir → no version-state file → onboarding needed
      assert {:error, {:live_redirect, %{to: "/welcome"}}} = live(conn, ~p"/")
    end
  end

  describe "home rendering" do
    setup do
      complete_onboarding()
      write_model_config()

      # Clear recent projects so the recent-chips state is deterministic
      for project <- EvoGit.TaskRegistry.list_recent_projects() do
        EvoGit.TaskRegistry.remove_recent_project(project.path)
      end

      :ok
    end

    test "renders brand, prompt input, mode tabs and pro corner", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Genesis"
      assert has_element?(view, "#simple-task-form")
      assert has_element?(view, "#simple-prompt")
      assert has_element?(view, "#pro-corner")
      # Two mode tabs, "develop new software" active by default
      assert has_element?(view, "#mode-tab-new[aria-selected='true']")
      assert has_element?(view, "#mode-tab-refactor[aria-selected='false']")
      # New mode: single path field, no second path field
      assert has_element?(view, "#simple-path-input")
      refute has_element?(view, "#simple-new-path-input")
      # Launch is disabled while the prompt is empty
      assert has_element?(view, "#simple-launch[disabled]")
    end

    test "refactor tab shows the two path fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "switch_mode", %{"mode" => "refactor"})

      assert html =~ "simple-new-path-input"
      assert has_element?(view, "#mode-tab-refactor[aria-selected='true']")

      # Switching back hides the second field again
      render_click(view, "switch_mode", %{"mode" => "new"})
      refute has_element?(view, "#simple-new-path-input")
    end

    test "launch with empty prompt shows an error", %{conn: conn} do
      tmp_dir = make_project_dir()

      {:ok, view, _html} = live(conn, ~p"/")

      html = render_submit(view, "launch", %{"prompt" => "   ", "path" => tmp_dir})
      assert html =~ "Please describe what you want to do."
    end

    test "launch without a path asks for the project", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_submit(view, "launch", %{"prompt" => "做一个计算器", "path" => ""})
      assert html =~ "Please select a project first."
    end

    test "launch with a nonexistent path shows directory not found", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        render_submit(view, "launch", %{
          "prompt" => "做一个计算器",
          "path" => "/nonexistent/xyz_#{System.unique_integer([:positive])}"
        })

      assert html =~ "Directory not found"
    end

    test "refactor mode never auto-creates the original path", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "switch_mode", %{"mode" => "refactor"})

      html =
        render_submit(view, "launch", %{
          "prompt" => "重构这个项目",
          "path" => "bare_name_should_not_be_created_#{System.unique_integer([:positive])}",
          "new_path" => ""
        })

      # Bare names are NOT auto-created in refactor mode for the original path
      assert html =~ "Directory not found"
    end

    test "launch with a bare name auto-creates the project and starts", %{conn: conn} do
      base =
        Path.join(System.tmp_dir!(), "evogit_simple_base_#{System.unique_integer([:positive])}")

      Application.put_env(:evo_dash, :simple_projects_base, base)
      on_exit(fn -> Application.delete_env(:evo_dash, :simple_projects_base) end)

      {:ok, view, _html} = live(conn, ~p"/")

      name = "proj_#{System.unique_integer([:positive])}"
      full_path = Path.join(base, name)

      on_exit(fn ->
        # Cancel the spawned task and clean up filesystem/registry state
        for task <- EvoGit.TaskRegistry.list_tasks_by_path(full_path) do
          try do
            EvoGit.TaskRegistry.cancel_task(task.id)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end

        try do
          EvoGit.TaskRegistry.remove_recent_project(full_path)
        rescue
          _ -> :ok
        end

        File.rm_rf(base)
      end)

      render_submit(view, "launch", %{"prompt" => "做一个计算器", "path" => name})

      # The folder was auto-created and the task was launched (navigates to /tree)
      assert File.dir?(full_path)
      assert EvoGit.TaskRegistry.list_tasks_by_path(full_path) != []
    end
  end
end
