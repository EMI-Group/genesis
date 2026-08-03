defmodule EvoDashWeb.SimpleLive.ReviewsTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoGit.TaskInfo
  alias EvoGit.TaskRegistry

  # Neutralize any pre-existing pending reviews so the empty-state test is
  # deterministic, restoring them afterwards.
  setup do
    :ok
  end

  defp insert_completed_task!(id, prompt) do
    task = %TaskInfo{
      id: id,
      type: :genesis,
      status: :completed,
      opts: [path: "/tmp/demo", prompt: prompt],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      logs: [],
      result:
        {:ok,
         %{
           commit_sha: "abc123",
           branch_name: "evogit/#{id}",
           result: "summary",
           pr_url: nil,
           pr_title: nil
         }},
      review_status: :open,
      branch_name: "evogit/#{id}"
    }

    EvoGit.Store.put_task(EvoGit.Store, task)

    on_exit(fn ->
      try do
        TaskRegistry.delete_task(id)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    task
  end

  test "empty state when nothing is pending", %{conn: conn} do
    # Temporarily mark pre-existing pending reviews as reviewed; restore after
    for task <- EvoDashWeb.SimpleLive.Reviews.pending() do
      TaskRegistry.set_review_status(task.id, :ignored)
      on_exit(fn -> TaskRegistry.set_review_status(task.id, :open) end)
    end

    {:ok, view, _html} = live(conn, ~p"/tree/review")

    assert has_element?(view, "#reviews-back")
    assert render(view) =~ "No pending reviews."
  end

  test "lists all pending review tasks, not just the latest", %{conn: conn} do
    id1 = "review_fixture_#{System.unique_integer([:positive])}"
    id2 = "review_fixture_#{System.unique_integer([:positive])}"
    insert_completed_task!(id1, "第一个演示任务")
    insert_completed_task!(id2, "第二个演示任务")

    {:ok, view, html} = live(conn, ~p"/tree/review")

    assert html =~ "第一个演示任务"
    assert html =~ "第二个演示任务"
    assert has_element?(view, "#review-item-#{id1}")
    assert has_element?(view, "#review-item-#{id2}")
  end
end
