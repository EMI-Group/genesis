defmodule EvoGit.Agent.Stream.Sink do
  @moduledoc """
  The worker-process-local, default-inert emitter of live activity and deltas.

  Installed sinks capture every LLM attempt, even without watchers, so the session can
  project the complete current call for a later snapshot. Publication remains watcher-gated
  in the session; no replay is retained. Without a sink, callbacks and emissions are inert.

  Activity messages are `{:activity, worker_pid, event}`. Callback closures capture the
  session, worker and call identity when installed, rather than reading a later attempt's
  process dictionary. Legacy deltas retain `{:delta, events}` for session compatibility.
  Streamed tool declarations still have no tool-call id (`{:tool_call, nil, name}`).
  """

  alias EvoGit.Agent.Stream
  alias EvoGit.Agent.Stream.Interrupted

  @session_key :evogit_stream_session
  @agent_id_key :evogit_stream_agent_id
  @turn_key :evogit_stream_turn
  @call_key :evogit_stream_call

  @doc "Installs the sink in the calling worker and clears stale interrupts and call identity."
  @spec install(pid(), term()) :: :ok
  def install(session_pid, agent_id) when is_pid(session_pid) do
    Process.put(@session_key, session_pid)
    Process.put(@agent_id_key, agent_id)
    Process.delete(@turn_key)
    Process.delete(@call_key)

    # WHY: an interrupt left over from an earlier exchange must not pre-empt this one.
    clear_interrupt()
    :ok
  end

  @doc "Removes the sink from the calling process (idempotent)."
  @spec uninstall() :: :ok
  def uninstall do
    Process.delete(@session_key)
    Process.delete(@agent_id_key)
    Process.delete(@turn_key)
    Process.delete(@call_key)
    :ok
  end

  @doc "Whether the calling process has an installed sink."
  @spec installed?() :: boolean()
  def installed?, do: is_pid(Process.get(@session_key))

  @doc "Starts a turn and resets its live activity."
  @spec start_turn(non_neg_integer()) :: :ok
  def start_turn(turn) do
    if installed?(), do: Process.put(@turn_key, turn)
    reset()
  end

  @doc "Starts an LLM attempt with a fresh string identity and returns that identity."
  @spec start_call(non_neg_integer()) :: String.t()
  def start_call(attempt) do
    id = Integer.to_string(System.unique_integer([:positive, :monotonic]))

    if installed?() do
      Process.put(@call_key, id)
      activity({:start_call, id, Process.get(@turn_key, 0), attempt})
    end

    id
  end

  @doc "Changes the phase of the identified call; stale identities are ignored by the projection."
  @spec call_phase(String.t(), EvoGit.Agent.Stream.Activity.phase()) :: :ok
  def call_phase(id, phase) do
    if Process.get(@call_key) == id and phase in [:idle, :retry_wait] do
      Process.delete(@call_key)
    end

    activity({:call_phase, id, phase})
  end

  @doc "Changes the activity phase, preserving the current call except on idle."
  @spec phase(EvoGit.Agent.Stream.Activity.phase()) :: :ok
  def phase(phase) do
    if phase == :idle, do: Process.delete(@call_key)
    activity({:phase, phase})
  end

  @doc "Resets activity to idle with no current call."
  @spec reset() :: :ok
  def reset do
    Process.delete(@call_key)
    activity(:reset)
  end

  @doc "LLM stream callbacks whenever a sink exists, independent of watcher count."
  @spec stream_opts() :: keyword()
  def stream_opts do
    case Process.get(@session_key) do
      session when is_pid(session) ->
        worker = self()
        id = Process.get(@call_key)

        [
          on_result: fn chunk -> send_activity(session, worker, {:chunk, id, :text, chunk}) end,
          on_thinking: fn chunk ->
            send_activity(session, worker, {:chunk, id, :thinking, chunk})
          end,
          on_tool_call: fn chunk ->
            send(session, {:delta, [{:tool_call, nil, chunk.name}]})
            :ok
          end,
          on_chunk: &on_chunk/1
        ]

      _other ->
        []
    end
  end

  @doc "Sends a non-empty normalized legacy delta batch; inert without an installed sink."
  @spec emit(term()) :: :ok
  def emit(event_or_list) do
    events = Stream.normalize_batch(event_or_list)

    with session_pid when is_pid(session_pid) <- Process.get(@session_key),
         [_ | _] <- events do
      send(session_pid, {:delta, events})
    end

    :ok
  end

  @doc "Consumes an interrupt for the calling process without blocking."
  @spec interrupt_requested?() :: boolean()
  def interrupt_requested? do
    receive do
      {:evogit_interrupt, _ref} -> true
    after
      0 -> false
    end
  end

  @doc "Drops stale interrupts from the calling process's mailbox (idempotent)."
  @spec clear_interrupt() :: :ok
  def clear_interrupt do
    receive do
      {:evogit_interrupt, _ref} -> clear_interrupt()
    after
      0 -> :ok
    end
  end

  defp activity(event) do
    case Process.get(@session_key) do
      session when is_pid(session) -> send_activity(session, self(), event)
      _other -> :ok
    end
  end

  defp send_activity(session, worker, event) do
    send(session, {:activity, worker, event})
    :ok
  end

  # ReqLLM rescues this raise and returns {:error, %Interrupted{}} to pre-empt the attempt.
  defp on_chunk(_chunk) do
    if interrupt_requested?(), do: raise(Interrupted, reason: :interrupted)
    :ok
  end
end
