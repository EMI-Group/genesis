defmodule EvoGit.BackgroundJobs do
  @moduledoc """
  Registry for detached ("background") shell jobs started by agents.

  `start_job/1` starts a command through `EvoGit.Sandbox.spawn_detached/1` (the ONE detached entry point, answered by every sandbox backend) and records it; the command's stdout/stderr accumulate in a per-job log file under the sandbox scratch directory, so callers poll `job/2` for status and drain the log with `read/2`, which returns only the bytes produced since the previous read.
  Job lifetime — every job is bound to its OWNING AGENT process (`:owner_pid`); `start_job/1` installs ONE `Process.monitor/1` per owner, and when that process dies EVERY job it started is killed and the monitor bookkeeping is dropped. Because agent processes are unlinked `Task.Supervisor.async_nolink` children killed by `Lifecycle.cancel_agent/2`, this single monitor covers every way an agent can end — normal completion, crash, graceful cancel AND force kill — so no hooks are needed at `EvoGit.TaskRegistry`'s terminal-write sites. The monitor is deliberately installed on the AGENT pid, never on the short-lived tool task that calls this module.
  Completion detection — ONE primary mechanism plus two cheap, idempotent fallbacks: the **observer port** (every backend keeps a port on the handle that reports the job's exit — a `:port` job's own child, and a `:unit` job's `systemd-run --wait` client, which exits with the UNIT's status), the **lazy reconcile** (every `read/2` / `list/1` / `job/2` re-checks a live job against the backend via `EvoGit.Sandbox.detached_status/1`) and the **periodic tick** (while at least one live job uses a `:unit` handle, ONE `@tick_interval_ms` timer re-reconciles them so `finished_at` / `exit_code` land promptly even if nobody reads; it is disarmed as soon as no such job remains). `{:unknown, nil}` from the backend is never treated as "running forever": a job that stays unreportable with no live observer port is settled terminally as `:failed` after a bounded `@unknown_grace_ms` grace.
  Error vocabulary — failures a caller must act on are returned as ONE actionable prose sentence, never a bare atom: `start_job/1` and `read/2` answer `{:error, message}` for EVERY failure INCLUDING an unreachable registry (the dead-registry fallback is wrapped in that tuple at both call sites, since their callers pattern-match it exactly); the ownership/finished probes in `job/2` and `kill/3` keep the small semantic tuples documented on those functions so a caller can branch on them before formatting prose. No input is ever converted with `String.to_atom/1`.
  """

  use GenServer

  require Logger

  alias EvoGit.Platform

  # Compile-time Mix env — safe in releases (`Mix.env/0` is evaluated at compile time; in prod releases it resolves to `:prod`).
  # Used to skip the one-shot boot sweep of stale detached units in the test env, matching the existing codebase pattern (`EvoGit.Application`'s boot-distribution gate).
  @mix_env Mix.env()

  ## Tunables (module attributes only — deliberately no config keys)

  # Maximum number of LIVE jobs a single owner (agent) may have at once.
  @max_jobs_per_owner 10
  # Periodic reconcile interval for live `:unit`-handled jobs.
  @tick_interval_ms 1_000
  # Defensive floor: how long a live job may stay UNREPORTABLE (the backend says
  # `{:unknown, nil}` and no observer port is open) before it is settled
  # terminally as `:failed` instead of pretending to run forever. A transient
  # systemctl failure is tolerated inside this window; the observer port always
  # wins (see `settle_unknown/2`). Overridable for tests via the app env
  # `:background_unknown_grace_ms`.
  @unknown_grace_ms 15_000
  # Suggested polling defaults for callers implementing a `wait: true` loop (this module does NOT block — see `wait_default_ms/0`).
  @wait_default_ms 8_000
  @wait_max_ms 60_000
  @poll_interval_ms 100
  # A spawn can briefly block (systemd-run / port open), so registry calls use an explicit timeout instead of the 5s default.
  @call_timeout 15_000
  # `reap_under/1` runs inside a GenServer teardown path (WorktreeManager's `:DOWN`), so it must fail fast instead of stalling that process.
  @reap_call_timeout 5_000
  # Default `read/2` byte cap when the caller does not pass `:max_bytes`.
  @default_max_bytes 20_000
  # Retention cap for FINISHED job records (live jobs are never pruned).
  @max_finished_retained 100
  # Per-owner cap on `snapshot/1` (the per-turn read; a full `list/1` stays uncapped).
  @snapshot_limit 20

  @id_prefix "bash-"

  @type status :: :running | :stopping | :completed | :killed | :failed

  @type job :: %{
          id: String.t(),
          kind: String.t(),
          label: String.t(),
          owner_pid: pid() | nil,
          owner_ref: reference() | nil,
          agent_id: String.t() | nil,
          task_id: String.t() | nil,
          cwd: String.t(),
          output_path: String.t(),
          handle: map() | nil,
          status: status(),
          exit_code: integer() | nil,
          detail: String.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          cursor: non_neg_integer(),
          lines_read: non_neg_integer(),
          announced: boolean()
        }

  # Spec keys accepted by `start_job/1`, mapped from their STRING spellings.
  # A fixed literal map — never `String.to_atom/1` on caller input.
  @spec_keys %{
    "command" => :command,
    "cwd" => :cwd,
    "repo_root" => :repo_root,
    "label" => :label,
    "owner_pid" => :owner_pid,
    "agent_id" => :agent_id,
    "task_id" => :task_id
  }

  ## Client API

  @doc """
  Resolves the `EvoGit.BackgroundJobs` server name for the CURRENT process: the value stored under the `:evogit_background_jobs_server` process dictionary key when present (an isolated instance started with a custom `:name` — the suite seam), otherwise the default registered name `__MODULE__`. Read at CALL time — never cached — so every client function routes to whichever instance the calling process was pointed at; when the key is unset the default registered singleton is used, keeping production behaviour unchanged.
  """
  @spec server() :: GenServer.server()
  def server do
    Process.get(:evogit_background_jobs_server) || __MODULE__
  end

  @doc "Starts the registry. Honours `:name` (default `#{inspect(__MODULE__)}`)."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Resolves the owning AGENT pid for the current call — the ONE place `:owner_pid` is looked up. Reads the `:evogit_agent_pid` process-dictionary key that the agent runner installs in every process it drives (agents and the tool tasks they spawn); returns `nil` when the key is absent, so callers can produce an actionable error instead of binding a job to a short-lived tool task.
  """
  @spec current_owner_pid() :: pid() | nil
  def current_owner_pid do
    case Process.get(:evogit_agent_pid) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  end

  @doc """
  Starts a detached background job and returns its record.
  Spec (`map` or keyword list): `:command` (**required**) — the shell command line to run; `:cwd` (**required**) — existing absolute working directory; `:owner_pid` (**required**) — the owning AGENT pid, defaulting to `current_owner_pid/0` when absent; `:repo_root` — optional repository root (context only); `:label` — optional short human label (defaults to the command's first line); `:agent_id` / `:task_id` — optional identifiers carried on the record.
  Returns `{:ok, job}` — the job record (`t:job/0`), whose output is written to its `:output_path` field — or `{:error, message}`, one actionable prose sentence.
  """
  @spec start_job(map() | keyword()) :: {:ok, job()} | {:error, String.t()}
  def start_job(spec) do
    with {:ok, normalized} <- normalize_start_spec(spec) do
      call_registry({:start_job, normalized}, {:error, registry_down_error()})
    end
  end

  @doc false
  # TEST SEAM — never called by production code. Starts a job whose backend
  # `handle` is supplied by the caller instead of being spawned, so a suite can
  # drive the exit-OBSERVER routing (a `:unit` handle carrying the
  # `systemd-run --wait` client port) without a systemd user bus. Every
  # remaining step — spec normalization, output file, owner monitor, job record,
  # tick arming, status transitions — is the production start path.
  @spec start_job_with_handle(map() | keyword(), map()) ::
          {:ok, job()} | {:error, String.t()}
  def start_job_with_handle(spec, handle) when is_map(handle) do
    with {:ok, normalized} <- normalize_start_spec(spec) do
      call_registry({:start_job, normalized, handle}, {:error, registry_down_error()})
    end
  end

  @doc """
  Fetches one job by id, reconciling a live job against the backend first.
  `opts[:owner_pid]` fences ownership: when it is set, a job belonging to another owner yields `{:error, :not_owner}`; otherwise the lookup is unscoped. Returns `{:ok, job}`, `{:error, :not_found}` (unknown id, or an unreachable registry) or `{:error, :not_owner}` (the job belongs to a different owner).
  """
  @spec job(String.t(), keyword()) :: {:ok, job()} | {:error, :not_found | :not_owner}
  def job(id, opts \\ []) when is_binary(id) do
    call_registry({:job, id, Keyword.get(opts, :owner_pid)}, {:error, :not_found})
  end

  @doc """
  Reads output produced since the previous read. The job's `:cursor` advances ONLY by the bytes actually returned, so a capped read never loses data: when more output is pending, the returned `:text` ends with `"[... more output pending; call job_output again]"`.
  Options: `:max_bytes` — maximum number of output bytes returned BY THIS CALL (positive integer, default `#{@default_max_bytes}`; bytes beyond the cap stay unread for the next call); `:owner_pid` — fences ownership (another owner's job is an error).
  Returns `{:ok, %{text: String.t(), job: job}}` or `{:error, message}` — one actionable prose sentence (unknown/foreign job, missing output file, bad `:max_bytes`, unreachable registry).
  """
  @spec read(String.t(), keyword()) ::
          {:ok, %{text: String.t(), job: job()}} | {:error, String.t()}
  def read(id, opts \\ []) when is_binary(id) do
    with {:ok, max_bytes} <- normalize_max_bytes(Keyword.get(opts, :max_bytes)) do
      call_registry(
        {:read, id, Keyword.get(opts, :owner_pid), max_bytes},
        {:error, registry_down_error()}
      )
    end
  end

  @doc """
  Lists jobs, newest first, reconciling live jobs against the backend first.
  `opts[:owner_pid]` limits the result to one owner's jobs. Returns `[]` when the registry is unreachable (a list-shaped API never raises).
  """
  @spec list(keyword()) :: [job()]
  def list(opts \\ []) do
    case call_registry({:list, Keyword.get(opts, :owner_pid)}, []) do
      jobs when is_list(jobs) -> jobs
      _ -> []
    end
  end

  @doc """
  Returns a NON-RECONCILING snapshot of one owner's jobs, newest first, capped at #{@snapshot_limit}.
  `opts[:owner_pid]` defaults to `current_owner_pid/0`; an unknown owner (or an unreachable registry) yields `[]`.
  This is the per-turn query shape: it reads registry state and nothing else — no backend reconciliation, no output-file I/O and no state mutation (no cursor advance) — so it is cheap enough to call on every agent turn. Use `list/1` when a reconciled status is required.
  """
  @spec snapshot(keyword()) :: [job()]
  def snapshot(opts \\ []) do
    owner_pid = Keyword.get(opts, :owner_pid) || current_owner_pid()

    if is_pid(owner_pid) and registry_alive?() do
      call_registry({:snapshot, owner_pid}, [])
    else
      []
    end
  end

  @doc """
  Claims this owner's finished-but-unannounced jobs in ONE registry call: returns `{:ok, jobs}` (newest first) and marks exactly those jobs `announced: true`, so a second call can never return the same job again.
  `announced` means "the owner already knows this job's outcome — no completion notice needed": it starts `false`, and is set by this claim, by `read/2` / `list/1` for the terminal jobs they return, and by a successful `kill/3` (including its `{:already_finished, job}` branch).
  `opts[:owner_pid]` defaults to `current_owner_pid/0`; nothing to claim (or an unreachable registry / unknown owner) yields `{:ok, []}`.
  Selection is a state read only — the periodic tick already refreshes `:unit`-handled jobs within about a second — and only TERMINAL statuses (`:completed | :killed | :failed`) are eligible.
  """
  @spec claim_finished_notices(keyword()) :: {:ok, [job()]}
  def claim_finished_notices(opts \\ []) do
    owner_pid = Keyword.get(opts, :owner_pid) || current_owner_pid()

    if is_pid(owner_pid) and registry_alive?() do
      call_registry({:claim_finished_notices, owner_pid}, {:ok, []})
    else
      {:ok, []}
    end
  end

  # Cheap pre-flight for the two state-only reads above: a registry that died between this check and the call is still
  # caught by `call_registry/3`'s single centralized `catch :exit` boundary (the repo forbids scattering broad rescues),
  # but skipping the doomed `GenServer.call` keeps the failure path off the caller's critical path.
  defp registry_alive? do
    case server() do
      pid when is_pid(pid) -> Process.alive?(pid)
      name when is_atom(name) -> Process.whereis(name) != nil
      _other -> true
    end
  end

  @doc """
  Kills a job (and its detached process) if it is still live. `reason` is recorded in the job's `:detail` as `"killed (<reason>)"`; `nil` becomes `"stopped by request"`.
  Returns `{:ok, job}` (now `:killed`), `{:error, :not_found}` (unknown id, or an unreachable registry), `{:error, :not_owner}` (`opts[:owner_pid]` fences a different owner's job), `{:error, {:already_finished, job}}` (the job already reached a terminal status; nothing was killed) or `{:error, message}` (the backend could not stop the process — one actionable prose sentence; the job is left in `:stopping`).
  The caller REQUESTED the kill, so both the `{:ok, job}` and `{:error, {:already_finished, job}}` replies come back with `announced: true` — no completion notice is raised for them (`job/2` afterwards returns a record with `announced: true`). The `{:error, message}` branch deliberately does NOT mark it: the process may still be running, so the agent should still learn the final status from a notice. A `read/2` after a kill still returns the output produced before it.
  """
  @spec kill(String.t(), term(), keyword()) ::
          {:ok, job()}
          | {:error, :not_found | :not_owner | {:already_finished, job()} | String.t()}
  def kill(id, reason \\ nil, opts \\ []) when is_binary(id) do
    call_registry(
      {:kill, id, reason, Keyword.get(opts, :owner_pid)},
      {:error, :not_found}
    )
  end

  @doc """
  Kills every live job whose `cwd` is `prefix` or a directory under it — used when a worktree / scratch directory is removed, since the detached processes would otherwise keep running with a deleted working directory. Ownership is deliberately NOT part of the fence here (reaping is a directory-scoped administrative action) and the call ALWAYS answers `:ok`.
  """
  @spec reap_under(String.t()) :: :ok
  def reap_under(prefix) when is_binary(prefix) and prefix != "" do
    case call_registry({:reap_under, prefix}, :ok, @reap_call_timeout) do
      _ -> :ok
    end
  end

  def reap_under(_prefix), do: :ok

  ## Tunable readers (public constants for callers implementing `wait: true`)

  @doc "Maximum number of live jobs one owner may have at once."
  def max_jobs_per_owner, do: @max_jobs_per_owner

  @doc "Suggested default wait budget (ms) for a caller-side `wait: true` loop."
  def wait_default_ms, do: @wait_default_ms

  @doc "Suggested maximum wait budget (ms) for a caller-side `wait: true` loop."
  def wait_max_ms, do: @wait_max_ms

  @doc "Suggested polling interval (ms) for a caller-side `wait: true` loop."
  def poll_interval_ms, do: @poll_interval_ms

  @doc "Periodic reconcile interval (ms) for live `:unit`-handled jobs."
  def tick_interval_ms, do: @tick_interval_ms

  @doc "Renders a job status as the public string vocabulary."
  @spec status_string(status() | nil) :: String.t() | nil
  def status_string(:running), do: "running"
  def status_string(:stopping), do: "stopping"
  def status_string(:completed), do: "completed"
  def status_string(:killed), do: "killed"
  def status_string(:failed), do: "failed"
  def status_string(nil), do: nil

  ## Registry plumbing

  # Every public call goes through here so a dead/absent registry can never make a calling tool crash with an exit.
  # The timeout is explicit per call: `reap_under/1` passes a short one so a wedged registry cannot stall its caller.
  defp call_registry(message, fallback, timeout \\ @call_timeout) do
    try do
      GenServer.call(server(), message, timeout)
    catch
      :exit, reason ->
        Logger.warning(
          "BackgroundJobs: registry call #{request_tag(message)} failed: #{inspect(reason)}"
        )

        fallback
    end
  end

  defp request_tag(message) when is_tuple(message), do: inspect(elem(message, 0))
  defp request_tag(message), do: inspect(message)

  defp registry_down_error do
    "The background job service is not running (it may be restarting after a crash), so this request did nothing. Retry in a moment; if it keeps failing, run the command in the foreground instead."
  end

  ## Spec normalization (client side — `:owner_pid` must be resolved in the CALLER)

  defp normalize_start_spec(spec) when is_list(spec), do: normalize_start_spec(Map.new(spec))

  defp normalize_start_spec(spec) when is_map(spec) do
    keyed = normalize_spec_keys(spec)

    command = trimmed_binary(Map.get(keyed, :command))
    cwd = trimmed_binary(Map.get(keyed, :cwd))
    owner_pid = Map.get(keyed, :owner_pid) || current_owner_pid()

    cond do
      is_nil(command) ->
        {:error,
         "A background job needs a non-empty `command` string; pass the shell command to run as `command` and retry."}

      is_nil(cwd) ->
        {:error,
         "A background job needs `cwd` — the absolute working directory to run in. Pass an existing directory as `cwd` and retry."}

      not is_binary(cwd) ->
        {:error,
         "`cwd` must be a path string (the working directory to run in); got #{inspect(cwd)}. Retry with an existing absolute directory."}

      not File.dir?(cwd) ->
        {:error,
         "The background job's working directory does not exist: #{cwd}. Pass an existing absolute directory as `cwd` and retry."}

      not is_pid(owner_pid) ->
        {:error,
         "Background jobs must be started from an agent tool call so the job can be tied to the agent's lifetime, but no owning agent process was found for this call. Retry from the agent's tool call (or pass `owner_pid`)."}

      true ->
        {:ok,
         %{
           command: command,
           cwd: cwd,
           repo_root: trimmed_binary(Map.get(keyed, :repo_root)),
           label: normalize_label(Map.get(keyed, :label), command),
           owner_pid: owner_pid,
           agent_id: trimmed_binary(Map.get(keyed, :agent_id)),
           task_id: trimmed_binary(Map.get(keyed, :task_id))
         }}
    end
  end

  defp normalize_start_spec(spec) do
    {:error,
     "A background job needs a spec map (or keyword list) with at least `command` and `cwd`; got #{inspect(spec)}. Retry with a spec map."}
  end

  # Maps the fixed set of STRING spec keys onto atoms. Atom keys pass through untouched; unknown keys are dropped.
  defp normalize_spec_keys(spec) do
    Enum.reduce(spec, %{}, fn {key, value}, acc ->
      case spec_key(key) do
        nil -> acc
        atom -> Map.put(acc, atom, value)
      end
    end)
  end

  defp spec_key(key) when is_atom(key), do: key
  defp spec_key(key) when is_binary(key), do: Map.get(@spec_keys, key)
  defp spec_key(_key), do: nil

  defp normalize_label(label, command) do
    case trimmed_binary(label) do
      nil -> default_label(command)
      text -> String.slice(text, 0, 200)
    end
  end

  defp default_label(command) do
    label =
      command
      |> String.split("\n", parts: 2)
      |> List.first()
      |> String.trim()

    case label do
      "" -> "bash command"
      text -> String.slice(text, 0, 200)
    end
  end

  defp trimmed_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed_binary(_value), do: nil

  defp normalize_max_bytes(nil), do: {:ok, @default_max_bytes}
  defp normalize_max_bytes(bytes) when is_integer(bytes) and bytes > 0, do: {:ok, bytes}

  defp normalize_max_bytes(other) do
    {:error,
     "`max_bytes` must be a positive integer — the maximum number of output bytes to return from this call; got #{inspect(other)}. Omit it to use the default of #{@default_max_bytes} bytes."}
  end

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    # Trapping exits is what makes `terminate/2` reachable on a shutdown that is not an explicit `GenServer.stop/2`: an UNTRAPPED exit signal from the supervisor kills this process outright, so the "kill every live job" defence would never run. Trapped, the `:gen_server` behaviour turns the PARENT's exit signal into a `terminate/2` call, while any other linked exit reaches the `{:EXIT, pid, reason}` handler below (logged, registry stays up).
    Process.flag(:trap_exit, true)

    # One-shot boot sweep: a job detached into its own systemd unit SURVIVES the BEAM that started it, so a crashed BEAM leaks transient `genesis-job-*` units.
    # `sweep_stale_units/0` is total and only garbage-collects units whose embedded `b<beam_os_pid>` is no longer alive, so it must NEVER kill a job belonging to another live instance on the same host.
    # Non-blocking and gated like the codebase's other boot-time side effects, so registry startup is never delayed or affected in tests.
    if @mix_env != :test and EvoGit.Sandbox.backend() == EvoGit.Sandbox.Linux do
      # Belt and braces: the sweep is already total, but a raise here must never take the registry down.
      Task.start(fn ->
        try do
          EvoGit.Sandbox.Background.sweep_stale_units()
        rescue
          exception ->
            Logger.warning(
              "BackgroundJobs: boot sweep of stale detached units failed (#{Exception.message(exception)})"
            )
        end
      end)
    end

    {:ok, %{jobs: %{}, owners: %{}, tick_timer: nil, unknown_since: %{}}}
  end

  @impl true
  def handle_call({:start_job, spec}, _from, state), do: handle_start(spec, nil, state)

  def handle_call({:start_job, spec, handle}, _from, state) do
    # Test seam only (see `start_job_with_handle/2`): the backend handle is
    # supplied by the caller instead of being spawned, so the exit-OBSERVER
    # routing can be exercised without a systemd user bus. Everything else is
    # the production start path.
    handle_start(spec, handle, state)
  end

  def handle_call({:job, id, owner_pid}, _from, state) do
    case fetch_owned_job(state, id, owner_pid) do
      {:ok, job} ->
        {job, state} = reconcile(job, state)
        {:reply, {:ok, job}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read, id, owner_pid, max_bytes}, _from, state) do
    case fetch_owned_job(state, id, owner_pid) do
      {:error, reason} ->
        {:reply, {:error, ownership_error(id, reason)}, state}

      {:ok, job} ->
        {job, state} = reconcile(job, state)

        case read_delta(job, max_bytes) do
          {:ok, text, job} ->
            # The caller just learned this job's status from the tool result, so a later notice would be a duplicate.
            job = mark_announced(job)
            {:reply, {:ok, %{text: text, job: job}}, put_job(state, job)}

          {:error, message} ->
            {:reply, {:error, message}, state}
        end
    end
  end

  def handle_call({:list, owner_pid}, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> filter_by_owner(owner_pid)
      |> sort_newest_first()

    {jobs, state} =
      Enum.reduce(jobs, {[], state}, fn job, {acc, acc_state} ->
        {job, acc_state} = reconcile(job, acc_state)
        # Same rule as `read/2`: a terminal job handed back to the caller counts as announced.
        job = mark_announced(job)
        {[job | acc], put_job(acc_state, job)}
      end)

    {:reply, Enum.reverse(jobs), state}
  end

  def handle_call({:snapshot, owner_pid}, _from, state) do
    # Pure state read: no reconciliation, no file I/O, no mutation.
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.owner_pid == owner_pid))
      |> sort_newest_first_with_id()
      |> Enum.take(@snapshot_limit)

    {:reply, jobs, state}
  end

  def handle_call({:claim_finished_notices, owner_pid}, _from, state) do
    # Exactly-once: the SAME call selects and marks, so two consecutive claims cannot return the same job.
    {claimed, state} =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.owner_pid == owner_pid and terminal?(&1) and not &1.announced))
      |> sort_newest_first_with_id()
      |> Enum.reduce({[], state}, fn job, {acc, acc_state} ->
        job = %{job | announced: true}
        {[job | acc], put_job(acc_state, job)}
      end)

    {:reply, {:ok, Enum.reverse(claimed)}, state}
  end

  def handle_call({:kill, id, reason, owner_pid}, _from, state) do
    case fetch_owned_job(state, id, owner_pid) do
      {:error, err} ->
        {:reply, {:error, err}, state}

      {:ok, job} ->
        if live?(job) do
          case stop_job(job, reason) do
            {:ok, job} ->
              # The CALLER requested this kill, so it already knows the job is ending: suppress the
              # completion notice (also covers a `:stopping` record a unit observer settles later).
              job = suppress_notice(job)
              {:reply, {:ok, job}, put_job(state, job)}

            {:error, message} ->
              # Deliberately NOT announced: the backend could not stop the process, so the outcome is
              # unknown and the agent SHOULD still learn the final status from a later notice.
              Logger.warning("BackgroundJobs: kill of #{job.id} failed: #{message}")

              {:reply, {:error, message},
               put_job(state, %{job | status: :stopping, detail: message})}
          end
        else
          # Same rule as `read/2` / `list/1`: a terminal job handed back to the caller counts as
          # announced, because the caller just learned its final status.
          job = suppress_notice(job)
          {:reply, {:error, {:already_finished, job}}, put_job(state, job)}
        end
    end
  end

  def handle_call({:reap_under, prefix}, _from, state) do
    state =
      Enum.reduce(state.jobs, state, fn {_id, job}, acc ->
        if live?(job) and Platform.path_under?(job.cwd, prefix) do
          case stop_job(job, :reaped) do
            {:ok, job} ->
              put_job(acc, job)

            {:error, message} ->
              Logger.warning(
                "BackgroundJobs: reaping #{job.id} under #{prefix} failed: #{message}"
              )

              acc
          end
        else
          acc
        end
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, state) when is_port(port) do
    # OUTPUT only comes from `:port` handles. A `:unit` handle's port is the
    # `systemd-run --wait` client (the exit observer): the unit writes its own
    # output to the log file via `-p StandardOutput=append:…`, so anything
    # arriving on that port is systemd-run's own (quiet-mode) diagnostics and is
    # deliberately dropped.
    case find_live_job_by_port(state.jobs, port) do
      {:ok, job} -> append_output(job, chunk)
      :error -> :ok
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, state) when is_port(port) do
    # The ONE completion signal for BOTH handle shapes: a `:port` job's own
    # child, and a `:unit` job's `systemd-run --wait` observer (which exits with
    # the UNIT's status). `mark_finished/2` maps it (and a kill request already
    # in flight → `:killed`).
    case find_live_job_by_observer_port(state.jobs, port) do
      {:ok, job} ->
        {:noreply, put_job(state, mark_finished(job, code)) |> forget_unknown(job.id)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:reconcile_tick, state) do
    state = %{state | tick_timer: nil}

    state =
      Enum.reduce(state.jobs, state, fn {_id, job}, acc ->
        if live?(job) and unit_handle?(job.handle) do
          {job, acc} = reconcile_job(job, acc)
          put_job(acc, job)
        else
          acc
        end
      end)

    {:noreply, arm_tick(state)}
  end

  # The load-bearing lifetime guarantee: one monitor per OWNER (agent) pid. Every way an agent can end funnels through this single `:DOWN` — normal completion, crash, graceful cancel, force kill.
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.fetch(state.owners, pid) do
      {:ok, %{ref: ^ref, ids: ids}} ->
        state = %{state | owners: Map.delete(state.owners, pid)}

        state =
          Enum.reduce(ids, state, fn id, acc ->
            case Map.fetch(acc.jobs, id) do
              {:ok, job} ->
                if live?(job) do
                  case stop_job(job, :owner_exited) do
                    {:ok, job} ->
                      put_job(acc, job)

                    {:error, message} ->
                      Logger.warning(
                        "BackgroundJobs: killing #{id} after owner #{inspect(pid)} exit failed: #{message}"
                      )

                      acc
                  end
                else
                  acc
                end

              :error ->
                acc
            end
          end)

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # A `:port` job's child ended (its port is linked to this registry, which opened it), so its `{:EXIT, port, _}` signal is expected and ignored — the real exit status already arrived as `{:exit_status, code}`. ANY OTHER linked exit is unexpected: the registry links ONLY its supervisor (job side effects use the unlinked `Task.start/1`) and `:gen_server` turns a PARENT exit into a `terminate/2` call, so it is logged and the registry stays up — going down would strand every job it tracks.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning("BackgroundJobs: unexpected linked exit #{inspect(pid)} #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Defence in depth: the supervisor is shutting down, so no detached process started by this registry may outlive it.
    # Bounded by construction: the `:unit` path's `Sandbox.Background.kill/1` delegates to `stop_unit_async/1`, which spawns a `Task` for `systemctl --user stop` and returns immediately, and a `:port` handle's port closes with this process (its child dies with it). The ONE genuinely async risk is therefore a `systemctl --user stop` that does not finish before the VM goes down, and `EvoGit.Sandbox.Background.sweep_stale_units/0` closes it at the next boot by garbage-collecting `genesis-job-*` units whose embedded `b<beam_os_pid>` is no longer alive.
    Enum.each(state.jobs, fn {_id, job} ->
      if live?(job), do: kill_detached(job.handle)
    end)

    :ok
  end

  ## Start path

  # Shared by the public `:start_job` call and the `start_job_with_handle/2`
  # test seam, so both go through the SAME cap check, start path and tick arming.
  defp handle_start(spec, handle_override, state) do
    if live_jobs_for_owner(state.jobs, spec.owner_pid) >= @max_jobs_per_owner do
      {:reply, {:error, limit_error()}, state}
    else
      case do_start_job(spec, handle_override, state) do
        {:ok, job, state} -> {:reply, {:ok, job}, arm_tick(prune_finished(state))}
        {:error, message} -> {:reply, {:error, message}, state}
      end
    end
  end

  defp do_start_job(spec, handle_override, state) do
    id = generate_id(state.jobs)
    output_path = Path.join(scratch_dir(), "genesis_job_#{id}.log")

    with :ok <- prepare_output_file(output_path),
         {:ok, handle} <-
           resolve_handle(handle_override, %{
             command: spec.command,
             cwd: spec.cwd,
             output_path: output_path,
             job_id: id
           }) do
      {ref, state} = ensure_owner_monitor(state, spec.owner_pid)

      # `spec.repo_root` is accepted for caller context only — the job record has no slot for it (its `cwd` is what `reap_under/1` matches on).
      job =
        %{
          id: id,
          kind: "bash",
          label: spec.label,
          owner_pid: spec.owner_pid,
          owner_ref: ref,
          agent_id: spec.agent_id,
          task_id: spec.task_id,
          cwd: spec.cwd,
          output_path: output_path,
          handle: handle,
          status: :running,
          exit_code: nil,
          detail: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          cursor: 0,
          lines_read: 0,
          announced: false
        }
        |> settle_start_exit()

      {:ok, job, put_job(add_owner_job(state, spec.owner_pid, id), job)}
    end
  end

  defp resolve_handle(nil, payload), do: spawn_detached(payload)
  defp resolve_handle(handle, _payload), do: {:ok, handle}

  # A systemd backend may observe the job's exit ALREADY inside the spawn call —
  # `systemd-run --wait` returns the unit's own status, so a command that
  # finishes (or fails to start) within the start grace window hands back
  # `pending_exit_code` instead of a live observer port. Apply it through the
  # ONE exit mapping so such a job is terminal (and noticeable) immediately
  # rather than waiting forever for a port message that can never arrive.
  defp settle_start_exit(%{handle: %{pending_exit_code: code}} = job),
    do: mark_finished(job, code)

  defp settle_start_exit(job), do: job

  # Output destination is decided ONCE, at spawn time, and stored on the job: a detached process has no process dictionary to re-derive it from later.
  defp scratch_dir do
    EvoGit.Sandbox.resolve_tmpdir()
  end

  # Non-bang on purpose: a permission problem must surface as prose, never as a crash of the shared registry.
  defp prepare_output_file(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.touch(path) do
      :ok
    else
      {:error, reason} ->
        {:error,
         "Could not create the background job's output file at #{path} (#{describe(reason)}). Check that the scratch directory is writable, then retry."}
    end
  end

  defp spawn_detached(payload) do
    case EvoGit.Sandbox.spawn_detached(payload) do
      {:ok, handle} ->
        {:ok, handle}

      {:error, reason} ->
        {:error,
         "Could not start the background job (#{describe(reason)}). Retry; if it keeps failing, run the command in the foreground instead."}

      other ->
        {:error,
         "Could not start the background job (unexpected backend reply #{inspect(other)}). Retry; if it keeps failing, run the command in the foreground instead."}
    end
  rescue
    exception ->
      {:error,
       "Could not start the background job (#{Exception.message(exception)}). Retry; if it keeps failing, run the command in the foreground instead."}
  catch
    kind, reason ->
      {:error,
       "Could not start the background job (#{kind}: #{describe(reason)}). Retry; if it keeps failing, run the command in the foreground instead."}
  end

  defp generate_id(jobs) do
    candidate = @id_prefix <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    if Map.has_key?(jobs, candidate) do
      generate_id(jobs)
    else
      candidate
    end
  end

  ## Owner monitor bookkeeping

  defp ensure_owner_monitor(state, owner_pid) do
    case Map.fetch(state.owners, owner_pid) do
      {:ok, %{ref: ref}} ->
        {ref, state}

      :error ->
        ref = Process.monitor(owner_pid)
        entry = %{ref: ref, ids: MapSet.new()}
        {ref, %{state | owners: Map.put(state.owners, owner_pid, entry)}}
    end
  end

  defp add_owner_job(state, owner_pid, id) do
    case Map.fetch(state.owners, owner_pid) do
      {:ok, entry} ->
        %{
          state
          | owners: Map.put(state.owners, owner_pid, %{entry | ids: MapSet.put(entry.ids, id)})
        }

      :error ->
        state
    end
  end

  defp live_jobs_for_owner(jobs, owner_pid) do
    Enum.count(jobs, fn {_id, job} -> job.owner_pid == owner_pid and live?(job) end)
  end

  defp filter_by_owner(jobs, nil), do: jobs
  defp filter_by_owner(jobs, owner_pid), do: Enum.filter(jobs, &(&1.owner_pid == owner_pid))

  defp fetch_owned_job(state, id, owner_pid) do
    case Map.fetch(state.jobs, id) do
      :error ->
        {:error, :not_found}

      {:ok, job} ->
        if is_nil(owner_pid) or job.owner_pid == owner_pid do
          {:ok, job}
        else
          {:error, :not_owner}
        end
    end
  end

  ## Status reconciliation

  # Reconciles a LIVE job against the backend so a finished job reports finished with no notification. Terminal jobs are returned untouched.
  defp reconcile(job, state) do
    {job, state} = reconcile_job(job, state)
    {job, put_job(state, job)}
  end

  defp reconcile_job(job, state) do
    if live?(job) do
      case detached_status(job.handle) do
        {:running, _} -> {job, forget_unknown(state, job.id)}
        {:exited, code} -> {mark_finished(job, code), forget_unknown(state, job.id)}
        {:unknown, _} -> settle_unknown(job, state)
        _other -> {job, state}
      end
    else
      {job, forget_unknown(state, job.id)}
    end
  end

  # `{:unknown, _}` from the backend must NEVER mean "running forever" — that is
  # exactly the bug that left every systemd job stuck at `:running` (systemd
  # unloads a successfully-exited transient unit immediately, so the post-mortem
  # `systemctl show` fails). Completion is normally delivered by the job's
  # observer port (`handle_info/2` above), so this is a DEFENSIVE FLOOR with a
  # bounded grace, and it yields to the observer: a handle whose observer port is
  # still open is left alone (the port message will settle it with the real exit
  # code), and only a handle with no live observer is settled terminally.
  defp settle_unknown(job, state) do
    if observer_alive?(job.handle) do
      {job, forget_unknown(state, job.id)}
    else
      now = System.monotonic_time(:millisecond)

      case Map.fetch(state.unknown_since, job.id) do
        :error ->
          # `{:unknown, _}` only means "the backend cannot tell" until the grace
          # has elapsed (a transient busy/torn-down unit is tolerated).
          {job, %{state | unknown_since: Map.put(state.unknown_since, job.id, now)}}

        {:ok, since} ->
          if now - since >= unknown_grace_ms() do
            Logger.warning(
              "BackgroundJobs: job #{job.id} has been unreportable for #{now - since}ms; settling it as failed (exit status unknown)"
            )

            {mark_finished(job, nil), forget_unknown(state, job.id)}
          else
            {job, state}
          end
      end
    end
  end

  defp unknown_grace_ms do
    case Application.get_env(:evo_git, :background_unknown_grace_ms, @unknown_grace_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> @unknown_grace_ms
    end
  end

  # Only a `:unit` handle with an OPEN observer port (or a `:port` handle whose
  # child still lives) can still deliver a real exit status — everything else is
  # unreportable and eligible for the floor.
  defp observer_alive?(%{kind: :port, port: port}), do: port_open?(port)
  defp observer_alive?(%{kind: :unit, port: port}), do: port_open?(port)
  defp observer_alive?(_handle), do: false

  defp port_open?(port) when is_port(port) do
    is_list(Port.info(port))
  rescue
    _ -> false
  end

  defp port_open?(_port), do: false

  defp forget_unknown(%{unknown_since: %{} = unknown_since} = state, id) do
    %{state | unknown_since: Map.delete(unknown_since, id)}
  end

  defp forget_unknown(state, _id), do: state

  defp detached_status(handle) do
    EvoGit.Sandbox.detached_status(handle)
  rescue
    exception ->
      Logger.debug(
        "BackgroundJobs: status check failed (#{Exception.message(exception)}); treating as running"
      )

      {:unknown, nil}
  catch
    kind, reason ->
      Logger.debug(
        "BackgroundJobs: status check failed (#{kind}: #{describe(reason)}); treating as running"
      )

      {:unknown, nil}
  end

  defp kill_detached(handle) do
    EvoGit.Sandbox.kill_detached(handle)
  rescue
    exception ->
      {:error, Exception.message(exception)}
  catch
    kind, reason ->
      {:error, "#{kind}: #{describe(reason)}"}
  end

  defp stop_job(job, reason) do
    case kill_detached(job.handle) do
      :ok ->
        {:ok,
         %{
           job
           | status: :killed,
             detail: "killed (#{kill_reason(reason)})",
             finished_at: DateTime.utc_now()
         }}

      {:error, detail} ->
        {:error,
         "Could not stop background job #{inspect(job.id)} (#{describe(detail)}). The process may still be running; retry the kill, or check the process before removing its directory."}

      other ->
        {:error,
         "Could not stop background job #{inspect(job.id)} (unexpected backend reply #{inspect(other)}). The process may still be running; retry the kill."}
    end
  end

  # Exit-status mapping: 0 → completed, other integer → failed, unknown → failed. A job we had already asked to stop (kill in flight) settles as killed.
  defp mark_finished(%{status: :stopping} = job, code) do
    %{
      job
      | status: :killed,
        exit_code: code,
        detail: "killed (stop requested)",
        finished_at: DateTime.utc_now()
    }
  end

  defp mark_finished(job, 0) do
    %{
      job
      | status: :completed,
        exit_code: 0,
        detail: "exit code: 0",
        finished_at: DateTime.utc_now()
    }
  end

  defp mark_finished(job, code) when is_integer(code) do
    %{
      job
      | status: :failed,
        exit_code: code,
        detail: "exit code: #{code}",
        finished_at: DateTime.utc_now()
    }
  end

  defp mark_finished(job, _code) do
    %{
      job
      | status: :failed,
        exit_code: nil,
        detail: "exit status unknown (the detached process ended without a readable exit code)",
        finished_at: DateTime.utc_now()
    }
  end

  ## Output reading

  defp read_delta(job, max_bytes) do
    path = job.output_path

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        # A file that shrank under us (truncated/replaced) restarts at 0 so the new content is not skipped forever.
        cursor = if size < job.cursor, do: 0, else: job.cursor
        available = max(size - cursor, 0)
        take = min(available, max_bytes)

        case read_bytes(path, cursor, take) do
          {:ok, delta} ->
            pending? = available - take > 0
            text = build_text(delta, pending?)

            job = %{
              job
              | cursor: cursor + byte_size(delta),
                lines_read: job.lines_read + count_lines(delta)
            }

            {:ok, text, job}

          {:error, message} ->
            {:error, message}
        end

      {:ok, _other} ->
        {:error, unreadable_output_error(job)}

      {:error, reason} ->
        {:error,
         "The output file for background job #{inspect(job.id)} is not readable at #{path} (#{describe(reason)}). Start a new background job to capture the command's output again."}
    end
  end

  defp read_bytes(_path, _offset, 0), do: {:ok, ""}

  defp read_bytes(path, offset, length) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, device} ->
        result = :file.pread(device, offset, length)
        :file.close(device)

        case result do
          {:ok, data} -> {:ok, data}
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, unreadable_output_error(path, reason)}
        end

      {:error, reason} ->
        {:error, unreadable_output_error(path, reason)}
    end
  end

  defp unreadable_output_error(job) when is_map(job) do
    "The output file for background job #{inspect(job.id)} is not a readable regular file at #{job.output_path}. Start a new background job to capture the command's output again."
  end

  defp unreadable_output_error(path, reason) do
    "Could not read the background job's output file at #{path} (#{describe(reason)}). Retry; if it keeps failing, start a new background job."
  end

  defp build_text(delta, pending?) do
    text = scrub_utf8(delta)

    if pending? do
      text <> "\n[... more output pending; call job_output again]"
    else
      text
    end
  end

  # Detached output is arbitrary bytes; invalid UTF-8 would poison a JSON-encoded tool result downstream, so drop the invalid chunks (cursor advance is still byte-based, so no data is replayed).
  defp scrub_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> String.chunk(:valid)
      |> Enum.filter(&String.valid?/1)
      |> IO.iodata_to_binary()
    end
  end

  defp count_lines(binary) do
    case String.split(binary, "\n") do
      [_single] -> 0
      parts -> length(parts) - 1
    end
  end

  # Port messages are only dispatched here; the file is the single record of the output so a reader never races the append.
  defp append_output(job, chunk) do
    case File.write(job.output_path, chunk, [:append]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "BackgroundJobs: could not append output for #{job.id} to #{job.output_path} (#{describe(reason)}); the chunk was dropped"
        )
    end
  end

  ## Tick management

  defp arm_tick(%{tick_timer: nil} = state) do
    if Enum.any?(state.jobs, fn {_id, job} -> live?(job) and unit_handle?(job.handle) end) do
      %{state | tick_timer: Process.send_after(self(), :reconcile_tick, @tick_interval_ms)}
    else
      state
    end
  end

  defp arm_tick(state), do: state

  ## Records / helpers

  defp put_job(state, job), do: %{state | jobs: Map.put(state.jobs, job.id, job)}

  defp live?(%{status: status}), do: status in [:running, :stopping]
  defp live?(_job), do: false

  # Terminal = the job can never change status again, so it is eligible for a (single) completion notice.
  defp terminal?(%{status: status}), do: status in [:completed, :killed, :failed]
  defp terminal?(_job), do: false

  # Marks a terminal job as announced ONCE; never reset back to `false` and never touches a live job.
  defp mark_announced(job) do
    if terminal?(job) and not job.announced do
      %{job | announced: true}
    else
      job
    end
  end

  # The kill path's own marking: the caller REQUESTED the stop, so it knows the outcome. Unlike
  # `mark_announced/1` this also applies to a non-terminal record (a `:stopping` unit handle
  # settles later), so the later `mark_finished/2` cannot resurrect a notice.
  defp suppress_notice(job), do: %{job | announced: true}

  defp unit_handle?(%{kind: :unit}), do: true
  defp unit_handle?(_handle), do: false

  # OUTPUT routing: only a `:port` handle's chunks are the job's own output.
  defp find_live_job_by_port(jobs, port) do
    Enum.find_value(jobs, :error, fn {_id, job} ->
      if live?(job) and match?(%{kind: :port, port: ^port}, job.handle) do
        {:ok, job}
      end
    end)
  end

  # EXIT routing: BOTH handle shapes carry a port that reports the job's exit —
  # a `:port` handle's own child and a `:unit` handle's `systemd-run --wait`
  # observer client.
  defp find_live_job_by_observer_port(jobs, port) do
    Enum.find_value(jobs, :error, fn {_id, job} ->
      if live?(job) and match?(%{port: ^port}, job.handle) do
        {:ok, job}
      end
    end)
  end

  defp sort_newest_first(jobs), do: Enum.sort_by(jobs, &started_key/1, :desc)

  # Deterministic newest-first ordering for the state-only reads: two jobs started in the same microsecond would
  # otherwise come back in arbitrary map-iteration order.
  defp sort_newest_first_with_id(jobs), do: Enum.sort_by(jobs, &{-started_key(&1), &1.id})

  defp started_key(job) do
    case job.started_at do
      %DateTime{} = started_at -> DateTime.to_unix(started_at, :microsecond)
      _ -> 0
    end
  end

  # Finished records are retained so a caller can still read the tail after the process exits; the oldest are dropped past the retention cap. Live jobs are never pruned.
  defp prune_finished(state) do
    state = %{state | unknown_since: prune_unknown_since(state)}
    finished = state.jobs |> Map.values() |> Enum.reject(&live?/1)
    excess = length(finished) - @max_finished_retained

    if excess > 0 do
      finished
      |> Enum.sort_by(&finished_key/1)
      |> Enum.take(excess)
      |> Enum.reduce(state, fn job, acc -> %{acc | jobs: Map.delete(acc.jobs, job.id)} end)
    else
      state
    end
  end

  # The floor only ever tracks LIVE jobs: a job that reached a terminal status by
  # another route (a kill, or its observer port's exit message) drops its marker
  # here, so the bookkeeping cannot grow without bound.
  defp prune_unknown_since(state) do
    state.unknown_since
    |> Enum.filter(fn {id, _since} ->
      match?(%{status: status} when status in [:running, :stopping], Map.get(state.jobs, id))
    end)
    |> Map.new()
  end

  defp finished_key(job) do
    case job.finished_at do
      %DateTime{} = finished_at -> DateTime.to_unix(finished_at, :microsecond)
      _ -> 0
    end
  end

  ## Prose helpers

  defp limit_error do
    "background job limit reached for this agent (limit: #{@max_jobs_per_owner}); use job_kill to stop an unneeded job, wait for it to finish, then retry"
  end

  defp ownership_error(id, :not_found) do
    "No background job with id #{inspect(id)} is known to this agent. Call job_list to see this agent's background jobs, then retry with a valid id."
  end

  defp ownership_error(id, :not_owner) do
    "Background job #{inspect(id)} belongs to another agent, so this agent cannot read it. Call job_list to see this agent's own background jobs."
  end

  defp describe(reason) when is_binary(reason), do: reason

  # The backend's own backstop for a missing `cwd` — the layer BELOW `normalize_start_spec/1`, which already rejects it with prose — rendered as prose so `start_job/1` stays one actionable sentence whichever layer caught it.
  defp describe({:cwd_missing, path}), do: "the working directory does not exist: #{path}"
  defp describe({tag, detail}) when is_atom(tag), do: "#{tag}: #{describe_value(detail)}"
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: describe_value(reason)

  defp describe_value(value) when is_binary(value), do: value
  defp describe_value(value) when is_atom(value), do: Atom.to_string(value)
  defp describe_value(value), do: inspect(value)

  defp kill_reason(nil), do: "stopped by request"
  defp kill_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp kill_reason(reason) when is_binary(reason), do: reason
  defp kill_reason(reason), do: inspect(reason)
end
