defmodule EvoGit.Review do
  @moduledoc """
  Review context module for managing code review operations.

  Provides functions for loading diff data, listing commits, merging/rejecting branches,
  and creating GitHub PRs manually from the review page.
  """

  alias EvoGit.Adapters.Git
  require Logger

  defmodule FileInfo do
    @moduledoc "Structured info about a changed file"
    defstruct [
      :path,
      :status,
      :additions,
      :deletions,
      :diff,
      :language,
      # Full file content at the head/new commit (nil until populated by the caller)
      full_new_content: nil,
      # Full file content at the base/old commit (nil until populated by the caller)
      full_old_content: nil
    ]
  end

  defmodule CommitInfo do
    @moduledoc "Structured info about a commit"
    defstruct [:sha, :short_sha, :message, :author_name, :author_email, :date]
  end

  @doc """
  Fetches the full content of a file at a specific commit.

  Returns `{:ok, content}` if the file exists at that commit, or
  `{:error, {tag, output}}` if not.

  This uses the standard git `"commit_sha:file_path"` revision syntax to
  address a file at a specific revision, enabling the caller to highlight
  the entire file (rather than per-hunk) with full context.
  """
  def get_file_content(repo_path, commit_sha, file_path) do
    Git.show(repo_path, "#{commit_sha}:#{file_path}")
  end

  # Record separator and git log pretty-format shared by list_commits/2 and
  # list_commits_from_shas/3.
  @commit_separator "|||COMMIT_SEP|||"
  @commit_format "%H%n%h%n%s%n%an%n%ae%n%aI%n#{@commit_separator}"

  @doc """
  Lists commits between base and branch tip, returning a list of CommitInfo structs.
  Returns {:ok, commits} or {:error, reason}.
  """
  def list_commits(repo_path, branch_name) do
    with {:ok, commit_sha} <- Git.rev_parse(repo_path, branch_name),
         {:ok, base_sha} <- resolve_merge_base(repo_path, commit_sha) do
      do_list_commits(repo_path, ["--format=#{@commit_format}", "#{base_sha}..#{commit_sha}"])
    else
      _ -> {:ok, []}
    end
  end

  @doc """
  Loads all review data for a given branch in a repository.
  Returns a map with :commit_sha, :base_sha, :diff_stat, :diff, :files, :changed_files_count, :total_additions, :total_deletions.
  The base is the merge-base between HEAD and the branch tip, so only the branch's changes are shown.
  """
  def load_review_data(repo_path, branch_name) do
    with {:ok, commit_sha} <- Git.rev_parse(repo_path, branch_name),
         {:ok, base_sha} <- resolve_merge_base(repo_path, commit_sha) do
      {:ok, diff_stat} = Git.diff_stat(repo_path, base_sha, commit_sha)
      {:ok, diff} = Git.diff(repo_path, base_sha, commit_sha)

      files = parse_diff_into_files(diff)
      {total_additions, total_deletions} = count_changes(files)

      {:ok,
       %{
         commit_sha: commit_sha,
         base_sha: base_sha,
         diff_stat: diff_stat,
         diff: diff,
         files: files,
         changed_files_count: length(files),
         total_additions: total_additions,
         total_deletions: total_deletions
       }}
    else
      error -> error
    end
  end

  @doc """
  Loads review metadata only (file list with counts, no diffs).
  Same return shape as `load_review_data/2` but the `:diff` field on each file is `nil`
  and the top-level `:diff` field is `nil`.

  This is much faster than `load_review_data/2` because it skips the full diff.
  Use this to show the file list immediately, then lazy-load individual file diffs
  via `load_file_diff/4`.

  Uses `git diff --shortstat` for accurate total line counts, since the summary
  is computed directly by git rather than summed from per-file entries.
  """
  def load_review_metadata(repo_path, branch_name) do
    with {:ok, commit_sha} <- Git.rev_parse(repo_path, branch_name),
         {:ok, base_sha} <- resolve_merge_base(repo_path, commit_sha) do
      {:ok, diff_stat} = Git.diff_numstat(repo_path, base_sha, commit_sha)

      files = parse_diff_stat_into_files(diff_stat)

      # Use --shortstat for accurate totals (single line from git, no per-file summing)
      totals =
        case Git.diff_shortstat(repo_path, base_sha, commit_sha) do
          {:ok, shortstat} ->
            totals = parse_shortstat(shortstat)
            # Log discrepancy if per-file summing differs from shortstat
            per_file = count_changes(files)

            if totals != per_file do
              Logger.warning(
                "Review totals mismatch for #{branch_name}: shortstat=#{inspect(totals)}, per_file=#{inspect(per_file)}"
              )
            end

            totals

          _ ->
            count_changes(files)
        end

      {:ok, build_metadata_map(base_sha, commit_sha, diff_stat, files, totals)}
    else
      error -> error
    end
  end

  @doc """
  Loads the diff for a single file between two commits.
  Delegates to `Git.file_diff/5` with the given base and commit SHAs.

  Returns `{:ok, diff_string}` or `{:error, {tag, output}}`.
  """
  def load_file_diff(repo_path, base_sha, commit_sha, file_path) do
    Git.file_diff(repo_path, file_path, base_sha, commit_sha, [])
  end

  @doc """
  Loads the diff for a single file between two commits with options.

  ## Options

    * `:context` - the number of context lines around changes. Pass an integer
      for a specific number of lines, `:all` for the full file, or `nil` (default)
      for git's default of 3 context lines.

  Returns `{:ok, diff_string}` or `{:error, {tag, output}}`.
  """
  def load_file_diff(repo_path, base_sha, commit_sha, file_path, opts) when is_list(opts) do
    args =
      case Keyword.get(opts, :context) do
        :all -> ["-U999999"]
        n when is_integer(n) -> ["-U#{n}"]
        nil -> []
      end

    Git.file_diff(repo_path, file_path, base_sha, commit_sha, args)
  end

  @doc """
  Loads review metadata from explicit base and commit SHAs.

  Unlike `load_review_metadata/2`, this does not resolve a merge base or require
  the branch to still exist — it uses the provided SHAs directly. This is useful
  after a branch has been merged or deleted but the commit objects are still
  reachable in the object database.

  Returns `{:ok, metadata_map}` with the same shape as `load_review_metadata/2`.
  """
  def load_review_metadata_from_shas(repo_path, base_sha, commit_sha) do
    with {:ok, diff_stat} <- Git.diff_numstat(repo_path, base_sha, commit_sha) do
      files = parse_diff_stat_into_files(diff_stat)
      totals = totals_via_shortstat(repo_path, base_sha, commit_sha, files)
      {:ok, build_metadata_map(base_sha, commit_sha, diff_stat, files, totals)}
    end
  end

  @doc """
  Lists commits between two explicit SHAs, returning a list of CommitInfo structs.

  Like `list_commits_from_shas/3` but without requiring the branch to exist.
  Returns `{:ok, commits}`.
  """
  def list_commits_from_shas(repo_path, base_sha, commit_sha) do
    do_list_commits(repo_path, ["--format=#{@commit_format}", "#{base_sha}..#{commit_sha}"])
  end

  @doc """
  Loads review metadata for a single commit (its diff against its parent).

  Uses `commit_sha~1` as the base, so only the changes introduced by that commit
  are shown.

  Returns `{:ok, metadata_map}` with the same shape as `load_review_metadata/2`,
  or `{:error, reason}` if the diff cannot be computed.
  """
  def load_commit_files(repo_path, commit_sha) do
    base_sha = "#{commit_sha}~1"

    with {:ok, diff_stat} <- Git.diff_numstat(repo_path, base_sha, commit_sha) do
      files = parse_diff_stat_into_files(diff_stat)
      totals = totals_via_shortstat(repo_path, base_sha, commit_sha, files)
      {:ok, build_metadata_map(base_sha, commit_sha, diff_stat, files, totals)}
    end
  end

  @doc """
  Loads the diff for a single file in a single commit (against its parent).

  Returns `{:ok, diff_string}` or `{:error, {tag, output}}`.
  """
  def load_commit_file_diff(repo_path, commit_sha, file_path) do
    Git.file_diff(repo_path, file_path, "#{commit_sha}~1", commit_sha)
  end

  @merge_target_candidates ["main", "master", "dev", "prod"]

  @doc """
  Merges the branch into the default merge target branch and deletes the branch.
  Returns {:ok, merged_sha} or {:conflict, details} or {:error, reason}.
  """
  def merge_branch(repo_path, branch_name) do
    case default_merge_target(repo_path) do
      {:ok, target} -> merge_branch(repo_path, branch_name, target)
      {:error, _} = error -> error
    end
  end

  @doc """
  Checks whether merging `branch_or_sha` into `target_branch` would conflict,
  without mutating the repository.

  This is a **non-mutating dry-run**: both refs are resolved, and the merge is
  then computed in memory by `git merge-tree --write-tree --name-only
  --no-messages` (requires git >= 2.38). `merge-tree` performs a real merge of
  the two commits' trees without touching the working tree, the index, or any
  ref — no temporary worktree is ever created (nothing is added to
  `<repo_path>/.genesis/`), nothing is committed, and the merge result is
  simply discarded.

  When both refs resolve to the same commit SHA (the branch is already merged
  into the target, or the two refs are identical), `{:ok, :clean}` is returned
  immediately without attempting any merge.

  Returns:

    * `{:ok, :clean}` — the merge would apply without conflicts (or the refs
      point at the same commit).
    * `{:ok, {:conflict, files}}` — the merge would conflict; `files` is the
      list of conflicted file paths.
    * `{:error, reason}` — a missing/unresolvable ref, a conflicted merge with
      no detectable conflict files, or any other git failure (`{tag, output}`,
      per the `EvoGit.Adapters.Git` return contract).
  """
  def check_merge(repo_path, branch_or_sha, target_branch) do
    with {:ok, branch_sha} <- Git.rev_parse(repo_path, branch_or_sha),
         {:ok, target_sha} <- Git.rev_parse(repo_path, target_branch) do
      if branch_sha == target_sha do
        {:ok, :clean}
      else
        check_merge_with_merge_tree(repo_path, branch_sha, target_sha)
      end
    else
      error -> error
    end
  end

  @doc """
  Merges the branch's tip commit into `target_branch` and deletes the branch.

  Works regardless of the currently checked-out branch: switches to
  `target_branch`, merges, then restores the original branch. The agent branch
  is only deleted on a successful merge.

  Returns {:ok, merged_sha} or {:conflict, details} or {:error, reason}.
  """
  def merge_branch(repo_path, branch_name, target_branch) do
    case Git.rev_parse(repo_path, branch_name) do
      {:ok, commit_sha} ->
        case Git.current_branch(repo_path) do
          {:ok, current} ->
            if target_branch == current do
              merge_into_current(repo_path, branch_name, commit_sha)
            else
              merge_into_other(repo_path, branch_name, target_branch, current, commit_sha)
            end

          other ->
            other
        end

      other ->
        other
    end
  end

  @doc """
  Resolves the default branch to merge agent branches into.

  Checks `main`, `master`, `dev`, `prod` in order, then falls back to the
  current branch (skipping detached HEAD), then the first local branch.
  Returns `{:ok, name}` or `{:error, :no_branch_found}`.
  """
  def default_merge_target(repo_path) do
    case Enum.find(@merge_target_candidates, &Git.branch_exists?(repo_path, &1)) do
      nil ->
        case current_branch_or_first_local(repo_path) do
          {:ok, name} -> {:ok, name}
          :none -> {:error, :no_branch_found}
        end

      name ->
        {:ok, name}
    end
  end

  @doc """
  Returns all local branch names.

  Delegates to `EvoGit.Adapters.Git.list_branches/1`; returns
  `{:ok, names}` or `{:error, {tag, output}}`.
  """
  def list_branches(repo_path) do
    Git.list_branches(repo_path)
  end

  # Merges the agent tip into the currently checked-out branch (no switching
  # needed). Deletes the agent branch on success.
  defp merge_into_current(repo_path, branch_name, commit_sha) do
    case Git.merge(repo_path, commit_sha) do
      {:ok, _output} ->
        Git.delete_branch(repo_path, branch_name)
        {:ok, commit_sha}

      {:error, {:conflict, details}} ->
        {:conflict, details}

      {:error, {code, output}} ->
        {:error, {code, output}}
    end
  end

  # Merges the agent tip into a target branch that is not checked out:
  # switch to the target, merge, then restore the original branch. The agent
  # branch is only deleted on a successful merge.
  defp merge_into_other(repo_path, branch_name, target_branch, current, commit_sha) do
    case Git.checkout(repo_path, target_branch) do
      {:ok, _} ->
        case Git.merge(repo_path, commit_sha) do
          {:ok, _output} ->
            Git.delete_branch(repo_path, branch_name)

            case restore_branch(repo_path, current) do
              :ok -> {:ok, commit_sha}
              {:error, reason} -> {:error, {:switch_back_failed, reason}}
            end

          {:error, {:conflict, details}} ->
            # A conflicted index blocks a plain `git checkout`; force the restore.
            case force_restore_branch(repo_path, current) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.warning("Failed to restore branch #{current}: #{inspect(reason)}")
            end

            {:conflict, details}

          {:error, {code, output}} ->
            case restore_branch(repo_path, current) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.warning("Failed to restore branch #{current}: #{inspect(reason)}")
            end

            {:error, {code, output}}
        end

      other ->
        other
    end
  end

  # Tries a plain checkout back to the original branch, falling back to a
  # forced checkout if the index is in a conflicted state.
  defp restore_branch(repo_path, branch) do
    case Git.checkout(repo_path, branch) do
      {:ok, _} -> :ok
      _ -> force_restore_branch(repo_path, branch)
    end
  end

  defp force_restore_branch(repo_path, branch) do
    case Git.run(["checkout", "--force", branch], repo_path) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp current_branch_or_first_local(repo_path) do
    case Git.current_branch(repo_path) do
      {:ok, "HEAD"} -> first_local_branch(repo_path)
      {:ok, name} -> {:ok, name}
      _ -> first_local_branch(repo_path)
    end
  end

  defp first_local_branch(repo_path) do
    case Git.list_branches(repo_path) do
      {:ok, [first | _]} -> {:ok, first}
      _ -> :none
    end
  end

  # Runs the in-memory dry-run merge via `git merge-tree --write-tree`. With
  # `--name-only --no-messages`, a clean merge prints only the resulting tree
  # OID, and a conflict prints the conflicted tree's OID followed by one
  # conflicted file path per line. Nothing in the repository is touched.
  defp check_merge_with_merge_tree(repo_path, branch_sha, target_sha) do
    case Git.run(
           [
             "merge-tree",
             "--write-tree",
             "--name-only",
             "--no-messages",
             branch_sha,
             target_sha
           ],
           repo_path
         ) do
      {:ok, _tree_oid} ->
        {:ok, :clean}

      {:error, {:conflict, output}} ->
        case conflicted_file_paths(output) do
          [] -> {:error, {:merge_failed, output}}
          files -> {:ok, {:conflict, files}}
        end

      other ->
        other
    end
  end

  # Extracts the conflicted file paths from `merge-tree --write-tree` conflict
  # output. The leading tree OID line(s) are dropped by shape, not by position
  # — git exit 1 can also carry non-conflict errors (e.g. a missing ref), whose
  # output contains no OID/file lines and correctly yields `[]`.
  @merge_tree_oid_re ~r/^[0-9a-f]{40}$/
  defp conflicted_file_paths(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or Regex.match?(@merge_tree_oid_re, &1)))
  end

  @doc """
  Rejects the changes by deleting the branch.
  Returns :ok or {:error, reason}.
  """
  def reject_branch(repo_path, branch_name) do
    case Git.delete_branch(repo_path, branch_name) do
      {:ok, _} -> :ok
      {:error, {code, output}} -> {:error, {code, output}}
    end
  end

  @doc """
  Creates a GitHub PR manually (delegates to PullRequest.try_create).
  Returns {pr_url, pr_title} or {nil, nil}.
  """
  def create_github_pr(repo_path, branch_name, objective, result) do
    EvoGit.Runtime.PullRequest.try_create(repo_path, branch_name, objective, result)
  end

  @doc """
  Checks if a branch exists in the repository.
  """
  def branch_exists?(repo_path, branch_name) do
    Git.branch_exists?(repo_path, branch_name)
  end

  @doc """
  Detects the syntax-highlighting language name for a file (consumed by the
  dashboard's frontend highlighter).
  """
  def language_for_file(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".js" -> "javascript"
      ".mjs" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "tsx"
      ".jsx" -> "jsx"
      ".py" -> "python"
      ".rs" -> "rust"
      ".go" -> "go"
      ".rb" -> "ruby"
      ".java" -> "java"
      ".html" -> "html"
      ".css" -> "css"
      ".scss" -> "scss"
      ".json" -> "json"
      ".md" -> "markdown"
      ".toml" -> "toml"
      ".yaml" -> "yaml"
      ".yml" -> "yaml"
      ".sh" -> "bash"
      ".bash" -> "bash"
      ".sql" -> "sql"
      ".c" -> "c"
      ".cpp" -> "cpp"
      ".h" -> "c"
      ".hpp" -> "cpp"
      ".cs" -> "c_sharp"
      ".swift" -> "swift"
      ".kt" -> "kotlin"
      ".lua" -> "lua"
      ".php" -> "php"
      ".r" -> "r"
      ".zig" -> "zig"
      ".dart" -> "dart"
      ".lock" -> "json"
      ".xml" -> "xml"
      ".heex" -> "html"
      ".leex" -> "html"
      ".eex" -> "html"
      _ -> "text"
    end
  end

  # --- Private helpers ---

  defp resolve_merge_base(repo_path, commit_sha) do
    case Git.merge_base(repo_path, "HEAD", commit_sha) do
      {:ok, base_sha} -> {:ok, base_sha}
      _ -> Git.rev_parse(repo_path, "HEAD")
    end
  end

  # Runs `git log` with the given args and parses the shared commit format.
  # Git errors are normalized to an empty list.
  defp do_list_commits(repo_path, git_log_args) do
    case Git.log(repo_path, git_log_args) do
      {:ok, output} ->
        commits =
          output
          |> String.trim()
          |> String.split(@commit_separator)
          |> Enum.map(&parse_commit_entry/1)
          |> Enum.reject(&is_nil/1)

        {:ok, commits}

      {:error, {_, _}} ->
        {:ok, []}
    end
  end

  defp parse_commit_entry(""), do: nil

  defp parse_commit_entry(entry) do
    case String.split(String.trim(entry), "\n", parts: 6) do
      [sha, short_sha, message, author_name, author_email, date] ->
        %CommitInfo{
          sha: sha,
          short_sha: short_sha,
          message: message,
          author_name: author_name,
          author_email: author_email,
          date: parse_iso_date(date)
        }

      _ ->
        nil
    end
  end

  defp parse_diff_into_files(diff) when is_binary(diff) do
    diff
    |> String.split(~r/^diff --git /m, trim: true)
    |> Enum.map(&parse_file_section/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_diff_into_files(_), do: []

  defp parse_diff_stat_into_files(diff_stat) when is_binary(diff_stat) do
    diff_stat
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_numstat_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_diff_stat_into_files(_), do: []

  defp parse_numstat_line(line) do
    # Numstat format: "additions\tdeletions\tpath"
    # Binary files show "-" for additions and deletions.
    case Regex.run(~r/^(\d+|-)\t(\d+|-)\t(.+)$/, line) do
      [_, add_str, del_str, path] ->
        additions = parse_numstat_count(add_str)
        deletions = parse_numstat_count(del_str)
        trimmed_path = String.trim(path)

        status =
          cond do
            additions == 0 and deletions > 0 -> "deleted"
            deletions == 0 -> "added"
            true -> "modified"
          end

        %FileInfo{
          path: trimmed_path,
          status: status,
          additions: additions,
          deletions: deletions,
          diff: nil,
          language: language_for_file(trimmed_path)
        }

      nil ->
        nil
    end
  end

  defp parse_numstat_count("-"), do: 0
  defp parse_numstat_count(str), do: String.to_integer(str)

  @doc false
  def parse_shortstat(shortstat) when is_binary(shortstat) do
    shortstat = String.trim(shortstat)

    insertions =
      case Regex.run(~r/(\d+)\s+insertions?\(\+\)/, shortstat) do
        [_, n] -> String.to_integer(n)
        nil -> 0
      end

    deletions =
      case Regex.run(~r/(\d+)\s+deletions?\(-\)/, shortstat) do
        [_, n] -> String.to_integer(n)
        nil -> 0
      end

    {insertions, deletions}
  end

  # Computes total additions/deletions from `git diff --shortstat` when git
  # reports them (single authoritative line), falling back to per-file summing.
  defp totals_via_shortstat(repo_path, base_sha, commit_sha, files) do
    case Git.diff_shortstat(repo_path, base_sha, commit_sha) do
      {:ok, shortstat} -> parse_shortstat(shortstat)
      _ -> count_changes(files)
    end
  end

  # Shared metadata map shape (`:diff` nil) returned by the metadata loaders.
  defp build_metadata_map(
         base_sha,
         commit_sha,
         diff_stat,
         files,
         {total_additions, total_deletions}
       ) do
    %{
      commit_sha: commit_sha,
      base_sha: base_sha,
      diff_stat: diff_stat,
      diff: nil,
      files: files,
      changed_files_count: length(files),
      total_additions: total_additions,
      total_deletions: total_deletions
    }
  end

  defp parse_file_section(section) do
    lines = String.split(section, "\n")

    # Extract file path from "--- a/path" or "+++ b/path" lines
    path = extract_file_path(lines)

    if path do
      # Count additions and deletions
      {additions, deletions} =
        Enum.reduce(lines, {0, 0}, fn line, {add, del} ->
          cond do
            String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
              {add + 1, del}

            String.starts_with?(line, "-") and not String.starts_with?(line, "---") ->
              {add, del + 1}

            true ->
              {add, del}
          end
        end)

      # Determine status
      status =
        cond do
          Enum.any?(lines, &String.starts_with?(&1, "new file")) -> "added"
          Enum.any?(lines, &String.starts_with?(&1, "deleted file")) -> "deleted"
          true -> "modified"
        end

      %FileInfo{
        path: path,
        status: status,
        additions: additions,
        deletions: deletions,
        diff: "diff --git " <> section,
        language: language_for_file(path)
      }
    end
  end

  defp extract_file_path(lines) do
    # Try +++ b/path first (works for all cases including new files)
    case Enum.find(lines, &String.starts_with?(&1, "+++ b/")) do
      nil ->
        # Fallback: try --- a/path (works for deleted files)
        case Enum.find(lines, &String.starts_with?(&1, "--- a/")) do
          nil -> nil
          line -> String.replace_prefix(line, "--- a/", "")
        end

      line ->
        String.replace_prefix(line, "+++ b/", "")
    end
  end

  defp parse_iso_date(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> str
    end
  end

  defp parse_iso_date(other), do: other

  defp count_changes(files) do
    Enum.reduce(files, {0, 0}, fn file, {add, del} ->
      {add + file.additions, del + file.deletions}
    end)
  end
end
