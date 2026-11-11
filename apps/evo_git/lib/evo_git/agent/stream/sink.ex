defmodule EvoGit.Agent.Stream.Sink do
  @moduledoc """
  The worker-process-local, DEFAULT-INERT emitter of live deltas.

  The exchange worker installs this sink at the start of a run and the LLM call path asks it for
  the `ReqLLM.StreamResponse.process_stream/2` callbacks. Two properties keep the unwatched path
  byte-identical to the pre-streaming runtime:

    * `stream_opts/0` returns `[]` unless the sink is installed AND the session reports a live
      watcher — so an unwatched turn passes no callbacks at all and ReqLLM does no extra work;
    * `emit/1` is a no-op when nothing is installed, so a stray call can never send a message.

  ## The session gate

  The gate is `EvoGit.Agent.Session.watching?/2` — the session's own watcher count, which no
  `Registry` or `Phoenix.PubSub` can answer (`Registry.register/2` only registers the CALLING
  process and PubSub exposes no subscriber count). It is checked ONCE per `stream_opts/0`
  invocation, i.e. exactly once per LLM attempt, which is the specified cadence: a watcher that
  attaches mid-attempt is served from the next attempt's batch on (and from a snapshot).

  ## Process dictionary (process-local, NEVER persisted)

  The sink lives in the WORKER process (the exchange worker, one per agent at a time), never in
  the state, never on disk and never across a process boundary:

  | Key                        | Value                | Meaning                                    |
  |----------------------------|----------------------|--------------------------------------------|
  | `:evogit_stream_session`   | `pid()`              | the session that receives `{:delta, …}`    |
  | `:evogit_stream_agent_id`  | `term()`             | the agent id the deltas belong to          |

  ## Deltas

  `emit/1` sends `{:delta, events}` to the session with the events ALWAYS a list (normalized via
  `EvoGit.Agent.Stream.normalize_batch/1`), so the session can append them to its batcher without
  caring which shape an emitter preferred.

  A tool-call chunk carries no call id (ReqLLM reconstructs ids from the fully accumulated
  response), so `:on_tool_call` emits `{:tool_call, nil, name}`. The id-bearing
  `{:tool_call, id, name}` is emitted later, from the tool-dispatch side.
  """

  alias EvoGit.Agent.Session
  alias EvoGit.Agent.Stream
  alias EvoGit.Agent.Stream.Interrupted

  @session_key :evogit_stream_session
  @agent_id_key :evogit_stream_agent_id

  @doc """
  Installs the sink in the CALLING process: deltas go to `session_pid` for `agent_id`.

  Purely a process-dictionary write (no message, no registration), so an installed-but-unwatched
  run still costs nothing.
  """
  @spec install(pid(), term()) :: :ok
  def install(session_pid, agent_id) when is_pid(session_pid) do
    Process.put(@session_key, session_pid)
    Process.put(@agent_id_key, agent_id)
    :ok
  end

  @doc "Removes the sink from the CALLING process (idempotent)."
  @spec uninstall() :: :ok
  def uninstall do
    Process.delete(@session_key)
    Process.delete(@agent_id_key)
    :ok
  end

  @doc "Whether the CALLING process has an installed sink."
  @spec installed?() :: boolean()
  def installed?, do: is_pid(Process.get(@session_key))

  @doc """
  The `process_stream/2` callbacks for one LLM attempt, or `[]` when the sink is inert.

  `[]` covers both "not installed" (a direct/test process) and "no live watcher" (the session
  gate is closed), so an unwatched turn installs no callbacks whatsoever.
  """
  @spec stream_opts() :: keyword()
  def stream_opts do
    with session_pid when is_pid(session_pid) <- Process.get(@session_key),
         true <- watching?(session_pid) do
      [
        on_result: &on_result/1,
        on_thinking: &on_thinking/1,
        on_tool_call: &on_tool_call/1,
        on_chunk: &on_chunk/1
      ]
    else
      _other -> []
    end
  end

  @doc """
  Sends a delta (or a list of deltas) to the session.

  A no-op when the sink is not installed. Never raises: the argument is normalized first, so the
  session always receives a list of events.
  """
  @spec emit(term()) :: :ok
  def emit(event_or_list) do
    case Process.get(@session_key) do
      session_pid when is_pid(session_pid) ->
        send(session_pid, {:delta, Stream.normalize_batch(event_or_list)})

      _other ->
        :ok
    end

    :ok
  end

  @doc """
  Whether an interrupt was requested for the CALLING process.

  A non-blocking mailbox peek at the documented `{:evogit_interrupt, _ref}` message: when it is
  present it is CONSUMED (so an interrupt is honoured exactly once) and `true` is returned. Never
  blocks and never raises.
  """
  @spec interrupt_requested?() :: boolean()
  def interrupt_requested? do
    receive do
      {:evogit_interrupt, _ref} -> true
    after
      0 -> false
    end
  end

  @doc """
  Drops a stale `{:evogit_interrupt, _ref}` from the CALLING process's mailbox.

  Total and idempotent: called when a new exchange starts (or after an interrupt was handled), so
  an interrupt sent between exchanges cannot abort the next stream.
  """
  @spec clear_interrupt() :: :ok
  def clear_interrupt do
    receive do
      {:evogit_interrupt, _ref} -> clear_interrupt()
    after
      0 -> :ok
    end
  end

  # The gate is consulted once per `stream_opts/0` call, i.e. once per LLM attempt.
  defp watching?(session_pid), do: Session.watching?(session_pid)

  defp on_result(chunk), do: emit({:text, chunk})

  defp on_thinking(chunk), do: emit({:thinking, chunk})

  # A stream chunk carries no call id (see the moduledoc), so the id slot is `nil`.
  defp on_tool_call(chunk), do: emit({:tool_call, nil, chunk.name})

  # The per-chunk interrupt check: raising here is how an interrupt pre-empts a stream, because
  # `ReqLLM.StreamResponse.process_stream/2` rescues the raise and returns `{:error, %Interrupted{}}`.
  defp on_chunk(_chunk) do
    if interrupt_requested?(), do: raise(Interrupted, reason: :interrupted)

    :ok
  end
end
