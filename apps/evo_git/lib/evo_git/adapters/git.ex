defmodule EvoGit.Adapters.Git do
  @moduledoc """
  Wrapper for Git CLI operations, focusing on Worktree isolation.
  """

  @doc """
  Runs a git command in the given directory.
  """
  def run(args, cd) do
    System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    |> handle_git_command_result(args, cd)
  end

  defp handle_git_command_result({output, 0}, _args, _cd), do: {:ok, String.trim(output)}

  defp handle_git_command_result({output, 1}, ["commit" | _], _cd) do
    # This is a graceful "no changes to commit" scenario for `git commit`
    if String.contains?(output, "nothing to commit, working tree clean") do
      {:ok, String.trim(output)}
    else
      # If it's a commit command with exit 1, but not the "nothing to commit" message, it's an error
      {:error, 1, String.trim(output)}
    end
  end

  defp handle_git_command_result({output, 1}, _args, _cd) do
    # Default behavior for exit code 1 (e.g., merge conflicts)
    {:conflict, String.trim(output)}
  end

  defp handle_git_command_result({output, code}, _args, _cd),
    do: {:error, code, String.trim(output)}

  def init(path) do
    run(["init"], path)
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

  def merge_octopus(path, commit_shas) when is_list(commit_shas) do
    case System.cmd("git", ["merge" | commit_shas], cd: path, stderr_to_stdout: true) do
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

  def status(path) do
    run(["status", "--porcelain"], path)
  end

  def rev_parse(path, rev \\ "HEAD") do
    run(["rev-parse", rev], path)
  end

  def check_ignore(path, files) when is_list(files) do
    # git check-ignore returns 0 if any matches, 1 if none.
    # We want the list of ignored files.
    case System.cmd("git", ["check-ignore" | files], cd: path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      {_output, 1} -> {:ok, []}
      {output, code} -> {:error, code, String.trim(output)}
    end
  end

  @doc """
  Returns the commit log.
  """
  def log(path, args \\ []) do
    run(["log" | args], path)
  end

  @doc """
  Returns the commit history for a specific file.
  """
  def file_history(path, file_path, args \\ []) do
    run(["log" | args] ++ ["--", file_path], path)
  end

  @doc """
  Shows the content of an object (commit, tree, blob, etc.).
  """
  def show(path, args) when is_list(args) do
    run(["show" | args], path)
  end

  def show(path, object_name) when is_binary(object_name) do
    run(["show", object_name], path)
  end

  @doc """
  Returns the diff between two commits.
  """
  def diff(path, commit_a, commit_b, args \\ []) do
    run(["diff" | args] ++ [commit_a, commit_b], path)
  end

  @doc """
  Returns the diff for a specific file between two commits.
  """
  def file_diff(path, file_path, commit_a, commit_b, args \\ []) do
    run(["diff" | args] ++ [commit_a, commit_b, "--", file_path], path)
  end

  @doc """
  Adds a note to a given object (usually a commit).
  """
  def add_note(path, object, message, args \\ []) do
    run(["notes", "add"] ++ args ++ ["-m", message, object], path)
  end

  @doc """
  Removes a note from a given object.
  """
  def remove_note(path, object, args \\ []) do
    run(["notes", "remove"] ++ args ++ [object], path)
  end

  @doc """
  Shows the note for a given object.
  """
  def show_note(path, object, args \\ []) do
    run(["notes", "show"] ++ args ++ [object], path)
  end

  @doc """
  Lists all notes.
  """
  def list_notes(path, args \\ []) do
    run(["notes", "list" | args], path)
  end

  @doc """
  Creates a tag on a specific commit.
  """
  def tag(path, tag_name, commit_sha \\ "HEAD") do
    run(["tag", tag_name, commit_sha], path)
  end

  @doc """
  Deletes a tag.
  """
  def delete_tag(path, tag_name) do
    run(["tag", "-d", tag_name], path)
  end
end
