defmodule EvoGit.AgentScheduler.Salvage do
  @moduledoc """
  Worktree SALVAGE for a crashed agent run.

  A crash-retried agent normally gets a FRESH worktree based on
  `spec.phylo_node.current_commit` (the task base). The crashed run's
  uncommitted work is lost, because the exchange worker's `try/after`
  auto-commit does not run when the SESSION process dies abnormally. This
  module preserves that work instead:

    * stage and commit whatever the crashed run left dirty in its worktree
      (`git add --all` + `git commit`, identity/trailer supplied by
      `EvoGit.GitEnv` through the Git adapter — never hand-built here);
    * anchor the resulting commit under
      `refs/genesis/salvage/<branch_name>` so it survives the reclaim that
      follows. The anchor is REQUIRED: `WorktreeManager.destroy_worktree/3`
      deletes the agent's branch (`evogit-agent-<task>-<agent>`) right after
      this call, and without a second ref the commit would be unreachable and
      could be garbage-collected;
    * report `{:ok, sha}` (work preserved), `{:ok, nil}` (nothing worth
      preserving: clean worktree still at the task base) or `{:error, reason}`.

  ## Totality and bounds

  `salvage/3` NEVER raises and never blocks the caller indefinitely: the body
  runs in a `spawn_monitor`ed process and the caller waits at most
  `timeout_ms/0` (app env `:worktree_salvage_timeout_ms`, default `15_000`,
  non-positive/invalid values falling back to the default) before killing it
  and answering `{:error, :timeout}`. A raise/throw/exit inside the worker is
  answered `{:error, {:crashed, reason}}`.

  ## The retention ref is a small durable anchor, not an archive

  Nothing reads `refs/genesis/salvage/*` back automatically; it exists so the
  commit stays reachable while an in-memory retry decision is pending. It is
  cheap (one ref update) and harmless if it is never cleaned up.
  """

  require Logger

  alias EvoGit.Adapters.Git

  @default_timeout_ms 15_000

  # The commit the salvage itself creates for the crashed run's dirty state.
  # Identity and the co-authored-by trailer come from `EvoGit.GitEnv` through
  # `EvoGit.Adapters.Git.commit/2` (which also uses a `-F` message file).
  @commit_message "Agent: salvage uncommitted work after crash"

  # The ref namespace the salvaged commit is anchored under.
  @salvage_ref_prefix "refs/genesis/salvage/"

  @doc """
  Preserves the crashed run's work in `worktree_path` and anchors it in
  `repo_root`.

  Options:

    * `:base_sha` — the sha the crashed run started from
      (`meta.spec.phylo_node.current_commit`). A clean worktree whose HEAD is
      still exactly this sha answers `{:ok, nil}`; a `nil` base makes the
      clean case indistinguishable, so the current HEAD is retained instead.
    * `:branch_name` — the agent branch (`evogit-agent-T<n>-A<m>`), used only
      to name the retention ref. When absent nothing is anchored and the sha is
      still returned.

  Returns `{:ok, sha}`, `{:ok, nil}` or `{:error, reason}`. Total: never
  raises, and every git interaction is bounded by `timeout_ms/0`.
  """
  @spec salvage(String.t() | nil, String.t() | nil, Keyword.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def salvage(worktree_path, repo_root, opts \\ [])

  def salvage(worktree_path, repo_root, opts)
      when is_binary(worktree_path) and is_binary(repo_root) do
    timeout = timeout_ms()
    parent = self()
    tag = make_ref()

    {pid, mref} =
      spawn_monitor(fn ->
        send(parent, {tag, safe_do_salvage(worktree_path, repo_root, opts)})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(mref, [:flush])
        result

      {:DOWN, ^mref, :process, ^pid, reason} ->
        {:error, {:crashed, reason}}
    after
      timeout ->
        # Hard bound: kill the worker, wait for its DOWN (so no result message
        # can still be produced), then drop one that was already in flight.
        Process.exit(pid, :kill)
        await_down(mref, pid)
        flush_tag(tag)
        {:error, :timeout}
    end
  end

  def salvage(_worktree_path, _repo_root, _opts), do: {:ok, nil}

  @doc """
  Returns true when `sha` resolves to a commit in `repo_root`
  (`git cat-file -e <sha>^{commit}`).

  Total: a missing repo, a nil sha, an unknown object or any git failure all
  answer `false` — the caller falls back to the task base.
  """
  @spec commit_exists?(String.t() | nil, String.t() | nil) :: boolean()
  def commit_exists?(repo_root, sha) when is_binary(repo_root) and is_binary(sha) do
    case Git.run(["cat-file", "-e", sha <> "^{commit}"], repo_root) do
      {:ok, _output} -> true
      {:error, _reason} -> false
    end
  end

  def commit_exists?(_repo_root, _sha), do: false

  @doc """
  True for an exit reason that denotes an ABNORMAL (crashing) process death.

  `:normal`, `:shutdown` and `{:shutdown, term}` are the ordinary stop reasons;
  everything else — including `:killed` and any error/tuple reason — is
  abnormal and therefore worth salvaging. The single source of truth shared by
  `WorktreeManager` (its `:DOWN` handling and `salvage_for_retry/2`) and
  `Lifecycle` (crash-retry classification).
  """
  @spec abnormal_exit?(term()) :: boolean()
  def abnormal_exit?(:normal), do: false
  def abnormal_exit?(:shutdown), do: false
  def abnormal_exit?({:shutdown, _term}), do: false
  def abnormal_exit?(_reason), do: true

  @doc false
  # The configured salvage bound in milliseconds. Read at CALL time so a test
  # can shrink it without a restart; a non-positive/invalid value falls back to
  # the production default.
  @spec timeout_ms() :: pos_integer()
  def timeout_ms do
    case Application.get_env(:evo_git, :worktree_salvage_timeout_ms, @default_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_timeout_ms
    end
  end

  # --- Internals (run inside the bounded worker) ---

  # Converts any raise/throw/exit into an error tuple so the worker always
  # reports through the same channel.
  defp safe_do_salvage(worktree_path, repo_root, opts) do
    do_salvage(worktree_path, repo_root, opts)
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:crashed, {kind, reason}}}
  end

  defp do_salvage(worktree_path, repo_root, opts) do
    base_sha = Keyword.get(opts, :base_sha)
    branch_name = Keyword.get(opts, :branch_name)

    with {:ok, status} <- Git.status(worktree_path),
         {:ok, head_sha} <- head_after_commit(worktree_path, status) do
      cond do
        clean?(status) and is_binary(base_sha) and head_sha == base_sha ->
          {:ok, nil}

        true ->
          anchor(repo_root, branch_name, head_sha)
          {:ok, head_sha}
      end
    end
  end

  # A dirty worktree is committed (that IS the salvage); a clean one is only
  # read. An unborn HEAD (`git rev-parse` failure) surfaces as an error.
  defp head_after_commit(worktree_path, status) do
    if clean?(status) do
      rev_parse_head(worktree_path)
    else
      with {:ok, _output} <- Git.run(["add", "--all"], worktree_path),
           {:ok, _output} <- Git.commit(worktree_path, @commit_message) do
        rev_parse_head(worktree_path)
      end
    end
  end

  defp rev_parse_head(worktree_path) do
    case Git.rev_parse(worktree_path) do
      {:ok, sha} when is_binary(sha) -> {:ok, sha}
      {:error, _reason} = error -> error
    end
  end

  defp clean?(status) when is_binary(status), do: String.trim(status) == ""
  defp clean?(_status), do: true

  # Anchors the salvaged commit under `refs/genesis/salvage/<branch_name>`.
  # Best-effort: a failing update-ref is logged and does NOT fail the salvage
  # (the caller still learns the sha), and no branch name means no ref to name.
  defp anchor(_repo_root, nil, _sha), do: true

  defp anchor(repo_root, branch_name, sha) do
    ref_name = @salvage_ref_prefix <> to_string(branch_name)

    case Git.update_ref(repo_root, ref_name, sha) do
      {:ok, _output} ->
        true

      {:error, reason} ->
        Logger.warning("Salvage: failed to anchor #{ref_name} at #{sha}: #{inspect(reason)}")

        true
    end
  end

  defp await_down(mref, pid) do
    receive do
      {:DOWN, ^mref, :process, ^pid, _reason} -> :ok
    after
      5_000 ->
        Process.demonitor(mref, [:flush])
        :ok
    end
  end

  defp flush_tag(tag) do
    receive do
      {^tag, _result} -> :ok
    after
      0 -> :ok
    end
  end
end
