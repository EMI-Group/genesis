defmodule EvoGit.Agent.TruncationFeedback do
  @moduledoc """
  Truncation feedback and rate-limit detection logic extracted from
  `EvoGit.Agent.__using__/1`.

  Handles detection of rate-limit errors in LLM responses, and generates
  concise truncation warnings when tool output exceeds size limits.
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
  Appends a one-line truncation warning to the tool output when the output was
  truncated. No-op when truncation_info is nil.
  """
  def append_truncation_feedback(output, nil, _tool_name), do: output

  def append_truncation_feedback(output, truncation_info, _tool_name) do
    feedback =
      "⚠️ Output truncated: original #{truncation_info.original_size} bytes, kept " <>
        "#{truncation_info.truncated_size} bytes — " <>
        "narrow the pattern/path or raise max_bytes (up to 131072) for the full result."

    output <> "\n\n" <> feedback
  end
end
