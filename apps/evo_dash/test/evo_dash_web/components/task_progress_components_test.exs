defmodule EvoDashWeb.TaskProgressComponentsTest do
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "renders task outcomes and blockers, rather than an agent counter" do
    html =
      render_component(&EvoDashWeb.TaskProgressComponents.progress/1,
        id: "task-progress-demo",
        status: :running,
        report: %{
          "summary" => "Backend ready; integrating UI",
          "updated_at" => "2026-11-08T12:00:00Z",
          "current_work" => ["Workspace picker"],
          "completed" => ["Shared tool catalog"],
          "remaining" => ["Page tests"],
          "blockers" => ["Need fixture"],
          "next_steps" => ["Run tests"]
        }
      )

    assert html =~ "Shared tool catalog"
    assert html =~ "Workspace picker"
    assert html =~ "Need fixture"
    assert html =~ "Page tests"
    assert html =~ "Run tests"
  end

  test "unknown progress is explicit and terminal states never imply ongoing work" do
    html =
      render_component(&EvoDashWeb.TaskProgressComponents.progress/1,
        id: "task-progress-empty",
        report: nil,
        status: :running
      )

    assert html =~ "No progress reported yet"

    receipt_only =
      render_component(&EvoDashWeb.TaskProgressComponents.progress/1,
        id: "receipt-only",
        report: %{"messages" => [%{"state" => "queued"}]},
        status: :running
      )

    assert receipt_only =~ "No progress reported yet"

    html =
      render_component(&EvoDashWeb.TaskProgressComponents.progress/1,
        id: "task-progress-stopped",
        report: %{"current_work" => ["Editing"]},
        status: :cancelled
      )

    assert html =~ "Last reported work"
    refute html =~ ">Current work<"
  end
end
