defmodule EvoGit.Agent.Session.Worker do
  @moduledoc """
  The exchange worker: ONE `EvoGit.Agent.Exchange` run, executed OFF the session
  process.

  `EvoGit.Agent.Session` starts this function with
  `Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, …)` so the session keeps
  answering inspection, input and cancel commands while the exchange runs. The
  worker owns nothing durable: it installs the process context with the SESSION
  pid as `:evogit_agent_pid` (D7), runs the exchange, and reports back with
  exactly two messages:

    * `{:checkpoint, %EvoGit.Agent.State{}}` — one per turn, so the session can
      publish a coalesced summary;
    * `{:exchange_finished, self(), outcome}` — the terminal
      `{:finish, %State{}, %Result{}} | {:error, reason}` value, verbatim.

  An EXCEPTION is deliberately NOT caught here: it propagates out of the task,
  becomes an abnormal `:DOWN` at the session, and the session maps it to its
  crash path — the same shape the scheduler's crash/retry handling expects.

  The completion side effects (git note, archive refs, `%Result{}`) are written
  INSIDE the exchange by `EvoGit.Agent.ToolDispatch.build_completion/2,3`, so
  this module only adds the post-run worktree bookkeeping that
  `EvoGit.Agent.Runner.run/3` does for the one-shot driver.
  """

  alias EvoGit.Agent.Exchange
  alias EvoGit.Agent.Runner
  alias EvoGit.Agent.Session.Setup
  alias EvoGit.Agent.State

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

    checkpoint = fn %State{} = checkpointed -> send(session_pid, {:checkpoint, checkpointed}) end
    exchange_opts = [checkpoint: checkpoint] ++ Keyword.delete(opts, :tmpdir)

    outcome =
      try do
        Exchange.run(state, exchange_opts)
      after
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
    {:finish, state, result |> Runner.refresh_commit_sha() |> elem(1)}
  end

  # A failed exchange is delivered verbatim — never converted into a raise or a
  # success.
  defp refresh({:error, reason}), do: {:error, reason}
end
