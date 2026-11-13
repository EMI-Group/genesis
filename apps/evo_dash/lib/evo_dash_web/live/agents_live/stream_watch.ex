defmodule EvoDashWeb.AgentsLive.StreamWatch do
  @moduledoc """
  Selected-agent stream transport for the inspector.

  Call `attach/2` and `detach/1` in the LiveView process: PubSub subscriptions
  belong to that process, not to a loader. Forward
  `{:inspector_stream_ready, node, token, id, result}` to `ready/5` and
  `{:agent_delta, id, seq, events}` to `push/4`, and worker monitor
  `{:DOWN, ref, :process, pid, reason}` to `down/4`. Render the reducer at
  `socket.assigns.inspector_stream.state`; the original snapshot remains at
  `.snapshot`. `active?/2` includes snapshot-pending watches, but not failures,
  so the page can suppress checkpoint-history fetches during attachment.

  `inspector_stream` is nil when detached, otherwise a map with `agent_id`,
  `node`, `token`, `snapshot`, `seq`, `pending` (arrival-ordered batches),
  `error`, `state` and `buffer_bytes`. Tokens never reset. A failed attachment
  remains visible with an error and can be retried by calling `attach/2`.

  One supervised, consumer-monitored serial worker owns ALL register/unregister
  calls for this LiveView. Selection changes update its desired target without
  blocking the LiveView. An obsolete registration is unregistered before a
  different target is registered; reattaching the same target never lets an
  old unregister remove its newer registration. The worker passes the LIVEVIEW
  pid to both runners, never its own pid. Runner seams are
  `:agents_watch_runner` / `:agents_unwatch_runner`, both `(node, id, pid)`.

  `detach/1` also works from `terminate/2` as best-effort cleanup. The worker
  monitors the consumer, and core sessions independently monitor that same pid.
  No poll or repeating timer is used. Cleanup errors are logged, not retried.
  Transport cannot repair deltas absent from the core snapshot's in-flight
  projection; replay is strictly seq > snapshot seq. Buffer overflow fails the
  watch explicitly instead of silently dropping potentially essential deltas.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1]

  require Logger

  alias EvoDash.{NodeContext, SafeCall, TaskSupervisor}
  alias EvoDashWeb.AgentsLive.RuntimeStream
  alias EvoGit.Agent.Stream.Snapshot

  @max_pending_batches 128
  @max_pending_bytes 1_048_576

  @doc "Attaches a connected consumer; an already healthy same-target watch is a no-op."
  def attach(socket, agent_id) do
    target_node = socket.assigns[:current_node] || node()

    cond do
      not connected?(socket) or pending_remote?(socket) or
          not (is_integer(agent_id) and agent_id > 0) ->
        socket

      active?(socket, agent_id) and socket.assigns.inspector_stream.node == target_node ->
        socket

      true ->
        socket = detach(socket)
        token = next_token(socket)

        stream = %{
          agent_id: agent_id,
          node: target_node,
          token: token,
          snapshot: nil,
          seq: nil,
          pending: [],
          buffer_bytes: 0,
          error: nil,
          state: RuntimeStream.new(agent_id, target_node)
        }

        socket = assign(socket, inspector_stream: stream, inspector_stream_token: token)

        case NodeContext.subscribe_agent_deltas(agent_id) do
          :ok -> start_watch(socket, stream)
          {:error, reason} -> fail(socket, {:subscribe_failed, reason})
        end
    end
  end

  @doc "Clears render state and the local subscription immediately; remote cleanup is serial and async."
  def detach(socket) do
    case socket.assigns[:inspector_stream] do
      %{agent_id: id} -> NodeContext.unsubscribe_agent_deltas(id)
      _ -> :ok
    end

    token = next_token(socket)
    command(socket, {:desired, token, nil})
    assign(socket, inspector_stream: nil, inspector_stream_token: token)
  end

  @doc "Applies a current snapshot, or cleans up an obsolete successful registration."
  def ready(socket, target_node, token, agent_id, result) do
    if target_node == (socket.assigns[:current_node] || node()) and
         not pending_remote?(socket) do
      apply_ready(socket, target_node, token, agent_id, result)
    else
      socket
    end
  end

  defp apply_ready(socket, target_node, token, agent_id, result) do
    case socket.assigns[:inspector_stream] do
      %{node: ^target_node, token: ^token, agent_id: ^agent_id, error: nil, snapshot: nil} =
          stream ->
        case snapshot_result(result) do
          {:ok, snapshot, seq} when snapshot.agent_id in [nil, agent_id] ->
            state = RuntimeStream.seed(stream.state, snapshot, seq)

            {state, seq} =
              Enum.reduce(stream.pending, {state, seq}, fn {batch_seq, events}, {state, seq} ->
                if batch_seq > seq do
                  {RuntimeStream.apply_batch(state, agent_id, batch_seq, events), batch_seq}
                else
                  {state, seq}
                end
              end)

            assign(socket,
              inspector_stream: %{
                stream
                | snapshot: snapshot,
                  state: state,
                  seq: seq,
                  pending: [],
                  buffer_bytes: 0
              }
            )

          {:ok, _snapshot, _seq} ->
            fail(socket, :snapshot_agent_mismatch)

          {:error, reason} ->
            fail(socket, reason)
        end

      _ ->
        # The worker also reconciles obsolete operations before registering its
        # next target. This handles a result already queued in the LV mailbox.
        if match?({:ok, _, _}, snapshot_result(result)) and
             not same_target?(socket, target_node, agent_id) do
          command(socket, {:cleanup, {target_node, agent_id}})
        end

        socket
    end
  end

  @doc "Buffers pre-snapshot batches and applies only newer batches after seeding."
  def push(socket, agent_id, seq, events)
      when is_integer(seq) and seq >= 0 and is_list(events) do
    if active?(socket, agent_id),
      do: apply_push(socket, agent_id, seq, events),
      else: socket
  end

  def push(socket, _agent_id, _seq, _events), do: socket

  defp apply_push(socket, agent_id, seq, events) do
    case socket.assigns[:inspector_stream] do
      %{agent_id: ^agent_id, error: nil, snapshot: nil} = stream ->
        bytes = stream.buffer_bytes + :erlang.external_size({seq, events})

        if length(stream.pending) >= @max_pending_batches or bytes > @max_pending_bytes do
          fail(socket, :pre_snapshot_buffer_overflow)
        else
          assign(socket,
            inspector_stream: %{
              stream
              | pending: stream.pending ++ [{seq, events}],
                buffer_bytes: bytes
            }
          )
        end

      %{agent_id: ^agent_id, error: nil, seq: old_seq} = stream
      when is_integer(old_seq) and seq > old_seq ->
        assign(socket,
          inspector_stream: %{
            stream
            | state: RuntimeStream.apply_batch(stream.state, agent_id, seq, events),
              seq: seq
          }
        )

      _ ->
        socket
    end
  end

  @doc "True for the selected healthy watch, including its snapshot-pending interval."
  def active?(socket, agent_id) do
    case socket.assigns[:inspector_stream] do
      %{agent_id: ^agent_id, node: target_node, error: nil} ->
        target_node == (socket.assigns[:current_node] || node()) and not pending_remote?(socket)

      _ ->
        false
    end
  end

  @doc """
  Handles a worker monitor DOWN; forward unmatched DOWN messages here from the page.

  Matching worker death fails a pending or established watch explicitly, clears
  its local subscription and permits an attach retry. Other monitors are inert.
  """
  def down(socket, ref, pid, reason) do
    if socket.assigns[:inspector_stream_worker_monitor] == ref and
         socket.assigns[:inspector_stream_worker] == pid do
      socket
      |> fail({:watch_worker_down, reason})
      |> assign(inspector_stream_worker: nil, inspector_stream_worker_monitor: nil)
    else
      socket
    end
  end

  defp pending_remote?(socket),
    do:
      socket.assigns[:current_node_id] != nil and
        (socket.assigns[:current_node] || node()) == node()

  defp start_watch(socket, stream) do
    case ensure_worker(socket) do
      {:ok, socket} ->
        desired = %{
          node: stream.node,
          id: stream.agent_id,
          token: stream.token,
          watch:
            Application.get_env(
              :evo_dash,
              :agents_watch_runner,
              &NodeContext.register_agent_watcher/3
            ),
          unwatch:
            Application.get_env(
              :evo_dash,
              :agents_unwatch_runner,
              &NodeContext.unregister_agent_watcher/3
            )
        }

        command(socket, {:desired, stream.token, desired})
        socket

      {:error, reason, socket} ->
        fail(socket, {:watch_start_failed, reason})
    end
  end

  defp ensure_worker(socket) do
    case socket.assigns[:inspector_stream_worker] do
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
             monitor = Process.monitor(consumer)

             worker(%{
               consumer: consumer,
               monitor: monitor,
               desired: nil,
               token: -1,
               registered: nil,
               attempted: nil,
               failed: false,
               cleanup: MapSet.new(),
               stopping: false
             })
           end)
         end) do
      {:ok, {:ok, pid}} ->
        monitor = Process.monitor(pid)

        {:ok,
         assign(socket,
           inspector_stream_worker: pid,
           inspector_stream_worker_monitor: monitor
         )}

      {:ok, {:error, reason}} ->
        {:error, reason, socket}

      {:error, reason} ->
        {:error, reason, socket}

      other ->
        {:error, other, socket}
    end
  end

  defp command(socket, message) do
    case socket.assigns[:inspector_stream_worker] do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp fail(socket, reason) do
    case socket.assigns[:inspector_stream] do
      %{} = stream ->
        NodeContext.unsubscribe_agent_deltas(stream.agent_id)
        command(socket, {:desired, stream.token, nil})

        assign(socket,
          inspector_stream: %{stream | error: reason, pending: [], buffer_bytes: 0}
        )

      _ ->
        socket
    end
  end

  defp next_token(socket) do
    case socket.assigns[:inspector_stream_token] do
      token when is_integer(token) and token >= 0 -> token + 1
      _ -> 1
    end
  end

  defp same_target?(socket, target_node, id) do
    case socket.assigns[:inspector_stream] do
      %{node: ^target_node, agent_id: ^id, error: nil} -> true
      _ -> false
    end
  end

  defp snapshot_result({:ok, {:ok, %Snapshot{} = snapshot, seq}})
       when is_integer(seq) and seq >= 0,
       do: {:ok, snapshot, seq}

  defp snapshot_result({:ok, %Snapshot{} = snapshot, seq}) when is_integer(seq) and seq >= 0,
    do: {:ok, snapshot, seq}

  defp snapshot_result({:ok, {:error, reason}}), do: {:error, reason}
  defp snapshot_result({:error, reason}), do: {:error, reason}
  defp snapshot_result(other), do: {:error, {:invalid_watch_result, other}}

  # All RPCs run in this supervised worker, not in the LiveView. Drain desired
  # changes after each RPC before deciding the next operation, including cleanup.
  # This is mailbox draining, not polling: the idle branch blocks in receive.
  defp worker(state) do
    state = drain(state)
    registered_target = target(state.registered)
    desired_target = target(state.desired)

    case Enum.find(state.cleanup, &(&1 != desired_target)) do
      nil ->
        cond do
          state.registered != nil and
              (registered_target != desired_target or
                 (state.failed and state.attempted == desired_token(state))) ->
            unwatch(state.registered, state.consumer)
            worker(%{state | registered: nil})

          state.desired != nil and state.attempted != desired_token(state) ->
            desired = state.desired

            result =
              SafeCall.run(fn -> desired.watch.(desired.node, desired.id, state.consumer) end)

            send(
              state.consumer,
              {:inspector_stream_ready, desired.node, desired.token, desired.id, result}
            )

            worker(%{
              state
              | registered: desired,
                attempted: desired.token,
                failed: not match?({:ok, _, _}, snapshot_result(result))
            })

          state.stopping ->
            :ok

          true ->
            receive do
              message -> worker(worker_message(state, message))
            end
        end

      {target_node, id} = obsolete ->
        # A stale-ready notification may arrive after its original unregister.
        # Repeating cleanup is safe here: calls are serial, and a desired target
        # is never cleaned. Use the original runner when it is still available.
        registration =
          if registered_target == obsolete do
            state.registered
          else
            %{
              node: target_node,
              id: id,
              unwatch:
                Application.get_env(
                  :evo_dash,
                  :agents_unwatch_runner,
                  &NodeContext.unregister_agent_watcher/3
                )
            }
          end

        unwatch(registration, state.consumer)

        worker(%{
          state
          | cleanup: MapSet.delete(state.cleanup, obsolete),
            registered: if(registered_target == obsolete, do: nil, else: state.registered)
        })
    end
  end

  defp drain(state) do
    receive do
      message -> drain(worker_message(state, message))
    after
      0 -> state
    end
  end

  defp worker_message(state, {:desired, token, desired}) when token >= state.token do
    if state.stopping, do: state, else: %{state | desired: desired, token: token}
  end

  defp worker_message(state, {:cleanup, target}) do
    %{state | cleanup: MapSet.put(state.cleanup, target)}
  end

  defp worker_message(state, {:DOWN, monitor, :process, consumer, _reason})
       when monitor == state.monitor and consumer == state.consumer do
    %{state | desired: nil, stopping: true}
  end

  defp worker_message(state, _message), do: state

  defp unwatch(registration, consumer) do
    result =
      SafeCall.run(fn -> registration.unwatch.(registration.node, registration.id, consumer) end)

    case result do
      {:ok, :ok} -> :ok
      {:ok, {:ok, _}} -> :ok
      other -> Logger.warning("Inspector stream cleanup failed: #{inspect(other)}")
    end
  end

  defp target(nil), do: nil
  defp target(registration), do: {registration.node, registration.id}
  defp desired_token(%{desired: nil}), do: nil
  defp desired_token(state), do: state.desired.token
end
