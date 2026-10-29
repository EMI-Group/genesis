defmodule EvoGit.Agent.ConflictState do
  @moduledoc """
  The ONE owner of the per-turn merge-conflict snapshot of an agent's worktree.

  The list of currently conflicted files is cached in the agent's PROCESS
  DICTIONARY and refreshed exactly ONCE per turn, at the END of the turn
  (`EvoGit.Agent.ToolDispatch.continue_after_tools/6`). Every consumer within
  the FOLLOWING turn therefore sees the same list with ZERO extra git calls:

    * the delegation-hint suppression in `ToolDispatch.batch_execute_tools/5`
      (`EvoGit.Agent.DelegationHints.filter_child_paths_if_conflicts/2`);
    * the delegation-reminder gate in `EvoGit.Agent.Runner.check_limit_warnings/1`
      (`EvoGit.Agent.TurnWarning` — a pure process-dictionary read).

  ## Why the snapshot is safe

  Defaulting to `[]` before the first refresh is safe: a fresh agent worktree is
  checked out at a commit, i.e. provably conflict-free — a conflict can only
  appear after a `git merge`/`rebase`/`cherry-pick` tool call, which always ends
  a turn and thus triggers a refresh.

  A git failure degrades to `[]` (best-effort: a broken `git diff` must never
  crash the agent loop, it only loses the transient suppression for one turn).

  Repo-less agents (the self-reflective agent) never shell out: `refresh/1`
  stores `[]` without calling git when `Process.get(:repo_less)` is truthy or the
  given repo path is not a binary.
  """
  alias EvoGit.Adapters.Git

  @pd_key :conflict_files

  @doc """
  Refreshes the per-turn snapshot and returns the currently conflicted files.

  Runs `git diff --name-only --diff-filter=U` in `repo_path` (via
  `EvoGit.Adapters.Git.conflict_files/1`) and stores the result in the process
  dictionary. Any error — a non-binary `repo_path`, a repo-less agent, or a git
  failure — is tolerated as `[]`, so this never raises and never crashes the
  loop.
  """
  @spec refresh(term()) :: [String.t()]
  def refresh(repo_path) when is_binary(repo_path) do
    files =
      if Process.get(:repo_less) do
        []
      else
        case Git.conflict_files(repo_path) do
          {:ok, files} -> files
          _ -> []
        end
      end

    Process.put(@pd_key, files)
    files
  end

  def refresh(_repo_path) do
    Process.put(@pd_key, [])
    []
  end

  @doc """
  Returns the cached conflict snapshot, defaulting to `[]` when it was never
  refreshed in this process.
  """
  @spec files() :: [String.t()]
  def files, do: Process.get(@pd_key, [])

  @doc """
  Returns `true` when the cached snapshot is non-empty, i.e. the agent's
  worktree currently has unresolved merge conflicts.
  """
  @spec in_conflict?() :: boolean()
  def in_conflict?, do: files() != []
end
