defmodule EvoDashWeb.TasksLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoDash.TaskRegistry
  alias EvoDash.TaskRegistry.TaskInfo

  setup do
    # Terminate the production registry to prevent automatic restarts and
    # to use an isolated DETS table for the test.
    case Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.TaskRegistry) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    unique = System.unique_integer([:positive])
    data_dir = Path.join(System.tmp_dir!(), "evogit_test_tasks_live_#{unique}")
    File.mkdir_p!(data_dir)

    {:ok, _pid} =
      start_supervised(
        {TaskRegistry,
         name: EvoDash.TaskRegistry,
         dets_tasks: :test_tasks_live_dets,
         dets_projects: :test_tasks_live_projects_dets,
         data_dir: data_dir}
      )

    on_exit(fn ->
      File.rm_rf(data_dir)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
    end)

    :ok
  end

  # Inserts a task directly into the registry's DETS table (bypasses the async
  # task spawn that `start_task/2` triggers). This lets us create deterministic
  # fixture tasks for search/filter assertions.
  defp insert_fixture!(overrides) do
    id = "fixture_#{System.unique_integer([:positive])}"

    task = %TaskInfo{
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

    :dets.insert(:test_tasks_live_dets, {id, task})
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
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_status, "test-finalizing", :finalizing})

      # render/1 flushes pending messages synchronously; a crash would propagate here.
      html = render(view)
      assert is_binary(html)
      assert html =~ "Task History"
    end

    test "handle_info catch-all does not crash on unknown messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # An arbitrary message the LiveView doesn't specifically handle should be
      # swallowed by the catch-all clause rather than crashing.
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:some_unexpected_event, 42})

      html = render(view)
      assert is_binary(html)
      assert html =~ "Task History"
    end
  end
end
