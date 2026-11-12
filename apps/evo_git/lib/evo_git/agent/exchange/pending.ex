defmodule EvoGit.Agent.Exchange.Pending do
  @moduledoc """
  The turn-top input surface: pending user messages and background-job notices.

  Both append user-role messages to the conversation and return a state carrying
  the new context; that state IS the authority (the session process owns it and
  publishes it at the turn boundary through the `:checkpoint` seam), so nothing
  here writes ETS.

  Only the pending-message drain touches the scheduler control plane, through
  the `:drain_inputs` seam (`EvoGit.Agent.Exchange.Seams`), so an exchange in a
  bare process drains exactly like a live agent.

  Neither helper owns the tool plane: `EvoGit.BackgroundJobs` claims finished
  notices itself (a tool-plane call, not a scheduler effect), so that call stays
  direct.
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

  This transport is the ONLY mid-run channel a HUMAN writes to, so each
  delivered message is stamped `:user_authored => true`
  (`EvoGit.Agent.MessageMarker`) — a display layer can then tell a real user
  turn from the harness text that shares the same `:user` role. The one
  exception is the graceful-cancel save-work notice, which the SCHEDULER
  appends to this same queue (`EvoGit.AgentScheduler.cancel_message/0`): it is
  harness-generated, so it is built by the neutral
  `build_injected_message/2` and carries no marker.
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
            tagged =
              if harness_injected?(msg) do
                EvoGit.Agent.ContextBuilder.build_injected_message(msg, state.turn)
              else
                EvoGit.Agent.ContextBuilder.build_user_authored_message(msg, state.turn)
              end

            ReqLLM.Context.append(ctx, tagged)
          end)

        # The new context rides the returned state (no ETS sync): the in-memory
        # context is already stamped at creation (build_injected_message above).
        %{state | context: new_context}
    end
  end

  # True for the ONE harness message that rides the user-send transport: the
  # graceful-cancel save-work notice, appended by the SCHEDULER
  # (`begin_graceful_cancel/1`) rather than by a human. ONE exact-text compare
  # against the single pinned notice is the whole rule; every other message —
  # legacy binary or `%{text:, attachments:}` map — is a genuine user send.
  # TOTAL: a malformed/unknown shape yields no text and is therefore a user send
  # (materialization raises the descriptive error later, as before).
  defp harness_injected?(message) do
    pending_text(message) == EvoGit.AgentScheduler.cancel_message()
  end

  defp pending_text(text) when is_binary(text), do: text
  defp pending_text(%{text: text}) when is_binary(text), do: text
  defp pending_text(_message), do: nil

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

  def inject_background_job_notices(%State{} = state, _opts) do
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
      # Neutral builder: a job notice is harness text, so it carries NO
      # `:user_authored` marker (`EvoGit.Agent.MessageMarker`).
      message = EvoGit.Agent.ContextBuilder.build_injected_message(text, state.turn)
      new_context = ReqLLM.Context.append(state.context, message)

      # The new context rides the returned state (no ETS sync).
      %{state | context: new_context}
    else
      _ -> state
    end
  end
end
