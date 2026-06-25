defmodule EvoDashWeb.ReviewLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

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
end
