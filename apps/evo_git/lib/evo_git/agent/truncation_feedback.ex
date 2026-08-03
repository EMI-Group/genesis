defmodule EvoGit.Agent.TruncationFeedback do
  @moduledoc """
  Truncation feedback and rate-limit detection logic extracted from
  `EvoGit.Agent.__using__/1`.

  Handles detection of rate-limit errors in LLM responses, and generates
  user-friendly truncation warnings when tool output exceeds size limits.
  """

  # --- Rate-Limit Detection ---

  @doc """
  Detects whether an LLM error reason indicates a rate-limit or quota
  exhaustion condition.
  """
  def is_rate_limit_error?(reason) do
    reason_str = inspect(reason)

    String.contains?(reason_str, "rate_limit") or
      String.contains?(reason_str, "quota") or
      String.contains?(reason_str, "429") or
      String.contains?(reason_str, "resource_exhausted")
  end

  # --- Truncation Feedback ---

  @doc """
  Appends a truncation warning to the tool output when the output was
  truncated. No-op when truncation_info is nil.
  """
  def append_truncation_feedback(output, nil, _tool_name), do: output

  def append_truncation_feedback(output, truncation_info, tool_name) do
    suggestion = tool_truncation_suggestion(tool_name)

    feedback =
      """
      ---
      ⚠️ **Output Truncated** (#{format_truncation_reason(truncation_info)})
      Original size: #{EvoGit.Agent.OutputSanitizer.format_bytes(truncation_info.original_size)} → Truncated to: #{EvoGit.Agent.OutputSanitizer.format_bytes(truncation_info.truncated_size)}

      **Suggestion:** #{suggestion}
      """
      |> String.trim()

    output <> "\n\n" <> feedback
  end

  # --- Tool-Specific Truncation Suggestions ---

  def tool_truncation_suggestion(tool_name)
       when tool_name in ["run_bash", "run_powershell"] do
    "Consider using `head`, `tail`, `grep`, or piping output to a file. You can also pass `max_bytes` to increase the output limit."
  end

  def tool_truncation_suggestion("read_file") do
    "Consider using `offset` and `limit` parameters to read only the needed portion. You can also pass `max_bytes` to increase the output limit."
  end

  def tool_truncation_suggestion("rg") do
    "Consider narrowing the search pattern or specifying a more targeted path. You can also pass `max_bytes` to increase the output limit."
  end

  def tool_truncation_suggestion("curl") do
    "The HTTP response was large. You can pass `max_bytes` to increase the output limit if you need more of the response."
  end

  def tool_truncation_suggestion("run_git") do
    "Consider using flags like `--stat`, `--oneline`, or `-n <count>` to reduce output. You can also pass `max_bytes` to increase the output limit."
  end

  def tool_truncation_suggestion("search_history") do
    "Consider reducing `max_count` or narrowing the search pattern. You can also pass `max_bytes` to increase the output limit."
  end

  def tool_truncation_suggestion("search_web") do
    "Consider reducing `max_results`. You can also pass `max_bytes` to increase the output limit."
  end

  def tool_truncation_suggestion("search_context") do
    "Consider narrowing the pattern or specifying a more targeted path. You can also pass `max_bytes` to increase the output limit."
  end

  def tool_truncation_suggestion(_tool_name) do
    "Consider using more specific arguments to reduce output. You can also pass `max_bytes` to increase the output limit."
  end

  # --- Formatting Helpers ---

  def format_truncation_reason(%{reason: :size_exceeded}), do: "output exceeded size limit"

  def format_truncation_reason(%{reason: :invalid_utf8}),
    do: "invalid UTF-8 data was repaired/truncated"
end
