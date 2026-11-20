defmodule EvoGit.Agent.Exchange do
  @moduledoc """
  ONE exchange: N turns of an agent until a terminal outcome.

  `run/2` is a plain function over `%EvoGit.Agent.State{}`. It owns the loop
  control — context compression, the pending-input drain, the background-job
  notice, the cancel-grace check and turn-limit recovery — and delegates exactly
  ONE turn (the LLM call plus the tool batch) to `EvoGit.Agent.Turn.run/3`.

  ## Outcome vocabulary

  An exchange ends with exactly one of:

    * `{:yield, %State{}, String.t()}` — an `:interactive` agent replied with no
      tool calls: its pending work is committed, the reply text is the message
      the session hands back, and the SESSION decides what happens next (wait for
      input, or close). No `%EvoGit.Agent.Result{}` is built and no completion
      side effect is written;
    * `{:pause, %State{}}` — a TASK-LEVEL PAUSE was requested for this agent and
      has been honoured at a turn boundary. A pause is a NON-TERMINAL RESTING
      outcome, distinct from `{:ok, %Result{}}` and from `{:error, _}`: the
      state is checkpointed exactly once (so the durable conversation and the
      worktree are resumable), and NO completion side effect, NO report and NO
      `%Result{}` is produced — the session turns it into a paused delivery;
    * `{:finish, %State{}, %EvoGit.Agent.Result{}}` — the run is complete (every
      `:oneshot` agent); the completion side effects were written exactly once by
      `EvoGit.Agent.Completion.Builder.finalize/2`;
    * `{:error, reason}` — the run failed (for example `:recovery_failed` or a
      terminal `{:llm_request_rejected, message}`).

  ## Where a pause is honoured

  The pause flag is probed at exactly TWO turn boundaries and NEVER mid-batch:

    * the top of the loop, immediately AFTER the cancel check returns `:no_cancel`
      and before the turn-limit check / `Turn.run/3` — this is the boundary that
      catches a pause that arrived during an in-flight LLM call;
    * right after a tool batch completed (results appended, the in-flight marker
      cleared) and before the next loop step — see
      `EvoGit.Agent.ToolDispatch.continue_after_tools/7`. In-flight tool calls are
      never interrupted, which is what makes a pause clean.

  Cancel ALWAYS wins: the pause is only probed on the `:no_cancel` branch, so an
  agent that is both cancelling and pausing takes the cancel-grace path.

  The mode decides ONLY what a tool-free reply means; everything else in the
  loop is identical for both modes.

  ## Runnable in a bare process

  The engine's ONLY outside-world interactions are the four seams of
  `EvoGit.Agent.Exchange.Seams` (`:llm_call`, `:tool_batch`, `:scheduler`,
  `:checkpoint`). With all four supplied, an exchange runs in a bare process: no
  scheduler, no ETS table and no live agent process. An absent seam is the
  PRODUCTION path, byte-identical to the un-seamed loop.

  ## The checkpoint boundary (`checkpoint/2`)

  `:checkpoint` is observable-only: it receives the state EXACTLY ONCE PER TURN,
  after that turn's state update — the state handed to the recursive loop step
  for a continuing turn (`continuations/2`), and the final state once before the
  outcome is returned for a finishing turn (`run/2`). Its return value is
  discarded and it can never change the state or the outcome; an absent seam
  performs no extra state work at all.

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
  alias EvoGit.Agent.Stream.Sink
  alias EvoGit.Agent.ToolDispatch
  alias EvoGit.Agent.Turn

  @typedoc """
  The terminal outcome of one exchange: a yielded interactive turn, a paused
  (resting, resumable) run, a finished run (with its result), or an error that
  ends the run.
  """
  @type outcome ::
          {:yield, State.t(), String.t()}
          | {:pause, State.t()}
          | {:finish, State.t(), Result.t()}
          | {:error, term()}

  @doc """
  Runs ONE exchange over `state` until it yields a terminal outcome.

  `opts` is the seam keyword list (`:llm_call`, `:tool_batch`, `:scheduler`,
  `:checkpoint`; see `EvoGit.Agent.Exchange.Seams`). The SAME `opts` is threaded
  down to every turn, so an explicit seam is honoured consistently for the whole
  exchange.

  An OPTIONAL `:now` entry pins the clock for the whole exchange (see
  `EvoGit.Agent.Clock`): every per-message `metadata[:timestamp]` this exchange
  stamps then carries that value. It defaults to `nil` — the real clock — and is
  process-scoped, so it never affects a concurrent exchange.
  """
  @spec run(State.t(), keyword()) :: outcome()
  def run(%State{} = state, opts \\ []) do
    EvoGit.Agent.Clock.with_opts(opts, fn ->
      # Resolve the seam set ONCE per exchange. `Seams.from_opts/1` is pure and
      # cheap, so resolving the same `opts` again inside `Turn.run/3`, `Pending`
      # and `Grace` yields the identical seam set (the explicit-key-wins rule is
      # order-independent and the app-env default is read at call time).
      seams = Seams.from_opts(opts)

      # Crash-resume repair runs ONCE, here — before the loop, so the very first
      # LLM call of a resumed run already sees a provider-valid transcript and
      # the `[RESUME]` notice. It is a no-op for every run that is not a restored
      # run (`EvoGit.Agent.Resume.restored_run?/1` — a crash retry OR a task
      # pause resume), and it never touches the system message or the first user
      # message (prompt-cache prefix).
      state = EvoGit.Agent.Resume.apply(state)

      case loop(state, opts, seams) do
        # A TERMINAL turn never reaches the recursive loop, so its state is
        # checkpointed here — the single place the terminal state is observable.
        # Invariant: exactly ONE checkpoint per turn (a continuing turn fired
        # inside `continuations/2`), and the return value is discarded. A `:yield`
        # is terminal for THIS exchange and is checkpointed the same way, then
        # returned verbatim.
        {:finish, %State{} = final_state, _result} = outcome ->
          checkpoint(terminal_state(final_state), seams)
          emit_finished(:completed)
          outcome

        {:yield, %State{} = final_state, _text} = outcome ->
          checkpoint(terminal_state(final_state), seams)
          outcome

        # A PAUSE is a resting, non-terminal outcome: the state is checkpointed
        # here (exactly once, like `:finish`/`:yield`) so the durable row and the
        # session's last adopted state describe the same boundary, and the value
        # is returned verbatim. No `{:finished, _}` delta is emitted — a pause is
        # not one of the stream's terminal statuses; the session's own terminal
        # snapshot (from `finalize/1`) is the only end-of-run publication.
        {:pause, %State{} = final_state} = outcome ->
          checkpoint(terminal_state(final_state), seams)
          outcome

        {:error, _reason} = error ->
          emit_finished(:failed)
          error
      end
    end)
  end

  # Emits the ONE terminal `{:finished, status}` delta of an exchange, right
  # before the outcome is returned.
  #
  # WHY here and not in the turn: a terminal outcome is decided HERE, and the
  # sink is installed in the exchange WORKER process, so `Sink.emit/1` reaches
  # the session as a `{:delta, …}` message that arrives BEFORE the worker's
  # `{:exchange_finished, …}` (same sender, message order preserved). A `:yield`
  # is NOT terminal — it emits its own `{:yield, text}` and is parked by the
  # session — so it deliberately emits no `{:finished, _}`.
  #
  # `Sink.emit/1` is a no-op when nothing is installed, so an unwatched exchange
  # stays behaviourally identical.
  defp emit_finished(status), do: Sink.emit({:finished, status})

  # A TERMINAL state never carries the in-flight batch marker: a `:finish`/`:yield`
  # comes from a tool-free completion turn, so the marker is already nil, and this
  # normalisation makes that an invariant of the durable row instead of a
  # coincidence.
  defp terminal_state(%State{} = state), do: EvoGit.Agent.Resume.clear_marker(state)

  # The ONE `:checkpoint` call site shared by both turn paths: called once per
  # turn AFTER that turn's state update, with the seam's return value DISCARDED
  # (observable-only — it must never change the state or the outcome). An absent
  # seam (nil or `false`) is a no-op, so an un-seamed exchange performs no extra
  # state work and stays byte-identical.
  defp checkpoint(_state, %Seams{checkpoint: seam}) when seam in [nil, false], do: :ok

  defp checkpoint(%State{} = state, %Seams{checkpoint: seam}) when is_function(seam, 1),
    do: seam.(state)

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
  # Whether a TASK-LEVEL PAUSE is pending for this agent — the ONE pause probe of
  # the engine, routed through the `:scheduler` seam's `:pause_requested?` kind
  # (payload = the agent id; the production default reads
  # `EvoGit.AgentScheduler.ControlPlane.pause_requested?/1` at call time and is
  # total). Strictly `== true`, so an un-seamed/`nil`/`:ok` answer means "no
  # pause" and an absent seam is byte-identical to production.
  #
  # Never raises: the seam itself is the only outside-world interaction, and its
  # production default answers `false` on any failure.
  @spec pause_requested?(Seams.t(), State.t()) :: boolean()
  def pause_requested?(%Seams{} = seams, %State{agent_id: agent_id} = state) do
    scheduler(seams, :pause_requested?, agent_id, state) == true
  end

  @doc false
  # Transitions into a grace period and re-enters the loop. Kept with the
  # default-`opts` arity for the seam-free callers/tests that only need the
  # production path.
  def trigger_recovery(%State{} = state, reason), do: trigger_recovery(state, reason, [])

  # --- Loop control ---

  defp loop(%State{} = state, opts, seams) do
    case EvoGit.Agent.ContextCompression.compress_if_needed(state,
           agent_id: state.agent_id,
           llm_model: state.llm_model,
           llm_context_window: ToolDispatch.normalize_context_window(state.llm_context_window),
           llm_generation_params: state.llm_generation_params
         ) do
      %State{} = state ->
        continue_loop(state, opts, seams)

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
  defp continue_loop(%State{} = state, opts, seams) do
    # "Preparing the next turn": published FIRST, before the turn warnings, the
    # pending-input drain, the background-job notices, the cancel-grace check,
    # the pause probe, the turn-limit check and prompt assembly, so a busy
    # worker never renders as idle during that window — and so any
    # `:compressing` phase from the step above is re-labelled. Inert without an
    # installed sink, so an unwatched exchange stays byte-identical.
    Sink.phase(:preparing)

    state = Warnings.check_limit_warnings(state)

    # No ETS write-through here anymore: the state this turn produces is the
    # authority and is published by the ONE `:checkpoint` seam at the turn
    # boundary (`continuations/2` / `run/2`).

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
        # A TASK-LEVEL PAUSE is honoured HERE, and only on the `:no_cancel`
        # branch: cancel always wins (an agent that is both cancelling and
        # pausing takes the cancel-grace path above). The probe sits BEFORE the
        # turn-limit check and the turn itself, so a pause that arrived during an
        # in-flight LLM call is caught at the very next boundary and no further
        # LLM call is made.
        if pause_requested?(seams, state) do
          {:pause, state}
        else
          cond do
            EvoGit.Agent.trigger_turn_limit_recovery?(state) ->
              trigger_recovery(state, turn_limit_reason(state), opts, seams)

            true ->
              Turn.run(state, continuations(opts, seams), opts)
          end
        end
    end
  end

  # The recovery message names the budget that was actually exhausted:
  # `max_turns` for a one-shot agent (BYTE-IDENTICAL to the historical text) and
  # the effective per-exchange burst budget for an interactive one.
  defp turn_limit_reason(%State{mode: :interactive} = state) do
    "max turns (#{EvoGit.Agent.exchange_turn_budget(state)}) exceeded"
  end

  defp turn_limit_reason(%State{max_turns: max}), do: "max turns (#{max}) exceeded"

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
      loop: fn st ->
        # A CONTINUING turn's state is checkpointed here — exactly once, at the
        # boundary where that state becomes the input of the next turn. The
        # initial (turn-0) state never passes through this closure, so it is not
        # counted as a turn.
        checkpoint(st, seams)
        loop(st, opts, seams)
      end,
      trigger_recovery: fn st, reason -> trigger_recovery(st, reason, opts) end
    }
  end
end
