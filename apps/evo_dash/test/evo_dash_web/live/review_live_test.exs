defmodule EvoDashWeb.ReviewLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoDash.TaskRegistry
  alias EvoDash.TaskRegistry.TaskInfo

  describe "review for non-existent task" do
    test "shows error for non-existent task id", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/review/nonexistent-task-id")

      assert html =~ "Review Not Available"
      assert html =~ "Task not found"
    end

    test "renders back to dashboard link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/review/nonexistent-task-id")

      assert html =~ "Back to Dashboard"
      assert html =~ "href=\"/\""
    end
  end

  describe "ignore action" do
    setup do
      task_id = "review_test_ignore_#{System.unique_integer([:positive])}"

      # A completed task whose result references a branch that does NOT exist in
      # any real repository (repo_path points nowhere). This simulates an
      # orphaned/merged/deleted branch — the exact scenario the Ignore escape
      # hatch is designed for.
      task = %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :completed,
        opts: [path: "/nonexistent/repo/path", objective: "Test objective"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        review_status: nil,
        result:
          {:ok,
           %{
             commit_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
             branch_name: "evogit/test-branch",
             result: "Agent summary",
             pr_url: nil,
             pr_title: nil
           }}
      }

      EvoDash.TaskStore.put_task(EvoDash.TaskStore, task)

      on_exit(fn ->
        TaskRegistry.delete_task(task_id)
        # Synchronize the deletion cast.
        TaskRegistry.list_tasks()
      end)

      {:ok, task_id: task_id}
    end

    test "ignore button is always shown, even when branch does not exist", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, _view, html} = live(conn, ~p"/review/#{task_id}")

      # The Ignore button is rendered (phx-click="ignore") regardless of
      # whether the branch exists.
      assert html =~ ~s(phx-click="ignore")
      assert html =~ "Ignore"
    end

    test "clicking ignore sets review status and navigates to dashboard", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      # Click the ignore button — this triggers a navigation, so we assert the
      # LiveView process terminates and the browser is redirected to "/".
      view |> element("button[phx-click='ignore']") |> render_click()

      assert_redirect(view, "/")

      # The cast runs async, but a synchronous get_task call guarantees all
      # prior casts to the registry have been processed.
      assert TaskRegistry.get_task(task_id).review_status == :ignored
    end
  end
end
