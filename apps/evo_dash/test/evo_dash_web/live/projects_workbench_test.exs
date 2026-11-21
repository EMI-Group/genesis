# Focused suite for the two RIGHT workbench panels: their default-CLOSED
# server-rendered state, the ONE filters form in front of the history panel, and
# the REAL server-side history read behind it (project / search / status /
# kind).
#
# `async: true` — this module never writes a BEAM-global that a concurrent
# module reads:
#
#   * the page is driven purely from the URL. `?project=<abs path>` makes
#     `ProjectsLive.handle_params/3` call `activate_project/2`, which sets
#     `active_project_path` and derives the display-only VCT identity from the
#     ALREADY loaded project list (a pure in-memory lookup), and `Layouts.app`
#     renders `workbench_project` / `workbench_git_project` from that path. No
#     `EvoGit.VCT.mount/2` is called — the panel's project-filter options come
#     from `NodeContext.projects/1` plus `ensure_project_option/2`'s
#     `Path.basename/1` fallback, so nothing here depends on (or mutates) the
#     process-global `EvoGit.VCT` mount table that the async
#     `EvoDashWeb.ProjectsLiveTest` reads for its "no active project" /
#     "no project rows" assertions.
#   * the only global this suite touches is the run-wide task store, seeded with
#     PER-TEST-UNIQUE ids/project paths and cleaned up through a direct
#     `EvoGit.Store.delete_task/2` (never a `TaskRegistry` cast, whose `"tasks"`
#     broadcast would arm every mounted page's reload debounce).
#   * the sidebar hub is cleared per test for the LOCAL `{nil, node()}` context
#     only — `EvoDashWeb.ConnCase` already does that in `setup`/`on_exit`, so it
#     is not repeated here.
#
# The suite defines its OWN fixtures instead of importing
# `EvoDashWeb.ProjectsLiveTest.Helpers`: a helper module defined in another
# `.exs` only exists once that file loads, and this file must run alone with
# `mix test apps/evo_dash/test/evo_dash_web/live/projects_workbench_test.exs`.
defmodule EvoDashWeb.ProjectsWorkbenchTest do
  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EvoGit.TaskInfo

  # Bounded-poll cadence + load-tolerant deadline for every wait on the panel's
  # asynchronous server-side read (the same figures the other live-page suites
  # use: scheduling on this shared host swings 10-30x, so the deadline is wide
  # while the cadence stays 2 ms — a fixed `Process.sleep` is never a mechanism).
  @wait_poll_ms 2
  @async_wait_budget_ms 30_000

  setup [:setup_temp_dir, :set_onboarding_completed]

  describe "right workbench panels" do
    test "both panels render closed with collapsed toggles and hidden chrome", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, html} = live(conn, ~p"/projects?#{%{project: tmp_dir, wb_home: "1"}}")

      # The open/close animation is JS+CSS only, so the SERVER-rendered initial
      # markup IS the closed state — that is the correct thing to pin here.
      assert html =~ ~s(data-panel-state="closed")

      assert has_element?(view, "aside.workbench-history#workbench-history[hidden]")
      assert has_element?(view, "aside.workbench-history#workbench-git[hidden]")
      assert has_element?(view, "#workbench-history[hidden][data-panel-state=closed]")
      assert has_element?(view, "#workbench-git[hidden][data-panel-state=closed]")

      assert has_element?(view, "#workbench-history-toggle[aria-expanded=false]")
      assert has_element?(view, "#workbench-git-toggle[aria-expanded=false]")

      # The overlay scrim and the drag resizer belong to the OPEN panel.
      assert has_element?(view, "#workbench-history-overlay[hidden]")
      assert has_element?(view, "#workbench-right-resize[hidden]")
    end
  end

  describe "history filters" do
    test "one server-side form carries the project default and the status inventory", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {view, _html} = mount_project_page!(conn, tmp_dir)

      assert has_element?(
               view,
               "#workbench-history-filters[phx-change=history_filters][phx-submit=history_filters]"
             )

      # The search box is a REAL server-rendered input, always visible: the old
      # collapsed toggle (`#workbench-history-search-toggle`) and the hidden
      # query wrapper no longer exist.
      assert has_element?(view, "#workbench-history-search[name=query][phx-debounce='300']")
      refute has_element?(view, "#workbench-history-search[hidden]")
      refute has_element?(view, "#workbench-history-query[hidden]")
      refute has_element?(view, "#workbench-history-search-toggle")

      # The project filter offers "All projects" first and DEFAULTS to the
      # project being viewed.
      project_select = view |> element("#workbench-history-project-filter") |> render()
      [first_option | _] = select_options(project_select)
      assert Floki.attribute([first_option], "value") == [""]
      assert Floki.text(first_option) == "All projects"
      assert selected_option_values(project_select) == [tmp_dir]

      # The status filter offers "Any status" first, then the full inventory.
      status_select = view |> element("#workbench-history-status-filter") |> render()

      assert status_select |> select_options() |> Floki.attribute("value") ==
               [
                 ""
                 | ~w(pending running finalizing awaiting_input cancelling pausing paused completed failed cancelled)
               ]

      # No status is preselected beyond the leading `""` option, which the
      # browser selects by default (`history_status` starts empty).
      assert selected_option_values(status_select) == []

      # The kind switch renders its SERVER-side pressed state (no client hand-off).
      assert has_element?(view, "[data-workbench-kind='task'][aria-pressed=true]")
      assert has_element?(view, "[data-workbench-kind='chat'][aria-pressed=false]")

      # The scope label is server-rendered text. No mount was registered, so the
      # label is the panel's own basename fallback for the selected path.
      assert has_element?(view, "#workbench-history-project", Path.basename(tmp_dir))

      # Retained sidebar hook: the recent-projects section reports its load state.
      wait_for(view, fn ->
        has_element?(view, "#workbench-projects[data-workbench-projects-loading=false]")
      end)
    end

    test "selecting All projects widens the scope server-side", %{conn: conn, tmp_dir: tmp_dir} do
      other_dir = make_project_dir!("evogit_workbench_other")

      current_id =
        seed_task!(path: tmp_dir, objective: unique_phrase("current"), status: :completed)

      other_id =
        seed_task!(path: other_dir, objective: unique_phrase("other"), status: :completed)

      {view, _html} = mount_project_page!(conn, tmp_dir)

      # Default scope = the project being viewed.
      wait_for(view, fn -> has_element?(view, row_selector(current_id)) end)
      refute has_element?(view, row_selector(other_id))
      assert has_element?(view, "#workbench-history-project", Path.basename(tmp_dir))

      view
      |> element("#workbench-history-filters")
      |> render_change(%{"project" => ""})

      wait_for(view, fn ->
        has_element?(view, row_selector(current_id)) and
          has_element?(view, row_selector(other_id))
      end)

      assert has_element?(view, "#workbench-history-project", "All projects")
    end

    test "the search box filters server-side", %{conn: conn, tmp_dir: tmp_dir} do
      prefix = unique_phrase("search")
      alpha_id = seed_task!(path: tmp_dir, objective: "#{prefix} alpha", status: :completed)
      beta_id = seed_task!(path: tmp_dir, objective: "#{prefix} beta", status: :completed)

      {view, _html} = mount_project_page!(conn, tmp_dir)

      wait_for(view, fn ->
        has_element?(view, row_selector(alpha_id)) and has_element?(view, row_selector(beta_id))
      end)

      view
      |> element("#workbench-history-filters")
      |> render_change(%{"query" => "#{prefix} alpha"})

      wait_for(view, fn ->
        has_element?(view, row_selector(alpha_id)) and
          not has_element?(view, row_selector(beta_id))
      end)

      # Clearing the query brings the widened set back.
      view
      |> element("#workbench-history-filters")
      |> render_change(%{"query" => ""})

      wait_for(view, fn ->
        has_element?(view, row_selector(alpha_id)) and has_element?(view, row_selector(beta_id))
      end)
    end

    test "the status filter narrows server-side", %{conn: conn, tmp_dir: tmp_dir} do
      completed_id =
        seed_task!(path: tmp_dir, objective: unique_phrase("done"), status: :completed)

      failed_id = seed_task!(path: tmp_dir, objective: unique_phrase("broke"), status: :failed)

      {view, _html} = mount_project_page!(conn, tmp_dir)

      wait_for(view, fn ->
        has_element?(view, row_selector(completed_id)) and
          has_element?(view, row_selector(failed_id))
      end)

      view
      |> element("#workbench-history-filters")
      |> render_change(%{"status" => "failed"})

      wait_for(view, fn ->
        has_element?(view, row_selector(failed_id)) and
          not has_element?(view, row_selector(completed_id))
      end)
    end

    test "the kind switch shows conversations and the empty flag", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      task_id = seed_task!(path: tmp_dir, objective: unique_phrase("kind"), status: :completed)

      {view, _html} = mount_project_page!(conn, tmp_dir)

      wait_for(view, fn -> has_element?(view, row_selector(task_id)) end)

      view
      |> element("[data-workbench-kind='chat']")
      |> render_click()

      # The pressed state flips SERVER-side and the task rows leave the list.
      wait_for(view, fn ->
        has_element?(view, "[data-workbench-kind='chat'][aria-pressed=true]") and
          has_element?(view, "[data-workbench-kind='task'][aria-pressed=false]") and
          not has_element?(view, row_selector(task_id))
      end)

      # No conversation session is created here on purpose: `EvoDash.ChatHistory`
      # is a process-wide cache that the async `home_live` / ChatHistory suites
      # read exactly, so this module never writes it. Instead of assuming the
      # cache is empty, a no-match query makes the empty verdict deterministic
      # (chat rows are filtered by the SAME server-side query).
      view
      |> element("#workbench-history-filters")
      |> render_change(%{"query" => unique_phrase("no-chat")})

      wait_for(view, fn ->
        has_element?(view, "#workbench-history-content[data-workbench-history-empty=true]") and
          not has_element?(view, "[data-workbench-item]")
      end)
    end
  end

  describe "history rows" do
    test "a task row carries the documented item hooks", %{conn: conn, tmp_dir: tmp_dir} do
      objective = unique_phrase("row")
      id = seed_task!(path: tmp_dir, objective: objective, status: :completed)

      {view, _html} = mount_project_page!(conn, tmp_dir)
      wait_for(view, fn -> has_element?(view, row_selector(id)) end)

      assert has_element?(view, "[data-workbench-item='task'][data-item-id='#{id}']")

      assert has_element?(
               view,
               "[data-item-id='#{id}'][data-item-title='#{objective}'][data-item-href='/tasks?task=#{id}']"
             )

      assert has_element?(view, "[data-item-id='#{id}'][data-item-state='Completed']")
      assert has_element?(view, "[data-item-id='#{id}'] [data-workbench-open]")

      # A COMPLETED row is not "active" — the attribute is only rendered for the
      # in-flight states, so its absence is the contract here.
      refute has_element?(view, "[data-item-id='#{id}'][data-item-active]")

      # "Load more tasks" only exists past the first 50-row page.
      refute has_element?(view, "[data-workbench-more]")
    end
  end

  # -- fixtures -------------------------------------------------------------

  defp mount_project_page!(conn, project_path) do
    {:ok, view, html} = live(conn, ~p"/projects?#{%{project: project_path, wb_home: "1"}}")

    # The panel's first read runs through `start_async` inside the live
    # component, which the root view's async queue covers.
    render_async(view, @async_wait_budget_ms)

    {view, html}
  end

  defp setup_temp_dir(_context) do
    {:ok, tmp_dir: make_project_dir!("evogit_workbench_test")}
  end

  defp make_project_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    # Deadline-bounded removal: a page load may still be reading the tree.
    on_exit(fn -> EvoDash.Test.FsCleanup.rm_rf!(dir) end)

    dir
  end

  # The ProjectsLive mount redirects first-time users to /welcome, so isolate
  # the config dir per test (the `:config_dir_fun` seam, inherited by the
  # mounted view and its supervised load tasks through `$callers`) and mark
  # onboarding complete in it.
  defp set_onboarding_completed(%{conn: conn}) do
    # `isolate!/1` registers the directory's ONLY cleanup (drain-backed, then
    # deadline-bounded removal); a second raw `File.rm_rf!/1` would run FIRST
    # (LIFO) with no drain and race a supervised page-load writer.
    EvoDash.Test.ConfigDir.isolate!("evogit_workbench_test_config")

    EvoGit.Config.VersionState.complete_onboarding()

    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  defp unique_phrase(kind) do
    "wb#{kind}#{System.unique_integer([:positive])}"
  end

  # Inserts ONE task directly into the run-wide store (no async task spawn) and
  # registers a DIRECT-store delete on exit: a `TaskRegistry` cast would
  # broadcast on "tasks" and arm every mounted page's reload debounce.
  defp seed_task!(opts) do
    id = "fixture_wb_#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    task = %TaskInfo{
      id: id,
      type: :genesis,
      status: Keyword.fetch!(opts, :status),
      opts: [path: Keyword.fetch!(opts, :path), objective: Keyword.fetch!(opts, :objective)],
      ref: nil,
      started_at: now,
      finished_at: now,
      logs: [],
      result: nil
    }

    EvoGit.Store.put_task(EvoGit.Store, task)

    on_exit(fn ->
      # Teardown-only rescue: a cleanup failure must never mask a test failure.
      try do
        EvoGit.Store.delete_task(EvoGit.Store, id)
      rescue
        _ -> :ok
      end
    end)

    id
  end

  # -- waits ----------------------------------------------------------------

  defp row_selector(id), do: "[data-workbench-item][data-item-id='#{id}']"

  # Floki's document parser drops `<option>` children of a fragment-level
  # `<select>`, so the rendered select is parsed as a FRAGMENT first.
  defp select_options(select_html) do
    select_html
    |> Floki.parse_fragment!()
    |> Floki.find("option")
  end

  defp selected_option_values(select_html) do
    select_html
    |> Floki.parse_fragment!()
    |> Floki.find("option[selected]")
    |> Floki.attribute("value")
  end

  # Bounded poll on the RENDERED output: the assertion is the RENDER, not an
  # internal assign, so this catches exactly what a user would see. 2 ms
  # cadence, `@async_wait_budget_ms` deadline, never a fixed sleep as a
  # mechanism.
  defp wait_for(view, predicate) when is_function(predicate, 0) do
    deadline = System.monotonic_time(:millisecond) + @async_wait_budget_ms

    poll = fn poll ->
      cond do
        predicate.() ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          flunk(
            "timed out waiting for the workbench history render; last panel render:\n" <>
              history_panel_html(view)
          )

        true ->
          Process.sleep(@wait_poll_ms)
          poll.(poll)
      end
    end

    poll.(poll)
  end

  defp history_panel_html(view) do
    case Floki.find(render(view), "#workbench-history-content") do
      [] -> "(no #workbench-history-content in the render)"
      nodes -> Floki.raw_html(nodes)
    end
  end
end
