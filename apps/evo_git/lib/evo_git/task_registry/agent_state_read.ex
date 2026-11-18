defmodule EvoGit.TaskRegistry.AgentStateRead do
  @moduledoc """
  Deadline-bounded, failure-isolated reads of the durable agent-state store
  (`EvoGit.AgentState`, the SEPARATE `agent_state.sqlite` database) for the
  LIFE-CRITICAL processes that must never block on it.

  Three callers qualify, and all call this module rather than
  `EvoGit.AgentState` directly:

    * `EvoGit.TaskRegistry` — pause/restart classification
      (`EvoGit.TaskRegistry.Pause.dirty_pausable?/1`,
      `pause_kind_for_restart/1,2`), resume admission and the ROOT run's
      `pause_commit` a resume hands to the scheduler;
    * `EvoGit.AgentScheduler.Dispatch` — the pause-resume worktree base, only
      on the direct-dispatch fallback (`spec.opts[:pause_commit]` absent);
    * `EvoGit.AgentScheduler.init/1` — the boot seed of `next_agent_id`
      (`max_agent_id/1`): agent ids must stay stable across a BEAM restart, so
      the in-memory counter starts above every id the durable store already
      holds. `EvoGit.TaskSupervisor` is started BEFORE the scheduler inside
      `EvoGit.AgentGroupSupervisor` (one `one_for_all` group), so the offload
      normally has a supervisor; a scheduler started on its own (an isolated
      test) degrades to `0` — boot is never blocked or crashed by the read.

  `EvoGit.AgentState` reads run in the CALLING process against the store's
  dynamic repo pid (see `EvoGit.AgentState.load/3`), so a busy/locked/slow
  database blocks whoever calls. In a `GenServer` that is the registry or the
  scheduler — and with it every dashboard call the process serves. `read/3`
  therefore runs the read in a `Task.Supervisor.async_nolink/2` child of
  `EvoGit.TaskSupervisor` and waits at most `:timeout` (default
  `#{5_000}` ms; the dispatch fallback passes 2 s), answering the caller's
  DOCUMENTED degraded value on any expiry, crash or absent supervisor.
  Total: it never raises, never exits and never double-replies.

  ## Degraded values are the store's own empty shapes

  | Function | Degraded value | Consequence |
  |---|---|---|
  | `root_agent_ids/2` | `[]` | resume/pause refuses with `:not_resumable` |
  | `resumable?/2` | `false` | a restart classifies as NON-resumable (`:failed`) |
  | `pause_commit/3` | `nil` | the worktree falls back to the task base |
  | `max_agent_id/1` | `0` | the scheduler seeds `next_agent_id` with `1` |

  An unprovable "resumable" is answered `false` on purpose: a resume that
  cannot prove durable state must not pretend, exactly like the honest-barrier
  rule for `EvoGit.AgentState.flush/1`.

  ## The target is resolved in the CALLER

  `EvoGit.AgentState.server/0` honours the `:evogit_agent_state_server`
  process-dictionary test seam, and a spawned task does NOT inherit the
  caller's process dictionary. Every read here therefore resolves the store in
  the CALLER process and passes it to the worker explicitly (`store: store`),
  so an isolated test instance stays isolated and a missing store degrades
  immediately without spawning anything.

  An explicit `:store` option overrides that resolution (a pid, or `nil` for
  "no store at all"). It exists for a caller whose process dictionary cannot be
  pinned — `EvoGit.AgentScheduler.init/1` runs in the scheduler's OWN process,
  so its boot seed is pointed at an isolated instance through the scheduler's
  `:agent_state_store` init option instead of the seam.
  """

  require Logger

  @supervisor EvoGit.TaskSupervisor
  @default_timeout 5_000

  @doc """
  The task's ROOT run ids (`parent_id IS NULL`), ascending. `[]` when the read
  cannot be answered within its budget.
  """
  @spec root_agent_ids(EvoGit.AgentState.task_id(), keyword()) :: [pos_integer()]
  def root_agent_ids(task_id, opts \\ []) do
    read(&EvoGit.AgentState.root_agent_ids(task_id, store: &1), [], opts)
  end

  @doc """
  Whether the task has ANY durable run row. `false` when the read cannot be
  answered within its budget.
  """
  @spec resumable?(EvoGit.AgentState.task_id(), keyword()) :: boolean()
  def resumable?(task_id, opts \\ []) do
    read(&EvoGit.AgentState.resumable?(task_id, store: &1), false, opts)
  end

  @doc """
  One run's persisted `pause_commit` sha, or `nil` — including when the read
  cannot be answered within its budget.
  """
  @spec pause_commit(EvoGit.AgentState.task_id(), integer(), keyword()) :: String.t() | nil
  def pause_commit(task_id, agent_id, opts \\ []) do
    read(&EvoGit.AgentState.pause_commit(task_id, agent_id, store: &1), nil, opts)
  end

  @doc """
  The largest `agent_id` any durable run row holds, or `0` — including when the
  read cannot be answered within its budget (the scheduler then seeds
  `next_agent_id` with `1`).

  Defaults to a 2 s budget: this read is made from `EvoGit.AgentScheduler.init/1`,
  where every extra millisecond delays the whole scheduler (and the dashboard
  behind it), so it is held tighter than the registry's 5 s default.
  """
  @spec max_agent_id(keyword()) :: non_neg_integer()
  def max_agent_id(opts \\ []) do
    opts = Keyword.put_new(opts, :timeout, 2_000)
    read(&EvoGit.AgentState.max_agent_id(store: &1), 0, opts)
  end

  # ONE bounded offload for every read. `fun` receives the store pid
  # resolved in THIS process (see the moduledoc).
  defp read(fun, degraded, opts) when is_function(fun, 1) do
    case resolve_store(opts) do
      store when is_pid(store) -> offload(fun, store, degraded, opts)
      _none -> degraded
    end
  end

  # An explicit `:store` wins — `nil` included, meaning "no store" (an isolated
  # caller that must NOT fall back to the app-global instance).
  defp resolve_store(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> store
      :error -> EvoGit.AgentState.server()
    end
  end

  defp offload(fun, store, degraded, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    op = Keyword.get(opts, :op, "agent-state")
    task = spawn_read(fun, store)
    await(task, timeout, op, degraded)
  catch
    # A supervisor that died between the lookup and the spawn: the read is
    # simply not answerable, which is the documented degrade path.
    :exit, reason ->
      degrade(Keyword.get(opts, :op, "agent-state"), degraded, {:exit, reason})
  end

  # A spawn that exits (no `EvoGit.TaskSupervisor`, a dead name) is contained by
  # the caller's `catch`; a live task is settled by `await/4`.
  defp spawn_read(fun, store),
    do: Task.Supervisor.async_nolink(@supervisor, fn -> fun.(store) end)

  defp await(task, timeout, op, degraded) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> value
      {:exit, reason} -> degrade(op, degraded, {:exit, reason})
      nil -> degrade(op, degraded, :timeout)
    end
  end

  defp degrade(op, degraded, reason) do
    Logger.warning(
      "EvoGit.AgentStateRead: #{op} read degraded (#{inspect(reason)}); " <>
        "answering the store's empty value so no life-critical process waits"
    )

    degraded
  end
end
