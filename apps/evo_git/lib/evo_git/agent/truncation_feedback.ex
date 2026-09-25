defmodule EvoGit.Agent.TruncationFeedback do
  @moduledoc """
  Truncation feedback and LLM error-classification logic extracted from
  `EvoGit.Agent.__using__/1`.

  Classifies LLM error reasons into two **model-exhaustion** classes:

    * `:insufficient_balance` — the provider account is out of credit / quota
      (e.g. HTTP 402, `insufficient_quota`), and
    * `:rate_limit` — the request was throttled (e.g. HTTP 429).

  The class split is informational only: both classes are exhausted-model
  signals and drive the SAME long scheduler-side per-model backoff downstream —
  they are handled identically by the slot/backoff machinery. The helpers here
  are pure and total: they never raise and simply return a boolean (or the
  class atom / `nil`) for any input term.

  Also generates concise truncation warnings when tool output exceeds size
  limits.

  ## Wrap boundary (BINARY-ONLY contract)

  This module is BINARY-ONLY: `append_truncation_feedback/3` takes a string and
  returns a string. It never receives or returns a
  `%EvoGit.Agent.ToolOutput{}` — the wrap/unwrap between a binary and a
  `%ToolOutput{}` happens ONLY inside `EvoGit.Agent.ToolDispatch` (see
  `EvoGit.Agent.ToolOutput` → "Wrap boundary invariant"). `ToolDispatch` calls
  it with `ToolOutput.text/1` and re-attaches the result with
  `ToolOutput.with_text/2`, so media survives the truncation notice.
  """
  # Provider phrases that indicate an out-of-credit / quota-exhaustion response.
  @insufficient_balance_phrases [
    "insufficient balance",
    "insufficient_quota",
    "insufficient_balance",
    "insufficient funds",
    "balance"
  ]

  # Provider error codes (`provider_code`) that indicate the same condition.
  @insufficient_balance_provider_codes [
    "insufficient_quota",
    "insufficient_balance"
  ]

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

  # --- Model Exhaustion Classification ---

  @doc """
  Detects whether an LLM error reason indicates an insufficient-balance /
  out-of-credit condition.

  Returns `true` when the reason is an HTTP 402 API error, carries an
  `insufficient_quota` / `insufficient_balance` provider code, or contains one
  of the known insufficient-balance provider phrases. Non-struct (arbitrary)
  reasons are matched via a string-substring fallback over `inspect/1`.

  Total: never raises and returns `false` for any unrecognized term. A bare
  `"402"` substring is deliberately NOT treated as a match.
  """
  def is_insufficient_balance_error?(reason) do
    structural_insufficient_balance?(reason) or fallback_insufficient_balance?(reason)
  end

  @doc """
  Detects whether an LLM error reason indicates a model-exhaustion condition —
  either `:insufficient_balance` or `:rate_limit`.

  Returns `true` when `classify_model_exhaustion/1` yields a class, else
  `false`.
  """
  def is_model_exhaustion_error?(reason) do
    classify_model_exhaustion(reason) != nil
  end

  @doc """
  Classifies an LLM error reason into a model-exhaustion class.

  Returns:

    * `:insufficient_balance` — when `is_insufficient_balance_error?/1` matches,
      else
    * `:rate_limit` — when `is_rate_limit_error?/1` matches, else
    * `nil`.

  Insufficient balance takes precedence over rate limit. The split is
  informational: both classes drive the SAME long scheduler-side backoff
  downstream.
  """
  def classify_model_exhaustion(reason) do
    cond do
      is_insufficient_balance_error?(reason) -> :insufficient_balance
      is_rate_limit_error?(reason) -> :rate_limit
      true -> nil
    end
  end

  # Structural inspection: only a real `%ReqLLM.Error.API.Request{}` carries the
  # typed `:status` / `:provider_code` / `:reason` / `:response_body` fields.
  defp structural_insufficient_balance?(%ReqLLM.Error.API.Request{} = error) do
    error.status == 402 or
      insufficient_balance_provider_code?(error.provider_code) or
      insufficient_balance_text?(error.reason) or
      insufficient_balance_text?(error.response_body)
  end

  defp structural_insufficient_balance?(_reason), do: false

  defp insufficient_balance_provider_code?(code) when is_binary(code) do
    code in @insufficient_balance_provider_codes
  end

  defp insufficient_balance_provider_code?(code) when is_atom(code) and not is_nil(code) do
    Atom.to_string(code) in @insufficient_balance_provider_codes
  end

  defp insufficient_balance_provider_code?(_code), do: false

  # Only actual binaries get substring checks; other shapes (maps, keywords,
  # nils) are rendered via `inspect/1` so they still resolve a text search.
  defp insufficient_balance_text?(text) when is_binary(text) do
    contains_insufficient_balance_phrase?(text)
  end

  defp insufficient_balance_text?(nil), do: false

  defp insufficient_balance_text?(value) do
    value |> inspect() |> contains_insufficient_balance_phrase?()
  end

  # String-substring fallback over `inspect/1` — mirrors `is_rate_limit_error?/1`
  # and catches arbitrary reason shapes that are not the API-request struct.
  defp fallback_insufficient_balance?(reason) do
    reason |> inspect() |> contains_insufficient_balance_phrase?()
  end

  defp contains_insufficient_balance_phrase?(text) when is_binary(text) do
    lowered = String.downcase(text)
    Enum.any?(@insufficient_balance_phrases, &String.contains?(lowered, &1))
  end

  defp contains_insufficient_balance_phrase?(_text), do: false

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
