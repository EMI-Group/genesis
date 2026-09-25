defmodule EvoGit.AgentScheduler.ForeignWorktree do
  @moduledoc """
  Lifecycle for the persistent worktree of every WRITABLE foreign repo.

  Each writable foreign repo keeps ONE long-lived checkout at
  `<root>/.genesis/foreign_repos/<id>` (path derived purely by
  `EvoGit.Core.ForeignRepo.worktree_path/1`). The location is deliberate:
  it lives OUTSIDE `.genesis/workers/`, so the `WorktreeManager`'s
  primary-only init wipe and the per-agent `destroy_worktree/3` teardown
  NEVER touch it.

  The worktree reflects the repo's **latest committed state**
  (last-writer-wins), so agents can read the foreign code through an absolute
  path that always resolves to fresh content. Provisioning and advancing the
  worktree NEVER create a branch and NEVER move the foreign repo's MAIN
  working-copy HEAD — the main checkout stays exactly where the user left it.

  Worktrees are intentionally **NOT torn down at task end**: the directory
  rides under the gitignored `.genesis/`, and the next task REUSES it,
  resetting it to the new starting commit (`ensure/2`). That keeps the
  provisioning cost to a single `git worktree add` for the first task and a
  cheap `git checkout`/`reset --hard` ever after.

  ## API

  - `start_commit/1` — the commit the worktree should sit at (`base_sha` when
    set, else the repo HEAD).
  - `ensure/2` — idempotent create-or-reset of the worktree at a commit.
  - `ensure_all/1` — provision every writable, non-primary repo in a list.
  - `sync_from_agent/0` — advance the worktree to the agent's final commit
    (called from the agent process after the run, post auto-commit fallback).

  All functions are TOTAL — they never raise (git failures arrive as error
  tuples via `EvoGit.Adapters.Git` and are returned or logged), and all git
  access goes through `EvoGit.Adapters.Git` only.
  """

  require Logger

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.WorktreeRetry
  alias EvoGit.Core.ForeignRepo

  @doc """
  The commit the persistent worktree should sit at: the repo's `base_sha` when
  set, otherwise the repo's current HEAD (`git rev-parse HEAD`).

  Returns `{:ok, sha} | {:error, reason}`.
  """
  @spec start_commit(ForeignRepo.t()) :: {:ok, String.t()} | {:error, term()}
  def start_commit(%ForeignRepo{base_sha: base_sha} = repo) do
    if is_binary(base_sha) and base_sha != "" do
      {:ok, base_sha}
    else
      Git.rev_parse(repo.root)
    end
  end

  def start_commit(repo), do: {:error, {:invalid_repo, repo}}

  @doc """
  Idempotently provisions (or advances) the persistent worktree of a writable
  foreign repo to `commit_sha`.

  - The worktree is created with `git worktree add --detach <path> <sha>`
    (never a branch) when it does not exist yet, or when the path is not a
    registered linked worktree.
  - An existing worktree is advanced with `git checkout <sha>`, falling back to
    `git reset --hard <sha>` when the checkout fails (e.g. dirty tree).
  - A non-writable repo is a no-op (`:ok`) — only writable foreign repos get a
    persistent worktree.

  Returns `:ok | {:error, {tag, output}}`.
  """
  @spec ensure(ForeignRepo.t(), String.t()) :: :ok | {:error, {term(), term()}}
  def ensure(%ForeignRepo{writable: true} = repo, commit_sha)
      when is_binary(commit_sha) and commit_sha != "" do
    worktree = worktree_path(repo)

    if valid_worktree?(worktree) do
      update_worktree(worktree, commit_sha)
    else
      create_worktree(repo, worktree, commit_sha)
    end
  end

  def ensure(%ForeignRepo{}, _commit_sha), do: :ok
  def ensure(_repo, _commit_sha), do: :ok

  @doc """
  Provisions the persistent worktree of every WRITABLE, non-primary foreign
  repo in `repos`, each at its own `start_commit/1`.

  Best-effort by design: a failure for one repo is logged as a warning and
  never raises (the task keeps its read path and the next task retries).
  Always returns `:ok`.
  """
  @spec ensure_all([ForeignRepo.t()]) :: :ok
  def ensure_all(repos) do
    repos
    |> normalize_repos()
    |> Enum.filter(fn repo -> repo.writable == true and not ForeignRepo.primary?(repo.id) end)
    |> Enum.each(&ensure_one/1)

    :ok
  end

  @doc """
  Advances the persistent worktree of the agent's CURRENT foreign repo to the
  agent's final committed HEAD — called from the agent process itself, after
  `EvoGit.AgentScheduler.Dispatch.commit_pending_in_worktree/0` ran, so the
  persistent worktree reflects the agent's final commit (including the
  auto-commit fallback) on every exit path.

  Resolution is entirely process-dictionary based (the process dict is the only
  bridge into the agent process): the repo is the entry in
  `Process.get(:foreign_repos)` whose `id` matches `Process.get(:evogit_repo_id)`
  (the ROOT agent's id is `"primary"`, which matches no foreign repo — no-op),
  and the agent's HEAD is read from `Process.get(:repo_path)` (the agent's own
  worktree).

  Repo-less agents, missing/non-writable repos, an unreadable repo path and any
  git failure are all no-ops (a git failure is logged as a warning) — this runs
  in an `after` block, so it must never raise. Always returns `:ok`.
  """
  @spec sync_from_agent() :: :ok
  def sync_from_agent do
    if Process.get(:repo_less) do
      :ok
    else
      case agent_foreign_repo() do
        %ForeignRepo{} = repo -> sync_repo_head(repo)
        nil -> :ok
      end
    end
  end

  @doc """
  Persistent worktree path of a foreign repo — delegates to
  `EvoGit.Core.ForeignRepo.worktree_path/1` (single source of truth).
  """
  @spec worktree_path(ForeignRepo.t()) :: String.t()
  def worktree_path(%ForeignRepo{} = repo), do: ForeignRepo.worktree_path(repo)

  # ---------------------------------------------------------------------------
  # ensure/2 internals
  # ---------------------------------------------------------------------------

  # A registered linked worktree has a `.git` FILE (containing `gitdir: ...`);
  # a plain leftover dir has none. PURE check — no git subprocess. A path whose
  # `.git` is a directory is a real working tree and is never treated as ours
  # (it cannot be — the worktree path is under `.genesis/foreign_repos/` — but
  # the check stays conservative for the same reason as
  # `Git.remove_leftover_worktree_dir/1`).
  defp valid_worktree?(worktree) do
    File.dir?(worktree) and File.regular?(Path.join(worktree, ".git"))
  end

  defp create_worktree(repo, worktree, commit_sha) do
    case WorktreeRetry.mkdir_p_retry(Path.dirname(worktree)) do
      :ok -> add_worktree(repo, worktree, commit_sha)
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  # `git worktree add` can fail on stale worktree metadata left behind by a
  # killed task (the worktree dir is gone but the entry is still registered, so
  # git refuses to re-add the path). Prune once and retry a single time —
  # `add_worktree/3` cleans its own leftovers on failure, so the retry starts
  # from a clean state.
  defp add_worktree(repo, worktree, commit_sha) do
    case Git.add_worktree(repo.root, worktree, commit_sha) do
      {:ok, _output} ->
        :ok

      {:error, _reason} ->
        WorktreeRetry.retry_on_transient(fn -> Git.prune_worktrees(repo.root) end)

        case Git.add_worktree(repo.root, worktree, commit_sha) do
          {:ok, _output} -> :ok
          {:error, _reason} = retry_error -> retry_error
        end
    end
  end

  defp update_worktree(worktree, commit_sha) do
    case Git.checkout(worktree, commit_sha) do
      {:ok, _output} ->
        :ok

      {:error, _reason} ->
        # Checkout refuses to move a dirty/conflicted worktree — hard-reset it
        # to the target commit instead (the worktree is a read cache of the
        # repo's committed state; nothing in it is user work).
        case Git.reset_hard(worktree, commit_sha) do
          {:ok, _output} -> :ok
          {:error, _reason} = error -> error
        end
    end
  end

  defp ensure_one(repo) do
    case start_commit(repo) do
      {:ok, sha} ->
        case ensure(repo, sha) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "ForeignWorktree: failed to provision the persistent worktree for " <>
                "foreign repo '#{repo.id}' at '#{repo.root}': #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.warning(
          "ForeignWorktree: could not resolve the starting commit for foreign repo " <>
            "'#{repo.id}' at '#{repo.root}': #{inspect(reason)}"
        )
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # sync_from_agent/0 internals
  # ---------------------------------------------------------------------------

  # The agent's own foreign repo, resolved purely from the process dict: the
  # task-level `:foreign_repos` list (structs OR string-keyed Codec round-trip
  # maps → normalized) matched by id against `:evogit_repo_id`. Read-only
  # entries (and the primary repo, whose id matches nothing) yield nil.
  defp agent_foreign_repo do
    repo_id = Process.get(:evogit_repo_id)

    if is_binary(repo_id) and repo_id != "" do
      Process.get(:foreign_repos, [])
      |> normalize_repos()
      |> Enum.find(fn repo -> repo.id == repo_id and repo.writable == true end)
    end
  end

  # Reads the agent's own worktree HEAD and advances the persistent worktree to
  # it. An unset `:repo_path` is a no-op (`get/2` — never a KeyError-shaped
  # crash in an `after` block).
  defp sync_repo_head(repo) do
    case Process.get(:repo_path, nil) do
      path when is_binary(path) and path != "" -> sync_repo_path(repo, path)
      _other -> :ok
    end
  end

  defp sync_repo_path(repo, path) do
    case Git.rev_parse(path) do
      {:ok, sha} when is_binary(sha) and sha != "" ->
        case ensure(repo, sha) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "ForeignWorktree: failed to advance the persistent worktree of foreign " <>
                "repo '#{repo.id}' to #{sha}: #{inspect(reason)}"
            )
        end

      {:ok, _other} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ForeignWorktree: could not resolve HEAD of '#{path}' for foreign repo " <>
            "'#{repo.id}': #{inspect(reason)}"
        )
    end

    :ok
  end

  # Accepts structs and the STRING-keyed maps that survive a Codec round trip
  # (persisted task opts); unparseable entries are dropped. Never raises.
  defp normalize_repos(repos) when is_list(repos) do
    repos
    |> Enum.map(&ForeignRepo.normalize/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_repos(_other), do: []
end
