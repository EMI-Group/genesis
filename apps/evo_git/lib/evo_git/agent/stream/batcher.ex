defmodule EvoGit.Agent.Stream.Batcher do
  @moduledoc """
  The ONE delta-coalescing buffer: PURE data plus PURE functions.

  This struct is the only batching logic in the codebase — nothing else may re-implement it.
  It holds the events accumulated since the last flush and the reference of the pending flush
  timer; it NEVER fires that timer and never sends anything, because the timer belongs to the
  owning process (the session), which owns its own `Process.send_after/3` and receives the
  resulting message.

  A batcher is threaded by value: `push/2` appends in EMISSION order (a delta's position in a
  batch must reflect the order the emitter produced it), `take/1` drains the whole buffer and
  returns a FRESH empty batcher, and the timer accessors let the owner attach/drop a pending
  flush without the buffer knowing about time.
  """

  alias EvoGit.Agent.Stream

  @type t :: %__MODULE__{events: [term()], timer: reference() | nil}

  defstruct events: [], timer: nil

  # The single ~60-80 ms coalescing window. The session MUST read this and never use a local
  # literal, so the whole system batches on one clock.
  @flush_interval_ms 75

  @doc """
  The coalescing window in milliseconds (`75`).

  Coalescing turns a burst of token-sized chunks into a handful of PubSub messages per second
  without adding perceptible latency: it is comfortably inside the ~60-80 ms budget the delta
  contract specifies.
  """
  @spec flush_interval_ms() :: pos_integer()
  def flush_interval_ms, do: @flush_interval_ms

  @doc "A new, empty batcher with no pending timer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Whether the buffer holds no events (a flush is then a no-op)."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{events: []}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Appends one event (or a list of events) in emission order.

  The argument is normalized through `EvoGit.Agent.Stream.normalize_batch/1`, so an emitter may
  hand over either shape and the buffer always stores a flat ordered list.
  """
  @spec push(t(), term()) :: t()
  def push(%__MODULE__{events: events} = batcher, event_or_list) do
    %{batcher | events: events ++ Stream.normalize_batch(event_or_list)}
  end

  @doc """
  Drains the buffer: `{events, fresh_batcher}`.

  The returned batcher is empty and has NO timer, so the owner cannot accidentally reuse the
  reference of a timer that has already fired.
  """
  @spec take(t()) :: {[term()], t()}
  def take(%__MODULE__{events: events}), do: {events, new()}

  @doc "Records the reference of the pending flush timer."
  @spec set_timer(t(), reference()) :: t()
  def set_timer(%__MODULE__{} = batcher, ref) when is_reference(ref), do: %{batcher | timer: ref}

  @doc "Drops the pending flush timer (nothing is cancelled here — the owner owns the timer)."
  @spec clear_timer(t()) :: t()
  def clear_timer(%__MODULE__{} = batcher), do: %{batcher | timer: nil}

  @doc "The reference of the pending flush timer (`nil` when none is scheduled)."
  @spec timer(t()) :: reference() | nil
  def timer(%__MODULE__{timer: timer}), do: timer
end
