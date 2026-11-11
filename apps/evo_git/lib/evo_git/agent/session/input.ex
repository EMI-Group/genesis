defmodule EvoGit.Agent.Session.Input do
  @moduledoc """
  The PURE input policy of `EvoGit.Agent.Session` — every decision an inbound user message
  demands, with no process state and no side effect, so it is unit-testable on its own.

  Two things live here:

    * `policy/1` maps the session's current phase to what `start_input/3` must do:
      `:resume` (an idle `:awaiting_input` session starts a NEW exchange on the SAME
      session/worktree/context), `:queue` (a `:running` exchange accepts the message through the
      existing pending-message transport) or the documented `{:error, reason}` refusal.
    * `resume_state/1` is the ONE resume transformation: it rebases the per-exchange turn budget
      on the turn the session has already reached, clears every per-exchange control/budget
      field and returns the session to `:running`.

  Resume is deliberately APPEND-ONLY: the caller appends the message through
  `EvoGit.AgentScheduler.Store.append_pending_user_message/2`, which the engine drains at the
  next turn boundary. Nothing here rebuilds the context tree and nothing here touches
  `prompt_cache_key`, so the provider prefix cache survives across exchanges of one session.
  """
  alias EvoGit.Agent.State

  @type policy :: :resume | :queue | {:error, :finished} | {:error, {:bad_state, atom()}}

  @doc """
  What `start_input/3` may do in `phase`.

  `:awaiting_input` resumes on this session; `:running` queues through the pending-message
  transport; `:cancelling`/`:finalizing`/`:done` are `{:error, :finished}` because the session
  is already on its way out; every other phase (`:starting`) is `{:error, {:bad_state, phase}}`.
  """
  @spec policy(atom()) :: policy()
  def policy(:awaiting_input), do: :resume
  def policy(:running), do: :queue
  def policy(phase) when phase in [:cancelling, :finalizing, :done], do: {:error, :finished}
  def policy(phase), do: {:error, {:bad_state, phase}}

  @doc """
  The resume transformation: the state a NEW exchange of the SAME session starts from.

  The conversation context, the worktree (`repo_path`) and the identity fields are kept
  verbatim; only the per-exchange budget is rebased (`exchange_turn_base` becomes the turn the
  session has already reached, so each exchange gets its own `max_exchange_turns` window) and
  the per-exchange control state is cleared (`cancel`, `in_grace_period`,
  `grace_turns_remaining`), because an idle session can never be mid-cancel or mid-grace.
  """
  @spec resume_state(State.t()) :: State.t()
  def resume_state(%State{} = state) do
    %{
      state
      | exchange_turn_base: state.turn,
        phase: :running,
        cancel: nil,
        in_grace_period: false,
        grace_turns_remaining: 0
    }
  end
end
