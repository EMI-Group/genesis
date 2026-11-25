defmodule EvoDashWeb.ProjectsWorkbenchGitTest do
  # Source Control requires a real VCT mount, which the async ProjectsLive
  # suite can clear from the shared registry while these reads are in flight.
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EvoGit.Adapters.Git
  alias EvoGit.VCT

  @async_wait_budget_ms 30_000

  @tag :tmp_dir
  test "the project overview shows real Git history and routes the working-tree diff to the shell",
       %{
         conn: conn,
         tmp_dir: project
       } do
    EvoDash.Test.ConfigDir.isolate!("workbench_git_config")
    EvoGit.Config.VersionState.complete_onboarding()
    conn = Plug.Test.init_test_session(conn, %{})

    on_exit(fn -> EvoDash.Test.FsCleanup.rm_rf!(project) end)
    assert {:ok, _} = Git.run(~w(init --template= -b main), project)
    notes = Path.join(project, "notes.txt")
    File.write!(notes, "committed source note\n")
    assert {:ok, _} = Git.add(project, "notes.txt")
    subject = "Record the first source note"

    assert {:ok, _} =
             Git.run(
               ["-c", "core.hooksPath=.git/hooks", "commit", "--no-gpg-sign", "-m", subject],
               project
             )

    assert {:ok, sha} = Git.run(~w(rev-parse HEAD), project)
    File.write!(notes, "edited source note\n")

    assert {:ok, mount} = VCT.mount(project)
    on_exit(fn -> assert :ok = VCT.forget(mount.point) end)

    {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: project}}")
    assert has_element?(view, "#workbench-project-overview[data-overview-kind=project]")
    refute has_element?(view, "#task-form")
    refute has_element?(view, "#workbench-git-diff-portal")

    # The open toggle is client-only; the rendered Refresh button requests
    # the same server-side snapshot without simulating the JS panel state.
    view |> element("#workbench-git-refresh") |> render_click()
    render_async(view, @async_wait_budget_ms)

    file = "#workbench-git-changes button[data-workbench-git-file][title='notes.txt']"
    assert has_element?(view, file)

    switcher = "#workbench-git .workbench-git-views"
    view |> element("#{switcher} button", "Commits") |> render_click()
    render_async(view, @async_wait_budget_ms)

    assert has_element?(view, "#{switcher} button[aria-pressed=true]", "Commits")
    assert has_element?(view, "#workbench-git-history button[phx-value-sha='#{sha}']", subject)

    view |> element("#{switcher} button", "Changes") |> render_click()
    view |> element(file) |> render_click()

    tree = view |> render_async(@async_wait_budget_ms) |> Floki.parse_document!()
    assert has_element?(view, "#{file}[aria-pressed=true]")

    # LiveViewTest renders the template, not the browser-side portal move.
    # Pin both ends: a single target alongside the main view, and the diff
    # template emitted from the Source Control component that owns the action.
    assert [_] = Floki.find(tree, "#workbench-git-diff-host")

    assert [_] = Floki.find(tree, ".workbench-content-stack > #workbench-git-diff-host")

    assert [portal] =
             Floki.find(
               tree,
               "#workbench-git-content template#workbench-git-diff-portal[data-phx-portal='#workbench-git-diff-host']"
             )

    assert [diff] = Floki.find(portal, "#workbench-git-diff")
    assert [deletion] = Floki.find(diff, "code[data-diff-type=deletion]")
    assert [addition] = Floki.find(diff, "code[data-diff-type=addition]")
    assert Floki.text(deletion) == "-committed source note"
    assert Floki.text(addition) == "+edited source note"
  end
end
