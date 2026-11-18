defmodule EvoGit.TaskRegistry.Pause do
  @moduledoc """
  Task-level PAUSE / RESUME protocol for `EvoGit.TaskRegistry`.

  A task-level pause winds ONE named task down to a durable, resumable resting
  state (`docs/task-pause.md`): the row becomes `:pausing`, the scheduler flags
  every agent of the task (`EvoGit.AgentScheduler.begin_task_pause/1`), each agent
  stops at its next TURN BOUNDARY (never mid-tool) after checkpointing its
  conversation and committing its worktree, and the wrapper result
  `{:paused, info}` lands the row `:paused` with `pause_kind: :clean`.

  This module owns the VALIDATION and the PERSISTENCE of that protocol; the
  `EvoGit.TaskRegistry` GenServer owns the sequencing (persist THEN broadcast),
  the in-memory `task_refs` bookkeeping and every refusal it must answer with a
  status transition. Every public function here is TOTAL — `:ok |
  {:error, reason}` (or an explicit multi-shape tuple documented per function) —
  and never raises or exits into the registry.

  ## Clean vs dirty

  `pause_kind` (`:clean | :dirty | nil`, the `tasks.pause_kind` column) is the
  ONE persisted discriminator:

    * `:clean` — the user paused the task. Nothing was interrupted, so a resume
      restores the transcript with NO repair and NO "files may be inconsistent"
      wording.
    * `:dirty` — the runtime restarted while the task was live. The agents died
      mid-flight, so a resume runs the existing crash-resume repair plus the
      `[RESUME]` notice. `pause_kind_for_restart/1,2` is the ONE classifier both
      restart paths (`TaskRegistry.init/1` reconciliation and the one-shot
      `:lease_sweep`) use.

  A pause is only possible when durable agent state is available
  (`:persistent_state`, default on), because the paused run is restored from
  `agent_state.sqlite`; without it the task is not resumable and pause is
  REFUSED rather than pretending.

  ## Who writes what

  | Step | Writer |
  |---|---|
  | `status: :pausing` (+ revert on an unavailable scheduler) | this module |
  | scheduler pause marker / per-agent pause flags | `EvoGit.AgentScheduler.begin_task_pause/1` |
  | `status: :paused`, `pause_kind: :clean`, lease cleared | `EvoGit.TaskRegistry.handle_wrapper_result/3` (the wrapper reports `{:paused, info}`) |
  | `status: :paused`, `pause_kind: :dirty`, lease cleared | `TaskRegistry.init/1` and `:lease_sweep` through this module's classifier |
  | `status: :running`, `pause_kind: nil`, fresh lease | `resume/4` |
  | every broadcast | `EvoGit.TaskRegistry` (after the persist) |
  """

  require Logger

  alias EvoGit.TaskRegistry.AgentStateRead
  alias EvoGit.TaskRegistry.StoreGuard

  # The `{:ok, transition}` shapes `pause/2` answers so the caller knows whether a
  # broadcast is due: only a REAL transition (`:pausing`) is broadcast.
  @type pause_result ::
          {:ok, :pausing}
          | {:ok, :already_pausing}
          | {:ok, :already_paused}
          | {:error, term()}

  @type resume_result :: {:ok, term()} | {:error, term()}

  ## Pause

  @doc """
  Requests a task-level pause: validates, persists `status: :pausing`, then flags
  the task's agents through `EvoGit.AgentScheduler.begin_task_pause/1`.

  Refusals, in this order (each leaves the row UNTOUCHED):

    * unknown task → `{:error, :not_found}` (only a genuinely absent row; a row
      whose status cannot be read is never `:not_found`);
    * `:pausing` / `:paused` → `{:ok, :already_pausing} | {:ok, :already_paused}`
      — IDEMPOTENT: no write, no scheduler call, and the caller must not
      broadcast;
    * `:awaiting_input`, or a task whose persisted `:session_mode` is
      `"interactive"` → `{:error, :not_pausable}` (an interactive session has no
      resumable one-shot run, and its lifecycle is user-driven);
    * `:persistent_state` stored as `false` (or as any non-boolean) →
      `{:error, :not_resumable}` (nothing durable to restore; read the RAW value,
      never `RuntimeOpts.persistent_state/1`, which raises);
    * any other status — `:pending` (no wrapper and no agents to drain), the
      terminal set, `:finalizing`, `:cancelling` → `{:error, :not_running}`.

  On a real transition the row is written `:pausing` FIRST and the scheduler is
  asked SECOND, so the drain is visible before any agent can observe the flag. A
  scheduler that is down (or a call that times out/exits) must never leave the
  row stuck in `:pausing`: the status is reverted to `:running` (the only status
  a pause can be requested from) and `{:error, :scheduler_unavailable}` is
  answered. Costs one extra write in the failure case; the alternative — a
  `:pausing` row with no agents to drain — is unrecoverable without a restart.

  The status is read through `EvoGit.Store.select_task_update_info/2` (narrow:
  status + opts, never `result`). An unreadable/NULL status reads as `nil` there
  and falls into the `:not_running` refusal, never `:not_found`.
  """
  @spec pause(pid(), String.t()) :: pause_result()
  def pause(store, task_id) do
    case read_update_info(store, task_id) do
      nil -> {:error, :not_found}
      %{status: status, opts: opts} -> classify(store, task_id, status, opts)
    end
  end

  defp classify(_store, _task_id, :pausing, _opts), do: {:ok, :already_pausing}
  defp classify(_store, _task_id, :paused, _opts), do: {:ok, :already_paused}

  defp classify(_store, _task_id, :awaiting_input, _opts), do: {:error, :not_pausable}

  defp classify(store, task_id, :running, opts) do
    cond do
      interactive?(opts) -> {:error, :not_pausable}
      persistent_state_on?(opts) -> request_pause(store, task_id)
      true -> {:error, :not_resumable}
    end
  end

  defp classify(_store, _task_id, _other, _opts), do: {:error, :not_running}

  defp request_pause(store, task_id) do
    case write_columns(store, task_id, status: :pausing) do
      :ok ->
        case begin_scheduler_pause(task_id) do
          :ok ->
            {:ok, :pausing}

          {:error, _reason} = error ->
            # Best-effort revert: the drain can never complete without a live
            # scheduler, so the row must not stay `:pausing`. A failed revert
            # write is logged by StoreGuard and the caller still gets the error.
            _ = write_columns(store, task_id, status: :running)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  # The scheduler call is a cross-GenServer boundary: a not-started or dead
  # scheduler raises `:exit`, not a rescue-able exception.
  defp begin_scheduler_pause(task_id) do
    :ok = EvoGit.AgentScheduler.begin_task_pause(task_id)
  catch
    :exit, reason ->
      Logger.warning(
        "TaskRegistry: AgentScheduler begin_task_pause failed (exit): #{inspect(reason)}"
      )

      {:error, :scheduler_unavailable}
  end

  ## Resume

  @doc """
  Resumes a PAUSED task IN PLACE: the same task id is re-enqueued with the same
  persisted opts (never a fresh id — `start_task/2` is deliberately not used).

  Accepts `:paused` ONLY: any other status answers `{:error, :not_paused}` and an
  absent row `{:error, :not_found}`.

  On a paused row it re-runs the SAME admission `start_task/2` runs
  (`RuntimeOpts.admit_model_selection/2` against the CURRENT config,
  `admit_session_mode/1`, `admit_persistent_state/1`); a failed admission answers
  that `{:error, reason}` and leaves the row `:paused`. It then requires durable
  run state (`EvoGit.AgentState.root_agent_ids/1 != []`, read BOUNDED through
  `EvoGit.TaskRegistry.AgentStateRead`), because a resume with nothing to
  restore would silently start the objective from scratch — that is
  `{:error, :not_resumable}`.

  The write is TARGETED (`update_task_columns/3`, which always bumps
  `updated_at`): `status: :running`, `finished_at: nil`, `error: nil`,
  `pause_kind: nil` and a FRESH lease; `started_at`, `opts`, `commit_sha`,
  `result`, `usage`, `review_status`, `branch_name` and `base_sha` are NOT
  touched, so the paused run's report and usage survive and usage keeps
  ACCUMULATING across resumes.

  `spawn_opts` are the ADMITTED runtime opts plus `resume_kind: :clean_pause`
  (`pause_kind == :clean`, or `nil` — a legacy/manual row) or
  `:dirty_pause` (`pause_kind == :dirty`). The PERSISTED opts are never mutated:
  the resume kind belongs to this dispatch only, exactly like `:resume_from`.
  `EvoGit.TaskRegistry.RuntimeOpts.build_common_runtime_opts/3` forwards the key
  to the runtime, which turns it into the dispatch ctx `resume_kind` and the
  matching narration (`EvoGit.Agent.Resume`).
  The ROOT run's pause checkpoint is resolved HERE, before the wrapper is
  spawned, and carried as `pause_commit: sha | nil` (see `put_pause_commit/3`):
  `EvoGit.AgentScheduler.Dispatch` bases the resumed worktree on it, and the
  scheduler itself must never make a synchronous durable read. The key is
  always present, so `nil` means "resolved, nothing stored" and an ABSENT key
  means "not a pause resume" (the direct-dispatch path, which falls back to a
  bounded read of its own).

  Sequencing: the scheduler pause marker is cleared FIRST (a re-spawned agent must
  never inherit a stale pause flag through `ControlPlane.ensure_row/1`), the
  wrapper is spawned through `wrapper_spawn_fun` (the registry's call-time seam;
  `nil` = the production `Task.Supervisor.async_nolink/4` call), and only then is
  the row written — mirroring `start_task/2`'s spawn-then-persist order. A failed
  write stops the spawned wrapper (it must never run against a row that is still
  `:paused`) and answers that `{:error, reason}`.

  Returns `{:ok, task_ref}` on a successful re-enqueue.
  """
  @spec resume(pid(), String.t(), atom() | nil, function() | nil) :: resume_result()
  def resume(store, task_id, server, spawn_fun \\ nil) do
    case read_row(store, task_id) do
      nil ->
        {:error, :not_found}

      %{} = task ->
        with :ok <- ensure_paused(task),
             {:ok, spawn_opts} <- admit(task),
             {:ok, root_ids} <- ensure_durable_runs(task_id) do
          requeue(store, task, put_pause_commit(spawn_opts, task_id, root_ids), server, spawn_fun)
        end
    end
  end

  defp ensure_paused(%{status: :paused}), do: :ok
  defp ensure_paused(_task), do: {:error, :not_paused}

  # The SAME admission gate `start_task/2` runs, in the same order. Each returns
  # `{:ok, opts}` / `{:error, reason}` — non-raising by contract.
  defp admit(%{opts: stored}) do
    opts = if is_list(stored), do: stored, else: []

    with {:ok, opts} <-
           EvoGit.TaskRegistry.RuntimeOpts.admit_model_selection(opts, EvoGit.Config.resolve()),
         {:ok, opts} <- EvoGit.TaskRegistry.RuntimeOpts.admit_session_mode(opts),
         {:ok, opts} <- EvoGit.TaskRegistry.RuntimeOpts.admit_persistent_state(opts) do
      {:ok, opts}
    end
  end

  # The durable-run gate: a resume with nothing stored would silently start the
  # objective from scratch. The ROOT ids come back so the resume can also carry
  # the root's PAUSE CHECKPOINT — see `put_pause_commit/3`.
  defp ensure_durable_runs(task_id) do
    case AgentStateRead.root_agent_ids(task_id, op: "root_agent_ids") do
      [] -> {:error, :not_resumable}
      ids -> {:ok, ids}
    end
  end

  # The resumed ROOT run's pause checkpoint, resolved HERE — in the caller of
  # `EvoGit.AgentScheduler.Dispatch`, never inside the scheduler. The dispatch
  # bases the resumed worktree on it (`spec.opts[:pause_commit]`) and must not
  # make a synchronous durable read to find it. The read is bounded and
  # offloaded (`EvoGit.TaskRegistry.AgentStateRead`), and the key is ALWAYS put
  # (as `sha | nil`) so the dispatch can tell "resolved to nothing" from "never
  # resolved" — the latter is the direct-dispatch fallback, which reads the
  # store itself, bounded.
  defp put_pause_commit(spawn_opts, task_id, [root_id | _rest]) do
    sha = AgentStateRead.pause_commit(task_id, root_id, op: "pause_commit")
    Keyword.put(spawn_opts, :pause_commit, sha)
  end

  defp requeue(store, task, spawn_opts, server, spawn_fun) do
    task_id = Map.fetch!(task, :id)
    task_type = Map.get(task, :type)
    spawn_opts = Keyword.put(spawn_opts, :resume_kind, resume_kind(Map.get(task, :pause_kind)))

    # 1. Abandon any leftover scheduler pause state BEFORE the new run can
    #    register an agent (see the @doc sequencing note).
    abandon(task_id)

    # 2. Spawn the wrapper exactly like `start_task/2` does (through the seam when
    #    one is configured).
    task_ref = spawn_wrapper(task_type, spawn_opts, task_id, server, spawn_fun)

    # 3. Persist the re-enqueue with a TARGETED write — never a full put_task, so
    #    the paused run's result/usage/commit_sha/review_status/opts survive.
    columns = [
      status: :running,
      finished_at: nil,
      error: nil,
      pause_kind: nil,
      lease_expires_at: System.system_time(:second) + EvoGit.TaskRegistry.lease_duration()
    ]

    case write_columns(store, task_id, columns) do
      :ok ->
        {:ok, task_ref}

      {:error, _reason} = error ->
        # The row is still :paused, so a wrapper running the task would be
        # unmanageable (pause/cancel/force-kill all key off the row). Stop it.
        stop_wrapper(task_ref)
        error
    end
  end

  # The registry's injectable wrapper spawn. `nil` (production) is the
  # byte-identical `start_task/2` call; a 4-arity fun replaces it (tests assert
  # the propagated `:resume_kind` through it).
  defp spawn_wrapper(task_type, spawn_opts, task_id, server, nil) do
    Task.Supervisor.async_nolink(
      EvoGit.TaskSupervisor,
      EvoGit.TaskRegistry.TaskExecutor,
      :execute_task,
      [task_type, spawn_opts, task_id, server]
    )
  end

  defp spawn_wrapper(task_type, spawn_opts, task_id, server, fun) when is_function(fun, 4),
    do: fun.(task_type, spawn_opts, task_id, server)

  defp stop_wrapper(%Task{} = task_ref), do: Task.shutdown(task_ref, :brutal_kill)
  defp stop_wrapper(_other), do: :ok

  @doc """
  The `:clean | :dirty` resume narration selector for a persisted `pause_kind`:
  `:clean_pause` for `:clean`/`nil`, `:dirty_pause` for `:dirty`.

  Public because the resume contract (`resume_kind` in the dispatch ctx) is
  documented as a task-level pause fact, not a `Pause`-internal detail.
  """
  @spec resume_kind(:clean | :dirty | nil) :: :clean_pause | :dirty_pause
  def resume_kind(:dirty), do: :dirty_pause
  def resume_kind(_clean_or_nil), do: :clean_pause

  ## Restart classification (dirty pause)

  @doc """
  `true` when a task that lost its wrapper is RESUMABLE from durable state:
  `:persistent_state` is on for it (`true`/absent/`nil`; `false` or any
  non-boolean refuses) AND `EvoGit.AgentState` holds at least one run row for the
  task (`EvoGit.AgentState.resumable?/1`, read BOUNDED through
  `EvoGit.TaskRegistry.AgentStateRead` so this classification can never block
  the registry; an unprovable answer degrades to `false`).

  Accepts a `%EvoGit.TaskInfo{}` (or any atom-keyed map with `:id` + `:opts`),
  which is what both restart paths decode anyway. Total.
  """
  @spec dirty_pausable?(map()) :: boolean()
  def dirty_pausable?(%{id: task_id} = task) do
    persistent_state_on?(Map.get(task, :opts)) and
      AgentStateRead.resumable?(task_id, op: "resumable?")
  end

  def dirty_pausable?(_task), do: false

  @doc """
  The `:dirty` pause kind a restarted task lands in, or `nil` when it is not
  resumable (and therefore keeps today's `:failed` restart behaviour).

  Two arities:
    * `pause_kind_for_restart(task)` — the task row is already decoded;
    * `pause_kind_for_restart(store, task_id)` — the caller has only a NARROW row
      (the boot reconciliation and the lease sweep both read
      `%{id, status, lease_expires_at}` without `opts`), so this reads the row
      once through `EvoGit.Store.get_task_lite/2` — the narrowest read that
      exposes `pause_kind`/`opts` — and classifies that. It is a single-row read
      of a task that has NO wrapper (boot / a leaked lease), never a hot path, and
      it never decodes more than that one row.
  """
  @spec pause_kind_for_restart(map()) :: :dirty | nil
  def pause_kind_for_restart(%{id: _id} = task) do
    if dirty_pausable?(task), do: :dirty, else: nil
  end

  def pause_kind_for_restart(_other), do: nil

  @spec pause_kind_for_restart(pid(), String.t()) :: :dirty | nil
  def pause_kind_for_restart(store, task_id) when is_binary(task_id) do
    case read_row(store, task_id) do
      %{id: _id} = task -> pause_kind_for_restart(task)
      _absent -> nil
    end
  end

  ## Teardown

  @doc """
  The PAUSE-AWARE TEARDOWN: clears the task's scheduler pause marker and every
  pause flag of its agents (`EvoGit.AgentScheduler.clear_task_pause/1`).

  Called wherever a pause can no longer be honoured — the drain completed, the
  pause was abandoned, the task was cancelled/force-killed, the task was resumed,
  or a direct terminal status write removed the wrapper. BEST-EFFORT and total:
  a scheduler that is down (or was never started) is logged at `:debug` and
  ignored, because a teardown must never fail the status write that owns it.
  """
  @spec abandon(String.t()) :: :ok
  def abandon(task_id) do
    :ok = EvoGit.AgentScheduler.clear_task_pause(task_id)
    :ok
  catch
    :exit, reason ->
      Logger.debug(
        "TaskRegistry: AgentScheduler clear_task_pause failed (exit): #{inspect(reason)}"
      )

      :ok
  end

  ## Reads / writes

  # Narrow read: status + opts (never `result`/`logs`/`usage`).
  defp read_update_info(store, task_id) do
    StoreGuard.read("pause select_task_update_info", nil, fn ->
      EvoGit.Store.select_task_update_info(store, task_id)
    end)
  end

  # The resume read needs `pause_kind`, which `select_task_update_info/2` does not
  # project, so it uses the lite single-row read (the narrowest one that exposes
  # the pause facts + persisted opts).
  defp read_row(store, task_id) do
    StoreGuard.read("pause get_task_lite", nil, fn ->
      EvoGit.Store.get_task_lite(store, task_id)
    end)
  end

  defp write_columns(store, task_id, columns) do
    StoreGuard.write("pause update_task_columns", fn ->
      EvoGit.Store.update_task_columns(store, task_id, columns)
    end)
  end

  ## Option classification (non-raising — these run inside the registry)

  # `:session_mode` is a STRING-keyed persisted opt (`EvoGit.Store.Codec`'s
  # `@string_opt_keys`), and this classifier only ever sees a DECODED row — so
  # the string spelling is the one that actually arrives here. Both are accepted:
  # the atom form is what a caller hands `start_task/2`, the string form is what
  # the store decodes it back to, and matching only the atom key silently
  # admitted a pause for an interactive run.
  defp interactive?(opts) when is_list(opts) do
    Enum.find_value(opts, false, fn
      {key, value} when key in [:session_mode, "session_mode"] -> value == "interactive"
      _other -> nil
    end)
  end

  defp interactive?(_opts), do: false

  # `:persistent_state` is absent by default and then means TRUE. `nil` means
  # "unset" as well. The admission would reject a non-boolean at start time, so a
  # stored non-boolean is treated as NOT providing durable state (refuse the
  # pause) instead of raising inside the registry.
  defp persistent_state_on?(opts) when is_list(opts) do
    case Keyword.fetch(opts, :persistent_state) do
      :error -> true
      {:ok, nil} -> true
      {:ok, value} when is_boolean(value) -> value
      {:ok, _other} -> false
    end
  end

  defp persistent_state_on?(_opts), do: true
end
