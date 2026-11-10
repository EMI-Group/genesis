defmodule EvoGit.Agent.Exchange.Grace do
  @moduledoc """
  Grace periods — the bounded wrap-up window shared by both recovery kinds.

  Entering a grace period runs the best-effort recovery auto-commit FIRST (a
  safety net so uncommitted work is preserved), then optionally appends a
  recovery message, then sets `in_grace_period: true` with a grace-turn budget.
  The budget is hard: every turn that ends without completing consumes one
  grace turn, and at `grace_turns_remaining <= 1` the next continue hard-stops
  with `{:error, :recovery_failed}` (`EvoGit.Agent.grace_period_continue_failed?/1`).

  Two triggers exist, both entering here:

    * turn-limit recovery — the turn budget is exhausted
      (`EvoGit.Agent.trigger_turn_limit_recovery?/1`), which appends the
      standard recovery message (`recovery_warning_message/2`);
    * cancel-grace — a user-requested graceful cancellation
      (`maybe_enter_cancel_grace/2`), which appends NO recovery message: the
      cancel message was already injected by the pending-input drain at the top
      of the exchange loop.

  `maybe_enter_cancel_grace/2` reads/clears the scheduler's per-agent
  `cancel_requested` flag through the `:scheduler` seam
  (`EvoGit.Agent.Exchange.Seams`), so a bare process can run it with a stub.
  """

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Exchange
  alias EvoGit.Agent.Exchange.Seams
  alias EvoGit.Agent.State

  import ReqLLM.Context, only: [user: 1]

  # Grace-turn budget for a user-requested graceful cancellation (cancel-grace).
  # The agent may wrap up and finish (a plain-text reply with no tool calls ends
  # the run and its text is the report) for up to this many turns before the run
  # hard-stops with `{:error, :recovery_failed}`.
  @cancel_grace_turns 3

  # Grace-turn budget for turn-limit recovery. A commit is a tool call and
  # therefore does not finish the run, so the agent needs one turn for a bounded
  # final commit PLUS at least one more to deliver its plain-text report; the
  # budget must never be 1, which makes "commit and report" impossible.
  # The bound stays hard: every turn that ends without completing consumes a
  # grace turn, and at `grace_turns_remaining <= 1` the next continue hard-stops
  # with `{:error, :recovery_failed}` (`Agent.grace_period_continue_failed?/1`).
  @turn_limit_grace_turns 3

  @doc false
  # Transitions an agent into a grace period WITHOUT re-entering the loop.
  #
  # Runs the best-effort recovery auto-commit FIRST (safety net so uncommitted
  # work is preserved — fires for BOTH grace kinds; for cancel-grace this is
  # exactly "save the changes"), then optionally appends a recovery message to
  # the context, then sets `in_grace_period: true` with the given grace-turn
  # budget. Returns the updated `%State{}`.
  #
  # `opts`:
  #   - `:message` — `:default` (or omitted) appends the standard hardcoded
  #     recovery message built from `reason`, the agent's objective and the
  #     current turn-limit budget (`recovery_warning_message/2`); `nil` skips
  #     the append (cancel-grace — the cancel message was already injected via
  #     the `pending_user_messages` drain in the exchange loop, so a second
  #     message would be redundant); a binary appends that custom message
  #     instead.
  #   - `:grace_turns` — the grace-turn budget (default `@turn_limit_grace_turns`).
  #
  # Any remaining keys are the seam keys of `EvoGit.Agent.Exchange.Seams`.
  def enter_grace(%State{} = state, reason, opts \\ []) do
    message = Keyword.get(opts, :message, :default)
    grace_turns = Keyword.get(opts, :grace_turns, @turn_limit_grace_turns)

    # Safety net: auto-commit any uncommitted work before entering the grace
    # period, so it is preserved even if the agent fails to commit during its
    # recovery turns. We only commit when there are actually changes
    # (non-empty porcelain status); a clean workspace is a no-op. Git errors
    # are allowed to propagate (crash) — this is best-effort salvage, not
    # error-masking.
    maybe_recovery_auto_commit(state)

    new_context =
      case message do
        :default ->
          objective =
            if is_binary(state.objective) and state.objective != "", do: state.objective

          warning_msg = recovery_warning_message(reason, objective)

          recovery_msg =
            EvoGit.Agent.ContextBuilder.tag_message_turn(user(warning_msg), state.turn)

          ReqLLM.Context.append(state.context, recovery_msg)

        nil ->
          # Cancel-grace: the cancel message was already injected via the
          # pending_user_messages drain in the exchange loop — do not append a
          # second recovery message.
          state.context

        custom when is_binary(custom) ->
          recovery_msg = EvoGit.Agent.ContextBuilder.tag_message_turn(user(custom), state.turn)
          ReqLLM.Context.append(state.context, recovery_msg)
      end

    %{
      state
      | context: new_context,
        in_grace_period: true,
        grace_turns_remaining: grace_turns
    }
  end

  @doc false
  # Checks whether a graceful cancellation was requested for this agent via the
  # scheduler's `cancel_requested` flag (set when the task is cancelled).
  #
  # If set: clears the flag and returns `{:cancel_grace, grace_state}` where
  # `grace_state` has `in_grace_period: true` and
  # `grace_turns_remaining: @cancel_grace_turns`. No recovery message is
  # appended — the cancel message was already injected into the context by the
  # `pending_user_messages` drain at the top of the exchange loop.
  #
  # If not set: returns `:no_cancel`.
  def maybe_enter_cancel_grace(%State{} = state, opts \\ []) do
    seams = Seams.from_opts(opts)

    if Exchange.scheduler(seams, :cancel_requested?, nil, state) do
      Exchange.scheduler(seams, :clear_cancel, nil, state)

      {:cancel_grace,
       enter_grace(state, "task cancelled", message: nil, grace_turns: @cancel_grace_turns)}
    else
      :no_cancel
    end
  end

  @doc false
  # The hardcoded turn-budget recovery message appended when entering a grace
  # period with `message: :default` (turn-limit recovery).
  #
  # Every claim here must hold for the CURRENT budget, so the number of final
  # turns is interpolated from `@turn_limit_grace_turns` instead of being
  # hardcoded, and the text spells out the three things an agent gets wrong:
  #   * the ONE completion rule — a reply with NO tool calls ends the run and its
  #     text IS the report, while a turn ending in a tool call merely continues;
  #   * the terminal consequence — using the window up without such a reply stops
  #     the run immediately with NO report at all;
  #   * the acceptable outcome — an honest partial report beats "just one more fix".
  def recovery_warning_message(reason, objective) do
    budget = @turn_limit_grace_turns

    if objective do
      """
      You have exceeded your turn budget (#{reason}). You have #{budget} final #{turn_word(budget)} left before this run stops immediately.

      How this run ends — the ONE completion rule: a reply with NO tool calls ends the run, and its text IS the report. A turn that ends with a tool call does NOT finish the run — it only uses up one of your final turns.

      If you use up all #{budget} final #{turn_word(budget)} without such a reply, this run stops immediately and there will be NO report at all.

      What to do now:
      1. First turn: make at most ONE final commit, and only if you have genuinely uncommitted work. Your already-committed work is safe, and no commit is needed when the workspace is clean.
      2. Then STOP working and reply with your final report as plain text. Do not start another change, and do not delegate.

      If you cannot complete the entire objective, that is acceptable: stop and report what you did (with the commit), what remains, and what a follow-up must pick up. Never keep working toward "just one more fix".

      Your original objective was:
      #{objective}

      Your report MUST summarize the status of this ENTIRE objective, not just your most recent sub-task.
      """
    else
      """
      You have exceeded your turn budget (#{reason}). You have #{budget} final #{turn_word(budget)} left before this run stops immediately.

      How this run ends — the ONE completion rule: a reply with NO tool calls ends the run, and its text IS the report. A turn that ends with a tool call does NOT finish the run — it only uses up one of your final turns.

      If you use up all #{budget} final #{turn_word(budget)} without such a reply, this run stops immediately and there will be NO report at all.

      What to do now:
      1. First turn: make at most ONE final commit, and only if you have genuinely uncommitted work. Your already-committed work is safe, and no commit is needed when the workspace is clean.
      2. Then STOP working and reply with your final report as plain text explaining the situation — what was done (with the commit), what remains, and what a follow-up must pick up.

      If you cannot complete the entire objective, that is acceptable: an honest partial report is exactly what is needed here. Never keep working toward "just one more fix".
      """
    end
  end

  @doc false
  def turn_word(1), do: "turn"
  def turn_word(_), do: "turns"

  @doc false
  # Best-effort auto-commit of any uncommitted work just before the grace
  # period, as a safety net so work is not lost if the agent fails to commit
  # during its grace turns. Only commits when the workspace is dirty
  # (non-empty porcelain status); a clean workspace is a silent no-op. Git
  # errors propagate (crash) rather than being swallowed — this is salvage,
  # not error-masking. No try/rescue per repo conventions.
  def maybe_recovery_auto_commit(%State{} = state) do
    # Repo-less agents never touch git (cardinal rule) — their repo_path is a
    # placeholder or the real source root, neither of which should be
    # status'd/committed. Both `repo_less` and `repo_path` are read from the
    # STRUCT: the runner installs the identical values into the process
    # dictionary (`:repo_less` / `:repo_path`) from these same fields.
    if state.repo_less do
      :ok
    else
      repo_path = state.repo_path

      if repo_path do
        case Git.status(repo_path) do
          {:ok, ""} ->
            :ok

          {:ok, _status_output} ->
            {:ok, _} = Git.add(repo_path, ".")
            {:ok, _} = Git.commit(repo_path, "auto-commit: turn-limit recovery")
            :ok
        end
      else
        :ok
      end
    end
  end
end
