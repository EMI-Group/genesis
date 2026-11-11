defmodule EvoDashWeb.HomeLive.SendPath do
  @moduledoc """
  The `/help` composer SEND PATH and the one-shot FINALIZE block for
  `EvoDashWeb.HomeLive`, extracted verbatim so the LiveView module stays
  readable.

  Two halves:

    * the send path — `send_chat/2` / `send_draft/3` guards (pending remote
      node, missing Genesis source), the interactive-session branch
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
    SourceGate,
    Transcript
  }

  alias EvoDashWeb.HomeLive

  @terminal_statuses [:completed, :cancelled, :failed]

  # ── Send path ──

  def send_chat(socket, text), do: send_draft(socket, text, :queue)
  # button are disabled in the same state, so this is the defensive backstop for
  def send_draft(socket, text, policy) do
    cond do
      ModelSelection.pending_remote?(socket) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Connect to the remote node before sending a message.")
         )}

      SourceGate.blocked?(socket.assigns) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Download the Genesis source before sending a message.")
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

      text == "" ->
        {:noreply, socket}

      true ->
        {message, attachments} =
          Attachments.to_message(text, socket.assigns[:pending_attachments])

        opts =
          if is_nil(socket.assigns[:session_id]) do
            [mode: "reflect", objective: reflect_objective(socket, message)]
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

  # is shown as a transient echo (never as a second answer bubble).
  def queue_session_message(socket, text, attachments, policy) do
    node = socket.assigns[:current_node] || node()
    agent_id = socket.assigns[:session_id]
    queued? = socket.assigns[:chat_status] == :running

    result =
      SafeCall.run(fn ->
        SessionActions.send_message(node, agent_id, text, attachments, policy)
      end)

    case normalize_send(result) do
      :ok ->
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
            chat_status: :running
          )
          |> ChatState.persist()

        {:noreply, if(queued?, do: push_queued_echo(socket, text), else: socket)}

      {:error, reason} ->
        {:noreply, send_failure(socket, reason)}
    end
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
  def start_session_chat(socket, text, attachments, task_opts) do
    node = socket.assigns[:current_node] || node()

    opts =
      SessionActions.session_opts(text,
        model_spec: Keyword.get(task_opts, :model_spec),
        attachments: attachments
      )

    case SafeCall.run(fn -> SessionActions.start(node, opts) end) do
      {:ok, {:ok, agent_id}} ->
        adopt_session(socket, agent_id, text)

      {:ok, {:error, reason}} ->
        start_failure(socket, reason, text, task_opts)

      {:error, reason} ->
        start_failure(socket, {:transport, reason}, text, task_opts)

      {:ok, other} ->
        start_failure(socket, {:unexpected_start_result, other}, text, task_opts)
    end
  end

  def start_failure(socket, reason, text, task_opts) do
    if SessionActions.session_unavailable?(reason) do
      {:noreply, fallback_socket} =
        start_chat(assign(socket, session_mode: :one_shot), text, task_opts)

      {:noreply,
       put_flash(
         fallback_socket,
         :info,
         gettext(
           "Interactive sessions are unavailable here. This conversation runs in one-shot mode."
         )
       )}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Failed to start the conversation: %{reason}", reason: inspect(reason))
       )}
    end
  end

  def adopt_session(socket, agent_id, text) do
    node = socket.assigns[:current_node] || node()

    transcript =
      socket.assigns[:transcript]
      |> Transcript.append(Transcript.entry(:user, text))
      |> Transcript.put_streaming_text("")

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
      |> HomeLive.maybe_load_sessions()

    {:noreply,
     push_patch(socket, to: SessionActions.url(socket.assigns[:current_node_id], agent_id))}
  end

  def start_chat(socket, text, task_opts) do
    transcript =
      socket.assigns[:transcript]
      |> Transcript.append(Transcript.entry(:user, text))
      |> Transcript.put_streaming_text("")

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
