defmodule EvoGit.Agent.Session.Worker do
  @moduledoc """
  The exchange worker: ONE `EvoGit.Agent.Exchange` run, executed OFF the session
  process.

  `EvoGit.Agent.Session` starts this function with
  `Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, …)` so the session keeps
  answering inspection, input and cancel commands while the exchange runs. The
  worker owns nothing durable: it installs the process context with the SESSION
  pid as `:evogit_agent_pid` (D7), runs the exchange, and reports the exchange
  back with exactly two messages:

    * `{:checkpoint, self(), %EvoGit.Agent.State{}}` — one per turn, so the
      session can reject stale workers before adopting state or publishing a
      coalesced summary;
    * `{:exchange_finished, self(), outcome}` — the terminal outcome value,
      verbatim: `{:yield, %State{}, text}` (an interactive agent's tool-free
      reply, already refreshed against the post-fallback worktree HEAD),
      `{:finish, %State{}, %Result{}}` or `{:error, reason}`.

  ## Live streaming

  The worker also INSTALLS the delta sink (`EvoGit.Agent.Stream.Sink`) for the
  duration of the run, and uninstalls it before returning.
  The sink is PROCESS-LOCAL: it is two `Process.put/2` entries in THIS process,
  and the exchange engine (`EvoGit.Agent.LLMPrompting`/`ToolDispatch`) runs here
  too, so no public arity has to change to reach every emitter.
  It is DEFAULT-INERT: it emits nothing and installs no stream callbacks at all
  unless the session reports a registered watcher (`EvoGit.Agent.Session.watching?/2`),
  so an unwatched run stays byte-identical to the pre-streaming runtime —
  installing it costs two `Process.put/2` calls and nothing else.
  `{:evogit_interrupt, ref}` messages that arrive in THIS process are consumed by
  the sink's per-chunk check, which raises `EvoGit.Agent.Stream.Interrupted` to
  pre-empt the stream in flight.
  `{:delta, events}` messages flow from the worker to the session, which batches
  them and broadcasts them on the agent's topic; they are NOT part of the
  exchange contract above and do not arrive while nothing watches.

  An EXCEPTION is deliberately NOT caught here: it propagates out of the task,
  becomes an abnormal `:DOWN` at the session, and the session maps it to its
  crash path — the same shape the scheduler's crash/retry handling expects.

  The completion side effects (git note, archive refs, `%Result{}`) are written
  INSIDE the exchange by `EvoGit.Agent.Completion.Builder.finalize/2` for a
  `:oneshot` agent, so this module only adds the post-run worktree bookkeeping
  (the same `refresh_commit_sha/1` refresh the retired one-shot driver
  performed). A `:yield` is NOT a completion: the session owns it and reaches
  the same builder once, when the session terminates.
  """

  alias EvoGit.Agent.Exchange
  alias EvoGit.Agent.Runner
  alias EvoGit.Agent.Session.Setup
  alias EvoGit.Agent.State
  alias EvoGit.Agent.Stream.Sink

  @doc """
  Runs one exchange for `state` and reports to `session_pid`.

  `opts` carries `:tmpdir` (the task scratch directory resolved by the session)
  plus any engine-seam options the session forwards (the `:exchange_opts`
  dispatch-ctx seam — DEFAULT INERT, production passes none).
  """
  @spec run(State.t(), pid(), keyword()) :: :ok
  def run(%State{} = state, session_pid, opts \\ []) when is_pid(session_pid) do
    tmpdir = Keyword.get(opts, :tmpdir)

    # The SESSION is the owner: the worker is short-lived and owns nothing
    # durable, so anything bound to the owner pid must outlive this task (D7).
    Setup.install_process_context(state, tmpdir, session_pid)

    # Installed AFTER the process context and BEFORE the exchange, so the very first
    # LLM attempt already sees the sink. It is process-local on purpose: this process
    # runs the exchange and therefore the LLM/tool path, so two `Process.put/2` writes
    # reach every emitter without changing a single public arity.
    Sink.install(session_pid, state.agent_id)

    # Checkpoints and terminal outcomes share the same worker identity: a late
    # checkpoint must never overwrite the state of a resumed exchange.
    checkpoint = fn %State{} = checkpointed ->
      send(session_pid, {:checkpoint, self(), checkpointed})
    end

    exchange_opts = [checkpoint: checkpoint] ++ Keyword.delete(opts, :tmpdir)

    outcome =
      try do
        Exchange.run(state, exchange_opts)
      after
        # Uninstall FIRST: the terminal `{:exchange_finished, …}` is sent right after
        # this block, and uninstalling here is what guarantees no delta can TRAIL it
        # (the session must never be told the exchange is over and then see more of
        # its output). Being first also means anything the fallback below triggers
        # hits an INERT sink — `emit/1` is a no-op once uninstalled.
        Sink.uninstall()

        # The agent process owns git operations. After the agent finishes
        # (any exit path), commit any pending changes as a best-effort
        # fallback so the worktree is clean before the scheduler processes
        # the result. The scheduler never touches git directly.
        EvoGit.AgentScheduler.Dispatch.commit_pending_in_worktree()

        # After the fallback committed, advance the agent's foreign repo's
        # PERSISTENT worktree to the agent's final HEAD — so the worktree other
        # agents read reflects the newest committed state (last-writer-wins).
        # Best-effort and a no-op for primary-repo / repo-less agents.
        EvoGit.AgentScheduler.ForeignWorktree.sync_from_agent()
      end

    send(session_pid, {:exchange_finished, self(), refresh(outcome)})
    :ok
  end

  # The `after` fallback above may have created the ONLY commit of this run,
  # while `Result.commit_sha` was captured earlier (on the completion path,
  # before the fallback committed) — i.e. it may still point at the
  # pre-fallback worktree HEAD. `Runtime.Helpers.merge_and_report/3,4`
  # compares that sha against the live HEAD of the repo root and treats a
  # match (or nil) as "no changes", so a stale pre-fallback sha would leave
  # the fallback-only commit unreviewable (no `genesis/agent_*` branch, and
  # the commit dies with the worktree on reclaim). Re-read the worktree HEAD
  # AFTER the fallback ran and refresh the returned result.
  #
  # `Runner.refresh_commit_sha/1` reads the process dictionary (`:repo_path`,
  # `:repo_less`), so it MUST run here in the worker — never in the session.
  # It refreshes success shapes only and returns everything else untouched.
  defp refresh({:finish, %State{} = state, result}) do
    {:finish, state, Runner.refresh_commit_sha(result)}
  end

  # A YIELD is not a completion: the exchange committed the pending work, and the
  # session decides what happens next. The `after` fallback above may still have
  # created the only commit of this exchange, so the state's recorded
  # `current_commit` is re-read here — AFTER that fallback, in this process (the
  # one that owns `:repo_path`/`:repo_less`). A repo-less agent, a blank
  # `:repo_path`, a non-git directory or a git error leaves the state unchanged;
  # a yield is never turned into a failure.
  defp refresh({:yield, %State{} = state, text}) do
    {:yield, refresh_current_commit(state), text}
  end

  # A failed exchange is delivered verbatim — never converted into a raise or a
  # success.
  defp refresh({:error, reason}), do: {:error, reason}

  defp refresh_current_commit(%State{} = state) do
    case Runner.current_commit_sha() do
      {:ok, sha} -> %{state | current_commit: sha}
      :error -> state
    end
  end
end
