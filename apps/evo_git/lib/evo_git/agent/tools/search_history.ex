defmodule EvoGit.Agent.Tools.SearchHistory do
  @moduledoc """
  Tool for searching patterns in git commit history.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared

  @default_commit_id "HEAD"
  @default_search_notes true
  @default_max_count 100

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "search_history",
      description:
        "Use the search_history tool to search the git commit history (messages and notes). " <>
          "Matching commits come back with their short id and subject, newest first; raise max_count or tighten the pattern to narrow the search.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "The regex pattern to match against commit messages (and notes)"
          },
          "commit_id" => %{
            "type" => "string",
            "description" =>
              "The commit, branch, or ref to start the log from. Default: \"#{@default_commit_id}\"; an empty string also means \"#{@default_commit_id}\".",
            "default" => @default_commit_id
          },
          "search_notes" => %{
            "type" => "boolean",
            "description" =>
              "Whether to search git notes as well. Default: #{@default_search_notes}.",
            "default" => @default_search_notes
          },
          "max_count" => %{
            "type" => "integer",
            "description" => "Maximum number of commits to walk. Default: #{@default_max_count}.",
            "default" => @default_max_count
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" => Shared.tool_output_limit_description(),
            "default" => 16_384
          }
        },
        "required" => ["pattern"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the search_history tool.
  """
  def execute(args, repo_path, repo_root) do
    case Shared.fetch_string_arg(args, "pattern") do
      {:ok, pattern} ->
        commit_id =
          Shared.get_optional_string(args, "commit_id", @default_commit_id)
          |> blank_to_default(@default_commit_id)

        search_notes = Shared.get_optional_boolean(args, "search_notes", @default_search_notes)
        max_count = Shared.get_optional_integer(args, "max_count", @default_max_count)

        do_search(pattern, commit_id, search_notes, max_count, repo_path, repo_root)

      {:error, message} ->
        Failure.error(message)
    end
  end

  # --- Private helpers ---

  defp blank_to_default("", default), do: default
  defp blank_to_default(val, _default), do: val

  defp do_search(pattern, commit_id, search_notes, max_count, repo_path, repo_root) do
    separator = "---COMMIT-SEPARATOR---"

    format =
      if search_notes do
        "--format=%H%n%B%n%N%n#{separator}"
      else
        "--format=%H%n%B%n#{separator}"
      end

    git_args =
      if search_notes do
        # --no-standard-notes disables the default refs/notes/commits ref so only
        # evogit notes (refs/notes/evogit) are included in %N.
        [
          "log",
          format,
          commit_id,
          "--max-count=#{max_count}",
          "--no-standard-notes",
          "--notes=evogit"
        ]
      else
        ["log", format, commit_id, "--max-count=#{max_count}"]
      end

    {output, exit_code} = EvoGit.sandbox_run(repo_path, "git", git_args, repo_root)

    if exit_code != 0 do
      Failure.error("search_history failed with exit code #{exit_code}.", "Output:\n#{output}")
    else
      case compile_regex(pattern) do
        {:ok, regex} ->
          # Filter out git warnings that pollute the structured output
          clean_output = filter_git_warnings(output)
          commits = parse_log_output(clean_output, separator)
          matches = filter_commits(commits, regex)
          format_results(matches, pattern)

        {:error, reason} ->
          Failure.error("compiling pattern '#{pattern}' failed: #{inspect(reason)}")
      end
    end
  end

  defp compile_regex(pattern) do
    Regex.compile(pattern)
  end

  defp parse_log_output(output, separator) do
    for part <- String.split(output, separator),
        trimmed = String.trim(part),
        trimmed != "",
        commit = parse_single_commit(trimmed),
        not is_nil(commit) do
      commit
    end
  end

  defp filter_git_warnings(output) do
    String.replace(output, "warning: notes ref refs/notes/evogit is invalid\n", "")
  end

  defp parse_single_commit(block) do
    case String.split(block, "\n", parts: 2) do
      [hash, body] ->
        %{hash: String.trim(hash), body: String.trim(body)}

      [hash] ->
        %{hash: String.trim(hash), body: ""}

      [] ->
        nil
    end
  end

  defp filter_commits(commits, regex) do
    Enum.filter(commits, fn commit ->
      Regex.match?(regex, commit.body)
    end)
  end

  defp format_results([], pattern) do
    "No commits found matching pattern '#{pattern}'."
  end

  defp format_results(matches, pattern) do
    entries =
      Enum.map(matches, fn commit ->
        short_hash = binary_part(commit.hash, 0, 7)

        subject =
          commit.body
          |> String.split("\n")
          |> List.first()
          |> String.trim()

        "Commit: #{short_hash}\n  Message: #{subject}"
      end)
      |> Enum.join("\n\n")

    "Found #{length(matches)} commit(s) matching pattern '#{pattern}':\n\n#{entries}"
  end
end
