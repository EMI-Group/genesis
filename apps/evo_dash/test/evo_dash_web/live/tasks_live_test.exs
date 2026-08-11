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

      html = render_hook(view, "filter_tasks", %{"status_filter" => "failed"})

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
      assert html =~ "Search by task ID, prompt, or objective"
    end

    test ":remote_poll on the local node does not crash and stops polling", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # On the local node (current_node == node()) the poll handler takes the
      # stop branch and sets :remote_poll_timer to false. No timer is
      # scheduled for the local node, so nothing leaks. A crash in the
      # handler would propagate through render/1.
      send(view.pid, :remote_poll)
      html = render(view)

      assert is_binary(html)
      assert html =~ "All Statuses"

      # The stop branch disables the poll timer. This LiveViewTest version
      # exposes no assigns accessor on the View struct, so read the LiveView
      # GenServer's socket state directly.
      state = :sys.get_state(view.pid)
      assert state.socket.assigns[:remote_poll_timer] == false
    end
  end

  describe "cancelling status display" do
    test "renders the Cancelling label with a violet pulsing dot", %{conn: conn} do
      insert_fixture!(status: :cancelling, finished_at: nil, opts: [prompt: "cancelling task"])

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "cancelling task"
      # Badge label — gettext("Cancelling…") uses a U+2026 ellipsis; assert the
      # stable prefix plus the violet pulsing-dot indicator classes.
      assert html =~ "Cancelling"
      assert html =~ "bg-violet-500"
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

      filtered = render_hook(view, "filter_tasks", %{"status_filter" => "cancelling"})

      assert filtered =~ "cancelling one"
      refute filtered =~ "completed one"
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

      {:ok, _view, html} = live(conn, ~p"/tasks")

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

      {:ok, _view, html} = live(conn, ~p"/tasks")

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

      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :cancelled
      refute Process.alive?(wrapper)
    end

    test "confirm_force_kill_task without opening the modal is a no-op", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "confirm_force_kill_task", %{})

      assert html =~ "running task"
      refute html =~ "Failed to force kill task"
      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :running
    end
  end
end
