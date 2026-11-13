defmodule EvoDashWeb.HomeLive.Watch do
  @moduledoc """
  Consumer-local subscription and serial, supervised registration for Assistant.

  Forward `{:chat_stream_ready, node, token, id, result}` to `ready/5`, deltas
  to `push/4`, terminal `{:agent_stream_closed, id, snapshot, seq}` handoffs to
  `closed/4`, and worker `:DOWN` messages to `down/4` in the LiveView process.
  `ready/5`, `push/4` and `closed/4` return `{:ok, socket, surface}`, `{:ignored, socket}`,
  `{:buffered, socket}` or `{:error, socket, reason}`. Install the returned
  `transcript`, `thought_process` and `meta` in the SAME callback as the returned
  socket. On ready, apply `surface.snapshot.phase` FIRST, then the replayed
  `surface.outcome`; snapshot history, live activity and sequence are one cut.

  Registration-time batches buffer and replay only above the snapshot sequence.
  A text-less finish requests one final atomic cut through the same worker and
  ready/5 route, keeping the subscription and cached surface while it is pending.
  Its generation and finish-sequence watermark reject obsolete or stale replies;
  failure never falls back to independent history or automatically repeats.
  `stream_active?/1` denotes history OWNERSHIP, including pending/failed watches:
  independent attach/history results must not overwrite their display or phase.
  Tag independent reads with `stream_attach_seq` and reject results after that
  generation changes, even if the watch has since detached.

  One consumer-monitored worker serializes registration and cleanup, passing the
  LiveView pid to the core. Detach never races a later register; worker startup,
  RPC failures and buffer overflow remain explicit errors, not history fallback.
  Runner seams are `:home_agent_watch_runner` and `:home_agent_unwatch_runner`,
  both `(node, agent_id, consumer_pid)`, resolved when attach is requested.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1]

  require Logger

  alias EvoGit.Agent.Stream.Snapshot
  alias EvoDash.{NodeContext, SafeCall, TaskSupervisor}
  alias EvoDashWeb.HomeLive.{Delta, Messages, Transcript}

  @max_batches 128
  @max_bytes 1_048_576

  @doc "Attaches a connected, resolved session; a healthy same-scope watch is a no-op."
  def attach(socket) do
    id = socket.assigns[:session_id]
    target_node = socket.assigns[:current_node] || node()

    cond do
      not connected?(socket) or not positive_int?(id) or pending_remote?(socket) ->
        socket

      stream_active?(socket) and socket.assigns.chat_stream[:error] == nil ->
        socket

      true ->
        socket = detach(socket)
        token = next_token(socket)

        stream = %{
          agent_id: id,
          node: target_node,
          target_id: socket.assigns[:current_node_id],
          token: token,
          delta: nil,
          snapshot: nil,
          pending: [],
          buffer_bytes: 0,
          final_resync: nil,
          closed_seq: nil,
          terminal_outcome: nil,
          required_seq: 0,
          error: nil
        }

        socket = assign(socket, chat_stream: stream, stream_attach_seq: token)

        with :ok <- NodeContext.subscribe_agent_deltas(id),
             {:ok, socket} <- ensure_worker(socket) do
          register(socket, stream)
          socket
        else
          {:error, reason} -> fail(socket, reason)
        end
    end
  end

  @doc "Unsubscribes inline, queues serial cleanup, and invalidates every older result."
  def detach(socket) do
    case socket.assigns[:chat_stream] do
      %{agent_id: id} -> NodeContext.unsubscribe_agent_deltas(id)
      _ -> :ok
    end

    command(socket, :unregister)

    assign(socket,
      chat_stream: nil,
      chat_stream_meta: nil,
      stream_attach_seq: next_token(socket)
    )
  end

  @doc "Admits the current atomic snapshot and replays only newer buffered batches."
  def ready(socket, target_node, token, id, result) do
    case socket.assigns[:chat_stream] do
      %{closed_seq: seq} when is_integer(seq) ->
        {:ignored, socket}

      %{node: ^target_node, token: ^token, agent_id: ^id, error: nil} = stream
      when stream.delta == nil or stream.final_resync == :pending ->
        if stream_active?(socket) do
          case snapshot_result(result, id, target_node) do
            {:ok, surface} when surface.delta.seq >= stream.required_seq ->
              outcome = if stream.final_resync == :pending, do: stream.terminal_outcome
              surface = Map.put(surface, :outcome, outcome)

              surface =
                stream.pending
                |> Enum.reverse()
                |> Enum.reduce(surface, fn {seq, events}, surface ->
                  reduce_batch(surface, seq, events)
                end)

              surface =
                if stream.final_resync == :pending or surface.snapshot.phase == :done,
                  do: %{surface | transcript: Transcript.close_streaming(surface.transcript)},
                  else: surface

              stream = %{
                stream
                | delta: surface.delta,
                  snapshot: surface.snapshot,
                  pending: [],
                  buffer_bytes: 0,
                  final_resync: if(stream.final_resync == :pending, do: :done)
              }

              socket = assign(socket, chat_stream: stream)
              {:ok, maybe_final_resync(socket, surface), surface}

            {:ok, surface} ->
              reason = {:snapshot_before_finish, surface.delta.seq, stream.required_seq}
              {:error, fail(socket, reason), reason}

            {:error, reason} ->
              {:error, fail(socket, reason), reason}
          end
        else
          {:ignored, socket}
        end

      _ ->
        {:ignored, socket}
    end
  end

  @doc "Buffers during registration, otherwise applies a strictly newer batch."
  def push(socket, id, seq, events) when is_integer(seq) and seq >= 0 and is_list(events) do
    case socket.assigns[:chat_stream] do
      %{closed_seq: closed_seq} when is_integer(closed_seq) ->
        {:ignored, socket}

      %{agent_id: ^id, error: nil} = stream ->
        if stream_active?(socket) do
          case stream.delta do
            %Delta{seq: previous} when seq <= previous ->
              {:ignored, socket}

            delta when delta == nil or stream.final_resync == :pending ->
              bytes = stream.buffer_bytes + :erlang.external_size(events)

              if length(stream.pending) >= @max_batches or bytes > @max_bytes do
                {:error, fail(socket, :watch_buffer_overflow), :watch_buffer_overflow}
              else
                stream = %{
                  stream
                  | pending: [{seq, events} | stream.pending],
                    buffer_bytes: bytes
                }

                {:buffered, assign(socket, chat_stream: stream)}
              end

            %Delta{seq: previous} when seq > previous ->
              surface = %{
                delta: stream.delta,
                transcript: socket.assigns[:transcript] || [],
                thought_process: socket.assigns[:thought_process] || [],
                meta: socket.assigns[:chat_stream_meta] || Delta.meta(),
                outcome: nil
              }

              surface = reduce_batch(surface, seq, events)
              socket = assign(socket, chat_stream: %{stream | delta: surface.delta})
              {:ok, maybe_final_resync(socket, surface), surface}

            _ ->
              {:ignored, socket}
          end
        else
          {:ignored, socket}
        end

      _ ->
        {:ignored, socket}
    end
  end

  def push(socket, _id, _seq, _events), do: {:ignored, socket}

  @doc """
  Admits the authoritative final cut delivered directly by the watched session.

  This may precede registration's reply or follow a failed final resync. It
  replaces the whole display surface, never appends or guesses message identity.
  Equal sequence is intentional: the final messages can checkpoint at the same
  watermark as an already applied finish batch. Once admitted, no late delta,
  registration reply or worker failure can replace this terminal cut.

  The returned snapshot retains the core's terminal status fields verbatim;
  the page must apply that status alongside `snapshot.phase` and the surface.
  """
  def closed(socket, id, %Snapshot{agent_id: id, phase: :done, seq: seq} = snapshot, seq)
      when is_integer(seq) and seq >= 0 do
    case socket.assigns[:chat_stream] do
      %{closed_seq: closed_seq} when is_integer(closed_seq) ->
        {:ignored, socket}

      %{agent_id: ^id} = stream ->
        if stream_active?(socket) and stream.token == socket.assigns[:stream_attach_seq] and
             seq >= observed_seq(stream) do
          {:ok, surface} = snapshot_result({:ok, snapshot, seq}, id, stream.node)

          surface =
            surface
            |> Map.put(:outcome, nil)
            |> Map.update!(:transcript, &Transcript.close_streaming/1)

          token = next_token(socket)

          stream =
            Map.merge(stream, %{
              token: token,
              delta: surface.delta,
              snapshot: snapshot,
              pending: [],
              buffer_bytes: 0,
              final_resync: :done,
              closed_seq: seq,
              terminal_outcome: nil,
              required_seq: seq,
              error: nil
            })

          NodeContext.unsubscribe_agent_deltas(id)
          command(socket, :unregister)
          socket = assign(socket, chat_stream: stream, stream_attach_seq: token)
          {:ok, socket, surface}
        else
          {:ignored, socket}
        end

      _ ->
        {:ignored, socket}
    end
  end

  def closed(socket, _id, _snapshot, _seq), do: {:ignored, socket}

  defp observed_seq(stream) do
    previous = if match?(%Delta{}, stream.delta), do: stream.delta.seq, else: 0

    Enum.reduce(stream.pending, max(previous, stream.required_seq), fn {seq, _events}, latest ->
      max(seq, latest)
    end)
  end

  # A silent finish retires the live call without its answer. Re-register through
  # the same worker for ONE authoritative cut, with no unsubscribe gap or history
  # fallback. Keep the last surface intact if the terminal session is already gone.
  defp maybe_final_resync(socket, %{outcome: {:finished, _} = outcome, delta: delta}) do
    stream = socket.assigns.chat_stream

    if stream.final_resync == nil and not Delta.streamed_text?(delta) do
      token = next_token(socket)

      stream = %{
        stream
        | token: token,
          final_resync: :pending,
          required_seq: delta.seq,
          terminal_outcome: outcome
      }

      register(socket, stream)
      assign(socket, chat_stream: stream, stream_attach_seq: token)
    else
      socket
    end
  end

  defp maybe_final_resync(socket, _surface), do: socket

  defp register(socket, stream) do
    command(
      socket,
      {:register,
       %{
         node: stream.node,
         id: stream.agent_id,
         token: stream.token,
         watch:
           Application.get_env(
             :evo_dash,
             :home_agent_watch_runner,
             &NodeContext.register_agent_watcher/3
           ),
         unwatch:
           Application.get_env(
             :evo_dash,
             :home_agent_unwatch_runner,
             &NodeContext.unregister_agent_watcher/3
           )
       }}
    )
  end

  defp reduce_batch(surface, seq, events) do
    if seq > surface.delta.seq do
      reduced =
        Delta.apply_batch(
          surface.delta,
          surface.transcript,
          surface.thought_process,
          surface.meta,
          events
        )

      Map.merge(surface, %{reduced | delta: %{reduced.delta | seq: seq}})
      |> Map.put(:outcome, reduced.outcome || surface.outcome)
    else
      surface
    end
  end

  @doc "Builds checkpoint history plus the complete captured current-call prefixes."
  @spec snapshot_result(term(), term(), node() | nil) :: {:ok, map()} | {:error, term()}
  def snapshot_result({:ok, result}, agent_id, target_node),
    do: snapshot_result(result, agent_id, target_node)

  def snapshot_result({:ok, %Snapshot{agent_id: id} = snapshot, seq}, id, target_node)
      when is_integer(seq) and seq >= 0 do
    delta = Delta.seed(Delta.new(id, target_node, seq), snapshot, seq)

    meta = %{
      Delta.meta()
      | turn: snapshot.turn,
        total_tokens: snapshot.total_tokens,
        usage: snapshot.usage
    }

    %{transcript: transcript, entries: thoughts} = Messages.transcript(snapshot.messages)

    surface =
      Delta.apply_batch(delta, transcript, thoughts, meta, [{:activity, snapshot.activity}])

    {:ok,
     %{
       snapshot: snapshot,
       delta: surface.delta,
       meta: surface.meta,
       transcript: surface.transcript,
       thought_process: surface.thought_process
     }}
  end

  def snapshot_result({:error, reason}, _id, _node), do: {:error, reason}
  def snapshot_result(result, _id, _node), do: {:error, {:invalid_watch_result, result}}

  @doc "True while this scope owns history, including registration and failed watches."
  def stream_active?(socket) do
    case socket.assigns[:chat_stream] do
      %{agent_id: id, node: target_node} = stream ->
        id == socket.assigns[:session_id] and
          target_node == (socket.assigns[:current_node] || node()) and
          Map.get(stream, :target_id, socket.assigns[:current_node_id]) ==
            socket.assigns[:current_node_id] and
          not pending_remote?(socket)

      _ ->
        false
    end
  end

  @doc "True when the current scope owns an admitted terminal handoff."
  def closed?(socket) do
    case socket.assigns[:chat_stream] do
      %{closed_seq: seq} when is_integer(seq) -> stream_active?(socket)
      _ -> false
    end
  end

  @doc "The current scope's watch failure, retained without surrendering history ownership."
  def failure(assigns) do
    if stream_active?(%{assigns: assigns}) do
      assigns.chat_stream.error
    end
  end

  @doc "Settles an unexpected registration-worker death; forward its monitor DOWN."
  def down(socket, ref, pid, reason) do
    if ref == socket.assigns[:chat_stream_worker_monitor] and
         pid == socket.assigns[:chat_stream_worker] do
      socket
      |> fail({:watch_worker_down, reason})
      |> assign(chat_stream_worker: nil, chat_stream_worker_monitor: nil)
    else
      socket
    end
  end

  defp fail(socket, reason) do
    case socket.assigns[:chat_stream] do
      %{closed_seq: seq} when is_integer(seq) ->
        socket

      %{} = stream ->
        NodeContext.unsubscribe_agent_deltas(stream.agent_id)
        command(socket, :unregister)

        assign(socket,
          chat_stream: %{
            stream
            | error: reason,
              required_seq: observed_seq(stream),
              pending: [],
              buffer_bytes: 0
          }
        )

      _ ->
        socket
    end
  end

  defp ensure_worker(socket) do
    case socket.assigns[:chat_stream_worker] do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, socket}, else: spawn_worker(socket)

      _ ->
        spawn_worker(socket)
    end
  end

  defp spawn_worker(socket) do
    consumer = self()

    case SafeCall.run(fn ->
           Task.Supervisor.start_child(TaskSupervisor, fn ->
             worker(consumer, Process.monitor(consumer), nil)
           end)
         end) do
      {:ok, {:ok, pid}} ->
        {:ok,
         assign(socket,
           chat_stream_worker: pid,
           chat_stream_worker_monitor: Process.monitor(pid)
         )}

      {:ok, {:error, reason}} ->
        {:error, {:watch_start_failed, reason}}

      {:error, reason} ->
        {:error, {:watch_start_failed, reason}}
    end
  end

  defp command(socket, message) do
    case socket.assigns[:chat_stream_worker] do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  # FIFO commands from ONE consumer serialize every RPC, including detach while
  # registration is blocked. The core also monitors the consumer, not this worker.
  defp worker(consumer, monitor, registration) do
    receive do
      {:register, desired} ->
        if registration != nil and target(registration) != target(desired),
          do: unwatch(registration, consumer)

        result = SafeCall.run(fn -> desired.watch.(desired.node, desired.id, consumer) end)
        send(consumer, {:chat_stream_ready, desired.node, desired.token, desired.id, result})
        worker(consumer, monitor, desired)

      :unregister ->
        if registration != nil, do: unwatch(registration, consumer)
        worker(consumer, monitor, nil)

      {:DOWN, ^monitor, :process, ^consumer, _reason} ->
        if registration != nil, do: unwatch(registration, consumer)
    end
  end

  defp unwatch(registration, consumer) do
    case SafeCall.run(fn ->
           registration.unwatch.(registration.node, registration.id, consumer)
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:ok, _}} -> :ok
      other -> Logger.warning("Assistant stream cleanup failed: #{inspect(other)}")
    end
  end

  defp target(registration), do: {registration.node, registration.id}
  defp next_token(socket), do: (socket.assigns[:stream_attach_seq] || 0) + 1
  defp positive_int?(id), do: is_integer(id) and id > 0

  defp pending_remote?(socket),
    do:
      socket.assigns[:current_node_id] != nil and
        (socket.assigns[:current_node] || node()) == node()
end
