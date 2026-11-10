defmodule EvoGit.Agent.Runner do
  @moduledoc """
  The entry point an agent module's `run/2` delegates to.

  `run/3` installs the dispatch context (`Runner.Setup`), builds the initial
  `%EvoGit.Agent.State{}` (`Runner.InitialState`), runs ONE `EvoGit.Agent.Exchange`
  and maps its outcome to the public `{:ok, %EvoGit.Agent.Result{}} | {:error, reason}`
  contract, then re-reads the worktree HEAD. The loop, the turn and the completion
  route live in `EvoGit.Agent.Exchange` / `EvoGit.Agent.Turn` /
  `EvoGit.AgentScheduler.Dispatch`.
  """

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Exchange

  @doc """
  Runs the agent synchronously, blocking until it completes.

  `dispatch_ctx` is the scheduler's keyword list: worktree setup, retry handling
  and process-dict initialization before the exchange starts.
  """
  def run(agent_module, objective, dispatch_ctx) do
    setup_dispatch_context(dispatch_ctx)

    # The agent process owns git operations. After the agent finishes
    # (any exit path), commit any pending changes as a best-effort
    # fallback so the worktree is clean before the scheduler processes
    # the result. The scheduler never touches git directly.
    result =
      try do
        case EvoGit.Agent.Runner.InitialState.build(agent_module, objective) do
          {:ok, state} -> map_outcome(Exchange.run(state))
          {:error, reason} -> {:error, reason}
        end
      after
        EvoGit.AgentScheduler.Dispatch.commit_pending_in_worktree()

        # After the fallback committed, advance the agent's foreign repo's
        # PERSISTENT worktree to the agent's final HEAD — so the worktree other
        # agents read reflects the newest committed state (last-writer-wins).
        # Best-effort and a no-op for primary-repo / repo-less agents.
        EvoGit.AgentScheduler.ForeignWorktree.sync_from_agent()
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
    refresh_commit_sha(result)
  end

  defp map_outcome({:finish, _state, result}), do: {:ok, result}
  defp map_outcome({:error, reason}), do: {:error, reason}

  # Refreshes the `commit_sha` of a successful agent result with the current
  # worktree HEAD. Public (@doc false) solely so it can be tested directly
  # against a real temporary git repository.
  #
  # Repo-less agents are returned COMPLETELY unchanged (their `:repo_path` may
  # point at the real Genesis source root — git must never run there). Success
  # shapes carrying a commit sha (`%EvoGit.Agent.Result{}`, a plain map with a
  # `:commit_sha` key, or either of those wrapped in `{:ok, inner}`) are
  # refreshed; `{:error, ...}` and every other shape are returned untouched, so
  # a successful result is never turned into a failure. When the HEAD cannot be
  # re-read (missing/vanished worktree, non-git directory, unset `:repo_path`),
  # the input is returned unchanged.
  @doc false
  def refresh_commit_sha(result) do
    if Process.get(:repo_less) == true do
      result
    else
      refresh_success_shape(result)
    end
  end

  defp refresh_success_shape({:ok, inner}), do: {:ok, refresh_success_shape(inner)}

  defp refresh_success_shape(%EvoGit.Agent.Result{} = result) do
    case current_worktree_sha() do
      {:ok, sha} -> %{result | commit_sha: sha}
      :error -> result
    end
  end

  # Defensive: Genesis Mode B merges sub-results with `Map.put/3`, which keeps
  # the struct type for `%Result{}` — this clause covers plain maps that carry
  # a `:commit_sha` key.
  defp refresh_success_shape(%{commit_sha: _} = map) do
    case current_worktree_sha() do
      {:ok, sha} -> Map.put(map, :commit_sha, sha)
      :error -> map
    end
  end

  defp refresh_success_shape(other), do: other

  # Reads the worktree HEAD. Never raises: `Git.rev_parse/2` pre-checks the
  # path and returns `{:error, {:enoent, _}}` for a missing directory and
  # `{:error, {code, output}}` for a non-git directory.
  defp current_worktree_sha do
    case Process.get(:repo_path) do
      path when is_binary(path) and path != "" ->
        case Git.rev_parse(path) do
          {:ok, sha} when is_binary(sha) and sha != "" -> {:ok, sha}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # Installs the dispatch context (process dict, worktree, task tmpdir) — the
  # body lives in `EvoGit.Agent.Runner.Setup`; this name is the public one
  # existing callers and documentation use.
  defdelegate setup_dispatch_context(ctx), to: EvoGit.Agent.Runner.Setup, as: :setup

  # --- Compatibility delegations (bodies in `Exchange.{Warnings,Pending,Grace}`) ---

  defdelegate check_limit_warnings(state),
    to: EvoGit.Agent.Exchange.Warnings,
    as: :check_limit_warnings

  # Public (@doc false) solely so they can be tested directly.
  @doc false
  defdelegate drain_and_inject_user_messages(state),
    to: EvoGit.Agent.Exchange.Pending,
    as: :drain_and_inject_user_messages

  @doc false
  defdelegate inject_background_job_notices(state),
    to: EvoGit.Agent.Exchange.Pending,
    as: :inject_background_job_notices

  @doc false
  defdelegate enter_grace(state, reason, opts \\ []),
    to: EvoGit.Agent.Exchange.Grace,
    as: :enter_grace

  @doc false
  defdelegate maybe_enter_cancel_grace(state),
    to: EvoGit.Agent.Exchange.Grace,
    as: :maybe_enter_cancel_grace
end
