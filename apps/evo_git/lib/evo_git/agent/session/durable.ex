defmodule EvoGit.Agent.Session.Durable do
  @moduledoc """
  The durable-state PROJECTIONS every session-side module shares.

  A `%EvoGit.Agent.State{}` is read through THREE shapes on the durability path —
  its conversation, its transcript length and ("is this the same run?") its
  identity — and each one used to be re-implemented privately in the module that
  needed it. They live here ONCE so a reader of the conversation can never
  disagree with the writer of it (the transcript projection in particular must be
  the SAME for the checkpoint writer, the adoption rule and `history/2`, or a
  boundary would compare two different lists).

  ## Totality

  Every function is TOTAL: a non-state, a struct whose `context` is a plain map
  (or `nil`) and a blank identity all degrade to the documented empty answer
  (`[]`, `0`, `false`) instead of raising, because durable state is an
  optimisation for recovery and never a prerequisite for running.
  """

  alias EvoGit.Agent.State

  @doc """
  The conversation messages of a state, or `[]`.

  Deliberately TOLERANT about where the list lives: a real
  `%ReqLLM.Context{messages: …}`, a plain map with the same key and a restored
  state whose context was rebuilt by hand all project the same way. Narrowing
  this to `%ReqLLM.Context{}` silently answers `[]` for the other shapes, which
  is exactly the drift this module exists to prevent.
  """
  @spec messages(State.t()) :: [term()]
  def messages(%State{context: %{messages: messages}}) when is_list(messages), do: messages
  def messages(_state), do: []

  @doc "The transcript LENGTH of a state (never a walk of a non-list context)."
  @spec transcript_size(State.t()) :: non_neg_integer()
  def transcript_size(%State{} = state), do: length(messages(state))
  def transcript_size(_state), do: 0

  @doc """
  True when `state` identifies a durable run: a non-blank `task_id` and an
  integer `agent_id`, i.e. the exact `(task_id, agent_id)` key an
  `agent_states` row is stored under.
  """
  @spec valid_identity?(term()) :: boolean()
  def valid_identity?(%State{task_id: task_id, agent_id: agent_id}),
    do: valid_identity?(task_id, agent_id)

  def valid_identity?(_state), do: false

  @doc """
  True when a `(task_id, agent_id)` pair can key a durable row: the task id is a
  NON-BLANK binary and the agent id is an integer.

  Shared by the session writer (`EvoGit.Agent.Session.Persistence`) and the pause
  finalizer (`EvoGit.Agent.Session.Pause`), which must agree on what "this run has
  a durable identity" means — a write and a marker that disagreed would leave a
  paused run un-resumable for no visible reason.
  """
  @spec valid_identity?(term(), term()) :: boolean()
  def valid_identity?(task_id, agent_id) do
    is_binary(task_id) and String.trim(task_id) != "" and is_integer(agent_id)
  end
end
