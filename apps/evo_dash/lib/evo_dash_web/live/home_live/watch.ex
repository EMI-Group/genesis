defmodule EvoDashWeb.HomeLive.Watch do
  @moduledoc """
  Owns the `/assistant` page's PUSH-ONLY agent-delta watch lifecycle.

  The core contract (`EvoGit.Agent.Stream`) has TWO halves, and they must run in
  DIFFERENT processes:

    * the PubSub SUBSCRIPTION is CONSUMER-LOCAL — deltas are delivered to the
      process that subscribed, and the core's per-process memo makes a repeat
      subscribe a no-op. It is therefore made INLINE by the LiveView process in
      `attach/1` (and undone inline by `detach/1`);
    * the WATCHER REGISTRATION + snapshot is a SESSION call — it may cross a node
      boundary and reads the session's whole transcript, so it runs in an
      `EvoDash.TaskSupervisor` child with the LIVEWIEW pid as the consumer (the
      session `Process.monitor/1`s that pid, so it reaps a dead page by itself).

  That split is why the page drops every delta until the snapshot lands: the
  page keeps `chat_stream: %{agent_id, node, delta}` with `delta: nil` while the
  registration is in flight, and `handle_info({:agent_delta, ...})` only applies
  a batch once `delta` is a `%Delta{}` with an integer `seq`. A delta published
  in the gap between the subscribe and the snapshot is not lost — it is covered
  by the snapshot's `seq` (`EvoGit.Agent.Stream.stale?/2`), which is the ONLY
  reconciliation rule of the contract (no replay buffer, no poll loop).

  ## Runner seams (resolved at spawn time)

    * `:home_agent_watch_runner` — 3-arity `(node, agent_id, watcher_pid)`,
      default `&EvoDash.NodeContext.register_agent_watcher/3`. Returns the flat
      `{:ok, %EvoGit.Agent.Stream.Snapshot{}, seq} | {:error, term}`.
    * `:home_agent_unwatch_runner` — 3-arity `(node, agent_id, watcher_pid)`,
      default `&EvoDash.NodeContext.unregister_agent_watcher/3`.

  Everything here is TOTAL: a dead render, a missing assign, a non-map
  `chat_stream` and an unexpected runner answer all degrade instead of raising.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1]

  alias EvoGit.Agent.Stream.Snapshot
  alias EvoDash.{NodeContext, SafeCall, TaskSupervisor}
  alias EvoDashWeb.HomeLive.Delta

  @watch_runner_key :home_agent_watch_runner
  @unwatch_runner_key :home_agent_unwatch_runner

  @doc """
  Attaches the page to its session's delta stream (LiveView process only).

  A no-op unless the socket is CONNECTED and `session_id` is a positive integer
  (the interactive-session identity). It first detaches a stream belonging to a
  DIFFERENT agent, then subscribes THIS process, then spawns the watcher
  registration with this pid as the consumer and stamps a fresh
  `stream_attach_seq`.

  Re-attaching the SAME agent id deliberately does NOT detach first: registering
  the same pid again is idempotent core-side, while a detach → re-register could
  race the fire-and-forget unregister.
  """
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    agent_id = socket.assigns[:session_id]

    if connected?(socket) and positive_int?(agent_id) do
      socket = detach_other(socket, agent_id)
      node = socket.assigns[:current_node]

      _ = NodeContext.subscribe_agent_deltas(agent_id)

      seq = (socket.assigns[:stream_attach_seq] || 0) + 1
      pid = self()

      runner =
        Application.get_env(:evo_dash, @watch_runner_key, &NodeContext.register_agent_watcher/3)

      _ =
        Task.Supervisor.start_child(TaskSupervisor, fn ->
          send(
            pid,
            {:chat_stream_ready, node, seq, agent_id,
             SafeCall.run(fn -> runner.(node, agent_id, pid) end)}
          )
        end)

      assign(socket,
        chat_stream: %{agent_id: agent_id, node: node, delta: nil},
        chat_stream_meta: nil,
        stream_attach_seq: seq
      )
    else
      socket
    end
  end

  @doc """
  Detaches the page from its session's delta stream.

  Unsubscribes THIS process inline and fires the watcher unregister in a
  supervised child (nothing is reported back — a gone watcher is reaped by the
  session's own monitor anyway), then clears `chat_stream`/`chat_stream_meta`.
  Idempotent and total: a nil/non-map `chat_stream` only clears the assigns.
  """
  @spec detach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def detach(socket) do
    case socket.assigns[:chat_stream] do
      %{agent_id: agent_id, node: node} ->
        _ = NodeContext.unsubscribe_agent_deltas(agent_id)

        pid = self()

        runner =
          Application.get_env(
            :evo_dash,
            @unwatch_runner_key,
            &NodeContext.unregister_agent_watcher/3
          )

        _ = Task.Supervisor.start_child(TaskSupervisor, fn -> runner.(node, agent_id, pid) end)

        assign(socket, chat_stream: nil, chat_stream_meta: nil)

      _other ->
        assign(socket, chat_stream: nil, chat_stream_meta: nil)
    end
  end

  @doc """
  Turns a watcher-registration result into the page's stream seed.

  Accepts the runner's flat `{:ok, %EvoGit.Agent.Stream.Snapshot{}, seq}` — and
  the `EvoDash.SafeCall`-wrapped `{:ok, {:ok, %Snapshot{}, seq}}` the async
  registration task actually sends — and answers
  `{:ok, %{snapshot:, delta:, meta:}}`, where the delta is seeded with the
  snapshot's seq/turn and the meta carries its turn/token/usage accounting.
  Every other shape (including an `{:error, reason}`) is `{:error, reason}`.
  Total: never raises.
  """
  @spec snapshot_result(term(), term(), node() | nil) ::
          {:ok, %{snapshot: Snapshot.t(), delta: Delta.t(), meta: map()}} | {:error, term()}
  def snapshot_result(result, agent_id, node) do
    snapshot =
      case result do
        {:ok, %Snapshot{} = snapshot, _seq} -> snapshot
        {:ok, {:ok, %Snapshot{} = snapshot, _seq}} -> snapshot
        _other -> nil
      end

    seq =
      case result do
        {:ok, %Snapshot{}, seq} -> seq
        {:ok, {:ok, %Snapshot{}, seq}} -> seq
        _other -> nil
      end

    if is_struct(snapshot, Snapshot) do
      delta = Delta.seed(Delta.new(agent_id, node, seq), snapshot, seq)

      meta = %{
        Delta.meta()
        | turn: snapshot.turn,
          total_tokens: snapshot.total_tokens,
          usage: snapshot.usage
      }

      {:ok, %{snapshot: snapshot, delta: delta, meta: meta}}
    else
      {:error, unwrap_error(result)}
    end
  end

  @doc """
  Whether the page currently has a SEEDED stream (a delta with an integer seq),
  i.e. deltas are being applied instead of being dropped.

  Used by the `"agents"` handlers to skip the per-message-count history refetch
  while a stream is live — that refetch IS the polling this feature removes.
  """
  @spec stream_active?(Phoenix.LiveView.Socket.t()) :: boolean()
  def stream_active?(socket) do
    case socket.assigns[:chat_stream] do
      %{delta: %Delta{seq: seq}} when is_integer(seq) -> true
      _other -> false
    end
  end

  # Only a stream belonging to a DIFFERENT agent is torn down first; the same
  # agent is re-registered idempotently (see attach/1).
  defp detach_other(socket, agent_id) do
    case socket.assigns[:chat_stream] do
      %{agent_id: ^agent_id} -> socket
      %{} -> detach(socket)
      _other -> socket
    end
  end

  defp unwrap_error({:ok, {:error, reason}}), do: reason
  defp unwrap_error({:error, reason}), do: reason
  defp unwrap_error(result), do: result

  defp positive_int?(id), do: is_integer(id) and id > 0
end
