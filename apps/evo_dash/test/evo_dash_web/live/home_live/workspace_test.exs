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
    project = legacy_project()

    restored =
      %{workspace: project, assistant_conversation_id: 123}
      |> ChatState.build()
      |> ChatState.restore()

    # A persisted selection restores in the CURRENT shape: a legacy map without
    # :kind/:point is a plain path-keyed PROJECT selection.
    assert restored.workspace == normalized_project()
    assert restored.assistant_conversation_id == 123
    assert Workspace.restore(project, {nil, node()}) == normalized_project()
    assert Workspace.restore(project, {"another-node", node()}) == nil
    assert Workspace.restore(project, {nil, :remote@host}) == nil
    assert Workspace.restore(project, {nil, :remote@host}) == nil
    assert Workspace.normalize(%{path: "relative", node: node()}) == nil
    assert Workspace.normalize(%{path: "/tmp", node: nil}) == nil
  end

  test "a persisted selection keeps its VCT point and reports unresolved members" do
    point = "vct:///projects/tracked-#{System.unique_integer([:positive])}"

    selection = %{
      kind: :workspace,
      point: "vct:///workspaces/group",
      path: "/tmp/member",
      name: "group",
      node: node(),
      node_id: nil,
      members: [%{point: point, path: "/tmp/member", name: "member"}],
      missing: [%{"point" => "vct:///projects/gone"}]
    }

    assert Workspace.normalize(selection) ==
             Map.put(selection, :missing, [%{point: "vct:///projects/gone", path: nil}])

    # The draft token is the WORKSPACE point, never the member's execution path.
    assert Workspace.draft_token(selection) == "vct:///workspaces/group"
    # A project with no point falls back to the raw path token (legacy identity).
    assert Workspace.draft_token(normalized_project()) == "/tmp/project"

    pointed = %{
      kind: :project,
      point: point,
      path: "/tmp/project",
      name: "project",
      node: node(),
      node_id: nil,
      members: [],
      missing: []
    }

    assert Workspace.draft_token(pointed) == point
    assert Workspace.normalize(%{pointed | kind: nil}) == pointed
    assert Workspace.normalize(%{pointed | kind: nil, point: nil}).kind == :project
  end

  test "a workbench draft re-settles onto the resolved point and keeps its legacy spelling" do
    point = "vct:///projects/settled-#{System.unique_integer([:positive])}"
    draft = "123456789012345678901234"
    key = {nil, node(), "/tmp/project", draft}

    selection = %{
      kind: :project,
      point: point,
      path: "/tmp/project",
      name: "project",
      node: node(),
      node_id: nil,
      members: [],
      missing: []
    }

    settled = {nil, node(), point, draft}

    assert Workspace.settle_workbench_key(%{workbench_draft_key: key}, selection) ==
             {settled, [key]}

    # Already settled: the key stays, and the path spelling is still searched so
    # a draft stored before the re-key is adopted instead of orphaned.
    assert Workspace.settle_workbench_key(%{workbench_draft_key: settled}, selection) ==
             {settled, [key]}

    # A DIFFERENT project never re-scopes an open workbench tab.
    other = %{selection | point: "vct:///projects/other", path: "/tmp/other"}
    assert Workspace.settle_workbench_key(%{workbench_draft_key: key}, other) == {key, []}
    assert Workspace.settle_workbench_key(%{workbench_draft_key: nil}, selection) == {nil, []}

    # The param a re-keyed tab receives is still the PATH: it addresses the tab.
    assert Workspace.open_tab?(
             %{workbench_draft_key: settled, workspace: selection},
             "/tmp/project",
             draft
           )

    assert Workspace.open_tab?(
             %{workbench_draft_key: settled, workspace: selection},
             point,
             draft
           )

    refute Workspace.open_tab?(
             %{workbench_draft_key: settled, workspace: selection},
             "/tmp/project",
             "999999999999999999999999"
           )

    refute Workspace.open_tab?(
             %{workbench_draft_key: settled, workspace: selection},
             "/tmp/other",
             draft
           )

    # The workbench link label stays an OS path in every case.
    assert Workspace.draft_project(%{workbench_draft_key: settled, workspace: selection}) ==
             "/tmp/project"

    assert Workspace.draft_project(%{workbench_draft_key: settled, workspace: nil}) == nil
    assert Workspace.draft_project(%{workbench_draft_key: key, workspace: nil}) == "/tmp/project"
    assert Workspace.draft_scope(%{workbench_draft_key: settled}) == point
    assert Workspace.draft_scope(%{workbench_draft_key: nil}) == nil
  end

  test "a pending remote target never opens a directory on the local node" do
    assert {:error, _} = Workspace.open("pending-node", node(), System.tmp_dir!())
    assert {:error, _} = Workspace.list("pending-node", node())
    assert {:error, _} = Workspace.open(nil, node(), "relative-path")
  end

  test "closing the picker is idempotent and never a toggle" do
    project = normalized_project()
    open = socket(%{workspace: project, workspace_open: true, workspace_error: "unavailable"})

    closed = Workspace.close(open)

    assert closed.assigns.workspace_open == false
    # Closing is VISIBILITY only: the selection, the draft and the inline error
    # survive, and no project list is reloaded.
    assert closed.assigns.workspace == project
    assert closed.assigns.chat_draft == "keep this"
    assert closed.assigns.workspace_error == "unavailable"
    assert closed.assigns.workspace_loading == open.assigns.workspace_loading
    # A click-away or Escape while the panel is already closed does nothing —
    # which is exactly why it is not `workspace_toggle` (the panel stays
    # mounted for its exit, so its window keydown fires while it is closed).
    assert Workspace.close(closed) == closed
    assert Workspace.close(closed).assigns.workspace_open == false
  end

  test "running replies lock project clearing and selection" do
    project = normalized_project()
    socket = socket(%{workspace: project, chat_status: :running, workspace_loading: false})
    assert Workspace.clear(socket).assigns.workspace == project
    assert Workspace.select(socket, "/tmp/another").assigns.workspace == project
    assert Workspace.select(socket, "/tmp/another").assigns.workspace_loading == false
  end

  test "late project results cannot overwrite another node, conversation, request or running turn" do
    project = normalized_project()
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

  # A selection persisted by an older page: no :kind, no :point.
  defp legacy_project,
    do: %{path: "/tmp/project", node: node(), node_id: nil, name: "project"}

  defp normalized_project,
    do: Map.merge(legacy_project(), %{kind: :project, point: nil, members: [], missing: []})
end
