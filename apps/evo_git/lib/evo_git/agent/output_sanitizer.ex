defmodule EvoGit.Agent.OutputSanitizer do
  @moduledoc """
  Centralizes all tool output sanitization and truncation logic.

  Provides a pipeline for cleaning and truncating tool outputs before they are
  returned to the LLM, preventing context bloat from:
  - Invalid UTF-8 binary data
  - ANSI escape sequences (colors, cursor movement, etc.)
  - Progress bar artifacts from CLI tools
  - Excessively large outputs

  ## Pipeline

  All functions return `{result, truncation_info}` tuples where:
  - `result` is the sanitized/truncated output
  - `truncation_info` is `nil` when no truncation occurred, or a map:
      `%{reason: :invalid_utf8 | :size_exceeded, original_size: pos_integer, truncated_size: pos_integer}`

  Steps: ensure_utf8 → strip_ansi → strip_progress_bars → truncate
  """

  require Logger

  @high_output_tools MapSet.new([
    "run_bash", "run_powershell", "read_file", "rg", "curl",
    "run_git", "search_web", "search_context", "search_history"
  ])

  @ansi_regex ~r/\e\[[0-9;]*[a-zA-Z]|\e\][^\x07]*\x07|\e[()][AB012]|\e\[[0-9;]*m/
  @progress_bar_regex ~r/^[\s\r]*\[[=\->#*_ ]+\]\s*\d*%?\s*$/
  @spinner_regex ~r/^[\|\/\-\\]$/

  # --- Public API ---

  @doc """
  Full sanitization + truncation pipeline for tool outputs.

  Steps: ensure_utf8 → strip_ansi → strip_progress_bars → truncate

  Returns `{result, truncation_info}` where truncation_info is `nil` when no
  truncation occurred, or `%{reason: atom, original_size: pos_integer, truncated_size: pos_integer}`.
  """
  def sanitize_and_truncate(result, tool_name, tool_args) do
    {result, utf8_info} = ensure_utf8(result)

    result =
      result
      |> strip_ansi()
      |> strip_progress_bars()

    {result, truncate_info} = truncate(result, tool_name, tool_args)

    {result, truncate_info || utf8_info}
  end

  @doc """
  Ensure output is valid UTF-8. Repairs or truncates invalid sequences.

  - If the result is valid UTF-8, returns `{result, nil}`.
  - If invalid, attempts repair via `:unicode.characters_to_binary/3`.
  - On repair failure, appends a warning and returns `{repaired_result, truncation_info}`.
  - Non-binary results pass through as `{result, nil}`.
  """
  def ensure_utf8(result) when is_binary(result) do
    if String.valid?(result) do
      {result, nil}
    else
      original_size = byte_size(result)

      case :unicode.characters_to_binary(result, :utf8, :utf8) do
        {:error, valid, _} ->
          warning = "\n[WARNING: Output truncated due to invalid UTF-8 binary data]"

          {valid <> warning,
           %{reason: :invalid_utf8, original_size: original_size, truncated_size: byte_size(valid) + byte_size(warning)}}

        {:incomplete, valid, _} ->
          warning = "\n[WARNING: Output truncated due to invalid UTF-8 binary data]"

          {valid <> warning,
           %{reason: :invalid_utf8, original_size: original_size, truncated_size: byte_size(valid) + byte_size(warning)}}

        valid when is_binary(valid) ->
          {valid, nil}
      end
    end
  end

  def ensure_utf8(result), do: {result, nil}

  @doc """
  Strip ANSI escape sequences from a string.

  Removes:
  - CSI sequences (colors, cursor movement, screen clearing)
  - OSC sequences (title setting)
  - Common two-byte sequences

  Non-binary results pass through unchanged.
  """
  def strip_ansi(input) when is_binary(input) do
    Regex.replace(@ansi_regex, input, "")
  end

  def strip_ansi(input), do: input

  @doc """
  Strip progress bar artifacts from CLI output.

  Detects and removes:
  - Carriage-return overwritten lines (keeps only the last segment after `\\r`)
  - Progress bar patterns like `[====>      ]`
  - Spinner patterns like `|`, `/`, `-`, `\\`
  - Purely whitespace lines
  """
  def strip_progress_bars(input) when is_binary(input) do
    input
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      processed = handle_carriage_returns(line)
      if progress_bar_line?(processed), do: acc, else: [processed | acc]
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  def strip_progress_bars(input), do: input

  @doc """
  Truncate output that exceeds the configured threshold.

  Uses per-tool truncation limits:
  - High-output tools (run_bash, read_file, rg, etc.) use a smaller default limit
  - Other tools use the global ceiling
  - `max_bytes` in tool_args overrides the default (capped by global ceiling)

  Reads thresholds from config:
  - `[:truncation, :tool_output_max_bytes]` (default: 128 KB) — global ceiling
  - `[:truncation, :tool_output_default_max_bytes]` (default: 16 KB) — for high-output tools
  - `[:truncation, :tool_output_truncate_size]` (default: 8192 bytes)

  Returns `{result, truncation_info}` where truncation_info is `nil` when no
  truncation occurred, or `%{reason: :size_exceeded, original_size: pos_integer, truncated_size: pos_integer}`.

  Non-binary results pass through as `{result, nil}`.
  """
  def truncate(result, tool_name, tool_args) when is_binary(result) do
    global_max = EvoGit.Config.resolve([:truncation, :tool_output_max_bytes]) || 128 * 1024
    default_max = EvoGit.Config.resolve([:truncation, :tool_output_default_max_bytes]) || 16 * 1024
    truncate_size = EvoGit.Config.resolve([:truncation, :tool_output_truncate_size]) || 8192

    effective_max = determine_effective_max(tool_name, tool_args, global_max, default_max)

    if byte_size(result) <= effective_max do
      {result, nil}
    else
      Logger.warning(
        "Output truncated for tool: #{tool_name}, arguments: #{inspect(tool_args)}, result byte_size: #{byte_size(result)}, effective max: #{effective_max}"
      )

      original_size = byte_size(result)
      half_size = div(truncate_size, 2)
      first_part = safe_binary_part(result, 0, half_size)
      last_part = safe_binary_part_from_end(result, half_size)
      omitted = original_size - truncate_size

      truncated =
        """
        [WARNING: Output exceeded #{effective_max} bytes (#{format_bytes(effective_max)}) and was truncated to #{truncate_size} bytes]
        The output from '#{tool_name}' was too large. Consider using more specific arguments
        or alternative tools to retrieve only the relevant portion of data.
        #{first_part}
        ... [#{omitted} bytes omitted] ...
        #{last_part}
        """
        |> String.trim()

      {truncated, %{reason: :size_exceeded, original_size: original_size, truncated_size: byte_size(truncated)}}
    end
  end

  def truncate(result, _tool_name, _tool_args), do: {result, nil}

  # --- Private Helpers ---

  defp determine_effective_max(tool_name, tool_args, global_max, default_max) do
    case tool_args do
      %{"max_bytes" => max} when is_integer(max) and max > 0 ->
        min(max, global_max)

      _ ->
        if MapSet.member?(@high_output_tools, tool_name) do
          default_max
        else
          global_max
        end
    end
  end

  defp format_bytes(bytes) do
    cond do
      bytes >= 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} bytes"
    end
  end

  # When \r appears within a line, keep only the last segment (after the final \r).
  # This handles progress bars that overwrite the same line using \r.
  defp handle_carriage_returns(line) do
    case String.split(line, "\r") do
      [_single] -> line
      parts -> List.last(parts)
    end
  end

  # Returns true if the line is a progress bar artifact that should be filtered out.
  defp progress_bar_line?(line) do
    stripped = String.trim(line)

    cond do
      # Empty or whitespace-only lines
      stripped == "" -> true
      # Pure progress bar: [====>      ] 50%
      Regex.match?(@progress_bar_regex, stripped) -> true
      # Spinner patterns: | / - \
      Regex.match?(@spinner_regex, stripped) -> true
      # Otherwise keep the line
      true -> false
    end
  end

  # Extracts `len` bytes starting at `start` from binary, ensuring we don't
  # split a multi-byte UTF-8 codepoint.
  defp safe_binary_part(binary, start, len) do
    if start + len >= byte_size(binary) do
      # Requested range exceeds the binary; just take what's available
      part = binary_part(binary, start, byte_size(binary) - start)
      if String.valid?(part), do: part, else: adjust_boundary(binary, start, byte_size(binary) - start)
    else
      part = binary_part(binary, start, len)
      if String.valid?(part), do: part, else: adjust_boundary(binary, start, len)
    end
  end

  # Extracts `len` bytes from the end of binary, ensuring we don't split a
  # multi-byte UTF-8 codepoint.
  defp safe_binary_part_from_end(binary, len) do
    total = byte_size(binary)
    start = total - len

    start = max(start, 0)
    available = total - start

    part = binary_part(binary, start, available)
    if String.valid?(part), do: part, else: adjust_boundary_from_end(binary, start, available)
  end

  # Backs up 1-3 bytes from the end until the result is valid UTF-8.
  defp adjust_boundary(binary, start, len) when len > 0 do
    adjusted_len = len - 1
    part = binary_part(binary, start, adjusted_len)

    if String.valid?(part) do
      part
    else
      adjust_boundary(binary, start, adjusted_len)
    end
  end

  defp adjust_boundary(_binary, _start, 0), do: ""

  # Trims 1-3 bytes from the start until the result is valid UTF-8.
  defp adjust_boundary_from_end(binary, start, len) when len > 0 do
    adjusted_start = start + 1
    adjusted_len = len - 1
    part = binary_part(binary, adjusted_start, adjusted_len)

    if String.valid?(part) do
      part
    else
      adjust_boundary_from_end(binary, adjusted_start, adjusted_len)
    end
  end

  defp adjust_boundary_from_end(_binary, _start, 0), do: ""
end
