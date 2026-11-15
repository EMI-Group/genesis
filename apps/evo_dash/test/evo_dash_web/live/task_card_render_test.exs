defmodule EvoDashWeb.HomeLive.TaskCardRenderTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias EvoDashWeb.HomeLive.{TaskCard, TaskTracking}

  defp assigns(overrides \\ %{}) do
    Map.merge(
      %{
        current_node: node(),
        current_node_id: nil,
        assistant_conversation_id: 12,
        tracked_tasks: [
          %{
            id: "task-123",
            title: "Implement search",
            status: "running",
            path: "/tmp/project",
            agent_count: 2,
            updated_at: "2026-11-15T08:00:00Z",
            has_result: false,
            error: false
          }
        ],
        task_tracking_error: nil
      },
      overrides
    )
  end

  test "task actions target one observed task and expose its real detail route" do
    html = render_component(&TaskCard.cards/1, assigns())
    html = LazyHTML.from_fragment(html)
    assert LazyHTML.query(html, "#assistant-task-task-123") |> Enum.count() == 1
    assert LazyHTML.query(html, "a[href='/review/task-123']") |> Enum.count() == 1

    assert LazyHTML.query(
             html,
             "#assistant-task-message-task-123 input[name=task_id][value=task-123]"
           )
           |> Enum.count() == 1

    assert LazyHTML.query(
             html,
             "button[phx-click=assistant_task_cancel][phx-value-task_id=task-123]"
           )
           |> Enum.count() == 1
  end

  test "accepted action disables repeated submissions while its result is pending" do
    state = assigns()
    state = Map.put(state, :task_action_pending, MapSet.new([TaskTracking.scope(state)]))
    html = render_component(&TaskCard.cards/1, state) |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, "#assistant-task-message-task-123 button[disabled]")
           |> Enum.count() == 1

    assert LazyHTML.query(html, "button[phx-click=assistant_task_cancel][disabled]")
           |> Enum.count() == 1
  end

  test "terminal task keeps details and result entry while removing mutation controls" do
    state = assigns()
    [task] = state.tracked_tasks

    html =
      render_component(&TaskCard.cards/1, %{
        state
        | tracked_tasks: [%{task | status: "completed", has_result: true}]
      })
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, "#assistant-task-task-123 a[href='/review/task-123']")
           |> Enum.count() == 1

    assert LazyHTML.query(html, "#assistant-task-message-task-123") |> Enum.count() == 0
    assert LazyHTML.query(html, "button[phx-click=assistant_task_cancel]") |> Enum.count() == 0
  end
end
