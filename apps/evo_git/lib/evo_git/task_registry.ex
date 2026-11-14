defmodule EvoGit.TaskRegistry do
  @moduledoc """
  Registry for tracking running EvoGit tasks.
  Tasks are identified by unique IDs and persisted to SQLite (the single source of truth)
  under namespaced keys `{:task, task_id}`.
  Runtime-only task references (`%Task{}`) are kept in-memory in `task_refs`.
  Supports configurable persistence of finished tasks to SQLite (platform data
  directory via EvoGit.Platform).

  The registry owns TASK state only: the Virtual Context Tree mount table is
  `EvoGit.VCT` business, persisted by `EvoGit.Store` and broadcast by the VCT
  itself, so nothing here reads or writes a mount.

  ## Why this file is long (and why it stays ONE GenServer)

  This module is the task LIFECYCLE STATE MACHINE. Every status transition a
  task can make is decided in ONE process, because the decisions are mutually
  exclusive and order-dependent: two processes (or two extracted state owners)
  could each pass a guard and then both write. So the file legitimately owns,
  in one place:

    * the status sets themselves (`@terminal_statuses`, the killable /
      cancellable / unstartable / finalizing-ignored lists) plus their
      `@doc false` accessors, which a table-driven totality test asserts
      against — a set that moves out of this file stops being total;
    * `start_task/2` and the admission guards (duplicate/unstartable ids,
      interactive and custom-root specs, tmpdir + `RuntimeOpts` validation);
    * the WRAPPER protocol: `task_refs`, the `{ref, result}` /
      `:DOWN` handlers, the stale-terminal guards and the straggler guard;
    * the cancellation model (`cancel_task/1` → `:cancelling` with a grace
      budget, `force_kill_task/1` → `:failed`, `:cancelled` meaning ONLY a
      graceful cancel) and the force-kill / cancel-direct writes;
    * task-level PAUSE and RESUME (`pause_task/1`, the `{:paused, info}`
      resting state, the dirty-pause restart mapping in `init/1` and the
      `:lease_sweep`, `resume_task/1` — the pure halves live in
      `EvoGit.TaskRegistry.Pause`);
    * lease bookkeeping (heartbeat renewal, the one-shot sweep) — the pure
      classification lives in `EvoGit.TaskRegistry.Lease`;
    * startup reconciliation of orphaned `:finalizing` / `:cancelling` rows and
      the stuck-`:finalizing` watchdog;
    * persistence sequencing over `EvoGit.Store` behind `StoreGuard` (the
      persist-BEFORE-broadcast rule every arm here follows), the `"tasks"`
      PubSub contract, and the cross-node filtering of it.

  Everything that is PURE — validation, resume plans, cleanup, diagnostics,
  the read offload, the runtime-opts and merge/resume context builders — is
  already extracted under `lib/evo_git/task_registry/`. What remains here is
  here because it reads or writes `%State{}`; splitting it out would either
  thread the state through a module that cannot own it, or introduce a second
  decision-maker for one transition.
  """
  use GenServer

  require Logger

  alias EvoGit.TaskInfo

  alias EvoGit.TaskRegistry.Cleanup
  alias EvoGit.TaskRegistry.Diagnostics
  alias EvoGit.TaskRegistry.Lease
  alias EvoGit.TaskRegistry.Pause
  alias EvoGit.TaskRegistry.ReadOffload
  alias EvoGit.TaskRegistry.RuntimeOpts
  alias EvoGit.TaskRegistry.StoreGuard
  alias EvoGit.TaskRegistry.TaskExecutor

  ## Call timeout

  # GenServer self-calls can block on EvoGit.Store calls (SQLite I/O may be
  # very slow on high-latency storage like an NFS-mounted home directory), so
  # they use an explicit 30s timeout instead of the 5s default. Keep the value
  # tunable in one place.
  @call_timeout 30_000

  # Registry instance name => its task-store name, published by `init/1` and
  # read by `put_task_archive/1`. App-owned (`EvoGit.Application`) so it
  # survives registry restarts; see `put_task_archive/1` for why the archive
  # write must not call the registry.
  @store_table :evogit_task_registry_stores

  @lease_duration 120
  @heartbeat_interval 60_000
  # One-shot lease sweep delay: longer than the lease duration so the lease has
  # definitely expired by the time the sweep fires. The +30 buffer avoids a race
  # where the owner died right after a renewal.
  @sweep_after (@lease_duration + 30) * 1000

  # Default grace (minutes) for the stuck-:finalizing watchdog — overridable via
  # the app env :finalizing_watchdog_grace_minutes (see finalizing_watchdog_grace/0).
  @finalizing_watchdog_default_minutes 60

  ## Task status sets
  #
  # EVERY status enumeration this GenServer owns lives here, exactly once, with
  # a `@doc false` accessor (`terminal_statuses/0`, `killable_statuses/0`, …) so
  # a table-driven test can assert totality: `:awaiting_input` — the
  # NON-TERMINAL status of an idle interactive session whose wrapper is still
  # alive on this node — must appear wherever `:running` does, except where a
  # set says otherwise in its comment.

  # Statuses after which a task never transitions again, except the still
  # allowed terminal → `:completed` (see the stale-terminal guard in
  # handle_update_status/6). `:paused` is NOT terminal: the task rests with no
  # wrapper, keeps `finished_at` nil and stays resumable (``docs/task-pause.md``).
  @terminal_statuses [:completed, :failed, :cancelled]

  # `force_kill_task/1` acts on these: the live agents and the wrapper are
  # brutal-killed and the row is persisted `:failed` with no result. An idle
  # `:awaiting_input` session is killable exactly like a running task, and so are
  # BOTH pause states: `:pausing` still has agents (the drain must be abortable)
  # and `:paused` has no wrapper at all (the "no live process" arm handles it).
  @killable_statuses [:running, :awaiting_input, :cancelling, :pausing, :paused]

  # Statuses `cancel_task/1` accepts. `:running` is cancelled gracefully through
  # the `:cancelling` state; an idle `:awaiting_input` session — which has
  # nothing to save but its transcript — is cancelled immediately
  # (`cancel_awaiting_input_session/2`), and so is a `:paused` task, whose run is
  # already stopped and merely needs the resting row retired. `:pausing` is
  # admitted for the SAME admission surfaces (the Assistant's cancel facade reads
  # this set), while the handler itself ABANDONS the pause first and then runs the
  # `:running` arm (a cancel that arrives while `:pausing` wins — the pause must
  # never be re-introduced).
  @gracefully_cancellable_statuses [:running, :awaiting_input, :pausing, :paused]

  # `start_task/2` refuses a task id already in one of these statuses. A waiting
  # session owns its id: restarting it would run a second session over the same
  # row, so the id is unstartable until the session ends. Both pause states are
  # listed for the same reason: a paused (or draining) row owns its id and is
  # resumed IN PLACE by `resume_task/1` — `start_task/2` mints a FRESH id and must
  # never take over a paused row (it would reset the archive roster and lose the
  # paused run's report).
  @unstartable_statuses [:cancelled, :cancelling, :awaiting_input, :pausing, :paused]

  # A `{:task_updated, id, :finalizing, node}` broadcast is ignored for these
  # (the row is already terminal or mid-graceful-cancel). `:awaiting_input` is
  # deliberately ABSENT: closing an idle session legitimately moves it through
  # `:finalizing`. `:pausing`/`:paused` are listed because a pause is NOT a
  # finalization: adopting `:finalizing` would clobber the pause bookkeeping (and
  # the watchdog would later fail a task that is merely resting).
  @finalizing_ignored_statuses [:completed, :cancelled, :cancelling, :pausing, :paused]

  # "A live task whose wrapper exists" — the in-flight set. This is NOT the
  # busy set: an idle `:awaiting_input` session holds no LLM slot, no tool slot
  # and no worker, so an update/idle gate must never count it as busy.
  # `:pausing` is live (its wrapper is alive and draining); `:paused` is
  # NON-terminal and must stay visible as an active task in the UI, but it has no
  # wrapper and no lease — which is why the lease sets exclude it while these
  # liveness sets include it.
  @active_statuses [
    :running,
    :pending,
    :finalizing,
    :cancelling,
    :awaiting_input,
    :pausing,
    :paused
  ]

  @doc false
  # Terminal statuses — no further transition (except terminal → `:completed`).
  def terminal_statuses, do: @terminal_statuses

  @doc false
  # Statuses `force_kill_task/1` accepts (`:failed`, no result).
  def killable_statuses, do: @killable_statuses

  @doc false
  # Statuses `cancel_task/1` accepts (graceful `:cancelling`, or immediate for a
  # waiting session / a paused task).
  def gracefully_cancellable_statuses, do: @gracefully_cancellable_statuses

  @doc false
  # Statuses whose task id `start_task/2` refuses.
  def unstartable_statuses, do: @unstartable_statuses

  @doc false
  # Statuses for which a `:finalizing` broadcast is ignored (`:awaiting_input`
  # is deliberately absent).
  def finalizing_ignored_statuses, do: @finalizing_ignored_statuses

  @doc false
  # Live statuses — a wrapper exists on this node (plus the paused resting state,
  # which is live for the UI but owns no wrapper/lease). Never the busy set.
  def active_statuses, do: @active_statuses

  @doc false
  # The lease duration (seconds) a live task's expiry is computed from. Exposed
  # so `EvoGit.TaskRegistry.Pause.resume/4` can write a FRESH lease without
  # duplicating the value.
  def lease_duration, do: @lease_duration

  ## Client API

  @doc """
  Resolves the TaskRegistry server name for the CURRENT process.

  Returns the value stored under the `:evogit_task_registry_server` process
  dictionary key when present (an isolated instance started with a custom
  `:name`), otherwise the default registered name `__MODULE__`.

  The value is read at CALL time — never cached — so every client function
  routes to whichever registry instance the calling process was pointed at.
  A task wrapper propagates its own registry name into the process dictionary
  of the spawned task process (see `EvoGit.TaskRegistry.TaskExecutor`), so code
  running inside the wrapper calls back to the SAME instance. The registry's
  OWN process also carries the key (`init/1` stores its registered name under
  it), so in-process self-calls — the `{ref, result}` / `:DOWN` handlers that
  cast terminal status — resolve to the same instance rather than the global
  singleton. When the key is unset the default registered singleton is used,
  keeping production behavior unchanged.
  """
  def server do
    Process.get(:evogit_task_registry_server) || __MODULE__
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def start_task(task_type, opts) do
    task_id = TaskExecutor.generate_id()
    GenServer.call(server(), {:start_task, task_id, task_type, opts}, @call_timeout)
  end

  def get_task(task_id) do
    GenServer.call(server(), {:get_task, task_id}, @call_timeout)
  end

  def list_tasks do
    GenServer.call(server(), :list_tasks, @call_timeout)
  end

  @doc """
  Returns a paginated slice of tasks (most-recent-first) with the total count.

  `opts` is a keyword list accepting `:limit` and `:offset` (both forwarded
  to `EvoGit.Store.safe_select_paginated_tasks/2`). Returns `{tasks, total_count}`.
  """
  def list_tasks_paginated(opts \\ []) do
    GenServer.call(server(), {:list_tasks_paginated, opts}, @call_timeout)
  end

  @doc """
  LIGHTWEIGHT paginated task read: one page of the 16-key summary projection
  plus the filtered total, `%{rows: [summary_map], total: non_neg_integer}`.

  Delegates to `EvoGit.Store.select_tasks_page/2` — the heavy JSON blobs
  (`result`, `logs`, `usage`) are never selected and the per-agent archive
  lives in its own table (see `list_task_archives/2`). `opts` accepts `:limit`
  (default 25, capped at 50), `:offset` and the filter keys `:status`,
  `:project_path`, `:review_status`, `:search`.

  Degrades to `%{rows: [], total: 0}` when the store call fails.
  """
  def list_tasks_page(opts \\ []) do
    GenServer.call(server(), {:list_tasks_page, opts}, @call_timeout)
  end

  @doc """
  LIGHTWEIGHT single-task read for detail views: decodes like `get_task/1` but
  through an explicit column projection (the per-agent archive is a separate
  table and is never read here — see `list_task_archives/2`).

  Delegates to `EvoGit.Store.get_task_lite/2`. Returns `%TaskInfo{}` or `nil`
  (also `nil` when the store call fails).
  """
  def get_task_lite(task_id) do
    GenServer.call(server(), {:get_task_lite, task_id}, @call_timeout)
  end

  @doc """
  Persists ONE archived agent record into the relational per-agent archive
  table (`task_agent_archives`) — the STREAMING producer write.

  Called by `EvoGit.Agent.Completion` the moment an agent completes, so
  each agent's archive is persisted on its own (ONE row per
  `{task_id, agent_id}`) instead of being buffered in memory and collected at
  task end. `entry` may be atom-keyed (the producer's shape, carrying
  `:task_id`) or string-keyed; the underlying write is an idempotent upsert, so
  a crash-retry completing twice replaces the row instead of duplicating it.

  The write runs in the CALLER's process, NOT in the registry GenServer: the
  registry name is only used to resolve that instance's store (published by
  `init/1` into `:evogit_task_registry_stores`), so a multi-MB archive insert
  never blocks the registry — and the dashboard reads and heartbeat queued
  behind it. `EvoGit.Store` serializes committed writes through
  `EvoGit.Store.Writer` and replies AFTER the commit, so this stays
  synchronous for the caller: the row is durable before the completing agent
  proceeds to its terminal transition (that ordering is the caller's).

  Persistence is BEST-EFFORT and never raises or exits into the caller: a
  dead/restarting store degrades to `{:error, :store_unavailable}` (logged by
  `EvoGit.TaskRegistry.StoreGuard`), an invalid entry to the store's own
  `{:error, reason}`. An agent's completion must never fail because its
  archive could not be stored.

  Returns `:ok` on success or `{:error, reason}` otherwise.
  """
  @spec put_task_archive(map()) :: :ok | {:error, term()}
  def put_task_archive(entry) do
    store = archive_store()

    StoreGuard.write("put_task_archive", fn ->
      EvoGit.Store.put_task_archive(store, entry)
    end)
  end

  @doc """
  Returns ONE page of a task's archived agents plus the task's TOTAL archive
  row count: `%{entries: [map()], total: non_neg_integer}`.

  Delegates to `EvoGit.Store.list_task_archives/3`. Entries are STRING-KEYED
  and ordered `depth ASC, agent_id ASC` (the spawn tree, root first). `opts`
  accepts:

    * `:limit` — page size, default 100, clamped to 1..1000;
    * `:offset` — rows to skip, default 0;
    * `:include_results` — default `false`; when false the heavy `result`
      column is NOT selected, so the `"result"` key is ABSENT (not `nil`) from
      every entry. The opened agent's full conversation comes from
      `get_agent_archive/2`.
    * `:include_settings` — default `false`; when false the export-only JSON
      columns (`"llm_settings"`, `"agent_settings"`, `"foreign_repos"`) are NOT
      selected, so their keys are ABSENT from every entry. The CSV/JSON export
      passes `true`.
    * `:include_total` — default `true`; pass `false` to skip the `count(*)`
      when the caller already knows the total (`total` is then `nil`).

  Every opt is forwarded UNCHANGED to `EvoGit.Store.list_task_archives/3` — the
  registry adds nothing, drops nothing and defaults nothing.
  `total` is the task's whole archive row count, independent of
  `:limit`/`:offset` (and `nil` when `:include_total` is `false`). Degrades to
  `%{entries: [], total: 0}` when the store read fails.
  """
  @spec list_task_archives(String.t(), keyword()) ::
          %{entries: [map()], total: non_neg_integer() | nil}
  def list_task_archives(task_id, opts \\ []) do
    GenServer.call(server(), {:list_task_archives, task_id, opts}, @call_timeout)
  end

  @doc """
  Returns ONE archived agent's full entry (including `"result"`), or `nil`
  when the task has no such archived agent.

  Delegates to `EvoGit.Store.get_agent_archive/3` — the lazy detail read that
  pairs with the `list_task_archives/2` roster page. Entries are STRING-KEYED.
  Degrades to `nil` (the "no such agent" shape) when the store read fails.
  """
  @spec get_agent_archive(String.t(), integer()) :: map() | nil
  def get_agent_archive(task_id, agent_id) do
    GenServer.call(server(), {:get_agent_archive, task_id, agent_id}, @call_timeout)
  end

  @doc """
  Gracefully cancels a running (or pending) task by id.

  - `:pending` → marked `:cancelled` immediately (no agents exist yet) and a
    subsequent `start_task` for the same id is refused.
  - `:running` → status set to `:cancelling` (broadcast to the dashboard) and
    `AgentScheduler.begin_graceful_cancel/1` is invoked, which injects a
    cancel notification + `cancel_requested` flag into every agent of the task
    so they enter a grace period and finish cleanly. The task's final mapping
    to `:cancelled` (with result preserved) happens when the wrapper completes.
  - `:cancelling` → `:ok` (idempotent; does NOT re-send messages).
  - `:awaiting_input` → `:cancelled` immediately: an idle interactive session
    has nothing to save but its transcript, so the row is written `:cancelled`
    (finished_at set, lease cleared) with NO `result` — the transcript/result is
    preserved — the session is stopped best-effort (task-addressed) and the
    `{:task_updated, task_id, :cancelled, node()}` broadcast fires on the
    successful write.

  Returns `:ok` on success, `{:error, :not_found}` for an unknown task, or
  `{:error, :not_running}` for terminal states (`:completed`/`:failed`/
  `:cancelled`) and `:finalizing`.

  For the brutal (no grace period) cancellation, use `force_kill_task/1`.
  """
  def cancel_task(task_id) do
    GenServer.call(server(), {:cancel_task, task_id}, @call_timeout)
  end

  @doc """
  Force-kills a running, awaiting-input or cancelling task by id — the BRUTAL
  cancellation path.

  Kills every agent of the task (via `AgentScheduler.force_kill_task_agents/1`,
  reverse-depth cascade with `:brutal_kill`), then brutal-kills the wrapper
  process and persists the task as `:failed` with finished_at set, the lease
  cleared, and no result (result nil). Works from `:running` (normal
  force-kill), `:cancelling` (escalation path — a graceful cancel that hangs)
  and `:awaiting_input` (an idle interactive session, killable exactly like a
  running task).

  Returns `:ok` on success, `{:error, :not_found}` for an unknown task, or
  `{:error, :not_running}` for other states.

  For the graceful cancellation, use `cancel_task/1`.
  """
  def force_kill_task(task_id) do
    GenServer.call(server(), {:force_kill_task, task_id}, @call_timeout)
  end

  @doc """
  Requests a TASK-LEVEL PAUSE for a running task by id (`docs/task-pause.md`).

  - `:running` → the row is written `:pausing` (broadcast to the dashboard
    immediately after the persist) and
    `EvoGit.AgentScheduler.begin_task_pause/1` flags every agent of the task, so
    each one stops at its NEXT TURN BOUNDARY — never mid-tool — after
    checkpointing its conversation and committing its worktree. When the root
    agent reports `{:paused, info}` the row becomes `:paused` with
    `pause_kind: :clean`, the lease cleared and `finished_at` nil, and the
    task's `result`/`usage`/archive are preserved (see `pause_task` on the
    wrapper-result path in `handle_wrapper_result/3`).
  - `:pausing`/`:paused` → `:ok` (IDEMPOTENT: no write, no scheduler call, no
    broadcast).
  - `:awaiting_input` (or any interactive-session task) →
    `{:error, :not_pausable}`: an interactive session has no resumable run.
  - `:persistent_state` stored as `false` → `{:error, :not_resumable}`: with no
    durable agent state there is nothing to resume, so pausing would be a lie.
  - Any other status (`:pending`, `:finalizing`, `:cancelling`, terminal) →
    `{:error, :not_running}`.
  - An unknown task → `{:error, :not_found}` (an unreadable status is
    `:not_running`, never `:not_found`).

  A scheduler that is DOWN (or a call that times out) reverts the row to
  `:running` and answers `{:error, :scheduler_unavailable}` — a pause must never
  leave a row stuck in `:pausing` with no agents to drain.

  Returns `:ok` on success (including the idempotent case) or `{:error, reason}`.
  The validation/persistence itself lives in `EvoGit.TaskRegistry.Pause`.
  """
  def pause_task(task_id) do
    GenServer.call(server(), {:pause_task, task_id}, @call_timeout)
  end

  @doc """
  RESUMES a paused task IN PLACE: the SAME task id is re-enqueued with its
  PERSISTED opts (`docs/task-pause.md`) — no fresh id, no `start_task/2`.

  Accepts `:paused` ONLY (`{:error, :not_paused}` otherwise, `{:error,
  :not_found}` for an unknown task). On the successful transition the row is
  written `status: :running`, `finished_at: nil`, `error: nil`,
  `pause_kind: nil` and a FRESH lease (TARGETED columns only — `started_at`,
  `opts`, `commit_sha`, `result`, `usage`, `review_status`, `branch_name` and
  `base_sha` are untouched, so a resumed run's report and usage ACCUMULATE), the
  stale scheduler pause marker is cleared, a wrapper is spawned for the same task
  id exactly like `start_task/2` does, and `{:task_updated, task_id, :running,
  node()}` is broadcast after the write.

  The spawn opts carry `resume_kind: :clean_pause` for a `:clean` (or legacy
  `nil`) paused row and `:dirty_pause` for a `:dirty` one, which
  `EvoGit.TaskRegistry.RuntimeOpts.build_common_runtime_opts/3` forwards to the
  runtime so the agent restores its conversation and narrates/repairs
  accordingly.

  Admission re-runs the SAME gates as `start_task/2` (model selection against the
  current config, `:session_mode`, `:persistent_state`); a failure answers that
  `{:error, reason}` and leaves the row `:paused`. A row with no durable run
  (`EvoGit.AgentState.root_agent_ids/1 == []`) is `{:error, :not_resumable}`.

  Returns `:ok` on success or `{:error, reason}`.
  """
  def resume_task(task_id) do
    GenServer.call(server(), {:resume_task, task_id}, @call_timeout)
  end

  def update_task_status(task_id, status, result \\ nil, opts \\ []) do
    GenServer.cast(server(), {:update_status, task_id, status, result, opts})
  end

  @doc """
  Status-only convenience over `update_task_status/4`: moves `task_id` to
  `status` with no result and no extra opts (a cast through
  `handle_update_status/6`, so the stale-terminal guard, the `:cancelling`
  force-map, the terminal teardown and the persist-then-broadcast contract all
  apply unchanged).

  This is what the interactive-session lifecycle calls to flip
  `:running ↔ :awaiting_input` on yield/resume: both are NON-terminal, so
  `finished_at` and the lease are untouched and the `task_refs` entry stays.
  A call that repeats the row's CURRENT status is a no-op — the write is
  harmless and no broadcast fires (`status != task_status`).

  It carries `result: nil`, so only use it for non-terminal transitions (no
  result exists yet); terminal transitions go through
  `update_task_status/4` with their result.
  """
  @spec update_status(String.t(), atom()) :: :ok
  def update_status(task_id, status) do
    update_task_status(task_id, status, nil, [])
  end

  defp update_task_status_with_caller(task_id, status, result, opts) do
    GenServer.cast(
      server(),
      {:update_status, task_id, status, result, opts, {self(), Diagnostics.capture_stacktrace(5)}}
    )
  end

  def set_review_status(task_id, status) do
    GenServer.cast(server(), {:set_review_status, task_id, status})
  end

  def set_review_metadata(task_id, base_sha, commit_sha) do
    GenServer.cast(server(), {:set_review_metadata, task_id, base_sha, commit_sha})
  end

  @doc """
  Returns lightweight task summaries for all tasks — only columns needed for
  the dashboard sidebar listing. Returns a list of plain maps.

  `statuses` is a list of status ATOMS; `[]` (default) means all statuses. When
  non-empty, the status filter is pushed into SQL.

  `since` is an optional fixed-precision ISO-8601 timestamp string; when
  non-nil, only tasks updated at or after `since` are returned (nil = no time
  filter). The filter is pushed into SQL.
  """
  def list_tasks_summary(statuses \\ [], since \\ nil) do
    GenServer.call(server(), {:list_tasks_summary, statuses, since}, @call_timeout)
  end

  @doc """
  Returns a minimal id/status/updated_at projection for tasks matching
  `statuses` (atoms; `[]` = all tasks).

  This is a lightweight query — only the `id`, `status`, and `updated_at`
  columns are read, no heavy JSON fields are decoded. `updated_at` is returned
  as the raw stored fixed-precision ISO string (not decoded to a DateTime).
  When `statuses` is non-empty, the status filter is pushed into SQL.
  """
  def list_task_ids(statuses \\ []) do
    GenServer.call(server(), {:list_task_ids, statuses}, @call_timeout)
  end

  @doc """
  Same as list_tasks_summary/2 but filtered to a specific project_path.
  """
  def list_tasks_summary_by_path(path, statuses \\ [], since \\ nil) do
    GenServer.call(
      server(),
      {:list_tasks_summary_by_path, path, statuses, since},
      @call_timeout
    )
  end

  @doc """
  Returns tasks created or updated at or after the given fixed-precision
  ISO-8601 timestamp string (`since_iso`). Delegates to
  `EvoGit.Store.select_tasks_changed_since/2`; returns a list of plain maps
  (id, status, updated_at, ...).
  """
  def list_tasks_changed_since(since_iso) do
    GenServer.call(server(), {:list_tasks_changed_since, since_iso}, @call_timeout)
  end

  def get_unique_paths do
    GenServer.call(server(), :get_unique_paths, @call_timeout)
  end

  def delete_task(task_id) do
    GenServer.cast(server(), {:delete_task, task_id})
  end

  def clear_finished_tasks do
    GenServer.call(server(), :clear_finished_tasks, @call_timeout)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    # Allow data_dir to be overridden via opts (for testing), fallback to config
    # then platform default. Tests set `config :evo_git, :data_dir` to a temp dir.
    data_dir =
      Keyword.get(
        opts,
        :data_dir,
        Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())
      )

    File.mkdir_p!(data_dir)

    # The TaskStore is started by the supervisor; here just reference by name.
    # Tests may pass their own task_store: name pointing to a test store.
    task_store = Keyword.get(opts, :task_store, EvoGit.Store)

    # This instance's OWN registered name. Captured here so the task wrapper it
    # spawns can propagate it into the wrapper process's `:evogit_task_registry_server`
    # process dictionary key — in-wrapper callbacks (MergeContext/ResumeContext)
    # then resolve back to THIS instance via `server/0`. Defaults to `__MODULE__`.
    server_name = Keyword.get(opts, :name, __MODULE__)

    # The registry's OWN process must also carry the seam key: its {ref, result}
    # / :DOWN handlers cast terminal statuses from INSIDE this process, and
    # server/0 is read at CALL time — without this they would resolve to the
    # global singleton instead of THIS instance. Unset elsewhere ⇒ server_name
    # == __MODULE__, so production resolves exactly as before.
    Process.put(:evogit_task_registry_server, server_name)

    # Publish this instance's store so `put_task_archive/1` can run the archive
    # write in the CALLING process instead of here (see that function).
    publish_store(server_name, task_store)

    state = %{
      data_dir: data_dir,
      task_store: task_store,
      task_refs: %{},
      read_offloads: ReadOffload.new(),
      server_name: server_name,
      # Call-time seam for `Pause.resume/4`'s wrapper spawn: `nil` (production and
      # every existing caller) is the byte-identical
      # `Task.Supervisor.async_nolink/4` call `start_task/2` makes; a 4-arity fun
      # replaces it so a test can assert the propagated `:resume_kind` without
      # running a real runtime. Per-instance (an init option, not app env), so it
      # can never leak into a concurrently running test.
      wrapper_spawn_fun: Keyword.get(opts, :wrapper_spawn_fun)
    }

    # Startup reconciliation for orphaned :finalizing, :cancelling, :awaiting_input,
    # :running and :pausing tasks. A task that was mid-finalization when the
    # runtime died (e.g. slow git calls in merge_and_report/3 hanging while the
    # app is killed) can never reach a terminal status in-process: the {ref, result}
    # and {:DOWN, ...} handlers key off task_refs, which is empty after restart.
    # Likewise a task that was mid-graceful-cancel when the runtime died must
    # resolve to :cancelled, not stay :cancelling forever, and an idle
    # interactive session (:awaiting_input) is in-memory only — its wrapper died
    # with the previous BEAM, so it can never resume and resolves to :failed.
    # Mark such tasks synchronously here (NOT via the async update_task_status/4
    # cast, which would race callers).
    #
    # TASK PAUSE — a RESUMABLE live row (`:persistent_state` on AND durable agent
    # state present, `Pause.pause_kind_for_restart/2`) has no wrapper after a
    # restart, so it becomes a DIRTY PAUSE (`:paused` + `pause_kind: :dirty`,
    # `finished_at` nil, lease cleared, result/usage untouched) instead of
    # `:failed`. This arm owns `:running` (which otherwise keeps today's "leave it
    # to the one-shot :lease_sweep" behaviour) AND `:pausing` (a drain that was
    # interrupted by the restart) — a NON-resumable row falls through to today's
    # behaviour in both cases (the sweep maps its expired lease to `:failed`).
    state =
      safe_store_read(
        "init select_running_lease_info",
        [],
        fn -> EvoGit.Store.select_running_lease_info(task_store) end
      )
      |> Enum.reduce(state, fn %{id: task_id, status: status}, acc ->
        case status do
          :finalizing ->
            message = "Runtime restarted during task finalization"

            handle_update_status(
              acc,
              task_id,
              :failed,
              message,
              [error: Diagnostics.failure_error(:restart, :startup_reconcile, message)],
              {:startup_reconcile, :finalizing}
            )

          :cancelling ->
            handle_update_status(
              acc,
              task_id,
              :cancelled,
              "Runtime restarted during task cancellation",
              [],
              {:startup_reconcile, :cancelling}
            )

          :awaiting_input ->
            # Sessions are in-memory only: their wrapper died with the previous
            # BEAM, so an idle session can never resume and must not sit in a
            # live status forever. Failed (not :cancelled) — nothing was
            # cancelled, the session was lost. The archived/result data a
            # closed session had already written is left untouched.
            message = "Runtime restarted during interactive session"

            handle_update_status(
              acc,
              task_id,
              :failed,
              message,
              [error: Diagnostics.failure_error(:restart, :startup_reconcile, message)],
              {:startup_reconcile, :awaiting_input}
            )

          status when status in [:running, :pausing] ->
            reconcile_paused(acc, task_id, status)

          _ ->
            acc
        end
      end)

    # Subscribe to task status events from EvoGit.PubSub
    Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

    # Start the periodic heartbeat timer for lease renewal (owned tasks only).
    # The sweep is NOT periodic — it fires once after the lease duration to
    # catch owners that died around our startup. After that, any new foreign
    # instance does its own check. (init itself reconciles orphaned
    # :finalizing tasks directly, above.)
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    Process.send_after(self(), :lease_sweep, @sweep_after)

    # Periodic cleanup: sweep expired tasks every 5 minutes
    Process.send_after(self(), :periodic_cleanup, 300_000)

    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call({:start_task, task_id, task_type, opts}, _from, state) do
    # Graceful-cancel / waiting-session guard: a task that was cancelled while
    # :pending (or is currently :cancelling) must never start, and neither must
    # an id owned by a waiting interactive session (`:awaiting_input`). There is
    # no in-runtime :pending → :running scheduled transition, so this is the
    # only place a cancelled pending task could slip through.
    persisted_status =
      safe_store_read("start_task get_task_status", nil, fn ->
        EvoGit.Store.get_task_status(state.task_store, task_id)
      end)

    # `{:unknown, raw}` — the row EXISTS but its status text is unreadable, so
    # it is never treated as absent; it also cannot be PROVEN `:cancelled`, so
    # the guard below deliberately does not fire and the start proceeds. This
    # handler always allocates a FRESH task id, so refusing here would only
    # strand a task nothing else could start.
    log_unreadable_status("start_task", task_id, persisted_status)

    case persisted_status do
      status when status in @unstartable_statuses ->
        {:reply, {:error, :cancelled}, state}

      _known_or_absent ->
        # Admit before spawning or persisting: invalid explicit selections must
        # not enqueue work, and the stored opts must match the admitted selection.
        # `:session_mode` is admitted the same way (non-raising — a raise here
        # would kill the registry); an invalid value never enqueues a task.
        # `:persistent_state` is admitted the same way: it turns durable
        # per-run agent-state checkpoints on for this task.
        with {:ok, opts} <- RuntimeOpts.admit_model_selection(opts, EvoGit.Config.resolve()),
             {:ok, opts} <- RuntimeOpts.admit_session_mode(opts),
             {:ok, opts} <- RuntimeOpts.admit_persistent_state(opts) do
          task_ref =
            Task.Supervisor.async_nolink(
              EvoGit.TaskSupervisor,
              TaskExecutor,
              :execute_task,
              [task_type, opts, task_id, state.server_name]
            )

          task = %TaskInfo{
            id: task_id,
            type: task_type,
            status: :running,
            opts: opts,
            ref: task_ref,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil,
            lease_expires_at: System.system_time(:second) + @lease_duration,
            model_id: Keyword.get(opts, :model_id)
          }

          # Persist to SQLite with ref nulled (ref is runtime-only data). A
          # disk-full write must NOT crash the registry: the task still runs
          # in-memory (unpersisted) and the next status write (terminal or
          # otherwise) retries the persistence. An UNAVAILABLE store (a dead /
          # restarting Store process, or an unexpected store fault) degrades the
          # same way — the registry never exits from a store call.
          case safe_store_write("start_task put_task", fn ->
                 EvoGit.Store.put_task(state.task_store, %{task | ref: nil})
               end) do
            :ok ->
              :ok

            {:error, :disk_full} ->
              Logger.warning(
                "TaskRegistry: disk full — task #{task_id} could not be persisted; " <>
                  "continuing in-memory only"
              )

            {:error, :store_unavailable} ->
              # StoreGuard already logged the fault — keep the task in memory.
              :ok
          end

          # Keep the runtime ref in-memory only
          state = %{state | task_refs: Map.put(state.task_refs, task_id, task_ref)}

          Phoenix.PubSub.broadcast(
            EvoGit.PubSub,
            "tasks",
            {:task_updated, task_id, :running, node()}
          )

          {:reply, {:ok, task}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_task, task_id}, _from, state) do
    task = task_get(state, task_id)
    {:reply, task, state}
  end

  @impl true
  def handle_call(:list_tasks, from, state) do
    offload(from, state, "list_tasks", [], fn ->
      EvoGit.Store.safe_select_all_tasks(state.task_store)
    end)
  end

  @impl true
  def handle_call({:list_tasks_paginated, opts}, from, state) do
    offload(from, state, "list_tasks_paginated", {[], 0}, fn ->
      EvoGit.Store.safe_select_paginated_tasks(state.task_store, opts)
    end)
  end

  @impl true
  def handle_call({:list_tasks_page, opts}, from, state) do
    offload(from, state, "list_tasks_page", %{rows: [], total: 0}, fn ->
      EvoGit.Store.select_tasks_page(state.task_store, opts)
    end)
  end

  @impl true
  def handle_call({:get_task_lite, task_id}, from, state) do
    offload(from, state, "get_task_lite", nil, fn ->
      EvoGit.Store.get_task_lite(state.task_store, task_id)
    end)
  end

  @impl true
  def handle_call({:list_task_archives, task_id, opts}, from, state) do
    offload(from, state, "list_task_archives", %{entries: [], total: 0}, fn ->
      EvoGit.Store.list_task_archives(state.task_store, task_id, opts)
    end)
  end

  @impl true
  def handle_call({:get_agent_archive, task_id, agent_id}, from, state) do
    offload(from, state, "get_agent_archive", nil, fn ->
      EvoGit.Store.get_agent_archive(state.task_store, task_id, agent_id)
    end)
  end

  @impl true
  def handle_call({:force_kill_task, task_id}, _from, state) do
    # Narrow-column existence/status check (reads only the status column).
    # Works from :running (normal force-kill), :cancelling (escalation path —
    # a graceful cancel that hangs must be force-killable) and :awaiting_input
    # (an idle interactive session — killable exactly like a running task).
    {result, state} =
      case safe_store_read("force_kill_task get_task_status", nil, fn ->
             EvoGit.Store.get_task_status(state.task_store, task_id)
           end) do
        status when status in @killable_statuses ->
          case Map.get(state.task_refs, task_id) do
            %Task{pid: pid} = task_ref ->
              if Process.alive?(pid) do
                # Notify the AgentScheduler to cancel all agents for this task
                # before killing the wrapper process. The scheduler uses the caller PID
                # to find the matching top-level agent and cascade cleanup to subagents.
                #
                # Justified catch :exit — cross-app boundary. The scheduler may
                # genuinely not be running (or the GenServer may be dead), in which
                # case the GenServer call raises an exit (not a rescue-able
                # exception). We always proceed to brutal_kill the wrapper
                # regardless, so we log the exit and continue.
                try do
                  EvoGit.AgentScheduler.force_kill_task_agents(pid)
                catch
                  :exit, reason ->
                    Logger.warning(
                      "TaskRegistry: AgentScheduler force_kill failed (exit): #{inspect(reason)}"
                    )
                end

                Task.shutdown(task_ref, :brutal_kill)

                # Pause + graceful-cancel teardown: this direct terminal write
                # bypasses `handle_update_status/6`, so BOTH markers must be
                # cleared here — a force-killed task must not leave the scheduler
                # believing a pause is still draining (and, for a `:pausing` row,
                # no agent keeps honouring a pause only to be killed anyway).
                Pause.abandon(task_id)
                clear_cancelling_marker(task_id)

                force_kill_write(state, task_id)
              else
                # A wrapper ref whose process already died has nothing to stop;
                # only a PAUSED row is still killable in that shape (a paused
                # task legitimately has no live wrapper).
                force_kill_without_wrapper(state, task_id, status)
              end

            nil ->
              # No wrapper at all: a `:paused` task ALWAYS looks like this (its
              # wrapper ended when the drain completed), so the kill must work
              # from this arm too.
              force_kill_without_wrapper(state, task_id, status)
          end

        nil ->
          {{:error, :not_found}, state}

        {:unknown, raw} ->
          # The row EXISTS but its status text is unreadable. Force kill
          # persists `:failed` — it MARKS the row — so it is only allowed for a
          # status we can prove is live and killable; refuse conservatively
          # rather than overwrite a row whose liveness we cannot establish.
          # Never `{:error, :not_found}`: the row is there.
          log_unreadable_status("force_kill_task", task_id, {:unknown, raw})
          {{:error, :not_running}, state}

        _status ->
          {{:error, :not_running}, state}
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, task_id, :failed, node()})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:cancel_task, task_id}, _from, state) do
    # GRACEFUL cancellation. Narrow-column existence/status check.
    status =
      safe_store_read("cancel_task get_task_status", nil, fn ->
        EvoGit.Store.get_task_status(state.task_store, task_id)
      end)

    if status == :awaiting_input do
      # An idle interactive session is the ONE arm that also has a live session
      # process to stop, so it threads state (task_refs) and answers the call
      # itself instead of falling through to the status-only arms below.
      cancel_awaiting_input_session(state, task_id)
    else
      result =
        case status do
          :pending ->
            # No agents exist yet — mark :cancelled immediately. The start_task
            # guard (see {:start_task, ...} handler) then refuses to start it.
            # On disk-full the persisted status stays :pending and
            # {:error, :disk_full} is returned (a later cancel retry would work).
            # Broadcast only on the successful write — the :running arm below
            # funnels through handle_update_status/6, which broadcasts the
            # :cancelling transition itself (no double broadcast).
            case safe_store_write("cancel_task update_task_columns", fn ->
                   EvoGit.Store.update_task_columns(state.task_store, task_id,
                     status: :cancelled,
                     finished_at: DateTime.utc_now(),
                     lease_expires_at: nil
                   )
                 end) do
              :ok ->
                # Direct terminal write (:cancelled) — bypasses
                # handle_update_status/6, so reclaim the tmpdir here too (a
                # :pending task never started, so this is normally a no-op).
                reclaim_task_tmpdir(state, task_id)

                Phoenix.PubSub.broadcast(
                  EvoGit.PubSub,
                  "tasks",
                  {:task_updated, task_id, :cancelled, node()}
                )

                :ok

              {:error, :disk_full} ->
                Logger.warning(
                  "TaskRegistry: disk full — pending task #{task_id} could not " <>
                    "be marked :cancelled"
                )

                {:error, :disk_full}

              {:error, :store_unavailable} ->
                # StoreGuard already logged it; the pending task is not persisted
                # as :cancelled, so return the degraded error like disk-full.
                {:error, :store_unavailable}
            end

          :running ->
            request_graceful_cancel(state, task_id)

          :pausing ->
            # A pause that is still DRAINING loses to a cancel. Abandon the pause
            # FIRST (task marker + every agent's `pause_requested` flag, so no
            # agent keeps walking to a pause), then proceed EXACTLY like
            # `:running`: the wrapper is still alive and honours the cancel.
            # Nothing in the registry re-introduces a pause afterwards — every
            # pause entry point (`Pause.pause/2`) refuses anything but `:running`.
            Pause.abandon(task_id)
            request_graceful_cancel(state, task_id)

          :paused ->
            # A PAUSED task has NO wrapper and NO agents to ask, so it is the
            # second IMMEDIATE arm (`:pending`-like): write `:cancelled` straight
            # away with `finished_at` set, the lease cleared and `pause_kind`
            # dropped, and broadcast only on the successful write.
            cancel_paused_task(state, task_id)

          :cancelling ->
            # Idempotent — a graceful cancel is already in flight. Do NOT re-send
            # the cancel message (agents already have it).
            :ok

          nil ->
            {:error, :not_found}

          {:unknown, raw} ->
            # The row EXISTS with an unreadable status: never `{:error,
            # :not_found}` (that would claim the row is absent), and neither
            # cancellation path can be justified — the `:pending` arm would mark a
            # possibly-live row `:cancelled` and the `:running` arm would push a
            # cancel to agents that may not exist. Conservative answer: it is not
            # running (the row keeps its status).
            log_unreadable_status("cancel_task", task_id, {:unknown, raw})
            {:error, :not_running}

          _status ->
            # :finalizing / :completed / :failed / :cancelled
            {:error, :not_running}
        end

      {:reply, result, state}
    end
  end

  @impl true
  def handle_call({:pause_task, task_id}, _from, state) do
    # Thin handler: `Pause.pause/2` validates and persists, this process owns the
    # persist-THEN-broadcast sequencing. ONLY a real transition is broadcast — the
    # idempotent (`{:ok, :already_pausing | :already_paused}`) and refused answers
    # write nothing.
    case Pause.pause(state.task_store, task_id) do
      {:ok, :pausing} ->
        Phoenix.PubSub.broadcast(
          EvoGit.PubSub,
          "tasks",
          {:task_updated, task_id, :pausing, node()}
        )

        {:reply, :ok, state}

      {:ok, _already_pausing_or_paused} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:resume_task, task_id}, _from, state) do
    # Thin handler: `Pause.resume/4` validates, clears the stale scheduler pause
    # and spawns the wrapper; tracking the ref here is what makes the existing
    # `{ref, result}` / `:DOWN` handlers work unchanged for a resumed run.
    case Pause.resume(state.task_store, task_id, state.server_name, state.wrapper_spawn_fun) do
      {:ok, task_ref} ->
        state = %{state | task_refs: Map.put(state.task_refs, task_id, task_ref)}

        Phoenix.PubSub.broadcast(
          EvoGit.PubSub,
          "tasks",
          {:task_updated, task_id, :running, node()}
        )

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_unique_paths, _from, state) do
    # select_task_paths now returns distinct non-nil project_path values
    # directly from the denormalized column — no per-row decode needed.
    paths =
      safe_store_read("get_unique_paths", [], fn ->
        EvoGit.Store.select_task_paths(state.task_store)
      end)

    {:reply, paths, state}
  end

  @impl true
  def handle_call({:list_tasks_summary, statuses, since}, from, state) do
    offload(from, state, "list_tasks_summary", [], fn ->
      EvoGit.Store.select_tasks_summary(state.task_store, statuses, since)
    end)
  end

  @impl true
  def handle_call({:list_tasks_summary_by_path, path, statuses, since}, from, state) do
    offload(from, state, "list_tasks_summary_by_path", [], fn ->
      EvoGit.Store.select_tasks_summary_by_path(state.task_store, path, statuses, since)
    end)
  end

  @impl true
  def handle_call({:list_tasks_changed_since, since_iso}, from, state) do
    offload(from, state, "list_tasks_changed_since", [], fn ->
      EvoGit.Store.select_tasks_changed_since(state.task_store, since_iso)
    end)
  end

  @impl true
  def handle_call({:list_task_ids, statuses}, _from, state) do
    # Tiny projection (id, status, updated_at) — no heavy decode, so reply
    # synchronously without the Task-start offload.
    tasks =
      safe_store_read("list_task_ids", [], fn ->
        EvoGit.Store.select_task_ids(state.task_store, statuses)
      end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call(:clear_finished_tasks, _from, state) do
    task_ids =
      safe_store_read("clear_finished_tasks select", [], fn ->
        EvoGit.Store.select_finished_task_ids(state.task_store)
      end)

    # On disk-full the finished rows remain and {:error, :disk_full} is
    # returned (a later clear retry would succeed once space is freed).
    reply =
      case safe_store_write("clear_finished_tasks delete", fn ->
             EvoGit.Store.delete_tasks(state.task_store, task_ids)
           end) do
        :ok ->
          safe_store_read("clear_finished_tasks cleanup", :ok, fn ->
            Cleanup.cleanup_expired_tasks(state.task_store)
          end)

          # One event per deleted row — the dashboard needs the id to drop
          # the task from its UI. Broadcast only on the successful write (on
          # disk-full the rows remain and nothing was deleted).
          Enum.each(task_ids, fn task_id ->
            Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_deleted, task_id, node()})

            # Same cascade as a single-task delete: a cleared task owns no
            # durable run state (best-effort, see `delete_agent_state/1`).
            delete_agent_state(task_id)
          end)

          :ok

        {:error, :disk_full} ->
          Logger.warning(
            "TaskRegistry: disk full — #{length(task_ids)} finished tasks could not be deleted"
          )

          {:error, :disk_full}

        {:error, :store_unavailable} ->
          # StoreGuard already logged it; nothing was deleted, so no broadcast.
          {:error, :store_unavailable}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:update_status, task_id, status, result, opts}, state) do
    {:noreply, handle_update_status(state, task_id, status, result, opts, nil)}
  end

  def handle_cast({:update_status, task_id, status, result, opts, caller_info}, state) do
    {:noreply, handle_update_status(state, task_id, status, result, opts, caller_info)}
  end

  @impl true
  def handle_cast({:delete_task, task_id}, state) do
    case safe_store_write("delete_task", fn ->
           EvoGit.Store.delete_task(state.task_store, task_id)
         end) do
      :ok ->
        # Broadcast only on the successful write — on disk-full the row
        # remains and nothing was deleted.
        Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_deleted, task_id, node()})

        # A deleted task owns no durable run state: drop its rows from the
        # SEPARATE agent-state database too, best-effort (see the helper).
        delete_agent_state(task_id)

        :ok

      {:error, :disk_full} ->
        # Fire-and-forget delete (cast): swallow + log — the task row simply
        # remains until disk space is freed and a later delete/cleanup retries.
        Logger.warning("TaskRegistry: disk full — task #{task_id} could not be deleted")

      {:error, :store_unavailable} ->
        # Same fire-and-forget degradation (StoreGuard already logged it).
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_review_status, task_id, status}, state) do
    # Narrow-column existence check: reads only the status column.
    case safe_store_read("set_review_status get_task_status", nil, fn ->
           EvoGit.Store.get_task_status(state.task_store, task_id)
         end) do
      nil ->
        :ok

      # A row that EXISTS — a known status atom OR `{:unknown, raw}` (its status
      # text is unreadable, but the row is there) — is writable. Only a missing
      # row is the no-op; review status is independent of the task status.
      present when not is_nil(present) ->
        case safe_store_write("set_review_status update_task_columns", fn ->
               EvoGit.Store.update_task_columns(state.task_store, task_id, review_status: status)
             end) do
          :ok ->
            :ok

          {:error, :disk_full} ->
            # Fire-and-forget review-status write (cast): swallow + log — the
            # review status stays as-is in the DB until a retry succeeds.
            Logger.warning(
              "TaskRegistry: disk full — review status for task #{task_id} not persisted"
            )

          {:error, :store_unavailable} ->
            :ok
        end
    end

    # Review-status mutations don't change the task status — broadcast nil.
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, task_id, nil, node()})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_review_metadata, task_id, base_sha, commit_sha}, state) do
    # Narrow-column existence check: reads only the status column.
    case safe_store_read("set_review_metadata get_task_status", nil, fn ->
           EvoGit.Store.get_task_status(state.task_store, task_id)
         end) do
      nil ->
        :ok

      # Same tri-state rule as `set_review_status`: `{:unknown, raw}` means the
      # row EXISTS (only its status text is unreadable), so the SHA columns are
      # written; only a missing row is a no-op.
      present when not is_nil(present) ->
        case safe_store_write("set_review_metadata update_task_columns", fn ->
               EvoGit.Store.update_task_columns(state.task_store, task_id,
                 base_sha: base_sha,
                 commit_sha: commit_sha
               )
             end) do
          :ok ->
            :ok

          {:error, :disk_full} ->
            # Fire-and-forget review-metadata write (cast): swallow + log — the
            # review SHAs stay as-is in the DB until a retry succeeds.
            Logger.warning(
              "TaskRegistry: disk full — review metadata for task #{task_id} not persisted"
            )

          {:error, :store_unavailable} ->
            :ok
        end
    end

    # Review-metadata mutations don't change the task status — broadcast nil.
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, task_id, nil, node()})
    {:noreply, state}
  end

  # Shared implementation for the :update_status cast handlers (5- and 6-tuple
  # variants). The optional caller_info is {pid, stacktrace} captured at the
  # call site by update_task_status_with_caller/4, or nil for the plain
  # update_task_status/4 API.
  defp handle_update_status(state, task_id, status, result, opts, caller_info) do
    usage = Keyword.get(opts, :usage)
    agent_count = Keyword.get(opts, :agent_count)
    commit_sha = Keyword.get(opts, :commit_sha)
    error = Keyword.get(opts, :error)

    # Narrow-column read: only status, opts, finished_at, lease_expires_at are
    # fetched (no full 19-column task_get decode) — exactly the fields this
    # handler needs for the stale-guard, preservation, and project_path.
    state =
      case safe_store_read("handle_update_status select_task_update_info", nil, fn ->
             EvoGit.Store.select_task_update_info(state.task_store, task_id)
           end) do
        %{
          status: task_status,
          opts: task_opts,
          finished_at: task_finished_at,
          lease_expires_at: task_lease_expires_at
        } ->
          # Final-result force-mapping for graceful cancellation: a task whose
          # CURRENT stored status is :cancelling that reaches a terminal phase
          # (the wrapper completed/failed during the grace period) must always
          # be persisted as :cancelled — never :completed/:failed. Everything
          # else (result/usage write, terminal bookkeeping) flows
          # through untouched, so intermediate result data is PRESERVED.
          status =
            if task_status == :cancelling and status in [:completed, :failed],
              do: :cancelled,
              else: status

          if task_status in @terminal_statuses and
               status in @terminal_statuses and
               task_status != status and
               status != :completed do
            Logger.warning(
              "TaskRegistry: Ignoring stale status update for task #{task_id}: " <>
                "already #{task_status}, ignoring #{status}"
            )

            state
          else
            # Log any transition INTO :failed that isn't already :failed.
            if status == :failed and task_status != :failed do
              Diagnostics.log_failed_transition(task_id, :update_status_cast, task_status,
                result: result,
                caller_info: caller_info
              )
            end

            finished_at =
              if status in @terminal_statuses,
                do: DateTime.utc_now(),
                else: task_finished_at

            lease_expires_at =
              if status in @terminal_statuses,
                do: nil,
                else: task_lease_expires_at

            project_path = Keyword.get(task_opts, :path)

            branch_name =
              case result do
                {:ok, data} when is_map(data) -> Map.get(data, :branch_name)
                _ -> nil
              end

            # Build a keyword list of exactly what changed — only these columns
            # are written, avoiding re-encoding opts/logs/json blobs.
            # Graceful-cancel guard: an error payload is persisted ONLY when
            # the FINAL status (after the :cancelling force-map above) is
            # :failed AND an error opt was provided. A cancelling task whose
            # wrapper fails during the grace period is force-mapped to
            # :cancelled here — its status variable is :cancelled by this
            # point, so the error is never written.
            update_cols =
              [
                status: status,
                result: result,
                finished_at: finished_at,
                lease_expires_at: lease_expires_at,
                project_path: project_path,
                branch_name: branch_name
              ] ++
                if(status == :failed and error != nil, do: [error: error], else: []) ++
                if(usage, do: [usage: usage], else: []) ++
                if(agent_count, do: [agent_count: agent_count], else: []) ++
                if(commit_sha, do: [commit_sha: commit_sha], else: [])

            case safe_store_write("handle_update_status update_task_columns", fn ->
                   EvoGit.Store.update_task_columns(state.task_store, task_id, update_cols)
                 end) do
              :ok ->
                # Broadcast the persisted status only when it actually changed.
                # A missing row or a stale/no-op update never reaches here, and
                # a disk-full write leaves the row untouched — so this is the
                # single place where the write is known to have happened.
                if status != task_status do
                  Phoenix.PubSub.broadcast(
                    EvoGit.PubSub,
                    "tasks",
                    {:task_updated, task_id, status, node()}
                  )
                end

                # End-of-window marker: the terminal write is known to have hit
                # the store (wrapper result, watchdog resolution, startup
                # reconcile all flow through here).
                if status in @terminal_statuses,
                  do:
                    Logger.info(
                      "TaskRegistry: Task #{task_id} terminal status persisted: #{inspect(status)}"
                    )

                :ok

              {:error, :disk_full} ->
                # The terminal write is lost, but the in-memory cleanup below
                # still runs so the task is not stuck: the task_refs entry is
                # removed and the cancelling marker cleared. The persisted row
                # keeps its old status until disk space is freed.
                Logger.warning(
                  "TaskRegistry: disk full — status write for task #{task_id} " <>
                    "not persisted (status #{inspect(status)})"
                )

              {:error, :store_unavailable} ->
                # StoreGuard already logged it. The terminal write is lost but
                # the in-memory cleanup below still runs (task_refs removal,
                # cancelling marker, tmpdir reclaim) so the task is not stuck.
                :ok
            end

            if status in @terminal_statuses do
              # Terminal state — clean up the graceful-cancel marker (guarded:
              # the scheduler may be down during startup reconciliation).
              clear_cancelling_marker(task_id)

              # Reclaim the task's managed per-task tmpdir (this is the dominant
              # terminal choke point — wrapper result, watchdog resolution and
              # startup reconciliation all flow through here). Best-effort +
              # idempotent; the primary repo path is already in hand.
              EvoGit.TaskTmpdir.reclaim(task_id, project_path)

              %{state | task_refs: Map.delete(state.task_refs, task_id)}
            else
              state
            end
          end

        nil ->
          # Missing row — no write, no broadcast.
          state
      end

    state
  end

  # --- Force-kill write helpers (shared by every force-kill arm) ---

  # The NON-resumable sweep outcome (today's behaviour, unchanged): a leaked
  # live row whose owning instance is gone and whose state cannot be resumed is
  # marked `:failed` with the `:lease_expired` payload.
  defp sweep_fail_task(state, id, lease, changed, failed_ids, paused_ids) do
    Diagnostics.log_failed_transition(id, :lease_sweep, :running,
      result: "Lease expired; owning instance no longer renewing",
      extra: [lease_expires_at: inspect(lease)]
    )

    # Full decode only for this specific task (to build the write-back
    # struct) — there should be very few of these (0-1 in normal use).
    case task_get(state, id) do
      %TaskInfo{} = task ->
        message = "Lease expired; owning instance no longer renewing"

        updated = %{
          task
          | status: :failed,
            lease_expires_at: nil,
            finished_at: DateTime.utc_now(),
            result: message,
            error: Diagnostics.failure_error(:lease_expired, :lease_sweep, message)
        }

        case safe_store_write("lease_sweep put_task", fn ->
               EvoGit.Store.put_task(state.task_store, updated)
             end) do
          :ok ->
            # Direct terminal write (:failed) — bypasses
            # handle_update_status/6, so reclaim the tmpdir here too. The
            # task struct is already in hand, so read the path locally.
            EvoGit.TaskTmpdir.reclaim(id, task_repo_path(task))

            # Teardown consistency: the wrapper is gone, so no scheduler pause
            # may survive the row.
            Pause.abandon(id)

            {true, [id | failed_ids], paused_ids}

          {:error, :disk_full} ->
            # The sweep result is still "changed" (in-memory state and
            # diagnostics updated) — log and continue, but the row was
            # not persisted so no broadcast fires for it.
            Logger.warning(
              "TaskRegistry: disk full — lease-expired task #{id} could not be " <>
                "persisted as :failed"
            )

            {true, failed_ids, paused_ids}

          {:error, :store_unavailable} ->
            # Same in-memory outcome as disk-full (StoreGuard logged it).
            {true, failed_ids, paused_ids}
        end

      nil ->
        {changed, failed_ids, paused_ids}
    end
  end

  # Steps 1–2 of a graceful cancel for a LIVE wrapper (`:running`, and a
  # still-draining `:pausing` after its pause is abandoned).
  defp request_graceful_cancel(state, task_id) do
    # 1. Transition to :cancelling via the normal status-update path so
    #    handle_update_status broadcasts {:task_updated, task_id,
    #    :cancelling, node()} (dashboard sees the change immediately).
    #    :cancelling is NON-terminal, so finished_at stays
    #    nil, the lease stays valid, and the task_refs entry stays. The
    #    returned state is discarded (unchanged for non-terminal).
    handle_update_status(state, task_id, :cancelling, nil, [], {:cancel_request, nil})

    # 2. Notify the scheduler: append the cancel message + set
    #    cancel_requested for every agent of the task, and register the
    #    task in the cancelling marker (blocks new root agents and puts
    #    late registrations into grace).
    #
    # Justified catch :exit — cross-GenServer boundary (TaskRegistry →
    # AgentScheduler). If the scheduler is down, the graceful path can't
    # proceed; the task is left :cancelling (a subsequent force_kill or
    # restart reconciliation resolves it).
    try do
      EvoGit.AgentScheduler.begin_graceful_cancel(task_id)
    catch
      :exit, reason ->
        Logger.warning(
          "TaskRegistry: AgentScheduler begin_graceful_cancel failed (exit): #{inspect(reason)}"
        )
    end

    :ok
  end

  # CANCEL of a `:paused` task — the second IMMEDIATE arm, mirroring `:pending`.
  # There is no wrapper and no agent to ask, so the row is written `:cancelled`
  # directly: `finished_at` set, the lease cleared (it has none anyway) and
  # `pause_kind` dropped so a cancelled task is never mistaken for a resumable
  # one. No `result:` key — a cancel never clobbers a preserved result/usage.
  defp cancel_paused_task(state, task_id) do
    # Best-effort pause teardown (the marker may still be set, the agent flags
    # ended with the sessions).
    Pause.abandon(task_id)

    reply =
      case safe_store_write("cancel_task paused update_task_columns", fn ->
             EvoGit.Store.update_task_columns(state.task_store, task_id,
               status: :cancelled,
               finished_at: DateTime.utc_now(),
               lease_expires_at: nil,
               pause_kind: nil
             )
           end) do
        :ok ->
          :ok

        {:error, :disk_full} ->
          Logger.warning(
            "TaskRegistry: disk full — paused task #{task_id} could not be marked :cancelled"
          )

          {:error, :disk_full}

        {:error, :store_unavailable} ->
          # StoreGuard already logged it; the row keeps :paused, so return the
          # degraded error like disk-full (a later cancel retry would work).
          {:error, :store_unavailable}
      end

    # Direct terminal write (:cancelled) — bypasses handle_update_status/6, so
    # the in-memory cleanup happens here: the ref (absent for a paused row) is
    # dropped either way, the graceful-cancel marker cleared and the managed
    # tmpdir reclaimed.
    state = %{state | task_refs: Map.delete(state.task_refs, task_id)}
    clear_cancelling_marker(task_id)
    reclaim_task_tmpdir(state, task_id)

    if reply == :ok do
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, task_id, :cancelled, node()}
      )
    end

    reply
  end

  # The targeted `:failed` write shared by every force-kill arm. A :running
  # task's result is always nil (results are written only on terminal
  # transitions), so writing `result: nil` preserves the old put_task semantics.
  # `ref` is runtime-only and never persisted. A force-killed task is persisted
  # as :failed (never :cancelled) — "cancelled" means ONLY graceful
  # cancellation — and `pause_kind: nil` drops a pause classification so a
  # killed task can never look resumable. On disk-full the in-memory cleanup
  # still happens (task_refs deleted, markers cleared) and
  # `{:error, :disk_full}` is returned.
  defp force_kill_write(state, task_id) do
    reply =
      case safe_store_write("force_kill_task update_task_columns", fn ->
             EvoGit.Store.update_task_columns(state.task_store, task_id,
               status: :failed,
               finished_at: DateTime.utc_now(),
               lease_expires_at: nil,
               result: nil,
               pause_kind: nil,
               error:
                 Diagnostics.failure_error(
                   :force_kill,
                   :force_kill_task,
                   "Task force-killed by user"
                 )
             )
           end) do
        :ok ->
          :ok

        {:error, :disk_full} ->
          Logger.warning(
            "TaskRegistry: disk full — force-killed task #{task_id} " <>
              "could not be persisted as :failed"
          )

          {:error, :disk_full}

        {:error, :store_unavailable} ->
          # StoreGuard already logged it — the in-memory cleanup below
          # still runs; the row keeps its previous status.
          {:error, :store_unavailable}
      end

    state = %{state | task_refs: Map.delete(state.task_refs, task_id)}

    # Direct terminal write (:failed) — bypasses
    # handle_update_status/6, so reclaim the tmpdir here too. The
    # task is gone in-memory regardless of disk-full retryability.
    reclaim_task_tmpdir(state, task_id)

    {reply, state}
  end

  # FORCE KILL with no live wrapper to stop. A `:paused` task ALWAYS has this
  # shape (no task_refs entry — the wrapper ended when the drain completed) and a
  # `:pausing` one can lose its wrapper to a crash, so both are killable here;
  # any other status keeps today's `{:error, :not_running}`.
  defp force_kill_without_wrapper(state, task_id, status) when status in [:pausing, :paused] do
    # Same teardown as the live arm: no scheduler pause may survive the kill.
    Pause.abandon(task_id)
    clear_cancelling_marker(task_id)

    force_kill_write(state, task_id)
  end

  defp force_kill_without_wrapper(state, _task_id, _status), do: {{:error, :not_running}, state}

  # --- TaskStore Read Helpers ---

  defp task_get(state, task_id) do
    safe_store_read("get_task", nil, fn ->
      EvoGit.Store.get_task(state.task_store, task_id)
    end)
  end

  # Removes a task_id from the :evogit_cancelling_tasks marker once the task
  # reaches a terminal state. Safe and idempotent: prefers the scheduler
  # GenServer (serialized, so it can't race begin_graceful_cancel), but when
  # the scheduler is down (e.g. startup reconciliation — TaskRegistry starts
  # BEFORE the AgentScheduler in the supervision tree) falls back to deleting
  # directly from the public ETS table. Never crashes the caller.
  defp clear_cancelling_marker(task_id) do
    if Process.whereis(EvoGit.AgentScheduler) do
      try do
        EvoGit.AgentScheduler.clear_cancelling_task(task_id)
      catch
        :exit, reason ->
          Logger.warning(
            "TaskRegistry: AgentScheduler clear_cancelling_task failed (exit): #{inspect(reason)}"
          )

          delete_cancelling_marker_ets(task_id)
      end
    else
      delete_cancelling_marker_ets(task_id)
    end

    :ok
  end

  defp delete_cancelling_marker_ets(task_id) do
    case :ets.whereis(:evogit_cancelling_tasks) do
      :undefined -> :ok
      _tid -> :ets.delete(:evogit_cancelling_tasks, task_id)
    end

    :ok
  end

  # --- Task-level pause: restart mapping ---
  #
  # BOTH restart paths classify a wrapper-less `:running`/`:pausing` row through
  # `EvoGit.TaskRegistry.Pause` (the ONE resumability classifier) and land a
  # RESUMABLE one in the DIRTY PAUSE resting state instead of today's `:failed`:
  # `status: :paused`, `pause_kind: :dirty`, `finished_at` nil and NO lease, with
  # `result`/`usage`/archive untouched (a TARGETED write — never a full
  # `put_task`, which would re-encode the heavy JSON columns and could clobber a
  # preserved result).
  #
  # A NON-resumable row is left completely alone here, so `init/1` keeps today's
  # behaviour for it (`:running` → the one-shot `:lease_sweep` after the lease
  # duration; `:pausing` likewise) and the sweep keeps mapping it to `:failed`
  # with the `:lease_expired` payload.
  #
  # Path split: `init/1` handles the rows present AT BOOT (there is no wrapper on
  # a fresh BEAM, so no lease check is needed), the sweep handles the rows that
  # become owner-less LATER (`Lease.leaked?/3`: not owned + expired lease).
  # Returns `:paused` only when the write succeeded — the caller broadcasts the
  # transition exactly once, AFTER the persist.
  defp orphan_to_dirty_pause(state, task_id) do
    case Pause.pause_kind_for_restart(state.task_store, task_id) do
      :dirty ->
        case safe_store_write("restart dirty pause update_task_columns", fn ->
               EvoGit.Store.update_task_columns(state.task_store, task_id,
                 status: :paused,
                 pause_kind: :dirty,
                 finished_at: nil,
                 lease_expires_at: nil
               )
             end) do
          :ok ->
            :paused

          {:error, :disk_full} ->
            Logger.warning(
              "TaskRegistry: disk full — resumable task #{task_id} could not be " <>
                "persisted as a dirty pause"
            )

            :unchanged

          {:error, :store_unavailable} ->
            # StoreGuard already logged it; the row keeps its live status.
            :unchanged
        end

      nil ->
        :unchanged
    end
  end

  # `init/1` reconciliation arm for a live, wrapper-less row at boot.
  defp reconcile_paused(state, task_id, status) do
    case orphan_to_dirty_pause(state, task_id) do
      :paused ->
        Logger.info(
          "TaskRegistry: Task #{task_id} (was #{inspect(status)}) reconciled to a DIRTY PAUSE " <>
            "after restart — resumable from durable agent state"
        )

        Phoenix.PubSub.broadcast(
          EvoGit.PubSub,
          "tasks",
          {:task_updated, task_id, :paused, node()}
        )

        state

      :unchanged ->
        state
    end
  end

  # --- Shared Private Helpers ---

  # GRACEFUL cancel of an idle interactive session (`:awaiting_input`).
  #
  # A waiting session has nothing to save but its transcript, so it is
  # cancelled IMMEDIATELY (never through `:cancelling` — there is no in-flight
  # turn that could honour a grace period): the row is written `:cancelled`
  # with `finished_at` set, the lease cleared and NO `result` column, so the
  # session's transcript/result is preserved. The session process is stopped
  # best-effort; the row's terminal status is authoritative either way.
  #
  # Returns the GenServer reply tuple, because it also threads state (the
  # `task_refs` entry it drops).
  defp cancel_awaiting_input_session(state, task_id) do
    # 1. Stop the session FIRST, while its `task_refs` entry is still present.
    #    The stop is TASK-addressed: an interactive session need not have a
    #    depth-0 SchedMeta `from` pid, so the pid-addressed
    #    `AgentScheduler.force_kill_task_agents/1` cannot find it. Both calls are
    #    best-effort — cross-GenServer (`:exit` when the scheduler is down) and
    #    a build without the task-addressed entry point must never fail the
    #    terminal write below.
    try do
      EvoGit.AgentScheduler.force_kill_task_agents_for_task(task_id)
    rescue
      UndefinedFunctionError ->
        Logger.warning(
          "TaskRegistry: AgentScheduler.force_kill_task_agents_for_task/1 is unavailable — " <>
            "the cancelled session #{task_id} was not stopped by the scheduler"
        )
    catch
      :exit, reason ->
        Logger.warning(
          "TaskRegistry: AgentScheduler force_kill_task_agents_for_task failed (exit): " <>
            inspect(reason)
        )
    end

    # The wrapper Task this instance still owns is stopped here too, BEFORE the
    # terminal write: `Task.shutdown/2` demonitors and flushes the brutal kill's
    # `:DOWN`, so the down handler cannot race the write below and map the task
    # to `:failed`.
    case Map.get(state.task_refs, task_id) do
      %Task{} = task_ref -> Task.shutdown(task_ref, :brutal_kill)
      _ -> :ok
    end

    # 2. Targeted terminal write — deliberately NO `result:` key, so a cancel
    #    never clobbers a session's preserved transcript/result.
    reply =
      case safe_store_write("cancel_task awaiting_input update_task_columns", fn ->
             EvoGit.Store.update_task_columns(state.task_store, task_id,
               status: :cancelled,
               finished_at: DateTime.utc_now(),
               lease_expires_at: nil
             )
           end) do
        :ok ->
          :ok

        {:error, :disk_full} ->
          Logger.warning(
            "TaskRegistry: disk full — waiting session #{task_id} could not be marked :cancelled"
          )

          {:error, :disk_full}

        {:error, :store_unavailable} ->
          # StoreGuard already logged it; the row keeps :awaiting_input, so
          # return the degraded error like disk-full.
          {:error, :store_unavailable}
      end

    # Direct terminal write (:cancelled) — bypasses handle_update_status/6, so
    # the in-memory cleanup happens here: the session is gone whatever the
    # write did, its graceful-cancel marker is cleared and its managed tmpdir is
    # reclaimed.
    state = %{state | task_refs: Map.delete(state.task_refs, task_id)}
    clear_cancelling_marker(task_id)
    reclaim_task_tmpdir(state, task_id)

    if reply == :ok do
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, task_id, :cancelled, node()}
      )
    end

    {:reply, reply, state}
  end

  # --- Managed per-task tmpdir lifecycle ---
  #
  # `EvoGit.TaskTmpdir` owns a per-task scratch directory (`task_<id>` under a
  # node-local managed root). Creation happens in the task wrapper
  # (`TaskExecutor`); RECLAIM happens here on EVERY terminal transition — the
  # handle_update_status/6 choke point PLUS the direct terminal writes that
  # bypass it (force_kill_task, :pending cancel, :lease_sweep,
  # resolve_recheck_task). All reclaims are safe + idempotent and never raise.

  # Reclaims `task_id`'s managed per-task tmpdir when the caller does not
  # already hold the task struct. Resolves the task's PRIMARY repo path
  # (`opts[:path]`) via the narrow select_task_update_info/2 read — a repo-less
  # (reflect) task yields nil and TaskTmpdir falls back to the :system/:custom
  # root. Best-effort: TaskTmpdir.reclaim/2 never raises.
  defp reclaim_task_tmpdir(state, task_id) do
    project_path =
      case safe_store_read("reclaim_task_tmpdir select_task_update_info", nil, fn ->
             EvoGit.Store.select_task_update_info(state.task_store, task_id)
           end) do
        %{opts: opts} when is_list(opts) -> Keyword.get(opts, :path)
        _ -> nil
      end

    EvoGit.TaskTmpdir.reclaim(task_id, project_path)
  end

  # The PRIMARY repo path from a decoded task struct (nil when absent/repo-less).
  defp task_repo_path(%TaskInfo{opts: opts}) when is_list(opts), do: Keyword.get(opts, :path)
  defp task_repo_path(_task), do: nil

  # ── Store fault isolation ────────────────────────────────────────────
  #
  # EVERY synchronous `EvoGit.Store` call in this module goes through one of
  # these two guards, so a failing store READ/WRITE can never exit or crash the
  # registry — the GenServer every dashboard LiveView depends on (full rationale
  # in `EvoGit.TaskRegistry.StoreGuard`).
  #
  #   * `safe_store_read/3` — `fun` is a store read; a failure yields the read's
  #     own EMPTY shape (`degraded`), exactly what `EvoGit.Store` itself answers
  #     with in-process. The happy-path shape never changes.
  #   * `safe_store_write/2` — `fun` is a store write; a failure yields
  #     `{:error, :store_unavailable}`, which call sites handle EXACTLY like
  #     `{:error, :disk_full}`: log + continue with the in-memory behavior.
  #
  # Both log at :error with the operation name, so a degraded store operation is
  # always observable — never silent.
  defp safe_store_read(op, degraded, fun), do: StoreGuard.read(op, degraded, fun)
  defp safe_store_write(op, fun), do: StoreGuard.write(op, fun)

  # A task delete cascades to the task's DURABLE agent state, which lives in a
  # SEPARATE best-effort SQLite database (`EvoGit.AgentState`). A failed
  # cleanup must never break the delete (the task row is already gone and the
  # dashboard has been told), and retention pruning is the backstop — so this
  # contains every failure and only logs it.
  defp delete_agent_state(task_id) do
    EvoGit.AgentState.delete_task(task_id)
  rescue
    error ->
      log_agent_state_delete_failure(task_id, error)
  catch
    :exit, reason ->
      log_agent_state_delete_failure(task_id, {:exit, reason})
  end

  defp log_agent_state_delete_failure(task_id, detail) do
    Logger.warning(
      "TaskRegistry: could not delete durable agent state for task #{task_id} " <>
        "(#{inspect(detail)}); retention pruning will reclaim it"
    )
  end

  # ── Unreadable persisted status (`{:unknown, raw}`) ──────────────────
  #
  # `Store.get_task_status/2` answers THREE shapes: `nil` (no row), a known
  # status atom, or `{:unknown, raw}` (the row EXISTS but its status text is
  # outside `Store.Codec.known_statuses/0`; the codec already logged it). Every
  # consumer above treats `{:unknown, _}` as a PRESENT row and never as absent;
  # this helper only makes that degradation visible in the log — it changes no
  # decision.
  defp log_unreadable_status(op, task_id, {:unknown, raw}) do
    Logger.warning(
      "TaskRegistry: #{op} #{task_id} — persisted status #{inspect(raw)} is not a known " <>
        "status; treating the row as PRESENT (never as absent/leaked)"
    )
  end

  defp log_unreadable_status(_op, _task_id, _status), do: :ok

  # Resolves this process's registry instance (`server/0`) to the store it was
  # started with, WITHOUT calling the registry — the whole point of the archive
  # producer write running in the caller (see `put_task_archive/1`). The mapping
  # is published by `init/1` into the app-owned `@store_table`; an instance that
  # never published (registry not started yet / already gone) falls back to the
  # default store, which is what `init/1` defaults `:task_store` to.
  defp archive_store do
    registry = server()

    case :ets.whereis(@store_table) do
      :undefined ->
        EvoGit.Store

      _table ->
        case :ets.lookup(@store_table, registry) do
          [{^registry, store}] -> store
          [] -> EvoGit.Store
        end
    end
  end

  # Publishes `server_name => task_store` for `archive_store/0`. Never raises: a
  # missing table (a registry started outside the `:evo_git` application, e.g. a
  # bare `start_link/1` in a script) only means archive writes target the
  # default store — it must not crash a registry boot.
  defp publish_store(server_name, task_store) do
    case :ets.whereis(@store_table) do
      :undefined ->
        Logger.warning(
          "TaskRegistry: the #{@store_table} ETS table is missing — archive writes will " <>
            "target #{inspect(EvoGit.Store)}"
        )

      _table ->
        :ets.insert(@store_table, {server_name, task_store})
    end
  end

  # Delegates a heavy Store read to a supervised worker so the decoded term is
  # allocated AND discarded on that worker's heap instead of ratcheting up this
  # GenServer's heap; the worker replies to `from` itself, so the value never
  # enters the registry (full contract: `EvoGit.TaskRegistry.ReadOffload`).
  # `fun` closes over the CURRENT state — captured here, before the worker runs.
  # `degraded` is this read's own empty shape, used when the worker cannot
  # answer (spawn failure, crash, or the deadline).
  defp offload(from, state, op, degraded, fun) do
    pending = ReadOffload.start(state.read_offloads, op, degraded, from, fun)
    {:noreply, %{state | read_offloads: pending}}
  end

  # Reverse lookup: finds the task id whose in-memory %Task{} ref matches `ref`.
  defp task_id_for_ref(state, ref) do
    Enum.find_value(state.task_refs, fn {id, %Task{ref: task_ref}} ->
      if task_ref == ref, do: id
    end)
  end

  # Reads the task's currently persisted status (nil when the task is unknown),
  # used to log failed transitions with the previous status.
  defp prev_status(state, task_id) do
    case task_get(state, task_id) do
      %TaskInfo{status: s} -> s
      nil -> nil
    end
  end

  # Captures and formats the current process stacktrace as the persisted
  # `TaskInfo.error.stacktrace` shape — a list of one formatted frame string
  # per frame (`[String.t()]`, via Diagnostics.format_stacktrace_frame/1).
  # Used by the in-handler failure paths (wrapper result handler, wrapper
  # :DOWN handler) when a backtrace is available at the failure site.
  defp stacktrace_lines do
    Diagnostics.capture_stacktrace(8)
    |> Enum.map(&Diagnostics.format_stacktrace_frame/1)
  end

  # Extracts an optional typed field from a `{:ok, map}` task result. `validator`
  # mirrors the original case-arm TYPE GUARD (e.g.
  # `&match?(%EvoGit.Agent.Usage{}, &1)`), so a wrong-typed or absent value
  # still yields nil and never flows into the DB write.
  defp result_field(result, key, validator) do
    case result do
      {:ok, data} when is_map(data) ->
        case Map.fetch(data, key) do
          {:ok, value} -> if validator.(value), do: value, else: nil
          :error -> nil
        end

      _ ->
        nil
    end
  end

  # Shared result-recovery logic used by handle_info({:recheck_task, _}). The
  # wrapper process is dead so the runtime result was lost (delivered via
  # GenServer.reply to a dead process). We try a best-effort result lookup from
  # the sched_meta ETS table. If nothing definitive is found, we mark the task
  # :completed — agents finished without a recorded failure, so treating it as
  # completed is the least surprising outcome.
  defp resolve_recheck_task(state, task_id, %TaskInfo{} = task) do
    result = Lease.lookup_sched_meta_result(task_id)

    {final_status, final_result} =
      case result do
        {:ok, _} = ok ->
          {:completed, ok}

        {:error, _} = err ->
          {:failed, err}

        {:exit, _} = exit_val ->
          {:failed, exit_val}

        nil ->
          Logger.warning(
            "TaskRegistry: recheck resolved task #{task_id} — no result found, " <>
              "marking :completed (agents finished, wrapper was dead)"
          )

          {:completed, nil}
      end

    if final_status == :failed do
      Diagnostics.log_failed_transition(task_id, :recheck_resolve, task.status,
        result: final_result
      )
    end

    finished_at = DateTime.utc_now()

    # Mirror handle_update_status/6's extraction: pull branch_name from tuple
    # results when present. Included in the write only when non-nil — writing
    # nil would clobber an existing branch_name persisted earlier.
    branch_name =
      case final_result do
        {:ok, data} when is_map(data) -> Map.get(data, :branch_name)
        _ -> nil
      end

    update_cols =
      [
        status: final_status,
        result: final_result,
        finished_at: finished_at,
        lease_expires_at: nil
      ] ++ if(branch_name, do: [branch_name: branch_name], else: [])

    # Targeted write — only the changed columns; `ref` is runtime-only and
    # never persisted. On disk-full the task stays in its previous persisted
    # state — log and continue (the in-memory resolution is complete).
    # Broadcast only when the write actually happened (status after resolve).
    case safe_store_write("resolve_recheck_task update_task_columns", fn ->
           EvoGit.Store.update_task_columns(state.task_store, task_id, update_cols)
         end) do
      :ok ->
        Phoenix.PubSub.broadcast(
          EvoGit.PubSub,
          "tasks",
          {:task_updated, task_id, final_status, node()}
        )

        # Terminal write persisted — reclaim this task's managed per-task tmpdir
        # (this is the one terminal path that bypasses handle_update_status/6).
        EvoGit.TaskTmpdir.reclaim(task_id, task_repo_path(task))

        :ok

      {:error, :disk_full} ->
        Logger.warning(
          "TaskRegistry: disk full — recheck resolution for task #{task_id} " <>
            "(#{final_status}) not persisted"
        )

      {:error, :store_unavailable} ->
        # StoreGuard already logged it — the in-memory resolution is complete.
        :ok
    end

    Logger.info("TaskRegistry: recheck resolved task #{task_id} to #{final_status}")

    {:noreply, state}
  end

  # --- Stuck-:finalizing grace watchdog ---
  #
  # Hardens the :finalizing stage against a wrapper that stays ALIVE but blocks
  # forever in an uninterruptible git call (e.g. merge_and_report/3 on an
  # NFS-mounted home — no timeout, no in-process resolution while the BEAM stays
  # up). When a task enters :finalizing we schedule a ONE-SHOT watchdog timer
  # (reusing the {:recheck_task, task_id} message shape); when it fires while
  # the task is STILL :finalizing, the task is resolved to :failed regardless of
  # scheduler/agent state — the whole point is that the wrapper is
  # alive-but-blocked, so the grace expiry resolves the task.

  # Reads the app-env seam `Application.get_env(:evo_git,
  # :finalizing_watchdog_grace_minutes)` and normalizes it to
  # `:disabled | {:ok, minutes}`:
  #   - false        -> :disabled (no timer scheduled; zero behavioral change)
  #   - nil / unset  -> default 60 minutes
  #   - numeric >= 0 -> that many minutes (0 = fire immediately; float/fractional
  #                     values tolerated)
  #   - any other    -> default 60 (defensive)
  defp finalizing_watchdog_grace do
    case Application.get_env(:evo_git, :finalizing_watchdog_grace_minutes) do
      false -> :disabled
      nil -> {:ok, @finalizing_watchdog_default_minutes}
      minutes when is_number(minutes) and minutes >= 0 -> {:ok, minutes}
      _ -> {:ok, @finalizing_watchdog_default_minutes}
    end
  end

  # The minutes named in the watchdog's result message, re-read at RESOLUTION
  # time so a mid-flight env change is reflected. :disabled here is only
  # possible if the env flipped to false after scheduling (a fire implies it was
  # enabled at schedule time) — fall back to the default.
  defp finalizing_watchdog_result_minutes do
    case finalizing_watchdog_grace() do
      :disabled -> @finalizing_watchdog_default_minutes
      {:ok, minutes} -> minutes
    end
  end

  # Schedules the one-shot watchdog for a task that just entered :finalizing
  # (called from the :ok arm of the :finalizing PubSub handler's put_task).
  # Delay = trunc(minutes * 60_000) — always an INTEGER (Process.send_after
  # rejects floats); minutes = 0 fires immediately. :disabled -> no timer.
  defp schedule_finalizing_watchdog(task_id) do
    case finalizing_watchdog_grace() do
      :disabled ->
        :ok

      {:ok, minutes} ->
        delay = trunc(minutes * 60_000)
        Process.send_after(self(), {:recheck_task, task_id}, delay)

        Logger.debug(
          "TaskRegistry: scheduled :finalizing watchdog for task #{task_id} in #{delay}ms"
        )

        :ok
    end
  end

  # Watchdog resolution: the task is STILL :finalizing past the grace period.
  # Resolve to :failed via the shared handle_update_status/6 — mirroring the
  # startup-reconcile call style ({:startup_reconcile, :finalizing}), which
  # gives Diagnostics failed-transition logging, finished_at/lease handling, the
  # {:task_updated, task_id, :failed, node()} broadcast (only on a successful
  # write), clear_cancelling_marker, and the task_refs deletion. Deliberately
  # does NOT check Lease.sched_meta_has_active_agents? and does NOT reschedule —
  # the wrapper is alive-but-blocked; the grace expiry resolves the task. No git
  # timeouts added, nothing killed (residual sched_meta/agent state is left
  # untouched, mirroring startup reconciliation).
  defp resolve_finalizing_watchdog(state, task_id, %TaskInfo{}) do
    minutes = finalizing_watchdog_result_minutes()
    result = "Finalization did not complete within #{minutes} minutes"

    Logger.warning(
      "TaskRegistry: :finalizing watchdog fired for task #{task_id} — " <>
        "finalization did not complete within #{minutes} minutes; resolving to :failed"
    )

    state =
      handle_update_status(
        state,
        task_id,
        :failed,
        result,
        [error: Diagnostics.failure_error(:timeout, :finalizing_watchdog, result)],
        {:finalizing_watchdog, task_id}
      )

    {:noreply, state}
  end

  ## GenServer Info Handlers

  @impl true
  def handle_info({:task_updated, task_id, :finalizing, node}, state) when node == node() do
    # :finalizing is the ONLY status acted on here — other statuses in
    # {:task_updated, ...} are persisted locally by TaskRegistry itself and
    # must not be reprocessed. A broadcast from a remote node (node !=
    # node()) is ignored by the no-op clause below: task ids are per-node,
    # so a cross-node collision would corrupt local rows.
    state =
      case task_get(state, task_id) do
        %TaskInfo{} = task ->
          # Ignore stale :finalizing updates for tasks already terminal AND
          # for tasks in graceful cancel (:cancelling) — a cancelling task
          # that reaches phase finalization keeps :cancelling (the more
          # informative state; the final mapping to :cancelled happens at
          # result time in handle_update_status/6).
          if task.status in @finalizing_ignored_statuses do
            Logger.debug(
              "TaskRegistry: Ignoring stale :task_updated finalizing update for task #{task_id}: " <>
                "already #{task.status}, ignoring :finalizing"
            )

            state
          else
            # :finalizing is NON-terminal — finished_at and the lease stay as
            # they are; the final terminal mapping happens at result time in
            # handle_update_status/6.
            updated = %{task | status: :finalizing}

            # On disk-full the persisted row keeps its old status — log and
            # continue.
            case safe_store_write("finalizing put_task", fn ->
                   EvoGit.Store.put_task(state.task_store, updated)
                 end) do
              :ok ->
                # The row is now :finalizing — schedule the ONE-SHOT stuck-
                # :finalizing grace watchdog (only here, NOT on the disk-full
                # path where the row never became :finalizing and the existing
                # mechanisms stay as-is). :disabled -> no timer.
                schedule_finalizing_watchdog(task_id)
                :ok

              {:error, :disk_full} ->
                Logger.warning(
                  "TaskRegistry: disk full — :task_updated finalizing update for task #{task_id} " <>
                    "not persisted (status :finalizing)"
                )

              {:error, :store_unavailable} ->
                # StoreGuard already logged it — the row keeps its old status
                # and no watchdog is scheduled.
                :ok
            end

            state
          end

        nil ->
          state
      end

    {:noreply, state}
  end

  # A remote node's :finalizing broadcast must NEVER be persisted into the
  # local store — task ids are per-node, so a cross-node collision would
  # corrupt local rows.
  def handle_info({:task_updated, _task_id, :finalizing, _other_node}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    if ReadOffload.offload?(state.read_offloads, ref) do
      # A read worker reported in: it already replied to its caller with
      # `GenServer.reply/2` (its reply is its last statement), so the payload
      # here is only the reply's `:ok`. The entry is settled by the `:DOWN`
      # right behind this message (or by the deadline).
      {:noreply, state}
    else
      handle_wrapper_result(ref, result, state)
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case ReadOffload.settle_down(state.read_offloads, ref, reason) do
      {:settled, pending} ->
        # A read worker: `:normal` means it already replied to its caller with
        # the real value, any other reason means that caller got the read's
        # degraded value. Either way the entry is done.
        {:noreply, %{state | read_offloads: pending}}

      :unknown ->
        handle_wrapper_down(ref, pid, reason, state)
    end
  end

  # The read-worker deadline: the worker wedged, so it is killed and its caller
  # gets the read's degraded value (never an exit).
  @impl true
  def handle_info({:read_offload_deadline, ref}, state) do
    {:noreply, %{state | read_offloads: ReadOffload.settle_deadline(state.read_offloads, ref)}}
  end

  # Periodic heartbeat handler. Renews leases for ALL tasks this registry owns
  # (in task_refs that are running/pending), so that we remain the authoritative
  # owner. This is purely renewal — no sweeping happens here. Reschedules itself.
  @impl true
  def handle_info(:heartbeat, state) do
    now = System.system_time(:second)

    # Renew leases for owned tasks using lightweight queries — avoids full
    # decode (task_get) + full re-encode (put_task) for every owned task on
    # every heartbeat. `Lease.lease_renewable?/1` is the ONE renewal
    # classification: it covers `:running | :pending | :cancelling` (a long
    # graceful cancel keeps its lease while the wrapper is still alive) AND
    # `{:unknown, raw}` — a row that EXISTS with status text we cannot read is
    # renewed, never left to expire, so an unrecognized status spelling can
    # never make a LIVE task look leaked to the sweep. `nil` (no row) and every
    # terminal status renew nothing.
    Enum.each(state.task_refs, fn {task_id, _ref} ->
      status =
        safe_store_read("heartbeat get_task_status", nil, fn ->
          EvoGit.Store.get_task_status(state.task_store, task_id)
        end)

      if Lease.lease_renewable?(status) do
        case safe_store_write("heartbeat update_lease_expires_at", fn ->
               EvoGit.Store.update_lease_expires_at(
                 state.task_store,
                 task_id,
                 now + @lease_duration
               )
             end) do
          :ok ->
            :ok

          {:error, :disk_full} ->
            # Fire-and-forget heartbeat renewal: swallow + log. The lease
            # simply expires on schedule if it cannot be renewed; the sweep
            # then treats the task as orphaned (correct degradation).
            Logger.warning(
              "TaskRegistry: disk full — lease renewal for task #{task_id} not persisted"
            )

          {:error, :store_unavailable} ->
            # Same degradation (StoreGuard already logged it).
            :ok
        end
      end
    end)

    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, state}
  end

  # One-shot lease-expiry sweep handler. Sweeps ALL running tasks we DON'T own
  # with expired leases and no active sched_meta agents, marking them :failed
  # (the owning instance is gone). This fires once (scheduled in init after the
  # lease duration) and does NOT reschedule itself — any new foreign instance
  # performs its own pair of checks on its own startup.
  @impl true
  def handle_info(:lease_sweep, state) do
    owned_ids = MapSet.new(Map.keys(state.task_refs))

    # Use the lightweight query — only id, status, and lease_expires_at are
    # decoded, avoiding the full struct decode for every task in the table.
    # We only need to task_get (full decode) for the very few tasks (usually
    # 0-1) that actually need to be marked :failed.
    {changed, failed_ids, paused_ids} =
      safe_store_read("lease_sweep select_running_lease_info", [], fn ->
        EvoGit.Store.select_running_lease_info(state.task_store)
      end)
      |> Enum.filter(fn %{id: id, status: status, lease_expires_at: lease} ->
        # `Lease.leaked?/3` is the ONE leak classification (the same module the
        # heartbeat's `lease_renewable?/1` lives in): leaked means a KNOWN
        # `:running`/`:pausing` row, not owned by this instance, with an
        # expired/missing lease. `{:unknown, raw}` is NEVER leaked — the row
        # exists, its status is merely unreadable, so a spelling must never fail
        # a live task. A `:paused` row is never leaked either (no lease, no
        # wrapper): it is this sweep's OUTPUT, never its input.
        #
        # Defence-in-depth: `Store.select_running_lease_info/1` already pushes
        # `status IN ('running','pausing','finalizing','cancelling')` into SQL,
        # so an unreadable status text cannot even reach this filter; the
        # classifier stays the single source of truth rather than an inline
        # re-derivation.
        Lease.leaked?(status, MapSet.member?(owned_ids, id), lease)
      end)
      |> Enum.reduce({false, [], []}, fn
        %{id: id, lease_expires_at: lease}, {changed, failed_ids, paused_ids} ->
          if Lease.sched_meta_has_active_agents?(id) do
            # Same VM, agents still active — skip (handled by :recheck_task)
            {changed, failed_ids, paused_ids}
          else
            # TASK PAUSE first: a RESUMABLE orphan (durable agent state present)
            # becomes a DIRTY PAUSE — the wrapper-less row parks in `:paused` with
            # `pause_kind: :dirty`, `finished_at` nil and no lease, its
            # result/usage untouched, and the caller broadcasts `:paused` once
            # after the persist. A NON-resumable row keeps today's
            # `:lease_expired` → `:failed`.
            case orphan_to_dirty_pause(state, id) do
              :paused ->
                Logger.info(
                  "TaskRegistry: lease-expired task #{id} parked as a DIRTY PAUSE — resumable from durable agent state"
                )

                # Teardown consistency: no scheduler pause may survive the row.
                Pause.abandon(id)

                {true, failed_ids, [id | paused_ids]}

              :unchanged ->
                sweep_fail_task(state, id, lease, changed, failed_ids, paused_ids)
            end
          end
      end)

    if changed do
      safe_store_read("lease_sweep cleanup", :ok, fn ->
        Cleanup.cleanup_expired_tasks(state.task_store)
      end)
    end

    # One event per successfully-persisted sweep — the dashboard needs the id
    # to attribute the :failed/:paused status to the specific task.
    Enum.each(failed_ids, fn id ->
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, id, :failed, node()})
    end)

    Enum.each(paused_ids, fn id ->
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, id, :paused, node()})
    end)

    {:noreply, state}
  end

  # Periodic cleanup handler: sweeps expired finished tasks to enforce
  # max_age_days and max_tasks limits. Reschedules itself every 5 minutes.
  @impl true
  def handle_info(:periodic_cleanup, state) do
    safe_store_read("periodic_cleanup", :ok, fn ->
      Cleanup.cleanup_expired_tasks(state.task_store)
    end)

    Process.send_after(self(), :periodic_cleanup, 300_000)
    {:noreply, state}
  end

  # Periodic recheck for tasks that had active agents but a dead wrapper pid at
  # reconcile time. The task could not be added to task_refs (no live process to
  # monitor), so the normal {ref, result} / {:DOWN, ...} handlers can never fire.
  # This handler periodically checks if agents are still active:
  #   - If YES: reschedule another check.
  #   - If NO: resolve the task. Since the wrapper process is dead, the runtime
  #     result was delivered via GenServer.reply to a dead process and is lost.
  #     We check the sched_meta ETS for any remaining entries (which may carry a
  #     result in sub_agent_results) as a best-effort lookup. If nothing
  #     definitive is found, we mark the task :completed — the agents finished
  #     without a recorded failure, so treating it as completed is the least
  #     surprising outcome.
  @impl true
  def handle_info({:recheck_task, task_id}, state) do
    case task_get(state, task_id) do
      nil ->
        # Task was cleaned up from the store — nothing to do.
        {:noreply, state}

      %TaskInfo{status: status} when status in @terminal_statuses ->
        # Task already resolved via another path (e.g. PubSub update) — stop rechecking.
        {:noreply, state}

      %TaskInfo{status: :finalizing} = task ->
        # Stuck-:finalizing grace watchdog fired while the task is STILL
        # :finalizing — the wrapper is alive but blocked past the grace period
        # (e.g. uninterruptible git I/O in merge_and_report/3). Resolve to
        # :failed regardless of scheduler state; do NOT reschedule.
        resolve_finalizing_watchdog(state, task_id, task)

      %TaskInfo{} = task ->
        if Lease.sched_meta_has_active_agents?(task_id) do
          # Agents still active — reschedule another check.
          Process.send_after(self(), {:recheck_task, task_id}, 30_000)
          {:noreply, state}
        else
          resolve_recheck_task(state, task_id, task)
        end
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # The task WRAPPER's result message — `Task.Supervisor.async_nolink/4` sends
  # `{ref, result}` to the wrapper's owner (this registry). Maps it to the
  # task's terminal status, or — for `{:paused, info}` — to the PAUSED RESTING
  # STATE (see `persist_paused/3`).
  defp handle_wrapper_result(ref, result, state) do
    # Search the in-memory task_refs map for the matching task reference
    task_id = task_id_for_ref(state, ref)

    state =
      if task_id do
        case result do
          # TASK-LEVEL PAUSE: the drain completed, so the wrapper reported a
          # pause instead of a `%Result{}`. The task parks in `:paused`; a paused
          # task is NOT finished (`finished_at` stays nil) and has no lease.
          {:paused, info} ->
            persist_paused(state, task_id, info)

          # STRAGGLER GUARD — see `pause_settled?/2`: once the task is
          # `:pausing`/`:paused`, NO late result may resurrect it.
          _ ->
            if pause_settled?(state, task_id) do
              discard_paused_result(state, task_id, result)
            else
              persist_wrapper_result(state, task_id, result)
            end
        end
      else
        # The result cannot be persisted — no matching in-memory task_refs entry
        # (e.g. the registry restarted after the wrapper finished, wiping the
        # refs, or the message is stale). Leave a trail so stranded tasks are
        # attributable instead of failing silently.
        Logger.warning(
          "TaskRegistry: received task result for unknown ref #{inspect(ref)} — " <>
            "no matching task_refs entry (registry restarted?); result dropped"
        )

        state
      end

    Process.demonitor(ref, [:flush])

    {:noreply, state}
  end

  # Maps a real wrapper result to the task's terminal status (today's behaviour,
  # unchanged). Returns state untouched — the state cleanup happens in
  # `handle_update_status/6` for a terminal status.
  defp persist_wrapper_result(state, task_id, result) do
    # Map the wrapper result to a terminal status. For :failed the arm ALSO
    # builds the persisted error payload (same arm → the reason and its human
    # message stay in lockstep): {:error, reason} records kind :error,
    # {:exit, reason} records kind :exit, and any other shape records
    # kind :error with an "unexpected result shape" message.
    {status, error} =
      case result do
        {:ok, _} ->
          {:completed, nil}

        {:error, reason} ->
          Logger.warning("TaskRegistry: Task #{task_id} returned error: #{inspect(reason)}")
          message = "Task failed: #{inspect(reason)}"

          {:failed,
           Diagnostics.failure_error(:error, :result_handler, message, stacktrace_lines())}

        {:exit, reason} ->
          Logger.warning("TaskRegistry: Task #{task_id} exited: #{inspect(reason)}")
          message = "Task exited: #{inspect(reason)}"

          {:failed,
           Diagnostics.failure_error(:exit, :result_handler, message, stacktrace_lines())}

        other ->
          Logger.warning(
            "TaskRegistry: Task #{task_id} returned unexpected result shape: #{inspect(other)}"
          )

          message = "Task returned unexpected result shape: #{inspect(other)}"

          {:failed,
           Diagnostics.failure_error(:error, :result_handler, message, stacktrace_lines())}
      end

    # Log the failed transition with the result value and current stacktrace.
    if status == :failed do
      Diagnostics.log_failed_transition(
        task_id,
        :result_handler,
        prev_status(state, task_id),
        result: result
      )
    end

    Logger.info(
      "TaskRegistry: Task #{task_id} wrapper returned — persisting terminal status #{inspect(status)}"
    )

    update_task_status_with_caller(task_id, status, result,
      usage: result_field(result, :usage, &match?(%EvoGit.Agent.Usage{}, &1)),
      agent_count: result_field(result, :agent_count, &is_integer/1),
      commit_sha: result_field(result, :commit_sha, &is_binary/1),
      error: error
    )

    state
  end

  # --- Task-level pause: wrapper result handling ---

  # The wrapper reported `{:paused, info}`: the drain completed and the task
  # parks in the PAUSED RESTING STATE.
  #
  # A TARGETED write (never a full `put_task`) — `result`, `usage`, `commit_sha`,
  # `branch_name`, `started_at` and `opts` are left byte-identical, which is what
  # makes a later resume ACCUMULATE usage and keep the same report. `finished_at`
  # is written NIL: a paused task is not finished, and the dashboard must not
  # date it. `pause_kind: :clean` records that the agents stopped at a turn
  # boundary (no in-flight tool batch to repair), which the resume turns into
  # `resume_kind: :clean_pause`.
  #
  # WHY ONE RESULT IS ENOUGH for a multi-agent drain: the scheduler orders the
  # drain — the ROOT agent only reports `{:paused, info}` once its children have
  # paused, so this single wrapper result closes the whole task.
  defp persist_paused(state, task_id, _info) do
    case safe_store_read("paused wrapper result select_task_update_info", nil, fn ->
           EvoGit.Store.select_task_update_info(state.task_store, task_id)
         end) do
      %{status: status} when status in [:pausing, :running] ->
        write_paused(state, task_id)

      %{status: :cancelling} ->
        # A cancel that arrived while the drain was in flight WINS (the pause was
        # abandoned scheduler-side). The wrapper is gone, so resolve the row the
        # way the cancellation model does: the normal status path force-maps a
        # terminal phase of a `:cancelling` task to `:cancelled` and runs the
        # usual teardown (markers, tmpdir, task_refs).
        Logger.info(
          "TaskRegistry: Task #{task_id} reported a PAUSE while :cancelling — the cancel wins"
        )

        update_task_status_with_caller(task_id, :cancelled, nil, [])
        state

      %{status: :paused} ->
        # Already parked (a duplicated result, or a restart reconciled the row
        # while the wrapper was still finishing): nothing to persist or
        # broadcast.
        finish_paused_bookkeeping(state, task_id)

      %{status: status} ->
        # Terminal / `:awaiting_input` — the pause lost a race; never overwrite a
        # resolved row with `:paused`.
        Logger.info(
          "TaskRegistry: discarding PAUSE report for task #{task_id} in status #{inspect(status)}"
        )

        %{state | task_refs: Map.delete(state.task_refs, task_id)}

      nil ->
        %{state | task_refs: Map.delete(state.task_refs, task_id)}
    end
  end

  defp write_paused(state, task_id) do
    case safe_store_write("paused wrapper result update_task_columns", fn ->
           EvoGit.Store.update_task_columns(state.task_store, task_id,
             status: :paused,
             pause_kind: :clean,
             finished_at: nil,
             lease_expires_at: nil
           )
         end) do
      :ok ->
        Logger.info(
          "TaskRegistry: Task #{task_id} PAUSED (clean checkpoint) — resume re-enqueues the same id"
        )

        Phoenix.PubSub.broadcast(
          EvoGit.PubSub,
          "tasks",
          {:task_updated, task_id, :paused, node()}
        )

        finish_paused_bookkeeping(state, task_id)

      {:error, :disk_full} ->
        # The paused write is lost, so no broadcast fires; the row keeps
        # `:pausing` with no wrapper and the lease sweep turns it into a DIRTY
        # PAUSE once the lease expires (degraded, never stuck in a live status).
        Logger.warning(
          "TaskRegistry: disk full — paused task #{task_id} could not be persisted as :paused"
        )

        %{state | task_refs: Map.delete(state.task_refs, task_id)}

      {:error, :store_unavailable} ->
        # StoreGuard already logged it; same degraded path as disk-full.
        %{state | task_refs: Map.delete(state.task_refs, task_id)}
    end
  end

  # Shared in-memory cleanup of the paused transition: the wrapper is done (drop
  # its ref exactly like a terminal result) and the scheduler pause marker/flags
  # are cleared — the drain is over, so nothing may keep honouring a pause.
  defp finish_paused_bookkeeping(state, task_id) do
    Pause.abandon(task_id)
    %{state | task_refs: Map.delete(state.task_refs, task_id)}
  end

  # The STRAGGLER GUARD: `true` when the row is already `:pausing`/`:paused`, i.e.
  # a late `{:ok, %Result{}}` / `{:error, _}` from a wrapper (or a `:DOWN`) must be
  # DISCARDED. A straggler must never resurrect a paused task, flip it to
  # `:completed`/`:failed`, or clobber the result/usage a later resume relies on.
  defp pause_settled?(state, task_id) do
    case safe_store_read("pause straggler select_task_update_info", nil, fn ->
           EvoGit.Store.select_task_update_info(state.task_store, task_id)
         end) do
      %{status: status} when status in [:pausing, :paused] -> true
      _ -> false
    end
  end

  defp discard_paused_result(state, task_id, result) do
    Logger.info(
      "TaskRegistry: discarding #{inspect(result_shape(result))} wrapper result for task " <>
        "#{task_id} — the task is pausing/paused, so a straggler never changes it"
    )

    %{state | task_refs: Map.delete(state.task_refs, task_id)}
  end

  # A compact, log-safe shape (a `%Result{}` or a long reason must never be
  # dumped into the log).
  defp result_shape({:ok, %module{}}), do: {:ok, module}
  defp result_shape({:ok, _other}), do: {:ok, :value}
  defp result_shape({:error, _reason}), do: :error
  defp result_shape(_other), do: :other

  # The task WRAPPER's `:DOWN`.
  defp handle_wrapper_down(ref, pid, reason, state) do
    task_id = task_id_for_ref(state, ref)

    cond do
      task_id == nil ->
        # No matching in-memory task_refs entry (e.g. the registry restarted after
        # the wrapper exited, wiping the refs). Leave a trail so a lost result is
        # attributable instead of being a silent no-op.
        Logger.warning(
          "TaskRegistry: received :DOWN for unknown ref #{inspect(ref)} (pid #{inspect(pid)}, " <>
            "reason #{inspect(reason)}) — no matching task_refs entry; ignoring"
        )

        {:noreply, state}

      # STRAGGLER GUARD (same rule as the wrapper result): a `:pausing`/`:paused`
      # task is never flipped to `:completed`/`:failed` by a wrapper that died
      # after the drain.
      pause_settled?(state, task_id) ->
        {:noreply, discard_paused_result(state, task_id, {:down, reason})}

      true ->
        do_handle_wrapper_down(task_id, pid, reason, state)
        {:noreply, state}
    end
  end

  defp do_handle_wrapper_down(task_id, pid, reason, state) do
    case reason do
      :normal ->
        # Normal completion via :DOWN (task returned a result and exited cleanly).
        # The {ref, result} handler should have already processed this, but handle
        # the edge case where {ref, result} was somehow missed.
        update_task_status(task_id, :completed)

      reason ->
        Logger.warning(
          "TaskRegistry: Task #{task_id} wrapper process #{inspect(pid)} exited abnormally: #{inspect(reason)}. " <>
            "Checking if AgentScheduler still has active agents before marking as failed."
        )

        # Check if the AgentScheduler still has active agents for this task.
        # If so, the wrapper crashed but the real work is still ongoing — do NOT
        # mark as failed. The task will complete normally when the scheduler
        # eventually finishes and the result arrives via a different mechanism.
        if Lease.sched_meta_has_active_agents?(task_id) do
          Logger.info(
            "TaskRegistry: Task #{task_id} still has active agents in AgentScheduler — keeping as :running despite wrapper crash"
          )

          # Do NOT update status — leave as :running
        else
          # No active agents — genuine failure
          Diagnostics.log_failed_transition(task_id, :down_handler, prev_status(state, task_id),
            result: "Task process exited: #{inspect(reason)}",
            extra: [
              pid: inspect(pid),
              exit_reason: inspect(reason),
              sched_meta_has_active_agents: false
            ]
          )

          message = "Task process exited: #{inspect(reason)}"

          update_task_status_with_caller(task_id, :failed, message,
            error: Diagnostics.failure_error(:down, :down_handler, message, stacktrace_lines())
          )
        end
    end
  end
end
