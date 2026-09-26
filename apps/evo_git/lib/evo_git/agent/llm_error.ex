defmodule EvoGit.Agent.LlmError do
  @moduledoc """
  Fail-fast classification of NON-RETRYABLE LLM provider errors.

  A provider rejection that is deterministic — e.g. HTTP 400 carrying Z.AI
  provider code 1210 "Invalid API parameter" — cannot succeed on a retry: the
  same request fails identically every time. Running it through the outer retry
  loop's backoff schedule burns the whole attempt budget (default 15 retries,
  ~9 minutes of sleeps) and THEN raises a bare `RuntimeError`, which the
  scheduler crash-retries — repeating the entire cycle with no actionable error
  ever surfaced. Instead the loop fails fast with
  `{:error, {:llm_request_rejected, message}}` (see
  `EvoGit.Agent.ToolDispatch.handle_llm_failure/7`), which the runtime returns to
  the task wrapper and persists as a `:failed` task whose structured `error`
  record carries the actionable message built by `format_failure/1`.

  ## Where the classification comes from

  ReqLLM reports provider failures as a `%ReqLLM.Error.API.Request{}` — the only
  struct carrying the typed `:status`, `:provider_code`, `:response_body` and
  `:retryable` fields. Inside a streaming call that struct usually arrives
  WRAPPED: `%ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Request{}}`,
  itself often inside a `{:error, reason}` tuple. The private unwrapper peels
  those layers (the `:error` / `:exit` / `:throw` / `:shutdown` /
  `:http_task_failed` tuple tags, an `API.Stream` `:cause`, a nested
  `API.Request` `:cause`, and a plain map/keyword carrying `:cause`) to reach
  it, bounded by a small depth so a cause cycle can never loop forever.

  ## Classification rule (applied to the unwrapped `API.Request`)

    * `retryable == true` → RETRYABLE (an explicit provider signal wins);
    * an integer status of `408`, `409`, `425`, `429` or `500..599` → RETRYABLE
      (the same status set `ReqLLM.Streaming.Failure.retryable_status?/1` uses);
    * an integer status in `400..499` (other than the above) → NON-RETRYABLE
      (a deterministic client/request rejection);
    * `retryable == false` with no/another status → NON-RETRYABLE;
    * no `API.Request` found, or no signal at all → NOT non-retryable, so the
      existing retry behaviour is preserved for anything unrecognized.

  ## Model-exhaustion precedence

  A model-exhaustion signal
  (`EvoGit.Agent.TruncationFeedback.classify_model_exhaustion/1` →
  `:insufficient_balance`, e.g. HTTP 402, or `:rate_limit`, e.g. HTTP 429)
  always keeps its long scheduler-side backoff path. `non_retryable?/1`
  therefore returns `false` for every such reason, and
  `ToolDispatch.handle_llm_failure/7` orders its model-exhaustion branch BEFORE
  the fail-fast branch — so the precedence holds whichever entry point is used.

  Every function here is pure and TOTAL: it never raises for any input (nil,
  strings, maps, cycles, arbitrary terms) and never touches the network, the
  scheduler or the process dictionary.
  """

  alias EvoGit.Agent.TruncationFeedback

  # Maximum number of wrapper layers peeled while looking for the API request.
  @max_unwrap_depth 5

  # The tuple tags a failed attempt may be wrapped in — mirrors
  # `ReqLLM.Streaming.Failure.classify/1`.
  @wrapper_tags [:error, :exit, :throw, :shutdown, :http_task_failed]

  # The one-line remediation `format_failure/1` always appends.
  @remediation "This error is non-retryable — the request will fail again until the model profile / request parameters (model id, temperature, tools) are fixed."

  @doc """
  Whether `reason` is a NON-RETRYABLE LLM provider rejection.

  Unwraps `reason` (see the module doc) to find the
  `%ReqLLM.Error.API.Request{}` and applies the classification rule; returns
  `false` when no API request is found, when it carries no non-retryable
  signal, or when the reason is a model-exhaustion signal (402 / 429 / a quota
  phrase) — those keep the existing long backoff.

  Total: never raises for any input shape.
  """
  @spec non_retryable?(term()) :: boolean()
  def non_retryable?(reason) do
    case find_api_request(reason, 0) do
      {:ok, %ReqLLM.Error.API.Request{} = request} ->
        TruncationFeedback.classify_model_exhaustion(reason) == nil and
          classify(request) == :non_retryable

      :not_found ->
        false
    end
  end

  @doc """
  A clear, actionable ONE-LINE message describing a non-retryable rejection.

  Everything is extracted DEFENSIVELY from the unwrapped
  `%ReqLLM.Error.API.Request{}` — a missing/oddly-typed field is simply omitted
  from the message instead of raising. Extracted fields:

    * **status** — `error.status` (rendered `HTTP 400`);
    * **provider code** — `response_body["metadata"]["provider_error_code"]`,
      then `response_body["error"]["code"]`, then the `provider_code` field;
    * **provider name** — `response_body["metadata"]["provider_name"]`;
    * **human message** — a `Jason.decode/1` of `response_body["metadata"]["raw"]`
      read as `["error"]["message"]` (falling back to the raw string verbatim
      when it is not valid JSON), then `response_body["error"]["message"]`, then
      `response_body["message"]`, then `error.reason`.

  Atom-keyed and string-keyed maps are both handled. A shape that does not
  reach an API request still yields a usable line (a bounded `inspect/1`
  summary plus the remediation). Never raises.

  ## Example (the real Z.AI rejection shape)

      Provider rejected the LLM request (HTTP 400, code 1210, provider Z.AI): \
      Invalid API parameter, please check the documentation. This error is \
      non-retryable — the request will fail again until the model profile / \
      request parameters (model id, temperature, tools) are fixed.
  """
  @spec format_failure(term()) :: String.t()
  def format_failure(reason) do
    case find_api_request(reason, 0) do
      {:ok, %ReqLLM.Error.API.Request{} = request} ->
        "Provider rejected the LLM request" <>
          parenthetical(request) <> ": " <> message(request) <> " " <> @remediation

      :not_found ->
        "The LLM request was rejected with a non-retryable error (" <>
          summarize(reason) <> "). " <> @remediation
    end
  end

  # --- Classification ---

  # Applies the documented rule order: an explicit `retryable` signal first,
  # then the status sets. Anything left over (no status, no boolean) is treated
  # as retryable so the pre-existing behaviour is preserved.
  defp classify(%ReqLLM.Error.API.Request{} = request) do
    cond do
      request.retryable == true -> :retryable
      retryable_status?(request.status) -> :retryable
      non_retryable_status?(request.status) -> :non_retryable
      request.retryable == false -> :non_retryable
      true -> :retryable
    end
  end

  defp retryable_status?(status) when status in [408, 409, 425, 429], do: true
  defp retryable_status?(status) when is_integer(status) and status in 500..599, do: true
  defp retryable_status?(_status), do: false

  defp non_retryable_status?(status) when is_integer(status) and status in 400..499, do: true
  defp non_retryable_status?(_status), do: false

  # --- Wrapper unwrapping (bounded depth: a cause cycle can never hang) ---

  defp find_api_request(reason, depth) when depth < @max_unwrap_depth do
    cond do
      is_struct(reason, ReqLLM.Error.API.Request) ->
        find_in_request(reason, depth)

      is_struct(reason, ReqLLM.Error.API.Stream) ->
        find_api_request(Map.get(reason, :cause), depth + 1)

      wrapper_tuple?(reason) ->
        find_api_request(elem(reason, 1), depth + 1)

      true ->
        case map_cause(reason) do
          {:ok, cause} -> find_api_request(cause, depth + 1)
          :error -> :not_found
        end
    end
  end

  defp find_api_request(_reason, _depth), do: :not_found

  # An API request carrying a real status is the authoritative error; one with
  # no status but a cause wraps the real failure (mirrors
  # `ReqLLM.Streaming.Failure.classify/1`).
  defp find_in_request(%ReqLLM.Error.API.Request{status: status} = request, _depth)
       when is_integer(status),
       do: {:ok, request}

  defp find_in_request(%ReqLLM.Error.API.Request{cause: cause}, depth) when not is_nil(cause),
    do: find_api_request(cause, depth + 1)

  defp find_in_request(%ReqLLM.Error.API.Request{} = request, _depth), do: {:ok, request}

  defp wrapper_tuple?(reason) do
    is_tuple(reason) and tuple_size(reason) == 2 and elem(reason, 0) in @wrapper_tags
  end

  # A plain map (or keyword list) carrying a `:cause`/`"cause"` key wraps the
  # real failure; anything else is not a wrapper.
  defp map_cause(reason) when is_map(reason) do
    case fetch_key(reason, :cause) do
      nil -> :error
      cause -> {:ok, cause}
    end
  end

  defp map_cause(reason) when is_list(reason) do
    if Keyword.keyword?(reason) do
      case Keyword.get(reason, :cause) do
        nil -> :error
        cause -> {:ok, cause}
      end
    else
      :error
    end
  end

  defp map_cause(_reason), do: :error

  # --- Message extraction (defensive, atom- OR string-keyed containers) ---

  # " (HTTP 400, code 1210, provider Z.AI)" — only the parts actually present.
  defp parenthetical(%ReqLLM.Error.API.Request{} = request) do
    case [
           status_label(request.status),
           code_label(request),
           provider_label(request)
         ]
         |> Enum.reject(&is_nil/1) do
      [] -> ""
      parts -> " (" <> Enum.join(parts, ", ") <> ")"
    end
  end

  defp status_label(status) when is_integer(status), do: "HTTP #{status}"
  defp status_label(_status), do: nil

  defp code_label(%ReqLLM.Error.API.Request{} = request) do
    code =
      value_at(request.response_body, ["metadata", "provider_error_code"]) ||
        value_at(request.response_body, ["error", "code"]) ||
        request.provider_code

    case label(code) do
      nil -> nil
      label -> "code #{label}"
    end
  end

  defp provider_label(%ReqLLM.Error.API.Request{} = request) do
    case text(value_at(request.response_body, ["metadata", "provider_name"])) do
      nil -> nil
      name -> "provider #{name}"
    end
  end

  defp message(%ReqLLM.Error.API.Request{} = request) do
    raw_message(request.response_body) ||
      text_at(request.response_body, ["error", "message"]) ||
      text_at(request.response_body, ["message"]) ||
      text(request.reason) ||
      "no further details provided"
  end

  # The provider's own human message, read from the `metadata.raw` JSON payload
  # when the provider nested it there (Z.AI / OpenRouter style): decode and take
  # `["error"]["message"]`; when `raw` is not valid JSON, use it verbatim.
  defp raw_message(response_body) do
    case value_at(response_body, ["metadata", "raw"]) do
      raw when is_binary(raw) ->
        case Jason.decode(raw) do
          {:ok, decoded} -> text_at(decoded, ["error", "message"]) || text(raw)
          {:error, _reason} -> text(raw)
        end

      _other ->
        nil
    end
  end

  defp text_at(container, keys), do: container |> value_at(keys) |> text()

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  # Renders a provider code / identifier defensively: binaries verbatim,
  # integers and atoms stringified, everything else omitted.
  defp label(value) when is_binary(value) and value != "", do: value
  defp label(value) when is_integer(value), do: Integer.to_string(value)
  defp label(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp label(_value), do: nil

  # `value_at(container, [key, ...])` walks nested maps/keyword lists, accepting
  # atom OR string keys; any non-container in the middle ends the walk with nil.
  defp value_at(container, []), do: container
  defp value_at(container, [key | rest]), do: container |> fetch_key(key) |> value_at(rest)

  defp fetch_key(container, key) when is_map(container) do
    case Map.fetch(container, key) do
      {:ok, value} -> value
      :error -> Map.get(container, string_key(key))
    end
  end

  defp fetch_key(container, key) when is_list(container) do
    if is_atom(key) and Keyword.keyword?(container), do: Keyword.get(container, key)
  end

  defp fetch_key(_container, _key), do: nil

  defp string_key(key) when is_binary(key), do: key
  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key), do: key

  # Bounded, single-line rendering of an arbitrary term for the rare fallback
  # path (no API request found): `inspect/1` never raises for any term.
  defp summarize(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 400)
    |> String.replace(~r/\s+/, " ")
  end
end
