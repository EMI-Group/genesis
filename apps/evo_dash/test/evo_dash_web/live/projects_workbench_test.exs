# Focused mounted suite for palette project windows, the empty-tabs route,
# node/project scope, and the workbench's right panels.
#
#   * for direct navigation, `?project=<abs path>` makes
#     `ProjectsLive.handle_params/3` call `activate_project/2`, which sets
#     `active_project_path` and derives the VCT identity from the loaded project
#     list, and `Layouts.app` renders `workbench_project` / `workbench_git_project`
#     from that path. The panel's project-filter options come from
#     `NodeContext.projects/1` plus `ensure_project_option/2`'s
#     `Path.basename/1` fallback for unregistered paths.
#   * task fixtures use PER-TEST-UNIQUE ids/project paths and are cleaned up
#     through a direct `EvoGit.Store.delete_task/2` (never a `TaskRegistry`
#     cast, whose `"tasks"` broadcast would arm every mounted page's debounce).
#   * the sidebar hub is cleared per test for the LOCAL `{nil, node()}` context
#     only — `EvoDashWeb.ConnCase` already does that in `setup`/`on_exit`, so it
#     is not repeated here.
#
# The suite defines its OWN fixtures instead of importing
# `EvoDashWeb.ProjectsLiveTest.Helpers`: a helper module defined in another
# `.exs` only exists once that file loads, and this file must run alone with
# `mix test apps/evo_dash/test/evo_dash_web/live/projects_workbench_test.exs`.
# Define the shared helpers before the async case so they're loaded when it runs.
defmodule EvoDashWeb.ProjectsWorkbenchTest.Helpers do
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Phoenix.LiveViewTest

  alias EvoGit.TaskInfo

  @wait_poll_ms 2
  @async_wait_budget_ms 30_000

  # The ProjectsLive mount redirects first-time users to /welcome, so isolate
  # the config dir per test (the `:config_dir_fun` seam, inherited by the
  # mounted view and its supervised load tasks through `$callers`) and mark
  # onboarding complete in it.
  def setup_workbench(%{conn: conn}) do
    tmp_dir = make_project_dir!("evogit_workbench_test")

    # `isolate!/1` registers the directory's ONLY cleanup (drain-backed, then
    # deadline-bounded removal); a second raw `File.rm_rf!/1` would run FIRST
    # (LIFO) with no drain and race a supervised page-load writer.
    EvoDash.Test.ConfigDir.isolate!("evogit_workbench_test_config")

    EvoGit.Config.VersionState.complete_onboarding()

    {:ok, conn: Plug.Test.init_test_session(conn, %{}), tmp_dir: tmp_dir}
  end

  def make_project_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    # Deadline-bounded removal: a page load may still be reading the tree.
    on_exit(fn -> EvoDash.Test.FsCleanup.rm_rf!(dir) end)

    dir
  end

  def unique_phrase(kind) do
    "wb#{kind}#{System.unique_integer([:positive])}"
  end

  # Inserts ONE task directly into the run-wide store (no async task spawn) and
  # registers a DIRECT-store delete on exit: a `TaskRegistry` cast would
  # broadcast on "tasks" and arm every mounted page's reload debounce.
  def seed_task!(opts) do
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

  def assert_empty_project_view(view, path) do
    assert has_element?(view, ~s(#app-layout[data-workbench-project="#{path}"]))

    assert has_element?(
             view,
             ~s(#dashboard-root[data-project="#{path}"][data-workbench-compose=false])
           )

    assert has_element?(view, "#workbench-tabs[phx-update=ignore]")
    refute has_element?(view, "#workbench-tabs > *")

    assert has_element?(
             view,
             "#workbench-idle [data-workbench-idle-window]:not([hidden])",
             "No window selected"
           )

    assert has_element?(view, "#workbench-idle [data-workbench-idle-projects][hidden]")

    assert has_element?(
             view,
             ~s(#workbench-history-project-filter option[selected][value="#{path}"])
           )

    assert has_element?(view, "#workbench-git-toggle")
    refute has_element?(view, "#workbench-project-overview")
    refute has_element?(view, "#task-form")
    refute has_element?(view, "#dashboard-root[phx-hook=StatePersistence]")
    assert_no_default_draft(view)
  end

  def assert_no_default_draft(view) do
    refute has_element?(view, "#app-layout[data-workbench-default-draft]")
  end

  def row_selector(id), do: "#workbench-history-rows [data-workbench-item][data-item-id='#{id}']"

  # Bounded poll on the RENDERED output: the assertion is the RENDER, not an
  # internal assign, so this catches exactly what a user would see. 2 ms
  # cadence, `@async_wait_budget_ms` deadline, never a fixed sleep as a
  # mechanism.
  def wait_for(view, predicate) when is_function(predicate, 0) do
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
    document = view |> render() |> Floki.parse_document!()

    case Floki.find(document, "#workbench-history-content") do
      [] -> "(no #workbench-history-content in the render)"
      nodes -> Floki.raw_html(nodes)
    end
  end
end

defmodule EvoDashWeb.ProjectsWorkbenchTest do
  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EvoDashWeb.ProjectsWorkbenchTest.Helpers

  @async_wait_budget_ms 30_000

  setup context do
    setup_workbench(context)
  end

  describe "project empty-tabs route" do
    test "switching projects on wb_home resets the server-side history scope", %{
      conn: conn,
      tmp_dir: first
    } do
      second = make_project_dir!("evogit_workbench_second")
      first_id = seed_task!(path: first, objective: unique_phrase("first"), status: :completed)
      second_id = seed_task!(path: second, objective: unique_phrase("second"), status: :failed)
      {view, _html} = mount_project_page!(conn, first)

      wait_for(view, fn -> history_row_ids(view) == [first_id] end)

      view
      |> element("#workbench-history-filters")
      |> render_change(%{"project" => "", "status" => "completed"})

      refute has_element?(
               view,
               "#workbench-history-project-filter option[selected]:not([value=''])"
             )

      render_patch(view, ~p"/projects?#{%{project: second, wb_home: "1"}}")

      assert_empty_project_view(view, second)
      wait_for(view, fn -> history_row_ids(view) == [second_id] end)

      # An invalid absolute path isn't a selected project, even when another
      # valid selection was visible immediately before it.
      missing = Path.join(second, "not-a-directory")
      render_patch(view, ~p"/projects?#{%{project: missing, wb_home: "1"}}")

      assert has_element?(view, ~s(#app-layout[data-workbench-project=""]))

      assert has_element?(
               view,
               "#workbench-idle [data-workbench-idle-projects]:not([hidden])",
               "No projects"
             )

      assert has_element?(view, "#workbench-idle [data-workbench-idle-window][hidden]")
      refute has_element?(view, "#workbench-history-filters")
      refute has_element?(view, row_selector(second_id))
      assert_no_default_draft(view)

      # The invalid path must also omit the hint without wb_home suppressing it.
      render_patch(view, ~p"/projects?#{%{project: missing}}")
      assert has_element?(view, ~s(#app-layout[data-workbench-project=""]))
      assert_no_default_draft(view)
    end
  end

  describe "right workbench panels" do
    test "both panels render closed and the history header does not repeat the project name", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {view, html} = mount_project_page!(conn, tmp_dir)

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

      # Ignore the selected option's legitimate project name. No heading or
      # scope label in the panel should repeat it.
      panel = view |> element("#workbench-history") |> render() |> Floki.parse_fragment!()
      refute panel |> Floki.filter_out("select") |> Floki.text() =~ Path.basename(tmp_dir)
    end
  end

  describe "history filters" do
    test "one server-side form places the project and status filters before search",
         %{conn: conn, tmp_dir: tmp_dir} do
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

      project_name = Path.basename(tmp_dir)

      assert has_element?(
               view,
               "#workbench-history-project-filter option[selected]",
               project_name
             )

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

      # Both selects keep their accessible labels and precede search in DOM order.
      form = view |> element("#workbench-history-filters") |> render() |> Floki.parse_fragment!()

      assert [_, _, "workbench-history-search"] =
               Floki.attribute(
                 form,
                 "#workbench-history-project-filter, #workbench-history-status-filter, #workbench-history-search",
                 "id"
               )

      assert has_element?(
               view,
               "label.workbench-history-field[for='workbench-history-project-filter']",
               "Project"
             )

      assert has_element?(
               view,
               "label.workbench-history-field[for='workbench-history-status-filter']",
               "Status"
             )

      assert has_element?(view, "#workbench-history-project-filter.workbench-history-filter")
      assert has_element?(view, "#workbench-history-status-filter.workbench-history-filter")

      # Retained sidebar hook: the recent-projects section reports its load state.
      wait_for(view, fn ->
        has_element?(view, "#workbench-projects[data-workbench-projects-loading=false]")
      end)
    end

    test "selecting All projects widens the scope server-side", %{conn: conn, tmp_dir: tmp_dir} do
      other_dir = make_project_dir!("evogit_workbench_other")
      prefix = unique_phrase("widen")

      current_id = seed_task!(path: tmp_dir, objective: "#{prefix} current", status: :completed)
      other_id = seed_task!(path: other_dir, objective: "#{prefix} other", status: :completed)

      {view, _html} = mount_project_page!(conn, tmp_dir)

      # Default scope = the project being viewed.
      wait_for(view, fn -> has_element?(view, row_selector(current_id)) end)
      refute has_element?(view, row_selector(other_id))

      assert has_element?(
               view,
               "#workbench-history-project-filter option[selected]",
               Path.basename(tmp_dir)
             )

      view
      |> element("#workbench-history-filters")
      |> render_change(%{"project" => "", "query" => prefix})

      wait_for(view, fn ->
        has_element?(view, row_selector(current_id)) and
          has_element?(view, row_selector(other_id))
      end)

      assert has_element?(
               view,
               "#workbench-history-project-filter option[value='']",
               "All projects"
             )

      refute has_element?(
               view,
               "#workbench-history-project-filter option[selected]:not([value=''])"
             )
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

    test "the segmented switch updates both pressed states and the displayed kind", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      task_id = seed_task!(path: tmp_dir, objective: unique_phrase("kind"), status: :completed)

      {view, _html} = mount_project_page!(conn, tmp_dir)

      wait_for(view, fn -> has_element?(view, row_selector(task_id)) end)
      assert_history_kind(view, "task")

      view
      |> element(".workbench-history-switch button", "Conversations")
      |> render_click()

      assert_history_kind(view, "chat")

      # ChatHistory is shared with exact-content readers in async suites. Use a
      # no-match query to exercise the empty state without writing to the cache.
      view
      |> element("#workbench-history-filters")
      |> render_change(%{"query" => unique_phrase("no-chat")})

      wait_for(view, fn ->
        has_element?(view, "#workbench-history-content[data-workbench-history-empty=true]") and
          history_row_ids(view) == []
      end)

      view
      |> element(".workbench-history-switch button", "Tasks")
      |> render_click()

      assert_history_kind(view, "task")

      view
      |> element("#workbench-history-filters")
      |> render_change(%{"query" => ""})

      wait_for(view, fn -> history_row_ids(view) == [task_id] end)
    end
  end

  describe "history rows" do
    test "a task row carries the documented item hooks", %{conn: conn, tmp_dir: tmp_dir} do
      objective = unique_phrase("row")
      id = seed_task!(path: tmp_dir, objective: objective, status: :completed)

      {view, _html} = mount_project_page!(conn, tmp_dir)
      wait_for(view, fn -> has_element?(view, row_selector(id)) end)

      assert has_element?(view, "#{row_selector(id)}[data-workbench-item='task']")
      refute has_element?(view, "#{row_selector(id)} [class*='hero-clipboard']")

      # A FINISHED run opens its review page: that is where its output (diff,
      # merge/reject, archive) lives.
      assert has_element?(
               view,
               "#{row_selector(id)}[data-item-title='#{objective}'][data-item-href='/review/#{id}']"
             )

      assert has_element?(view, "#{row_selector(id)}[data-item-state='Completed']")

      assert has_element?(
               view,
               "#{row_selector(id)} a[data-workbench-open][href='/review/#{id}']"
             )

      # A COMPLETED row is not "active" — the attribute is only rendered for the
      # in-flight states, so its absence is the contract here.
      refute has_element?(view, "#{row_selector(id)}[data-item-active]")

      # "Load more tasks" only exists past the first 15-row page.
      refute has_element?(view, "#workbench-history-rows [data-workbench-more]")
    end

    test "the destination follows the lifecycle state", %{conn: conn, tmp_dir: tmp_dir} do
      prefix = unique_phrase("dest")

      # Finished runs are reviewable: their row belongs on the review page.
      finished =
        for status <- [:completed, :failed, :cancelled] do
          {status, seed_task!(path: tmp_dir, objective: "#{prefix} #{status}", status: status)}
        end

      # Live runs are focused on the tasks page instead.
      live_statuses = [
        :pending,
        :running,
        :finalizing,
        :cancelling,
        :awaiting_input,
        :pausing,
        :paused
      ]

      live =
        for status <- live_statuses do
          {status, seed_task!(path: tmp_dir, objective: "#{prefix} #{status}", status: status)}
        end

      {view, _html} = mount_project_page!(conn, tmp_dir)

      view
      |> element("#workbench-history-filters")
      |> render_change(%{"query" => prefix})

      wait_for(view, fn -> length(history_row_ids(view)) == length(finished) + length(live) end)

      for {status, id} <- finished do
        row = row_selector(id)
        href = "/review/#{id}"

        assert has_element?(view, "#{row}[data-item-href='#{href}']"),
               "expected the #{status} row to open #{href}"

        assert has_element?(view, "#{row} a[data-workbench-open][href='#{href}']")

        # Finished means finished: never marked active, never routed at /tasks.
        refute has_element?(view, "#{row}[data-item-active]")
        refute has_element?(view, "#{row}[data-item-href^='/tasks']")
      end

      for {status, id} <- live do
        # `?task=<id>` IS the tasks page's focus mode (it filters the page to the
        # one task and opens its card), so a live row lands on that run.
        row = row_selector(id)
        href = "/tasks?task=#{id}"

        assert has_element?(view, "#{row}[data-item-href='#{href}']"),
               "expected the #{status} row to focus its run on /tasks"

        assert has_element?(view, "#{row} a[data-workbench-open][href='#{href}']")
        refute has_element?(view, "#{row}[data-item-href^='/review/']")
        # The in-flight statuses are the ones the presentational flag marks.
        assert has_element?(view, "#{row}[data-item-active='true']")
      end
    end

    test "both destinations keep the viewed node, joined correctly" do
      alias EvoDashWeb.WorkbenchComponent

      # The row hrefs are built by `navigation_path/3`, which puts `node:` FIRST
      # and `&`-joins any further param — the `with_node_param/2` gotcha, where a
      # second `?` would corrupt the query.
      assert WorkbenchComponent.navigation_path("/review/abc", "remote-7") ==
               "/review/abc?node=remote-7"

      assert WorkbenchComponent.navigation_path("/tasks", "remote-7", task: "abc") ==
               "/tasks?node=remote-7&task=abc"

      assert WorkbenchComponent.navigation_path("/review/abc", nil) == "/review/abc"
      assert WorkbenchComponent.navigation_path("/tasks", nil, task: "abc") == "/tasks?task=abc"
    end

    test "the first page holds 15 rows and Load more appends the rest", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      prefix = unique_phrase("page")

      ids =
        for index <- 1..17 do
          seed_task!(path: tmp_dir, objective: "#{prefix} #{index}", status: :completed)
        end

      {view, _html} = mount_project_page!(conn, tmp_dir)

      view
      |> element("#workbench-history-filters")
      |> render_change(%{"query" => prefix})

      # The first page has 15 entries; Load more retains them and appends the rest.
      more = "#workbench-history-rows [data-workbench-more]"
      wait_for(view, fn -> length(history_row_ids(view)) == 15 and has_element?(view, more) end)
      first_page = history_row_ids(view)

      view |> element(more) |> render_click()

      wait_for(view, fn ->
        length(history_row_ids(view)) == 17 and not has_element?(view, more)
      end)

      all_rows = history_row_ids(view)
      assert Enum.take(all_rows, 15) == first_page
      assert Enum.sort(all_rows) == Enum.sort(ids)
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

  defp assert_history_kind(view, kind) do
    indicator = Map.fetch!(%{"task" => "tasks", "chat" => "conversations"}, kind)
    switch = "#workbench-history .workbench-history-switch[data-history-kind='#{indicator}']"

    assert has_element?(
             view,
             "#{switch} button[data-workbench-kind=task][aria-pressed='#{kind == "task"}']",
             "Tasks"
           )

    assert has_element?(
             view,
             "#{switch} button[data-workbench-kind=chat][aria-pressed='#{kind == "chat"}']",
             "Conversations"
           )
  end

  defp history_row_ids(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("#workbench-history-rows [data-workbench-item][data-item-id]")
    |> Floki.attribute("data-item-id")
  end

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
end

defmodule EvoDashWeb.ProjectsWorkbenchConversationTest do
  # Seeding EvoDash.ChatHistory would race the async suite's exact cache reads.
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EvoDashWeb.ProjectsWorkbenchTest.Helpers

  setup context do
    setup_workbench(context)
  end

  test "a conversation row in project history opens its Assistant session", %{
    conn: conn,
    tmp_dir: path
  } do
    chat_id = System.unique_integer([:positive])
    title = unique_phrase("chat")
    on_exit(fn -> EvoDash.ChatHistory.delete_chat(chat_id) end)

    :ok =
      EvoDash.ChatHistory.put_state(chat_id, %{
        transcript: [%{role: :user, text: title}],
        workspace: %{path: path, node: node(), node_id: nil}
      })

    {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: path, wb_home: "1"}}")
    view |> element("#workbench-history button", "Conversations") |> render_click()

    row = "#{row_selector(chat_id)}[data-workbench-item='chat']"
    href = "/assistant?session=#{chat_id}"

    wait_for(view, fn -> has_element?(view, row) end)
    assert has_element?(view, "#{row}[data-item-href='#{href}']")
    assert has_element?(view, "#{row} a[data-workbench-open][href='#{href}']", title)
  end
end

# This fixture is local to the VCT case; the unique target IDs are saved in
# the test's isolated config directory, and events go only to its view.
defmodule EvoDashWeb.ProjectsWorkbenchVctTest.ConnectionManager do
  use GenServer

  def start_link(id), do: GenServer.start_link(__MODULE__, id)

  @impl true
  def init(id) do
    {:ok, _} = Registry.register(EvoGit.RemoteConnection.Registry, id, :status)
    {:ok, %{phase: :connecting, node: nil, last_error: nil}}
  end

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}
  def handle_call({:set_status, status}, _from, _previous), do: {:reply, :ok, status}
end

defmodule EvoDashWeb.ProjectsWorkbenchVctTest do
  # ProjectsLiveTest clears the process-global VCT registry. Run serially so
  # those clears neither delete a fixture mount nor mask an unexpected mount.
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EvoDashWeb.ProjectsWorkbenchTest.Helpers

  alias __MODULE__.ConnectionManager
  alias EvoGit.Adapters.Git
  alias EvoGit.VCT

  @async_wait_budget_ms 30_000

  setup context do
    setup_workbench(context)
  end

  describe "palette project window" do
    test "Open Project by Path lands on the registered project's overview", %{
      conn: conn,
      tmp_dir: root
    } do
      path = Path.join(root, "existing project")
      File.mkdir!(path)
      expect_unregistered_project(path)

      view = browse_project_window(conn, "open", "Open Project by Path", path)

      view
      |> element(
        "#workbench-project-window button[phx-click=open]:not([disabled])",
        "Open project"
      )
      |> render_click()

      assert_project_window_destination(view, conn, path)
    end

    test "Create New Project lands on the new project's overview", %{conn: conn, tmp_dir: root} do
      name = "new project"
      path = Path.join(root, name)
      refute File.exists?(path)
      expect_unregistered_project(path)

      view = browse_project_window(conn, "create", "Create New Project", root)

      assert has_element?(
               view,
               "#workbench-project-window button[form=workbench-project-form]:not([disabled])",
               "Create"
             )

      view |> form("#workbench-project-form", %{"name" => name}) |> render_submit()

      assert_project_window_destination(view, conn, path)
    end
  end

  test "a direct URL to an unregistered repo offers manual tasks but not scoped chat", %{
    conn: conn,
    tmp_dir: path
  } do
    assert {:ok, _} = Git.run(~w(init --template= -b main), path)

    assert {:ok, _} =
             Git.run(
               ~w(-c user.name=Workbench -c user.email=workbench@example.invalid
                  -c core.hooksPath=.git/hooks commit --no-gpg-sign --allow-empty -m Seed),
               path
             )

    expect_unregistered_project(path)

    {:ok, view, html} = live(conn, ~p"/projects?#{%{project: path}}")
    refute html =~ "data-workbench-default-draft="

    # The local batch seeds notification IDs in the same result as the VCT roster.
    wait_for(view, fn ->
      %{socket: %{assigns: assigns}} = :sys.get_state(view.pid, @async_wait_budget_ms)
      assigns[:notified_task_ids_ready?] == true
    end)

    overview = "#workbench-project-overview[data-overview-kind=project]"
    assert has_element?(view, "#{overview} [data-overview-path]", path)
    assert {:error, :not_found} = VCT.resolve(path)
    assert_no_default_draft(view)

    # Keep the settled overview markup while exercising the real manual action.
    overview_dom = view |> element(overview) |> render() |> Floki.parse_fragment!()
    new_task = "#{overview} button#overview-new-task[phx-click=compose_task]:not([disabled])"
    view |> element(new_task, "New task") |> render_click()

    assert %URI{path: "/projects", query: query} =
             view |> assert_patch(@async_wait_budget_ms) |> URI.parse()

    assert URI.decode_query(query) == %{"project" => path, "wb_task" => "1"}
    assert has_element?(view, "#dashboard-root[data-workbench-compose=true] form#task-form")
    assert {:error, :not_found} = VCT.resolve(path)

    assert Floki.find(overview_dom, "a#overview-chat-assistant[href]") == []
    assert Floki.find(overview_dom, "button#overview-chat-assistant:not([disabled])") == []
    assert Floki.text(overview_dom) =~ ~r/\bproject picker\b/i
  end

  describe "project empty-tabs route" do
    test "leaving the overview for wb_home keeps the project scope but renders no view", %{
      conn: conn,
      tmp_dir: root
    } do
      path = Path.join(root, "project with spaces")
      File.mkdir!(path)
      point = register_project!(path)
      task_id = seed_task!(path: path, objective: unique_phrase("empty-tabs"), status: :completed)
      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: path}}")

      assert has_element?(view, "#workbench-project-overview[data-overview-kind=project]")
      assert has_element?(view, "#dashboard-root[data-workbench-compose=false]")
      await_confirmed_overview(view, point, task_id)

      assert_scoped_default_draft(view, path)

      # This is the URL reached after the client closes the last open tab; no
      # client hook has to fix an incorrect server scope or display state.
      render_patch(view, ~p"/projects?#{%{project: path, wb_home: "1"}}")

      assert_empty_project_view(view, path)
      assert has_element?(view, row_selector(task_id))

      render_patch(view, ~p"/projects?#{%{project: path, wb_task: "1"}}")
      assert has_element?(view, "#dashboard-root[data-workbench-compose=true] #task-form")
      refute has_element?(view, "#workbench-project-overview")
      assert_no_default_draft(view)
    end

    test "switching the viewed node drops local scope and ignores the old target's connect event",
         %{
           conn: conn,
           tmp_dir: path
         } do
      point = register_project!(path)
      task_id = seed_task!(path: path, objective: unique_phrase("local-only"), status: :completed)
      {old_id, old_manager} = connecting_target!("Old workbench node")
      {current_id, current_manager} = connecting_target!("Current workbench node")
      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: path}}")
      await_confirmed_overview(view, point, task_id)

      # Keep the exact same project path throughout: a path-only scope check
      # cannot distinguish either pending remote context from the local one.
      for {id, name} <- [{old_id, "Old workbench node"}, {current_id, "Current workbench node"}] do
        direct = ~p"/projects?#{%{project: path, node: id}}"
        render_patch(view, direct)
        assert_patch(view, direct, @async_wait_budget_ms)
        assert has_element?(view, "#main-content p", "Connecting to #{name}…")
        assert_no_project_scope(view, id, task_id)

        target_path = ~p"/projects?#{%{project: path, wb_home: "1", node: id}}"
        render_patch(view, target_path)
        assert_patch(view, target_path, @async_wait_budget_ms)
        assert has_element?(view, "#main-content p", "Connecting to #{name}…")
      end

      assert_no_project_scope(view, current_id, task_id)
      assert_stale_connect_ignored(view, old_id, old_manager, current_id, task_id)

      # A direct project URL also must not advertise a draft after a stale
      # connect notification, independent of the empty-tabs suppression.
      direct = ~p"/projects?#{%{project: path, node: current_id}}"
      render_patch(view, direct)
      assert_patch(view, direct, @async_wait_budget_ms)
      assert_stale_connect_ignored(view, old_id, old_manager, current_id, task_id)

      empty = ~p"/projects?#{%{project: path, wb_home: "1", node: current_id}}"
      render_patch(view, empty)
      assert_patch(view, empty, @async_wait_budget_ms)

      # Positive control: the same event from the CURRENT target reconnects
      # the page and preserves the empty-tabs URL. The fake has no daemon to
      # answer File.dir?; a directory on the local host cannot validate it.
      connect_target(view, current_id, current_manager)
      uri = view |> assert_patch(@async_wait_budget_ms) |> URI.parse()
      assert uri.path == "/projects"

      assert URI.decode_query(uri.query) == %{
               "project" => path,
               "wb_home" => "1",
               "node" => current_id
             }

      render_async(view, @async_wait_budget_ms)
      assert_unavailable_project(view, path, current_id, task_id)

      render_patch(view, direct)
      assert_unavailable_project(view, path, current_id, task_id)

      render_patch(view, ~p"/projects?#{%{project: path, wb_home: "1"}}")
      assert_empty_project_view(view, path)
      wait_for(view, fn -> has_element?(view, row_selector(task_id)) end)
    end
  end

  defp browse_project_window(conn, mode, label, path) do
    {:ok, view, _html} = live(conn, ~p"/projects")
    render_hook(view, "open_project_palette", %{})

    # The Workbench hook intercepts this button before its legacy phx-click
    # and sends the rendered mode to the mounted ProjectWindow component.
    trigger = "#project-omnibox button[data-workbench-project-window=#{mode}]"
    rendered = view |> element(trigger, label) |> render() |> Floki.parse_fragment!()
    assert [^mode] = Floki.attribute(rendered, "button", "data-workbench-project-window")

    render_hook(with_target(view, "#workbench-project-window-component"), "prepare", %{
      "mode" => mode
    })

    view |> form("#project-picker-path-form", %{"path" => path}) |> render_submit()
    render_async(view, @async_wait_budget_ms)

    assert has_element?(
             view,
             ~s(#workbench-project-window .project-picker-path [title="#{path}"]),
             path
           )

    view
  end

  defp assert_project_window_destination(view, conn, path) do
    # ProjectWindow uses push_navigate after its async mount, not the parent
    # LiveView's legacy push_patch path.
    {to, _flash} = assert_redirect(view, @async_wait_budget_ms)
    assert File.dir?(path)
    assert {:ok, %{path: ^path, point: point}} = VCT.resolve(path)
    assert %URI{path: "/projects", query: query} = URI.parse(to)
    assert URI.decode_query(query) == %{"project" => path}

    {:ok, overview, _html} = live(conn, to)
    selector = "#workbench-project-overview[data-overview-kind=project]"

    wait_for(overview, fn ->
      has_element?(overview, "#{selector} [data-overview-point]", point)
    end)

    assert has_element?(overview, "#{selector} [data-overview-path]", path)
    assert has_element?(overview, "#dashboard-root[data-workbench-compose=false]")
    assert_scoped_default_draft(overview, path)
  end

  defp expect_unregistered_project(path) do
    assert {:error, :not_found} = VCT.resolve(path)

    on_exit(fn ->
      # Clean up the exact test mount even when the navigation assertion fails.
      case VCT.resolve(path) do
        {:ok, mount} -> assert :ok = VCT.forget(mount.point)
        {:error, :not_found} -> :ok
      end
    end)
  end

  defp assert_scoped_default_draft(view, path) do
    chat_link =
      ~s|a#overview-chat-assistant[href^="/assistant?"][data-phx-link=redirect]:not([aria-disabled=true]):not([hidden])|

    # Take both hrefs from the SAME settled render: the draft id belongs to
    # this navigation, and the hint must not mint a second id.
    overview = view |> render() |> Floki.parse_document!()
    assert [link] = Floki.find(overview, chat_link)
    assert Floki.text(link) =~ "Chat with Assistant"
    assert [chat_href] = Floki.attribute(link, "href")
    assert %URI{path: "/assistant", query: query} = URI.parse(chat_href)
    assert %{"wb_draft" => draft} = URI.decode_query(query)
    assert draft =~ ~r/\A[0-9a-f]{24}\z/
    assert chat_href == "/assistant?" <> URI.encode_query(wb_project: path, wb_draft: draft)
    assert Floki.attribute(overview, "#app-layout", "data-workbench-default-draft") == [chat_href]
  end

  defp register_project!(path) do
    assert {:ok, mount} = EvoGit.VCT.mount(path)
    on_exit(fn -> EvoGit.VCT.forget(mount.point) end)
    mount.point
  end

  defp connecting_target!(name) do
    id = unique_phrase("target")

    assert {:ok, _} =
             EvoGit.RemoteConnections.save(%{ssh_target: "user@host", id: id, name: name})

    manager = start_supervised!({ConnectionManager, id}, id: id)
    {id, manager}
  end

  defp connect_target(view, id, manager) do
    status = %{phase: :connected, node: "#{id}@127.0.0.1", last_error: nil}
    :ok = GenServer.call(manager, {:set_status, status}, @async_wait_budget_ms)
    send(view.pid, {:remote_connection_status, id, status})
  end

  defp await_confirmed_overview(view, point, task_id) do
    wait_for(view, fn ->
      has_element?(view, "#workbench-project-overview [data-overview-point]", point) and
        has_element?(view, row_selector(task_id))
    end)
  end

  defp assert_stale_connect_ignored(view, old_id, old_manager, current_id, task_id) do
    connect_target(view, old_id, old_manager)
    # The state round trip drains our send; render then flushes any patch
    # notification from the LiveViewTest proxy before the negative probe.
    :sys.get_state(view.pid, @async_wait_budget_ms)
    render(view)
    refute_patched(view)
    assert has_element?(view, "#main-content p", "Connecting to Current workbench node…")
    assert_no_project_scope(view, current_id, task_id)
  end

  defp assert_unavailable_project(view, path, target_id, task_id) do
    wait_for(view, fn ->
      has_element?(view, "#flash-error", "Directory does not exist on the remote node: #{path}") and
        not has_element?(view, "#workbench-project-loading")
    end)

    assert_no_project_scope(view, target_id, task_id)
  end

  defp assert_no_project_scope(view, target_id, task_id) do
    assert has_element?(
             view,
             ~s(#app-layout[data-workbench-node="#{target_id}"][data-workbench-project=""])
           )

    assert has_element?(view, "#dashboard-root[data-workbench-compose=false]:not([data-project])")
    refute has_element?(view, "#workbench-history-toggle")
    refute has_element?(view, "#workbench-history-filters")
    refute has_element?(view, "#workbench-git-toggle")
    refute has_element?(view, "#task-form")
    refute has_element?(view, row_selector(task_id))
    assert_no_default_draft(view)
  end
end
