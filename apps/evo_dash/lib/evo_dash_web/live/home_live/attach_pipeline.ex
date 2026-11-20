defmodule EvoDashWeb.HomeLive.AttachPipeline do
  @moduledoc """
  The independent ATTACH / HISTORY READ pipeline for `EvoDashWeb.HomeLive`.
  Everything here is a read-only view of the conversation that the delta stream
  may already own:
    * `spawn_attach/2` — ONE supervised attach task per (seq, node, session)
      that gathers the agent summary, the awaiting-input list and the agent
      history (`SessionActions.load_attach/2`), tagged
      `{{:session_attached, seq, node, session_id}, result}`;
    * `apply_attach/2` — the result fold: the session's task id, the transcript
      rebuild (`apply_history/3`), the chat status from the summary/awaiting
      pair, then the chat persistence and the sidebar refresh;
    * `settle_attach/2` — the failure / no-watch fallback: keep the last
      coherent transcript and decide `:ended` versus `:idle`;
    * `maybe_load_sessions/1` — the shared sidebar Conversations refresh (the
      one helper the send path and the chat lifecycle call back into);
    * the chat-agent / history / task loaders (`async_lookup_agent/1,2`,
      `async_fetch_history/1,2`, `async_fetch_task/1,2`) and their
      `handle_info/2` settlements with the page's monotonic seq + node guards.
  A WATCHED session keeps display ownership: neither the attach history nor a
  message-count-driven refetch may replace its transcript or phase
  (`Watch.stream_active?/1`), while an independent read still captures
  `stream_attach_seq` and is dropped after it moves.
  Extracted verbatim; `EvoDash.SafeCall` remains the exit-safe boundary and no
  call blocks the LiveView process.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1]
  alias EvoDash.{NodeContext, SafeCall, TaskSupervisor}

  alias EvoDashWeb.HomeLive.{
    AgentStream,
    ApprovalDialogState,
    ChatBootstrap,
    ChatState,
    Messages,
    SessionActions,
    SessionList,
    SessionResolution,
    StreamFold,
    TaskTracking,
    Transcript,
    Watch
  }

  @doc """
  Starts ONE attach task for `session_id`, tagged
  `{{:session_attached, seq, node, session_id, stream_seq}, result}`.
  """
  def spawn_attach(socket, session_id) do
    if connected?(socket) do
      # Establish watch ownership before tagging the independent metadata read.
      # Its history/phase must never replace the watch's atomic display cut.
      socket = StreamFold.attach_stream(socket)
      seq = (socket.assigns[:session_attach_seq] || 0) + 1
      node = socket.assigns[:current_node]
      stream_seq = socket.assigns[:stream_attach_seq]

      case SafeCall.start(self(), {:session_attached, seq, node, session_id, stream_seq}, fn ->
             SessionActions.load_attach(node, session_id)
           end) do
        {:ok, _pid} ->
          assign(socket, session_attach_seq: seq, session_attach_pending?: true)

        {:error, reason} ->
          socket |> assign(session_attach_pending?: false) |> settle_attach({:error, reason})
      end
    else
      socket
    end
  end

  @doc "Folds an attach task's result into the page."
  def apply_attach(socket, {:ok, %{summary: summary, awaiting?: awaiting?, history: history}}) do
    status = SessionActions.status_from(summary, awaiting?)

    socket = assign(socket, chat_task_id: summary_value(summary, :task_id))

    socket =
      if Watch.stream_active?(socket) do
        socket
      else
        socket
        |> assign(chat_task_status: summary_value(summary, :status))
        |> apply_history(history, true)
        |> assign(chat_status: attach_status(summary, awaiting?, status))
      end

    socket
    |> ChatState.persist()
    |> maybe_load_sessions()
  end

  def apply_attach(socket, {:error, reason}), do: settle_attach(socket, {:error, reason})

  def apply_attach(socket, _other),
    do: settle_attach(socket, {:error, :unexpected_attach_result})

  @doc "The failure / no-watch fallback for an attach task."
  def settle_attach(socket, _result) do
    socket = assign(socket, workspace_loading: false)

    if Watch.stream_active?(socket) do
      socket
    else
      status = if socket.assigns[:transcript] == [], do: :ended, else: :idle

      socket
      |> assign(chat_status: status)
      |> ChatState.persist()
    end
  end

  defp attach_status(nil, false, _status), do: :ended

  defp attach_status(_summary, _awaiting?, status)
       when status in [:idle, :running, :cancelling],
       do: status

  defp attach_status(_summary, _awaiting?, _status), do: :ended

  defp summary_value(summary, key) when is_map(summary) do
    case Map.fetch(summary, key) do
      {:ok, value} -> value
      :error -> Map.get(summary, Atom.to_string(key))
    end
  end

  defp summary_value(_summary, _key), do: nil

  @doc """
  The transcript projection of a fetched history list.
  """
  def apply_history(socket, messages, rebuild?) when is_list(messages) do
    %{transcript: built, entries: entries} = Messages.transcript(messages)
    text = Messages.assistant_text(messages)

    # A REBUILD from an EMPTY fetched history means the session is gone with
    # nothing to replay, so a non-empty locally cached transcript (and its
    # reasoning) is KEPT and rendered read-only instead of being wiped by `[]`.
    # A non-empty history always wins, and a first-ever attach with no cache
    # stays empty (the ended state).
    keep_cache? = rebuild? and messages == [] and socket.assigns[:transcript] not in [nil, []]

    transcript =
      cond do
        keep_cache? ->
          socket.assigns[:transcript]

        rebuild? ->
          built

        ChatBootstrap.interactive_session?(socket) and messages != [] ->
          built

        text == "" ->
          socket.assigns[:transcript]

        true ->
          transcript = Transcript.put_streaming_text(socket.assigns[:transcript], text)
          answer = Enum.find(Enum.reverse(transcript), &(&1.role == :assistant and &1.streaming))

          reasoning =
            for entry <- built, entry.role == :assistant, thought <- entry.reasoning, do: thought

          Transcript.put_reasoning(transcript, answer.id, reasoning)
      end

    assign(socket,
      transcript: transcript,
      agent_message_count: length(messages),
      thought_process: if(keep_cache?, do: socket.assigns[:thought_process] || [], else: entries)
    )
  end

  def apply_history(socket, _messages, _rebuild?), do: socket

  @doc """
  Refreshes the shared sidebar's Conversations load for the current node.
  """
  def maybe_load_sessions(socket) do
    if connected?(socket) do
      SessionList.spawn_load(socket, socket.assigns[:current_node])
    else
      socket
    end
  end

  ## Chat-agent / history / task loaders ---------------------------------

  @doc """
  Resolves the chat task's root agent, tagged
  `{:chat_agent_lookup, node, seq, task_id, stream_seq, agent}`.
  """
  def async_lookup_agent(socket, node_override \\ nil) do
    task_id = socket.assigns[:chat_task_id]
    node = node_override || socket.assigns[:current_node] || node()
    seq = socket.assigns[:chat_fetch_seq] + 1
    stream_seq = socket.assigns[:stream_attach_seq]
    pid = self()

    Task.Supervisor.start_child(TaskSupervisor, fn ->
      agents = SafeCall.run(fn -> NodeContext.list_agents(node) end, [])
      agent = AgentStream.find_root_agent(agents, task_id)
      send(pid, {:chat_agent_lookup, node, seq, task_id, stream_seq, agent})
    end)

    assign(socket, chat_fetch_seq: seq)
  end

  @doc """
  Reads the watched agent's history, tagged
  `{:chat_history_loaded, node, seq, agent_id, stream_seq, result}`.
  """
  def async_fetch_history(socket, node_override \\ nil) do
    agent_id = socket.assigns[:chat_agent_id]
    node = node_override || socket.assigns[:current_node] || node()
    seq = socket.assigns[:chat_fetch_seq] + 1
    stream_seq = socket.assigns[:stream_attach_seq]
    pid = self()

    runner =
      Application.get_env(:evo_dash, :home_agent_history_runner, &NodeContext.get_agent_history/2)

    Task.Supervisor.start_child(TaskSupervisor, fn ->
      result =
        SafeCall.run(fn -> runner.(node, agent_id) end, [])

      send(pid, {:chat_history_loaded, node, seq, agent_id, stream_seq, result})
    end)

    assign(socket, chat_fetch_seq: seq)
  end

  @doc """
  Reads the chat task's lite row, tagged `{:chat_task_loaded, node, seq, task_id, task}`.
  """
  def async_fetch_task(socket, node_override \\ nil) do
    task_id = socket.assigns[:chat_task_id]
    node = node_override || socket.assigns[:current_node] || node()
    seq = socket.assigns[:chat_task_fetch_seq] + 1
    pid = self()

    Task.Supervisor.start_child(TaskSupervisor, fn ->
      task = SafeCall.run(fn -> NodeContext.get_task_lite(node, task_id) end, nil)
      send(pid, {:chat_task_loaded, node, seq, task_id, task})
    end)

    assign(socket, chat_task_fetch_seq: seq)
  end

  ## Async results --------------------------------------------------------

  def handle_info(socket, {:chat_agent_lookup, node, seq, task_id, stream_seq, agent}) do
    if ChatBootstrap.stale?(socket, node, seq) or task_id != socket.assigns[:chat_task_id] or
         stream_seq != socket.assigns[:stream_attach_seq] or Watch.stream_active?(socket) do
      {:noreply, socket}
    else
      if is_map(agent) do
        socket =
          assign(socket,
            chat_agent_id: Map.get(agent, :id),
            agent_message_count: AgentStream.message_count(agent)
          )

        {:noreply,
         socket
         |> ChatState.persist()
         |> async_fetch_history()
         |> ApprovalDialogState.maybe_recover_approvals()}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_info(socket, {:chat_history_loaded, node, seq, agent_id, stream_seq, result}) do
    if ChatBootstrap.stale?(socket, node, seq) or agent_id != socket.assigns[:chat_agent_id] or
         stream_seq != socket.assigns[:stream_attach_seq] or Watch.stream_active?(socket) do
      {:noreply, socket}
    else
      case result do
        msgs when is_list(msgs) ->
          socket = socket |> apply_history(msgs, false) |> ChatState.persist()

          # No writer is left once the session stopped, so a reply that just
          # landed from history must not stay rendered as still streaming.
          socket =
            if socket.assigns[:chat_status] in [:ended, :idle],
              do: StreamFold.finalize_bubble(socket),
              else: socket

          {:noreply, socket}

        _ ->
          {:noreply, socket}
      end
    end
  end

  def handle_info(socket, {{:session_attached, seq, node, session_id, stream_seq}, result}) do
    if seq == socket.assigns[:session_attach_seq] and
         node == socket.assigns[:current_node] and
         session_id == socket.assigns[:session_id] do
      socket =
        socket
        |> assign(session_attach_pending?: false)
        |> SessionResolution.restore_attached_context(result)

      # Stream generations own the transcript, while the owning session supplies identity.
      socket =
        if stream_seq == socket.assigns[:stream_attach_seq],
          do: apply_attach(socket, result),
          else: ChatState.persist(socket)

      {:noreply, socket |> ApprovalDialogState.maybe_recover_approvals() |> TaskTracking.refresh()}
    else
      {:noreply, socket}
    end
  end
end
