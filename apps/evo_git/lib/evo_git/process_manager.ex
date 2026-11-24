defmodule EvoGit.ProcessManager do
  @moduledoc """
  THE single source of truth for the live OS executions an agent/task holds.

  Genesis holds work in three shapes — a foreground tool call (a shell command
  or a built-in tool an agent blocks on), a detached background job
  (`EvoGit.BackgroundJobs`) and the sandbox trees those imply — and until now
  nothing could answer "what is this node running right now, for which agent,
  and how much memory is it using?". This module owns ONE in-memory record per
  execution (`EvoGit.ProcessManager.Execution`), ONE normalized OS handle
  (`…Handle`), one sampling timer and one PubSub topic (`"processes"`), so
  operators, the dashboard and the tool layer all read the SAME view.

  Two independent axes describe an execution: its ORIGIN — `:runtime`, either
  `:foreground` (the agent is blocked on the call) or `:background` (the call
  outlives the turn) — and its BACKEND — `:builtin` (the call ran inside the
  BEAM, so it has NO OS process, no stats and answers
  `{:error, :no_os_process}` to `sample/2`, `signal/3`, `pause/2`, `resume/2`
  and `kill/2`) or `:systemd | :bwrap | :sandbox_exec | :none` (an external OS
  process anchored by that sandbox backend).

  It records and observes; it does NOT become the thing that starts processes.
  Round 1 (this module) is the registry, the control layer and the sampling;
  later rounds wire `EvoGit.BackgroundJobs`, `EvoGit.Sandbox.*` and the tool
  dispatch layer to `track/3`, `attach/3` and `finish/3`.

  ## Public contract (FROZEN)

      track(kind, meta, opts)      :: {:ok, id}
      attach(id, handle, opts)     :: :ok
      finish(id, status, opts)     :: :ok
      list(opts)                   :: [%Execution{}]
      get(id, opts)                :: {:ok, %Execution{}} | {:error, :not_found}
      sample(id, opts)             :: {:ok, stats} | {:error, term()}
      sample_all(opts)             :: %{id => stats}
      signal(id, signal, opts)     :: :ok | {:error, term()}
      pause(id, opts)              :: :ok | {:error, term()}
      resume(id, opts)             :: :ok | {:error, term()}
      kill(id, opts)               :: :ok | {:error, term()}
      subscribe() / unsubscribe()  :: :ok
      server() / start_link(opts)  :: GenServer.server()

  ## The one rule: no OS call inside the registry

  The registry is a GenServer every reader shares (`get`, `list`, the dashboard),
  so it never probes the OS itself. `sample/2`, `sample_all/1`, `signal/3`,
  `pause/2`, `resume/2` and `kill/2` resolve the record, do the OS work in the
  CALLING process (or a bounded `Task.async_stream`), and hand the registry a
  plain fact to store. The sampling timer probes in a monitored worker. A hung
  `ps`/`systemctl` can therefore never freeze the node's execution view.

  ## Instances

  `server/0` is `Process.get(:evogit_process_manager_server) || __MODULE__`,
  read at CALL time, and every function accepts `:server` — so a suite (or a
  future multi-tenant runtime) starts an ISOLATED named instance and points the
  calling process at it without touching the app-global registry.

  ## Events (PubSub topic `"processes"`, node LAST)

      {:process_started, execution, node}
      {:process_updated, id, changes_map, node}
      {:process_exited, execution, node}
      {:process_sample, node, seq, [%{id: id, status: status, stats: stats}]}
      {:process_control, id, %{action:, signal:, reason:, actor:, at:}, node}

  Lifecycle changes only — a no-op (a second `finish`, an unchanged status)
  never broadcasts. `{:process_updated, …}` carries only the changed fields
  (`%{status: :paused}`, `%{stats: stats}`).

  ## Locality

  The roster is NODE-LOCAL and in-memory only, per BEAM: records are never
  persisted to the task store, never archived with a task and never aggregated
  across nodes, so they die with the process (a restart starts an empty roster).
  A remote caller only ever sees them through the existing RPC
  (`EvoGit.AgentScheduler.RemoteAPI` / `EvoGit.RemoteNode`), which calls THIS
  local facade on the node that owns the executions.

  ## Call-time seams (app env; no TOML keys, so the suite stays async-safe)

    * `:process_manager_sample_interval_ms` — sampling tick (default `3_000`).
    * `:process_stats_enabled` — `false` disables OS probes entirely (default
      `true`).
    * `:process_finished_retention_ms` — how long the age-prunable terminal
      records are kept (default `300_000`); it covers a DEAD owner's
      `:background_job` and every `:tool_call`, never a live owner's job.
    * `:process_finished_max_records` — maximum retained terminal records of
      those same age-prunable ones (default `200`); live records are never
      pruned.
    * `:process_background_max_per_owner` — how many terminal `:background_job`
      records ONE live `owner_pid` keeps (default `20`); such a record is never
      age-pruned, so only that owner's own oldest overflow beyond N is dropped.
    * `:process_stats_probe_timeout_ms` — per-execution `sample_all/1` budget
      (default `2_000`).
    * `:process_kill_grace_ms` — TERM→KILL escalation grace (default `1_500`);
      the CALLING process's `:process_kill_grace_ms` dictionary entry wins over
      this key (a per-process, default-inert shrink for an async suite, since
      the OS kill runs in the caller).

  ## Unavailable registry vs wedged registry

  The registry can be absent (not started, or stopped) or WEDGED (a request it
  never answers). These are different facts and are reported differently:

    * absent → each function's documented degraded value: `list/1` and
      `sample_all/1` answer `[]` / `%{}`, `get/2` and the control functions
      answer `{:error, :not_found}`, `prune/1` answers `{:ok, 0}`,
      `track/3` answers `{:error, :process_manager_unavailable}`.
    * wedged, or crashed while answering → `{:error, :timeout}` /
      `{:error, {:registry_exit, reason}}`, so "nothing is running" can never
      mean "the registry is stuck". `list/1` and `sample_all/1` stay `[]` / `%{}`
      (they are the dashboard reads whose empty value IS the contract).

  No function here raises for any registry state: the OS work happens in the
  caller and the registry answers pure state.
  """

  alias EvoGit.ProcessManager.{Control, Execution, Handle, Registry, Stats}

  @topic "processes"
  @terminal Execution.terminal_statuses()
  @live Execution.live_statuses()

  # Bounded concurrency for the on-demand probe of every live execution.
  @sample_concurrency 4
  @default_kill_reason :killed_by_operator

  ## Server resolution

  @doc """
  Resolves the server for the CURRENT process: the value stored under the
  `:evogit_process_manager_server` process-dictionary key when present (an
  isolated instance — the suite seam), otherwise the registered singleton
  `EvoGit.ProcessManager`. Read at CALL time, never cached.
  """
  @spec server() :: GenServer.server()
  def server do
    Process.get(:evogit_process_manager_server) || __MODULE__
  end

  @doc "Starts the registry. Honours `:name` (default `EvoGit.ProcessManager`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: Registry.start_link(opts)

  @doc """
  Supervisor child spec. The id is the REGISTRY NAME, so the app-global
  instance (`EvoGit.ProcessManager`) and any isolated named instance a suite
  starts under the same supervisor can coexist without id conflicts.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  ## Recording

  @doc """
  Records a new execution and returns its id (`"proc-<n>"`).

  `kind` is `:tool_call` (a tool call an agent is blocked on) or
  `:background_job` (a detached job); a string is accepted and normalized.

  `meta` carries the AGENT-visible identity — `:tool`, `:command`, `:label`,
  `:agent_id`, `:task_id`, `:owner_pid`, `:cwd`, `:repo_root`, `:backend`
  (`:builtin` for a tool that ran inside the BEAM, else the sandbox backend
  `:systemd | :bwrap | :sandbox_exec | :none`, default `:none`), `:runtime`
  (`:foreground` by default, `:background` for background jobs), `:job_id`.
  Atom keys are preferred; the documented string keys are accepted
  and unknown keys are ignored (no atom is ever created from input).

  When `:owner_pid` is a pid it is MONITORED: the owner's death kills every
  execution it owns (see `finish/3` and the owner-lifetime contract).

  Answers `{:error, :process_manager_unavailable}` when the registry is not
  running and `{:error, :timeout}` / `{:error, {:registry_exit, reason}}` when
  it is wedged or crashed.
  """
  @spec track(Execution.kind() | String.t(), map() | keyword(), keyword()) ::
          {:ok, String.t()}
          | {:error, :process_manager_unavailable | Registry.call_error()}
  def track(kind, meta, opts \\ []) do
    Registry.track(server_from(opts), normalize_kind(kind), Registry.normalize_meta(meta))
  end

  @doc """
  Records the OS handle that became known for an execution.

  Accepts a `%EvoGit.ProcessManager.Handle{}` or a LEGACY backend handle map
  (`%{kind: :unit, unit: …}` / `%{kind: :port, os_pid: …}`, as returned by
  `EvoGit.Sandbox.Background`), normalized by `Handle.normalize/1`. The
  execution becomes `:running`, `started_at` is stamped ONLY if it is still
  nil (a re-attach does not move it) and `:process_started` is broadcast on the
  `:starting → :running` transition.

  Total: an unknown/terminal execution or an unrecognized handle is a no-op
  (`:ok`) — never a raise, never a ghost `:running` record. A wedged or crashed
  registry answers `{:error, :timeout}` / `{:error, {:registry_exit, reason}}`.
  """
  @spec attach(String.t(), Handle.t() | map(), keyword()) :: :ok | {:error, Registry.call_error()}
  def attach(id, handle, opts \\ [])

  def attach(id, handle, opts) when is_binary(id) do
    Registry.attach(server_from(opts), id, handle)
  end

  def attach(_id, _handle, _opts), do: :ok

  @doc """
  Records a TERMINAL status: `:completed`, `:failed` or `:killed`.
  A non-terminal status is ignored (`:ok`, no broadcast); a second `finish` for
  an already-terminal execution is a no-op; an unknown id is `:ok`.

  Options: `:exit_code` (integer, kept when omitted), `:reason` (any terminal
  cause — `:exited`, `:timeout`, `:invalid_arguments`, `:owner_died`,
  `{:killed_by, actor}`, `{:crashed, detail}`, `:no_os_process` or
  `{:tool_error, reason}`; the owner-death path uses `:owner_died`, see
  `EvoGit.ProcessManager.Execution.status_for_reason/1` for the uniform status
  mapping). Stamps `ended_at` and broadcasts
  `{:process_exited, execution, node}` exactly once.

  A wedged or crashed registry answers `{:error, :timeout}` /
  `{:error, {:registry_exit, reason}}` — the terminal fact was NOT stored.
  """
  @spec finish(String.t(), Execution.status() | term(), keyword()) ::
          :ok | {:error, Registry.call_error()}
  def finish(id, status, opts \\ [])

  def finish(id, status, opts) when is_binary(id) do
    Registry.finish(server_from(opts), id, status, opts)
  end

  def finish(_id, _status, _opts), do: :ok

  @doc """
  Lists executions, newest first (by `inserted_at`, then numeric id).
  Filters (all optional, all exact-match): `:agent_id`, `:task_id`, `:kind`,
  `:status`, `:backend`. A registry that is unreachable OR wedged yields `[]`
  (the dashboard-shaped read: an empty roster is its documented degraded value).
  """
  @spec list(keyword()) :: [Execution.t()]
  def list(opts \\ []) do
    Registry.list(server_from(opts), Keyword.drop(opts, [:server]))
  end

  @doc """
  Fetches one execution. Unknown id (or an unreachable registry) yields
  `{:error, :not_found}`; a wedged or crashed registry yields
  `{:error, :timeout}` / `{:error, {:registry_exit, reason}}` instead — a stuck
  registry never reads as "no such execution".

  `{:error, :not_found}` at THIS layer means "not retained here": the execution
  was never tracked, or its terminal record has aged out of the in-memory
  roster. It is never a claim that the work did not happen — for an aged-out
  background job the agent-facing answer is the `EvoGit.BackgroundJobs`
  tombstone.
  """
  @spec get(String.t(), keyword()) ::
          {:ok, Execution.t()} | {:error, :not_found | Registry.call_error()}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id), do: Registry.get(server_from(opts), id)
  def get(_id, _opts), do: {:error, :not_found}

  @doc """
  Forces a retention pass and returns `{:ok, removed_count}`.
  Retention also runs on every `finish/3` and every sampling tick; this is the
  explicit (operator/test) entry point. A pass ages out and globally caps the
  age-prunable terminal records (a dead owner's `:background_job` and every
  `:tool_call`) while keeping each LIVE owner's newest
  `:process_background_max_per_owner` terminal `:background_job` records
  regardless of age.
  An unreachable registry answers `{:ok, 0}`; a wedged one answers
  `{:error, :timeout}` (and `{:error, {:registry_exit, reason}}` after a crash)
  rather than claiming a clean pass that never ran.
  """
  @spec prune(keyword()) :: {:ok, non_neg_integer()} | {:error, Registry.call_error()}
  def prune(opts \\ []), do: Registry.prune(server_from(opts))

  ## Observation

  @doc """
  Probes ONE execution's live resource usage, on demand.

  The record is read from the registry and the OS work runs HERE, in the
  caller; the observed stats are then stored on the record (no broadcast — a
  read must not churn the topic). Answers `{:ok, stats}`, `{:error, :not_found}`
  (unknown id), `{:error, :no_os_process}` (a `:builtin` execution — it ran
  inside the BEAM, so there is nothing to probe), `{:error, :not_running}` (a
  terminal execution, or one that never attached a handle) or `{:error, reason}`
  from the backend — including `{:error, :timeout}` /
  `{:error, {:registry_exit, reason}}` from a wedged or crashed registry. Never
  raises.
  """
  @spec sample(String.t(), keyword()) :: {:ok, Stats.t()} | {:error, term()}
  def sample(id, opts \\ [])

  def sample(id, opts) when is_binary(id) do
    server = server_from(opts)

    case Registry.lookup(server, id) do
      {:ok, execution, handle} ->
        cond do
          Execution.builtin?(execution) -> {:error, :no_os_process}
          not Execution.live?(execution.status) -> {:error, :not_running}
          is_nil(handle) -> {:error, :not_running}
          true -> store_sample(server, id, probe(handle))
        end

      # An unknown id answers `{:error, :not_found}`, and a wedged or crashed
      # registry passes its own reason through unchanged — a timeout or a
      # registry exit is NOT "no such execution".
      {:error, reason} ->
        {:error, reason}
    end
  end

  def sample(_id, _opts), do: {:error, :not_found}

  @doc """
  Probes EVERY sampleable (live and external) execution with bounded concurrency
  (`#{@sample_concurrency}` at a time, `EvoGit.ProcessManager.Stats.sample_timeout_ms/0`
  per probe, timed-out probes killed) and returns `%{id => stats}`. A live
  `:builtin` execution is never probed, so it never appears here.

  Failed probes are OMITTED from the map rather than reported as errors — this
  is the dashboard-shaped read, and one dead handle must not hide the other
  executions. A registry that is unavailable OR wedged yields `%{}` (same
  contract as `list/1`). Never raises.
  """
  @spec sample_all(keyword()) :: %{optional(String.t()) => Stats.t()}
  def sample_all(opts \\ []) do
    server = server_from(opts)
    timeout = Stats.sample_timeout_ms()

    server
    |> Registry.live()
    |> Task.async_stream(
      fn {id, _status, handle} -> {id, probe(handle)} end,
      max_concurrency: @sample_concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, {:ok, stats}}}, acc ->
        Registry.record_stats(server, id, stats)
        Map.put(acc, id, stats)

      _other, acc ->
        acc
    end)
  end

  ## Control

  @doc """
  Delivers one signal to an execution's OS handle and records the action.

  `signal` is `:term | :kill | :int | :hup | :stop | :cont | :usr1 | :usr2` or a
  signal name (`"TERM"`, `"SIGKILL"`, …). Options: `:reason` (any term),
  `:actor` (any term — the human/agent that asked).

  On success the action is appended to the record's `control_log` and
  `{:process_control, id, entry, node}` is broadcast; `SIGSTOP` sets `:paused`
  and `SIGCONT` sets `:running` on a paused execution (each broadcasting
  `{:process_updated, id, %{status: …}, node}`).

  Answers `{:error, :not_found}`, `{:error, :no_os_process}` (a `:builtin`
  execution — nothing runs outside the BEAM to signal), `{:error, :terminal}`
  (the OS already ended it), `{:error, :invalid_signal}`, `{:error, :no_handle}`
  (nothing to signal yet), the backend's own error, or `{:error, :timeout}` /
  `{:error, {:registry_exit, reason}}` from a wedged or crashed registry. Never
  raises.
  """
  @spec signal(String.t(), Control.signal(), keyword()) :: :ok | {:error, term()}
  def signal(id, signal, opts \\ [])

  def signal(id, signal, opts) when is_binary(id) do
    server = server_from(opts)
    reason = Keyword.get(opts, :reason)
    actor = Keyword.get(opts, :actor)

    case Registry.lookup(server, id) do
      {:ok, execution, handle} ->
        cond do
          Execution.builtin?(execution) ->
            {:error, :no_os_process}

          Execution.terminal?(execution.status) ->
            {:error, :terminal}

          is_nil(handle) ->
            {:error, :no_handle}

          true ->
            case Control.signal(handle, signal) do
              :ok ->
                entry =
                  Execution.control_entry(
                    action: action_for(signal),
                    signal: Control.signal_name(signal),
                    reason: reason,
                    actor: actor
                  )

                Registry.record_control(server, id, entry, Control.status_after_signal(signal))
                :ok

              {:error, reason_error} ->
                {:error, reason_error}
            end
        end

      # An unknown id answers `{:error, :not_found}`, and a wedged or crashed
      # registry passes its own reason through unchanged — a timeout or a
      # registry exit is NOT "no such execution".
      {:error, reason} ->
        {:error, reason}
    end
  end

  def signal(_id, _signal, _opts), do: {:error, :not_found}

  @doc """
  Suspends an execution (`SIGSTOP`) — status becomes `:paused`.

  Delegates to `signal/3`, so a `:builtin` execution answers
  `{:error, :no_os_process}`.
  """
  @spec pause(String.t(), keyword()) :: :ok | {:error, term()}
  def pause(id, opts \\ []), do: signal(id, :stop, opts)

  @doc """
  Resumes a paused execution (`SIGCONT`) — status becomes `:running`.

  Delegates to `signal/3`, so a `:builtin` execution answers
  `{:error, :no_os_process}`.
  """
  @spec resume(String.t(), keyword()) :: :ok | {:error, term()}
  def resume(id, opts \\ []), do: signal(id, :cont, opts)

  @doc """
  Terminates an execution and records it as `:killed`.

  For a `:background_job` carrying a `job_id` the kill routes through
  `EvoGit.BackgroundJobs.kill/2` (guarded: an unreachable registry is caught,
  never propagated), falling back to handle control when that job is unknown.
  Every other execution is killed through `Control` (TERM → short grace →
  KILL) in the CALLER — the registry is never blocked.

  A `:builtin` execution answers `{:error, :no_os_process}` FIRST and is never
  finished: nothing runs outside the BEAM to kill.

  Options:

    * `:reason` — the HUMAN-supplied text; it survives in `control_log` only.
      ALWAYS supply one, the default is `#{inspect(@default_kill_reason)}`.
    * `:actor` — the human/agent that asked; defaults to `:operator`, never nil.
    * `:terminal_reason` — the terminal `:reason` recorded on the finished
      record; defaults to `{:killed_by, actor}` (so it follows the supplied
      `:actor`).

  Answers `:ok` (already terminal: idempotent), `{:error, :not_found}`, the
  backend's error, or `{:error, :timeout}` / `{:error, {:registry_exit, reason}}`
  from a wedged or crashed registry (in which case nothing was killed).

  The record becomes `:killed` ONLY when the backend reports success: an
  accepted kill appends `%{action: :kill, reason: <human text>, actor: actor}`
  to `control_log` and finishes with `:killed`, `reason: terminal_reason` and
  `exit_code: nil` (a kill never fabricates an exit code). A failed or refused
  kill leaves the status untouched — the execution stays observable and
  controllable — appends
  `%{action: :kill, reason: {:kill_failed, reason}, actor: actor}` to
  `control_log`, and returns that error.

  The operator's kill is AUTHORITATIVE against the sandbox layer's own exit
  observation of the same process: a kill intent carrying the `:actor` is
  declared before the stop, so if the sandbox settles the record first (usually
  `:completed` + `:exited` + the signal's exit code) it settles as `:killed`,
  `reason: {:killed_by, actor}` and `exit_code: nil` instead — the operator
  asked for the kill, so the observed exit is its consequence, not a terminal
  fact.
  """
  @spec kill(String.t(), keyword()) :: :ok | {:error, term()}
  def kill(id, opts \\ [])

  def kill(id, opts) when is_binary(id) do
    server = server_from(opts)

    case Registry.lookup(server, id) do
      {:ok, execution, handle} ->
        cond do
          Execution.builtin?(execution) -> {:error, :no_os_process}
          Execution.terminal?(execution.status) -> :ok
          true -> kill_execution(server, id, execution, handle, opts)
        end

      # An unknown id answers `{:error, :not_found}`, and a wedged or crashed
      # registry passes its own reason through unchanged — a timeout or a
      # registry exit is NOT "no such execution".
      {:error, reason} ->
        {:error, reason}
    end
  end

  def kill(_id, _opts), do: {:error, :not_found}

  ## Subscription

  @doc "Subscribes the CALLING process to the `\"processes\"` topic."
  @spec subscribe() :: :ok
  def subscribe, do: Phoenix.PubSub.subscribe(EvoGit.PubSub, @topic)

  @doc "Unsubscribes the CALLING process from the `\"processes\"` topic."
  @spec unsubscribe() :: :ok
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(EvoGit.PubSub, @topic)

  ## Internal

  defp server_from(opts), do: Keyword.get(opts, :server) || server()

  defp normalize_kind(kind) when kind in [:tool_call, :background_job], do: kind
  defp normalize_kind("tool_call"), do: :tool_call
  defp normalize_kind("background_job"), do: :background_job
  defp normalize_kind(_kind), do: :tool_call

  # The facade's OWN concern is a handle that never became known. Everything
  # else is `Control.stats/1`'s job: it dispatches to the backend and is already
  # TOTAL (`{:error, :no_handle}` for a missing backend, backend errors as data,
  # and a crashed backend tagged `{:error, {:probe_failed, detail}}` there), so
  # wrapping it in another rescue/catch would only duplicate the tag.
  defp probe(nil), do: {:error, :no_handle}

  defp probe(handle), do: Control.stats(handle)

  defp store_sample(_server, _id, {:error, _reason} = error), do: error

  defp store_sample(server, id, {:ok, stats}) do
    Registry.record_stats(server, id, stats)
    {:ok, stats}
  end

  # A background job is killed through its owning registry; anything else (and a
  # job BackgroundJobs no longer knows) goes through the OS handle.
  defp stop_execution(
         %Execution{kind: :background_job, job_id: job_id} = execution,
         handle,
         reason,
         actor
       )
       when is_binary(job_id) do
    case background_kill(job_id, reason, actor) do
      {:ok, _job} -> :ok
      {:error, {:already_finished, _job}} -> :ok
      _other -> handle_kill(execution, handle)
    end
  end

  defp stop_execution(execution, handle, _reason, _actor), do: handle_kill(execution, handle)

  defp handle_kill(_execution, nil), do: :ok
  defp handle_kill(_execution, handle), do: Control.kill(handle)

  defp background_kill(job_id, reason, actor) do
    EvoGit.BackgroundJobs.kill(job_id, reason, actor: actor)
  rescue
    e -> {:error, {:background_jobs_unavailable, Exception.message(e)}}
  catch
    :exit, _reason -> {:error, :background_jobs_unavailable}
    kind, reason_error -> {:error, {:background_jobs_unavailable, {kind, reason_error}}}
  end

  # One accepted/failed kill, mirroring the `control_log` entry shape the signal
  # path uses. The human `:reason` text lives in the log only; the record's
  # terminal `:reason` is `:terminal_reason` and no exit code is ever fabricated.
  #
  # The OPERATOR kill is authoritative even though the sandbox layer observes
  # the very exit this stop causes: the intent is declared BEFORE the stop, so
  # whichever finish lands first settles `:killed` / `{:killed_by, actor}` and
  # every later finish is a no-op. A failed stop clears it again.
  defp kill_execution(server, id, execution, handle, opts) do
    reason = Keyword.get(opts, :reason, @default_kill_reason)
    actor = Keyword.get(opts, :actor) || :operator
    terminal_reason = Keyword.get(opts, :terminal_reason, {:killed_by, actor})

    Registry.put_kill_intent(server, id, actor)

    case stop_execution(execution, handle, reason, actor) do
      :ok ->
        Registry.record_control(
          server,
          id,
          Execution.control_entry(action: :kill, reason: reason, actor: actor)
        )

        finish(id, :killed, server: server, reason: terminal_reason, exit_code: nil)
        Registry.clear_kill_intent(server, id)
        # The OS stop SUCCEEDED: a registry that stopped answering while the
        # bookkeeping was written must not turn an accepted kill into an error.
        :ok

      {:error, reason_error} ->
        Registry.clear_kill_intent(server, id)

        entry =
          Execution.control_entry(
            action: :kill,
            reason: {:kill_failed, reason_error},
            actor: actor
          )

        Registry.record_control(server, id, entry)
        {:error, reason_error}
    end
  end

  defp action_for(signal) do
    case Control.normalize_signal(signal) do
      {:ok, "STOP"} -> :pause
      {:ok, "CONT"} -> :resume
      _ -> :signal
    end
  end

  @doc false
  # The statuses a SAMPLEABLE execution may carry (documented for consumers).
  @spec live_statuses() :: [Execution.status()]
  def live_statuses, do: @live

  @doc false
  @spec terminal_statuses() :: [Execution.status()]
  def terminal_statuses, do: @terminal
end
