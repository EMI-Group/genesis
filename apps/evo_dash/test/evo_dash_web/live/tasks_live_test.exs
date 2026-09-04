defmodule EvoDashWeb.TasksLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoGit.TaskRegistry
  alias EvoGit.TaskInfo

  setup do
    # Terminate production children to prevent auto-restarts and use isolated stores.
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_tasks_live_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({EvoGit.Store, data_dir: sqlite_path})

    start_supervised(
      {TaskRegistry, task_store: EvoGit.Store, data_dir: root, name: EvoGit.TaskRegistry}
    )

    # ActiveTasks is a global GenServer under EvoDash.Application that is NOT
    # terminated by the Store/TaskRegistry isolation above — reset it so one
    # test's sidebar snapshot never leaks into the next.
    EvoDash.ActiveTasks.reset()

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.Store)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    end)

    :ok
  end

  # Inserts a task directly into the SQLite store (bypasses the async
  # task spawn that `start_task/2` triggers). This lets us create deterministic
  # fixture tasks for search/filter assertions.
  defp insert_fixture!(overrides) do
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
    id
  end

  # Delegates to the shared flush helper (EvoDashWeb.TestHelpers.flush_loading/4).
  defp flush_tasks_load(view, timeout \\ 5000),
    do:
      EvoDashWeb.TestHelpers.flush_loading(
        view,
        "Loading tasks...",
        "timed out waiting for the async task load to finish",
        timeout
      )

  # Polls `fun` every 10ms until it returns truthy (or the timeout elapses).
  # Used to observe the PubSub-driven debounce phases (:tasks_reload_pending
  # true → false) without fixed sleeps.
  defp wait_until(fun, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop = fn wait_loop ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for async condition")
        else
          Process.sleep(10)
          wait_loop.(wait_loop)
        end
      end
    end

    wait_loop.(wait_loop)
  end

  describe "task search" do
    test "renders the search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "Search by task ID, prompt, objective, or response"
    end

    test "search_tasks handler filters tasks by prompt text", %{conn: conn} do
      insert_fixture!(opts: [prompt: "build a web app", path: "/tmp/proj"])
      insert_fixture!(opts: [prompt: "write a database migration", path: "/tmp/proj"])
      insert_fixture!(opts: [prompt: "refactor the auth module", path: "/tmp/proj"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "search_tasks", %{"search_query" => "database"})
      html = flush_tasks_load(view)

      assert html =~ "write a database migration"
      refute html =~ "build a web app"
      refute html =~ "refactor the auth module"
    end

    test "search_tasks handler filters tasks by objective text", %{conn: conn} do
      insert_fixture!(opts: [objective: "fix the login bug"])
      insert_fixture!(opts: [objective: "add dark mode toggle"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "search_tasks", %{"search_query" => "login"})
      html = flush_tasks_load(view)

      assert html =~ "fix the login bug"
      refute html =~ "add dark mode toggle"
    end

    test "search_tasks handler filters tasks by task ID", %{conn: conn} do
      id1 = insert_fixture!(opts: [prompt: "alpha task"])
      insert_fixture!(opts: [prompt: "beta task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "search_tasks", %{"search_query" => id1})
      html = flush_tasks_load(view)

      assert html =~ "alpha task"
      refute html =~ "beta task"
    end

    test "clearing the search query restores all tasks", %{conn: conn} do
      insert_fixture!(opts: [prompt: "alpha task"])
      insert_fixture!(opts: [prompt: "beta task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # First narrow down
      _html = render_hook(view, "search_tasks", %{"search_query" => "alpha"})
      flush_tasks_load(view)
      # Then clear
      _html = render_hook(view, "search_tasks", %{"search_query" => ""})
      html = flush_tasks_load(view)

      assert html =~ "alpha task"
      assert html =~ "beta task"
    end

    test "search is case-insensitive", %{conn: conn} do
      insert_fixture!(opts: [prompt: "Build a REST API"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "search_tasks", %{"search_query" => "rest api"})
      html = flush_tasks_load(view)

      assert html =~ "Build a REST API"
    end

    test "search_tasks handler filters tasks by agent response message", %{conn: conn} do
      # Each fixture's response fragment appears ONLY in that fixture's result
      # text (never in any opts/prompt/id), so a hit proves the result-column
      # match. The prompts are what render in the task cards.
      insert_fixture!(
        opts: [prompt: "deploy the delivery scheduling feature"],
        result:
          {:ok,
           %{
             result: "Widget Deployment finished cleanly",
             commit_sha: "abc123",
             branch_name: "agent-1"
           }}
      )

      insert_fixture!(
        opts: [prompt: "write the inventory audit report"],
        result:
          {:ok,
           %{
             result: "Refactored the legacy parser module",
             commit_sha: "def456",
             branch_name: "agent-2"
           }}
      )

      insert_fixture!(
        opts: [prompt: "tune the payment gateway timeouts"],
        result:
          {:ok,
           %{
             result: "Resolved the checkout race condition",
             commit_sha: "beef01",
             branch_name: "agent-3"
           }}
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # Exact-fragment leg: the query occurs in exactly one fixture's response
      # text, so only that task row survives the store filter.
      _html = render_hook(view, "search_tasks", %{"search_query" => "Widget Deployment"})
      html = flush_tasks_load(view)

      assert html =~ "deploy the delivery scheduling feature"
      refute html =~ "write the inventory audit report"
      refute html =~ "tune the payment gateway timeouts"

      # Case-insensitive leg: re-search the same response fragment with
      # different casing and the matching fixture still renders.
      _html = render_hook(view, "search_tasks", %{"search_query" => "widget deployment"})
      html = flush_tasks_load(view)

      assert html =~ "deploy the delivery scheduling feature"
      refute html =~ "write the inventory audit report"
      refute html =~ "tune the payment gateway timeouts"
    end
  end

  describe "filter selects" do
    test "filter_tasks handler filters by status", %{conn: conn} do
      insert_fixture!(status: :completed, opts: [prompt: "completed one"])
      insert_fixture!(status: :failed, opts: [prompt: "failed one"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "filter_tasks", %{"status_filter" => "failed"})
      html = flush_tasks_load(view)

      assert html =~ "failed one"
      refute html =~ "completed one"
    end

    test "filter_tasks handler 'all' shows everything", %{conn: conn} do
      insert_fixture!(status: :completed, opts: [prompt: "completed one"])
      insert_fixture!(status: :failed, opts: [prompt: "failed one"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "filter_tasks", %{"status_filter" => "all"})
      html = flush_tasks_load(view)

      assert html =~ "completed one"
      assert html =~ "failed one"
    end

    test "reset_filters clears all filters including search", %{conn: conn} do
      insert_fixture!(opts: [prompt: "alpha task"])
      insert_fixture!(opts: [prompt: "beta task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # Apply a search filter first
      _html = render_hook(view, "search_tasks", %{"search_query" => "alpha"})
      flush_tasks_load(view)
      # Then reset
      _html = render_click(view, "reset_filters")
      html = flush_tasks_load(view)

      assert html =~ "alpha task"
      assert html =~ "beta task"
    end
  end

  describe "reflect chat tasks (show_reflect_tasks reveal toggle)" do
    # :reflect repo-less Home-chat (self-reflective agent) tasks are hidden
    # from the cross-project list by default and only revealed when the
    # "Show chat tasks" checkbox in the filter bar is checked. The toggle is a
    # page-local REVEAL preference, NOT a narrowing filter: it is deliberately
    # left out of reset_filters and the active-filters indicator.

    test "reflect tasks are hidden by default; the reveal checkbox renders unchecked", %{
      conn: conn
    } do
      insert_fixture!(opts: [prompt: "MARKER NORMAL TASK SHOWN BY DEFAULT"])

      insert_fixture!(
        type: :reflect,
        opts: [mode: "reflect", prompt: "MARKER REFLECT CHAT TASK HIDDEN BY DEFAULT"]
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # The normal task renders; the :reflect task does NOT.
      assert html =~ "MARKER NORMAL TASK SHOWN BY DEFAULT"
      refute html =~ "MARKER REFLECT CHAT TASK HIDDEN BY DEFAULT"

      # The "Show chat tasks" label renders in the filter bar, and its checkbox
      # (value="true") is present but unchecked (default false).
      assert html =~ "Show chat tasks"
      assert attribute(html, "input[name=show_reflect_tasks]", "value") == ["true"]
      assert attribute(html, "input[name=show_reflect_tasks]", "checked") == []
    end

    test "checking the reveal toggle shows reflect tasks", %{conn: conn} do
      insert_fixture!(
        type: :reflect,
        opts: [mode: "reflect", prompt: "MARKER REFLECT CHAT TASK REVEALED BY TOGGLE"]
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # With only a hidden :reflect row the list renders its empty state.
      assert html =~ "No tasks found"
      refute html =~ "MARKER REFLECT CHAT TASK REVEALED BY TOGGLE"

      # A CHECKED daisyUI checkbox submits "true" (an unchecked box would be
      # absent from the form params); the async page load re-runs.
      _html = render_hook(view, "toggle_reflect_tasks", %{"show_reflect_tasks" => "true"})
      html = flush_tasks_load(view)

      assert html =~ "MARKER REFLECT CHAT TASK REVEALED BY TOGGLE"
      refute html =~ "No tasks found"
      assert html =~ "Show chat tasks"
      assert attribute(html, "input[name=show_reflect_tasks]", "checked") != []

      # The reveal preference is not counted as an active (narrowing) filter:
      # no active-filters indicator appears just because reflect tasks are shown.
      refute html =~ "Active filters:"
    end

    test "toggle is additive: normal tasks render regardless and other filter assigns survive", %{
      conn: conn
    } do
      insert_fixture!(opts: [prompt: "MARKER KEEPS VISIBLE NORMAL TASK"])
      insert_fixture!(opts: [prompt: "MARKER EXCLUDED NORMAL TASK"])

      insert_fixture!(
        type: :reflect,
        opts: [mode: "reflect", prompt: "MARKER KEEPS VISIBLE REFLECT CHAT TASK"]
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # Narrow with a search query: the matching normal task renders, the
      # non-matching one is filtered out, and the matching :reflect row is
      # hidden by the reveal preference (it passes the SQL filter but is
      # dropped by visible_tasks/2).
      _html = render_hook(view, "search_tasks", %{"search_query" => "MARKER KEEPS VISIBLE"})
      html = flush_tasks_load(view)

      assert html =~ "MARKER KEEPS VISIBLE NORMAL TASK"
      refute html =~ "MARKER EXCLUDED NORMAL TASK"
      refute html =~ "MARKER KEEPS VISIBLE REFLECT CHAT TASK"

      # Toggling reveal ON adds the matching :reflect row without disturbing
      # the search query — the excluded normal task stays excluded.
      _html = render_hook(view, "toggle_reflect_tasks", %{"show_reflect_tasks" => "true"})
      html = flush_tasks_load(view)

      assert html =~ "MARKER KEEPS VISIBLE NORMAL TASK"
      assert html =~ "MARKER KEEPS VISIBLE REFLECT CHAT TASK"
      refute html =~ "MARKER EXCLUDED NORMAL TASK"

      # Toggling reveal back OFF (an unchecked box sends no param) hides only
      # the :reflect row; the search query is still intact.
      _html = render_hook(view, "toggle_reflect_tasks", %{})
      html = flush_tasks_load(view)

      assert html =~ "MARKER KEEPS VISIBLE NORMAL TASK"
      refute html =~ "MARKER KEEPS VISIBLE REFLECT CHAT TASK"
      refute html =~ "MARKER EXCLUDED NORMAL TASK"
    end

    test "empty store renders the first-run nudge, not the adjust-filters hint", %{conn: conn} do
      # No fixtures at all: genuinely empty DB, no filters, reveal toggle off.
      # total_count == 0, so the empty-state hint falls through to the friendly
      # first-run message (not the "adjust your filters" nudge).
      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      assert html =~ "No tasks found"
      assert html =~ "Tasks will appear here once you start them from the dashboard."
      refute html =~ "Try adjusting your filters or search query."
    end

    test "a store containing only hidden reflect tasks renders the adjust-filters hint", %{
      conn: conn
    } do
      # A single :reflect (repo-less Home-chat) row: total_count > 0 but the
      # reveal toggle is off, so the visible list is empty and the hint tells
      # the user the filter-bar "Show chat tasks" checkbox would un-hide it.
      insert_fixture!(
        type: :reflect,
        opts: [mode: "reflect", prompt: "MARKER ONLY REFLECT CHAT TASK IN STORE"]
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # The visible list is empty and the hidden :reflect row does not render.
      assert html =~ "No tasks found"
      refute html =~ "MARKER ONLY REFLECT CHAT TASK IN STORE"

      # total_count (SQL-truthful) counts the reflect row, so the adjusting
      # hint wins over the first-run nudge.
      assert html =~ "Try adjusting your filters or search query."
      refute html =~ "Tasks will appear here once you start them from the dashboard."
    end
  end

  describe ":task_updated broadcast handling" do
    # The EvoGit runtime broadcasts {:task_updated, task_id, status, node} on
    # the "tasks" PubSub topic (node-identity contract). TasksLive forwards the
    # message to NodeAware.handle_task_info/2, which applies the node filter
    # (only the viewed node's events trigger UI updates) and schedules a 300ms
    # debounced reload. These tests verify the handle_info clauses handle these
    # messages gracefully.

    test "handle_info {:task_updated, _, :finalizing, node} does not crash the LiveView", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Broadcast a :finalizing status transition in the new node-identity shape
      # (the message that previously crashed).
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, "test-finalizing", :finalizing, node()}
      )

      # render/1 flushes pending messages synchronously; a crash would propagate here.
      html = render(view)
      assert is_binary(html)
      assert html =~ "All Statuses"
    end

    test "handle_info catch-all does not crash on unknown messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # An arbitrary message the LiveView doesn't specifically handle should be
      # swallowed by the catch-all clause rather than crashing.
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:some_unexpected_event, 42})

      html = render(view)
      assert is_binary(html)
      assert html =~ "All Statuses"
    end
  end

  describe "pagination" do
    # Inserts a task with a deterministic, distinct started_at so ordering is
    # predictable. Index 0 is the oldest; higher indices are more recent and
    # appear first (ORDER BY started_at DESC). Each task gets a unique prompt
    # so tests can assert which page shows what. Optional overrides allow
    # customizing status and prompt for filtering tests.
    defp insert_timed_fixture!(i, opts \\ []) do
      id = "page_fixture_#{System.unique_integer([:positive])}"
      started = ~U[2026-01-01 00:00:00Z] |> DateTime.add(i, :second)

      task = %TaskInfo{
        id: id,
        type: :genesis,
        status: Keyword.get(opts, :status, :completed),
        opts: [path: "/tmp/test", prompt: Keyword.get(opts, :prompt, "task number #{i}")],
        ref: nil,
        started_at: started,
        finished_at: DateTime.add(started, 1, :second),
        logs: [],
        result: nil
      }

      EvoGit.Store.put_task(EvoGit.Store, task)
      id
    end

    test "page 1 shows first page_size tasks and pagination controls appear", %{conn: conn} do
      # Insert page_size + 1 = 26 tasks to trigger pagination (2 pages).
      for i <- 0..25, do: insert_timed_fixture!(i)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # Pagination controls should render.
      assert html =~ "Page 1 of 2"

      # "Showing X–Y of Z" text — page 1 shows 1..25 of 26.
      assert html =~ "Showing 1–25 of 26 tasks"

      # The most recent tasks (indices 25..1) should be on page 1.
      assert html =~ "task number 25"
      assert html =~ "task number 1"
      # Index 0 (oldest) is on page 2.
      refute html =~ "task number 0"
    end

    test "navigating to ?page=2 shows the next set", %{conn: conn} do
      for i <- 0..25, do: insert_timed_fixture!(i)

      {:ok, view, _html} = live(conn, ~p"/tasks?page=2")
      html = flush_tasks_load(view)

      assert html =~ "Page 2 of 2"

      # Page 2 shows the oldest task (index 0).
      assert html =~ "task number 0"
      # Page 2 should NOT show the newest (index 25).
      refute html =~ "task number 25"
    end

    test "invalid page params clamp and do not crash", %{conn: conn} do
      for i <- 0..25, do: insert_timed_fixture!(i)

      # Non-integer page → defaults to 1.
      {:ok, view_abc, _html} = live(conn, ~p"/tasks?page=abc")
      html_abc = flush_tasks_load(view_abc)
      assert html_abc =~ "Page 1 of 2"

      # Negative page → clamps to 1.
      {:ok, view_neg, _html} = live(conn, ~p"/tasks?page=-1")
      html_neg = flush_tasks_load(view_neg)
      assert html_neg =~ "Page 1 of 2"

      # Out-of-range page → clamps to last page (2).
      {:ok, view_big, _html} = live(conn, ~p"/tasks?page=9999")
      html_big = flush_tasks_load(view_big)
      assert html_big =~ "Page 2 of 2"
      assert html_big =~ "task number 0"
    end

    test "next_page / prev_page events navigate correctly", %{conn: conn} do
      for i <- 0..25, do: insert_timed_fixture!(i)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # Navigate to page 2 via next_page.
      _html = render_click(view, "next_page")
      html_next = flush_tasks_load(view)
      assert html_next =~ "Page 2 of 2"
      assert html_next =~ "task number 0"

      # Navigate back to page 1 via prev_page.
      _html = render_click(view, "prev_page")
      html_prev = flush_tasks_load(view)
      assert html_prev =~ "Page 1 of 2"
      assert html_prev =~ "task number 25"
    end

    test "goto_page event navigates to a specific page", %{conn: conn} do
      for i <- 0..25, do: insert_timed_fixture!(i)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_click(view, "goto_page", %{"page" => "2"})
      html = flush_tasks_load(view)
      assert html =~ "Page 2 of 2"
      assert html =~ "task number 0"
    end

    test "status filter works across pages (server-side filtering)", %{conn: conn} do
      # Insert 30 tasks: 20 completed + 10 failed. Each gets a distinct
      # started_at so ordering is deterministic, and a unique prompt that
      # encodes the status so we can assert which appear/disappear.
      for i <- 0..19 do
        insert_timed_fixture!(i, status: :completed, prompt: "completed task number #{i}")
      end

      for i <- 0..9 do
        insert_timed_fixture!(i, status: :failed, prompt: "failed task number #{i}")
      end

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "filter_tasks", %{"status_filter" => "failed"})
      html = flush_tasks_load(view)

      # 10 failed tasks, page_size 25 → 1 page.
      assert html =~ "Page 1 of 1"
      # "Showing 1–10 of 10 tasks"
      assert html =~ "Showing 1–10 of 10 tasks"

      # The failed prompts should appear.
      assert html =~ "failed task number 9"
      assert html =~ "failed task number 0"

      # The completed prompts should NOT appear.
      refute html =~ "completed task number 19"
      refute html =~ "completed task number 0"
    end
  end

  describe "node-aware behavior" do
    test "task list UI renders (no remote-only info message)", %{conn: conn} do
      insert_fixture!(opts: [prompt: "visible task"])

      {:ok, _view, html} = live(conn, ~p"/tasks")

      # The old info message should NOT appear — the full UI always renders.
      refute html =~ "Task history is only available when viewing the local node"
      assert html =~ "Search by task ID, prompt, objective, or response"
    end
  end

  describe "async page load" do
    test "async page load populates the task list", %{conn: conn} do
      insert_fixture!(opts: [prompt: "async visible task"])

      {:ok, view, html} = live(conn, ~p"/tasks")

      # Deterministic: the async load task cannot apply its result before the
      # initial render, so the loading placeholder is what live/2 returns.
      assert html =~ "Loading tasks..."
      refute html =~ "async visible task"

      html = flush_tasks_load(view)

      assert html =~ "async visible task"
      assert html =~ "1 task found"
      assert html =~ "Page 1 of 1"
    end

    test "stale page-load result is dropped", %{conn: conn} do
      insert_fixture!(opts: [prompt: "real visible task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      stale_task = %TaskInfo{
        id: "stale_id",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/stale", prompt: "STALE MARKER TASK"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      # Old seq (0 < tasks_load_seq): dropped by the seq stale-guard.
      send(
        view.pid,
        {:tasks_page_loaded, 0, node(),
         {:ok,
          %{
            tasks: [stale_task],
            current_page: 1,
            total_count: 1,
            total_pages: 1,
            project_paths: []
          }}}
      )

      html = render(view)
      refute html =~ "STALE MARKER TASK"
      assert html =~ "real visible task"

      # Wrong node with a high seq: dropped by the node stale-guard.
      send(
        view.pid,
        {:tasks_page_loaded, 999, :other@host,
         {:ok,
          %{
            tasks: [stale_task],
            current_page: 1,
            total_count: 1,
            total_pages: 1,
            project_paths: []
          }}}
      )

      html = render(view)
      refute html =~ "STALE MARKER TASK"
      assert html =~ "real visible task"
    end

    test "a task_updated broadcast triggers a debounced reload", %{conn: conn} do
      insert_fixture!(opts: [prompt: "event visible task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # A task seeded AFTER the initial page load is only visible after a reload.
      insert_fixture!(opts: [prompt: "event-added task"])

      # New-shape event from the local node: NodeAware's node filter matches,
      # so the 300ms debounced reload is scheduled.
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, "t1", :running, node()})

      # Phase 1: the event is processed and the debounce is scheduled.
      wait_until(fn ->
        state = :sys.get_state(view.pid)
        state.socket.assigns[:tasks_reload_pending] == true
      end)

      # Phase 2: the debounce fires and the full reload re-renders the page.
      wait_until(fn ->
        state = :sys.get_state(view.pid)
        state.socket.assigns[:tasks_reload_pending] == false
      end)

      html = render(view)
      assert html =~ "event visible task"
      assert html =~ "event-added task"
    end

    test "a foreign-node task_updated broadcast does not trigger a reload", %{conn: conn} do
      insert_fixture!(opts: [prompt: "event visible task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # A task seeded after the initial load would only render if a reload
      # wrongly fired.
      insert_fixture!(opts: [prompt: "foreign marker task"])

      # Event from a DIFFERENT BEAM node: the node filter must drop it BEFORE
      # the debounce is scheduled.
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, "t1", :running, :remote@elsewhere}
      )

      # Sample across the 300ms debounce window (10ms cadence): the
      # reload-pending flag must never become true.
      deadline = System.monotonic_time(:millisecond) + 400

      check_no_reload = fn check_no_reload ->
        state = :sys.get_state(view.pid)
        assert state.socket.assigns[:tasks_reload_pending] == false

        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          check_no_reload.(check_no_reload)
        end
      end

      check_no_reload.(check_no_reload)

      html = render(view)
      assert html =~ "event visible task"
      refute html =~ "foreign marker task"
    end

    test "a task_deleted broadcast triggers a debounced reload", %{conn: conn} do
      insert_fixture!(opts: [prompt: "delete visible task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # Seed + remove a task directly in the store, then broadcast its deletion
      # — the debounced reload must re-read the store and drop the row.
      id = insert_fixture!(opts: [prompt: "delete me task"])
      EvoGit.Store.delete_task(EvoGit.Store, id)

      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_deleted, id, node()})

      # Phase 1: the event is processed and the debounce is scheduled.
      wait_until(fn ->
        state = :sys.get_state(view.pid)
        state.socket.assigns[:tasks_reload_pending] == true
      end)

      # Phase 2: the debounce fires and the full reload re-renders the page.
      wait_until(fn ->
        state = :sys.get_state(view.pid)
        state.socket.assigns[:tasks_reload_pending] == false
      end)

      html = render(view)
      assert html =~ "delete visible task"
      refute html =~ "delete me task"
    end
  end

  describe "cancelling status display" do
    test "renders the Cancelling label with a warning pulsing dot", %{conn: conn} do
      insert_fixture!(status: :cancelling, finished_at: nil, opts: [prompt: "cancelling task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      assert html =~ "cancelling task"
      # Badge label — gettext("Cancelling…") uses a U+2026 ellipsis; assert the
      # stable prefix plus the warning pulsing-dot indicator classes
      # (cancelling shares the transitional warning family via
      # Helpers.task_status_dot_class/1).
      assert html =~ "Cancelling"
      assert html =~ "bg-warning"
    end

    test "status filter includes a cancelling option and filters to cancelling tasks", %{
      conn: conn
    } do
      insert_fixture!(status: :cancelling, finished_at: nil, opts: [prompt: "cancelling one"])
      insert_fixture!(status: :completed, opts: [prompt: "completed one"])

      {:ok, view, html} = live(conn, ~p"/tasks")

      # The filter <select> offers the :cancelling status with the gettext label.
      # (The option body renders with newline indentation around the label.)
      assert html =~ ~r/<option value="cancelling"[^>]*>\s*Cancelling\s*<\/option>/

      _filtered = render_hook(view, "filter_tasks", %{"status_filter" => "cancelling"})
      filtered = flush_tasks_load(view)

      assert filtered =~ "cancelling one"
      refute filtered =~ "completed one"
    end
  end

  describe "review button" do
    test "renders a Review button for a cancelled task with a branch result", %{conn: conn} do
      id =
        insert_fixture!(
          status: :cancelled,
          result:
            {:ok,
             %{
               branch_name: "evogit/cancelled-branch",
               commit_sha: "deadbeef",
               result: "summary"
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      assert html =~ ~s(href="/review/#{id}")
      assert html =~ "Review"
    end

    test "renders a Review button for a cancelled task with a no_changes result", %{conn: conn} do
      id = insert_fixture!(status: :cancelled, result: {:ok, %{no_changes: true}})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      assert html =~ ~s(href="/review/#{id}")
      assert html =~ "Review"
    end

    test "does not render a Review button for failed, cancelling, running, or pending tasks", %{
      conn: conn
    } do
      # The failed task uses the force-killed shape: result nil.
      insert_fixture!(status: :failed, result: nil, opts: [prompt: "failed one"])
      insert_fixture!(status: :cancelling, finished_at: nil, opts: [prompt: "cancelling one"])
      insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running one"])
      insert_fixture!(status: :pending, finished_at: nil, opts: [prompt: "pending one"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # No task card may link to the review page.
      refute html =~ ~r{href="/review/"}
    end
  end

  describe "cancel task action" do
    test "Cancel button renders only for pending and running tasks", %{conn: conn} do
      pending_id =
        insert_fixture!(status: :pending, finished_at: nil, opts: [prompt: "pending one"])

      running_id =
        insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running one"])

      completed_id = insert_fixture!(status: :completed, opts: [prompt: "completed one"])
      cancelled_id = insert_fixture!(status: :cancelled, opts: [prompt: "cancelled one"])

      cancelling_id =
        insert_fixture!(status: :cancelling, finished_at: nil, opts: [prompt: "cancelling one"])

      finalizing_id =
        insert_fixture!(status: :finalizing, finished_at: nil, opts: [prompt: "finalizing one"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      cancel_buttons =
        html
        |> then(&Regex.scan(~r/<button[^>]*phx-click="open_cancel_modal"[^>]*>/, &1))
        |> List.flatten()

      # The visibility guard is @task.status in [:pending, :running] — exactly
      # two cancel buttons (one per in-flight fixture), none for terminal states.
      assert length(cancel_buttons) == 2
      assert Enum.any?(cancel_buttons, &(&1 =~ pending_id))
      assert Enum.any?(cancel_buttons, &(&1 =~ running_id))
      refute Enum.any?(cancel_buttons, &(&1 =~ completed_id))
      refute Enum.any?(cancel_buttons, &(&1 =~ cancelled_id))
      refute Enum.any?(cancel_buttons, &(&1 =~ cancelling_id))
      refute Enum.any?(cancel_buttons, &(&1 =~ finalizing_id))
    end

    test "open_cancel_modal shows the confirmation modal", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "open_cancel_modal", %{"task_id" => id})

      assert html =~ "Cancel Task?"

      assert html =~
               "All agents of this task will be informed to immediately save their changes and exit. Intermediate results will be saved."

      assert html =~ "Keep Running"
    end

    test "close_cancel_modal closes the modal without changing the store", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "open_cancel_modal", %{"task_id" => id})
      assert html =~ "Cancel Task?"

      html = render_click(view, "close_cancel_modal", %{})
      refute html =~ "Cancel Task?"

      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :running
    end

    test "confirm_cancel_task on a pending task marks it cancelled immediately", %{conn: conn} do
      id = insert_fixture!(status: :pending, finished_at: nil, opts: [prompt: "pending task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_click(view, "open_cancel_modal", %{"task_id" => id})
      render_click(view, "confirm_cancel_task", %{})

      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :cancelled
    end

    test "confirm_cancel_task on a running task transitions it to :cancelling", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_click(view, "open_cancel_modal", %{"task_id" => id})
      render_click(view, "confirm_cancel_task", %{})

      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :cancelling
    end

    test "confirm_cancel_task on a completed task flashes an error", %{conn: conn} do
      id = insert_fixture!(status: :completed, opts: [prompt: "completed task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_click(view, "open_cancel_modal", %{"task_id" => id})
      html = render_click(view, "confirm_cancel_task", %{})

      assert html =~ "Failed to cancel task"
    end

    test "confirm_cancel_task without opening the modal is a no-op", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_click(view, "confirm_cancel_task", %{})

      assert html =~ "running task"
      refute html =~ "Failed to cancel task"
      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :running
    end
  end

  describe "force kill action" do
    test "dropdown menu is always present; force kill item only for running/cancelling", %{
      conn: conn
    } do
      running_id =
        insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running one"])

      cancelling_id =
        insert_fixture!(status: :cancelling, finished_at: nil, opts: [prompt: "cancelling one"])

      completed_id = insert_fixture!(status: :completed, opts: [prompt: "completed one"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # The three-dot dropdown <ul> menu is always in the DOM (CSS-hidden).
      assert html =~ "menu menu-sm dropdown-content"

      force_kill_buttons =
        html
        |> then(&Regex.scan(~r/<button[^>]*phx-click="open_force_kill_modal"[^>]*>/, &1))
        |> List.flatten()

      # Force kill item renders for :running and :cancelling only; the "Danger
      # zone" divider ships in the same conditional block.
      assert length(force_kill_buttons) == 2
      assert Enum.any?(force_kill_buttons, &(&1 =~ running_id))
      assert Enum.any?(force_kill_buttons, &(&1 =~ cancelling_id))
      refute Enum.any?(force_kill_buttons, &(&1 =~ completed_id))
      assert html =~ "Danger zone"
      assert html =~ "Force kill"

      # The existing Delete item keeps its phx-click + phx-confirm wiring.
      assert html =~ ~s(phx-click="delete_task")
      assert html =~ ~s(phx-confirm="Delete this task?")
    end

    test "open_force_kill_modal shows the confirmation modal", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "open_force_kill_modal", %{"task_id" => id})

      assert html =~ "Force Kill Task?"
      assert html =~ "ALL progress will be completely lost. This cannot be undone."
      assert html =~ "Force Kill"
    end

    test "close_force_kill_modal closes the modal without changing the store", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "open_force_kill_modal", %{"task_id" => id})
      assert html =~ "Force Kill Task?"

      html = render_click(view, "close_force_kill_modal", %{})
      refute html =~ "Force Kill Task?"

      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :running
    end

    test "confirm_force_kill_task on a store-only running task flashes an error", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_click(view, "open_force_kill_modal", %{"task_id" => id})
      html = render_click(view, "confirm_force_kill_task", %{})

      # NEW wording ("Failed to force kill task: %{reason}") — a sibling lib
      # change not yet merged into this worktree. This single assertion may fail
      # locally until that change lands; it must NOT be weakened to the old
      # shared msgid ("Failed to cancel task: ...").
      assert html =~ "Failed to force kill task"
    end

    test "confirm_force_kill_task on an owned running task force-kills the wrapper", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      wrapper = spawn(fn -> Process.sleep(:infinity) end)

      # Inject the wrapper into the registry's in-memory task_refs so the
      # force-kill path sees an owned, alive task — store-only fixtures have no
      # task_refs entry and return {:error, :not_running}. The replace_state fun
      # runs inside the TaskRegistry process, so self() here IS the owner that
      # Task.shutdown/2 later validates against.
      :sys.replace_state(EvoGit.TaskRegistry, fn state ->
        task_ref = %Task{pid: wrapper, ref: make_ref(), owner: self(), mfa: nil}

        %{state | task_refs: Map.put(state.task_refs, id, task_ref)}
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_click(view, "open_force_kill_modal", %{"task_id" => id})
      render_click(view, "confirm_force_kill_task", %{})

      # Backend contract: force kill ⇒ :failed with result nil. The evo_git
      # persistence change lands in a parallel workstream, so this assertion
      # may fail until then — do NOT revert it.
      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :failed
      refute Process.alive?(wrapper)
    end

    test "confirm_force_kill_task without opening the modal is a no-op", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_click(view, "confirm_force_kill_task", %{})

      assert html =~ "running task"
      refute html =~ "Failed to force kill task"
      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :running
    end
  end

  describe "task detail view" do
    # Long objective/result fixtures: the old detail view truncated the
    # objective at 300 chars server-side; the flattened view renders the full
    # text in a scrollable container, so the tail marker must appear.
    test "expanded card renders the flattened Objective and Agent Message cards", %{conn: conn} do
      long_objective =
        "Build a web app. " <>
          String.duplicate("more words here ", 30) <> " OBJECTIVE TAIL MARKER"

      long_result =
        "The agent finished the work. " <>
          String.duplicate("more words here ", 30) <> " RESULT TAIL MARKER"

      id =
        insert_fixture!(
          opts: [prompt: long_objective, mode: "simple", path: "/tmp/test"],
          result:
            {:ok,
             %{
               result: long_result,
               commit_sha: "abc1234",
               branch_name: "genesis/agent_1",
               tag: "v1.0.0",
               pr_url: "https://example.com/pr"
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_hook(view, "toggle_task_details", %{"task_id" => id})

      # Flattened structure: "Objective" and "Agent Message" are direct h4 card
      # headers. The old nested "Options"/"Result" card headers are gone —
      # scoped to <h4> so the plain "Result"/"Options" words inside the
      # `<!-- Full Result Modal -->` / `<!-- Full Options Modal -->` HTML
      # comments (which HEEx emits verbatim) can't false-positive.
      h4_headers = h4_header_texts(html)
      assert "Objective" in h4_headers
      assert "Agent Message" in h4_headers
      refute "Options" in h4_headers
      refute "Result" in h4_headers

      # The full objective text renders (beyond the old 300-char truncation) in
      # a scrollable container.
      assert html =~ "OBJECTIVE TAIL MARKER"
      assert html =~ "max-h-48"
      assert html =~ "overflow-y-auto"

      # Objective card: copy + Full buttons, with the full text in data-content.
      assert html =~ ~s(phx-click="view_full_options")
      assert attribute(html, "#task-#{id}-objective-copy", "phx-hook") == ["ClipboardCopy"]
      assert data_content(html, "#task-#{id}-objective-copy") =~ "OBJECTIVE TAIL MARKER"

      # Agent Message card: copy + Full buttons, with the full result text in
      # data-content.
      assert html =~ ~s(phx-click="view_full_result")
      assert attribute(html, "#task-#{id}-result-copy", "phx-hook") == ["ClipboardCopy"]
      assert data_content(html, "#task-#{id}-result-copy") =~ "RESULT TAIL MARKER"

      # Result badges are preserved: branch, commit, tag, and PR link.
      assert html =~ "genesis/agent_1"
      assert html =~ "abc1234"
      assert html =~ "v1.0.0"
      assert html =~ "View PR"
      assert html =~ ~s(href="https://example.com/pr")

      # Mode/path badges render in the Objective card body.
      assert html =~ "simple"
      assert html =~ "/tmp/test"

      # Toggling again collapses the detail cards.
      collapsed = render_hook(view, "toggle_task_details", %{"task_id" => id})
      refute collapsed =~ "Agent Message"
    end

    test "error result renders the Error state and an inspected copy payload", %{conn: conn} do
      id = insert_fixture!(result: {:error, "explosion happened"})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_hook(view, "toggle_task_details", %{"task_id" => id})

      assert html =~ "Agent Message"
      assert html =~ "Error"
      assert html =~ "explosion happened"

      # result_copy_text({:error, reason}) inspects the reason, so the copy
      # payload is the quoted string "explosion happened" (Floki may or may not
      # decode the &quot; entities — assert the stable substring).
      assert data_content(html, "#task-#{id}-result-copy") =~ "explosion happened"
    end

    test "no-changes result renders the No Changes notice", %{conn: conn} do
      id = insert_fixture!(result: {:ok, %{no_changes: true, result: "nothing to do"}})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_hook(view, "toggle_task_details", %{"task_id" => id})

      assert html =~ "Agent Message"
      assert html =~ "No Changes"
      assert html =~ "The agent completed without making any changes to the codebase."
      assert html =~ "nothing to do"
      assert data_content(html, "#task-#{id}-result-copy") == "nothing to do"
    end

    test "view_full_result opens the zoomed Task Result modal with a copy button", %{conn: conn} do
      long_result = "The agent finished the work. " <> String.duplicate("more words here ", 30)
      id = insert_fixture!(result: {:ok, %{result: long_result}})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_hook(view, "toggle_task_details", %{"task_id" => id})
      assert html =~ "Agent Message"

      html = render_hook(view, "view_full_result", %{"task_id" => id})

      assert html =~ "Task Result"
      assert attribute(html, "#full-result-copy", "phx-hook") == ["ClipboardCopy"]
      assert data_content(html, "#full-result-copy") == long_result
    end

    test "view_full_options opens the zoomed Full Objective modal with a copy button", %{
      conn: conn
    } do
      long_objective =
        "Build a web app. " <>
          String.duplicate("more words here ", 30) <> " OBJECTIVE TAIL MARKER"

      id = insert_fixture!(opts: [prompt: long_objective])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "toggle_task_details", %{"task_id" => id})

      html = render_hook(view, "view_full_options", %{"task_id" => id})

      assert html =~ "Full Objective"
      assert attribute(html, "#full-options-copy", "phx-hook") == ["ClipboardCopy"]
      assert data_content(html, "#full-options-copy") == long_objective
    end

    test "copied event flashes the confirmation message", %{conn: conn} do
      insert_fixture!(opts: [prompt: "some objective"], result: {:ok, %{result: "some result"}})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_hook(view, "copied", %{})

      assert html =~ "Copied to clipboard"
    end
  end

  describe "task result repos dimension" do
    # Multi-repo results carry a top-level `repos` map (STRING keys):
    # `%{repo_id => %{"commit_sha" => sha, "branch_name" => branch | nil}}` —
    # `"primary"` ALWAYS present (branch_name nil when the primary produced no
    # changes), writable foreign repos with commits present, read-only repos
    # absent. Legacy results have NO `repos` key and must render unchanged.
    # The Store Codec keeps the top-level `repos` key STRING-keyed after the
    # round trip (unknown result keys are never atomized), so fixtures pass
    # through the same shape the core produces.
    test "collapsed card shows the compact per-repo indicator", %{conn: conn} do
      insert_fixture!(
        result:
          {:ok,
           %{
             result: "multi-repo work done",
             commit_sha: "aaaaaaa1111111",
             branch_name: "genesis/agent_1",
             repos: %{
               "primary" => %{commit_sha: "aaaaaaa1111111", branch_name: "genesis/agent_1"},
               "legacy-api" => %{commit_sha: "bbbbbbb2222222", branch_name: "genesis/agent_1"},
               "readme-tools" => %{commit_sha: "ccccccc3333333", branch_name: "genesis/agent_1"}
             }
           }}
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # Collapsed indicator: repo ids + short SHAs (first 7 chars) visible
      # without expanding.
      assert html =~ "legacy-api:"
      assert html =~ "readme-tools:"
      assert html =~ "aaaaaaa"
      assert html =~ "bbbbbbb"
      assert html =~ "ccccccc"
    end

    test "expanded card renders the per-repo Repositories section", %{conn: conn} do
      id =
        insert_fixture!(
          result:
            {:ok,
             %{
               result: "multi-repo work done",
               commit_sha: "aaaaaaa1111111",
               branch_name: "genesis/agent_1",
               repos: %{
                 "primary" => %{commit_sha: "aaaaaaa1111111", branch_name: "genesis/agent_1"},
                 "legacy-api" => %{commit_sha: "bbbbbbb2222222", branch_name: "genesis/agent_1"},
                 "readme-tools" => %{commit_sha: "ccccccc3333333", branch_name: "genesis/agent_1"}
               }
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_hook(view, "toggle_task_details", %{"task_id" => id})

      assert html =~ "Repositories"
      assert html =~ "legacy-api:"
      assert html =~ "readme-tools:"
      assert html =~ "aaaaaaa"
      assert html =~ "bbbbbbb"
      assert html =~ "ccccccc"
      assert html =~ "genesis/agent_1"
    end

    test "full-result modal renders the per-repo Repositories section", %{conn: conn} do
      id =
        insert_fixture!(
          result:
            {:ok,
             %{
               result: "multi-repo work done",
               commit_sha: "aaaaaaa1111111",
               branch_name: "genesis/agent_1",
               repos: %{
                 "primary" => %{commit_sha: "aaaaaaa1111111", branch_name: "genesis/agent_1"},
                 "legacy-api" => %{commit_sha: "bbbbbbb2222222", branch_name: "genesis/agent_1"}
               }
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_hook(view, "view_full_result", %{"task_id" => id})

      assert html =~ "Task Result"
      assert html =~ "Repositories"
      assert html =~ "legacy-api:"
      assert html =~ "aaaaaaa"
      assert html =~ "bbbbbbb"
    end

    test "legacy task without repos renders exactly as before", %{conn: conn} do
      id =
        insert_fixture!(
          result:
            {:ok,
             %{
               result: "legacy summary",
               commit_sha: "abc1234",
               branch_name: "genesis/agent_old"
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # No per-repo indicator on the collapsed card.
      refute html =~ "Repositories"

      html = render_hook(view, "toggle_task_details", %{"task_id" => id})

      # Existing badges/behavior unchanged.
      assert html =~ "Agent Message"
      assert html =~ "legacy summary"
      assert html =~ "abc1234"
      assert html =~ "genesis/agent_old"
      refute html =~ "Repositories"
    end

    test "repos with a nil primary branch (no changes) renders gracefully", %{conn: conn} do
      id =
        insert_fixture!(
          result:
            {:ok,
             %{
               result: "nothing to do",
               no_changes: true,
               commit_sha: "aaaaaaa1111111",
               branch_name: nil,
               repos: %{
                 "primary" => %{commit_sha: "aaaaaaa1111111", branch_name: nil},
                 "legacy-api" => %{commit_sha: "bbbbbbb2222222", branch_name: "genesis/agent_1"}
               }
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_hook(view, "toggle_task_details", %{"task_id" => id})

      # The No Changes notice still renders (primary had no commits)…
      assert html =~ "No Changes"
      assert html =~ "nothing to do"

      # …and the Repositories section shows the primary short sha with a muted
      # "no changes" hint plus the foreign repo's branch.
      assert html =~ "Repositories"
      assert html =~ "aaaaaaa"
      assert html =~ "no changes"
      assert html =~ "legacy-api:"
      assert html =~ "bbbbbbb"
      assert html =~ "genesis/agent_1"
    end
  end

  # --- task detail view helpers ---

  # Extracts the first matching element's attribute (Floki), mirroring the
  # helper in project_components_test.exs.
  defp attribute(html, selector, attr) do
    [el] = Floki.find(Floki.parse_document!(html), selector)
    el |> Floki.attribute(attr) |> Enum.map(&to_string/1)
  end

  # Returns the data-content attribute of the first matching element.
  defp data_content(html, selector) do
    [value] = attribute(html, selector, "data-content")
    value
  end

  # The trimmed text of every <h4> on the page — used to pin the flattened
  # card headers ("Objective"/"Agent Message") and refute the old nested
  # "Options"/"Result" card headers.
  defp h4_header_texts(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("h4")
    |> Enum.map(fn el -> Floki.text(el) |> String.trim() end)
  end
end
