defmodule EvoDash.TaskRegistry.Diagnostics do
  @moduledoc """
  Failed-transition diagnostic logging functions for `EvoDash.TaskRegistry`.

  When a task transitions to `:failed` from an unexpected path, it's hard to
  determine which code path triggered it. Every site that can set a task to
  `:failed` calls `log_failed_transition/4` with a consistent, greppable prefix
  (`"TaskRegistry: FAILED_TRANSITION"`) so occurrences can be diagnosed.

  These are pure Logger/Process.info functions with no GenServer state dependency.
  """

  require Logger

  @failed_transition_prefix "TaskRegistry: FAILED_TRANSITION"

  @doc """
  Logs a consistent, greppable warning whenever a task transitions to `:failed`.

  ## Parameters
    - `task_id`     — the task being marked failed
    - `source`      — an atom identifying the code path (e.g. `:result_handler`,
                      `:down_handler`, `:reconcile`, `:task_status_pubsub`,
                      `:update_status_cast`)
    - `prev_status` — the status BEFORE transitioning to `:failed` (may be `nil`
                      if the task couldn't be found)
    - `opts`        — keyword list of extra context:
        * `:result`       — the result/reason value, if any
        * `:extra`        — a keyword list of additional diagnostic fields
        * `:caller_info`  — `{pid, stacktrace}` captured at the call site (for
                            cast-based transitions via `update_task_status/4`)

  The log captures a short stacktrace of the CURRENT process at the point of
  transition, so the user can see WHO triggered it. For cast-based transitions
  (where the actual setter is the GenServer, not the original caller), the
  caller's pid + stacktrace are included via `caller_info`.
  """
  def log_failed_transition(task_id, source, prev_status, opts) do
    result = Keyword.get(opts, :result)
    extra = Keyword.get(opts, :extra, [])
    caller_info = Keyword.get(opts, :caller_info)

    # Current stacktrace (the GenServer process for most paths).
    stacktrace = format_stacktrace(capture_stacktrace(5))

    # Caller info (captured in the caller's process for cast-based transitions).
    caller_str =
      case caller_info do
        {caller_pid, caller_stack} when is_pid(caller_pid) ->
          "caller_pid=#{inspect(caller_pid)} caller_stack=\n#{format_stacktrace(caller_stack)}"

        _ ->
          "caller_pid=N/A (same-process transition)"
      end

    extra_str =
      case extra do
        [] -> ""
        fields -> " " <> Enum.map_join(fields, " ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
      end

    Logger.warning(
      "#{@failed_transition_prefix} task_id=#{task_id} source=#{source} " <>
        "prev_status=#{inspect(prev_status)} result=#{inspect(result)}#{extra_str}\n" <>
        "  current_stacktrace=\n#{stacktrace}\n" <>
        "  #{caller_str}"
    )
  end

  @doc """
  Captures up to `n` frames of the current process stacktrace, skipping the
  internal logging helper frames (`capture_stacktrace`/`log_failed_transition`) so
  the first visible frame is the actual handler that triggered the transition.
  GenServer dispatch frames are also skipped. Returns a list of stacktrace
  entries.
  """
  def capture_stacktrace(n) do
    {:current_stacktrace, trace} = Process.info(self(), :current_stacktrace)

    trace
    |> Enum.drop_while(fn
      {Process, :info, _, _} ->
        true

      {mod, fun, _, _}
      when mod == __MODULE__ and fun in [:capture_stacktrace, :log_failed_transition] ->
        true

      {:gen_server, _, _, _} ->
        true

      _ ->
        false
    end)
    |> Enum.take(n)
  end

  @doc """
  Formats a stacktrace (list of `{module, function, arity_or_file_info, location}`)
  into a readable, indented string, one frame per line.
  """
  def format_stacktrace([]), do: "  (no stacktrace available)"

  def format_stacktrace(trace) do
    Enum.map_join(trace, "\n", fn frame ->
      "    #{format_stacktrace_frame(frame)}"
    end)
  end

  def format_stacktrace_frame({module, function, arity, location}) do
    loc = format_location(location)
    fun = format_function(function, arity)
    "#{inspect(module)}.#{fun}#{loc}"
  end

  def format_stacktrace_frame(other), do: "    #{inspect(other)}"

  def format_function(name, arity) when is_atom(name) and is_integer(arity),
    do: "#{name}/#{arity}"

  def format_function(name, args) when is_atom(name) and is_list(args),
    do: "#{name}(#{length(args)})"

  def format_function(other, _), do: inspect(other)

  def format_location([{file, line} | _]) when is_list(file) and is_integer(line),
    do: " at #{List.to_string(file)}:#{line}"

  def format_location(_), do: ""
end
