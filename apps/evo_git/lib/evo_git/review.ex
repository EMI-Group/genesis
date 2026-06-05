defmodule EvoGit.Review do
  @moduledoc """
  Review context module for managing code review operations.
  
  Provides functions for loading diff data, listing commits, merging/rejecting branches,
  and creating GitHub PRs manually from the review page.
  """
  
  alias EvoGit.Adapters.Git
  
  defmodule FileInfo do
    @moduledoc "Structured info about a changed file"
    defstruct [:path, :status, :additions, :deletions, :diff, :language]
  end
  
  defmodule CommitInfo do
    @moduledoc "Structured info about a commit"
    defstruct [:sha, :short_sha, :message, :author_name, :author_email, :date]
  end
  
  @doc """
  Lists commits between base and branch tip, returning a list of CommitInfo structs.
  Returns {:ok, commits} or {:error, reason}.
  """
  def list_commits(repo_path, branch_name) do
    with {:ok, commit_sha} <- Git.rev_parse(repo_path, branch_name),
         {:ok, base_sha} <- resolve_merge_base(repo_path, commit_sha) do
      separator = "|||COMMIT_SEP|||"
      format = "%H%n%h%n%s%n%an%n%ae%n%aI%n#{separator}"
      case Git.log(repo_path, ["--format=#{format}", "#{base_sha}..#{commit_sha}"]) do
        {:ok, output} ->
          commits =
            output
            |> String.trim()
            |> String.split(separator)
            |> Enum.map(&parse_commit_entry/1)
            |> Enum.reject(&is_nil/1)
          {:ok, commits}
        
        {:error, _, _} ->
          {:ok, []}
      end
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
      
      {:ok, %{
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
  """
  def load_review_metadata(repo_path, branch_name) do
    with {:ok, commit_sha} <- Git.rev_parse(repo_path, branch_name),
         {:ok, base_sha} <- resolve_merge_base(repo_path, commit_sha) do

      {:ok, diff_stat} = Git.diff_stat(repo_path, base_sha, commit_sha)

      files = parse_diff_stat_into_files(diff_stat)
      {total_additions, total_deletions} = count_changes(files)

      {:ok, %{
        commit_sha: commit_sha,
        base_sha: base_sha,
        diff_stat: diff_stat,
        diff: nil,
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
  Loads the diff for a single file between two commits.
  Delegates to `Git.file_diff/5` with the given base and commit SHAs.

  Returns `{:ok, diff_string}` or `{:error, code, output}`.
  """
  def load_file_diff(repo_path, base_sha, commit_sha, file_path) do
    Git.file_diff(repo_path, file_path, base_sha, commit_sha)
  end
  
  @doc """
  Merges the branch into the current HEAD and deletes the branch.
  Returns {:ok, merged_sha} or {:conflict, details} or {:error, reason}.
  """
  def merge_branch(repo_path, branch_name) do
    {:ok, commit_sha} = Git.rev_parse(repo_path, branch_name)
    
    case Git.merge(repo_path, commit_sha) do
      {:ok, _output} ->
        Git.delete_branch(repo_path, branch_name)
        {:ok, commit_sha}
      
      {:conflict, details} ->
        {:conflict, details}
      
      {:error, code, output} ->
        {:error, {code, output}}
    end
  end
  
  @doc """
  Rejects the changes by deleting the branch.
  Returns :ok or {:error, reason}.
  """
  def reject_branch(repo_path, branch_name) do
    case Git.delete_branch(repo_path, branch_name) do
      {:ok, _} -> :ok
      {:error, code, output} -> {:error, {code, output}}
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
  Detects the Lumis language name from a file extension.
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
    |> String.split("\n")
    |> Enum.map(&parse_diff_stat_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_diff_stat_into_files(_), do: []

  defp parse_diff_stat_line(line) do
    # Match lines like: " path/to/file.ex | 10 ++++----"
    # Does NOT match summary lines like: " 2 files changed, 8 insertions(+), 7 deletions(-)"
    case Regex.run(~r/^\s*(.+?)\s+\|\s+(\d+)\s+([+\-]*?)\s*$/, line) do
      [_, path, _total_changes, change_symbols] ->
        additions =
          change_symbols
          |> String.graphemes()
          |> Enum.count(&(&1 == "+"))

        deletions =
          change_symbols
          |> String.graphemes()
          |> Enum.count(&(&1 == "-"))

        status = cond do
          additions == 0 and deletions > 0 -> "deleted"
          deletions == 0 -> "added"
          true -> "modified"
        end

        %FileInfo{
          path: String.trim(path),
          status: status,
          additions: additions,
          deletions: deletions,
          diff: nil,
          language: language_for_file(String.trim(path))
        }

      nil ->
        nil
    end
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
            String.starts_with?(line, "+") and not String.starts_with?(line, "+++") -> {add + 1, del}
            String.starts_with?(line, "-") and not String.starts_with?(line, "---") -> {add, del + 1}
            true -> {add, del}
          end
        end)
      
      # Determine status
      status = cond do
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
