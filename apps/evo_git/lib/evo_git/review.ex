defmodule EvoGit.Review do
  @moduledoc """
  Review context module for managing code review operations.
  
  Provides functions for loading diff data, merging/rejecting branches,
  and creating GitHub PRs manually from the review page.
  """
  
  alias EvoGit.Adapters.Git
  
  defmodule FileInfo do
    @moduledoc "Structured info about a changed file"
    defstruct [:path, :status, :additions, :deletions, :diff, :language]
  end
  
  @doc """
  Loads all review data for a given branch in a repository.
  Returns a map with :commit_sha, :base_sha, :diff_stat, :diff, :files, :changed_files_count, :total_additions, :total_deletions.
  The base is the current HEAD, and we compare HEAD vs the branch tip.
  """
  def load_review_data(repo_path, branch_name) do
    with {:ok, commit_sha} <- Git.rev_parse(repo_path, branch_name),
         {:ok, base_sha} <- Git.rev_parse(repo_path, "HEAD") do
      
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
      ".ex" -> "elixir"
      ".lock" -> "json"
      ".xml" -> "xml"
      ".heex" -> "html"
      ".leex" -> "html"
      ".eex" -> "html"
      _ -> "text"
    end
  end
  
  # --- Private helpers ---
  
  defp parse_diff_into_files(diff) when is_binary(diff) do
    diff
    |> String.split(~r/^diff --git /m, trim: true)
    |> Enum.map(&parse_file_section/1)
    |> Enum.reject(&is_nil/1)
  end
  
  defp parse_diff_into_files(_), do: []
  
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
  
  defp count_changes(files) do
    Enum.reduce(files, {0, 0}, fn file, {add, del} ->
      {add + file.additions, del + file.deletions}
    end)
  end
end
