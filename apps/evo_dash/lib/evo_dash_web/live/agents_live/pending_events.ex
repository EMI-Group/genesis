defmodule EvoDashWeb.AgentsLive.PendingEvents do
  @moduledoc """
  Pure bookkeeping for the Agents page's agent-event coalescing buffer.

  The `"agents"` PubSub topic is high-frequency: a task spawns and updates
  agents in bursts, and every `{:agent_registered, id, summary, node}` /
  `{:agent_updated, id, changed_fields, node}` / `{:agent_removed, id, node}`
  broadcast previously triggered its own synchronous merge plus a full
  re-render of the whole agent tree. Two problems followed: the LiveView
  mailbox was starved (a user `phx-click` sat behind the burst), and a burst
  flushed to the browser in a single visual jump when a backgrounded tab was
  foregrounded.

  This module owns the pure buffer mechanics of the fix: the flush window
  constant, an O(1) newest-first append, the "should a flush timer be
  scheduled?" decision, and the arrival-order drain used when the buffer is
  applied. The LiveView keeps the socket-mutating merge/flush logic; the
  buffer itself is a plain list stored in the `:pending_agent_events` assign
  (newest-first, so appending is a prepend).
  """

  # The coalescing window (milliseconds) — the trailing-edge debounce used to
  # flush buffered agent events into a single merge + render.
  @flush_ms 300

  @doc """
  The trailing-edge flush window in milliseconds.
  """
  @spec flush_ms() :: pos_integer()
  def flush_ms, do: @flush_ms

  @doc """
  An empty buffer.
  """
  @spec new() :: [tuple()]
  def new, do: []

  @doc """
  Buffers `event` newest-first (prepend — O(1)). `drain/1` restores arrival
  order.
  """
  @spec append([tuple()], tuple()) :: [tuple()]
  def append(buffer, event), do: [event | buffer]

  @doc """
  Whether a flush timer should be scheduled. Only the FIRST event of a window
  schedules the timer — while a flush is already scheduled the flag is truthy
  and subsequent events are appended to the existing buffer without a second
  timer.
  """
  @spec should_schedule?(boolean()) :: boolean()
  def should_schedule?(scheduled?), do: not scheduled?

  @doc """
  Drains the buffer in ARRIVAL order (reverses the newest-first prepend
  order). The buffer is expected to be discarded by the caller after draining.
  """
  @spec drain([tuple()]) :: [tuple()]
  def drain(buffer), do: Enum.reverse(buffer)
end
