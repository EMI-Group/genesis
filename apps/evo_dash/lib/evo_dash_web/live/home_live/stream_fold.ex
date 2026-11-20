defmodule EvoDashWeb.HomeLive.StreamFold do
  @moduledoc """
  The PUSH-ONLY delta stream boundary of `EvoDashWeb.HomeLive`.
  `EvoDashWeb.HomeLive.Watch` owns subscription, registration, sequence gating
  and the atomic snapshot surface; this module is the one place the page folds
  what it returns into the socket:
    * `attach_stream/1` — attach (or reattach) the watch for the current
      `?session=` agent, then settle a failed ownership;
    * `apply_watch_result/1` — install the returned transcript, thought process,
      turn meta and phase WITHOUT re-rendering value-equal assigns
      (`maybe_assign_changed/4` — a value-equal re-assign re-renders the subtree,
      which is what made the column jitter on every ~75 ms delta batch), fold the
      batch outcome, settle a terminal snapshot, persist;
    * `fold_stream_outcome/2` / `apply_stream_phase/2` — the outcome and phase
      vocabulary: a yield parks the session (`:idle` / `:awaiting_input`), a
      finish ends it, `:cancelling` keeps the session alive;
    * `apply_terminal_snapshot/2` — a closed snapshot's phase/status is the
      lifecycle authority (it deliberately carries no synthetic delta outcome);
    * `settle_watch_failure/1` — ONLY the registry's absent-session verdict ends
      the chat; every other failure keeps the last coherent surface and offers an
      explicit reattach;
    * `finalize_bubble/1` — close the streaming assistant bubble.
  Extracted verbatim: no guard, seq or assign name changed.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  alias EvoDashWeb.HomeLive.{ChatState, Transcript, Watch}
  @terminal_statuses [:completed, :cancelled, :failed]

  @doc """
  Attaches the page to the current `?session=` agent's PUSH-ONLY delta stream.

  The stream is seeded by a snapshot from `EvoDashWeb.HomeLive.Watch`, which
  also owns the consumer-local PubSub subscription; `SendPath.adopt_session/3`
  calls this for a freshly started session (whose URL push short-circuits
  `SessionResolution.resolve_session/3`, so `reattach_session/2` never runs for
  it).
  """
  def attach_stream(socket), do: socket |> Watch.attach() |> settle_watch_failure()

  @doc """
  Settles a watch ownership failure: only the registry's absent-session verdict
  proves the session has ended.
  """
  def settle_watch_failure(socket) do
    # Only the registry's absent-session verdict proves the session has ended.
    # Other :not_found reasons include timeout, unsupported watch and missing
    # PubSub: keep the last coherent surface/phase and offer explicit reattach.
    # Failed ownership stays intact, so an independent attach cannot resurrect
    # the session or replace cached text/reasoning, in either arrival order.
    case Watch.failure(socket.assigns) do
      {:not_found, :session_not_found} ->
        socket
        |> assign(
          chat_status: :ended,
          chat_task_status: nil,
          queued_echoes: [],
          transcript: Transcript.finalize_streaming(socket.assigns[:transcript])
        )
        |> ChatState.persist()

      _ ->
        socket
    end
  end

  @doc "Closes the in-flight assistant bubble (an empty placeholder is dropped)."
  def finalize_bubble(socket) do
    assign(socket, transcript: Transcript.close_streaming(socket.assigns[:transcript]))
  end

  ## Watch results --------------------------------------------------------

  def apply_watch_result({:ok, socket, surface}) do
    socket =
      case surface do
        %{snapshot: snapshot} ->
          socket
          |> assign(agent_message_count: length(snapshot.messages))
          |> apply_stream_phase(snapshot.phase)

        _ ->
          socket
      end

    socket
    |> maybe_assign_changed(:transcript, surface.transcript, socket.assigns[:transcript])
    |> maybe_assign_changed(
      :thought_process,
      surface.thought_process,
      socket.assigns[:thought_process]
    )
    |> maybe_assign_changed(:chat_stream_meta, surface.meta, socket.assigns[:chat_stream_meta])
    |> fold_stream_outcome(surface.outcome)
    |> apply_terminal_snapshot(surface)
    |> ChatState.persist()
  end

  def apply_watch_result({:error, socket, _reason}), do: settle_watch_failure(socket)
  def apply_watch_result({_status, socket}), do: socket

  # Assign a value only when it differs from what the socket already holds:
  # a value-equal re-assign still re-renders that subtree, which is what made
  # the transcript column jitter on every ~75 ms delta batch.
  defp maybe_assign_changed(socket, _key, new_value, new_value), do: socket
  defp maybe_assign_changed(socket, key, new_value, _previous), do: assign(socket, key, new_value)

  # Closed snapshots deliberately have no synthetic delta outcome: lifecycle
  # and final status come from the authoritative snapshot, after its transcript.
  defp apply_terminal_snapshot(socket, %{snapshot: %{phase: :done} = snapshot}) do
    socket =
      case Map.get(snapshot, :status) do
        status when status in @terminal_statuses ->
          assign(socket, chat_task_status: status)

        _ ->
          socket
      end

    socket
    |> assign(chat_status: :ended, queued_echoes: [])
    |> finalize_bubble()
  end

  defp apply_terminal_snapshot(socket, _surface), do: socket

  defp apply_stream_phase(socket, :awaiting_input), do: fold_stream_outcome(socket, :yield)

  defp apply_stream_phase(socket, phase)
       when phase in [:starting, :running, :cancelling, :finalizing] do
    assign(socket,
      chat_status: if(phase == :cancelling, do: :cancelling, else: :running),
      chat_task_status: if(phase == :starting, do: :running, else: phase)
    )
  end

  defp apply_stream_phase(socket, :done),
    do: assign(socket, chat_status: :ended, queued_echoes: [])

  defp apply_stream_phase(socket, _phase), do: socket

  # The outcome a delta batch reported: a yield parks the session (idle, waiting
  # for input), a finish ends it, and anything else terminal-looking fails it.
  defp fold_stream_outcome(socket, nil), do: socket

  defp fold_stream_outcome(socket, :yield) do
    assign(socket, chat_status: :idle, chat_task_status: :awaiting_input, queued_echoes: [])
  end

  defp fold_stream_outcome(socket, {:finished, :completed}) do
    assign(socket, chat_status: :ended, chat_task_status: :completed, queued_echoes: [])
  end

  defp fold_stream_outcome(socket, {:finished, status}) when status in @terminal_statuses do
    assign(socket, chat_status: :ended, chat_task_status: status, queued_echoes: [])
  end

  defp fold_stream_outcome(socket, _outcome) do
    assign(socket, chat_status: :ended, chat_task_status: :failed, queued_echoes: [])
  end

  ## Delta / readiness / close / worker-down ------------------------------

  # Watch owns sequence gating, registration-time buffering and failed watches.
  # Always retain its returned socket, even when no display surface is admitted.
  def handle_info(socket, {:agent_delta, agent_id, seq, batch}) do
    {:noreply, apply_watch_result(Watch.push(socket, agent_id, seq, batch))}
  end

  def handle_info(socket, {:agent_stream_closed, agent_id, snapshot, seq}) do
    {:noreply, apply_watch_result(Watch.closed(socket, agent_id, snapshot, seq))}
  end

  def handle_info(socket, {:chat_stream_ready, node, seq, agent_id, result}) do
    {:noreply, apply_watch_result(Watch.ready(socket, node, seq, agent_id, result))}
  end

  def handle_info(socket, {:DOWN, ref, :process, pid, reason}) do
    {:noreply, socket |> Watch.down(ref, pid, reason) |> settle_watch_failure()}
  end
end
