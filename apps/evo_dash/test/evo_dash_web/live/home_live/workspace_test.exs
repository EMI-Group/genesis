defmodule EvoDashWeb.HomeLive.WorkspaceTest do
  use ExUnit.Case, async: true
  import Phoenix.Component, only: [assign: 2]
  alias EvoDashWeb.HomeLive.{ChatState, Workspace}

  defp socket(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          chat_id: 1,
          current_node_id: nil,
          current_node: node(),
          workspace: nil,
          workspace_open: true,
          workspace_loading: true,
          workspace_seq: 1,
          workspace_error: nil,
          workspace_path: "",
          chat_status: :idle,
          chat_draft: "keep this"
        },
        overrides
      )

    assign(%Phoenix.LiveView.Socket{}, assigns)
  end

  test "persisted workspace belongs to its own node and conversation" do
    project = %{path: "/tmp/project", node: node(), node_id: nil, name: "project"}

    restored =
      %{workspace: project, assistant_conversation_id: 123}
      |> ChatState.build()
      |> ChatState.restore()

    assert restored.workspace == project
    assert restored.assistant_conversation_id == 123
    assert Workspace.restore(project, {nil, node()}) == project
    assert Workspace.restore(project, {"another-node", node()}) == nil
    assert Workspace.restore(project, {nil, :remote@host}) == nil
    assert Workspace.normalize(%{path: "relative", node: node()}) == nil
    assert Workspace.normalize(%{path: "/tmp", node: nil}) == nil
  end

  test "a pending remote target never opens a directory on the local node" do
    assert {:error, _} = Workspace.open("pending-node", node(), System.tmp_dir!())
    assert {:error, _} = Workspace.list("pending-node", node())
    assert {:error, _} = Workspace.open(nil, node(), "relative-path")
  end

  test "running replies lock project clearing and selection" do
    project = %{path: "/tmp/project", node: node(), node_id: nil, name: "project"}
    socket = socket(%{workspace: project, chat_status: :running, workspace_loading: false})
    assert Workspace.clear(socket).assigns.workspace == project
    assert Workspace.select(socket, "/tmp/another").assigns.workspace == project
    assert Workspace.select(socket, "/tmp/another").assigns.workspace_loading == false
  end

  test "late project results cannot overwrite another node, conversation, request or running turn" do
    project = %{path: "/tmp/project", node: node(), node_id: nil, name: "project"}
    result = {:ok, {:ok, project}}
    socket = socket()

    for {seq, scope, chat} <- [
          {0, {nil, node()}, 1},
          {1, {nil, node()}, 2},
          {1, {"remote", node()}, 1}
        ] do
      assert Workspace.apply_result(socket, seq, scope, chat, :open, result) == socket
    end

    running = socket(%{chat_status: :running})

    assert Workspace.apply_result(running, 1, {nil, node()}, 1, :open, result).assigns.workspace ==
             nil

    applied = Workspace.apply_result(socket, 1, {nil, node()}, 1, :open, result)
    assert applied.assigns.workspace == project
    assert applied.assigns.chat_draft == "keep this"
  end
end
