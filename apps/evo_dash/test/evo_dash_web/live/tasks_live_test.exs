defmodule EvoDashWeb.TasksLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoDash.TaskRegistry
  alias EvoDash.TaskInfo

  setup do
    # Terminate production children to prevent auto-restarts and use isolated stores.
    Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
    Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_tasks_live_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({EvoDash.Store, data_dir: sqlite_path})

    start_supervised(
      {TaskRegistry, task_store: EvoDash.Store, data_dir: root, name: EvoDash.TaskRegistry}
    )

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.Store)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
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

    EvoDash.Store.put_task(EvoDash.Store, task)
    id
  end

  describe "task search" do
    test "renders the search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "Search by task ID, prompt, or objective"
    end

    test "search_tasks handler filters tasks by prompt text", %{conn: conn} do
      insert_fixture!(opts: [prompt: "build a web app", path: "/tmp/proj"])
      insert_fixture!(opts: [prompt: "write a database migration", path: "/tmp/proj"])
      insert_fixture!(opts: [prompt: "refactor the auth module", path: "/tmp/proj"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_hook(view, "search_tasks", %{"search_query" => "database"})

      assert html =~ "write a database migration"
      refute html =~ "build a web app"
      refute html =~ "refactor the auth module"
    end

    test "search_tasks handler filters tasks by objective text", %{conn: conn} do
      insert_fixture!(opts: [objective: "fix the login bug"])
      insert_fixture!(opts: [objective: "add dark mode toggle"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_hook(view, "search_tasks", %{"search_query" => "login"})

      assert html =~ "fix the login bug"
      refute html =~ "add dark mode toggle"
    end

    test "search_tasks handler filters tasks by task ID", %{conn: conn} do
      id1 = insert_fixture!(opts: [prompt: "alpha task"])
      insert_fixture!(opts: [prompt: "beta task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_hook(view, "search_tasks", %{"search_query" => id1})

      assert html =~ "alpha task"
      refute html =~ "beta task"
    end

    test "clearing the search query restores all tasks", %{conn: conn} do
      insert_fixture!(opts: [prompt: "alpha task"])
      insert_fixture!(opts: [prompt: "beta task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # First narrow down
      _html = render_hook(view, "search_tasks", %{"search_query" => "alpha"})
      # Then clear
      html = render_hook(view, "search_tasks", %{"search_query" => ""})

      assert html =~ "alpha task"
      assert html =~ "beta task"
    end

    test "search is case-insensitive", %{conn: conn} do
      insert_fixture!(opts: [prompt: "Build a REST API"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_hook(view, "search_tasks", %{"search_query" => "rest api"})

      assert html =~ "Build a REST API"
    end
  end

  describe "filter selects" do
    test "filter_tasks handler filters by status", %{conn: conn} do
      insert_fixture!(status: :completed, opts: [prompt: "completed one"])
      insert_fixture!(status: :failed, opts: [prompt: "failed one"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_hook(view, "filter_tasks", %{"status_filter" => "failed"})

      assert html =~ "failed one"
      refute html =~ "completed one"
    end

    test "filter_tasks handler 'all' shows everything", %{conn: conn} do
      insert_fixture!(status: :completed, opts: [prompt: "completed one"])
      insert_fixture!(status: :failed, opts: [prompt: "failed one"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_hook(view, "filter_tasks", %{"status_filter" => "all"})

      assert html =~ "completed one"
      assert html =~ "failed one"
    end

    test "reset_filters clears all filters including search", %{conn: conn} do
      insert_fixture!(opts: [prompt: "alpha task"])
      insert_fixture!(opts: [prompt: "beta task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Apply a search filter first
      _html = render_hook(view, "search_tasks", %{"search_query" => "alpha"})
      # Then reset
      html = render_click(view, "reset_filters")

      assert html =~ "alpha task"
      assert html =~ "beta task"
    end
  end

  describe ":task_status broadcast handling" do
    # The EvoGit runtime broadcasts {:task_status, task_id, status} on the "tasks"
    # PubSub topic. Before the fix, TasksLive had no clause matching this tuple,
    # so a :finalizing status transition crashed the LiveView. These tests verify
    # the handle_info clauses added by the fix handle these messages gracefully.

    test "handle_info {:task_status, _, :finalizing} does not crash the LiveView", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Broadcast a :finalizing status transition (the message that previously crashed).
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_status, "test-finalizing", :finalizing}
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
    # so tests can assert which page shows what.
    defp insert_timed_fixture!(i) do
      id = "page_fixture_#{System.unique_integer([:positive])}"
      started = ~U[2026-01-01 00:00:00Z] |> DateTime.add(i, :second)

      task = %TaskInfo{
        id: id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test", prompt: "task number #{i}"],
        ref: nil,
        started_at: started,
        finished_at: DateTime.add(started, 1, :second),
        logs: [],
        result: nil
      }

      EvoDash.Store.put_task(EvoDash.Store, task)
      id
    end

    test "page 1 shows first page_size tasks and pagination controls appear", %{conn: conn} do
      # Insert page_size + 1 = 26 tasks to trigger pagination (2 pages).
      for i <- 0..25, do: insert_timed_fixture!(i)

      {:ok, _view, html} = live(conn, ~p"/tasks")

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

      {:ok, _view, html} = live(conn, ~p"/tasks?page=2")

      assert html =~ "Page 2 of 2"

      # Page 2 shows the oldest task (index 0).
      assert html =~ "task number 0"
      # Page 2 should NOT show the newest (index 25).
      refute html =~ "task number 25"
    end

    test "invalid page params clamp and do not crash", %{conn: conn} do
      for i <- 0..25, do: insert_timed_fixture!(i)

      # Non-integer page → defaults to 1.
      {:ok, _view, html_abc} = live(conn, ~p"/tasks?page=abc")
      assert html_abc =~ "Page 1 of 2"

      # Negative page → clamps to 1.
      {:ok, _view, html_neg} = live(conn, ~p"/tasks?page=-1")
      assert html_neg =~ "Page 1 of 2"

      # Out-of-range page → clamps to last page (2).
      {:ok, _view, html_big} = live(conn, ~p"/tasks?page=9999")
      assert html_big =~ "Page 2 of 2"
      assert html_big =~ "task number 0"
    end

    test "next_page / prev_page events navigate correctly", %{conn: conn} do
      for i <- 0..25, do: insert_timed_fixture!(i)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Navigate to page 2 via next_page.
      html_next = render_click(view, "next_page")
      assert html_next =~ "Page 2 of 2"
      assert html_next =~ "task number 0"

      # Navigate back to page 1 via prev_page.
      html_prev = render_click(view, "prev_page")
      assert html_prev =~ "Page 1 of 2"
      assert html_prev =~ "task number 25"
    end

    test "goto_page event navigates to a specific page", %{conn: conn} do
      for i <- 0..25, do: insert_timed_fixture!(i)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "goto_page", %{"page" => "2"})
      assert html =~ "Page 2 of 2"
      assert html =~ "task number 0"
    end
  end
end
