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

      result
      |> ensure_utf8()
      |> strip_ansi()
      |> strip_progress_bars()
      |> then(&truncate(&1, tool_name, tool_args))
  """

  require Logger

  # --- Public API ---

  @doc """
  Full sanitization + truncation pipeline for tool outputs.

  Steps: ensure_utf8 → strip_ansi → strip_progress_bars → truncate
  """
  def sanitize_and_truncate(result, tool_name, tool_args) do
    result
    |> ensure_utf8()
    |> strip_ansi()
    |> strip_progress_bars()
    |> then(&truncate(&1, tool_name, tool_args))
  end

  @doc """
  Ensure output is valid UTF-8. Repairs or truncates invalid sequences.

  - If the result is valid UTF-8, returns it unchanged.
  - If invalid, attempts repair via `:unicode.characters_to_binary/3`.
  - On repair failure, appends a warning and returns the valid prefix.
  - Non-binary results pass through unchanged.
  """
  def ensure_utf8(result) when is_binary(result) do
    if String.valid?(result) do
      result
    else
      case :unicode.characters_to_binary(result, :utf8, :utf8) do
        {:error, valid, _} ->
          valid <> "\n[WARNING: Output truncated due to invalid UTF-8 binary data]"

        {:incomplete, valid, _} ->
          valid <> "\n[WARNING: Output truncated due to invalid UTF-8 binary data]"

        valid when is_binary(valid) ->
          valid
      end
    end
  end

  def ensure_utf8(result), do: result

  @doc """
  Strip ANSI escape sequences from a string.

  Removes:
  - CSI sequences (colors, cursor movement, screen clearing)
  - OSC sequences (title setting)
  - Common two-byte sequences

  Non-binary results pass through unchanged.
  """
  def strip_ansi(input) when is_binary(input) do
    Regex.replace(~r/\e\[[0-9;]*[a-zA-Z]|\e\][^\x07]*\x07|\e[()][AB012]|\e\[[0-9;]*m/, input, "")
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
    |> Enum.map(&handle_carriage_returns/1)
    |> Enum.reject(&progress_bar_line?/1)
    |> Enum.join("\n")
  end

  def strip_progress_bars(input), do: input

  @doc """
  Truncate output that exceeds the configured threshold.

  Uses `byte_size/1` (not `String.length/1`) for accurate size measurement.
  Keeps first half + last half of the truncated size, with a warning header.

  Reads thresholds from config:
  - `[:truncation, :tool_output_max_bytes]` (default: 128 KB)
  - `[:truncation, :tool_output_truncate_size]` (default: 8192 bytes)

  Non-binary results pass through unchanged.
  """
  def truncate(result, tool_name, tool_args) when is_binary(result) do
    max_bytes = EvoGit.Config.resolve([:truncation, :tool_output_max_bytes]) || 128 * 1024
    truncate_size = EvoGit.Config.resolve([:truncation, :tool_output_truncate_size]) || 8192

    if byte_size(result) <= max_bytes do
      result
    else
      Logger.warning(
        "Output truncated for tool: #{tool_name}, arguments: #{inspect(tool_args)}, result byte_size: #{byte_size(result)}"
      )

      half_size = div(truncate_size, 2)
      first_part = safe_binary_part(result, 0, half_size)
      last_part = safe_binary_part_from_end(result, half_size)
      omitted = byte_size(result) - truncate_size

      """
      [WARNING: Output exceeded #{max_bytes} bytes and was truncated to #{truncate_size} bytes]
      The output from '#{tool_name}' was too large. Consider using more specific arguments
      or alternative tools to retrieve only the relevant portion of data.
      #{first_part}
      ... [#{omitted} bytes omitted] ...
      #{last_part}
      """
      |> String.trim()
    end
  end

  def truncate(result, _tool_name, _tool_args), do: result

  # --- Private Helpers ---

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
      Regex.match?(~r/^[\s\r]*\[[=\->#*_ ]+\]\s*\d*%?\s*$/, stripped) -> true
      # Spinner patterns: | / - \
      Regex.match?(~r/^[\|\/\-\\]$/, stripped) -> true
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
