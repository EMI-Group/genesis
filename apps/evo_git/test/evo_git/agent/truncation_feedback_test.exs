defmodule EvoGit.Agent.TruncationFeedbackTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.TruncationFeedback

  describe "is_rate_limit_error?/1" do
    test "detects rate_limit indicator" do
      assert TruncationFeedback.is_rate_limit_error?("rate_limit_exceeded")
    end

    test "detects quota indicator" do
      assert TruncationFeedback.is_rate_limit_error?("quota exhausted")
    end

    test "detects 429 indicator" do
      assert TruncationFeedback.is_rate_limit_error?("HTTP 429 Too Many Requests")
    end

    test "detects resource_exhausted indicator" do
      assert TruncationFeedback.is_rate_limit_error?("resource_exhausted")
    end

    test "returns false for unrelated error strings" do
      refute TruncationFeedback.is_rate_limit_error?("internal server error")
      refute TruncationFeedback.is_rate_limit_error?("connection timeout")
      refute TruncationFeedback.is_rate_limit_error?("")
    end

    test "works with non-string reasons via inspect" do
      # The function inspects the reason, so atoms and tuples are handled
      assert TruncationFeedback.is_rate_limit_error?({:error, %{message: "rate_limit hit"}})
      assert TruncationFeedback.is_rate_limit_error?(:rate_limit)
      refute TruncationFeedback.is_rate_limit_error?({:error, :timeout})
    end

    test "matching is case-sensitive on the underlying inspect output" do
      # The check is substring-based on inspect output; lowercase "rate_limit"
      assert TruncationFeedback.is_rate_limit_error?("rate_limit")
      # Uppercase variant does not match the lowercase substring
      refute TruncationFeedback.is_rate_limit_error?("RATE_LIMIT")
    end
  end

  describe "append_truncation_feedback/3 with nil truncation_info" do
    test "returns output unchanged" do
      assert TruncationFeedback.append_truncation_feedback("hello", nil, "run_bash") == "hello"
    end

    test "returns empty output unchanged" do
      assert TruncationFeedback.append_truncation_feedback("", nil, "read_file") == ""
    end
  end

  describe "append_truncation_feedback/3 with truncation_info" do
    test "appends feedback for size_exceeded reason" do
      truncation_info = %{
        reason: :size_exceeded,
        original_size: 200_000,
        truncated_size: 50_000
      }

      result = TruncationFeedback.append_truncation_feedback("output text", truncation_info, "run_bash")

      assert result =~ "output text"
      assert result =~ "Output Truncated"
      assert result =~ "output exceeded size limit"
      assert result =~ "head"
    end

    test "appends feedback for invalid_utf8 reason" do
      truncation_info = %{
        reason: :invalid_utf8,
        original_size: 100,
        truncated_size: 95
      }

      result = TruncationFeedback.append_truncation_feedback("text", truncation_info, "read_file")

      assert result =~ "Output Truncated"
      assert result =~ "invalid UTF-8 data was repaired/truncated"
    end

    test "includes original and truncated sizes in human-readable format" do
      truncation_info = %{
        reason: :size_exceeded,
        original_size: 1_048_576,
        truncated_size: 65_536
      }

      result = TruncationFeedback.append_truncation_feedback("o", truncation_info, "rg")

      assert result =~ "1.0 MB"
      assert result =~ "64.0 KB"
    end

    test "includes tool-specific suggestion" do
      truncation_info = %{reason: :size_exceeded, original_size: 1000, truncated_size: 500}

      result = TruncationFeedback.append_truncation_feedback("o", truncation_info, "search_history")

      assert result =~ "max_count"
    end

    test "separates original output from feedback with newlines" do
      truncation_info = %{reason: :size_exceeded, original_size: 1000, truncated_size: 500}

      result = TruncationFeedback.append_truncation_feedback("my output", truncation_info, "run_bash")

      # The original output should be followed by \n\n then the feedback marker
      assert result =~ "my output\n\n---"
    end
  end

  describe "tool_truncation_suggestion/1" do
    test "run_bash suggests head/tail/grep/file and max_bytes" do
      suggestion = TruncationFeedback.tool_truncation_suggestion("run_bash")
      assert suggestion =~ "head"
      assert suggestion =~ "tail"
      assert suggestion =~ "grep"
      assert suggestion =~ "max_bytes"
    end

    test "run_powershell shares the same suggestion as run_bash" do
      assert TruncationFeedback.tool_truncation_suggestion("run_powershell") ==
               TruncationFeedback.tool_truncation_suggestion("run_bash")
    end

    test "read_file suggests offset and limit" do
      suggestion = TruncationFeedback.tool_truncation_suggestion("read_file")
      assert suggestion =~ "offset"
      assert suggestion =~ "limit"
    end

    test "rg suggests narrowing search pattern" do
      suggestion = TruncationFeedback.tool_truncation_suggestion("rg")
      assert suggestion =~ "narrowing"
    end

    test "curl mentions large HTTP response" do
      suggestion = TruncationFeedback.tool_truncation_suggestion("curl")
      assert suggestion =~ "HTTP response"
    end

    test "run_git suggests flags like --stat and --oneline" do
      suggestion = TruncationFeedback.tool_truncation_suggestion("run_git")
      assert suggestion =~ "--stat"
      assert suggestion =~ "--oneline"
    end

    test "search_history suggests reducing max_count" do
      suggestion = TruncationFeedback.tool_truncation_suggestion("search_history")
      assert suggestion =~ "max_count"
    end

    test "search_web suggests reducing max_results" do
      suggestion = TruncationFeedback.tool_truncation_suggestion("search_web")
      assert suggestion =~ "max_results"
    end

    test "search_context suggests narrowing the pattern" do
      suggestion = TruncationFeedback.tool_truncation_suggestion("search_context")
      assert suggestion =~ "narrowing"
    end

    test "unknown tool name falls back to generic suggestion" do
      suggestion = TruncationFeedback.tool_truncation_suggestion("some_random_tool")
      assert suggestion =~ "more specific arguments"
      assert suggestion =~ "max_bytes"
    end

    test "every tool suggestion mentions max_bytes" do
      for tool <- ["run_bash", "run_powershell", "read_file", "rg", "curl", "run_git",
                   "search_history", "search_web", "search_context", "unknown"] do
        assert TruncationFeedback.tool_truncation_suggestion(tool) =~ "max_bytes"
      end
    end

    test "all suggestions return strings" do
      for tool <- ["run_bash", "read_file", "rg", "curl", "run_git", "search_history",
                   "search_web", "search_context", "unknown_tool"] do
        assert is_binary(TruncationFeedback.tool_truncation_suggestion(tool))
      end
    end
  end

  describe "format_truncation_reason/1" do
    test "formats size_exceeded reason" do
      assert TruncationFeedback.format_truncation_reason(%{reason: :size_exceeded}) ==
               "output exceeded size limit"
    end

    test "formats invalid_utf8 reason" do
      assert TruncationFeedback.format_truncation_reason(%{reason: :invalid_utf8}) ==
               "invalid UTF-8 data was repaired/truncated"
    end

    test "ignores extra keys in the map" do
      assert TruncationFeedback.format_truncation_reason(%{reason: :size_exceeded, original_size: 100}) ==
               "output exceeded size limit"
    end
  end
end
