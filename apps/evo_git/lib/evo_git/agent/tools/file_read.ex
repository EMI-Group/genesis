defmodule EvoGit.Agent.Tools.FileRead do
  @moduledoc """
  Tool for reading file contents.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "read_file",
      description:
        "Reads the content of a single file. " <>
          "Returns formatted output with line numbers (cat -n style). " <>
          "Usage: " <>
          "- By default reads up to 2000 lines, with a 128 KB file size limit. " <>
          "- For large files (>128 KB), you MUST use offset and limit parameters. " <>
          "- Automatically streams files >= 5 MB for memory efficiency.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "The path to the file to read (relative to git repo path)"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "Line number to start reading from (1-indexed, default: 1)",
            "default" => 1
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of lines to read (default: 2000)",
            "default" => 2000
          },
          "line_numbers" => %{
            "type" => "boolean",
            "description" => "Whether to include line numbers in the output (default: true)",
            "default" => true
          }
        },
        "required" => ["file_path"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the read_file tool.
  """
  def execute(args, repo_path, _repo_root) do
    with {:ok, file_path} <- Shared.fetch_string_arg(args, "file_path"),
         expanded_path = Shared.expand_path(file_path, repo_path),
         {:ok, offset} <- validate_offset(Map.get(args, "offset", 1)),
         {:ok, limit} <- validate_limit(Map.get(args, "limit", 2000)),
         {:ok, line_numbers} <- validate_line_numbers(Map.get(args, "line_numbers", true)) do
      do_read(
        expanded_path,
        file_path,
        offset,
        limit,
        line_numbers,
        Map.has_key?(args, "offset") or Map.has_key?(args, "limit")
      )
    end
  end

  defp do_read(file_path, display_path, offset, limit, line_numbers, custom_range?) do
    with {:ok, stat} <- File.stat(file_path),
         :ok <- validate_file_size(stat, custom_range?),
         {:ok, result} <- read_file_with_lines(file_path, stat, offset, limit) do
      format_result(result, display_path, line_numbers)
    else
      {:error, :too_large} ->
        "Error: File #{display_path} is too large (>256 KB). Use offset and limit parameters to read specific ranges."

      {:error, reason} ->
        "Error reading file #{display_path}: #{:file.format_error(reason)}"
    end
  end

  defp validate_offset(value) when is_integer(value) and value >= 1, do: {:ok, value}

  defp validate_offset(value),
    do: {:error, "Argument 'offset' must be a positive integer, got: #{inspect(value)}"}

  defp validate_limit(value) when is_integer(value) and value >= 1, do: {:ok, value}

  defp validate_limit(value),
    do: {:error, "Argument 'limit' must be a positive integer, got: #{inspect(value)}"}

  defp validate_line_numbers(value) when is_boolean(value), do: {:ok, value}

  defp validate_line_numbers(value),
    do: {:error, "Argument 'line_numbers' must be a boolean, got: #{inspect(value)}"}

  # Validates file size - only enforce limit for default (no offset/limit) reads
  defp validate_file_size(stat, custom_range?) do
    max_size = 256 * 1024

    if custom_range? or stat.size <= max_size do
      :ok
    else
      {:error, :too_large}
    end
  end

  # Reads file with line number support, handling large files via streaming
  defp read_file_with_lines(file_path, stat, offset, limit) do
    file_size = stat.size

    if file_size < 5 * 1024 * 1024 do
      read_file_fast_path(file_path, offset, limit)
    else
      read_file_streaming(file_path, offset, limit)
    end
  end

  # Fast path for small files - read entirely into memory
  defp read_file_fast_path(file_path, offset, limit) do
    with {:ok, raw_content} <- File.read(file_path) do
      content = strip_bom(raw_content)

      lines =
        content
        |> String.split("\n")
        |> Enum.map(fn line -> String.replace_suffix(line, "\r", "") end)

      total_lines = length(lines)

      start_index = max(0, offset - 1)
      end_index = if limit, do: min(start_index + limit, total_lines), else: total_lines

      selected_lines = Enum.slice(lines, start_index, end_index - start_index)

      {:ok,
       %{
         lines: selected_lines,
         start_line: offset,
         total_lines: total_lines,
         num_lines: length(selected_lines)
       }}
    end
  end

  # Streaming path for large files - process line by line
  defp read_file_streaming(file_path, offset, limit) do
    end_index = if limit, do: offset + limit, else: :infinity

    {selected_lines, total_lines} =
      file_path
      |> File.stream!([], 512_000)
      |> Enum.map(fn line -> String.replace_suffix(line, "\r", "") end)
      |> Enum.reduce({[], 0}, fn line, {acc, idx} ->
        current_line = idx + 1

        selected =
          if current_line >= offset and current_line < end_index do
            [line | acc]
          else
            acc
          end

        {selected, current_line}
      end)

    {:ok,
     %{
       lines: Enum.reverse(selected_lines),
       start_line: offset,
       total_lines: total_lines,
       num_lines: length(selected_lines)
     }}
  end

  # Formats result with line numbers (cat -n style)
  defp format_result(result, file_path, line_numbers) do
    %{lines: lines, start_line: start_line, total_lines: total_lines, num_lines: num_lines} =
      result

    cond do
      total_lines == 0 ->
        "File: #{file_path}\nWarning: File exists but has empty contents.\n"

      true ->
        formatted_lines =
          if line_numbers do
            lines
            |> Enum.with_index(start_line)
            |> Enum.map(fn {line, num} -> "#{num}\t#{line}" end)
            |> Enum.join("\n")
          else
            Enum.join(lines, "\n")
          end

        header =
          "File: #{file_path}\nLines: #{start_line}-#{start_line + num_lines - 1} of #{total_lines}\n\n"

        header <> formatted_lines
    end
  end

  # Strips UTF-8 BOM if present at start of content
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content
end
