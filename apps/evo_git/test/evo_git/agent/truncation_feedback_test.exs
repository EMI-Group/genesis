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

      result =
        TruncationFeedback.append_truncation_feedback("output text", truncation_info, "run_bash")

      assert result =~ "output text"
      assert result =~ "⚠️ Output truncated"
      assert result =~ "original 200000 bytes"
      assert result =~ "kept 50000 bytes"
      assert result =~ "max_bytes (up to 131072)"
    end

    test "appends feedback for invalid_utf8 reason" do
      truncation_info = %{
        reason: :invalid_utf8,
        original_size: 100,
        truncated_size: 95
      }

      result = TruncationFeedback.append_truncation_feedback("text", truncation_info, "read_file")

      assert result =~ "⚠️ Output truncated"
      assert result =~ "original 100 bytes"
    end

    test "includes original and truncated sizes as raw byte counts" do
      truncation_info = %{
        reason: :size_exceeded,
        original_size: 1_048_576,
        truncated_size: 65_536
      }

      result = TruncationFeedback.append_truncation_feedback("o", truncation_info, "rg")

      assert result =~ "original 1048576 bytes"
      assert result =~ "kept 65536 bytes"
    end

    test "includes the generic max_bytes remediation hint" do
      truncation_info = %{reason: :size_exceeded, original_size: 1000, truncated_size: 500}

      result =
        TruncationFeedback.append_truncation_feedback("o", truncation_info, "search_history")

      assert result =~ "max_bytes (up to 131072)"
    end

    test "separates original output from feedback with newlines" do
      truncation_info = %{reason: :size_exceeded, original_size: 1000, truncated_size: 500}

      result =
        TruncationFeedback.append_truncation_feedback("my output", truncation_info, "run_bash")

      # The original output should be followed by \n\n then the feedback marker
      assert result =~ "my output\n\n⚠️"
    end

    test "appended feedback states accurate sizes and the single remediation" do
      truncation_info = %{
        reason: :size_exceeded,
        original_size: 72_154,
        truncated_size: 8_192
      }

      result = TruncationFeedback.append_truncation_feedback("o", truncation_info, "rg")

      assert result =~ "⚠️ Output truncated"
      assert result =~ "original 72154 bytes"
      assert result =~ "kept 8192 bytes"
      assert result =~ "max_bytes (up to 131072)"
      # No old `---` separator line before the feedback
      refute result =~ "\n\n---"
    end
  end
end
