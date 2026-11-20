defmodule EvoDashWeb.HomeLive.TaskEvents do
  @moduledoc """
  TASK / AGENT BROADCASTS and the chat task's terminal control for
  `EvoDashWeb.HomeLive`.
  The page is push-based: node-filtered `"tasks"` and `"agents"` broadcasts are
  the only change feed, and every handler here is a pure fold into the socket.
    * `task_updated/2` / `task_deleted/2` — node-filtered, then the chat task's
      own lifecycle (`handle_task_event/4`): an interactive session folds the
      session phases and keeps a pending/failed watch's display ownership, the
      one-shot `:reflect` path fetches the terminal task row instead;
    * `agent_registered/2` / `agent_updated/2` / `agents_updated/2` — the chat
      agent id, the message-count gating and the queued-echo reconciliation; a
      WATCHED session is never refetched on a message-count change (that refetch
      IS the poll the delta stream removes);
    * `node_aware_reload_tasks/1` — the shared debounced sidebar reload;
    * the CHAT CONTROL results — `cancel_chat_task/1` (graceful cancel),
      `stop_reply/1` (`{:chat_stop_result, …}`) and `finish_chat/4`
      (`{:chat_finish_result, …}`), each tagged with its own monotonic
      generation plus the identity it was issued for, so a superseded answer is
      DROPPED rather than mutating a different chat;
    * the assistant task-tracking / task-picker results, which are thin
      delegations to their own modules.
  Extracted verbatim: `EvoDash.SafeCall` stays the exit-safe boundary, no call
  blocks the LiveView process, and every gettext string is unchanged.
  """
  use Gettext, backend: EvoDashWeb.Gettext
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]
  alias EvoDash.{NodeContext, SafeCall}
  alias EvoDashWeb.LiveHooks.NodeAware

  alias EvoDashWeb.HomeLive.{
    AgentStream,
    ApprovalDialogState,
    AttachPipeline,
    ChatBootstrap,
    ChatState,
    SendPath,
    StreamFold,
    TaskPicker,
    TaskTracking,
    Watch
  }

  @terminal_statuses [:completed, :cancelled, :failed]

  ## Task broadcasts ------------------------------------------------------

  def task_updated(socket, {:task_updated, task_id, status, node}) do
    {:noreply, socket} =
      NodeAware.handle_task_info(socket, {:task_updated, task_id, status, node})

    socket = handle_task_event(socket, task_id, status, node)

    socket =
      if NodeAware.event_from_current_node?(socket.assigns, node),
        do: TaskTracking.refresh(socket),
        else: socket

    {:noreply, socket}
  end

  def task_deleted(socket, {:task_deleted, task_id, node}) do
    {:noreply, socket} = NodeAware.handle_task_info(socket, {:task_deleted, task_id, node})
    {:noreply, handle_task_deleted(socket, task_id, node)}
  end

  def agent_registered(socket, {:agent_registered, id, summary, node}) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         Map.get(summary, :task_id) == socket.assigns[:chat_task_id] do
      socket =
        assign(socket,
          chat_agent_id: id,
          agent_message_count: AgentStream.message_count(summary)
        )

      socket =
        if Watch.stream_active?(socket) do
          ChatState.persist(socket)
        else
          socket |> ChatState.persist() |> AttachPipeline.async_fetch_history()
        end

      {:noreply, ApprovalDialogState.maybe_recover_approvals(socket)}
    else
      {:noreply, socket}
    end
  end

  def agent_updated(socket, {:agent_updated, id, changed_fields, node}) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         id == socket.assigns[:chat_agent_id] and
         is_list(changed_fields) and Keyword.has_key?(changed_fields, :message_count) do
      socket =
        if SendPath.message_count_grew?(socket, changed_fields),
          do: drop_echoes(socket),
          else: socket

      # A WATCHED session is driven by its delta stream: refetching the whole
      # history per message-count change IS the poll this feature removes.
      socket =
        if Watch.stream_active?(socket) do
          ChatState.persist(socket)
        else
          AttachPipeline.async_fetch_history(socket)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def agent_removed(socket, {:agent_removed, _id, _node}), do: {:noreply, socket}

  def agents_updated(socket, {:agents_updated, node}) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         socket.assigns[:chat_task_id] != nil and socket.assigns[:chat_agent_id] == nil do
      {:noreply, AttachPipeline.async_lookup_agent(socket)}
    else
      {:noreply, socket}
    end
  end

  def node_aware_reload_tasks(socket) do
    # The sidebar Conversations load for THIS event is owned by
    # `EvoDashWeb.LiveHooks.NodeAware` (its `{:cont, socket}` already spawns the
    # same node's `SessionList` load), so the page must not ask a second time.
    socket =
      socket
      |> NodeAware.reload_tasks()
      |> NodeAware.clear_task_reload_pending()

    {:noreply, socket}
  end

  ## Chat task lifecycle --------------------------------------------------

  defp handle_task_event(socket, task_id, status, node) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         task_id == socket.assigns[:chat_task_id] do
      if ChatBootstrap.interactive_session?(socket) do
        session_task_event(socket, status)
      else
        one_shot_task_event(socket, status)
      end
    else
      socket
    end
  end

  defp session_task_event(socket, status) do
    socket =
      cond do
        Watch.closed?(socket) ->
          socket

        status in @terminal_statuses ->
          socket =
            socket
            |> assign(chat_task_status: status, chat_status: :ended, queued_echoes: [])
            |> StreamFold.finalize_bubble()

          # Pending and failed watches still own the surface. Detaching here
          # invalidates the silent finish's final snapshot (or loses a finish
          # still in flight); keep cached text if that snapshot is unavailable.
          if Watch.stream_active?(socket) do
            socket
          else
            socket
            |> Watch.detach()
            |> AttachPipeline.async_fetch_history(socket.assigns[:chat_node])
          end

        status == :cancelling ->
          # No more text is coming, but the session is still alive: finalize the
          # bubble and KEEP the watcher.
          socket
          |> assign(chat_task_status: :cancelling, chat_status: :cancelling)
          |> StreamFold.finalize_bubble()

        status in [:running, :pending, :finalizing] ->
          assign(socket, chat_task_status: status)

        true ->
          socket
      end

    ChatState.persist(socket)
  end

  defp one_shot_task_event(socket, status) do
    socket =
      case status do
        :completed ->
          AttachPipeline.async_fetch_task(assign(socket, chat_task_status: :completed))

        :cancelled ->
          AttachPipeline.async_fetch_task(assign(socket, chat_task_status: :cancelled))

        :failed ->
          socket
          |> assign(chat_task_status: :failed)
          |> SendPath.finalize_streaming(gettext("The task failed."))
          |> SendPath.clear_task_refs()

        :running ->
          socket = assign(socket, chat_task_status: :running)

          if socket.assigns[:chat_agent_id] == nil do
            AttachPipeline.async_lookup_agent(socket)
          else
            socket
          end

        :cancelling ->
          assign(socket, chat_task_status: :cancelling, chat_status: :cancelling)

        :pending ->
          assign(socket, chat_task_status: :pending)

        :finalizing ->
          assign(socket, chat_task_status: :finalizing)

        _ ->
          socket
      end

    ChatState.persist(socket)
  end

  defp handle_task_deleted(socket, task_id, node) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         task_id == socket.assigns[:chat_task_id] do
      if ChatBootstrap.interactive_session?(socket) do
        socket
        |> assign(
          chat_task_id: nil,
          chat_task_status: nil,
          chat_status: :ended,
          queued_echoes: []
        )
        |> ChatState.persist()
      else
        socket
        |> SendPath.finalize_streaming(gettext("The conversation was deleted."))
        |> SendPath.clear_task_refs()
        |> ChatState.persist()
      end
    else
      socket
    end
  end

  ## Chat control (stop / cancel / terminal task read) --------------------

  def chat_task_loaded(socket, {:chat_task_loaded, node, seq, task_id, task}) do
    if Watch.closed?(socket) or node != socket.assigns[:current_node] or
         seq != socket.assigns[:chat_task_fetch_seq] or
         task_id != socket.assigns[:chat_task_id] do
      {:noreply, socket}
    else
      {:noreply, SendPath.finalize_terminal(socket, task)}
    end
  end

  # The async stop / cancel answers. Each result carries its own monotonic
  # generation plus the identity it was issued for, so a superseded answer is
  # DROPPED instead of mutating a different chat.
  def chat_stop_result(socket, {{:chat_stop_result, seq, node, session_id}, result}) do
    socket =
      if ChatBootstrap.stale_control?(socket, seq, node) or
           session_id != socket.assigns[:session_id] do
        socket
      else
        case result do
          {:ok, :ok} ->
            put_flash(
              socket,
              :info,
              gettext("Stopping this reply. Background development tasks continue.")
            )

          {:ok, {:error, reason}} ->
            stop_flash(socket, reason)

          {:error, reason} ->
            stop_flash(socket, reason)

          _other ->
            socket
        end
      end

    {:noreply, socket}
  end

  def chat_finish_result(
        socket,
        {{:chat_finish_result, seq, node, task_id, assigns, reload?}, result}
      ) do
    socket =
      if ChatBootstrap.stale_control?(socket, seq, node) or
           task_id != socket.assigns[:chat_task_id] do
        socket
      else
        case result do
          {:ok, {:error, reason}} -> stop_flash(socket, reason)
          {:error, reason} -> stop_flash(socket, reason)
          {:ok, _ok} -> stop_ok(socket, assigns, reload?)
          _other -> socket
        end
      end

    {:noreply, socket}
  end

  @doc "Gracefully cancels the chat task's in-flight work."
  def cancel_chat_task(socket) do
    node = socket.assigns[:current_node] || node()

    finish_chat(
      socket,
      fn -> NodeContext.cancel_task(node, socket.assigns[:chat_task_id]) end,
      [chat_status: :cancelling, chat_task_status: :cancelling, queued_echoes: []],
      false
    )
  end

  @doc "Stops the current interactive turn (the session keeps its task)."
  def stop_reply(socket) do
    target = socket.assigns[:current_node] || node()
    session_id = socket.assigns[:session_id]
    seq = socket.assigns[:stop_seq] + 1

    runner =
      Application.get_env(:evo_dash, :home_session_stop_runner, &NodeContext.stop_current_turn/2)

    socket = assign(socket, stop_seq: seq)

    # ASYNC: the node answers through `{:chat_stop_result, …}`, so a busy or
    # remote node no longer freezes the page mid-stop.
    case SafeCall.start(self(), {:chat_stop_result, seq, target, session_id}, fn ->
           runner.(target, session_id)
         end) do
      {:ok, _pid} -> {:noreply, socket}
      {:error, reason} -> {:noreply, stop_flash(socket, reason)}
    end
  end

  defp finish_chat(socket, fun, assigns, reload?) do
    target = socket.assigns[:current_node] || node()
    task_id = socket.assigns[:chat_task_id]
    seq = socket.assigns[:stop_seq] + 1

    socket = assign(socket, stop_seq: seq)

    # ASYNC, same contract as `stop_reply/1`: the success mutation and the
    # `reload?` decision ride the tagged result so they apply to the socket as
    # it is when the answer lands (never to a stale captured one).
    case SafeCall.start(
           self(),
           {:chat_finish_result, seq, target, task_id, assigns, reload?},
           fun
         ) do
      {:ok, _pid} -> {:noreply, socket}
      {:error, reason} -> {:noreply, stop_flash(socket, reason)}
    end
  end

  defp stop_ok(socket, assigns, reload?) do
    socket = assign(socket, assigns)
    socket = if reload?, do: AttachPipeline.maybe_load_sessions(socket), else: socket
    ChatState.persist(socket)
  end

  # Justification: transport/exit reasons are untrusted terms, inspected for the operator.
  defp stop_flash(socket, reason) do
    put_flash(socket, :error, gettext("Failed to stop: %{reason}", reason: inspect(reason)))
  end

  defp drop_echoes(socket), do: assign(socket, queued_echoes: [])

  ## Assistant task tracking / picker results ----------------------------

  def assistant_action_reconcile(socket, {:assistant_action_reconcile, scope}),
    do: {:noreply, TaskTracking.reconcile(socket, scope)}

  def assistant_action_status(socket, {{:assistant_action_status, scope, id}, result}),
    do: {:noreply, TaskTracking.reconcile_result(socket, scope, id, result)}

  def assistant_follow_result(socket, {{:assistant_follow_result, scope}, result}),
    do: {:noreply, TaskTracking.follow_result(socket, scope, result)}

  def assistant_task_choices(socket, {{:assistant_task_choices, seq, scope, offset}, result}),
    do: {:noreply, TaskPicker.apply_result(socket, seq, scope, offset, result)}

  def assistant_tasks_tick(socket, :assistant_tasks_tick),
    do: {:noreply, TaskTracking.refresh(socket)}

  def assistant_tasks_loaded(socket, {{:assistant_tasks_loaded, seq, scope}, result}),
    do: {:noreply, TaskTracking.apply_result(socket, seq, scope, result)}

  def assistant_task_action(socket, {{:assistant_task_action, scope, id}, result}),
    do: {:noreply, TaskTracking.correlated_result(socket, scope, id, result)}
end
