defmodule EvoDashWeb.HomeLive.TaskTrackingTest do
  use ExUnit.Case, async: true
  alias EvoDashWeb.HomeLive.TaskTracking

  test "known status is preserved without inventing progress on refresh failure" do
    row = TaskTracking.project(%{id: "a", status: "completed", project_path: "/project"}, true)
    assert row.status == "completed"
    assert row.path == "/project"
    assert row.error
    refute row.has_result
    assert row.updated_at == nil
  end

  test "saved result visibility comes from the authoritative snapshot" do
    row =
      TaskTracking.project(
        %{
          id: "a",
          status: "completed",
          progress: %{observed_at: "now", saved_state: %{has_result: true}}
        },
        false
      )

    assert row.has_result
    assert row.updated_at == "now"
    refute row.error
  end

  test "node and conversation determine the projection scope" do
    assert TaskTracking.scope(%{assistant_conversation_id: 3, chat_id: 8}) == {node(), 3}
    assert TaskTracking.scope(%{current_node: :remote, chat_id: 8}) == {:remote, 8}
  end

  test "a late operation status cannot settle a newer request" do
    scope = {node(), 7}

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        chat_id: 7,
        task_action_ids: %{scope => "new"},
        task_action_pending: MapSet.new([scope])
      }
    }

    assert TaskTracking.reconcile_result(socket, scope, "old", {:ok, {:done, {:ok, %{}}}}) ==
             socket
  end

  test "pending remote node never queries the local runtime" do
    assert TaskTracking.scope(%{current_node_id: "remote", current_node: node(), chat_id: 7}) ==
             {:unavailable, 7}

    assert TaskTracking.load({:unavailable, 7}) == {:error, :not_connected}
  end

  test "a failed follow in another conversation cannot change this page" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, chat_id: 7}}
    assert TaskTracking.follow_result(socket, {node(), 8}, {:error, :disconnected}) == socket
  end

  test "an uncertain action in another conversation cannot replace this page's feedback" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, chat_id: 7}}
    assert TaskTracking.action_result(socket, {node(), 8}, {:error, :disconnected}) == socket
  end

  test "an operation absent after reconnect releases the UI latch" do
    target = {node(), 17}

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        chat_id: 17,
        task_action_ids: %{target => "missing"},
        task_action_pending: MapSet.new([target])
      }
    }

    result = TaskTracking.reconcile_result(socket, target, "missing", {:ok, {:error, :not_found}})
    refute MapSet.member?(result.assigns.task_action_pending, target)
  end
end
