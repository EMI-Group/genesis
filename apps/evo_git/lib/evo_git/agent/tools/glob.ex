defmodule EvoGit.Agent.Tools.Glob do
  @moduledoc """
  Tool for file pattern matching using glob patterns.

  Output conventions (aligned with the `rg` tool, so both read as one family):

    * a plain path listing, one per line, newest first — no header;
    * a TRAILING bracketed footer ONLY when the list is capped:
      `[showing <max_files> of <total> files; raise max_files or narrow the pattern]`;
    * an empty result is exactly `No files found.` (the pattern is echoed in a
      trailing hint);
    * a malformed pattern is a `Error: `-prefixed one-sentence failure rendered
      through `EvoGit.Agent.Tools.Failure`.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "glob",
      description:
        "Use the glob tool to find files by name pattern — it works with any codebase size. " <>
          "Supports glob patterns like '**/*.js', 'src/**/*.ts', '**/*.{ex,exs}'. " <>
          "Returns matching file paths, one per line, sorted by modification time (newest first); " <>
          "100 files by default (raise max_files for more), and when the listing is capped a " <>
          "trailing footer reports the total. " <>
          "path is relative to the repository root and defaults to the git repo path.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" =>
              "The glob pattern to match against (e.g., 'lib/**/*.ex', '**/*.{ex,exs}')"
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Directory to search in, relative to repository root (default: git repo path, e.g., './', './src')"
          },
          "max_files" => %{
            "type" => "integer",
            "description" => "Maximum number of files to return (default: 100)",
            "default" => 100
          }
        },
        "required" => ["pattern"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the glob tool.
  """
  def execute(args, repo_path, _repo_root) do
    with {:ok, pattern} <- Shared.fetch_string_arg(args, "pattern"),
         {:ok, max_files} <- validate_max_files(Map.get(args, "max_files", 100)),
         path_value = Map.get(args, "path"),
         search_path =
           if(is_binary(path_value),
             do: EvoGit.Platform.safe_expand(path_value, repo_path),
             else: repo_path
           ) do
      do_glob(pattern, search_path, max_files)
    end
  end

  defp validate_max_files(value) when is_integer(value) and value >= 1, do: {:ok, value}

  defp validate_max_files(value),
    do: {:error, "Argument 'max_files' must be a positive integer, got: #{inspect(value)}"}

  defp do_glob(pattern, search_path, max_files) do
    full_pattern = Path.join(search_path, pattern)

    case safe_wildcard(full_pattern) do
      {:ok, paths} ->
        case sort_by_mtime_desc(paths) do
          # Every match vanished between globbing and stat-ing: an empty listing,
          # not an error.
          [] -> no_files(pattern)
          sorted -> render_paths(sorted, search_path, max_files)
        end

      {:error, reason} ->
        pattern_error(pattern, reason)
    end
  end

  defp sort_by_mtime_desc(paths) do
    paths
    |> Enum.flat_map(fn path ->
      case File.stat(path) do
        {:ok, stat} -> [{path, stat.mtime}]
        {:error, _} -> []
      end
    end)
    |> Enum.sort_by(fn {_path, mtime} -> mtime end, :desc)
  end

  # One path per line, newest first, no header. The footer reports the totals
  # ONLY when files were dropped, so a complete listing is returned byte-identical.
  defp render_paths(sorted, search_path, max_files) do
    total = length(sorted)

    listing =
      sorted
      |> Enum.take(max_files)
      |> Enum.map(fn {path, _mtime} -> Path.relative_to(path, search_path) end)
      |> Enum.join("\n")

    if total > max_files do
      listing <> "\n" <> truncation_footer(max_files, total)
    else
      listing
    end
  end

  defp truncation_footer(max_files, total) do
    "[showing #{max_files} of #{total} files; raise max_files or narrow the pattern]"
  end

  # Fixed first line (the sentence models are trained on), then the pattern as a
  # trailing hint so an unexpected empty result stays diagnosable.
  defp no_files(pattern), do: "No files found." <> Failure.notice("[pattern: #{pattern}]")

  defp pattern_error(pattern, reason) do
    Failure.error(
      "invalid glob pattern '#{pattern}' (malformed: #{inspect(unwrap_badpattern(reason))}). " <>
        "Please check the pattern syntax — e.g. ensure braces '{...}' and brackets '[...]' are balanced."
    )
  end

  defp unwrap_badpattern({:badpattern, reason}), do: reason
  defp unwrap_badpattern(reason), do: reason

  # KEEP (try/catch, not rescue): Path.wildcard has no non-crashing variant.
  # We genuinely expect this error — the glob pattern is user input (from the
  # LLM tool call) and malformed patterns (e.g. unmatched `{` or `[`) crash as
  # `{:badpattern, :missing_delimiter}`. Different Erlang/Elixir versions raise
  # (:error), throw, or exit, so we catch all three. Crashing the agent on a
  # bad pattern would waste a retry; returning a helpful error message is the
  # right behavior. case/with cannot be used because Path.wildcard crashes
  # rather than returning error tuples.
  defp safe_wildcard(full_pattern) do
    try do
      {:ok, Path.wildcard(full_pattern, match_dot: true)}
    catch
      :error, reason -> {:error, reason}
      :throw, reason -> {:error, reason}
      :exit, reason -> {:error, reason}
    end
  end
end
