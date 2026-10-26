defmodule EvoDash.SafeCall do
  @moduledoc """
  The single exit-safe boundary for store / registry / cross-node (RPC) calls
  made from a LiveView or from a supervised loader task.

  Every LiveView or spawned-loader call to the task store
  (`EvoGit.TaskRegistry` / `EvoGit.Store`), the scheduler, or an
  `EvoDash.NodeContext` RPC helper goes through this module. Those calls are
  remote in the `GenServer.call` sense: the target process can be dead, busy, or
  simply slower than the call timeout, and a timed-out call EXITS the calling
  process instead of returning an error. Without this boundary a `rescue`-only
  loader crashes the LiveView (or leaves a `loading: true` flag wedged forever,
  because the task died before sending its result message).

  Errors are expected VALUES, not crashes: every call returns `{:ok, value}` or
  `{:error, reason}`, so callers render a retry-able error state.

      case EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.get_task(node, id) end) do
        {:ok, task} -> assign(socket, :task, task)
        {:error, reason} -> assign(socket, :load_error, reason)
      end

  For async loads prefer `start/4`, which runs the same boundary inside
  `EvoDash.TaskSupervisor` and always sends `{tag, result}` back to the caller —
  even on exit, so a loading flag can never stick:

      EvoDash.SafeCall.start(self(), :task_loaded, fn ->
        EvoDash.NodeContext.get_task(node, id)
      end)

  """

  @default_supervisor EvoDash.TaskSupervisor

  @typedoc """
  Outcome of a guarded call: the call's value, or an error reason
  (`{:exit, reason}` / `{:exception, exception}` / `{:throw, reason}` /
  `{:invalid_function, term}`).
  """
  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Runs the 0-arity `fun` and captures every failure mode as a value.

  Returns:

    * `{:ok, value}` when `fun` returns normally;
    * `{:error, {:exit, reason}}` when the call exits — e.g. a
      `GenServer.call` timeout or a call to a dead process;
    * `{:error, {:exception, exception}}` when `fun` raises;
    * `{:error, {kind, reason}}` when `fun` throws (`{:throw, reason}`);
    * `{:error, {:invalid_function, term}}` for a non-0-arity argument.
  """
  @spec run((-> term())) :: result()
  # Deliberate try/rescue/catch boundary (the codebase's explicitly allowed
  # catch-`exit` case): do we expect the error? YES — every caller of this
  # module makes a cross-process store/RPC call whose target GenServer can be
  # dead, busy, or slower than the call timeout, and a `GenServer.call` timeout
  # raises an EXIT (not a rescue-able exception). Is this the cleanest
  # approach? YES — exits cannot be caught by `rescue`, and without this
  # boundary the caller (a LiveView or a supervised loader task) dies, which
  # crashes the page or wedges a `loading` flag forever. This module exists so
  # that conversion happens in exactly one place instead of at every call site.
  def run(fun) when is_function(fun, 0) do
    try do
      {:ok, fun.()}
    rescue
      exception ->
        {:error, {:exception, exception}}
    catch
      :exit, reason ->
        {:error, {:exit, reason}}

      kind, reason ->
        {:error, {kind, reason}}
    end
  end

  def run(other), do: {:error, {:invalid_function, other}}

  @doc """
  Runs the 0-arity `fun` and returns its value, or `fallback` on any error
  (see `run/1` for the captured failure modes).
  """
  @spec run((-> term()), term()) :: term()
  def run(fun, fallback) do
    case run(fun) do
      {:ok, value} -> value
      {:error, _reason} -> fallback
    end
  end

  @doc """
  Starts `fun` in a supervisor and sends `{tag, run(fun)}` to `parent`.

  The result message is ALWAYS sent — including for an exit — so a caller can
  clear its loading state unconditionally. Returns whatever
  `Task.Supervisor.start_child/2` returns (`{:ok, pid} | {:error, reason}`;
  nothing is sent when the child could not be started).

  Options:

    * `:supervisor` — the supervisor to start the child under (a pid or a
      registered name). Defaults to `EvoDash.TaskSupervisor`.
  """
  @spec start(pid() | atom(), term(), (-> term()), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(parent, tag, fun, opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, @default_supervisor)

    Task.Supervisor.start_child(supervisor, fn ->
      send(parent, {tag, run(fun)})
    end)
  end
end
