defmodule EvoGit.Agent.Session.TerminalHandoff do
  @moduledoc """
  Direct, watched-only delivery of the session's authoritative terminal snapshot.

  The session calls `deliver/2` exactly once in its normal finalization path, after
  adopting the final state, retiring activity and flushing deltas, but before
  publishing the final summary or delivering the scheduler result. The session
  builds ONE snapshot at that post-flush sequence cut and passes it here.

  The snapshot must have `phase: :done` and `status: :done | :failed`, with the
  status taken from the same terminal decision as the final summary. Adding that
  status field to `EvoGit.Agent.Stream.Snapshot` is an integration prerequisite;
  this helper does not construct or extend the snapshot struct itself.

  This module only sends to the registered watcher pids (including remote pids).
  It does not publish through PubSub, increment the sequence, retain a snapshot,
  or retry delivery. Exactly-once invocation belongs to the session's finalizer,
  not to a second lifecycle or deduplication store here. Force cancellation and
  abnormal termination must not call it from `terminate/3`.
  """

  alias EvoGit.Agent.Stream.Snapshot

  @doc """
  Sends `{:agent_stream_closed, agent_id, snapshot, seq}` to each watcher.

  `watchers` is the session-owned `%{pid => monitor_ref}` map, not a PubSub
  subscriber list. An empty map is a no-op. There is deliberately no local-only
  `Process.alive?/1` probe: `send/2` also accepts remote pids, and a dead watcher
  needs no recovery. No acknowledgement or consumer processing order is implied.
  """
  @spec deliver(%{pid() => reference()}, Snapshot.t()) :: :ok
  def deliver(watchers, %{__struct__: Snapshot, phase: :done, status: status} = snapshot)
      when is_map(watchers) and status in [:done, :failed] do
    message = {:agent_stream_closed, snapshot.agent_id, snapshot, snapshot.seq}

    Enum.each(watchers, fn {pid, _monitor_ref} -> send(pid, message) end)
    :ok
  end
end
