defmodule EvoDashWeb.HomeLive.SessionResolution do
  @moduledoc """
  URL → CONVERSATION resolution for `EvoDashWeb.HomeLive`.
  `run/2` is the whole `handle_params/3` pipeline the page delegates to: the
  node context is resolved first (`NodeAware.assign_node/2`), the chat scope is
  attached, a node/chat-scope move starts a NEW chat, the canonical model
  selection is restored, and then `?session=` / `?wb_draft=` decide WHICH
  conversation this tab shows before the source-gate check, the approval
  recovery and the task-tracking refresh run.
  The resolution itself lives here:
    * `?session=<id>` — parse, same-id short-circuit, reattach from the cached
      `EvoDash.ChatHistory` conversation or attach to the live session
      (`resolve_session/3`, `reattach_session/2`, `attach_interactive_session/3`);
      a MISSING session param leaves the session (`leave_session/1`);
    * `?wb_project=&wb_draft=` — the workbench tab draft, which starts
      PATH-keyed and re-settles onto the VCT point of the mounted project
      (`open_workbench_draft/2`, `adopt_workbench_scope/1`), carrying an
      unsaved draft or an older one-shot chat across the re-key.
  Extracted verbatim: every assign, ordering guarantee and short-circuit is the
  one the page module had. The attach loaders it starts belong to
  `EvoDashWeb.HomeLive.AttachPipeline`, the delta stream to
  `EvoDashWeb.HomeLive.StreamFold`.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: EvoDashWeb.Endpoint,
    router: EvoDashWeb.Router,
    statics: EvoDashWeb.static_paths()

  alias EvoDash.ChatHistory
  alias EvoDashWeb.LiveHooks.NodeAware

  alias EvoDashWeb.HomeLive.{
    ApprovalDialogState,
    ApprovalWorkflow,
    AttachPipeline,
    Attachments,
    ChatBootstrap,
    ChatState,
    ModelSelection,
    SessionActions,
    StreamFold,
    TaskPicker,
    TaskTracking,
    Uploads,
    WorkbenchScope,
    Workspace
  }

  @doc """
  The `handle_params/3` pipeline: node context, chat scope, model selection and
  the `?session=` / `?wb_draft=` conversation resolution.
  """
  def run(socket, params) do
    prev_node = socket.assigns[:current_node]
    prev_node_id = socket.assigns[:current_node_id]

    socket =
      socket
      |> NodeAware.assign_node(params, preserve_unresolved?: true)
      |> ChatBootstrap.attach_chat(params)

    node_changed =
      socket.assigns.model_selection_resolved and
        (socket.assigns[:current_node] != prev_node or
           socket.assigns[:current_node_id] != prev_node_id)

    chat_node_mismatch =
      socket.assigns[:chat_node] != nil and
        socket.assigns[:chat_node] != socket.assigns[:current_node]

    scope = ModelSelection.selection_scope(socket)
    saved_selection = socket.assigns.model_selection_restore || socket.assigns

    saved_scope =
      if is_map(saved_selection), do: Map.get(saved_selection, :model_selection_scope)

    selection_scope_mismatch = not is_nil(saved_scope) and saved_scope != scope

    socket =
      socket
      |> assign(ChatState.restore_selection(saved_selection, scope))
      |> assign(model_selection_restore: nil, model_selection_resolved: true)

    socket =
      cond do
        node_changed or chat_node_mismatch or selection_scope_mismatch ->
          ChatBootstrap.start_new_chat(socket)

        true ->
          socket
      end

    socket
    |> resolve_session(params["session"], params)
    |> restore_workspace_scope(scope)
    |> open_workbench_draft(params)
    |> adopt_workbench_scope()
    |> ChatState.persist()
    |> ModelSelection.assign_model_select()
    |> assign(
      current_path: ~p"/assistant",
      workbench_reconnect_params: Map.take(params, ~w(session wb_project wb_draft))
    )
    |> WorkbenchScope.maybe_check_source()
    |> ApprovalDialogState.maybe_recover_approvals()
    |> TaskTracking.refresh()
  end

  ## Session identity -----------------------------------------------------

  def resolve_session(socket, param, params) do
    case ModelSelection.pending_remote?(socket) do
      true -> socket
      false -> resolve_session_on_node(socket, param, params)
    end
  end

  defp resolve_session_on_node(socket, param, params) do
    case SessionActions.parse_session(param) do
      {:ok, id} ->
        if id == socket.assigns[:current_session_id],
          do: socket,
          else: reattach_session(socket, id)

      :none
      when is_map_key(params, "wb_draft") and not is_nil(socket.assigns.current_session_id) ->
        ChatBootstrap.new_workbench_draft(socket)

      :none ->
        leave_session(socket)
    end
  end

  defp reattach_session(socket, id) do
    state = cached_conversation(socket, id)

    case state do
      %{session_mode: :one_shot} ->
        socket
        |> ChatBootstrap.reset_chat()
        |> ChatBootstrap.restore_chat(id, state)
        |> assign(current_session_id: id, workbench_draft_key: state[:workbench_draft_key])
        |> assign(ChatState.restore_selection(state, ModelSelection.selection_scope(socket)))

      _ ->
        attach_interactive_session(socket, id, ChatState.restore(state))
    end
  end

  defp cached_conversation(socket, id) do
    if connected?(socket) do
      target = socket.assigns.current_node

      case ChatHistory.get_state(id) do
        %{chat_node: ^target} = state ->
          state

        state when is_map(state) and target == node() ->
          if is_nil(state[:chat_node]), do: state

        _ ->
          nil
      end
    end
  end

  defp attach_interactive_session(socket, id, restored) do
    socket = socket |> Uploads.cancel_all() |> TaskPicker.reset()

    socket
    |> assign(
      session_id: id,
      current_session_id: id,
      chat_id: id,
      session_mode: :interactive,
      workbench_draft: nil,
      workbench_draft_key: nil,
      chat_agent_id: id,
      chat_node: socket.assigns[:current_node],
      chat_task_id: nil,
      chat_task_status: nil,
      agent_message_count: nil,
      queued_echoes: [],
      task_action_ids: restored.task_action_ids,
      task_action_pending: restored.task_action_pending,
      workspace: Workspace.restore(restored[:workspace], Workspace.scope(socket.assigns)),
      assistant_conversation_id: restored[:assistant_conversation_id] || id,
      workspace_open: false,
      workspace_loading: false,
      workspace_error: nil,
      workspace_seq: socket.assigns.workspace_seq + 1,
      thought_process: restored.thought_process,
      raw_entry_ids: MapSet.new(),
      pending_attachments: Attachments.clear(),
      chat_draft: restored.chat_draft,
      draft_edited?: false,
      transcript: restored.transcript,
      chat_status: ChatBootstrap.restore_status(restored.chat_status)
    )
    |> assign(ChatState.restore_selection(restored, ModelSelection.selection_scope(socket)))
    |> ApprovalWorkflow.init()
    |> AttachPipeline.spawn_attach(id)
    |> StreamFold.attach_stream()
  end

  defp leave_session(socket) do
    if is_nil(socket.assigns[:current_session_id]) do
      socket
    else
      socket
      |> ChatBootstrap.reset_chat()
      |> assign(workbench_draft: nil, workbench_draft_key: nil)
      |> ChatBootstrap.attach_default_chat()
      |> assign(
        session_id: nil,
        current_session_id: nil,
        session_mode: nil,
        queued_echoes: [],
        pending_attachments: Attachments.clear()
      )
      |> ChatState.persist()
    end
  end

  defp restore_workspace_scope(socket, scope) do
    assign(socket, workspace: Workspace.restore(socket.assigns[:workspace], scope))
  end

  ## Workbench draft scope ------------------------------------------------

  def open_workbench_draft(socket, %{"wb_draft" => draft, "wb_project" => project})
      when is_binary(draft) and byte_size(draft) == 24 and is_binary(project) do
    {node_id, target} = Workspace.scope(socket.assigns)
    key = {node_id, target, project, draft}

    cond do
      socket.assigns[:current_session_id] != nil ->
        socket

      Workspace.open_tab?(socket.assigns, project, draft) ->
        socket

      !connected?(socket) or (node_id && target == node()) ->
        socket

      true ->
        existing = ChatHistory.get_draft({:workbench, key}) || one_shot_workbench_chat(key)

        socket =
          case existing do
            %{chat_id: id} = state ->
              socket
              |> ChatBootstrap.reset_chat()
              |> ChatBootstrap.restore_chat(id, state)
              |> assign(
                ChatState.restore_selection(state, ModelSelection.selection_scope(socket))
              )

            nil ->
              socket |> ChatBootstrap.new_workbench_draft() |> assign(workspace: nil)
          end

        workspace = Workspace.restore(socket.assigns[:workspace], {node_id, target})

        socket
        |> assign(workbench_draft: draft, workbench_draft_key: key, workspace: workspace)
        |> Workspace.select_mounted((workspace && workspace.path) || project)
    end
  end

  def open_workbench_draft(socket, _), do: socket

  # Adoption: once the mount resolves, the SAME workbench tab moves from its
  # path spelling onto the VCT-point scope, carrying whatever the legacy
  # spelling already stored (an unsaved draft OR an older one-shot chat) so a
  # re-key never orphans work. A chat that already owns a session, or a
  # streaming turn, is never re-keyed.
  def adopt_workbench_scope(socket) do
    {settled, legacy_keys} =
      Workspace.settle_workbench_key(socket.assigns, socket.assigns[:workspace])

    cond do
      is_nil(settled) -> socket
      is_nil(socket.assigns[:workspace]) -> socket
      socket.assigns[:current_session_id] != nil -> socket
      socket.assigns[:chat_status] in [:running, :cancelling] -> socket
      true -> adopt_workbench_draft(socket, settled, legacy_keys)
    end
  end

  defp adopt_workbench_draft(socket, settled, legacy_keys) do
    keys = Enum.uniq([settled | legacy_keys])

    case find_workbench_chat(keys) do
      %{chat_id: id} = state ->
        socket
        |> ChatBootstrap.reset_chat()
        |> ChatBootstrap.restore_chat(id, state)
        |> assign(workbench_draft_key: settled)
        |> assign(ChatState.restore_selection(state, ModelSelection.selection_scope(socket)))
        |> ChatState.persist()
        |> forget_workbench_drafts(legacy_keys)

      nil ->
        socket
        |> move_workbench_draft(keys, settled)
        |> assign(workbench_draft_key: settled)
    end
  end

  # A draft adopted onto the VCT point identity must not ALSO linger under its
  # retired raw-path spelling, or the workbench link would resurrect a twin.
  defp forget_workbench_drafts(socket, keys) do
    Enum.each(keys, &ChatHistory.delete_draft({:workbench, &1}))
    socket
  end

  defp find_workbench_chat(keys) do
    Enum.find_value(keys, &ChatHistory.get_draft({:workbench, &1})) ||
      Enum.find_value(keys, &one_shot_workbench_chat/1)
  end

  # An unsaved draft keeps its text: it is MOVED onto the settled key and the
  # abandoned spellings are dropped so no second restore can find a stale copy.
  defp move_workbench_draft(socket, keys, settled) do
    case ChatHistory.get_draft({:workbench, settled}) do
      nil ->
        case Enum.find_value(keys, &ChatHistory.get_draft({:workbench, &1})) do
          nil ->
            socket

          state ->
            ChatHistory.put_draft({:workbench, settled}, state)

            keys
            |> Enum.reject(&(&1 == settled))
            |> Enum.each(&ChatHistory.delete_draft({:workbench, &1}))

            socket
        end

      _existing ->
        socket
    end
  end

  defp one_shot_workbench_chat(key) do
    Enum.find_value(ChatHistory.list_chats(), fn id ->
      case ChatHistory.get_state(id) do
        %{workbench_draft_key: ^key, session_mode: :one_shot} = state ->
          if ChatState.conversation?(state), do: Map.put(state, :chat_id, id)

        _ ->
          nil
      end
    end)
  end

  ## Attach / stream hand-offs -------------------------------------------

  # The workspace context an attach snapshot restores (the conversation id and
  # the project/workspace selection). The attach result folding itself lives in
  # `EvoDashWeb.HomeLive.AttachPipeline`.
  def restore_attached_context(socket, {:ok, %{summary: %{assistant_context: context}}})
      when is_map(context) do
    workspace = Map.get(context, :assistant_workspace, socket.assigns.workspace)

    assign(socket,
      assistant_conversation_id:
        context[:assistant_conversation_id] || socket.assigns.assistant_conversation_id,
      workspace: Workspace.restore(workspace, Workspace.scope(socket.assigns))
    )
  end

  def restore_attached_context(socket, _result), do: socket

  ## Workspace load results ------------------------------------------------

  # A workspace load re-runs the workbench key adoption: the panel that just
  # resolved is what the draft scope settles onto.
  def workspace_loaded(socket, seq, scope, chat_id, kind, result) do
    socket = Workspace.apply_result(socket, seq, scope, chat_id, kind, result)

    {:noreply, if(kind == :list, do: socket, else: adopt_workbench_scope(socket))}
  end
end
