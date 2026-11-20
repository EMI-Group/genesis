defmodule EvoDashWeb.HomeLive.SendPath do
  @moduledoc """
  The `/assistant` composer SEND PATH and the one-shot FINALIZE block for
  `EvoDashWeb.HomeLive`, extracted verbatim so the LiveView module stays
  readable.

  Two halves:

    * the send path — `send_chat/2` / `send_draft/3` guards (pending remote
      node, project selection in progress), the interactive-session branch
      (`SessionActions.send_message/5`, with the queue policy of the
      interactive composer) and the one-shot `:reflect` branch
      (`NodeContext.start_task/3` via the session-attach fallback), plus the
      transient queued-echo bookkeeping and the send-failure flash paths;
    * the finalize block — turning a streamed assistant turn / a terminal
      task row into final transcript text and clearing the task refs.

  Everything here keeps the page's contracts untouched: every store/RPC call
  still goes through `EvoDash.SafeCall`, every user-facing string is
  `gettext`-wrapped, and no behaviour is decided here that the LiveView did
  not already decide. The two helpers this module borrows from the page
  (`EvoDashWeb.HomeLive.spawn_attach/2`, `maybe_load_sessions/1`,
  `maybe_recover_approvals/1`, `async_lookup_agent/2`) are public page
  functions — they are deliberately NOT copied here.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]

  alias EvoDash.{NodeContext, SafeCall}

  alias EvoDashWeb.HomeLive.{
    AgentStream,
    ApprovalWorkflow,
    Attachments,
    ChatState,
    ModelSelect,
    ModelSelection,
    SessionActions,
    Transcript,
    TaskTracking
  }

  alias EvoDashWeb.HomeLive

  @terminal_statuses [:completed, :cancelled, :failed]

  # ── Send path ──

  def send_chat(socket, text), do: send_draft(socket, text, :queue)
  # button are disabled in the same state, so this is the defensive backstop for
  def send_draft(socket, text, policy) do
    cond do
      # Server-side backstop mirroring the composer's disabled Send: a refused
      # send, or one whose RPC is still in flight, never double-submits.
      socket.assigns[:send_in_flight] == true ->
        {:noreply, socket}

      ModelSelection.pending_remote?(socket) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Connect to the remote node before sending a message.")
         )}

      socket.assigns[:session_attach_pending?] == true or
          socket.assigns[:workspace_loading] == true ->
        {:noreply,
         put_flash(socket, :error, gettext("Wait for the project selection to finish."))}

      EvoDashWeb.HomeLive.Workspace.missing_draft_project?(socket.assigns) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This project is no longer open on the selected node.")
         )}

      true ->
        do_send_chat(socket, text, policy)
    end
  end

  def do_send_chat(socket, text, policy) do
    text = String.trim(text || "")

    cond do
      not sendable_status?(socket) ->
        # Defensive — the composer disables Send in these states anyway.
        {:noreply, socket}

      socket.assigns[:upload_in_progress] == true ->
        {:noreply, socket}

      text == "" and Attachments.count(socket.assigns[:pending_attachments]) == 0 ->
        {:noreply, socket}

      true ->
        {message, attachments} =
          Attachments.to_message(text, socket.assigns[:pending_attachments])

        opts =
          if is_nil(socket.assigns[:session_id]) do
            [
              mode: "reflect",
              objective: reflect_objective(socket, message),
              attachments: attachments,
              assistant_workspace: socket.assigns[:workspace],
              assistant_conversation_id:
                socket.assigns[:assistant_conversation_id] || socket.assigns[:chat_id]
            ]
          else
            []
          end

        case ModelSelect.task_opts(
               socket.assigns.model_snapshot,
               socket.assigns,
               ModelSelection.selection_scope(socket),
               opts
             ) do
          {:ok, task_opts} ->
            dispatch_send(socket, message, attachments, task_opts, policy)

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, gettext("Choose a valid model before sending a message."))}
        end
    end
  end

  def sendable_status?(socket) do
    if is_nil(socket.assigns[:session_id]) do
      socket.assigns[:chat_status] == :idle
    else
      socket.assigns[:chat_status] in [:idle, :running, :awaiting_input]
    end
  end

  def reflect_objective(socket, text) do
    case Transcript.build_preamble(socket.assigns[:transcript]) do
      {:ok, preamble} -> preamble <> "New message: " <> text
      :empty -> text
    end
  end

  def dispatch_send(socket, text, attachments, task_opts, policy) do
    if is_nil(socket.assigns[:session_id]) do
      start_session_chat(socket, text, attachments, task_opts)
    else
      queue_session_message(socket, text, attachments, policy)
    end
  end

  # and, when the turn is already running, one transient echo (never a second
  # answer bubble).
  #
  # ASYNC + OPTIMISTIC: the user bubble (plus the echo) appears at once and the
  # RPC runs in `EvoDash.TaskSupervisor` (`EvoDash.SafeCall.start/3`), so the
  # LiveView keeps processing deltas and timers while the node answers. The
  # rollback context travels in `send_pending.prev`, so a refused queue send
  # loses neither the draft nor the staged attachments.
  def queue_session_message(socket, text, attachments, policy) do
    node = socket.assigns[:current_node] || node()
    agent_id = socket.assigns[:session_id]
    queued? = socket.assigns[:chat_status] == :running
    seq = (socket.assigns[:send_seq] || 0) + 1
    opts = [assistant_workspace: socket.assigns[:workspace]]

    prev = %{
      transcript: socket.assigns[:transcript],
      chat_draft: socket.assigns[:chat_draft],
      pending_attachments: socket.assigns[:pending_attachments],
      chat_status: socket.assigns[:chat_status],
      queued_echoes: socket.assigns[:queued_echoes]
    }

    transcript =
      Transcript.append(socket.assigns[:transcript], Transcript.entry(:user, text))

    transcript =
      if queued?, do: transcript, else: Transcript.put_streaming_text(transcript, "")

    socket =
      socket
      |> assign(
        transcript: transcript,
        chat_draft: "",
        pending_attachments: Attachments.clear(),
        chat_status: :running,
        send_in_flight: true,
        send_seq: seq,
        send_pending: %{
          kind: :message,
          seq: seq,
          text: text,
          policy: policy,
          queued?: queued?,
          node: node,
          session_id: agent_id,
          prev: prev
        }
      )
      |> ChatState.persist()

    socket = if queued?, do: push_queued_echo(socket, text), else: socket

    case SafeCall.start(self(), {:chat_send_result, seq}, fn ->
           SessionActions.send_message(node, agent_id, text, attachments, policy, opts)
         end) do
      {:ok, _pid} -> {:noreply, socket}
      {:error, reason} -> {:noreply, apply_send_result(socket, seq, {:error, reason})}
    end
  end

  # Settles ONE async send: `result` is the `EvoDash.SafeCall` envelope pushed by
  # `{:chat_send_result, seq}`. A result whose seq no longer owns the slot (a
  # newer send, a chat reset, or a node/session move) is dropped — it may not
  # resurrect a previous chat or leave the composer disabled.
  def apply_send_result(socket, seq, result) do
    case socket.assigns[:send_pending] do
      %{seq: ^seq} = pending ->
        socket = assign(socket, send_in_flight: false, send_pending: nil)

        if send_superseded?(socket, pending),
          do: socket,
          else: dispatch_send_result(socket, pending, result)

      _other ->
        # A newer send owns the slot (or a reset cleared it): never touch it.
        socket
    end
  end

  defp send_superseded?(socket, pending) do
    (socket.assigns[:current_node] || node()) != Map.get(pending, :node) or
      socket.assigns[:session_id] != Map.get(pending, :session_id)
  end

  defp dispatch_send_result(socket, %{kind: :start} = pending, result) do
    case result do
      {:ok, {:ok, agent_id}} ->
        adopt_session(socket, agent_id, pending.text)

      {:ok, {:error, reason}} ->
        start_failure(socket, reason, pending)

      {:error, reason} ->
        start_failure(socket, {:transport, reason}, pending)

      {:ok, other} ->
        start_failure(socket, {:unexpected_start_result, other}, pending)
    end
  end

  defp dispatch_send_result(socket, %{kind: :message} = pending, result) do
    case normalize_send(result) do
      :ok -> send_succeeded(socket, pending)
      {:error, reason} -> send_failure(socket, reason, pending)
    end
  end

  # The accepted send. The user bubble, the reply placeholder and the queued echo
  # were applied optimistically in `queue_session_message/4`, so this only
  # re-asserts the settled state and refreshes the agent tracking.
  defp send_succeeded(socket, _pending) do
    socket
    |> assign(
      chat_draft: "",
      pending_attachments: Attachments.clear(),
      chat_status: :running
    )
    |> ChatState.persist()
    |> TaskTracking.refresh()
  end

  def normalize_send({:ok, :ok}), do: :ok
  def normalize_send({:ok, {:error, reason}}), do: {:error, reason}
  def normalize_send({:error, reason}), do: {:error, reason}
  def normalize_send({:ok, other}), do: {:error, {:unexpected_send_result, other}}

  def push_queued_echo(socket, text) do
    echo = %{
      id: System.unique_integer([:positive]) |> Integer.to_string(),
      text: text,
      at: System.system_time(:millisecond)
    }

    echoes = (socket.assigns[:queued_echoes] || []) ++ [echo]

    socket
    |> assign(queued_echoes: Enum.take(echoes, -20))
    |> ChatState.persist()
  end

  def message_count_grew?(socket, changed_fields) do
    case Keyword.get(changed_fields, :message_count) do
      count when is_integer(count) ->
        case socket.assigns[:agent_message_count] do
          nil -> true
          previous when is_integer(previous) -> count > previous
          _other -> true
        end

      _other ->
        false
    end
  end

  # A refused send. The user bubble (and, for a queued send, the echo) were
  # applied optimistically before the RPC, so the rollback context in
  # `:send_pending`'s `:prev` restores the exact pre-send transcript, draft and
  # staged attachments before the failure is reported.
  def send_failure(socket, reason, pending) do
    socket
    |> restore_send(Map.get(pending, :prev))
    |> send_failure(reason)
  end

  def send_failure(socket, :workspace_changed) do
    put_flash(
      socket,
      :error,
      gettext(
        "The project selection changed in another view. Select the project again and retry your message."
      )
    )
  end

  def send_failure(socket, reason) do
    if SessionActions.session_ended?(reason) do
      socket
      |> assign(chat_status: :ended, queued_echoes: [])
      |> ChatState.persist()
      |> put_flash(
        :error,
        gettext("This conversation has ended. Start a new chat to continue.")
      )
    else
      put_flash(
        socket,
        :error,
        gettext("Failed to send the message: %{reason}", reason: inspect(reason))
      )
    end
  end

  # error — never a silent Auto, never a fallback on a transport error.
  #
  # ASYNC + OPTIMISTIC: the user bubble and the empty reply bubble appear at
  # once and the RPC runs in `EvoDash.TaskSupervisor`, so a slow or remote node
  # never freezes delta processing. The rollback context travels in
  # `:send_pending` (see `apply_send_result/3`).
  def start_session_chat(socket, text, attachments, task_opts) do
    node = socket.assigns[:current_node] || node()

    opts =
      SessionActions.session_opts(text,
        model_spec: Keyword.get(task_opts, :model_spec),
        attachments: attachments,
        assistant_workspace: socket.assigns[:workspace],
        assistant_conversation_id:
          socket.assigns[:assistant_conversation_id] || socket.assigns[:chat_id]
      )

    seq = (socket.assigns[:send_seq] || 0) + 1

    prev = %{
      transcript: socket.assigns[:transcript],
      chat_draft: socket.assigns[:chat_draft],
      pending_attachments: socket.assigns[:pending_attachments],
      chat_status: socket.assigns[:chat_status]
    }

    transcript =
      socket.assigns[:transcript]
      |> Transcript.append(Transcript.entry(:user, text))
      |> Transcript.put_streaming_text("")

    socket =
      socket
      |> assign(
        transcript: transcript,
        chat_draft: "",
        pending_attachments: Attachments.clear(),
        chat_status: :running,
        chat_node: node,
        send_in_flight: true,
        send_seq: seq,
        send_pending: %{
          kind: :start,
          seq: seq,
          text: text,
          task_opts: task_opts,
          node: node,
          session_id: socket.assigns[:session_id],
          prev: prev
        }
      )
      |> ChatState.persist()

    case SafeCall.start(self(), {:chat_send_result, seq}, fn ->
           SessionActions.start(node, opts)
         end) do
      {:ok, _pid} -> {:noreply, socket}
      {:error, reason} -> {:noreply, apply_send_result(socket, seq, {:error, reason})}
    end
  end

  def start_failure(socket, reason, %{text: text, task_opts: task_opts} = pending) do
    if SessionActions.session_unavailable?(reason) do
      # The optimistic user bubble is already in the transcript, so the one-shot
      # fallback must NOT append a second copy of the same message.
      {:noreply, fallback_socket} =
        start_chat(assign(socket, session_mode: :one_shot), text, task_opts, true)

      put_flash(
        fallback_socket,
        :info,
        gettext(
          "Interactive sessions are unavailable here. This conversation runs in one-shot mode."
        )
      )
    else
      put_flash(
        restore_send(socket, Map.get(pending, :prev)),
        :error,
        gettext("Failed to start the conversation: %{reason}", reason: inspect(reason))
      )
    end
  end

  # Roll an optimistic send back: a refused send leaves neither a phantom user
  # bubble nor a lost draft / attachment set behind, and a refused QUEUED send
  # also drops the echo it optimistically pushed.
  defp restore_send(socket, prev) when is_map(prev) do
    assign(socket,
      transcript: Map.get(prev, :transcript, socket.assigns[:transcript]),
      chat_draft: Map.get(prev, :chat_draft, socket.assigns[:chat_draft]),
      pending_attachments:
        Map.get(prev, :pending_attachments, socket.assigns[:pending_attachments]),
      chat_status: Map.get(prev, :chat_status, socket.assigns[:chat_status]),
      queued_echoes: Map.get(prev, :queued_echoes, socket.assigns[:queued_echoes] || [])
    )
  end

  defp restore_send(socket, _prev), do: socket

  def adopt_session(socket, agent_id, _text) do
    node = socket.assigns[:current_node] || node()
    if key = ChatState.draft_key(socket.assigns), do: EvoDash.ChatHistory.delete_draft(key)

    # The user bubble was appended optimistically when the send started, so the
    # adoption keeps THIS transcript: the empty reply placeholder is merely
    # re-asserted (idempotent — it updates the streaming entry in place).
    transcript = Transcript.put_streaming_text(socket.assigns[:transcript], "")

    socket =
      socket
      |> assign(
        session_id: agent_id,
        current_session_id: agent_id,
        chat_id: agent_id,
        session_mode: :interactive,
        chat_agent_id: agent_id,
        chat_node: node,
        chat_task_id: nil,
        chat_task_status: :running,
        agent_message_count: nil,
        chat_status: :running,
        chat_draft: "",
        queued_echoes: [],
        pending_attachments: Attachments.clear(),
        transcript: transcript
      )
      |> ChatState.persist()
      |> ApprovalWorkflow.init()
      |> HomeLive.maybe_recover_approvals()
      |> HomeLive.spawn_attach(agent_id)
      |> HomeLive.attach_stream()
      |> HomeLive.maybe_load_sessions()
      |> TaskTracking.refresh()

    # Bare socket by contract: every `SendPath` helper returns a `%Socket{}` and
    # the `handle_info` clause in `home_live.ex` owns the single `{:noreply, _}`
    # wrap for the pushed send result.
    push_patch(socket, to: SessionActions.url(socket.assigns[:current_node_id], agent_id))
  end

  # The one-shot `:reflect` fallback. `user_appended?` is true when an
  # optimistic send already appended the user bubble (the interactive start
  # refused with a session-unavailable reason), so the message is never
  # duplicated in the transcript.
  def start_chat(socket, text, task_opts, user_appended? \\ false) do
    transcript =
      if user_appended? do
        Transcript.put_streaming_text(socket.assigns[:transcript], "")
      else
        socket.assigns[:transcript]
        |> Transcript.append(Transcript.entry(:user, text))
        |> Transcript.put_streaming_text("")
      end

    socket =
      assign(socket,
        transcript: transcript,
        chat_draft: "",
        chat_status: :running,
        chat_node: socket.assigns[:current_node] || node()
      )

    result =
      case SafeCall.run(fn ->
             NodeContext.start_task(
               socket.assigns[:current_node] || node(),
               :reflect,
               task_opts
             )
           end) do
        {:ok, start_result} -> start_result
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, _task} ->
        case AgentStream.task_id_from_start(result) do
          {:ok, id} ->
            socket =
              socket
              |> assign(chat_task_id: id, chat_task_status: :pending)
              |> assign(pending_attachments: Attachments.clear())
              |> ChatState.persist()
              |> HomeLive.async_lookup_agent()
              |> HomeLive.maybe_recover_approvals()

            {:noreply, socket}

          {:error, :no_task_id} ->
            socket =
              socket
              |> finalize_streaming(gettext("Failed to start the task: no task id returned"))
              |> assign(:chat_status, :idle)
              |> ChatState.persist()

            {:noreply, socket}
        end

      {:error, reason} ->
        socket =
          socket
          |> finalize_streaming(
            gettext("Failed to start the task: %{reason}", reason: inspect(reason))
          )
          |> assign(:chat_status, :idle)
          |> ChatState.persist()

        {:noreply, socket}
    end
  end

  # ── Finalize block ──

  def finalize_streaming(socket, text) do
    assign(socket, transcript: Transcript.finalize_assistant(socket.assigns[:transcript], text))
  end

  def finalize_terminal(socket, task) do
    cond do
      task == nil ->
        socket
        |> finalize_streaming(gettext("The conversation was deleted."))
        |> clear_task_refs()
        |> ChatState.persist()

      is_map(task) ->
        case Map.get(task, :status) do
          status when status in @terminal_statuses ->
            socket = assign(socket, chat_task_status: status)

            socket =
              case status do
                :completed -> finalize_completed(socket, Map.get(task, :result))
                :cancelled -> finalize_cancelled(socket, Map.get(task, :result))
                :failed -> finalize_failed(socket, Map.get(task, :error))
              end

            socket
            |> clear_task_refs()
            |> ChatState.persist()

          :cancelling ->
            socket
            |> assign(chat_task_status: :cancelling, chat_status: :cancelling)
            |> ChatState.persist()

          status when status in [:running, :pending, :finalizing] ->
            socket
            |> assign(chat_task_status: status)
            |> ChatState.persist()

          _ ->
            socket
        end

      true ->
        socket
    end
  end

  def finalize_completed(socket, result) do
    case AgentStream.extract_final_text(result) do
      {:ok, text} -> finalize_streaming(socket, text)
      :empty -> finalize_streaming(socket, gettext("No response."))
      :error -> finalize_streaming(socket, gettext("The task failed."))
    end
  end

  def finalize_cancelled(socket, result) do
    case AgentStream.extract_final_text(result) do
      {:ok, text} -> finalize_streaming(socket, text)
      _ -> finalize_streaming(socket, gettext("Stopped."))
    end
  end

  def finalize_failed(socket, error) do
    case AgentStream.extract_failed_message(error) do
      nil -> finalize_streaming(socket, gettext("The task failed."))
      message -> finalize_streaming(socket, message)
    end
  end

  def clear_task_refs(socket) do
    socket
    |> assign(
      chat_task_id: nil,
      chat_agent_id: nil,
      agent_message_count: nil,
      chat_status: :idle
    )
    |> ApprovalWorkflow.init()
  end
end
