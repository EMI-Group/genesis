defmodule EvoGit.Agent.Tools.Glob do
  @moduledoc """
  Tool for file pattern matching using glob patterns.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "glob",
      description:
        "Fast file pattern matching tool that works with any codebase size. " <>
          "Supports glob patterns like '**/*.js' or 'src/**/*.ts'. " <>
          "Returns matching file paths sorted by modification time (newest first). " <>
          "Usage: " <>
          "- Use this tool when you need to find files by name patterns. " <>
          "- Results are limited to 100 files by default (use max_files to adjust). " <>
          "- Example patterns: '**/*.ex', 'lib/**/*.ex', 'test/**/test_*.ex'",
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
            "description" => "Directory to search in, relative to repository root (default: git repo path, e.g., './', './src')"
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
           if(is_binary(path_value), do: Path.expand(path_value, repo_path), else: repo_path) do
      do_glob(pattern, search_path, max_files)
    end
  end

  defp validate_max_files(value) when is_integer(value) and value >= 1, do: {:ok, value}

  defp validate_max_files(value),
    do: {:error, "Argument 'max_files' must be a positive integer, got: #{inspect(value)}"}

  defp do_glob(pattern, search_path, max_files) do
    full_pattern = Path.join(search_path, pattern)

    case safe_wildcard(full_pattern) do
      {:ok, []} ->
        "No files found matching pattern: #{pattern}"

      {:ok, paths} ->
        {sorted_paths, total_count} =
          paths
          |> Enum.flat_map(fn path ->
            case File.stat(path) do
              {:ok, stat} -> [{path, stat.mtime}]
              {:error, _} -> []
            end
          end)
          |> Enum.sort_by(fn {_path, mtime} -> mtime end, :desc)
          |> then(fn sorted ->
            total = length(sorted)

            truncated =
              if total > max_files do
                Enum.take(sorted, max_files)
              else
                sorted
              end

            {truncated, total}
          end)

        relative_paths =
          Enum.map(sorted_paths, fn {path, _mtime} ->
            Path.relative_to(path, search_path)
          end)

        truncated = total_count > max_files

        format_result(relative_paths, total_count, truncated)

      {:error, reason} ->
        format_pattern_error(pattern, reason)
    end
  end

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

  defp format_pattern_error(pattern, {:badpattern, reason}) do
    "Error: invalid glob pattern '#{pattern}' (malformed: #{inspect(reason)}). " <>
      "Please check the pattern syntax — e.g. ensure braces '{...}' and brackets '[...]' are balanced."
  end

  defp format_pattern_error(pattern, reason) do
    "Error: invalid glob pattern '#{pattern}' (#{inspect(reason)}). " <>
      "Please check the pattern syntax — e.g. ensure braces '{...}' and brackets '[...]' are balanced."
  end

  defp format_result(paths, total_count, truncated) do
    count = length(paths)

    truncated_str = if truncated, do: " (truncated)", else: ""

    header = "Found: #{count} of #{total_count} files#{truncated_str}\n"

    paths_str = Enum.join(paths, "\n")

    header <> "\n" <> paths_str
  end
end
