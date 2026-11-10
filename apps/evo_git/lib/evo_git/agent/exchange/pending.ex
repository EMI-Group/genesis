defmodule EvoGit.Agent.Exchange.Pending do
  @moduledoc """
  The turn-top input surface: pending user messages and background-job notices.

  Both append user-role messages to the conversation and sync the new context
  through the `:context` seam (`EvoGit.Agent.Exchange.Seams`), so an exchange in
  a bare process produces exactly the same context updates as a live agent.

  Neither helper owns the tool plane: `EvoGit.BackgroundJobs` claims finished
  notices itself (a tool-plane call, not a scheduler effect), so that call stays
  direct even when a scheduler seam is supplied.
  """

  alias EvoGit.Agent.Exchange
  alias EvoGit.Agent.Exchange.Seams
  alias EvoGit.Agent.State

  @doc """
  Drains the agent's pending user-message queue and appends each message to the
  context as a turn-tagged user-role message.

  Each drained message may be a legacy plain `String.t()` or a
  `%{text:, attachments:}` map (the `:drain_inputs` seam yields whatever was
  queued) — materialization is delegated to the pure
  `EvoGit.Agent.ContextBuilder.build_injected_message/2`, which yields a plain
  `user(text)` for a legacy binary / no media and a
  `user([ContentPart.text(text) | media…])` content-part message when the
  message carries attachments. There is NO root gate on injected messages:
  any agent at any depth may receive media here (the root-only gate covers the
  `:attachments` TASK OPT only — the first user message).
  """
  @spec drain_and_inject_user_messages(State.t(), keyword()) :: State.t()
  def drain_and_inject_user_messages(%State{} = state, opts \\ []) do
    seams = Seams.from_opts(opts)
    messages = Exchange.scheduler(seams, :drain_inputs, nil, state)

    case messages do
      [] ->
        state

      _ ->
        new_context =
          Enum.reduce(messages, state.context, fn msg, ctx ->
            tagged = EvoGit.Agent.ContextBuilder.build_injected_message(msg, state.turn)
            ReqLLM.Context.append(ctx, tagged)
          end)

        # Sync updated context for dashboard visibility (returns :ok). The
        # in-memory new_context is already stamped at creation
        # (build_injected_message above) — no rebind needed.
        Exchange.scheduler(seams, :context, new_context, state)

        %{state | context: new_context}
    end
  end

  @doc """
  Claims this agent's finished-but-unannounced background shell jobs and, when
  there are any, appends ONE combined `[NOTICE]` user message so the LLM learns
  a detached command finished. The claim is exactly-once (the registry marks the
  jobs `announced`), so a poll via `job_output`/`job_list` can never produce a
  duplicate notice. Skipped entirely during a grace period: the grace budget is
  for wrapping up, and claiming there would consume the notice without the
  agent ever acting on it. A missing registry already yields `{:ok, []}`.
  """
  @spec inject_background_job_notices(State.t(), keyword()) :: State.t()
  def inject_background_job_notices(state, opts \\ [])

  def inject_background_job_notices(%State{in_grace_period: true} = state, _opts), do: state

  def inject_background_job_notices(%State{} = state, opts) do
    seams = Seams.from_opts(opts)

    # `notice/1` answers `nil` for an empty list; the guard already excludes it,
    # but the explicit `is_binary` match keeps the append total.
    # The owner is the AGENT/session pid, NOT this exchange worker's `self()`:
    # the worker is short-lived and owns nothing durable (D7), while the jobs
    # were started under the session pid installed as `:evogit_agent_pid`.
    # `current_owner_pid/0` is the ONE resolution site and falls back to
    # `self()` for a driver that installs no owner (where it IS the agent pid).
    with {:ok, jobs} when is_list(jobs) and jobs != [] <-
           EvoGit.BackgroundJobs.claim_finished_notices(
             owner_pid: EvoGit.BackgroundJobs.current_owner_pid() || self()
           ),
         text when is_binary(text) <- EvoGit.Agent.BackgroundJobNotice.notice(jobs) do
      message = EvoGit.Agent.ContextBuilder.build_injected_message(text, state.turn)
      new_context = ReqLLM.Context.append(state.context, message)

      # Sync for dashboard/history visibility (same side effect as the
      # pending-message drain).
      Exchange.scheduler(seams, :context, new_context, state)

      %{state | context: new_context}
    else
      _ -> state
    end
  end
end
