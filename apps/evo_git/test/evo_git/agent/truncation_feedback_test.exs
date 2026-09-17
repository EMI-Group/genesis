defmodule EvoGit.Agent.TruncationFeedbackTest do
  @moduledoc """
  `async: true` — pure `EvoGit.Agent.TruncationFeedback` helpers
  (`is_rate_limit_error?/1`, `classify_model_exhaustion/1`,
  `is_insufficient_balance_error?/1`, `is_model_exhaustion_error?/1`,
  `append_truncation_feedback/3`); no shared/global state is touched.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.TruncationFeedback
  alias ReqLLM.Error.API.Request, as: ApiRequest

  # The DeepSeek HTTP 402 shape: `%ReqLLM.Error.API.Request{status: 402,
  # reason: "Insufficient Balance", response_body: %{"error" => %{"message" =>
  # "Insufficient Balance"}}}` (the real struct fields are `:reason`, `:status`,
  # `:response_body`, `:provider_code`, …; see deps/req_llm/lib/req_llm/error.ex).
  defp insufficient_balance_error do
    %ApiRequest{
      status: 402,
      reason: "Insufficient Balance",
      response_body: %{"error" => %{"message" => "Insufficient Balance"}}
    }
  end

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

  describe "classify_model_exhaustion/1" do
    test "classifies an HTTP 402 insufficient-balance struct as :insufficient_balance" do
      assert TruncationFeedback.classify_model_exhaustion(insufficient_balance_error()) ==
               :insufficient_balance
    end

    test "classifies rate-limit shapes as :rate_limit" do
      assert TruncationFeedback.classify_model_exhaustion("rate_limit_exceeded") == :rate_limit

      assert TruncationFeedback.classify_model_exhaustion("HTTP 429 Too Many Requests") ==
               :rate_limit

      assert TruncationFeedback.classify_model_exhaustion("resource_exhausted") == :rate_limit

      assert TruncationFeedback.classify_model_exhaustion(%ApiRequest{
               status: 429,
               reason: "Too Many Requests"
             }) == :rate_limit
    end

    test "insufficient balance takes precedence when both classes match" do
      # status 429 matches the rate-limit check AND the reason matches the
      # insufficient-balance phrases — the balance class wins.
      error = %ApiRequest{status: 429, reason: "Insufficient Balance"}

      assert TruncationFeedback.is_rate_limit_error?(error)
      assert TruncationFeedback.classify_model_exhaustion(error) == :insufficient_balance
    end

    test "a bare \"402\" substring is NOT a match (no false positives)" do
      # Token counts / byte sizes routinely contain "402" — only an actual 402
      # API status or an insufficient-balance phrase may classify.
      refute TruncationFeedback.is_insufficient_balance_error?("used 402 tokens")
      refute TruncationFeedback.is_model_exhaustion_error?("used 402 tokens")
      assert TruncationFeedback.classify_model_exhaustion("used 402 tokens") == nil

      refute TruncationFeedback.is_insufficient_balance_error?(%ApiRequest{
               status: nil,
               reason: "response had 402 tokens"
             })

      assert TruncationFeedback.classify_model_exhaustion(%ApiRequest{
               status: nil,
               reason: "response had 402 tokens"
             }) == nil
    end

    test "returns nil for unrelated errors" do
      assert TruncationFeedback.classify_model_exhaustion(%ApiRequest{
               status: 500,
               reason: "Internal Server Error"
             }) == nil

      assert TruncationFeedback.classify_model_exhaustion(:timeout) == nil
      assert TruncationFeedback.classify_model_exhaustion({:error, :connection_closed}) == nil
      assert TruncationFeedback.classify_model_exhaustion(:boom) == nil
      assert TruncationFeedback.classify_model_exhaustion(nil) == nil
      assert TruncationFeedback.classify_model_exhaustion("") == nil
    end
  end

  describe "is_insufficient_balance_error?/1" do
    test "matches the HTTP 402 struct" do
      assert TruncationFeedback.is_insufficient_balance_error?(insufficient_balance_error())
    end

    test "matches insufficient-quota phrases and provider codes" do
      assert TruncationFeedback.is_insufficient_balance_error?("insufficient_quota")
      assert TruncationFeedback.is_insufficient_balance_error?("insufficient_balance")
      assert TruncationFeedback.is_insufficient_balance_error?("Insufficient Funds")

      assert TruncationFeedback.is_insufficient_balance_error?(%ApiRequest{
               status: 403,
               provider_code: "insufficient_quota"
             })
    end

    test "does not match rate-limit-only or unrelated errors" do
      refute TruncationFeedback.is_insufficient_balance_error?("HTTP 429 Too Many Requests")

      refute TruncationFeedback.is_insufficient_balance_error?(%ApiRequest{
               status: 500,
               reason: "Internal Server Error"
             })

      refute TruncationFeedback.is_insufficient_balance_error?(:timeout)
    end
  end

  describe "is_model_exhaustion_error?/1" do
    test "treats :insufficient_balance as a model-exhaustion error" do
      assert TruncationFeedback.is_model_exhaustion_error?(insufficient_balance_error())

      assert TruncationFeedback.classify_model_exhaustion(insufficient_balance_error()) ==
               :insufficient_balance
    end

    test "treats rate-limit errors as model-exhaustion errors" do
      assert TruncationFeedback.is_model_exhaustion_error?("rate_limit")
      assert TruncationFeedback.is_model_exhaustion_error?("resource_exhausted")
    end

    test "is false for unrelated errors" do
      refute TruncationFeedback.is_model_exhaustion_error?(:timeout)
      refute TruncationFeedback.is_model_exhaustion_error?("internal server error")
      refute TruncationFeedback.is_model_exhaustion_error?(nil)
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
