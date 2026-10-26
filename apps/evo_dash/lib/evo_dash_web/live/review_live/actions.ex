defmodule EvoDashWeb.ReviewLive.Actions do
  @moduledoc """
  Off-process action layer for `EvoDashWeb.ReviewLive`.

  Every review ACTION (merge, merge-all, reject, resume, ignore, create PR,
  extract skills, auto-resolve, review-status persistence) and every lazy diff
  fetch runs here — in a supervised task, never in the LiveView process — so a
  slow store/registry/Git/RPC call can never block (or, on a
  `GenServer.call` timeout, EXIT) the LiveView.

  No function here takes or returns a socket: each one performs the I/O and
  normalizes the raw result into a small outcome tuple. Every caller wraps the
  call in `EvoDash.SafeCall.run/1`, so a cross-process exit surfaces as
  `{:error, reason}` rather than killing the spawned task before it reports.

  All functions are TOTAL — an unexpected underlying shape becomes
  `{:error, {:unexpected, other}}` instead of a `FunctionClauseError`.
  """

  alias EvoDash.NodeContext

  @doc """
  Merges one repo's branch into `target` — `{:merged, target}` | `{:conflict,
  details}` | `{:error, reason}`.
  """
  def merge(node, repo_path, branch_name, target) do
    merge_with(merge_runner(), node, repo_path, branch_name, target)
  end

  @doc """
  Merges every entry (`%{repo_id:, repo_path:, branch_name:, target:}`)
  best-effort and sequentially — `[{repo_id, outcome}]` in input order, each
  outcome shaped like `merge/4`'s.
  """
  def merge_all(node, entries) when is_list(entries) do
    runner = merge_runner()

    Enum.map(entries, fn entry ->
      repo_id = Map.get(entry, :repo_id)

      outcome =
        merge_with(
          runner,
          node,
          Map.get(entry, :repo_path),
          Map.get(entry, :branch_name),
          Map.get(entry, :target)
        )

      {repo_id, outcome}
    end)
  end

  def merge_all(_node, _entries), do: []

  @doc """
  Rejects (deletes) one repo's branch — `:rejected` | `{:error, reason}`.
  """
  def reject(node, repo_path, branch_name) do
    case reject_runner().(node, repo_path, branch_name) do
      :ok -> :rejected
      {:error, reason} -> {:error, {:reject_failed, reason}}
      other -> {:error, {:unexpected, other}}
    end
  end

  @doc """
  Persists a task's review status on the viewed node — `:ok` | `{:error,
  reason}`.
  """
  def set_review_status(node, task_id, status) do
    case NodeContext.set_review_status(node, task_id, status) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  @doc """
  Creates the GitHub pull request for a repo's branch — `{:pr, url, title}` |
  `:no_pr` | `{:error, reason}`.
  """
  def create_pr(node, repo_path, branch_name, objective, result) do
    case NodeContext.create_github_pr(node, repo_path, branch_name, objective, result) do
      {url, title} when is_binary(url) -> {:pr, url, title}
      {nil, nil} -> :no_pr
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  @doc """
  Starts a task on the viewed node, passing `NodeContext.start_task/3`'s
  `{:ok, task}` | `{:error, reason}` through.
  """
  def start_task(node, task_type, opts) do
    case NodeContext.start_task(node, task_type, opts) do
      {:ok, task} -> {:ok, task}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  @doc """
  Marks the reviewed task continued (best-effort, its result is ignored) and
  starts the merge-resolution task — returns `start_task/3`'s result.
  """
  def auto_resolve(node, task_id, opts) do
    set_review_status(node, task_id, :continued)
    start_task(node, :evolve, opts)
  end

  @doc """
  Loads one file's review diff — `{:ok, diff_string}` | `{:error, reason}`.
  """
  def load_review_diff(node, repo_path, base_sha, commit_sha, path, opts \\ []) do
    result =
      case opts do
        [] -> NodeContext.load_file_diff(node, repo_path, base_sha, commit_sha, path)
        opts -> NodeContext.load_file_diff(node, repo_path, base_sha, commit_sha, path, opts)
      end

    normalize_diff(result)
  end

  @doc """
  Loads one file's diff within a single commit — `{:ok, diff_string}` |
  `{:error, reason}`.
  """
  def load_commit_diff(node, repo_path, commit_sha, path) do
    normalize_diff(NodeContext.load_commit_file_diff(node, repo_path, commit_sha, path))
  end

  @doc """
  Loads one file's commit diff with expanded context — `{:ok, diff_string}` |
  `{:error, reason}` (the `:commit` route's expand-context shape: diff the
  commit against its parent).
  """
  def load_commit_diff_with_opts(node, repo_path, commit_sha, path, opts) do
    normalize_diff(
      NodeContext.load_file_diff(node, repo_path, "#{commit_sha}~1", commit_sha, path, opts)
    )
  end

  defp normalize_diff({:ok, diff}), do: {:ok, diff}
  defp normalize_diff({:error, reason}), do: {:error, reason}
  defp normalize_diff(other), do: {:error, {:unexpected, other}}

  # ONE repo's merge through an already-resolved runner (shared by merge/4 and
  # merge_all/2, so a batch resolves the test seam only once).
  defp merge_with(runner, node, repo_path, branch_name, target) do
    case runner.(node, repo_path, branch_name, target) do
      {:ok, _sha} -> {:merged, target}
      {:conflict, details} -> {:conflict, details}
      {:error, reason} -> {:error, {:merge_failed, reason}}
      other -> {:error, {:unexpected, other}}
    end
  end

  # Test seams, resolved at CALL time (inside the spawned task) so tests can
  # stub the real repo-touching operations.
  defp merge_runner do
    case Application.get_env(:evo_dash, :review_merge_runner, nil) do
      nil ->
        fn node, repo_path, branch_name, merge_target ->
          if merge_target do
            NodeContext.merge_branch(node, repo_path, branch_name, merge_target)
          else
            NodeContext.merge_branch(node, repo_path, branch_name)
          end
        end

      fun ->
        fun
    end
  end

  defp reject_runner do
    Application.get_env(:evo_dash, :review_reject_runner, nil) ||
      (&NodeContext.reject_branch/3)
  end
end
