defmodule EvoGit.Agent.Runner do
  @moduledoc """
  The remaining thin helpers of the agent run, plus the `commit_sha` refresh.

  The agent lifecycle itself now lives in `EvoGit.Agent.Session` (the supervised
  per-agent `gen_statem`) and its per-exchange worker
  (`EvoGit.Agent.Session.Worker`), which drives `EvoGit.Agent.Exchange.run/2`
  and publishes every turn's state through the `:checkpoint` seam. Set-up lives
  in `EvoGit.Agent.Session.Setup` (worktree binding, process context and the
  initial `%EvoGit.Agent.State{}`).

  What is left here is callable without a session:

    * `refresh_commit_sha/1` — re-reads the worktree HEAD after the auto-commit
      fallback so `Result.commit_sha` never points at the pre-fallback commit;
      the session worker calls it exactly like the retired one-shot driver did.
    * pure delegations to the engine helpers (`check_limit_warnings/1`,
      `drain_and_inject_user_messages/1,2`, `inject_background_job_notices/1,2`,
      `enter_grace/2,3`, `maybe_enter_cancel_grace/1`), kept so tests can reach
      the same behaviour through one shim.
  """

  alias EvoGit.Adapters.Git

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

  # --- Compatibility delegations (bodies in `Exchange.{Warnings,Pending,Grace}`) ---

  defdelegate check_limit_warnings(state),
    to: EvoGit.Agent.Exchange.Warnings,
    as: :check_limit_warnings

  # Public (@doc false) solely so they can be tested directly.
  @doc false
  defdelegate drain_and_inject_user_messages(state, opts \\ []),
    to: EvoGit.Agent.Exchange.Pending,
    as: :drain_and_inject_user_messages

  @doc false
  defdelegate inject_background_job_notices(state, opts \\ []),
    to: EvoGit.Agent.Exchange.Pending,
    as: :inject_background_job_notices

  @doc false
  defdelegate enter_grace(state, reason, opts \\ []),
    to: EvoGit.Agent.Exchange.Grace,
    as: :enter_grace

  @doc false
  defdelegate maybe_enter_cancel_grace(state, opts \\ []),
    to: EvoGit.Agent.Exchange.Grace,
    as: :maybe_enter_cancel_grace
end
