defmodule EvoGit.Agent.Exchange do
  @moduledoc """
  ONE exchange: N turns of an agent until a terminal outcome.

  `run/2` is a plain function over `%EvoGit.Agent.State{}`. It owns the loop
  control — context compression, the pending-input drain, the background-job
  notice, the cancel-grace check and turn-limit recovery — and delegates exactly
  ONE turn (the LLM call plus the tool batch) to `EvoGit.Agent.Turn.run/3`.

  ## Outcome vocabulary

  An exchange ends with exactly one of:

    * `{:finish, %State{}, %EvoGit.Agent.Result{}}` — the run is complete; the
      caller performs the completion side effects (`EvoGit.Agent.Completion`)
      exactly once;
    * `{:error, reason}` — the run failed (for example `:recovery_failed` or a
      terminal `{:llm_request_rejected, message}`).

  There is deliberately NO `:yield` outcome and no interactive mode in P1: the
  yield/finish split and the `:awaiting_input` task status land with the
  per-agent session process.

  ## Runnable in a bare process

  The engine's ONLY outside-world interactions are the three seams of
  `EvoGit.Agent.Exchange.Seams` (`:llm_call`, `:tool_batch`, `:scheduler`).
  With all three supplied, an exchange runs in a bare process: no scheduler, no
  ETS table and no live agent process. An absent seam is the PRODUCTION path,
  byte-identical to the un-seamed loop.

  ## Role-agnostic

  Nothing here knows which kind of agent it is running: behaviour comes from
  `state.agent_module`'s callbacks and every other value comes from `%State{}`.
  No role name appears in this module.
  """

  alias EvoGit.Agent.Exchange.Grace
  alias EvoGit.Agent.Exchange.Pending
  alias EvoGit.Agent.Exchange.Seams
  alias EvoGit.Agent.Exchange.Warnings
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolDispatch
  alias EvoGit.Agent.Turn

  @typedoc """
  The terminal outcome of one exchange: a finished run (with its result) or an
  error that ends the run.
  """
  @type outcome :: {:finish, State.t(), Result.t()} | {:error, term()}

  @doc """
  Runs ONE exchange over `state` until it yields a terminal outcome.

  `opts` is the seam keyword list (`:llm_call`, `:tool_batch`, `:scheduler`; see
  `EvoGit.Agent.Exchange.Seams`). The SAME `opts` is threaded down to every
  turn, so an explicit seam is honoured consistently for the whole exchange.
  """
  @spec run(State.t(), keyword()) :: outcome()
  def run(%State{} = state, opts \\ []) do
    # Resolve the seam set ONCE per exchange. `Seams.from_opts/1` is pure and
    # cheap, so resolving the same `opts` again inside `Turn.run/3`, `Pending`
    # and `Grace` yields the identical seam set (the explicit-key-wins rule is
    # order-independent and the app-env default is read at call time).
    seams = Seams.from_opts(opts)
    loop(state, opts, seams)
  end

  @doc false
  # The ONE scheduler-seam adapter shared by the engine and its helpers: the
  # `:scheduler` seam when one is set, else `Seams.default_scheduler/3` (the
  # exact production calls, so an absent seam is byte-identical to before). See
  # `EvoGit.Agent.Exchange.Seams` for the kind/payload contract.
  def scheduler(%Seams{scheduler: nil}, kind, payload, %State{} = state) do
    Seams.default_scheduler(kind, payload, state)
  end

  def scheduler(%Seams{scheduler: seam}, kind, payload, %State{} = state) do
    seam.(kind, payload, state)
  end

  @doc false
  # Transitions into a grace period and re-enters the loop. Kept with the
  # default-`opts` arity for the seam-free callers/tests that only need the
  # production path.
  def trigger_recovery(%State{} = state, reason), do: trigger_recovery(state, reason, [])

  # --- Loop control ---

  defp loop(%State{} = state, opts, seams) do
    context_before = state.context

    case EvoGit.Agent.ContextCompression.compress_if_needed(state,
           agent_id: state.agent_id,
           llm_model: state.llm_model,
           llm_context_window: ToolDispatch.normalize_context_window(state.llm_context_window),
           llm_generation_params: state.llm_generation_params
         ) do
      %State{} = state ->
        continue_loop(state, context_before, opts, seams)

      {:error, {:llm_request_rejected, _message} = terminal} ->
        # The compression call hit a NON-RETRYABLE provider rejection (the
        # fail-fast exception in `ContextCompression.compress_if_needed/2`).
        # Propagate the terminal error out of the exchange UNCHANGED so it
        # reaches the caller's return value — the Runner's `refresh_commit_sha/1`
        # passes `{:error, _}` through untouched — and the task is persisted
        # `:failed` with the actionable message instead of being crash-retried
        # through the same doomed request.
        {:error, terminal}
    end
  end

  # The remainder of the turn, after compression returned a `%State{}`
  # (compressed or unchanged — byte-identical to the pre-existing flow).
  defp continue_loop(%State{} = state, context_before, opts, seams) do
    state = Warnings.check_limit_warnings(state)

    # Sync context after any updates (compression, warnings). The in-memory
    # context is already stamped at creation; the `:context`/`:total_tokens`
    # seams return `:ok`, so they are called for the side effect only.
    if context_before != state.context do
      scheduler(seams, :context, state.context, state)
      scheduler(seams, :total_tokens, state.total_tokens, state)
    end

    # Drain any pending user messages (injected externally via dashboard/RPC)
    # and append them to the context as user-role messages before the next LLM call.
    state = Pending.drain_and_inject_user_messages(state, opts)

    # Turn top, right after the drain: a background shell job that finished
    # since the previous turn is announced with ONE `[NOTICE]` user message.
    # Placed HERE (not earlier) because compression has already run for this
    # turn, so a fresh notice can never be compressed away immediately; and not
    # later because it must precede the LLM call and never interrupt an
    # in-flight tool batch.
    state = Pending.inject_background_job_notices(state, opts)

    # Immediately after the drain: check whether a graceful cancellation was
    # requested for this agent (the scheduler's `cancel_requested` flag, set
    # when the task is cancelled). If set, the flag is cleared and the agent
    # enters cancel-grace (budget `Grace.cancel_grace_turns/0`, NO extra
    # recovery message — the cancel message was already injected via the
    # pending_user_messages drain above).
    case Grace.maybe_enter_cancel_grace(state, opts) do
      {:cancel_grace, grace_state} ->
        loop(grace_state, opts, seams)

      :no_cancel ->
        cond do
          EvoGit.Agent.trigger_turn_limit_recovery?(state) ->
            trigger_recovery(state, "max turns (#{state.max_turns}) exceeded", opts, seams)

          true ->
            Turn.run(state, continuations(opts, seams), opts)
        end
    end
  end

  defp trigger_recovery(%State{} = state, reason, opts) do
    trigger_recovery(state, reason, opts, Seams.from_opts(opts))
  end

  defp trigger_recovery(%State{} = state, reason, opts, seams) do
    loop(Grace.enter_grace(state, reason, opts), opts, seams)
  end

  # The continuations handed to ONE turn. Plain closures — nothing fun-bearing
  # ever enters `%State{}`.
  defp continuations(opts, seams) do
    %{
      loop: fn st -> loop(st, opts, seams) end,
      trigger_recovery: fn st, reason -> trigger_recovery(st, reason, opts) end
    }
  end
end
