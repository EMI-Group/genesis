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
                       "run_bash",
                       "run_powershell",
                       "read_file",
                       "rg",
                       "curl",
                       "run_git",
                       "search_web",
                       "search_context",
                       "search_history"
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
    {result, utf8_info} = EvoGit.UTF8.ensure_utf8(result)

    result =
      result
      |> strip_ansi()
      |> strip_progress_bars()

    {result, truncate_info} = truncate(result, tool_name, tool_args)

    {result, truncate_info || utf8_info}
  end

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

  def strip_ansi(input) when not is_binary(input), do: input

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

  def strip_progress_bars(input) when not is_binary(input), do: input

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
    global_max = EvoGit.Config.resolve([:truncation, :tool_output_max_bytes])
    default_max = EvoGit.Config.resolve([:truncation, :tool_output_default_max_bytes])
    truncate_size = EvoGit.Config.resolve([:truncation, :tool_output_truncate_size])

    effective_max = determine_effective_max(tool_name, tool_args, global_max, default_max)

    original_size = byte_size(result)

    if original_size <= effective_max do
      {result, nil}
    else
      Logger.warning(
        "Tool output truncated for '#{tool_name}' (arguments: #{inspect(tool_args)}): " <>
          "original #{original_size} bytes exceeded effective max #{effective_max} bytes — " <>
          "the LLM received only a PARTIAL result. Raise the limit via the " <>
          "`[truncation] tool_output_default_max_bytes` / `[truncation] tool_output_max_bytes` " <>
          "config keys or a per-call `max_bytes` argument (capped by the global ceiling)."
      )

      {first_part, last_part, retained, omitted} = head_tail_slices(result, truncate_size)

      body =
        if omitted == 0 do
          first_part
        else
          first_part <> "\n... [#{omitted} bytes omitted] ...\n" <> last_part
        end

      truncated =
        (truncation_header(
           effective_max,
           original_size,
           first_part,
           last_part,
           omitted,
           global_max
         ) <>
           "\n" <> body)
        |> String.trim()

      # Defensive UTF-8 safety net: String.byte_slice/3 is already
      # UTF-8-boundary-safe (Elixir 1.17+ backs off to the last valid codepoint),
      # but keep the final assembled string valid no matter what. ensure_utf8/1
      # on an already-valid string is a no-op returning {result, nil} — keep only
      # the first element so the :size_exceeded truncation_info below is never
      # clobbered by a repair info.
      {truncated, _utf8_info} = EvoGit.UTF8.ensure_utf8(truncated)

      {truncated,
       %{
         reason: :size_exceeded,
         original_size: original_size,
         truncated_size: retained
       }}
    end
  end

  def truncate(result, _tool_name, _tool_args) when not is_binary(result), do: {result, nil}

  # --- Private Helpers ---

  # Computes the head/tail content slices for a truncated output using the
  # kept-budget clamp: never slice more than the original size, so the head and
  # tail cannot overlap and the omitted count can never go negative. Returns
  # {first_part, last_part, retained, omitted} where `retained` is the ACTUAL
  # number of content bytes kept (byte_slice may return slightly fewer bytes on
  # codepoint backoff) and `omitted` = original_size - retained (always >= 0).
  defp head_tail_slices(result, truncate_size) do
    original_size = byte_size(result)
    kept_budget = min(truncate_size, original_size)

    if kept_budget >= original_size do
      # Output exceeded the threshold but is smaller than the keep size: keep
      # the whole original content unchanged (nothing omitted).
      {result, "", original_size, 0}
    else
      half = div(kept_budget, 2)
      first = String.byte_slice(result, 0, half)
      last = String.byte_slice(result, -half, half)
      retained = byte_size(first) + byte_size(last)
      {first, last, retained, original_size - retained}
    end
  end

  # Short, factual inline header the LLM sees at the top of a truncated output.
  # Must be accurate in both cases: omitted > 0 (head + tail kept) and the
  # edge case where the whole output was retained (omitted == 0).
  defp truncation_header(effective_max, original_size, first_part, last_part, omitted, global_max) do
    if omitted == 0 do
      "[WARNING: Output exceeded #{effective_max} bytes (#{format_bytes(effective_max)}) — " <>
        "the full #{original_size} bytes (#{format_bytes(original_size)}) were retained unchanged; nothing omitted]"
    else
      first_size = byte_size(first_part)
      last_size = byte_size(last_part)

      "[WARNING: Output exceeded #{effective_max} bytes (#{format_bytes(effective_max)}) — " <>
        "original #{original_size} bytes, kept first #{first_size} + last #{last_size} bytes, " <>
        "#{omitted} bytes in the middle omitted " <>
        "(PARTIAL OUTPUT — do not conclude the result is empty/missing; " <>
        "narrow the pattern/path or raise max_bytes up to #{global_max})]"
    end
  end

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

  def format_bytes(bytes) do
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
end
