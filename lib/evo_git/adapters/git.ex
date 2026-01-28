defmodule EvoGit.Adapters.Git do
  @moduledoc """
  Wrapper for Git CLI operations, focusing on Worktree isolation.
  """

  @doc """
  Runs a git command in the given directory.
  """
  def run(args, cd) do
    case System.cmd("git", args, cd: cd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, code, String.trim(output)}
    end
  end

  def add_worktree(repo_path, worktree_path, base_sha, branch_name \\ nil) do
    args =
      if branch_name do
        ["worktree", "add", "-b", branch_name, worktree_path, base_sha]
      else
        ["worktree", "add", "--detach", worktree_path, base_sha]
      end

    run(args, repo_path)
  end

  def prune_worktrees(repo_path) do
    run(["worktree", "prune"], repo_path)
  end

  def checkout(path, sha) do
    run(["checkout", sha], path)
  end

  def reset_hard(path, sha \\ "HEAD") do
    run(["reset", "--hard", sha], path)
  end

  def clean(path) do
    run(["clean", "-fd"], path)
  end

  def add(path, files \\ ".") do
    run(["add", files], path)
  end

  def commit(path, message) do
    run(["commit", "-m", message], path)
  end

  def merge(path, commit_sha) do
    case System.cmd("git", ["merge", commit_sha], cd: path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, 1} -> {:conflict, String.trim(output)}
      {output, code} -> {:error, code, String.trim(output)}
    end
  end

  def merge_base(path, commit_a, commit_b) do
    run(["merge-base", commit_a, commit_b], path)
  end

  def conflict_files(path) do
    # Returns list of files with conflicts
    case run(["diff", "--name-only", "--diff-filter=U"], path) do
      {:ok, output} ->
        files = if output == "", do: [], else: String.split(output, "\n")
        {:ok, files}

      error ->
        error
    end
  end

  def rev_parse(path, rev \\ "HEAD") do
    run(["rev-parse", rev], path)
  end
end
