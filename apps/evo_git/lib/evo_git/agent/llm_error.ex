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

  ## Self-diagnosing failures (`format_failure/2`)

  A provider code such as Z.AI's 1210 "Invalid API parameter" names the KIND of
  problem but not the offending field, and the provider's own
  `request_body`/headers are not echoed back — so after the fact nobody can tell
  WHICH parameter Genesis sent was rejected. `format_failure/2` therefore appends
  a self-diagnosing tail to the same actionable line:

    * the **names** (keys only) of the request parameters handed to
      `ReqLLM.stream_text/3` for that call, sorted + de-duplicated, and
    * the **resolved model spec** to check the model profile for.

  Only parameter NAMES and the model spec are rendered — never a value, a
  message/objective/tool-result body, a header or a credential (a model spec
  given as a map is reduced to its `:id`/`:model`/`:provider` identity fields, so
  an `:api_key` inside it can never reach the message). `parameter_names/1` and
  `format_parameter_names/1` expose the same rendering to the request path's
  debug log. `format_failure/1` is the unchanged no-context form.
  """
  alias EvoGit.Agent.TruncationFeedback

  # Maximum number of wrapper layers peeled while looking for the API request.
  @max_unwrap_depth 5

  # The tuple tags a failed attempt may be wrapped in — mirrors
  # `ReqLLM.Streaming.Failure.classify/1`.
  @wrapper_tags [:error, :exit, :throw, :shutdown, :http_task_failed]

  # The one-line remediation `format_failure/1,2` always appends.
  @remediation "This error is non-retryable — the request will fail again until the model profile / request parameters (model id, temperature, tools) are fixed."

  # Bounds keeping the self-diagnosing tail single-line and cheap even for a
  # hostile/generated parameter list: the number of parameter names rendered and
  # the length of one rendered name (the model spec uses the same length bound).
  @max_parameter_names 32
  @max_name_length 200
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
  def format_failure(reason), do: format_failure(reason, [])

  @doc """
  `format_failure/1` plus a self-diagnosing tail naming the request parameters
  Genesis sent and the resolved model spec.

  `request_context` is a keyword list (or map, atom- OR string-keyed) carrying:

    * `:params` — the EXACT keyword list handed to `ReqLLM.stream_text/3` for
      this call (e.g. `Keyword.merge([tools: tools], llm_gen_opts)`); only its
      KEY names are rendered (see `parameter_names/1`);
    * `:model` — the resolved model spec (`ToolDispatch.current_model/0`); a
      binary spec is rendered verbatim, a map/struct is reduced to its
      `:id`/`:model`/`:provider` identity fields only.

  Each part is omitted when absent, so `format_failure(reason, [])` (and
  `format_failure/1`, which delegates here) produce EXACTLY the previous
  message — the tail is purely additive:

      Provider rejected the LLM request (HTTP 400, code 1210, provider Z.AI): \
      Invalid API parameter, please check the documentation. Request parameters \
      sent: [max_tokens, temperature, tools]. Check the model profile for model \
      zai:glm-4.6 and remove parameters the provider does not support. This \
      error is non-retryable — ...

  The result is always a single line: every rendered name is sanitized
  (control/whitespace runs collapsed, length capped) and the name list is
  capped. Nothing but parameter NAMES and the model spec is ever rendered —
  values (which may carry objective/tool-result content or credentials) are
  never inspected. Never raises.
  """
  @spec format_failure(term(), keyword() | map() | nil) :: String.t()
  def format_failure(reason, request_context) do
    base =
      case find_api_request(reason, 0) do
        {:ok, %ReqLLM.Error.API.Request{} = request} ->
          "Provider rejected the LLM request" <>
            parenthetical(request) <> ": " <> message(request)

        :not_found ->
          "The LLM request was rejected with a non-retryable error (" <>
            summarize(reason) <> ")."
      end

    Enum.join([base | diagnostics(request_context)] ++ [@remediation], " ")
  end

  @doc """
  The sorted, de-duplicated NAMES of the parameters in a request keyword list
  (or map) — the "what did Genesis actually send?" diagnostic.

  Names only: values are never read, rendered or inspected. Keys are rendered as
  strings (atoms via `Atom.to_string/1`), sanitized to a single line, and capped
  at #{@max_parameter_names} entries. A `:tools` entry whose value is an empty
  list contributes NOTHING: ReqLLM sends no tools field for an empty list, so
  listing the name would misattribute a provider rejection to a parameter that
  never reached it.

  Total: any non-keyword/non-map input yields `[]`.
  """
  @spec parameter_names(term()) :: [String.t()]
  def parameter_names(params) when is_map(params) do
    params
    |> Enum.reject(fn {key, value} -> key == :__struct__ or empty_tools?({key, value}) end)
    |> Enum.map(fn {key, _value} -> key end)
    |> names()
  end

  def parameter_names(params) when is_list(params) do
    params
    |> Enum.reject(&empty_tools?/1)
    |> Enum.map(fn
      {key, _value} -> key
      key -> key
    end)
    |> names()
  end

  def parameter_names(_params), do: []

  @doc """
  Renders a parameter-name list as `[a, b]` — the ONE formatting site shared by
  the terminal message (`format_failure/2`) and the request-path debug log.
  """
  @spec format_parameter_names([String.t()]) :: String.t()
  def format_parameter_names(names) when is_list(names),
    do: "[" <> Enum.join(names, ", ") <> "]"

  # An empty (or absent) tools list is not a parameter Genesis sends.
  defp empty_tools?({key, value}) when key in [:tools, "tools"], do: value in [nil, []]
  defp empty_tools?(_entry), do: false

  defp names(keys) do
    keys
    |> Enum.map(&name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> cap_names()
  end

  defp name(key) when is_atom(key) and not is_nil(key), do: scalar(Atom.to_string(key))
  defp name(key) when is_binary(key), do: scalar(key)
  defp name(_key), do: nil

  defp cap_names(names) when length(names) <= @max_parameter_names, do: names

  defp cap_names(names) do
    {kept, rest} = Enum.split(names, @max_parameter_names)
    kept ++ ["... #{length(rest)} more"]
  end

  # The self-diagnosing sentences, each omitted when its input is absent.
  defp diagnostics(nil), do: []

  defp diagnostics(request_context) do
    [
      parameter_sentence(parameter_names(fetch_key(request_context, :params))),
      model_sentence(model_label(fetch_key(request_context, :model)))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp parameter_sentence([]), do: nil

  defp parameter_sentence(parameter_names) do
    "Request parameters sent: " <> format_parameter_names(parameter_names) <> "."
  end

  defp model_sentence(nil), do: nil

  defp model_sentence(model) do
    "Check the model profile for model #{model} and remove parameters the " <>
      "provider does not support."
  end

  # Renders a model spec defensively WITHOUT ever leaking a credential: a binary
  # (the normal "provider:model" profile string) verbatim, any other scalar via
  # `label/1`, and a map/struct reduced to its `:id` (or `:model`) plus an
  # optional provider. Arbitrary keys — notably `:api_key`, `:headers`,
  # `:base_url` — are never rendered.
  defp model_label(model) when is_binary(model), do: scalar(model)
  defp model_label(model) when is_atom(model) and not is_nil(model), do: scalar(model)

  defp model_label(model) when is_map(model) do
    id = scalar(fetch_key(model, :id)) || scalar(fetch_key(model, :model))
    provider = scalar(fetch_key(model, :provider))

    case {id, provider} do
      {nil, nil} -> nil
      {id, nil} -> id
      {nil, provider} -> "(provider #{provider})"
      {id, provider} -> "#{id} (provider #{provider})"
    end
  end

  defp model_label(_model), do: nil

  # A displayable SCALAR rendered as a single line. Anything else (maps, lists,
  # structs) yields nil so a value can never be inspected into the message.
  defp scalar(value) do
    case label(value) do
      nil -> nil
      rendered -> sanitize(rendered)
    end
  end

  # Collapses whitespace/control runs and caps the length — guarantees the
  # "single line" property the whole message relies on, even for a hostile key.
  # An empty result is nil (nothing to render).
  defp sanitize(text) do
    case text |> String.replace(~r/[[:cntrl:]\s]+/u, " ") |> String.trim() do
      "" -> nil
      clean -> String.slice(clean, 0, @max_name_length)
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
