defmodule EvoGit.Adapters.Git do
  @moduledoc """
  Wrapper for Git CLI operations, focusing on Worktree isolation.
  """

  @co_author_trailer "\n\nCo-Authored-By: Genesis <noreply@evogit.ai>"

  @doc """
  Runs a git command in the given directory.
  Sets LC_ALL=C to ensure locale-independent (English) output for reliable parsing.
  """
  def run(args, cd) do
    System.cmd(EvoGit.Executable.resolve("git"), args,
      cd: cd,
      stderr_to_stdout: true,
      env: %{"LC_ALL" => "C"}
    )
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
    if branch_name && branch_exists?(repo_path, branch_name) do
      # Branch already exists (previous session crashed) — force-delete and recreate
      System.cmd(EvoGit.Executable.resolve("git"), ["branch", "-D", branch_name], cd: repo_path)
    end

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
    full_message = message <> @co_author_trailer
    run(["commit", "-m", full_message], path)
  end

  def merge(path, commit_sha) do
    case System.cmd(EvoGit.Executable.resolve("git"), ["merge", commit_sha],
           cd: path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, 1} -> {:conflict, String.trim(output)}
      {output, code} -> {:error, code, String.trim(output)}
    end
  end

  def merge_no_commit(path, commit_sha) do
    case System.cmd(EvoGit.Executable.resolve("git"), ["merge", "--no-commit", commit_sha],
           cd: path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, 1} -> {:conflict, String.trim(output)}
      {output, code} -> {:error, code, String.trim(output)}
    end
  end

  def merge_octopus(path, commit_shas) when is_list(commit_shas) do
    case System.cmd(EvoGit.Executable.resolve("git"), ["merge" | commit_shas],
           cd: path,
           stderr_to_stdout: true
         ) do
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
    case System.cmd(EvoGit.Executable.resolve("git"), ["check-ignore" | files],
           cd: path,
           stderr_to_stdout: true
         ) do
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
  Returns a short diff stat between two commits.
  Shows files changed, insertions, and deletions.
  """
  def diff_stat(path, commit_a, commit_b) do
    run(["diff", "--stat", commit_a, commit_b], path)
  end

  @doc """
  Returns the numeric diff stats between two commits.
  Outputs `additions\tdeletions\tfilepath` per line with exact counts (no terminal-width scaling).
  Binary files show `-` for additions and deletions.
  """
  def diff_numstat(path, commit_a, commit_b) do
    run(["diff", "--numstat", commit_a, commit_b], path)
  end

  @doc """
  Returns a short diff stat summary between two commits.
  Outputs a single line like:
    " 89 files changed, 18628 insertions(+), 0 deletions(-)"
  or:
    " 89 files changed, 18628 insertions(+)"
  (deletions are omitted when 0).
  """
  def diff_shortstat(path, commit_a, commit_b) do
    run(["diff", "--shortstat", commit_a, commit_b], path)
  end

  @doc """
  Adds a note to a given object (usually a commit).

  Extra args (e.g. `["--ref=evogit"]`) are placed between `notes` and the
  subcommand so that `--ref` is recognised by git.

  The force option (if true) adds `-f` after the `add` subcommand.
  """
  def add_note(path, object, message, args \\ [], force \\ false) do
    force_flag = if force, do: ["-f"], else: []
    run(["notes" | args] ++ ["add" | force_flag] ++ ["-m", message, object], path)
  end

  @doc """
  Removes a note from a given object.

  Extra args (e.g. `["--ref=evogit"]`) are placed between `notes` and the
  subcommand so that `--ref` is recognised by git.
  """
  def remove_note(path, object, args \\ []) do
    run(["notes" | args] ++ ["remove", object], path)
  end

  @doc """
  Shows the note for a given object.

  Extra args (e.g. `["--ref=evogit"]`) are placed between `notes` and the
  subcommand so that `--ref` is recognised by git.
  """
  def show_note(path, object, args \\ []) do
    run(["notes" | args] ++ ["show", object], path)
  end

  @doc """
  Gets the parsed note content for a given object as a map.
  Returns {:ok, metadata_map} or :error if note doesn't exist or is invalid JSON.
  """
  def get_note(path, object, args \\ []) do
    case run(["notes" | args] ++ ["show", object], path) do
      {:ok, note_content} ->
        case Jason.decode(note_content) do
          {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
          _ -> :error
        end

      _ ->
        :error
    end
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

  @doc """
  Deletes a branch.
  """
  def delete_branch(path, branch_name) do
    run(["branch", "-D", branch_name], path)
  end

  @doc """
  Lists branches, optionally filtered by a glob pattern.

  Returns a list of branch names (without the `*` current-branch marker
  or surrounding whitespace). When `pattern` is `nil`, all local branches
  are listed.
  """
  def list_branches(repo_root, pattern \\ nil) do
    args = if pattern, do: ["branch", "--list", pattern], else: ["branch", "--list"]

    case run(args, repo_root) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line -> line |> String.trim_leading("* ") |> String.trim() end)

      _ ->
        []
    end
  end

  @doc """
  Creates a branch pointing at a specific commit.

  Uses `git branch <name> <sha>`.
  """
  def create_branch(repo_path, branch_name, commit_sha) do
    run(["branch", branch_name, commit_sha], repo_path)
  end

  @doc """
  Returns `{:ok, branch_name}` for the current branch, or `{:ok, "HEAD"}` if detached.

  Uses `git rev-parse --abbrev-ref HEAD`.
  """
  def current_branch(repo_path) do
    run(["rev-parse", "--abbrev-ref", "HEAD"], repo_path)
  end

  @doc """
  Returns `true` if the given branch name exists in the repository, `false` otherwise.

  Uses `git show-ref --verify --quiet refs/heads/<branch_name>` and checks the exit code.
  """
  def branch_exists?(repo_path, branch_name) do
    case System.cmd(
           EvoGit.Executable.resolve("git"),
           ["show-ref", "--verify", "--quiet", "refs/heads/#{branch_name}"],
           cd: repo_path
         ) do
      {_output, 0} -> true
      {_output, _code} -> false
    end
  end

  @doc """
  Returns `true` if the `gh` CLI tool is available on the system, `false` otherwise.

  Uses `System.find_executable("gh")` to check availability.
  """
  def gh_available? do
    System.find_executable("gh") != nil
  end

  @doc """
  Checks if a branch has commits that are not in the base branch.

  Returns `true` if the branch has unique commits, `false` otherwise.
  Uses `git merge-base --is-ancestor` to check ancestry.
  """
  def branch_has_unique_commits?(repo_path, branch, base) do
    # Check if branch tip is an ancestor of base (meaning branch has no unique commits)
    case System.cmd(
           EvoGit.Executable.resolve("git"),
           ["merge-base", "--is-ancestor", branch, base],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      # branch is ancestor of base, no unique commits
      {_output, 0} -> false
      # branch has commits not in base
      {_output, 1} -> true
      # assume unique commits on other errors
      {_output, _} -> true
    end
  end

  @doc """
  Pushes a branch to the remote repository.

  Returns `{:ok, output}` on success, `{:conflict, output}` or `{:error, code, output}` on failure.
  """
  def push_branch(repo_path, branch_name) do
    run(["push", "-u", "origin", branch_name], repo_path)
  end

  @doc """
  Creates a pull request using the `gh` CLI.

  Uses `gh pr create --head <head> --base <base> --title <title> --body <body>`.
  Returns `{:ok, pr_url}` on success, `{:error, code, output}` on failure.
  """
  def create_pull_request(repo_path, head_branch, base_branch, title, body) do
    case System.cmd(
           "gh",
           [
             "pr",
             "create",
             "--head",
             head_branch,
             "--base",
             base_branch,
             "--title",
             title,
             "--body",
             body
           ],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, code, String.trim(output)}
    end
  end

  @doc """
  Checks if the repository has a remote named 'origin'.

  Returns `true` if origin remote exists, `false` otherwise.
  """
  def has_origin_remote?(repo_path) do
    case System.cmd(EvoGit.Executable.resolve("git"), ["remote", "get-url", "origin"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      {_output, _} -> false
    end
  end

  @doc """
  Creates a new remote repository using `gh` CLI and adds it as origin.

  Uses `gh repo create` with the current directory name as the repo name.
  Returns `{:ok, repo_url}` on success, `{:error, code, output}` on failure.
  """
  def create_origin_remote(repo_path) do
    dir_name = Path.basename(repo_path)

    case System.cmd(
           "gh",
           [
             "repo",
             "create",
             dir_name,
             "--private",
             "--source=.",
             "--remote=origin",
             "--push=false"
           ],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        # Extract the repo URL from the output
        case parse_repo_url(output) do
          {:ok, url} -> {:ok, url}
          :error -> {:ok, "https://github.com/#{get_github_username()}/#{dir_name}"}
        end

      {output, code} ->
        {:error, code, String.trim(output)}
    end
  end

  @doc """
  Gets the default branch name of the origin remote.

  Returns `{:ok, branch_name}` or `{:error, reason}`.
  """
  def origin_default_branch(repo_path) do
    case System.cmd(
           EvoGit.Executable.resolve("git"),
           ["symbolic-ref", "refs/remotes/origin/HEAD"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        branch = output |> String.trim() |> String.split("/") |> List.last()
        {:ok, branch}

      {_output, _} ->
        # Fallback to common defaults
        {:ok, "main"}
    end
  end

  defp parse_repo_url(output) do
    case Regex.run(~r/https:\/\/github\.com\/[^\/]+\/[^\/\s]+/, output) do
      [url | _] -> {:ok, url}
      _ -> :error
    end
  end

  defp get_github_username do
    case System.cmd("gh", ["auth", "status"]) do
      {output, 0} ->
        case Regex.run(~r/Logged in as ([^\s]+)/, output) do
          [_, username | _] -> username
          _ -> "unknown"
        end

      _ ->
        "unknown"
    end
  end
end
