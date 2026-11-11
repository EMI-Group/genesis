defmodule EvoGit.Agent.Stream do
  @moduledoc """
  The consumer-facing entry point of the PUSH-ONLY delta contract.

  One call does everything a consumer needs: `watch/1` subscribes the caller to the per-agent
  `EvoGit.PubSub` topic, registers it in the session's own watcher set and returns the current
  snapshot plus its `seq`. After that, deltas are PUSHED — `{:agent_delta, agent_id, seq, batch}`
  in the production broadcast shape — and the consumer never polls:

    * a delta whose `seq` is `<=` the snapshot's `seq` is stale and must be dropped
      (`stale?/2` is that whole reconciliation rule);
    * a consumer that fell behind or reconnected catches up with a FRESH snapshot, never with a
      replayed ring buffer or a cursor read — `snapshot/1` is the only resync.

  ## Why the session owns the gate

  The watcher set lives in the session's `%EvoGit.Agent.State{}` (`watchers`), where the session
  `Process.monitor/1`s each consumer, so a dead watcher is reaped by its own `:DOWN` — local or
  remote — with no bookkeeping process. That is also why the streaming gate is the session's
  `watching?/2` boolean and not something a `Registry` or `Phoenix.PubSub` could answer.

  ## Totality and error shapes

  Every public function is TOTAL: it never raises and never exits out of this API. A missing
  session, an unstarted registry, a dead process, a timeout and an unavailable PubSub all degrade
  to a documented value. The only error shapes are
  `{:error, {:not_found, reason}}` and `{:error, {:bad_state, phase}}`.

  ## Watch ordering is load-bearing

  `watch/1` subscribes to the topic BEFORE it registers the watcher and takes the snapshot. A
  delta broadcast in that gap is either already covered by the snapshot (`seq <= snapshot.seq`,
  so the consumer drops it) or newer than the snapshot (so it is delivered normally) — there is
  no window in which a delta can be lost. Registering first would create one: the session would
  emit between registration and subscription.
  """

  alias EvoGit.Agent.Session
  alias EvoGit.Agent.Stream.Snapshot

  # The same short deadline every session call uses: every session command is answerable in
  # microseconds because the owner never runs the exchange itself.
  @call_timeout 5_000

  @typedoc "A session pid, or a value that resolves to one through the session registry."
  @type target :: pid() | term()

  @typedoc """
  One live delta.

  `{:tool_call, nil, name}` is what a STREAM chunk can report (ReqLLM reconstructs call ids from
  the accumulated response); the id-bearing `{:tool_call, id, name}` comes from tool dispatch.
  """
  @type event ::
          {:text, String.t()}
          | {:thinking, String.t()}
          | {:tool_call, term(), String.t()}
          | {:tool_result, term(), term()}
          | {:turn, map()}
          | {:yield, String.t()}
          | {:finished, atom()}

  @type error :: {:error, {:not_found, term()} | {:bad_state, Session.phase()}}

  @doc """
  The `EvoGit.PubSub` topic of one agent: `"agent:<agent_id>"`.
  """
  @spec topic(term()) :: String.t()
  def topic(agent_id), do: "agent:" <> to_string(agent_id)

  @doc """
  Attaches the CALLING process as a watcher of the agent's session.

  Subscribes to `topic(agent_id)` FIRST, then registers the calling pid in the session (which
  monitors it) and returns `{:ok, snapshot, seq}`. On a registration failure the subscription is
  undone again, so a refused watch leaves no residue.

  `target` is a session pid (its agent id is read with `EvoGit.Agent.Session.identity/2`, because
  the topic is keyed by id) or an agent id (resolved through
  `EvoGit.Agent.Session.whereis/1`).
  """
  @spec watch(target()) :: {:ok, Snapshot.t(), non_neg_integer()} | error()
  def watch(target) do
    with {:ok, pid, agent_id} <- resolve_with_id(target),
         :ok <- subscribe(agent_id) do
      case register_at(pid, self()) do
        {:ok, _snapshot, _seq} = ok ->
          ok

        {:error, _reason} = error ->
          unsubscribe(agent_id)
          error
      end
    end
  end

  @doc """
  Registers an ARBITRARY consumer pid (the RPC-facing primitive) and returns the snapshot.

  Unlike `watch/1` this does NOT subscribe anything: a remote consumer subscribes to its OWN
  node's `EvoGit.PubSub` and only needs its (possibly external) pid in the session's watcher set,
  which `Process.monitor/1` accepts for a remote pid.
  """
  @spec register_watcher(target(), pid()) ::
          {:ok, Snapshot.t(), non_neg_integer()} | error()
  def register_watcher(target, consumer_pid) when is_pid(consumer_pid) do
    with {:ok, pid} <- resolve(target) do
      register_at(pid, consumer_pid)
    end
  end

  @doc """
  Removes `consumer_pid` from the session's watcher set (the RPC-facing counterpart of
  `register_watcher/2`).

  `:ok` when the watcher is gone (or was never registered) — unregistering is idempotent.
  """
  @spec unregister_watcher(target(), pid()) :: :ok | error()
  def unregister_watcher(target, consumer_pid) when is_pid(consumer_pid) do
    with {:ok, pid} <- resolve(target) do
      unregister_at(pid, consumer_pid)
    end
  end

  @doc """
  Detaches the CALLING process: unregisters it and unsubscribes it from the agent's topic.

  Idempotent and TOTAL (`:ok` even when the session, the watcher entry or PubSub is already
  gone). A target that no longer resolves also answers `:ok`: the caller's own subscription dies
  with its process, so there is nothing left to clean up.
  """
  @spec unwatch(target()) :: :ok
  def unwatch(target) do
    case resolve_with_id(target) do
      {:ok, pid, agent_id} ->
        _ = unregister_at(pid, self())
        unsubscribe(agent_id)

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  One bounded one-shot read of the session's current snapshot.

  This is the ONLY resync path (never a poll loop): a consumer that fell behind, reconnected or
  lost a delta asks once and continues from the returned `seq`.
  """
  @spec snapshot(target()) :: {:ok, Snapshot.t(), non_neg_integer()} | error()
  def snapshot(target) do
    with {:ok, pid} <- resolve(target) do
      call(pid, {:snapshot})
    end
  end

  @doc """
  Whether a delta with `seq` is stale against `snapshot_seq` and must be DROPPED.

  `seq <= snapshot_seq` is the whole reconciliation rule. A pair that is not two integers is not a
  comparable delta (a malformed or absent tag), so it is dropped as well — failing CLOSED here can
  only lose a delta that a fresh snapshot would restore, while failing open could apply it twice.
  """
  @spec stale?(term(), term()) :: boolean()
  def stale?(seq, snapshot_seq) when is_integer(seq) and is_integer(snapshot_seq),
    do: seq <= snapshot_seq

  def stale?(_seq, _snapshot_seq), do: true

  @doc """
  Normalizes an emitter's payload into a LIST of events.

  Accepts a single event, a list of events, or `nil` (nothing emitted), so a consumer never has to
  care which shape an emitter used.
  """
  @spec normalize_batch(term()) :: [term()]
  def normalize_batch(nil), do: []
  def normalize_batch(batch) when is_list(batch), do: batch
  def normalize_batch(event), do: [event]

  # --- target resolution ---

  # An agent id needs the registry; a pid needs `identity/2`, because the topic is keyed by the
  # agent id and a pid alone cannot produce it.
  defp resolve_with_id(pid) when is_pid(pid) do
    case Session.identity(pid) do
      {:ok, agent_id} -> {:ok, pid, agent_id}
      :error -> {:error, {:not_found, :session_unavailable}}
    end
  end

  defp resolve_with_id(agent_id) when is_integer(agent_id) or is_binary(agent_id) do
    case Session.whereis(agent_id) do
      {:ok, pid} -> {:ok, pid, agent_id}
      :error -> {:error, {:not_found, :session_not_found}}
    end
  end

  defp resolve_with_id(_other), do: {:error, {:not_found, :invalid_target}}

  defp resolve(pid) when is_pid(pid), do: {:ok, pid}

  defp resolve(agent_id) when is_integer(agent_id) or is_binary(agent_id) do
    case Session.whereis(agent_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, {:not_found, :session_not_found}}
    end
  end

  defp resolve(_other), do: {:error, {:not_found, :invalid_target}}

  # --- session calls (TOTAL) ---

  # `:gen_statem.call/3` EXITS on a dead, stopping or unresponsive session (`:noproc`, `:normal`,
  # `:timeout`). Every function here is TOTAL, so the exit becomes the documented fallback — the
  # same `catch` boundary `EvoGit.Agent.Session.call/3` keeps for the same reason.
  defp call(pid, request, normalizer \\ &normalize_read_reply/1) do
    reply =
      try do
        :gen_statem.call(pid, request, @call_timeout)
      catch
        :exit, :timeout -> {:error, {:not_found, :timeout}}
        :exit, _reason -> {:error, {:not_found, :session_unavailable}}
      end

    normalizer.(reply)
  end

  defp register_at(pid, consumer_pid) do
    call(pid, {:watch, consumer_pid}, &normalize_snapshot_reply/1)
  end

  defp unregister_at(pid, consumer_pid) do
    call(pid, {:unwatch, consumer_pid}, &normalize_ok_reply/1)
  end

  defp normalize_snapshot_reply({:ok, %Snapshot{} = snapshot, seq}), do: {:ok, snapshot, seq}

  defp normalize_snapshot_reply({:error, {kind, reason}}) when kind in [:not_found, :bad_state],
    do: {:error, {kind, reason}}

  # Any other reply (the session's generic `{:error, :not_found}`, or a shape this phase does not
  # answer yet because the handler lands in the next phase) is a refusal, never a success.
  defp normalize_snapshot_reply(_other), do: {:error, {:not_found, :watch_not_supported}}

  defp normalize_read_reply({:ok, %Snapshot{} = snapshot, seq}), do: {:ok, snapshot, seq}

  defp normalize_read_reply({:error, {kind, reason}}) when kind in [:not_found, :bad_state],
    do: {:error, {kind, reason}}

  defp normalize_read_reply(_other), do: {:error, {:not_found, :snapshot_not_supported}}

  defp normalize_ok_reply(:ok), do: :ok

  defp normalize_ok_reply({:error, {kind, reason}}) when kind in [:not_found, :bad_state],
    do: {:error, {kind, reason}}

  # An absent watcher entry is not a failure: unregistering is idempotent.
  defp normalize_ok_reply(_other), do: :ok

  # --- PubSub (guarded: subscribing to a dead PubSub EXITS) ---

  defp subscribe(agent_id) do
    if Process.whereis(EvoGit.PubSub) do
      case Phoenix.PubSub.subscribe(EvoGit.PubSub, topic(agent_id)) do
        :ok -> :ok
        {:error, reason} -> {:error, {:not_found, {:subscribe_failed, reason}}}
      end
    else
      {:error, {:not_found, :pubsub_unavailable}}
    end
  end

  defp unsubscribe(agent_id) do
    if Process.whereis(EvoGit.PubSub) do
      _ = Phoenix.PubSub.unsubscribe(EvoGit.PubSub, topic(agent_id))
      :ok
    else
      :ok
    end
  end
end
