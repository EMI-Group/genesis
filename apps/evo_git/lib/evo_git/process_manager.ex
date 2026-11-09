defmodule EvoGit.ProcessManager do
  @moduledoc """
  THE single source of truth for the live OS executions an agent/task holds.

  Genesis spawns processes in three shapes — a foreground tool call (a shell
  command an agent blocks on), a detached background job
  (`EvoGit.BackgroundJobs`) and the sandbox trees those imply — and until now
  nothing could answer "what is this node running right now, for which agent,
  and how much memory is it using?". This module owns ONE in-memory record per
  execution (`EvoGit.ProcessManager.Execution`), ONE normalized OS handle
  (`…Handle`), one sampling timer and one PubSub topic (`"processes"`), so
  operators, the dashboard (phase 2) and the tool layer all read the SAME view.

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

  ## Call-time seams (app env; no TOML keys, so the suite stays async-safe)

    * `:process_manager_sample_interval_ms` — sampling tick (default `3_000`).
    * `:process_stats_enabled` — `false` disables OS probes entirely (default
      `true`).
    * `:process_finished_retention_ms` — how long terminal records are kept
      (default `300_000`).
    * `:process_stats_probe_timeout_ms` — per-execution `sample_all/1` budget
      (default `2_000`).
    * `:process_kill_grace_ms` — TERM→KILL escalation grace (default `1_500`).
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

  `kind` is `:tool_call` (a foreground command an agent is blocked on) or
  `:background_job` (a detached job); a string is accepted and normalized.

  `meta` carries the AGENT-visible identity — `:tool`, `:command`, `:label`,
  `:agent_id`, `:task_id`, `:owner_pid`, `:cwd`, `:repo_root`, `:backend`,
  `:runtime` (`:foreground` by default, `:detached` for background jobs),
  `:job_id`. Atom keys are preferred; the documented string keys are accepted
  and unknown keys are ignored (no atom is ever created from input).

  When `:owner_pid` is a pid it is MONITORED: the owner's death kills every
  execution it owns (see `finish/3` and the owner-lifetime contract).
  """
  @spec track(Execution.kind() | String.t(), map() | keyword(), keyword()) ::
          {:ok, String.t()} | {:error, :process_manager_unavailable}
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
  (`:ok`) — never a raise, never a ghost `:running` record.
  """
  @spec attach(String.t(), Handle.t() | map(), keyword()) :: :ok
  def attach(id, handle, opts \\ [])

  def attach(id, handle, opts) when is_binary(id) do
    Registry.attach(server_from(opts), id, handle)
  end

  def attach(_id, _handle, _opts), do: :ok

  @doc """
  Records a TERMINAL status: `:completed`, `:failed` or `:killed`.
  A non-terminal status is ignored (`:ok`, no broadcast); a second `finish` for
  an already-terminal execution is a no-op; an unknown id is `:ok`.

  Options: `:exit_code` (integer, kept when omitted), `:reason` (any term; the
  owner-death path uses `:owner_died`). Stamps `ended_at` and broadcasts
  `{:process_exited, execution, node}` exactly once.
  """
  @spec finish(String.t(), Execution.status() | term(), keyword()) :: :ok
  def finish(id, status, opts \\ [])

  def finish(id, status, opts) when is_binary(id) do
    Registry.finish(server_from(opts), id, status, opts)
  end

  def finish(_id, _status, _opts), do: :ok

  @doc """
  Lists executions, newest first (by `inserted_at`, then numeric id).
  Filters (all optional, all exact-match): `:agent_id`, `:task_id`, `:kind`,
  `:status`, `:backend`. An unreachable registry yields `[]`.
  """
  @spec list(keyword()) :: [Execution.t()]
  def list(opts \\ []) do
    Registry.list(server_from(opts), Keyword.drop(opts, [:server]))
  end

  @doc """
  Fetches one execution. Unknown id (or an unreachable registry) yields
  `{:error, :not_found}`.
  """
  @spec get(String.t(), keyword()) :: {:ok, Execution.t()} | {:error, :not_found}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id), do: Registry.get(server_from(opts), id)
  def get(_id, _opts), do: {:error, :not_found}

  @doc """
  Forces a retention pass and returns `{:ok, removed_count}`.
  Retention also runs on every `finish/3` and every sampling tick; this is the
  explicit (operator/test) entry point.
  """
  @spec prune(keyword()) :: {:ok, non_neg_integer()}
  def prune(opts \\ []), do: Registry.prune(server_from(opts))

  ## Observation

  @doc """
  Probes ONE execution's live resource usage, on demand.

  The record is read from the registry and the OS work runs HERE, in the
  caller; the observed stats are then stored on the record (no broadcast — a
  read must not churn the topic). Answers `{:ok, stats}`, `{:error, :not_found}`
  (unknown id), `{:error, :not_running}` (a terminal execution, or one that
  never attached a handle) or `{:error, reason}` from the backend. Never raises.
  """
  @spec sample(String.t(), keyword()) :: {:ok, Stats.t()} | {:error, term()}
  def sample(id, opts \\ [])

  def sample(id, opts) when is_binary(id) do
    server = server_from(opts)

    case Registry.lookup(server, id) do
      {:ok, execution, handle} ->
        cond do
          not Execution.live?(execution.status) -> {:error, :not_running}
          is_nil(handle) -> {:error, :not_running}
          true -> store_sample(server, id, probe(handle))
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def sample(_id, _opts), do: {:error, :not_found}

  @doc """
  Probes EVERY `:running`/`:paused` execution with bounded concurrency
  (`#{@sample_concurrency}` at a time, `EvoGit.ProcessManager.Stats.sample_timeout_ms/0`
  per probe, timed-out probes killed) and returns `%{id => stats}`.

  Failed probes are OMITTED from the map rather than reported as errors — this
  is the dashboard-shaped read, and one dead handle must not hide the other
  executions. Never raises.
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

  Answers `{:error, :not_found}`, `{:error, :terminal}` (the OS already ended
  it), `{:error, :invalid_signal}`, `{:error, :no_handle}` (nothing to signal
  yet) or the backend's own error. Never raises.
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

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def signal(_id, _signal, _opts), do: {:error, :not_found}

  @doc "Suspends an execution (`SIGSTOP`) — status becomes `:paused`."
  @spec pause(String.t(), keyword()) :: :ok | {:error, term()}
  def pause(id, opts \\ []), do: signal(id, :stop, opts)

  @doc "Resumes a paused execution (`SIGCONT`) — status becomes `:running`."
  @spec resume(String.t(), keyword()) :: :ok | {:error, term()}
  def resume(id, opts \\ []), do: signal(id, :cont, opts)

  @doc """
  Terminates an execution and records it as `:killed`.

  For a `:background_job` carrying a `job_id` the kill routes through
  `EvoGit.BackgroundJobs.kill/2` (guarded: an unreachable registry is caught,
  never propagated), falling back to handle control when that job is unknown.
  Every other execution is killed through `Control` (TERM → short grace →
  KILL) in the CALLER — the registry is never blocked.

  Options: `:reason` — recorded on the record; ALWAYS supply one, the default
  is `#{inspect(@default_kill_reason)}` — and `:actor`.

  Answers `:ok` (already terminal: idempotent), `{:error, :not_found}`, or the
  backend's error. The record is marked `:killed` even when the OS call failed,
  because the operator asked for it; the returned error still reports that the
  process may be alive.
  """
  @spec kill(String.t(), keyword()) :: :ok | {:error, term()}
  def kill(id, opts \\ [])

  def kill(id, opts) when is_binary(id) do
    server = server_from(opts)
    reason = Keyword.get(opts, :reason, @default_kill_reason)

    case Registry.lookup(server, id) do
      {:ok, execution, handle} ->
        if Execution.terminal?(execution.status) do
          :ok
        else
          result = stop_execution(execution, handle, reason)
          finish(id, :killed, server: server, reason: reason, exit_code: exit_code(handle))
          result
        end

      {:error, :not_found} ->
        {:error, :not_found}
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

  defp probe(nil), do: {:error, :no_handle}

  defp probe(handle) do
    Control.stats(handle)
  rescue
    e -> {:error, {:probe_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:probe_failed, {kind, reason}}}
  end

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
         reason
       )
       when is_binary(job_id) do
    case background_kill(job_id, reason) do
      {:ok, _job} -> :ok
      {:error, {:already_finished, _job}} -> :ok
      _other -> handle_kill(execution, handle)
    end
  end

  defp stop_execution(execution, handle, _reason), do: handle_kill(execution, handle)

  defp handle_kill(_execution, nil), do: :ok
  defp handle_kill(_execution, handle), do: Control.kill(handle)

  defp background_kill(job_id, reason) do
    EvoGit.BackgroundJobs.kill(job_id, reason)
  rescue
    e -> {:error, {:background_jobs_unavailable, Exception.message(e)}}
  catch
    :exit, _reason -> {:error, :background_jobs_unavailable}
    kind, reason_error -> {:error, {:background_jobs_unavailable, {kind, reason_error}}}
  end

  defp exit_code(%Handle{pending_exit_code: code}) when is_integer(code), do: code
  defp exit_code(_handle), do: nil

  defp action_for(signal) do
    case Control.normalize_signal(signal) do
      {:ok, "STOP"} -> :pause
      {:ok, "CONT"} -> :resume
      _ -> :signal
    end
  end

  @doc false
  # The statuses `sample_all/1` probes (documented for consumers).
  @spec live_statuses() :: [Execution.status()]
  def live_statuses, do: @live

  @doc false
  @spec terminal_statuses() :: [Execution.status()]
  def terminal_statuses, do: @terminal
end
