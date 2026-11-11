defmodule EvoGit.Agent.Stream.Watchers do
  @moduledoc """
  The ONE watcher-set and delta-flush mechanism of `EvoGit.Agent.Session`.

  The set is ordinary session DATA — `%{consumer_pid => monitor_ref}` — never a process, a
  `Registry` or an ETS table (D5).
  Registering a consumer is a `Process.monitor/1`, so a dead consumer (local or remote, because a
  monitor on a remote pid is a cross-node signal) is reaped by the session's own `:DOWN` with no
  bookkeeping process at all.

  A watcher is what opens the streaming gate: `watching?/1` is the same boolean the sink consults
  before installing any `ReqLLM.StreamResponse.process_stream/2` callback, so an unwatched session
  pays nothing.

  ## Re-registration and stale downs

  Re-registering a pid demonitors the OLD ref first, so one consumer can never strand a monitor.
  `unregister_ref/3` only removes the entry when the stored ref is the one that went down, so a
  stale `:DOWN` from an older registration can never evict a live re-registration.

  ## Flushing

  `flush/4` is the ONE coalescing flush.
  It drains the batcher, DROPS the events when no watcher is registered (nothing to publish, and
  no sequence number is consumed), and otherwise publishes exactly ONE
  `{:agent_delta, agent_id, seq + 1, events}` on the agent's `EvoGit.PubSub` topic.
  A broadcast can never take the session down: an unavailable PubSub degrades to a dropped batch
  that a fresh snapshot repairs.
  """

  alias EvoGit.Agent.Stream
  alias EvoGit.Agent.Stream.Batcher

  @type t :: %{pid() => reference()}

  @doc """
  Registers `consumer_pid` and returns the new watcher map.

  The consumer is monitored, and a previous registration of the SAME pid is demonitored (flushing
  its pending `:DOWN`) before the new ref is stored.
  """
  @spec register(t(), pid()) :: t()
  def register(watchers, consumer_pid) when is_map(watchers) and is_pid(consumer_pid) do
    watchers
    |> demonitor(consumer_pid)
    |> Map.put(consumer_pid, Process.monitor(consumer_pid))
  end

  @doc """
  Removes `consumer_pid` (demonitoring and flushing its ref) and returns the new watcher map.

  Idempotent: an absent entry is a no-op.
  """
  @spec unregister(t(), pid()) :: t()
  def unregister(watchers, consumer_pid) when is_map(watchers) and is_pid(consumer_pid) do
    demonitor(watchers, consumer_pid)
  end

  @doc """
  Removes `pid` ONLY when it is still monitored by `ref` — the `:DOWN` bookkeeping.

  No demonitor: the process is already dead, and a stale `:DOWN` must never evict a live
  re-registration that happened after the dying one.
  """
  @spec unregister_ref(t(), pid(), reference()) :: t()
  def unregister_ref(watchers, pid, ref) when is_map(watchers) and is_pid(pid) do
    case Map.get(watchers, pid) do
      ^ref -> Map.delete(watchers, pid)
      _other -> watchers
    end
  end

  @doc "Whether `pid` is currently monitored by `ref` in this watcher map."
  @spec watcher_ref?(t(), pid(), reference()) :: boolean()
  def watcher_ref?(watchers, pid, ref) when is_map(watchers) and is_pid(pid) do
    Map.get(watchers, pid) == ref
  end

  @doc "Whether ANY consumer watches — the streaming gate (zero watchers is the zero-cost path)."
  @spec watching?(t()) :: boolean()
  def watching?(watchers) when is_map(watchers), do: map_size(watchers) > 0

  @doc """
  Cancels a pending flush timer (when one is recorded) and clears it from the batcher.

  The buffered events are kept: this is the "drop the timer, flush now" primitive of the exit
  paths, not a discard.
  """
  @spec cancel_timer(Batcher.t()) :: Batcher.t()
  def cancel_timer(%Batcher{} = batcher) do
    case Batcher.timer(batcher) do
      nil ->
        batcher

      ref ->
        # A timer that already fired answers `false`; cancellation is best-effort either way,
        # because a late `:flush_deltas` finds an empty batch and is a no-op.
        _ = Process.cancel_timer(ref)
        Batcher.clear_timer(batcher)
    end
  end

  @doc """
  The ONE flush: `{batcher, seq}` after draining the batch through the watcher gate.

  * an EMPTY batch flushes nothing and cancels nothing — `{batcher, seq}` comes back untouched;
  * a non-empty batch with ZERO watchers is DROPPED (no broadcast, `seq` unchanged);
  * otherwise ONE `{:agent_delta, agent_id, seq + 1, events}` is broadcast and `seq` advances.
  """
  @spec flush(t(), Batcher.t(), term(), non_neg_integer()) :: {Batcher.t(), non_neg_integer()}
  def flush(watchers, %Batcher{} = batcher, agent_id, seq) when is_map(watchers) do
    if Batcher.empty?(batcher) do
      {batcher, seq}
    else
      {events, drained} = Batcher.take(batcher)

      if watching?(watchers) do
        broadcast(agent_id, seq + 1, events)
        {drained, seq + 1}
      else
        {drained, seq}
      end
    end
  end

  # --- internals ---

  defp demonitor(watchers, pid) do
    case Map.pop(watchers, pid) do
      {nil, watchers} ->
        watchers

      {ref, watchers} ->
        Process.demonitor(ref, [:flush])
        watchers
    end
  end

  # TOTAL by construction: a missing or restarted PubSub must never crash the emitting session.
  # An unavailable `:ok` shape is a dropped batch, which a consumer repairs with a fresh snapshot.
  defp broadcast(agent_id, seq, events) do
    Phoenix.PubSub.broadcast(EvoGit.PubSub, Stream.topic(agent_id), {
      :agent_delta,
      agent_id,
      seq,
      events
    })
  rescue
    _exception -> :ok
  catch
    # `Phoenix.PubSub.broadcast/3` EXITS when the named PubSub is not running; the batch is then
    # dropped rather than taking the session down with it.
    _kind, _reason -> :ok
  end
end
