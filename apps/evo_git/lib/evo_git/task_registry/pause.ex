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

  ## The ROOT row is the gate

  Resumability is decided by the task's durable ROOT run — the record whose
  `parent_id` is absent or `nil` — never by "any durable row": a resume that
  cannot restore a root would silently start the objective from scratch, and a
  roster holding only CHILD rows has nothing to resume. ONE bounded, offloaded
  `EvoGit.TaskRegistry.AgentStateRead.roster/2` read yields that row
  (`read_root_run/2`; the lowest `agent_id` among the root rows, which is what
  the roster's `depth ASC, agent_id ASC` order puts first).

  A resume carries five facts from that row to the scheduler, each key ALWAYS
  present on the spawn opts (`nil` included, so "resolved to nothing" and
  "never resolved" stay distinguishable):

  | Key | Value |
  |---|---|
  | `:pause_commit` | the root row's `fields[:pause_commit]` (the worktree checkpoint) |
  | `:resume_agent_id` | the row's persisted `agent_id` — the id the resumed run registers under |
  | `:resume_current_commit` | the root row's `current_commit` |
  | `:resume_branch` | the root row's `branch` |
  | `:resume_anchor_ref` | the root row's `anchor_ref`, else `EvoGit.AgentState.Anchor.ref/2` |

  The SAME root-row probe classifies a wrapper-less task for the restart paths,
  so a child-only roster keeps the `:lease_expired` → `:failed` behaviour
  instead of parking a task that could never be resumed.

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

  alias EvoGit.AgentState.Anchor
  alias EvoGit.AgentState.Record
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
  that `{:error, reason}` and leaves the row `:paused`. It then requires the
  task's durable ROOT row (`read_root_run/2`: ONE bounded, offloaded
  `EvoGit.TaskRegistry.AgentStateRead.roster/2` read), because a resume with
  nothing to restore — no durable row at all, or a roster holding only child
  rows — would silently start the objective from scratch: that is
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
  The ROOT run's five resume facts are resolved HERE, before the wrapper is
  spawned, and carried on the spawn opts (see `put_resume_facts/3`):
  `:pause_commit` (the worktree checkpoint the resumed worktree is based on),
  `:resume_agent_id` (the persisted root `agent_id` the resumed run registers
  under, so every durable read keyed `(task_id, agent_id)` still resolves), and
  `:resume_current_commit` / `:resume_branch` / `:resume_anchor_ref` (the root's
  own newest commit, work branch and anchoring ref). Every key is always
  present, `nil` included, so `nil` means "resolved, nothing stored" while an
  ABSENT key means "not a pause resume" (the direct-dispatch path, which falls
  back to a bounded read of its own). The scheduler itself must never make a
  synchronous durable read.

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
             {:ok, root} <- ensure_root_run(task_id) do
          requeue(store, task, put_resume_facts(spawn_opts, task_id, root), server, spawn_fun)
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

  # The durable-run gate: the ROOT row, not "any durable row". A resume with no
  # root row (including a roster holding only children) would silently start the
  # objective from scratch, so it refuses. ONE bounded, offloaded roster read
  # serves this gate and the resume facts below.
  defp ensure_root_run(task_id) do
    case read_root_run(task_id, "resume_roster") do
      %Record{} = root -> {:ok, root}
      _none -> {:error, :not_resumable}
    end
  end

  # The task's durable ROOT run — the record whose `fields[:parent_id]` is
  # absent or `nil` (a missing key counts as root) — or `nil`. The roster is
  # ordered `depth ASC, agent_id ASC`, so `Enum.find/2` yields the LOWEST
  # `agent_id` when several root rows exist. Total: an unanswerable read
  # degrades to `[]` and therefore to `nil`.
  defp read_root_run(task_id, op) do
    task_id
    |> AgentStateRead.roster(op: op)
    |> Enum.find(&root_run?/1)
  end

  defp root_run?(%Record{fields: fields}) when is_map(fields),
    do: is_nil(Map.get(fields, :parent_id))

  defp root_run?(_record), do: false

  # The resumed ROOT run's five resume facts, resolved HERE — in the caller of
  # `EvoGit.AgentScheduler.Dispatch`, never inside the scheduler. The dispatch
  # bases the resumed worktree and the agent identity on them
  # (`spec.opts[:pause_commit]`, `[:resume_agent_id]`, …) and must not make a
  # synchronous durable read to find them. EVERY key is put (as `sha |
  # binary | nil`) so the dispatch can tell "resolved to nothing" from "never
  # resolved" — the latter is the direct-dispatch fallback, which reads the
  # store itself, bounded.
  defp put_resume_facts(spawn_opts, task_id, %Record{} = root) do
    agent_id = root.agent_id
    fields = if is_map(root.fields), do: root.fields, else: %{}

    facts = [
      pause_commit: Map.get(fields, :pause_commit),
      resume_agent_id: agent_id,
      resume_current_commit: Map.get(fields, :current_commit),
      resume_branch: Map.get(fields, :branch),
      resume_anchor_ref: Map.get(fields, :anchor_ref) || Anchor.ref(task_id, agent_id)
    ]

    Enum.reduce(facts, spawn_opts, fn {key, value}, acc -> Keyword.put(acc, key, value) end)
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
  non-boolean refuses), it is NOT an interactive session (`interactive?/1`, the
  SAME rule the clean pause refuses with `:not_pausable`, because an interactive
  session's lifecycle is user-driven and a resumed one would have no client),
  AND `EvoGit.AgentState` holds a durable ROOT run row for the task
  (`read_root_run/2`: ONE bounded, offloaded
  `EvoGit.TaskRegistry.AgentStateRead.roster/2` read, so this classification can
  never block the registry).

  The ROOT row is the fact that matters: a roster holding only CHILD runs cannot
  restore the task (a resume starts from the root), so such a task answers
  `false` and keeps the `:lease_expired` → `:failed` restart behaviour. An
  unanswerable durable read also degrades to `false`.

  Accepts a `%EvoGit.TaskInfo{}` (or any atom-keyed map with `:id` + `:opts`),
  which is what both restart paths decode anyway. Total.
  """
  @spec dirty_pausable?(map()) :: boolean()
  def dirty_pausable?(%{id: task_id} = task) do
    opts = Map.get(task, :opts)

    persistent_state_on?(opts) and not interactive?(opts) and
      not is_nil(read_root_run(task_id, "dirty_pause_roster"))
  end

  def dirty_pausable?(_task), do: false

  @doc """
  The `:dirty` pause kind a restarted task lands in, or `nil` when it is not
  resumable (and therefore keeps the `:failed` restart behaviour).

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
