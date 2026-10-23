defmodule EvoGit.Agent.Tools.FileRead do
  @moduledoc """
  The `read` tool: reads a line range of a single text file.

  Output shape:

      File: <path>
      <line number>\t<line>
      ...

      (Showing lines X-Y of N. Use offset=Z to continue.)

  The trailing block becomes `(End of file - total N lines)` when the read
  reached the end of the file. A line longer than 2000 characters is clipped
  with a visible marker so one minified line cannot dominate the context.

  The schema name is the model-facing `"read"`; the internal dispatch key stays
  `"read_file"` (bridged by `EvoGit.Agent.ToolNames`).
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared

  # ONE source of truth for the default-read size gate AND the size the schema
  # description advertises — the two can never drift apart again.
  @max_file_size 256 * 1024

  # Per-line clip. `String.slice/3` counts GRAPHEMES, so the clip can never
  # split a UTF-8 codepoint.
  @max_line_chars 2000
  @line_clip_marker "… (line truncated to #{@max_line_chars} chars)"

  @default_limit 2000

  # At or above this size the file is processed by streaming (line by line)
  # instead of being read into memory in one piece.
  @streaming_threshold 5 * 1024 * 1024

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "read",
      description:
        "Use the read tool — not shell commands like cat — to inspect text files. " <>
          "Read from `offset` (1-indexed, default 1) up to `limit` lines (default 2000). " <>
          "Lines longer than #{@max_line_chars} characters are clipped with a visible marker. " <>
          "A partial read ends with a footer naming the next `offset` to continue from. " <>
          "A default read is capped at #{div(@max_file_size, 1024)} KB; pass `offset`/`limit` to read a larger file.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" =>
              "Path to the file to read, relative to the repo root (e.g. './src/main.ex')"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "First line to read (1-indexed, default: 1)",
            "default" => 1
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of lines to read (default: 2000)",
            "default" => @default_limit
          },
          "line_numbers" => %{
            "type" => "boolean",
            "description" => "Prefix every line with its line number (default: true)",
            "default" => true
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" => Shared.tool_output_limit_description(),
            "default" => 16_384
          }
        },
        "required" => ["file_path"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the `read` tool.
  """
  def execute(args, repo_path, _repo_root) do
    with {:ok, file_path} <- Shared.fetch_string_arg(args, "file_path"),
         {:ok, offset} <- validate_offset(Map.get(args, "offset", 1)),
         {:ok, limit} <- validate_limit(Map.get(args, "limit", @default_limit)),
         {:ok, line_numbers} <- validate_line_numbers(Map.get(args, "line_numbers", true)) do
      do_read(
        Shared.expand_path(file_path, repo_path),
        file_path,
        offset,
        limit,
        line_numbers,
        Map.has_key?(args, "offset") or Map.has_key?(args, "limit")
      )
    else
      {:error, message} -> Failure.error(message)
    end
  end

  defp do_read(file_path, display_path, offset, limit, line_numbers, custom_range?) do
    with {:ok, stat} <- File.stat(file_path),
         :ok <- validate_file_size(stat, custom_range?),
         {:ok, result} <- read_file_with_lines(file_path, stat, offset, limit) do
      format_result(result, display_path, line_numbers)
    else
      {:error, :too_large} ->
        Failure.error(
          "File #{display_path} is too large (>#{div(@max_file_size, 1024)} KB). " <>
            "Use offset and limit parameters to read specific ranges."
        )

      {:error, reason} ->
        Failure.error("reading file #{display_path} failed: #{:file.format_error(reason)}")
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

  # Validates file size - only enforce the cap for default (no offset/limit)
  # reads; an explicit range may address any part of an arbitrarily large file.
  defp validate_file_size(stat, custom_range?) do
    if custom_range? or stat.size <= @max_file_size do
      :ok
    else
      {:error, :too_large}
    end
  end

  # Reads file with line number support, handling large files via streaming
  defp read_file_with_lines(file_path, stat, offset, limit) do
    if stat.size < @streaming_threshold do
      read_file_fast_path(file_path, offset, limit)
    else
      read_file_streaming(file_path, offset, limit)
    end
  end

  # Fast path for small files - read entirely into memory
  defp read_file_fast_path(file_path, offset, limit) do
    with {:ok, raw_content} <- File.read(file_path) do
      lines = raw_content |> strip_bom() |> split_lines()

      total_lines = length(lines)

      start_index = max(0, offset - 1)
      start_index = min(start_index, total_lines)

      amount =
        if limit, do: min(limit, total_lines - start_index), else: total_lines - start_index

      amount = max(0, amount)

      selected_lines = Enum.slice(lines, start_index, amount)

      {:ok,
       %{
         lines: selected_lines,
         start_line: offset,
         total_lines: total_lines,
         num_lines: length(selected_lines)
       }}
    end
  end

  # Streaming path for large files - one LINE at a time, so an arbitrarily large
  # file is never held in memory as a whole.
  defp read_file_streaming(file_path, offset, limit) do
    end_index = if limit, do: offset + limit, else: :infinity

    {selected_lines, last_line_number, ends_with_newline?} =
      file_path
      |> File.stream!()
      |> Enum.reduce({[], 0, false}, fn chunk, {acc, idx, _ends_with_newline?} ->
        current_line = idx + 1

        line =
          chunk
          |> strip_line_ending()
          |> maybe_strip_bom(current_line)

        selected =
          if in_range?(current_line, offset, end_index) do
            [line | acc]
          else
            acc
          end

        {selected, current_line, String.ends_with?(chunk, "\n")}
      end)

    # `split_lines/1` (the fast path) yields a trailing empty element for content
    # ending with a newline; mirror that so BOTH paths report the same line count
    # and the same `offset` arithmetic.
    total_lines = if ends_with_newline?, do: last_line_number + 1, else: last_line_number
    lines = Enum.reverse(selected_lines)

    lines =
      if ends_with_newline? and in_range?(total_lines, offset, end_index) do
        lines ++ [""]
      else
        lines
      end

    {:ok,
     %{
       lines: lines,
       start_line: offset,
       total_lines: total_lines,
       num_lines: length(lines)
     }}
  end

  defp in_range?(line_number, offset, end_index) do
    line_number >= offset and line_number < end_index
  end

  # `File.stream!/1` keeps the line delimiter; a trailing CR belongs to a CRLF
  # ending and is never part of the content.
  defp strip_line_ending(chunk) do
    chunk
    |> String.replace_suffix("\n", "")
    |> String.replace_suffix("\r", "")
  end

  # The BOM can only ever sit at the very start of the file.
  defp maybe_strip_bom(line, 1), do: strip_bom(line)
  defp maybe_strip_bom(line, _line_number), do: line

  # `File: <path>` header, the clipped line block, then the trailing block
  # (footer or empty-file note) separated from the content by a blank line.
  defp format_result(result, display_path, line_numbers) do
    %{lines: lines, start_line: start_line, total_lines: total_lines} = result

    cond do
      total_lines == 0 ->
        "File: #{display_path}" <> Failure.notice("File exists but has empty contents.")

      start_line > total_lines ->
        Failure.error(
          "offset #{start_line} is beyond the end of #{display_path}, " <>
            "which has #{line_count_label(total_lines)}."
        )

      true ->
        body =
          lines
          |> Enum.map(&clip_line/1)
          |> format_lines(start_line, line_numbers)

        footer = read_footer(start_line, length(lines), total_lines)

        "File: #{display_path}\n" <> body <> Failure.notice(footer)
    end
  end

  # The trained read footer: either the continuation hint or the end-of-file
  # marker, never both. Shared by the numbered and non-numbered branches.
  defp read_footer(start_line, shown, total_lines) do
    last_line = start_line + shown - 1

    if last_line < total_lines do
      "(Showing lines #{start_line}-#{last_line} of #{total_lines}. " <>
        "Use offset=#{last_line + 1} to continue.)"
    else
      "(End of file - total #{total_lines} lines)"
    end
  end

  defp format_lines(lines, start_line, true) do
    lines
    |> Enum.with_index(start_line)
    |> Enum.map_join("\n", fn {line, num} -> "#{num}\t#{line}" end)
  end

  defp format_lines(lines, _start_line, false), do: Enum.map_join(lines, "\n", & &1)

  # A single over-long line would otherwise flood the context; the marker makes
  # the clip visible so the model knows the text it sees is incomplete.
  defp clip_line(line) do
    if String.length(line) > @max_line_chars do
      String.slice(line, 0, @max_line_chars) <> @line_clip_marker
    else
      line
    end
  end

  defp line_count_label(1), do: "1 line"
  defp line_count_label(count), do: "#{count} lines"

  # An EMPTY file has ZERO lines — not one empty line — so the caller renders the
  # empty-file note instead of a blank numbered line.
  defp split_lines(""), do: []

  defp split_lines(content) do
    for line <- String.split(content, "\n"), do: String.replace_suffix(line, "\r", "")
  end

  # Strips UTF-8 BOM if present at start of content
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content
end
