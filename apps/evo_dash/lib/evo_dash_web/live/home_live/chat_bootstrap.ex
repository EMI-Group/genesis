defmodule EvoDashWeb.HomeLive.ChatBootstrap do
  @moduledoc """
  Chat BOOTSTRAP and chat-scope LIFECYCLE for `EvoDashWeb.HomeLive`.
  Two halves:
    * the bootstrap — `base_assigns/0` (every assign the page owns, with the
      defaults a dead render and a connected mount share) plus `init/1`, the
      connected/dead mount assign chain: the assistant client id, the
      `assign_new` seeds the global on-mount hooks already provide, the
      approval workflow init and the browser-upload setup
      (`handle_upload_progress/3` is the upload progress hook it installs);
    * the chat scope — which `EvoDash.ChatHistory` chat this tab is on
      (`attach_chat/2`, `attach_default_chat/1`, `restore_chat/3`,
      `reconcile_chat/1`), the resets that retire it (`reset_chat/1`,
      `start_new_chat/1`, `new_workbench_draft/1`) and the identity guards
      every async loader reads (`interactive_session?/1`, `stale?/3`,
      `stale_control?/3`).
  Extracted verbatim from the LiveView module so the page module stays a
  router + template; every assign name, counter and reset rule is unchanged.
  `reconcile_chat/1` borrows three page loaders from
  `EvoDashWeb.HomeLive.AttachPipeline` — they are deliberately NOT copied here.
  """
  import Phoenix.Component, only: [assign: 2, assign_new: 3]
  use Phoenix.VerifiedRoutes,
    endpoint: EvoDashWeb.Endpoint,
    router: EvoDashWeb.Router,
    statics: EvoDashWeb.static_paths()

  import Phoenix.LiveView, only: [connected?: 1, get_connect_params: 1, push_patch: 2]
  alias EvoDash.ChatHistory

  alias EvoDashWeb.HomeLive.{
    AttachPipeline,
    Attachments,
    ApprovalWorkflow,
    ChatState,
    SessionActions,
    TaskPicker,
    TaskTracking,
    Transcript,
    Uploads,
    Watch
  }

  @doc "Every assign the page owns, seeded by `mount/3` before `init/1` runs."
  def base_assigns do
    %{
      workspace: nil,
      assistant_client_id: nil,
      assistant_conversation_id: nil,
      workspace_open: false,
      workspace_path: "",
      workspace_projects: [],
      workspace_workspaces: [],
      workspace_expanded: MapSet.new(),
      workspace_error: nil,
      workspace_loading: false,
      workspace_seq: 0,
      tracked_tasks: [],
      task_tracking_error: nil,
      task_tracking_loading: false,
      task_tracking_seq: 0,
      task_picker: TaskPicker.new(),
      transcript: Transcript.new(),
      chat_draft: "",
      draft_edited?: false,
      chat_status: :idle,
      chat_task_id: nil,
      chat_agent_id: nil,
      agent_message_count: nil,
      chat_task_status: nil,
      thought_process: [],
      chat_node: nil,
      chat_id: nil,
      session_id: nil,
      current_session_id: nil,
      session_mode: nil,
      queued_echoes: [],
      session_attach_seq: 0,
      session_attach_pending?: false,
      # Async send / stop control state. `send_in_flight` blocks a second
      # submit, `send_seq` is the monotonic staleness guard for
      # `{:chat_send_result, seq}` and `send_pending` carries the optimistic
      # send's rollback context; `stop_seq` guards `{:chat_stop_result, …}` and
      # `{:chat_finish_result, …}` the same way.
      send_in_flight: false,
      send_seq: 0,
      send_pending: nil,
      stop_seq: 0,
      # Push-only delta stream state (`EvoDashWeb.HomeLive.Watch`): the
      # subscribed agent + its seeded `%Delta{}` (nil until the registration
      # snapshot lands), that snapshot's turn meta, and the monotonic attach seq.
      chat_stream: nil,
      chat_stream_meta: nil,
      stream_attach_seq: 0,
      chat_stream_worker: nil,
      chat_stream_worker_monitor: nil,
      # `:session_list` / `:session_list_loading` / `:session_list_error` /
      # `:session_list_seq` are seeded (and loaded) by
      # `EvoDashWeb.LiveHooks.NodeAware` — the layout sidebar owns the
      # Conversations section on every page, including this one.
      pending_attachments: Attachments.new(),
      attach_unavailable: false,
      chat_fetch_seq: 0,
      chat_task_fetch_seq: 0,
      selected_model_id: nil,
      raw_entry_ids: MapSet.new(),
      # after handle_params resolves the node, never against mount's local seed.
      approval_context: nil,
      # Purely local view state for the approval review dialog; ApprovalWorkflow
      # owns the requests themselves and never touches these two.
      approval_dialog_open: false,
      approval_dialog_index: 0,
      provider_profiles: [],
      model_selections: [],
      model_spec: nil,
      model_selection_scope: nil,
      model_selection_error: nil,
      model_selection_restore: nil,
      model_selection_resolved: false,
      model_selection_enabled: false,
      model_snapshot: nil,
      model_selection_bundle: nil,
      model_select_loading: false,
      model_select_load_error: nil,
      model_select_seq: 0,
      source_available: nil,
      source_check_loading: false,
      source_check_seq: 0,
      source_busy: nil,
      current_path: ~p"/assistant",
      workbench_draft: nil,
      workbench_draft_key: nil
    }
  end

  @doc """
  Mounts the chat-scope assigns on top of `base_assigns/0`.
  """
  def init(socket) do
    socket
    |> assign(assistant_client_id: assistant_client_id(socket))
    # The node bookkeeping and the accent are seeded by the global
    # on-mount hooks that ran BEFORE this mount; these keep the template's
    # explicit `@remote_targets` / `@connection_statuses` / `@accent_color`
    # reads total even if a hook were skipped.
    |> assign_new(:remote_targets, fn -> [] end)
    |> assign_new(:connection_statuses, fn -> %{} end)
    |> assign_new(:accent_color, fn -> "blue" end)
    |> ApprovalWorkflow.init()
    |> Uploads.init(&__MODULE__.handle_upload_progress/3)
  end

  # The upload progress hook installed by `Uploads.init/2`: the composer's only
  # upload id, forwarded to the uploads helper.
  def handle_upload_progress(:chat_files, entry, socket),
    do: {:noreply, Uploads.progress(entry, socket)}

  @doc "True for a chat backed by a live interactive session."
  def interactive_session?(socket) do
    socket.assigns[:session_mode] == :interactive and not is_nil(socket.assigns[:session_id])
  end

  @doc "An independent (non-watch) chat read is stale when its node/seq moved."
  def stale?(socket, node, seq) do
    node != socket.assigns[:current_node] or seq != socket.assigns[:chat_fetch_seq]
  end

  @doc """
  A stop / cancel answer is stale when a newer control action was issued or
  the viewed node moved out from under it.
  """
  def stale_control?(socket, seq, node) do
    seq != socket.assigns[:stop_seq] or node != (socket.assigns[:current_node] || node())
  end

  # `ChatState.restore/1` already whitelists the stored status; this defensive
  # (tolerated for a foreign/legacy row).
  def restore_status(status)
      when status in [:idle, :running, :cancelling, :awaiting_input, :ended],
      do: status

  def restore_status(_status), do: :idle

  ## Chat scope -----------------------------------------------------------

  # `?wb_project=` carries a PATH (the workbench client's only spelling), so a
  # workbench tab starts PATH-keyed and re-settles onto the VCT point of the
  # project the mount resolves to (`SessionResolution.adopt_workbench_scope/1`).
  def attach_chat(socket, params) do
    if connected?(socket) and is_nil(socket.assigns.chat_id) do
      if params["session"] || params["wb_draft"] do
        new_workbench_draft(socket)
      else
        attach_default_chat(socket)
      end
    else
      socket
    end
  end

  def attach_default_chat(%{assigns: %{assistant_client_id: client}} = socket)
      when is_binary(client) do
    key = ChatState.draft_key(socket.assigns)

    if connected?(socket) do
      case key && ChatHistory.get_draft(key) do
        %{chat_id: id} = state ->
          socket |> restore_chat(id, state) |> assign(model_selection_restore: state)

        _ ->
          start_new_chat(socket)
      end
    else
      socket
    end
  end

  def attach_default_chat(socket) do
    if connected?(socket) do
      id = ChatHistory.current_chat_id() || ChatHistory.new_chat()
      state = ChatHistory.get_state(id) || %{}

      socket
      |> restore_chat(id, state)
      |> assign(model_selection_restore: state)
    else
      socket
    end
  end

  def restore_chat(socket, id, state) do
    socket
    |> assign(ChatState.restore(state))
    |> assign(
      chat_id: id,
      draft_edited?: state[:draft_edited?] == true,
      assistant_conversation_id: state[:assistant_conversation_id] || id
    )
    |> reconcile_chat()
  end

  def reconcile_chat(socket) do
    if socket.assigns[:chat_status] in [:running, :cancelling] and
         socket.assigns[:chat_task_id] != nil do
      socket = AttachPipeline.async_fetch_task(socket, socket.assigns[:chat_node])

      if socket.assigns[:chat_agent_id] != nil do
        AttachPipeline.async_fetch_history(socket, socket.assigns[:chat_node])
      else
        AttachPipeline.async_lookup_agent(socket, socket.assigns[:chat_node])
      end
    else
      socket
    end
  end

  def new_workbench_draft(socket) do
    id = System.unique_integer([:positive])

    socket
    |> reset_chat()
    |> assign(chat_id: id, assistant_conversation_id: id)
  end

  def start_new_chat(socket) do
    socket =
      if connected?(socket) do
        id = standalone_chat_id(socket.assigns.assistant_client_id)
        assign(socket, chat_id: id, assistant_conversation_id: id)
      else
        socket
      end

    socket
    |> reset_chat()
    |> assign(workbench_draft: nil, workbench_draft_key: nil)
    |> ChatState.persist()
    |> TaskTracking.refresh()
  end

  def reset_chat(socket) do
    # Keep the serial registration worker and the generation advanced by detach;
    # older loader results must stay obsolete even after a later chat reset.
    socket
    |> Uploads.cancel_all()
    |> TaskPicker.reset()
    |> Watch.detach()
    |> assign(
      transcript: Transcript.new(),
      chat_draft: "",
      draft_edited?: false,
      chat_status: :idle,
      chat_task_id: nil,
      chat_agent_id: nil,
      agent_message_count: nil,
      chat_task_status: nil,
      thought_process: [],
      chat_node: nil,
      chat_fetch_seq: 0,
      chat_task_fetch_seq: 0,
      raw_entry_ids: MapSet.new(),
      session_id: nil,
      current_session_id: nil,
      session_mode: nil,
      queued_echoes: [],
      pending_attachments: Attachments.clear(),
      approval_context: nil,
      session_attach_pending?: false,
      approval_dialog_open: false,
      approval_dialog_index: 0,
      workspace_open: false,
      workspace_loading: false,
      workspace_error: nil,
      workspace_projects: [],
      workspace_workspaces: [],
      workspace_expanded: MapSet.new(),
      workspace_seq: socket.assigns.workspace_seq + 1,
      # Advance BOTH control generations and drop the in-flight send context, so
      # a result from the previous chat is provably stale and can never re-enable
      # or mutate this one.
      send_in_flight: false,
      send_pending: nil,
      send_seq: socket.assigns.send_seq + 1,
      stop_seq: socket.assigns.stop_seq + 1
    )
    |> ApprovalWorkflow.init()
  end

  def standalone_chat_id(client) when is_binary(client), do: System.unique_integer([:positive])

  def standalone_chat_id(nil) do
    id = ChatHistory.new_chat()
    ChatHistory.prune(10)
    id
  end

  def assistant_client_id(socket) do
    if connected?(socket) do
      case get_connect_params(socket)["guide_client_id"] do
        id when is_binary(id) and byte_size(id) in 1..128 -> id
        _ -> nil
      end
    end
  end

  ## Page-local events ----------------------------------------------------

  def new_chat(socket) do
    if socket.assigns[:chat_status] in [:idle, :ended] do
      had_session? =
        not is_nil(socket.assigns[:current_session_id]) or
          not is_nil(socket.assigns[:workbench_draft])

      if key = ChatState.draft_key(socket.assigns), do: ChatHistory.delete_draft(key)

      socket =
        socket
        |> assign(session_id: nil, current_session_id: nil, session_mode: nil)
        |> start_new_chat()
        |> AttachPipeline.maybe_load_sessions()

      socket =
        if had_session? do
          push_patch(socket, to: SessionActions.url(socket.assigns[:current_node_id], nil))
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def chat_input(socket, %{"message" => text}) do
    {:noreply,
     socket |> assign(chat_draft: text || "") |> ChatState.persist(clear_empty_draft: true)}
  end

  # The raw/Markdown toggle of ONE assistant entry is chat-scope view state:
  # `reset_chat/1` owns (and clears) `raw_entry_ids`, so the toggle lives here.
  def toggle_assistant_raw(socket, %{"id" => id}) when is_binary(id) do
    raw = socket.assigns[:raw_entry_ids] || MapSet.new()

    raw =
      if MapSet.member?(raw, id) do
        MapSet.delete(raw, id)
      else
        MapSet.put(raw, id)
      end

    {:noreply, assign(socket, raw_entry_ids: raw)}
  end

  def toggle_assistant_raw(socket, _params), do: {:noreply, socket}
end
