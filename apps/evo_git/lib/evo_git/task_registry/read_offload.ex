defmodule EvoGit.TaskRegistry.ReadOffload do
  @moduledoc """
  Failure-isolated, deadline-bounded offload of a heavy `EvoGit.Store` read for
  `EvoGit.TaskRegistry`.

  Every large-decode registry read (`list_tasks`, `list_tasks_paginated`,
  `list_tasks_page`, `get_task_lite`, `list_task_archives`,
  `get_agent_archive`, `list_tasks_summary`, `list_tasks_summary_by_path`,
  `list_tasks_changed_since`) runs HERE instead of in the registry process: the
  worker allocates the decoded term, discards it, and replies to the caller with
  `GenServer.reply/2` itself, so the value never enters the registry's heap —
  not even in transit (the only message the registry receives back is the tiny
  `{ref, :ok}` task result).

  ## Why the registry keeps its own layer

  `EvoGit.Store` already isolates its reads, but it hands the decoded term to
  whoever CALLED it — per read that is the registry. Only a caller-side worker
  keeps the term off the registry heap, and the registry is the GenServer every
  dashboard LiveView and the 60 s heartbeat share.

  ## Shape

  Workers are `Task.Supervisor.async_nolink/2` children of the named
  `EvoGit.TaskRegistry.ReadSupervisor` — a dedicated supervisor, so a read
  worker never dies with an `AgentScheduler`/`EvoGit.TaskSupervisor` restart.
  `async_nolink` (not `Task.start/1`) means a failed START degrades that one
  read instead of raising in the registry.

  Each request is tracked in a `pending` map (`ref => entry`) owned by the
  registry's state; the messages it produces are settled by the owners below:

    * `{ref, :ok}` — the worker's own reply already went straight to the
      caller; nothing to do (the `:DOWN` right behind it settles the entry);
    * `{:DOWN, ref, …, :normal}` — settled: the deadline timer is cancelled;
    * `{:DOWN, ref, …, other}` — the worker died WITHOUT replying, so the
      caller gets the read's degraded value and the fault is logged at `:error`;
    * `{:read_offload_deadline, ref}` — the worker wedged: it is killed
      (`Task.shutdown(…, :brutal_kill)`) so it can never reply with a stale
      value afterwards, and the caller gets the degraded value.

  `@deadline` (28 s) sits between the store's own 25 s read deadline and the
  registry's 30 s `GenServer.call/3` budget, so a caller always receives a
  value — degraded, never an exit — before its own call would time out. The one
  double-reply window is a worker that replies microseconds before its own
  deadline fires; the second reply is an unmatched message to an
  already-answered call (benign).
  """

  require Logger

  alias EvoGit.TaskRegistry.StoreGuard

  @supervisor EvoGit.TaskRegistry.ReadSupervisor
  @deadline 28_000

  @typedoc "In-flight reads, keyed by their worker monitor `ref`."
  @type pending :: %{reference() => entry()}

  @typedoc """
  One in-flight read: the worker (for `Task.shutdown/2`), its deadline timer,
  and what to answer the caller with when the worker cannot.
  """
  @type entry :: %{
          task: Task.t(),
          timer: reference(),
          op: String.t(),
          degraded: term(),
          from: GenServer.from()
        }

  @doc "An empty `pending` map."
  @spec new() :: pending()
  def new, do: %{}

  @doc """
  Starts one offloaded read and returns the updated `pending` map.

  MUST be called from the process that owns `pending` (the registry): the
  deadline timer is addressed to the CALLING process, and the `:DOWN`/result
  messages arrive there too.

  `fun` is the store read; it closes over the caller's bindings before the
  worker runs, and it is wrapped in `EvoGit.TaskRegistry.StoreGuard.read/3`
  inside the worker, so a dead store or an unexpected raise yields `degraded`.

  If the worker cannot even be started (the supervisor is down or refuses the
  child, or process/`:system_limit` exhaustion), the caller's `from` is
  answered with `degraded` immediately and only `pending` is logged.
  """
  @spec start(pending(), String.t(), term(), GenServer.from(), (-> term())) :: pending()
  def start(pending, op, degraded, from, fun) when is_binary(op) and is_function(fun, 0) do
    task =
      Task.Supervisor.async_nolink(@supervisor, fn ->
        GenServer.reply(from, StoreGuard.read(op, degraded, fun))
      end)

    timer = Process.send_after(self(), {:read_offload_deadline, task.ref}, @deadline)

    Map.put(pending, task.ref, %{
      task: task,
      timer: timer,
      op: op,
      degraded: degraded,
      from: from
    })
  catch
    # Justified: a worker START failure is the one cross-process call here —
    # `async_nolink/2` EXITS when the supervisor is gone or refuses the child
    # (an exit, which `rescue` cannot catch). Degrading that ONE read is exactly
    # what this layer exists for; letting the exit through would crash the
    # registry.
    kind, reason ->
      Logger.error(
        "TaskRegistry: could not start the read worker for #{op} (#{kind}: #{inspect(reason)}) " <>
          "— replying with the degraded value #{inspect(degraded)}"
      )

      GenServer.reply(from, degraded)
      pending
  end

  @doc "True when `ref` belongs to an in-flight offloaded read."
  @spec offload?(pending(), reference()) :: boolean()
  def offload?(pending, ref), do: Map.has_key?(pending, ref)

  @doc """
  Settles `ref` after its worker exited (`:DOWN`).

  `:normal` means the worker already replied with the real value (the reply is
  its last statement, so a `:normal` exit can only follow it); ANY other reason
  means it died before replying — the caller then gets the read's degraded value
  and the fault is logged at `:error` with the operation name.
  """
  @spec settle_down(pending(), reference(), term()) :: {:settled, pending()} | :unknown
  def settle_down(pending, ref, reason) do
    case Map.pop(pending, ref) do
      {nil, _pending} ->
        :unknown

      {entry, pending} ->
        Process.cancel_timer(entry.timer)

        if reason == :normal do
          :ok
        else
          fail(entry, {:exit, reason})
        end

        {:settled, pending}
    end
  end

  @doc """
  Settles `ref` when its deadline fired: the wedged worker is killed
  (`:brutal_kill`, so it can never reply afterwards with a stale value) and the
  caller gets the read's degraded value.
  """
  @spec settle_deadline(pending(), reference()) :: pending()
  def settle_deadline(pending, ref) do
    case Map.pop(pending, ref) do
      {nil, pending} ->
        pending

      {entry, pending} ->
        Task.shutdown(entry.task, :brutal_kill)
        fail(entry, {:timeout, @deadline})
        pending
    end
  end

  defp fail(entry, reason) do
    Logger.error(
      "TaskRegistry: the read worker for #{entry.op} FAILED (#{inspect(reason)}) — " <>
        "replying with the degraded value #{inspect(entry.degraded)} " <>
        "(the registry stays alive; the store may be restarting)"
    )

    GenServer.reply(entry.from, entry.degraded)
  end
end
