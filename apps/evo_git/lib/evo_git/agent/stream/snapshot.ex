defmodule EvoGit.Agent.Stream.Snapshot do
  @moduledoc """
  The ONE point-in-time view a streaming consumer receives when it attaches.

  `EvoGit.Agent.Stream.watch/1` answers `{:ok, %Snapshot{}, seq}`, and that snapshot is the ONLY
  resync mechanism of the push-only delta contract: there is deliberately no replay ring buffer
  and no cursor/poll path, so a consumer that fell behind (or reconnected) simply asks for a
  fresh snapshot again.

  The struct is PLAIN DATA — no pids, no refs, no funs — so it is JSON-clean and can cross an RPC
  boundary unchanged. `seq` is the session's monotonic `event_seq` at snapshot time: a delta whose
  `seq` is `<= snapshot.seq` is stale and dropped (`EvoGit.Agent.Stream.stale?/2`), which is the
  whole reconciliation rule.

  `messages` is the FULL transcript of the state the session currently owns. Only
  `EvoGit.Agent.Session` owns the authoritative conversation, so the snapshot is the one supported
  way to read it without a per-message-count copy loop.
  """

  alias EvoGit.Agent.State

  @type t :: %__MODULE__{
          agent_id: term(),
          phase: State.phase() | nil,
          seq: non_neg_integer(),
          turn: non_neg_integer(),
          total_tokens: non_neg_integer(),
          usage: EvoGit.Agent.Usage.t() | nil,
          messages: [ReqLLM.Message.t()],
          mode: State.mode() | nil,
          model_spec: map() | nil,
          compression_count: non_neg_integer()
        }

  defstruct agent_id: nil,
            phase: nil,
            seq: 0,
            turn: 0,
            total_tokens: 0,
            usage: nil,
            messages: [],
            mode: nil,
            model_spec: nil,
            compression_count: 0

  @doc """
  Builds the snapshot of `state` for the session `phase` it is being reported in.

  The session only ever calls this with a real `%State{}` (a snapshot of a session that has not
  checkpointed yet is not offered), so no raising guard is added for impossible input. A state
  whose context is not a list of messages yields `[]` rather than leaking the raw term.
  """
  @spec from(State.t(), State.phase()) :: t()
  def from(%State{} = state, phase) do
    %__MODULE__{
      agent_id: state.agent_id,
      phase: phase,
      seq: state.event_seq,
      turn: state.turn,
      total_tokens: state.total_tokens,
      usage: state.usage,
      messages: messages(state),
      mode: state.mode,
      model_spec: state.model_spec,
      compression_count: state.compression_count
    }
  end

  defp messages(%State{context: %{messages: messages}}) when is_list(messages), do: messages
  defp messages(_state), do: []
end
