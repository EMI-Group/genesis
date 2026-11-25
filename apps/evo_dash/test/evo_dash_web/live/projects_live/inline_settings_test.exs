defmodule EvoDashWeb.ProjectsLive.InlineSettingsTest do
  # Select through the URL, not through a mount action: no shared VCT mutations,
  # app-env runner overrides, or task launches.
  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @async_wait_budget_ms 30_000
  @options "#workbench-task-composer section[aria-labelledby=task-options-title]"
  @settings "details#workbench-task-settings"
  @add_form "#{@settings} form[phx-submit=add_foreign_repo]"
  @edit_form "#{@settings} form[phx-submit=save_foreign_repo]"

  setup %{conn: conn} do
    root = EvoDash.Test.ConfigDir.isolate!("evodash-inline-settings")
    EvoGit.Config.VersionState.complete_onboarding()

    project = Path.join(root, "project with spaces")
    File.mkdir!(project)

    %{conn: Plug.Test.init_test_session(conn, %{}), project: project, root: root}
  end

  test "New task opens inline options with mode-specific controls bound to the task form", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: project}}")

    refute has_element?(view, "#task-options-title")
    refute has_element?(view, @settings)

    view |> element("#overview-new-task", "New task") |> render_click()

    assert %{path: "/projects", query: query} =
             view |> assert_patch(@async_wait_budget_ms) |> URI.parse()

    assert URI.decode_query(query) == %{"project" => project, "wb_task" => "1"}

    assert has_element?(view, "#workbench-task-composer form#task-form[phx-submit=task_submit]")
    assert has_element?(view, "#{@options} h2#task-options-title", "Task Options")

    assert has_element?(
             view,
             "#{@options} select[name=build_system][form=task-form]",
             "No build system"
           )

    assert has_element?(view, "#{@options} input[type=checkbox][name=archive][form=task-form]")

    assert has_element?(
             view,
             "#{@settings}:not([open]) > summary#workbench-task-settings-title",
             "Project Settings"
           )

    refute has_element?(view, "dialog#workbench-task-settings")
    refute has_element?(view, "#{@settings} [form=task-form]")
    refute has_element?(view, "#{@options} [name=node_path]")

    toggle = "#{@options} #persist-agent-state-toggle"
    assert has_element?(view, "#{toggle}[checked]")

    view |> element(toggle) |> render_click()

    assert has_element?(view, "#{toggle}:not([checked])")

    assert_push_event(
      view,
      "persist_state",
      %{project: ^project, persist_agent_state?: false},
      @async_wait_budget_ms
    )

    view |> element("#task-form #mode-option-evolve_simple") |> render_click()

    assert has_element?(view, "#task-form input[type=hidden][name=mode][value=evolve_simple]")
    assert has_element?(view, "#{@options} #task-advanced-options > summary", "Advanced options")

    for name <- ~w(node_path starting_commit resume_from) do
      assert has_element?(
               view,
               "#{@options} #task-advanced-options input[name=#{name}][form=task-form]"
             )
    end

    refute has_element?(view, "#{@options} select[name=build_system]")
    assert has_element?(view, "#{@options} input[name=archive][form=task-form]")
    assert has_element?(view, "#{toggle}:not([checked])")
    assert has_element?(view, "#{@settings} > summary", "Project Settings")
  end

  test "inline Project Settings renders project metadata and owns the foreign repo forms", %{
    conn: conn,
    project: project,
    root: root
  } do
    File.write!(Path.join(project, "genesis.toml"), """
    [worktree]
    script = "scripts/setup-worktree.sh"
    """)

    {repo, head} = make_git_repo!(root)
    {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: project, wb_task: "1"}}")

    assert has_element?(view, "#{@settings} > summary", "Project Settings")
    assert has_element?(view, "#{@settings} p", "genesis.toml found — using project settings")
    assert has_element?(view, "#{@settings} p", project)
    assert has_element?(view, "#{@settings} p", "scripts/setup-worktree.sh")
    assert has_element?(view, "#{@settings} p", "No foreign repositories registered")

    # The summary opens natively in the browser; LiveViewTest doesn't run that
    # interaction. Exercise the actual LiveView controls inside the disclosure.
    view |> element("#{@settings} button", "Add Foreign Repo") |> render_click()

    refute has_element?(view, "#task-form form")
    assert has_element?(view, @add_form)

    fields = %{
      "repo_id" => "upstream",
      "path" => repo,
      "description" => "Reference repository",
      "writable" => "true"
    }

    html =
      view
      |> form(@add_form, Map.put(fields, "base_sha", "nonexistent-base"))
      |> render_submit()

    assert html =~ "Base commit nonexistent-base not found in repository: #{repo}"
    assert has_element?(view, @add_form)
    assert has_element?(view, "#{@settings} p", "No foreign repositories registered")

    view |> form(@add_form, Map.put(fields, "base_sha", head)) |> render_submit()

    refute has_element?(view, @add_form)
    assert has_element?(view, "#{@settings} span", "Reference repository")
    assert has_element?(view, "#{@settings} span", "Writable")
    assert has_element?(view, "#{@settings} code[title='#{head}']", head)

    assert_push_event(
      view,
      "persist_state",
      %{
        project: ^project,
        foreign_repos: [
          %{
            "id" => "upstream",
            "path" => ^repo,
            "description" => "Reference repository",
            "writable" => true,
            "base_sha" => ^head
          }
        ]
      },
      @async_wait_budget_ms
    )

    view
    |> element("#{@settings} button[phx-click=edit_foreign_repo][phx-value-repo_id=upstream]")
    |> render_click()

    assert has_element?(view, "#{@edit_form} input[name=repo_id][value=upstream][readonly]")
    assert has_element?(view, "#{@edit_form} input[name=writable][checked]")
    assert has_element?(view, "#{@edit_form} input[name=base_sha][value='#{head}']")

    view
    |> form(@edit_form, %{"description" => "Updated reference", "base_sha" => "HEAD"})
    |> render_submit()

    refute has_element?(view, @edit_form)
    assert has_element?(view, "#{@settings} span", "Updated reference")
    assert has_element?(view, "#{@settings} code[title=HEAD]", "HEAD")

    view
    |> element("#{@settings} button[phx-click=remove_foreign_repo][phx-value-repo_id=upstream]")
    |> render_click()

    assert has_element?(view, "#{@settings} p", "No foreign repositories registered")
    assert has_element?(view, "#{@settings} button", "Add Foreign Repo")
  end

  defp make_git_repo!(root) do
    repo = Path.join(root, "reference repository")
    File.mkdir!(repo)
    git!(repo, ["init", "--template="])

    git!(repo, [
      "-c",
      "user.name=Inline Settings Test",
      "-c",
      "user.email=inline-settings@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.hooksPath=.git/hooks",
      "commit",
      "--allow-empty",
      "-m",
      "Initial commit"
    ])

    {repo, git!(repo, ["rev-parse", "HEAD"]) |> String.trim()}
  end

  defp git!(repo, args) do
    assert {output, 0} =
             System.cmd(EvoGit.Executable.resolve("git"), args, cd: repo, stderr_to_stdout: true)

    output
  end
end
