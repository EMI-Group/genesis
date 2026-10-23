defmodule EvoGit.Agent.ToolInvocation do
  @moduledoc """
  Pure preparation helpers for a SINGLE tool call at the dispatch boundary
  (`EvoGit.Agent.ToolDispatch`): the tolerant arguments parse and the per-call
  timeout rule.

  ## Tolerant arguments parse (three stages)

  `ReqLLM.ToolCall.args_map/1` returns `nil` when the argument JSON does not
  decode (a truncated stream, a model emitting prose instead of JSON, …). A nil
  reaching `EvoGit.Agent.Tools.execute/5` used to raise `FunctionClauseError`
  inside a LINKED `Task.async` and kill the whole agent. `arguments/1` never
  lets that shape through:

    1. decoded JSON object → passed to the tool layer as a map (the normal case);
    2. non-blank but UNPARSEABLE raw arguments → the RAW STRING is passed through,
       so the tool layer decides/reports (it already has a `is_binary(args)`
       clause that answers with a self-correcting error string);
    3. nothing recoverable (missing/blank/null arguments, or a call that is not a
       `%ReqLLM.ToolCall{}` at all — a plain map, nil, an RPC-decoded term) →
       `{:error, reason}`, which the caller renders as the standard
       `Error: invalid arguments: <reason>` tool result so the model can
       self-correct on the next turn.

  The call SHAPE is checked before any `ReqLLM.ToolCall.*` accessor runs: those
  accessors are struct-only, so a non-struct call takes stage 3 instead of
  raising `FunctionClauseError`.
  ## Per-call timeout

  `resolve_timeout/4` centralizes the timeout rule so an omitted `timeout` means
  the same thing everywhere:

    * an explicit positive integer `timeout` argument → used, clamped by the
      configured `max_tool_timeout`;
    * the platform shell tool (`bash`, `run_bash`, `run_powershell`, `pwsh`,
      `shell`, `sh`, …) with NO explicit timeout → at least
      `@shell_default_timeout_ms` (120 s), clamped by `max_tool_timeout`. The
      shell schema advertises a long timeout, and a long test run that omits the
      argument must not be cut at the generic 10 s default;
    * every other tool with no explicit timeout → the configured
      `[:scheduler, :default_tool_timeout]`.
  """

  # Generous default for the platform shell tool when the model omits `timeout`
  # (mirrors the reference harness); still clamped by `[:scheduler,
  # :max_tool_timeout]` at the dispatch site.
  @shell_default_timeout_ms 120_000

  # Every spelling of the platform shell tool: the canonical `bash` plus the
  # legacy/per-platform names. The execute-time alias normalization inside
  # `EvoGit.Agent.Tools` rewrites a subset of these before dispatch, but that
  # table is owned by `tools.ex`, so this set is deliberately self-contained and
  # matched case-insensitively: the timeout rule must not depend on the name
  # having been normalized yet (it is resolved from the RAW tool-call name).
  @shell_tool_names ~w(
    bash run_bash run_powershell pwsh powershell shell sh execute_bash
    bash_command run_shell shell_command
  )

  @doc """
  Tolerant three-stage parse of one tool call's arguments (see the moduledoc).

  Returns `{:ok, args}` where `args` is a decoded map OR the raw argument
  string, and `{:error, reason}` when nothing usable could be recovered — which
  includes any call that is not a `%ReqLLM.ToolCall{}`.

  TOTAL: never raises.
  """
  @spec arguments(term()) :: {:ok, map() | String.t()} | {:error, String.t()}
  def arguments(call) do
    case decoded_args(call) do
      {:ok, args} when is_map(args) -> {:ok, args}
      _not_decodable -> raw_arguments(raw_args_json(call))
    end
  end

  @doc """
  The decoded arguments as a map, or `%{}` when they cannot be decoded.

  TOTAL by design: the hint/telemetry helpers downstream of tool execution are
  map-only (`Map.get/3`), and the tolerant parse may legitimately hand a raw
  STRING to the tool layer — they must never see a non-map. A call that is not a
  `%ReqLLM.ToolCall{}` is undecodable by definition and yields `%{}`.
  """
  @spec arguments_map(term()) :: map()
  def arguments_map(call) do
    case decoded_args(call) do
      {:ok, args} when is_map(args) -> args
      _not_decodable -> %{}
    end
  end

  @doc """
  Renders the standard tool-result string for unusable arguments.
  """
  @spec invalid_arguments_result(String.t()) :: String.t()
  def invalid_arguments_result(reason) when is_binary(reason) do
    "Error: invalid arguments: #{reason}"
  end

  @doc """
  Resolves the per-call timeout (ms) for one tool call.

  `args` may be anything the tolerant parse produced (a map, a raw string, nil) —
  only a map can carry a `timeout`. A non-integer / non-positive `timeout`
  argument is treated as absent rather than crashing the dispatch.
  `configured_default` is `[:scheduler, :default_tool_timeout]`,
  `max_timeout` is `[:scheduler, :max_tool_timeout]`.
  """
  @spec resolve_timeout(term(), term(), pos_integer(), non_neg_integer()) :: non_neg_integer()
  def resolve_timeout(name, args, configured_default, max_timeout)
      when is_integer(configured_default) and is_integer(max_timeout) do
    case explicit_timeout(args) do
      {:ok, timeout} ->
        min(timeout, max_timeout)

      :none ->
        default_timeout(name, configured_default) |> min(max_timeout)
    end
  end

  @doc """
  The timeout (ms) used when the model supplied no explicit `timeout`: the
  generous shell default for the platform shell tool (never LOWER than the
  configured default), otherwise the configured default.
  """
  @spec default_timeout(term(), non_neg_integer()) :: non_neg_integer()
  def default_timeout(name, configured_default) when is_integer(configured_default) do
    if shell_tool?(name),
      do: max(@shell_default_timeout_ms, configured_default),
      else: configured_default
  end

  @doc """
  True when `name` is any spelling of the platform shell tool.
  """
  @spec shell_tool?(term()) :: boolean()
  def shell_tool?(name) when is_binary(name) do
    String.downcase(name) in @shell_tool_names
  end

  def shell_tool?(_name), do: false

  # The declared `timeout` tool argument, when it is a usable positive integer.
  defp explicit_timeout(args) when is_map(args) do
    case Map.get(args, "timeout") do
      timeout when is_integer(timeout) and timeout > 0 -> {:ok, timeout}
      _absent_or_invalid -> :none
    end
  end

  defp explicit_timeout(_args), do: :none

  # The `ReqLLM.ToolCall.*` accessors are struct-only (they match
  # `%ReqLLM.ToolCall{function: %{arguments: _}}`). The call shape is verified
  # BEFORE either of them is touched, so an unexpected call shape (a plain map, a
  # nil, an RPC-decoded term, a struct with no `function`) degrades to the
  # "nothing recoverable" stage instead of raising `FunctionClauseError` and
  # crashing the agent.
  defp decoded_args(%ReqLLM.ToolCall{function: %{arguments: _}} = call),
    do: {:ok, ReqLLM.ToolCall.args_map(call)}

  defp decoded_args(_not_a_tool_call), do: :undecodable

  defp raw_args_json(%ReqLLM.ToolCall{function: %{arguments: _}} = call),
    do: ReqLLM.ToolCall.args_json(call)

  defp raw_args_json(_not_a_tool_call), do: nil

  # Stage 2: a non-blank raw string is handed to the tool layer as-is.
  defp raw_arguments(raw) when is_binary(raw) do
    if String.trim(raw) == "" do
      {:error, "the tool call carried no arguments"}
    else
      {:ok, raw}
    end
  end

  # Stage 3: nothing recoverable.
  defp raw_arguments(_raw), do: {:error, "the arguments could not be decoded as JSON"}
end
