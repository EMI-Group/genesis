defmodule EvoDashWeb.AgentsLive.StreamWatch do
  @moduledoc """
  Selected-agent stream transport for the inspector.

  Call `attach/2` and `detach/1` in the LiveView process: PubSub subscriptions
  belong to that process, not to a loader. Forward
  `{:inspector_stream_ready, node, token, id, result}` to `ready/5` and
  `{:agent_delta, id, seq, events}` to `push/4`, and worker monitor
  `{:DOWN, ref, :process, pid, reason}` to `down/4`. Render the reducer at
  `socket.assigns.inspector_stream.state`; its `messages` are the ONLY checkpoint
  source while watched. The admitted atomic snapshot remains at `.snapshot`.
  Forward `{:inspector_stream_reconciled, node, token, id, request, result}` to
  `reconciled/6` and project checkpoint messages from the updated state in that
  SAME LiveView callback. Independent history results must not overwrite them.
  `active?/2` includes snapshot-pending and reconciling watches, but not failures.

  `inspector_stream` is nil when detached, otherwise a map with `agent_id`,
  `node`, `token`, `snapshot`, `seq`, `snapshot_request`, `reconciling`,
  `required_seq`, `pending` (arrival-ordered batches), `error`, `state` and
  `buffer_bytes`. Tokens never reset. A failed attachment remains visible with
  an error and can be retried by calling `attach/2`.

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

  A retirement/replacement batch is held back in its entirety while `reconcile/1`
  requests a fresh atomic snapshot through the SAME idempotent watch runner and
  serial worker (no unsubscribe/register gap). Snapshot messages AND activity
  replace the rendered pair together, followed only by buffered seq > snapshot
  seq. If replay crosses another boundary it requests another snapshot instead
  of mixing new checkpoint history with an obsolete excerpt. Turn/yield/tool
  events alone never prove adoption. Explicit refreshes coalesce with an active
  request. Buffers cap at 128 batches / 1 MiB; overflow, stale snapshots and RPC
  failures fail visibly, preserve the last coherent rendered pair, and require
  explicit reattachment rather than silent loss or automatic error retries.
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
          snapshot_request: 0,
          reconciling: false,
          required_seq: 0,
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
        adopt_snapshot(socket, stream, result)

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

  @doc """
  Requests an atomic checkpoint/activity snapshot without unregistering the watch.

  Requests coalesce while one is outstanding. The old checkpoint/live pair stays
  rendered and all newer deltas buffer until `reconciled/6` admits the snapshot.
  Use this for explicit checkpoint refreshes (including a full-message modal),
  not an independent history RPC. Retirement/replacement invokes it automatically.
  """
  def reconcile(socket) do
    case socket.assigns[:inspector_stream] do
      %{snapshot: %Snapshot{}, reconciling: false, error: nil} = stream ->
        if active?(socket, stream.agent_id) do
          request = stream.snapshot_request + 1
          command(socket, {:reconcile, stream.token, request})

          assign(socket,
            inspector_stream: %{
              stream
              | snapshot_request: request,
                reconciling: true,
                required_seq: stream.seq
            }
          )
        else
          socket
        end

      _ ->
        socket
    end
  end

  @doc "Admits only the current watch's outstanding atomic reconciliation result."
  def reconciled(socket, target_node, token, agent_id, request, result) do
    case socket.assigns[:inspector_stream] do
      %{
        node: ^target_node,
        token: ^token,
        agent_id: ^agent_id,
        snapshot_request: ^request,
        reconciling: true,
        error: nil
      } = stream ->
        if active?(socket, agent_id), do: adopt_snapshot(socket, stream, result), else: socket

      _ ->
        socket
    end
  end

  defp adopt_snapshot(socket, stream, result) do
    case snapshot_result(result) do
      {:ok, snapshot, seq} when snapshot.agent_id == stream.agent_id ->
        if seq >= stream.required_seq do
          pending = stream.pending
          state = RuntimeStream.seed(stream.state, snapshot, seq)

          socket =
            assign(socket,
              inspector_stream: %{
                stream
                | snapshot: snapshot,
                  state: state,
                  seq: seq,
                  reconciling: false,
                  pending: [],
                  buffer_bytes: 0
              }
            )

          # Replaying may encounter ANOTHER ownership boundary after this
          # snapshot. Freeze at that batch and request the next atomic pair.
          Enum.reduce(pending, socket, fn {batch_seq, events}, socket ->
            apply_push(socket, stream.agent_id, batch_seq, events)
          end)
        else
          fail(socket, {:snapshot_before_boundary, seq, stream.required_seq})
        end

      {:ok, _snapshot, _seq} ->
        fail(socket, :snapshot_agent_mismatch)

      {:error, reason} ->
        fail(socket, reason)
    end
  end

  @doc "Buffers snapshot-pending batches; freezes ownership boundaries until atomic reconciliation."
  def push(socket, agent_id, seq, events)
      when is_integer(seq) and seq >= 0 and is_list(events) do
    if active?(socket, agent_id),
      do: apply_push(socket, agent_id, seq, events),
      else: socket
  end

  def push(socket, _agent_id, _seq, _events), do: socket

  defp apply_push(socket, agent_id, seq, events) do
    case socket.assigns[:inspector_stream] do
      %{agent_id: ^agent_id, error: nil, seq: old_seq}
      when is_integer(old_seq) and seq <= old_seq ->
        socket

      %{agent_id: ^agent_id, error: nil, snapshot: nil} = stream ->
        buffer(socket, stream, seq, events)

      %{agent_id: ^agent_id, error: nil, reconciling: true} = stream ->
        buffer(socket, stream, seq, events)

      %{agent_id: ^agent_id, error: nil} = stream ->
        if RuntimeStream.checkpoint_transition?(stream.state, events) do
          socket = reconcile(socket)
          stream = %{socket.assigns.inspector_stream | required_seq: seq}
          buffer(socket, stream, seq, events)
        else
          assign(socket,
            inspector_stream: %{
              stream
              | state: RuntimeStream.apply_batch(stream.state, agent_id, seq, events),
                seq: seq
            }
          )
        end

      _ ->
        socket
    end
  end

  defp buffer(socket, stream, seq, events) do
    # PubSub batches are ordered. Re-deliveries do not consume buffer capacity.
    last_seq =
      case List.last(stream.pending) do
        {last_seq, _} -> last_seq
        nil -> stream.seq
      end

    if is_integer(last_seq) and seq <= last_seq do
      socket
    else
      bytes = stream.buffer_bytes + :erlang.external_size({seq, events})

      if length(stream.pending) >= @max_pending_batches or bytes > @max_pending_bytes do
        fail(socket, :snapshot_buffer_overflow)
      else
        assign(socket,
          inspector_stream: %{
            stream
            | pending: stream.pending ++ [{seq, events}],
              buffer_bytes: bytes
          }
        )
      end
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
          snapshot_request: 0,
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
          inspector_stream: %{
            stream
            | error: reason,
              reconciling: false,
              pending: [],
              buffer_bytes: 0
          }
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
                 (state.failed and state.attempted == desired_request(state))) ->
            unwatch(state.registered, state.consumer)
            worker(%{state | registered: nil})

          state.desired != nil and state.attempted != desired_request(state) ->
            desired = state.desired

            result =
              SafeCall.run(fn -> desired.watch.(desired.node, desired.id, state.consumer) end)

            message =
              if desired.snapshot_request == 0 do
                {:inspector_stream_ready, desired.node, desired.token, desired.id, result}
              else
                {:inspector_stream_reconciled, desired.node, desired.token, desired.id,
                 desired.snapshot_request, result}
              end

            send(state.consumer, message)

            worker(%{
              state
              | registered: desired,
                attempted: desired_request(state),
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

  defp worker_message(state, {:reconcile, token, request}) do
    case state.desired do
      %{token: ^token, snapshot_request: previous} = desired
      when request > previous and not state.stopping ->
        %{state | desired: %{desired | snapshot_request: request}}

      _ ->
        state
    end
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
  defp desired_request(%{desired: nil}), do: nil
  defp desired_request(state), do: {state.desired.token, state.desired.snapshot_request}
end
