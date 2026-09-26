defmodule EvoGit.Agent.LlmErrorTest do
  @moduledoc """
  `async: true` — PURE unit suite for `EvoGit.Agent.LlmError`: the fail-fast
  classification of NON-RETRYABLE LLM provider rejections (`non_retryable?/1`)
  and the actionable one-line message built for them (`format_failure/1`).

  Nothing shared is touched: every input is a literal struct / map / tuple
  (no server, no scheduler, no ETS, no app env, no process dictionary), and the
  module under test is documented as total (never raises for any term), so the
  suite needs no globals and never has to serialise against another module.

  The suite additionally PINS one reported production divergence — a phrase-less
  HTTP 402 wrapped in `{:error, …}` / an `API.Stream` is classified
  non-retryable instead of keeping the long model-exhaustion backoff. See the
  `"known divergence (reported production bug)"` describe block: it asserts the
  CURRENT behaviour, not the correct one.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.LlmError
  alias ReqLLM.Error.API.Request, as: ApiRequest
  alias ReqLLM.Error.API.Stream, as: ApiStream

  # The provider's own nested JSON payload, exactly as Z.AI returns it inside
  # `response_body["metadata"]["raw"]` (an OpenRouter-style envelope).
  @zai_raw_json ~s({"error":{"code":"1210","message":"Invalid API parameter, please check the documentation."}})

  # The human message nested in that payload (what a user must act on).
  @zai_human_message "Invalid API parameter, please check the documentation."

  # The REAL captured Z.AI rejection shape: HTTP 400, provider code 1210,
  # `retryable: false`, with the provider details buried in
  # `response_body["metadata"]`.
  defp zai_rejection do
    %ApiRequest{
      status: 400,
      provider_code: 400,
      retryable: false,
      response_body: %{
        "code" => 400,
        "message" => "Provider returned error",
        "metadata" => %{
          "is_byok" => false,
          "provider_error_code" => "1210",
          "provider_name" => "Z.AI",
          "raw" => @zai_raw_json
        }
      }
    }
  end

  # The DeepSeek out-of-credit 402 (the shape whose LONG scheduler backoff must
  # be preserved) — the reason/body text is what keeps it classified as a
  # model-exhaustion signal once it is wrapped.
  defp insufficient_balance_402 do
    %ApiRequest{
      status: 402,
      reason: "Insufficient Balance",
      response_body: %{"error" => %{"message" => "Insufficient Balance"}}
    }
  end

  # A transport (non-API) failure — carries no `:status` / `:provider_code`
  # metadata at all, so it must never be classified as a provider rejection.
  defp finch_transport_error do
    %Finch.TransportError{reason: :timeout}
  end

  # Wraps `request` in `depth` nested `%{cause: …}` layers.
  defp nest(request, 0), do: request
  defp nest(request, depth), do: %{cause: nest(request, depth - 1)}

  describe "non_retryable?/1 — non-retryable provider rejections" do
    test "the real captured Z.AI 400 rejection is non-retryable" do
      assert LlmError.non_retryable?(zai_rejection())
    end

    test "the same rejection wrapped in an API.Stream is still found" do
      assert LlmError.non_retryable?(%ApiStream{cause: zai_rejection()})
    end

    test "the :error and :exit wrapper tuples are peeled" do
      assert LlmError.non_retryable?({:error, zai_rejection()})
      assert LlmError.non_retryable?({:exit, zai_rejection()})
    end

    test "the remaining ReqLLM wrapper tags are peeled too" do
      # Mirrors `ReqLLM.Streaming.Failure.classify/1`'s wrapper tag list.
      for tag <- [:throw, :shutdown, :http_task_failed] do
        assert LlmError.non_retryable?({tag, zai_rejection()}),
               "expected {#{inspect(tag)}, %ApiRequest{}} to be peeled"
      end
    end

    test "a stack of mixed wrapper layers is peeled" do
      assert LlmError.non_retryable?({:error, %ApiStream{cause: %{cause: zai_rejection()}}})
    end

    test "a plain map carrying :cause to the request is peeled" do
      assert LlmError.non_retryable?(%{cause: zai_rejection()})
    end

    test "a string-keyed map carrying \"cause\" to the request is peeled" do
      assert LlmError.non_retryable?(%{"cause" => zai_rejection()})
    end

    test "a keyword list carrying :cause to the request is peeled" do
      assert LlmError.non_retryable?(cause: zai_rejection())
    end

    test "a bare 400 with retryable: nil is non-retryable (status decides)" do
      assert LlmError.non_retryable?(%ApiRequest{status: 400, retryable: nil})
    end

    test "retryable: false with no status at all is non-retryable" do
      assert LlmError.non_retryable?(%ApiRequest{status: nil, retryable: false})
    end

    test "other deterministic 4xx statuses are non-retryable" do
      for status <- [400, 401, 403, 404, 422] do
        assert LlmError.non_retryable?(%ApiRequest{status: status, retryable: false}),
               "expected HTTP #{status} to be non-retryable"
      end
    end
  end

  describe "non_retryable?/1 — stays retryable" do
    test "402 keeps the long model-exhaustion backoff (bare)" do
      refute LlmError.non_retryable?(insufficient_balance_402())
      refute LlmError.non_retryable?(%ApiRequest{status: 402})
    end

    test "402 wrapped in an :error tuple keeps the long backoff" do
      refute LlmError.non_retryable?({:error, insufficient_balance_402()})
    end

    test "402 wrapped in an API.Stream keeps the long backoff" do
      refute LlmError.non_retryable?(%ApiStream{cause: insufficient_balance_402()})
    end

    test "429 (rate limit) stays retryable, bare and wrapped" do
      request = %ApiRequest{status: 429, reason: "Too Many Requests"}

      refute LlmError.non_retryable?(request)
      refute LlmError.non_retryable?({:error, request})
      refute LlmError.non_retryable?(%ApiStream{cause: request})
    end

    test "5xx server errors stay retryable" do
      for status <- [500, 502, 503] do
        refute LlmError.non_retryable?(%ApiRequest{status: status, retryable: false}),
               "expected HTTP #{status} to stay retryable"
      end
    end

    test "the other transient 4xx statuses stay retryable" do
      for status <- [408, 409, 425] do
        refute LlmError.non_retryable?(%ApiRequest{status: status, retryable: false}),
               "expected HTTP #{status} to stay retryable"
      end
    end

    test "an explicit retryable: true signal wins over a 400 status" do
      refute LlmError.non_retryable?(%ApiRequest{status: 400, retryable: true})
    end

    test "model exhaustion takes precedence over the deterministic 4xx rule" do
      # A 400 whose text reads as out-of-credit keeps the long scheduler backoff
      # (the documented precedence), even though 400 is normally non-retryable.
      refute LlmError.non_retryable?(%ApiRequest{status: 400, reason: "Insufficient Balance"})
    end

    test "no API request found → retryable (nil, atoms, strings, maps, lists)" do
      for reason <- [
            nil,
            :timeout,
            :boom,
            "rate_limit_exceeded",
            "plain failure string",
            %{status: 400},
            %{"message" => "json body without a struct"},
            [1, 2, 3],
            {:error, :timeout},
            {:error, "boom"},
            finch_transport_error()
          ] do
        refute LlmError.non_retryable?(reason), "expected #{inspect(reason)} to stay retryable"
      end
    end

    test "a stream error with no cause is retryable" do
      refute LlmError.non_retryable?(%ApiStream{cause: nil})
      refute LlmError.non_retryable?(%ApiStream{reason: "stream broke", cause: nil})
    end

    test "an API request carrying no signal at all is retryable" do
      refute LlmError.non_retryable?(%ApiRequest{status: nil, retryable: nil})
    end

    test "an unknown wrapper tag is NOT peeled" do
      # Only the five ReqLLM tags are wrappers; an arbitrary 2-tuple is opaque.
      refute LlmError.non_retryable?({:unknown_tag, zai_rejection()})
    end

    test "a non-keyword list carrying the request is not a wrapper" do
      refute LlmError.non_retryable?([zai_rejection(), 1])
    end
  end

  describe "non_retryable?/1 — unbounded cause chains terminate" do
    # Erlang terms are immutable and the external term format has no
    # back-references, so a literally self-referential `:cause` cannot be
    # constructed. The property the module's depth bound actually protects is
    # that an ARBITRARILY LONG cause chain terminates instead of looping
    # forever — which is what these fixtures exercise (a real self-cycle would
    # behave the same way: the bound stops the walk).
    test "a chain within the unwrap bound is still peeled" do
      assert LlmError.non_retryable?(nest(zai_rejection(), 1))
      assert LlmError.non_retryable?(nest(zai_rejection(), 4))
    end

    test "a chain past the unwrap bound returns false instead of looping" do
      # `EvoGit.Agent.LlmError`'s `@max_unwrap_depth` is 5, so 5 wrapper layers
      # (0..4 are walked) are the boundary: the request below is never reached.
      refute LlmError.non_retryable?(nest(zai_rejection(), 5))
    end

    test "a hostile 1000-layer chain terminates with a boolean" do
      result = LlmError.non_retryable?(nest(zai_rejection(), 1_000))

      # Bounded: never hangs (ExUnit's per-test timeout would catch a loop),
      # never raises, always a boolean.
      assert is_boolean(result)
      refute result
    end

    test "a chain alternating API.Stream wrappers terminates with a boolean" do
      result =
        1..50
        |> Enum.reduce(zai_rejection(), fn _, acc -> %ApiStream{cause: %{cause: acc}} end)
        |> LlmError.non_retryable?()

      assert is_boolean(result)
      refute result
    end
  end

  describe "known divergence (reported production bug)" do
    # PRODUCTION DIVERGENCE — reported to the caller; NOT fixed here (this suite
    # is test-only) and NOT weakened: the CURRENT value is pinned so the
    # divergence stays visible.
    #
    # `non_retryable?/1` peels the wrapper layers to LOCATE the API request, but
    # the model-exhaustion precedence check runs on the RAW reason:
    # `TruncationFeedback.classify_model_exhaustion/1` only recognises a BARE
    # `%ReqLLM.Error.API.Request{}` structurally and otherwise falls back to a
    # substring search over `inspect/1`. A 402 wrapped in `{:error, …}` (or in an
    # `API.Stream`) therefore loses its exhaustion class whenever the wrapper's
    # `inspect/1` text carries no balance/quota phrase — and the status rule
    # (`400..499` ⇒ non-retryable) then classifies it NON-RETRYABLE, so an
    # out-of-credit provider fails the task fast instead of taking the long
    # (~2.5 day) scheduler backoff. `ToolDispatch.handle_llm_failure/7` performs
    # the same raw-reason check, so it takes the same branch.
    #
    # CORRECT behaviour is `false`. Minimal reproduction:
    #
    #     {:error, %ReqLLM.Error.API.Request{status: 402, reason: "Payment Required"}}
    #     |> EvoGit.Agent.LlmError.non_retryable?()   #=> true (should be false)
    #
    # Compare "402 wrapped in an :error tuple keeps the long backoff" above: the
    # real DeepSeek 402 carries "Insufficient Balance" and is therefore handled
    # correctly — only a phrase-less 402 falls through.
    test "a phrase-less wrapped 402 is currently classified non-retryable" do
      request = %ApiRequest{status: 402, reason: "Payment Required"}

      # Bare: correctly retryable (structural 402 wins).
      refute LlmError.non_retryable?(request)

      # Wrapped: the bug — the exhaustion class is lost with the wrapper.
      assert LlmError.non_retryable?({:error, request})
      assert LlmError.non_retryable?(%ApiStream{cause: request})
    end
  end

  describe "format_failure/1 — the real Z.AI rejection" do
    test "is a single line naming the status, provider code, provider and message" do
      message = LlmError.format_failure(zai_rejection())

      refute String.contains?(message, "\n"), "expected a single-line message"
      assert message =~ "HTTP 400"
      assert message =~ "code 1210"
      assert message =~ "Z.AI"
      assert message =~ @zai_human_message
    end

    test "uses the provider's nested message, not the raw JSON envelope" do
      message = LlmError.format_failure(zai_rejection())

      assert String.starts_with?(message, "Provider rejected the LLM request")
      refute message =~ "{\"error\""
    end

    test "the message is identical for a wrapped reason (same request found)" do
      bare = LlmError.format_failure(zai_rejection())

      assert LlmError.format_failure({:error, zai_rejection()}) == bare
      assert LlmError.format_failure(%ApiStream{cause: zai_rejection()}) == bare
      assert LlmError.format_failure(%{cause: zai_rejection()}) == bare
    end
  end

  describe "format_failure/1 — defensive field extraction" do
    test "a minimal shape with only a top-level \"message\" still renders" do
      message =
        LlmError.format_failure(%ApiRequest{
          status: 400,
          response_body: %{"message" => "Bad request"}
        })

      refute String.contains?(message, "\n")
      assert message =~ "HTTP 400"
      assert message =~ "Bad request"
      refute message =~ "code "
      refute message =~ "provider "
    end

    test "an invalid-JSON metadata.raw falls back to the raw text verbatim" do
      message =
        LlmError.format_failure(%ApiRequest{
          status: 400,
          response_body: %{"metadata" => %{"raw" => "not json at all"}}
        })

      refute String.contains?(message, "\n")
      assert message =~ "HTTP 400"
      assert message =~ "not json at all"
    end

    test "valid-JSON metadata.raw without error.message falls back to the raw string" do
      raw = ~s({"detail":"weird"})

      message =
        LlmError.format_failure(%ApiRequest{
          status: 400,
          response_body: %{"metadata" => %{"raw" => raw}}
        })

      assert message =~ raw
    end

    test "the provider code falls back to response_body[\"error\"][\"code\"]" do
      message =
        LlmError.format_failure(%ApiRequest{
          status: 500,
          response_body: %{"error" => %{"code" => 500, "message" => "boom"}}
        })

      assert message =~ "HTTP 500"
      assert message =~ "code 500"
      assert message =~ "boom"
    end

    test "the provider code falls back to the provider_code field" do
      message =
        LlmError.format_failure(%ApiRequest{status: 400, provider_code: "invalid_request"})

      assert message =~ "code invalid_request"
    end

    test "the human message falls back to error.reason" do
      message = LlmError.format_failure(%ApiRequest{status: 400, reason: "some reason"})

      assert message =~ "some reason"
    end

    test "a request with no extractable detail still renders a usable line" do
      message = LlmError.format_failure(%ApiRequest{status: 400})

      assert String.starts_with?(message, "Provider rejected the LLM request")
      assert message =~ "(HTTP 400)"
      assert message =~ "no further details provided"
      assert message =~ "non-retryable"
    end

    test "the parenthetical is omitted when the request carries no metadata" do
      message = LlmError.format_failure(%ApiRequest{status: nil, retryable: false})

      assert String.starts_with?(message, "Provider rejected the LLM request:")
      refute message =~ "()"
    end
  end

  describe "format_failure/1 — hostile inputs never raise" do
    test "no API request found → a bounded inspect summary plus the remediation" do
      message = LlmError.format_failure(nil)

      assert String.starts_with?(
               message,
               "The LLM request was rejected with a non-retryable error"
             )

      assert message =~ "nil"
      assert message =~ "non-retryable"
    end

    test "every hostile term yields a single-line String" do
      hostile = [
        nil,
        :boom,
        "plain string",
        [1, 2, 3],
        [cause: :ignored],
        %{a: %{b: %{c: [1, 2]}}},
        %{cause: "with\nnewline"},
        {:error, :timeout},
        finch_transport_error(),
        %ApiStream{cause: nil},
        # Stand-in for a "cyclic" map: a cause chain far deeper than any bound.
        Enum.reduce(1..250, :leaf, fn _, acc -> %{cause: acc} end)
      ]

      for reason <- hostile do
        message = LlmError.format_failure(reason)

        assert is_binary(message), "expected a String for #{inspect(reason, limit: 5)}"

        refute String.contains?(message, "\n"),
               "expected a single line for #{inspect(reason, limit: 5)}"
      end
    end

    test "an unusable cause chain still returns a String (no raise, no hang)" do
      deep = Enum.reduce(1..500, zai_rejection(), fn _, acc -> %{cause: acc} end)

      # The request is unreachable (past the bound), so the fallback path runs.
      message = LlmError.format_failure(deep)

      assert is_binary(message)
      assert message =~ "non-retryable"
    end
  end
end
