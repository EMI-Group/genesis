defmodule EvoGit.Agent.Tools.Boundary do
  @moduledoc """
  The ONE process-boundary guard for tool implementations.

  A tool call routinely crosses process boundaries: the `EvoGit.TaskRegistry`
  GenServer, the VCT server, the agent scheduler and the SQLite store behind
  them. A `GenServer.call/3` to a process that is down, restarting or that has
  already timed out exits the CALLER with `:noproc`/`:timeout` — and that is an
  exit, not a rescue-able exception — while a raise inside a handler would
  otherwise unwind the agent loop.

  `run/2` turns both into a readable error value the LLM can act on (retry,
  report, or pick another tool), so a tool stays total when a dependency is
  unavailable. Only raises, exits and throws are intercepted: the wrapped
  function's own return value (`{:ok, _}`, `{:error, _}`, `:ok`, a struct, …)
  passes through byte-identically.

  The `rescue`/`catch` clauses below are the ONE sanctioned home of that
  pattern; individual tool modules call `run/2`, `run_string/1` or `call/3`
  instead of carrying their own try/catch, so the rationale lives here only.
  """

  @max_reason_length 200

  @doc """
  Calls the zero-arity `fun` and returns its value unchanged.

  A raised exception, an `:exit` or a `:throw` becomes
  `{:error, on_error.(reason)}`, where `reason` is the exception struct for a
  raise and the exit/throw reason otherwise. The default formatter
  (`default_error/1`) renders a short, single-line, human-readable binary.
  """
  @spec run((-> result)) :: result | {:error, String.t()} when result: var
  @spec run((-> result), (term() -> error)) :: result | {:error, error}
        when result: var, error: var
  def run(fun, on_error \\ &default_error/1) when is_function(fun, 0) do
    fun.()
  rescue
    # Justified rescue/catch: this module IS the tool-side process boundary —
    # an unavailable GenServer exits the caller (`:noproc`/`:timeout`) and a
    # raising handler would otherwise crash the agent loop.
    exception -> {:error, on_error.(exception)}
  catch
    :exit, reason -> {:error, on_error.(reason)}
    :throw, reason -> {:error, on_error.(reason)}
  end

  @doc """
  Same guard as `run/2`, but the failure value is a plain error STRING
  (`"Error: …"`) instead of a wrapped term.

  Use this in tools whose result contract is a `String.t()` the LLM reads.
  """
  @spec run_string((-> result)) :: result | {:error, String.t()} when result: var
  def run_string(fun) when is_function(fun, 0) do
    run(fun, fn reason -> "Error: " <> default_error(reason) end)
  end

  @doc """
  Applies `module.function(args)` under the same guard as `run/2`.

  Answers `{:error, message}` — a readable binary — when the call raises or
  exits, which is the failure shape the `EvoGit.TaskRegistry`-backed tools and
  their formatters already consume.
  """
  @spec call(module(), atom(), [term()]) :: {:error, String.t()} | term()
  def call(module, function, args) when is_atom(module) and is_atom(function) and is_list(args) do
    run(fn -> apply(module, function, args) end)
  end

  # --- Error formatting ---

  # The default `on_error` formatter: a raised exception renders its message,
  # every non-exception reason (an exit/throw reason) renders through
  # `format_reason/1` so the common `{:noproc, {GenServer, :call, …}}` case
  # names the unavailable component instead of dumping a raw term.
  defp default_error(reason) do
    if is_exception(reason) do
      Exception.message(reason)
    else
      format_reason(reason)
    end
  end

  defp format_reason({exit_reason, {GenServer, :call, [component | _]}})
       when is_atom(exit_reason) do
    "#{component_name(component)} is unavailable (exit: #{inspect(exit_reason)})"
  end

  defp format_reason(:noproc), do: "the dependency process is not running"
  defp format_reason(:timeout), do: "the dependency call timed out"
  defp format_reason(reason), do: "the dependency call failed: " <> short_inspect(reason)

  defp component_name(component) when is_atom(component), do: inspect(component)
  defp component_name(component), do: "the process #{short_inspect(component)}"

  # Reasons must stay single-line and bounded: they end up inside a tool result
  # the LLM reads, and a raw `GenServer.call/3` trace can carry whole args.
  defp short_inspect(reason) do
    reason
    |> inspect(limit: 20, printable_limit: @max_reason_length)
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, @max_reason_length)
  end
end
