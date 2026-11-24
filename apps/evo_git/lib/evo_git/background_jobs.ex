defmodule EvoGit.BackgroundJobs do
  @moduledoc """
  Registry for detached ("background") shell jobs started by agents.

  `start_job/1` starts a command through `EvoGit.Sandbox.spawn_detached/1` (the ONE detached entry point, answered by every sandbox backend) and records it; the command's stdout/stderr accumulate in a per-job log file under the sandbox scratch directory, so callers poll `job/2` for status and drain the log with `read/2`, which returns only the bytes produced since the previous read.
  Job lifetime — every job is bound to its OWNING AGENT process (`:owner_pid`); `start_job/1` installs ONE `Process.monitor/1` per owner, and when that process dies EVERY job it started is killed and the monitor bookkeeping is dropped. Because agent processes are unlinked `Task.Supervisor.async_nolink` children killed by `Lifecycle.cancel_agent/2`, this single monitor covers every way an agent can end — normal completion, crash, graceful cancel AND force kill — so no hooks are needed at `EvoGit.TaskRegistry`'s terminal-write sites. The monitor is deliberately installed on the AGENT pid, never on the short-lived tool task that calls this module.
  Completion detection — ONE primary mechanism plus two cheap, idempotent fallbacks: the **observer port** (every backend keeps a port on the handle that reports the job's exit — a `:port` job's own child, and a `:unit` job's `systemd-run --wait` client, which exits with the UNIT's status), the **lazy reconcile** (every `read/2` / `list/1` / `job/2` re-checks a live job against the backend via `EvoGit.BackgroundJobs.StatusProbe` and the registry's per-job probe cache) and the **periodic tick** (while at least one live job uses a `:unit` handle, ONE `@tick_interval_ms` timer re-reconciles them so `finished_at` / `exit_code` land promptly even if nobody reads; it is disarmed as soon as no such job remains). `{:unknown, nil}` from the backend is never treated as "running forever": a job that stays unreportable with no live observer port is settled terminally as `:failed` after a bounded `@unknown_grace_ms` grace.
  No handler blocks on the OS — a `:unit` handle's status probe (`systemctl --user show`, one subprocess) NEVER runs inside this GenServer: `StatusProbe.start/2` computes it in its own unlinked task and reports back with `{:probe_result, job_id, result}`, and `reconcile_job/2` applies only the CACHED result of a live `:unit` job (never inventing a status it has not observed). A `:port` handle's probe is `Port.info/2` and stays synchronous. `@probe_min_interval_ms` (call-time seam `:background_probe_min_interval_ms`) bounds how often one job may be re-probed, so a tight poll loop cannot fork a subprocess per call.
  Completion notices — the per-turn `claim_finished_notices/1` is a PURE `:ets` read of the public mirror owned by `EvoGit.BackgroundJobs.NoticeMirror`: it never calls this GenServer, so a busy, blocked or slow registry cannot stall an agent's turn start and the claim cannot time out (there is no reply to wait for, therefore no "timed out means no notices" path). `%{jobs: ...}` here stays AUTHORITATIVE — the mirror is only that read path, kept correct by the ONE state writer `put_job/2` — and after a claim's atomic `:ets.take/2` the caller fires ONE `GenServer.cast/2` (`{:notices_claimed, owner_pid, ids}`) so the registry records the same `announced: true` marks.
  Error vocabulary — an unreachable registry is NEVER reported as a missing record: the ONE transport boundary (`EvoGit.BackgroundJobs.RegistryClient`) turns an exited call into `{:error, :registry_unavailable}`, and every public function maps that to its own documented answer in one visible place. `job/2` and `kill/3` return that atom verbatim (a dead registry is honestly "unavailable", not "no such job"); `start_job/1` and `read/2` keep their `{:error, message}` prose contract, so the availability failure becomes ONE actionable sentence; `list/1` and `snapshot/1` answer `[]` and `reap_under/1` always answers `:ok` (a list/admin-shaped API never raises). The ownership/finished probes in `job/2` and `kill/3` keep the small semantic tuples documented on those functions (`:not_found` is reserved for an id the registry really does not know) so a caller can branch on them before formatting prose. No input is ever converted with `String.to_atom/1`.
  Process registry — every job is ALSO recorded as ONE `:background_job` execution in `EvoGit.ProcessManager` (the single source of truth for what this node runs): the start path `track`s it with the agent-visible identity, `attach`es the normalized OS handle (`EvoGit.Sandbox.Background.normalize_handle/1`) and stores the returned `execution_id` on the job record, and ONE terminal funnel in `put_job/2` `finish`es that execution when the job reaches a terminal status (`:completed` / `:failed` / `:killed`, plus `:killed` on a registry shutdown). The registry resolves its manager ONCE at `start_link/1` (`:process_manager` opt, default `EvoGit.ProcessManager`) and passes it as `server:`; every call is total, so an unavailable manager never affects job bookkeeping. Because the manager routes a `:background_job` kill back to `kill/3`, killing through either door stops the process and settles both records.
  Retention and tombstones — `EvoGit.BackgroundJobs.Retention` owns the finished-record policy (`prune/1`, run on every accepted start AND after a notice claim): a finished record a LIVE owner has not yet observed is never evicted by an ordinary cap, per-owner caps separate living from dead owners, and a global valve converts (never silently deletes) a still-unobserved record into a TOMBSTONE. A tombstone keeps the id, status, exit code and log path, so `job/2` answers it verbatim, `read/2` serves the surviving log tail, `list/1` includes it and `kill/3` answers `{:error, {:already_finished, tombstone}}` — an id this registry issued is never again reported as unknown, and `generate_id/2` never reuses it.
  """

  use GenServer

  require Logger

  alias EvoGit.BackgroundJobs.Notice
  alias EvoGit.BackgroundJobs.NoticeMirror
  alias EvoGit.BackgroundJobs.RegistryClient
  alias EvoGit.BackgroundJobs.Retention
  alias EvoGit.BackgroundJobs.StatusProbe
  alias EvoGit.ProcessManager
  alias EvoGit.Platform

  # Compile-time Mix env — safe in releases (`Mix.env/0` is evaluated at compile time; in prod releases it resolves to `:prod`).
  # Used to skip the one-shot boot sweep of stale detached units in the test env, matching the existing codebase pattern (`EvoGit.Application`'s boot-distribution gate).
  @mix_env Mix.env()

  ## Tunables (module attributes only — deliberately no config keys)

  # Maximum number of LIVE jobs a single owner (agent) may have at once.
  @max_jobs_per_owner 10
  # Periodic reconcile interval for live `:unit`-handled jobs.
  # Overridable for tests via the app env `:background_tick_interval_ms` (a
  # test-only CALL-TIME seam; the production default below is unchanged).
  @tick_interval_ms 1_000
  # Defensive floor: how long a live job may stay UNREPORTABLE (the backend says
  # `{:unknown, nil}` and no observer port is open) before it is settled
  # terminally as `:failed` instead of pretending to run forever. A transient
  # systemctl failure is tolerated inside this window; the observer port always
  # wins (see `settle_unknown/2`). Overridable for tests via the app env
  # `:background_unknown_grace_ms`.
  @unknown_grace_ms 15_000
  # Suggested polling defaults for callers implementing a `wait: true` loop (this module does NOT block — see `wait_default_ms/0`).
  # `@wait_default_ms` is the PRODUCTION default wait budget and it is the SAME
  # generous 120 s the foreground shell tool advertises: a background job is
  # usually started BECAUSE it takes minutes, so a small default would make the
  # agent re-poll every few seconds instead of settling the job with ONE call.
  # It is read through `resolved_wait_default_ms/0`, a CALL-TIME seam (app env
  # `:background_wait_default_ms`, non-negative integers only) so a suite can pin
  # the default-budget path of `EvoGit.Agent.Tools.JobOutput`'s `wait: true` loop
  # without sleeping the full 120 s.
  @wait_default_ms 120_000
  @poll_interval_ms 100
  # Headroom (ms) the DISPATCHER needs on top of a wait budget (the completing
  # read plus registry latency — a poll of a `:unit` job now applies the probe
  # CACHE, so no handler forks `systemctl`).
  # `wait_max_ms/0` SUBTRACTS it from the scheduler's tool ceiling, and
  # `EvoGit.Agent.Tools.default_timeout_ms/1` adds it straight back through
  # `dispatch_headroom_ms/0`, so `job_output`'s dispatch ceiling lands exactly on
  # `[:scheduler, :max_tool_timeout]`. ONE literal lives here — never duplicate it.
  @dispatch_headroom_ms 25_000
  # Last-resort ceiling, used ONLY when `Config.resolve/1` does not answer a
  # positive integer for `[:scheduler, :max_tool_timeout]`. It MIRRORS that key's
  # schema default (`config/schema/definitions.ex` is the single source of
  # truth) and is unreachable in practice, because the schema enforces a
  # positive integer.
  @wait_max_fallback_ms 1_800_000
  # Defensive floor for the derived cap: a configured ceiling smaller than the
  # headroom must never yield a zero/negative wait budget.
  @wait_max_floor_ms 1_000
  # A spawn can briefly block (systemd-run / port open), so registry calls use an explicit timeout instead of the 5s default.
  @call_timeout 15_000
  # `reap_under/1` runs inside a GenServer teardown path (WorktreeManager's `:DOWN`), so it must fail fast instead of stalling that process.
  @reap_call_timeout 5_000
  # Default `read/2` byte cap when the caller does not pass `:max_bytes`.
  @default_max_bytes 20_000
  # Per-owner cap on `snapshot/1` (the per-turn read; a full `list/1` stays uncapped).
  @snapshot_limit 20
  # Minimum interval (ms) between two OFF-PROCESS status probes of the SAME job.
  # A `:unit` probe forks `systemctl --user show`, so a tight `job/2` poll loop
  # must not start one probe per call; between probes a read answers from the
  # registry's cached result. Overridable for tests via the app env
  # `:background_probe_min_interval_ms` (a CALL-TIME seam, non-negative
  # integers only; the production default below is unchanged).
  @probe_min_interval_ms 250

  # Job ids are SHORT and predictable — `@id_prefix` plus a per-registry
  # monotonically increasing counter (`bash-1`, `bash-2`, …) — because an agent
  # has to repeat one in `job_output`/`job_kill`. The counter lives in the
  # GenServer state and `generate_id/2` skips any candidate still held by
  # `state.jobs` OR by a tombstone in `state.tombstones`, so an id is never
  # reused while ANY answer for it exists. `bash-<n>` is also safe as a
  # systemd unit-name component (`Sandbox.Background.unit_name/1`).
  @id_prefix "bash-"

  @type status :: :running | :stopping | :completed | :killed | :failed

  @type job :: %{
          id: String.t(),
          kind: String.t(),
          label: String.t(),
          owner_pid: pid() | nil,
          owner_ref: reference() | nil,
          agent_id: term(),
          task_id: term(),
          cwd: String.t(),
          output_path: String.t(),
          handle: map() | nil,
          execution_id: String.t() | nil,
          status: status(),
          exit_code: integer() | nil,
          # Execution-level terminal cause (the `:reason` the execution record is
          # settled with) — `nil` while the job is live, then one of
          # `:exited | :timeout | :owner_died | {:killed_by, term()} |
          # {:crashed, term()} | :no_os_process`. The job's own `:detail` prose is
          # a SEPARATE human-facing field.
          terminal_reason: term(),
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

  @doc """
  Starts the registry. Honours `:name` (default `#{inspect(__MODULE__)}`) and `:process_manager` — the `EvoGit.ProcessManager` instance every execution is registered with (default `EvoGit.ProcessManager`), resolved ONCE here so an isolated manager is the suite's test-isolation seam.
  Also honours `:retention` — a keyword list or map OVERLAYING `EvoGit.BackgroundJobs.Retention.defaults/0` per key (`:max_observed_per_owner`, `:max_dead_per_owner`, `:max_finished_total`, `:max_tombstones`), so an isolated registry can drive its retention caps without any app-env key.
  The registered name is handed to `init/1` as `:server_name` because it is ALSO the name of the public notice-mirror ETS table (`EvoGit.BackgroundJobs.NoticeMirror`), which an ETS table can carry without creating any atom.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, with_server_name(opts, name), name: name)
  end

  defp with_server_name(opts, name) do
    if is_list(opts) and Keyword.keyword?(opts) do
      Keyword.put(opts, :server_name, name)
    else
      [server_name: name]
    end
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
  The job holds one scheduler tool permit for its full live lifetime: a runtime
  tool's inherited permit is transferred to the registry; direct callers acquire
  in the calling process before launch, never inside the singleton registry.
  An unavailable scheduler refuses launch rather than bypassing the tool pool.
  Spec (`map` or keyword list): `:command` (**required**) — the shell command line to run; `:cwd` (**required**) — existing absolute working directory; `:owner_pid` (**required**) — the owning AGENT pid, defaulting to `current_owner_pid/0` when absent; `:repo_root` — optional repository root (context only); `:label` — optional short human label (defaults to the command's first line); `:agent_id` / `:task_id` — optional identifiers carried on the record.
  Returns `{:ok, job}` — the job record (`t:job/0`), whose output is written to its `:output_path` field — or `{:error, message}`, one actionable prose sentence.
  """
  @spec start_job(map() | keyword()) :: {:ok, job()} | {:error, String.t()}
  def start_job(spec) do
    with {:ok, normalized} <- normalize_start_spec(spec) do
      start_with_permit(normalized, nil)
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
      start_with_permit(normalized, handle)
    end
  end

  @doc """
  Fetches one job by id, reconciling a live job against the backend first.
  `opts[:owner_pid]` fences ownership: when it is set, a job belonging to another owner yields `{:error, :not_owner}`; otherwise the lookup is unscoped.
  Returns `{:ok, job}`, `{:error, :not_found}` (an id the registry does not know), `{:error, :not_owner}` (the job belongs to a different owner) or `{:error, :registry_unavailable}` — the registry is not running, so NOTHING is known about the id; retry instead of treating it as missing.
  An id whose record aged out of retention returns `{:ok, tombstone}` — a job-shaped map carrying the terminal status, exit code and log path plus `evicted_reason`/`evicted_at` and `announced: true` — so `{:error, :not_found}` is reserved for an id the registry never issued, and another owner's tombstone is `{:error, :not_owner}`.
  """
  @spec job(String.t(), keyword()) ::
          {:ok, job()} | {:error, :not_found | :not_owner | :registry_unavailable}
  def job(id, opts \\ []) when is_binary(id) do
    case call_registry({:job, id, Keyword.get(opts, :owner_pid)}) do
      {:ok, reply} -> reply
      {:error, :registry_unavailable} -> {:error, :registry_unavailable}
    end
  end

  @doc """
  Reads output produced since the previous read. The job's `:cursor` advances ONLY by the bytes actually returned, so a capped read never loses data: when more output is pending, the returned `:text` ends with `"[... more output pending; call job_output again]"`.
  Options: `:max_bytes` — maximum number of output bytes returned BY THIS CALL (positive integer, default `#{@default_max_bytes}`; bytes beyond the cap stay unread for the next call); `:owner_pid` — fences ownership (another owner's job is an error).
  Returns `{:ok, %{text: String.t(), job: job}}` or `{:error, message}` — one actionable prose sentence (unknown/foreign job, missing output file, bad `:max_bytes`, unreachable registry).
  A tombstone serves the surviving log tail from its saved cursor (advancing it), and when the log file is gone it returns one honest `{:error, message}` naming the final status/exit code, the retention eviction and the former log path — never an "unknown job" message.
  """
  @spec read(String.t(), keyword()) ::
          {:ok, %{text: String.t(), job: job()}} | {:error, String.t()}
  def read(id, opts \\ []) when is_binary(id) do
    with {:ok, max_bytes} <- normalize_max_bytes(Keyword.get(opts, :max_bytes)) do
      case call_registry({:read, id, Keyword.get(opts, :owner_pid), max_bytes}) do
        {:ok, reply} -> reply
        {:error, :registry_unavailable} -> {:error, registry_down_error()}
      end
    end
  end

  @doc """
  Lists jobs, newest first, reconciling live jobs against the backend first.
  `opts[:owner_pid]` limits the result to one owner's jobs. Returns `[]` when the registry is unreachable (a list-shaped API never raises).
  The result includes that owner's tombstones (all tombstones when `opts[:owner_pid]` is nil), newest first and unreconciled.
  """
  @spec list(keyword()) :: [job()]
  def list(opts \\ []) do
    case call_registry({:list, Keyword.get(opts, :owner_pid)}) do
      {:ok, jobs} when is_list(jobs) -> jobs
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
      case call_registry({:snapshot, owner_pid}) do
        {:ok, jobs} when is_list(jobs) -> jobs
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Claims this owner's finished-but-unannounced jobs and returns `{:ok, jobs}` (newest first), marking exactly those jobs `announced: true` so a second call can never return the same job again.
  This is a PURE `:ets` read of the public notice mirror (`EvoGit.BackgroundJobs.NoticeMirror`) — NEVER a registry call — so a busy, blocked or slow registry cannot delay an agent's turn start, and there is no bounded call whose timeout could silently mean "no notices".
  `:ets.take/2` is atomic per key, which is what makes the claim exactly-once even with two concurrent claimants; the registry's own map stays authoritative, and ONE `GenServer.cast/2` records the marks it did not make itself.
  `announced` means "the owner already knows this job's outcome — no completion notice needed": it starts `false`, and is set by this claim, by `read/2` / `list/1` for the terminal jobs they return, and by a successful `kill/3` (including its `{:already_finished, job}` branch) — every one of those removes the job from the mirror.
  `opts[:owner_pid]` defaults to `current_owner_pid/0`; nothing to claim (or no registry / no table / unknown owner) yields `{:ok, []}`.
  Only TERMINAL statuses (`:completed | :killed | :failed`) are ever eligible.
  """
  @spec claim_finished_notices(keyword()) :: {:ok, [job()]}
  def claim_finished_notices(opts \\ []) do
    owner_pid = Keyword.get(opts, :owner_pid) || current_owner_pid()

    if is_pid(owner_pid) do
      case NoticeMirror.claim(NoticeMirror.table_for(server()), owner_pid) do
        {:ok, []} ->
          {:ok, []}

        {:ok, jobs} ->
          # A cast never blocks and never awaits a reply; cast-then-call from the
          # same process is order-preserving, so a `job/2` right after this claim
          # already sees the marks.
          GenServer.cast(server(), {:notices_claimed, owner_pid, Enum.map(jobs, & &1.id)})
          {:ok, jobs}
      end
    else
      {:ok, []}
    end
  end

  # Cheap pre-flight for `snapshot/1` (the ONE remaining state-only read that still needs the registry): a registry that
  # died between this check and the call is still caught by `EvoGit.BackgroundJobs.RegistryClient`'s single centralized
  # `catch :exit` boundary (the repo forbids scattering broad rescues), but skipping the doomed `GenServer.call` keeps
  # the failure path off the caller's critical path.
  defp registry_alive? do
    case server() do
      pid when is_pid(pid) -> Process.alive?(pid)
      name when is_atom(name) -> Process.whereis(name) != nil
      _other -> true
    end
  end

  @doc """
  Kills a job (and its detached process) if it is still live. `reason` is recorded in the job's `:detail` as `"killed (<reason>)"`; `nil` becomes `"stopped by request"`.
  Returns `{:ok, job}` (now `:killed`), `{:error, :not_found}` (an id the registry does not know), `{:error, :not_owner}` (`opts[:owner_pid]` fences a different owner's job), `{:error, {:already_finished, job}}` (the job already reached a terminal status; nothing was killed), `{:error, :registry_unavailable}` (the registry is not running, so the job is NOT known to be gone and may still be running — retry) or `{:error, message}` (the backend could not stop the process — one actionable prose sentence; the job is left in `:stopping`).
  The caller REQUESTED the kill, so both the `{:ok, job}` and `{:error, {:already_finished, job}}` replies come back with `announced: true` — no completion notice is raised for them (`job/2` afterwards returns a record with `announced: true`). The `{:error, message}` branch deliberately does NOT mark it: the process may still be running, so the agent should still learn the final status from a notice. A `read/2` after a kill still returns the output produced before it.
  `opts[:actor]` names who asked (defaults to `:operator`) and becomes the settled execution's terminal cause `{:killed_by, actor}`.
  A tombstone already reached its terminal status, so killing one answers `{:error, {:already_finished, tombstone}}` with no state or notice-mirror change.
  """
  @spec kill(String.t(), term(), keyword()) ::
          {:ok, job()}
          | {:error,
             :not_found
             | :not_owner
             | :registry_unavailable
             | {:already_finished, job()}
             | String.t()}
  def kill(id, reason \\ nil, opts \\ []) when is_binary(id) do
    message =
      {:kill, id, reason, Keyword.get(opts, :owner_pid), Keyword.get(opts, :actor) || :operator}

    case call_registry(message) do
      {:ok, reply} -> reply
      {:error, :registry_unavailable} -> {:error, :registry_unavailable}
    end
  end

  @doc """
  Kills every live job whose `cwd` is `prefix` or a directory under it — used when a worktree / scratch directory is removed, since the detached processes would otherwise keep running with a deleted working directory. Ownership is deliberately NOT part of the fence here (reaping is a directory-scoped administrative action) and the call ALWAYS answers `:ok`.
  """
  @spec reap_under(String.t()) :: :ok
  def reap_under(prefix) when is_binary(prefix) and prefix != "" do
    _ = call_registry({:reap_under, prefix}, @reap_call_timeout)
    :ok
  end

  def reap_under(_prefix), do: :ok

  ## Tunable readers (public constants for callers implementing `wait: true`)

  @doc "Maximum number of live jobs one owner may have at once."
  def max_jobs_per_owner, do: @max_jobs_per_owner

  @doc """
  Suggested default wait budget (ms) for a caller-side `wait: true` loop — the
  PRODUCTION default is 120_000 (the same generous budget the foreground shell
  tool uses, so a slow job is settled by ONE call instead of a re-poll every few
  seconds), exposed through a CALL-TIME seam (app env
  `:background_wait_default_ms`, honoured only when it is a non-negative
  integer) because `EvoGit.Agent.Tools.JobOutput` reads this value for its
  `wait: true` loop and a test must be able to pin the default-budget path
  without sleeping the full 120 s.
  """
  def wait_default_ms, do: resolved_wait_default_ms()

  @doc """
  Dispatcher headroom (ms) — the slack a `wait: true` call needs on top of its
  wait budget for the completing read plus registry latency.

  `wait_max_ms/0` subtracts it from the scheduler's tool ceiling and
  `EvoGit.Agent.Tools.default_timeout_ms/1` adds it back, so the `job_output`
  dispatch ceiling is exactly `[:scheduler, :max_tool_timeout]`.
  """
  def dispatch_headroom_ms, do: @dispatch_headroom_ms

  @doc """
  Maximum wait budget (ms) for a caller-side `wait: true` loop — DERIVED at CALL
  time from the scheduler's tool ceiling: `[:scheduler, :max_tool_timeout]`
  (schema default 1_800_000 = 30 min) minus `dispatch_headroom_ms/0`, i.e.
  1_775_000 ms (~29.6 min) with the default config, floored at 1_000 so a tiny
  configured ceiling cannot produce a zero/negative budget.

  Deriving the cap (instead of fixing it at 60 s) is what lets ONE long wait
  cover a genuinely slow background job instead of an agent re-polling every
  minute.

  Test-only CALL-TIME seam: app env `:background_wait_max_ms`, honoured only
  when it is a POSITIVE integer (anything else falls through to the derivation),
  so a suite can shrink the cap without sleeping minutes.
  """
  def wait_max_ms, do: resolved_wait_max_ms()

  @doc "Suggested polling interval (ms) for a caller-side `wait: true` loop."
  def poll_interval_ms, do: resolved_poll_interval_ms()

  @doc "Periodic reconcile interval (ms) for live `:unit`-handled jobs."
  def tick_interval_ms, do: resolved_tick_interval_ms()

  @doc "Renders a job status as the public string vocabulary."
  @spec status_string(status() | nil) :: String.t() | nil
  def status_string(:running), do: "running"
  def status_string(:stopping), do: "stopping"
  def status_string(:completed), do: "completed"
  def status_string(:killed), do: "killed"
  def status_string(:failed), do: "failed"
  def status_string(nil), do: nil

  ## Registry plumbing

  # Every public call goes through here, and through `RegistryClient` — the ONE place a `GenServer.call/3`
  # happens — so a dead/absent registry can neither crash a calling tool with an exit nor be reported as a
  # missing record: the transport failure is ALWAYS `{:error, :registry_unavailable}`, which each public
  # function maps to its own documented answer in one visible place.
  # The timeout is explicit per call: `reap_under/1` passes a short one so a wedged registry cannot stall its caller.
  defp call_registry(message, timeout \\ @call_timeout) do
    RegistryClient.call(server(), message, timeout)
  end

  # Acquire only in the caller: the singleton must remain able to observe exits
  # and release capacity while another launch waits. An inherited permit is the
  # tool call's existing capacity, not a second slot.
  defp start_with_permit(spec, handle) do
    acquired =
      if is_reference(spec.tool_permit),
        do: {:ok, spec.tool_permit},
        else: permit_call(fn -> EvoGit.AgentScheduler.acquire_tool_permit(spec.agent_id) end)

    case acquired do
      {:ok, permit} ->
        try do
          message =
            {:start_job,
             Map.merge(spec, %{
               tool_permit: permit,
               launch_requester: self(),
               launch_deadline: System.monotonic_time(:millisecond) + @call_timeout
             }), handle}

          case call_registry(message) do
            {:ok, reply} ->
              reply

            {:error, :registry_unavailable} ->
              {:error,
               "The background job service is not running or the launch timed out before acknowledgement. Any unaccepted launch will be stopped; check the job list before retrying."}
          end
        after
          # Owner-enforced: after handoff this stale caller cannot free the job's
          # permit; before handoff it cleans up failed/dead registry calls.
          release_permit(permit)
        end

      {:error, reason} ->
        {:error, "Background job tool permit request failed: #{inspect(reason)}"}
    end
  end

  # Scheduler availability is an external lifecycle boundary, including shutdown.
  defp permit_call(fun) do
    try do
      fun.()
    catch
      :exit, reason -> {:error, {:scheduler_unavailable, reason}}
    end
  end

  defp release_permit(permit) when is_reference(permit),
    do: permit_call(fn -> EvoGit.AgentScheduler.release_tool_permit(permit) end)

  defp release_permit(_), do: :ok

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
           agent_id: normalize_identity(Map.get(keyed, :agent_id)),
           task_id: normalize_identity(Map.get(keyed, :task_id)),
           tool_permit: Process.get(:evogit_tool_permit)
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

  # Agent/task identities are OPAQUE terms, not text: a Genesis agent id is an
  # integer, so routing it through `trimmed_binary/1` (which nils every
  # non-binary) silently dropped it. Only a blank string is meaningless here;
  # everything else — integers, atoms, tuples — is carried VERBATIM.
  defp normalize_identity(nil), do: nil

  defp normalize_identity(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp normalize_identity(value), do: value

  defp normalize_max_bytes(nil), do: {:ok, @default_max_bytes}
  defp normalize_max_bytes(bytes) when is_integer(bytes) and bytes > 0, do: {:ok, bytes}

  defp normalize_max_bytes(other) do
    {:error,
     "`max_bytes` must be a positive integer — the maximum number of output bytes to return from this call; got #{inspect(other)}. Omit it to use the default of #{@default_max_bytes} bytes."}
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
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

    {:ok,
     %{
       jobs: %{},
       owners: %{},
       tick_timer: nil,
       unknown_since: %{},
       probes: %{},
       tombstones: %{},
       retention: retention_from(opts),
       next_id: 1,
       process_manager: process_manager_from(opts),
       notice_table: NoticeMirror.new(server_name_from(opts))
     }}
  end

  # The registry's OWN registered name, which doubles as the notice-mirror table name (see `NoticeMirror`). A non-atom / absent name yields `nil`, i.e. no mirror (the claim then always answers `{:ok, []}`).
  defp server_name_from(opts) do
    case is_list(opts) and Keyword.keyword?(opts) and Keyword.get(opts, :server_name) do
      name when is_atom(name) and not is_nil(name) -> name
      _other -> nil
    end
  end

  # The retention policy for THIS registry: the `:retention` start option
  # overlays `EvoGit.BackgroundJobs.Retention.defaults/0` per key, and anything
  # unrecognised falls back to the module default (never to "no policy").
  defp retention_from(opts) do
    configured =
      if is_list(opts) and Keyword.keyword?(opts), do: Keyword.get(opts, :retention), else: nil

    Retention.from_opts(configured)
  end

  # Resolved ONCE per registry (never per job) so every `EvoGit.ProcessManager`
  # call in this GenServer targets the SAME instance — the `:process_manager`
  # start option is the suite's isolation seam, the module itself is production.
  defp process_manager_from(opts) do
    configured =
      if is_list(opts) and Keyword.keyword?(opts),
        do: Keyword.get(opts, :process_manager),
        else: nil

    case configured do
      server when is_atom(server) or is_pid(server) or is_tuple(server) -> server
      _other -> EvoGit.ProcessManager
    end
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
    case fetch_owned_record(state, id, owner_pid) do
      {:ok, {:tombstone, tombstone}} ->
        # A tombstoned record can never change status again, so it is answered VERBATIM: no
        # reconcile and no `put_job/2` (which would recreate the record from a stale map).
        {:reply, {:ok, tombstone}, state}

      {:ok, {:job, job}} ->
        {job, state} = reconcile(job, state)
        {:reply, {:ok, job}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read, id, owner_pid, max_bytes}, _from, state) do
    case fetch_owned_record(state, id, owner_pid) do
      {:error, reason} ->
        {:reply, {:error, ownership_error(id, reason)}, state}

      {:ok, {:tombstone, tombstone}} ->
        handle_tombstone_read(tombstone, max_bytes, state)

      {:ok, {:job, job}} ->
        {job, state} = reconcile(job, state)

        case read_delta(job, max_bytes) do
          {:ok, text, job} ->
            # The caller just learned this job's status from the tool result, so a later notice would be a duplicate.
            job = Notice.mark_announced(job)
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
      |> Notice.sort_newest_first()

    {jobs, state} =
      Enum.reduce(jobs, {[], state}, fn job, {acc, acc_state} ->
        {job, acc_state} = reconcile_job(job, acc_state)
        acc_state = maybe_start_probe(acc_state, job)
        # Same rule as `read/2`: a terminal job handed back to the caller counts as announced.
        job = Notice.mark_announced(job)
        {[job | acc], put_job(acc_state, job)}
      end)

    # Tombstones are listed beside the live/recent records (same ownership fence, same newest-first
    # order) but are NEVER reconciled or re-`put`: they are a read-only answer for an id we issued.
    tombstones =
      state.tombstones
      |> Map.values()
      |> filter_by_owner(owner_pid)
      |> Notice.sort_newest_first()

    {:reply, Notice.sort_newest_first(Enum.reverse(jobs) ++ tombstones), state}
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

  def handle_call({:kill, id, reason, owner_pid, actor}, _from, state) do
    case fetch_owned_record(state, id, owner_pid) do
      {:error, err} ->
        {:reply, {:error, err}, state}

      {:ok, {:tombstone, tombstone}} ->
        # Already finished AND out of retention: the answer names the record, and nothing about the
        # state or the notice mirror changes (there is no live process and no record to re-put).
        {:reply, {:error, {:already_finished, tombstone}}, state}

      {:ok, {:job, job}} ->
        if Notice.live?(job) do
          case stop_job(job, reason, {:killed_by, actor}) do
            {:ok, job} ->
              # The CALLER requested this kill, so it already knows the job is ending: suppress the
              # completion notice (also covers a `:stopping` record a unit observer settles later).
              job = Notice.suppress_notice(job)
              {:reply, {:ok, job}, put_job(state, job)}

            {:error, message} ->
              # Deliberately NOT announced: the backend could not stop the process, so the outcome is
              # unknown and the agent SHOULD still learn the final status from a later notice.
              Logger.warning("BackgroundJobs: kill of #{job.id} failed: #{message}")

              # The stop is REQUESTED and in flight, so a later exit settles as a kill by this
              # actor; carrying it on the record is what lets `mark_finished/2` keep it.
              {:reply, {:error, message},
               put_job(state, %{
                 job
                 | status: :stopping,
                   detail: message,
                   terminal_reason: {:killed_by, actor}
               })}
          end
        else
          # Same rule as `read/2` / `list/1`: a terminal job handed back to the caller counts as
          # announced, because the caller just learned its final status.
          job = Notice.suppress_notice(job)
          {:reply, {:error, {:already_finished, job}}, put_job(state, job)}
        end
    end
  end

  def handle_call({:reap_under, prefix}, _from, state) do
    state =
      Enum.reduce(state.jobs, state, fn {_id, job}, acc ->
        if Notice.live?(job) and Platform.path_under?(job.cwd, prefix) do
          case stop_job(job, :reaped, {:killed_by, :operator}) do
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

  # The other half of the mirror claim (`claim_finished_notices/1`): the caller already TOOK those rows out of the ETS
  # mirror, so this records the same marks in the authoritative state. A job that is gone (or already announced) is a
  # no-op; the cast never replies and therefore never blocks the claiming agent. A claim is also a retention EVENT —
  # observed records accumulate here (not on the start path), so the policy runs again right after the marks.
  @impl true
  def handle_cast({:notices_claimed, _owner_pid, ids}, state) when is_list(ids) do
    state =
      Enum.reduce(ids, state, fn id, acc ->
        case Map.fetch(acc.jobs, id) do
          {:ok, job} -> put_job(acc, Notice.mark_announced(job))
          :error -> acc
        end
      end)

    {:noreply, Retention.prune(state)}
  end

  def handle_cast(_message, state), do: {:noreply, state}

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
        state = drop_probe(state, job.id)
        {:noreply, put_job(state, mark_finished(job, code)) |> forget_unknown(job.id)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:reconcile_tick, state) do
    state = %{state | tick_timer: nil}

    # Applies only what the off-process probe already OBSERVED (its cached result) and kicks ONE new probe per live
    # `:unit` job — this handler never forks `systemctl` itself.
    state =
      Enum.reduce(state.jobs, state, fn {_id, job}, acc ->
        if Notice.live?(job) and StatusProbe.offprocess?(job.handle) do
          {job, acc} = reconcile_job(job, acc)
          acc = maybe_start_probe(acc, job)
          put_job(acc, job)
        else
          acc
        end
      end)

    {:noreply, arm_tick(state)}
  end

  # The off-process status probe's answer (`StatusProbe.start/2`). A result for a job that is gone or already terminal
  # is ignored; otherwise it is CACHED (probe done, timestamped) and applied through the SAME transition logic a cached
  # read uses — so a probe that reports an exit settles the job, and with it the process-registry execution, through the
  # ONE `put_job/2` funnel.
  def handle_info({:probe_result, job_id, result}, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} when is_map(job) ->
        if Notice.terminal?(job) do
          {:noreply, drop_probe(state, job_id)}
        else
          state = put_probe(state, job_id, %{result: result, at: now_ms(), in_flight: false})
          {job, state} = reconcile_job(job, state)
          state = maybe_start_probe(state, job)
          {:noreply, arm_tick(put_job(state, job))}
        end

      _missing ->
        {:noreply, drop_probe(state, job_id)}
    end
  end

  # The load-bearing lifetime guarantee: one monitor per OWNER (agent) pid. Every way an agent can end funnels through this single `:DOWN` — normal completion, crash, graceful cancel, force kill.
  # The dead owner's jobs are found by their `owner_pid` field: retention never removes a LIVE record, so the job map IS the complete live set (the owner bookkeeping stays one monitor ref, with no id list to grow).
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.fetch(state.owners, pid) do
      {:ok, %{ref: ^ref}} ->
        state = %{state | owners: Map.delete(state.owners, pid)}

        state =
          Enum.reduce(state.jobs, state, fn {_id, job}, acc ->
            if job.owner_pid == pid and Notice.live?(job) do
              case stop_job(job, :owner_exited, :owner_died) do
                {:ok, job} ->
                  put_job(acc, job)

                {:error, message} ->
                  Logger.warning(
                    "BackgroundJobs: killing #{job.id} after owner #{inspect(pid)} exit failed: #{message}"
                  )

                  acc
              end
            else
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
      if Notice.live?(job) do
        kill_detached(job.handle)
        release_permit(Map.get(job, :tool_permit))
        settle_shutdown(state, job)
      end
    end)

    # The mirror table dies with this process anyway; clearing it is tidiness (and keeps a same-named successor from
    # ever seeing a stale row in the window before it recreates the table).
    NoticeMirror.clear(state.notice_table)

    :ok
  end

  # The registry is going away, so every job it was holding a live process for
  # is being killed right here: settle its execution TERMINALLY (never leave a
  # ghost `:running` record behind). Bounded by the manager's own call timeout,
  # and total — a manager that already terminated answers nothing and the job
  # record is gone with this process anyway.
  defp settle_shutdown(state, job) do
    if is_binary(Map.get(job, :execution_id)) do
      safe_finish(state.process_manager, Map.get(job, :execution_id), :killed,
        reason: {:killed_by, :registry_shutdown},
        exit_code: nil
      )
    end

    :ok
  end

  ## Start path

  # Shared by the public `:start_job` call and the `start_job_with_handle/2`
  # test seam, so both go through the SAME cap check, start path and tick arming.
  defp handle_start(spec, handle_override, state) do
    case permit_call(fn ->
           EvoGit.AgentScheduler.transfer_tool_permit(spec.tool_permit, self())
         end) do
      :ok ->
        result = handle_permitted_start(spec, handle_override, state)

        case result do
          {:reply, {:error, _}, updated_state} ->
            # A failed cleanup must stay counted and inspectable until reaped.
            unless Enum.any?(updated_state.jobs, fn {_id, job} ->
                     job.tool_permit == spec.tool_permit and not Notice.terminal?(job)
                   end) do
              release_permit(spec.tool_permit)
            end

          _ ->
            :ok
        end

        result

      {:error, reason} ->
        {:reply, {:error, "Background job tool permit handoff failed: #{inspect(reason)}"}, state}
    end
  end

  defp handle_permitted_start(spec, handle_override, state) do
    cond do
      not launch_valid?(spec) ->
        {:reply, {:error, launch_abandoned_error()}, state}

      live_jobs_for_owner(state.jobs, spec.owner_pid) >= @max_jobs_per_owner ->
        {:reply, {:error, limit_error()}, state}

      true ->
        case do_start_job(spec, handle_override, state) do
          {:ok, job, state} ->
            # Spawn/tracking can block past the call budget or outlive the tool
            # task. Only this acceptance point detaches from the requester.
            if launch_valid?(spec) do
              {:reply, {:ok, job}, arm_tick(Retention.prune(state))}
            else
              case stop_job(job, :launch_abandoned, {:killed_by, :launch_abandoned}) do
                {:ok, stopped} ->
                  {:reply, {:error, launch_abandoned_error()}, arm_tick(put_job(state, stopped))}

                {:error, message} ->
                  {:reply, {:error, launch_abandoned_error() <> " " <> message}, arm_tick(state)}
              end
            end

          {:error, message} ->
            {:reply, {:error, message}, state}
        end
    end
  end

  defp launch_valid?(spec) do
    Process.alive?(spec.launch_requester) and Process.alive?(spec.owner_pid) and
      System.monotonic_time(:millisecond) < spec.launch_deadline
  end

  defp launch_abandoned_error do
    "The background job launch was not accepted because its requester or owning agent ended, or its launch deadline expired."
  end

  defp do_start_job(spec, handle_override, state) do
    {id, next_id} = generate_id(state, state.next_id)
    output_path = Path.join(scratch_dir(), "genesis_job_#{id}.log")

    with :ok <- prepare_output_file(output_path),
         {:ok, handle} <-
           resolve_handle(handle_override, %{
             command: spec.command,
             cwd: spec.cwd,
             output_path: output_path,
             job_id: id
           }) do
      state = %{state | next_id: next_id}
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
          tool_permit: spec.tool_permit,
          execution_id: nil,
          status: :running,
          exit_code: nil,
          terminal_reason: nil,
          detail: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          cursor: 0,
          lines_read: 0,
          announced: false
        }
        |> track_execution(spec, state.process_manager)
        |> settle_start_exit()

      {:ok, job, put_job(state, job)}
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

  ## Process registry integration
  #
  # Every started job becomes ONE `:background_job` execution in
  # `EvoGit.ProcessManager`, so "what is this node running right now" has a single
  # answer. This happens BEFORE `settle_start_exit/1` deliberately: a job whose
  # exit is already known at spawn time must still leave a TERMINAL execution
  # record instead of none.

  defp track_execution(job, spec, manager) do
    meta = %{
      tool: "bash",
      command: spec.command,
      label: spec.label,
      agent_id: spec.agent_id,
      task_id: spec.task_id,
      owner_pid: spec.owner_pid,
      cwd: spec.cwd,
      repo_root: spec.repo_root,
      backend: backend_atom(job.handle),
      runtime: :background,
      job_id: job.id
    }

    case safe_track(manager, meta) do
      {:ok, execution_id} when is_binary(execution_id) ->
        safe_attach(manager, execution_id, job.handle)
        %{job | execution_id: execution_id}

      _unavailable ->
        %{job | execution_id: nil}
    end
  end

  # The execution's `backend` vocabulary (`:systemd | :bwrap | :sandbox_exec |
  # :none`) — derived from the handle's backend MODULE through the process
  # registry's ONE detection point, with `:none` as the safe fallback (an
  # unknown/absent backend must never leave the field empty).
  defp backend_atom(handle) when is_map(handle) do
    case ProcessManager.Handle.execution_backend(%ProcessManager.Handle{
           backend: Map.get(handle, :backend)
         }) do
      nil -> :none
      backend -> backend
    end
  end

  defp backend_atom(_handle), do: :none

  defp safe_track(manager, meta) do
    ProcessManager.track(:background_job, meta, server: manager)
  rescue
    exception ->
      Logger.debug(
        "BackgroundJobs: process tracking unavailable (#{Exception.message(exception)})"
      )

      {:error, :process_manager_unavailable}
  catch
    kind, reason ->
      Logger.debug("BackgroundJobs: process tracking unavailable (#{kind}: #{describe(reason)})")

      {:error, :process_manager_unavailable}
  end

  defp safe_attach(manager, execution_id, handle) do
    # `normalize_handle/1` is the ONE handle conversion point (nil = not
    # addressable, so the execution simply stays without OS addressing).
    case EvoGit.Sandbox.Background.normalize_handle(handle) do
      nil -> :ok
      normalized -> ProcessManager.attach(execution_id, normalized, server: manager)
    end
  rescue
    exception ->
      Logger.debug("BackgroundJobs: handle attach failed (#{Exception.message(exception)})")

      :ok
  catch
    kind, reason ->
      Logger.debug("BackgroundJobs: handle attach failed (#{kind}: #{describe(reason)})")
      :ok
  end

  # Total: a dead/unreachable manager is never allowed to affect job bookkeeping.
  defp safe_finish(manager, execution_id, status, opts) do
    ProcessManager.finish(execution_id, status, [{:server, manager} | opts])
  rescue
    exception ->
      Logger.debug("BackgroundJobs: process finish failed (#{Exception.message(exception)})")
      :ok
  catch
    kind, reason ->
      Logger.debug("BackgroundJobs: process finish failed (#{kind}: #{describe(reason)})")
      :ok
  end

  # Output destination is decided ONCE, at spawn time, and stored on the job: a detached process has no process dictionary to re-derive it from later.
  defp scratch_dir do
    EvoGit.Sandbox.resolve_tmpdir()
  end

  # Non-bang on purpose: a permission problem must surface as prose, never as a crash of the shared registry.
  # The file is CREATED/TRUNCATED to empty (never merely `touch`ed): ids are short
  # and sequential, so a reused id in a reused scratch dir (the system tmpdir when
  # no per-task tmpdir is installed) would otherwise leak a previous job's output
  # into this job's reads.
  defp prepare_output_file(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, "") do
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

  # Returns the next FREE id and the counter value that follows it. The counter is
  # monotonic per registry, so ids read `bash-1`, `bash-2`, … in start order; a
  # candidate still present in `jobs` OR kept as a TOMBSTONE is skipped, because an
  # id is never reused while ANY answer for it exists (a pruned id must not come
  # back as a DIFFERENT job and silently reset an agent's cursor), and the same
  # loop finds a free id even if the counter starts at 0.
  defp generate_id(state, counter) do
    candidate = @id_prefix <> Integer.to_string(counter)

    if Map.has_key?(state.jobs, candidate) or
         Map.has_key?(Map.get(state, :tombstones, %{}), candidate) do
      generate_id(state, counter + 1)
    else
      {candidate, counter + 1}
    end
  end

  ## Owner monitor bookkeeping

  # ONE `Process.monitor/1` per owner, kept as `%{ref: ref}`: the monitor ref is the only fact the `:DOWN` handler needs (the dead owner's jobs are found by their `owner_pid`), so a long-lived owner costs ONE bounded entry no matter how many jobs it starts.
  defp ensure_owner_monitor(state, owner_pid) do
    case Map.fetch(state.owners, owner_pid) do
      {:ok, %{ref: ref}} ->
        {ref, state}

      :error ->
        ref = Process.monitor(owner_pid)
        {ref, %{state | owners: Map.put(state.owners, owner_pid, %{ref: ref})}}
    end
  end

  defp live_jobs_for_owner(jobs, owner_pid) do
    Enum.count(jobs, fn {_id, job} -> job.owner_pid == owner_pid and Notice.live?(job) end)
  end

  defp filter_by_owner(jobs, nil), do: jobs
  defp filter_by_owner(jobs, owner_pid), do: Enum.filter(jobs, &(&1.owner_pid == owner_pid))

  # The ONE lookup all four id-addressed handlers share: the authoritative `jobs` map first, then
  # the TOMBSTONES (a record that left retention but whose id must still answer), each behind the
  # same ownership fence. An id in NEITHER is the only `:not_found`.
  defp fetch_owned_record(state, id, owner_pid) do
    case Map.fetch(state.jobs, id) do
      {:ok, job} ->
        check_owner(job, owner_pid, {:job, job})

      :error ->
        case Retention.fetch_tombstone(state, id) do
          {:ok, tombstone} -> check_owner(tombstone, owner_pid, {:tombstone, tombstone})
          :error -> {:error, :not_found}
        end
    end
  end

  defp check_owner(_record, nil, tagged), do: {:ok, tagged}
  defp check_owner(%{owner_pid: owner_pid}, owner_pid, tagged), do: {:ok, tagged}
  defp check_owner(_record, _owner_pid, _tagged), do: {:error, :not_owner}

  ## Status reconciliation

  # Reconciles a LIVE job against the backend so a finished job reports finished with no notification, and kicks the next
  # OFF-PROCESS probe for a job whose backend status costs a subprocess. Terminal jobs are returned untouched.
  defp reconcile(job, state) do
    {job, state} = reconcile_job(job, state)
    state = maybe_start_probe(state, job)
    {job, put_job(state, job)}
  end

  defp reconcile_job(job, state) do
    cond do
      not Notice.live?(job) ->
        # Terminal: nothing to probe, and its cached result (if any) is dead weight.
        {job, state |> forget_unknown(job.id) |> drop_probe(job.id)}

      StatusProbe.offprocess?(job.handle) ->
        # A `:unit` probe forks `systemctl`, so it NEVER runs in this process: apply only what an already-finished
        # probe OBSERVED, and let `maybe_start_probe/2` schedule the next one. With no cached result the job simply
        # keeps its last known status — an invented "finished" would be worse than a late one.
        apply_cached_probe(job, state)

      true ->
        # A `:port` handle's probe is `Port.info/2` — a cheap in-VM BIF, so it stays synchronous.
        case StatusProbe.run(job.handle) do
          {:running, _} -> {job, forget_unknown(state, job.id)}
          {:exited, code} -> {mark_finished(job, code), forget_unknown(state, job.id)}
          {:unknown, _} -> settle_unknown(job, state)
          _other -> {job, state}
        end
    end
  end

  # Applies the registry's CACHED probe result for a live `:unit` job — the ONLY status this path may report, because
  # it is the only one actually observed.
  defp apply_cached_probe(job, state) do
    case Map.get(state.probes, job.id) do
      %{result: {:running, _}} ->
        {job, forget_unknown(state, job.id)}

      %{result: {:exited, code}} ->
        {mark_finished(job, code), state |> forget_unknown(job.id) |> drop_probe(job.id)}

      %{result: {:unknown, _}} ->
        settle_unknown(job, state)

      # No probe has answered yet (or it answered something unexpected): keep the last known status.
      _pending_or_other ->
        {job, state}
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

  # Test-only CALL-TIME override (`:background_probe_min_interval_ms`); the
  # production default `@probe_min_interval_ms` is unchanged. Read per decision so
  # a suite can widen or narrow the probe cadence without touching attributes.
  defp probe_min_interval_ms do
    case Application.get_env(:evo_git, :background_probe_min_interval_ms, @probe_min_interval_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> @probe_min_interval_ms
    end
  end

  ## Off-process status probes

  # Starts the next probe for a LIVE `:unit` job when none is in flight and the cached result is old enough. Bounded by
  # construction: never linked, never awaited, ONE task per decision, and at most one in flight per job.
  defp maybe_start_probe(state, job) do
    entry = Map.get(state.probes, job.id)

    cond do
      not Notice.live?(job) ->
        state

      not StatusProbe.offprocess?(job.handle) ->
        state

      is_nil(entry) ->
        start_probe(state, job, nil)

      Map.get(entry, :in_flight, false) ->
        state

      now_ms() - Map.get(entry, :at, 0) >= probe_min_interval_ms() ->
        start_probe(state, job, entry)

      true ->
        state
    end
  end

  defp start_probe(state, job, entry) do
    # The previous result is KEPT while the new probe runs, so a read in that window still answers from observation
    # instead of forgetting what the backend last said.
    previous = if is_nil(entry), do: nil, else: Map.get(entry, :result)
    started = StatusProbe.start(self(), job)

    if match?({:ok, _pid}, started) do
      put_probe(state, job.id, %{result: previous, at: now_ms(), in_flight: true})
    else
      # No probe is running, so `in_flight` stays false — otherwise this job could never be probed again.
      Logger.debug(
        "BackgroundJobs: could not start a status probe for #{job.id}: #{inspect(started)}"
      )

      state
    end
  end

  defp put_probe(state, id, entry), do: %{state | probes: Map.put(state.probes, id, entry)}

  defp drop_probe(state, id) do
    if Map.has_key?(state.probes, id) do
      %{state | probes: Map.delete(state.probes, id)}
    else
      state
    end
  end

  # One clock read for the probe throttles, delegated to the shared monotonic
  # clock so the millisecond source has exactly one definition.
  defp now_ms, do: EvoGit.Util.Time.now_ms()

  # Test-only CALL-TIME override (`:background_wait_default_ms`); the production
  # default `@wait_default_ms` is unchanged. Read on EVERY call (`wait_default_ms/0`)
  # by `EvoGit.Agent.Tools.JobOutput`'s `wait: true` loop, so a suite can pin the
  # default-budget path without sleeping the documented 120 s.
  defp resolved_wait_default_ms do
    case Application.get_env(:evo_git, :background_wait_default_ms, @wait_default_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> @wait_default_ms
    end
  end

  # Test-only CALL-TIME override (`:background_wait_max_ms`), honoured only for a
  # POSITIVE integer; a nil / string / float / non-positive value falls through to
  # the derivation. Read on EVERY call (`wait_max_ms/0`) so a suite can shrink the
  # cap instead of sleeping minutes, and so no value is ever frozen at compile
  # time (a compile-time read would also re-read config inside an attribute).
  defp resolved_wait_max_ms do
    case Application.get_env(:evo_git, :background_wait_max_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _other -> derived_wait_max_ms()
    end
  end

  # The scheduler's tool ceiling is the single source of truth for how long a tool
  # call may block; the wait cap is that ceiling MINUS the dispatcher's own
  # headroom (which `EvoGit.Agent.Tools.default_timeout_ms/1` adds back, so a
  # full-length wait expires just before the dispatcher would kill the call).
  # `Config.resolve/1` is read at CALL time — never cached here — so a config
  # reload is honoured by the next wait.
  defp derived_wait_max_ms do
    ceiling =
      case EvoGit.Config.resolve([:scheduler, :max_tool_timeout]) do
        ms when is_integer(ms) and ms > 0 -> ms
        _other -> @wait_max_fallback_ms
      end

    max(@wait_max_floor_ms, ceiling - @dispatch_headroom_ms)
  end

  # Test-only CALL-TIME override (`:background_poll_interval_ms`); the production
  # default `@poll_interval_ms` is unchanged. Read on EVERY sleep of a caller-side
  # `wait: true` loop (`EvoGit.Agent.Tools.JobOutput`), so a suite can shorten the
  # poll cadence without redefining the documented production interval.
  defp resolved_poll_interval_ms do
    case Application.get_env(:evo_git, :background_poll_interval_ms, @poll_interval_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> @poll_interval_ms
    end
  end

  # Test-only CALL-TIME override (`:background_tick_interval_ms`); the production
  # default `@tick_interval_ms` is unchanged. Read per timer arm so a test module
  # can shorten the periodic tick without touching module attributes.
  defp resolved_tick_interval_ms do
    case Application.get_env(:evo_git, :background_tick_interval_ms, @tick_interval_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> @tick_interval_ms
    end
  end

  # Only a `:unit` handle with an OPEN observer port (or a `:port` handle whose
  # child still lives) can still deliver a real exit status — everything else is
  # unreportable and eligible for the floor.
  defp observer_alive?(%{kind: :port, port: port}), do: port_open?(port)
  defp observer_alive?(%{kind: :unit, port: port}), do: port_open?(port)
  defp observer_alive?(_handle), do: false

  # A live port answers a list of info terms; a CLOSED port answers `nil` and does NOT raise, so the
  # `nil` clause is the normal closed-port path. Deliberately NO `rescue`: an unexpected raise here must
  # surface, because swallowing it would silently mean "observer dead" and let the `@unknown_grace_ms`
  # floor settle a job whose observer may still be alive.
  @doc false
  # TEST SEAM — `@doc false` public so a suite can pin the observer probe's totality (a non-port value
  # and a closed port both answer `false`) without reaching into the GenServer's private helpers.
  @spec port_open?(term()) :: boolean()
  def port_open?(port) when is_port(port) do
    case Port.info(port) do
      nil -> false
      info when is_list(info) -> true
    end
  end

  def port_open?(_port), do: false

  defp forget_unknown(%{unknown_since: %{} = unknown_since} = state, id) do
    %{state | unknown_since: Map.delete(unknown_since, id)}
  end

  defp forget_unknown(state, _id), do: state

  # The backend status probe lives in `EvoGit.BackgroundJobs.StatusProbe` (total, call-time test seam, and — for a
  # `:unit` handle — run OFF this process). Only `kill_detached/1` below still shells out from here, bounded, because a
  # kill is an explicit request rather than a status poll.
  defp kill_detached(handle) do
    EvoGit.Sandbox.kill_detached(handle)
  rescue
    exception ->
      {:error, Exception.message(exception)}
  catch
    kind, reason ->
      {:error, "#{kind}: #{describe(reason)}"}
  end

  # `terminal_reason` is the EXECUTION-level cause this stop implies (`:owner_died`, or
  # `{:killed_by, actor}` for a requested kill); the job's own `:detail` prose stays human-facing.
  defp stop_job(job, reason, terminal_reason) do
    case kill_detached(job.handle) do
      :ok ->
        {:ok,
         %{
           job
           | status: :killed,
             detail: "killed (#{kill_reason(reason)})",
             terminal_reason: terminal_reason,
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
  # The execution-level cause is ALWAYS `:exited` for an observed exit status —
  # the execution is `:completed` even for a non-zero code (the JOB record stays
  # `:failed`); only a stop requested in flight turns the exit into a kill.
  defp mark_finished(%{status: :stopping} = job, code) do
    %{
      job
      | status: :killed,
        exit_code: code,
        detail: "killed (stop requested)",
        terminal_reason: Map.get(job, :terminal_reason) || {:killed_by, :operator},
        finished_at: DateTime.utc_now()
    }
  end

  defp mark_finished(job, 0) do
    %{
      job
      | status: :completed,
        exit_code: 0,
        detail: "exit code: 0",
        terminal_reason: :exited,
        finished_at: DateTime.utc_now()
    }
  end

  defp mark_finished(job, code) when is_integer(code) do
    %{
      job
      | status: :failed,
        exit_code: code,
        detail: "exit code: #{code}",
        terminal_reason: :exited,
        finished_at: DateTime.utc_now()
    }
  end

  defp mark_finished(job, _code) do
    %{
      job
      | status: :failed,
        exit_code: nil,
        detail: "exit status unknown (the detached process ended without a readable exit code)",
        terminal_reason: :exited,
        finished_at: DateTime.utc_now()
    }
  end

  ## Output reading

  # A tombstoned record's log file usually SURVIVES the record (retention drops the map entry, not the
  # file), so the read serves the same delta shape from its saved cursor and persists the advance into
  # `state.tombstones`. When the log is gone the answer is HONEST prose about retention — never the
  # "unknown id" sentence, because this id was genuinely issued to this agent.
  defp handle_tombstone_read(tombstone, max_bytes, state) do
    case read_delta(tombstone, max_bytes) do
      {:ok, text, tombstone} ->
        {:reply, {:ok, %{text: text, job: tombstone}},
         Retention.update_tombstone(state, tombstone)}

      {:error, _message} ->
        {:reply, {:error, tombstone_output_error(tombstone)}, state}
    end
  end

  defp tombstone_output_error(tombstone) do
    "The background job #{inspect(tombstone.id)} aged out of the background-job retention window, so its " <>
      "output log is no longer readable at #{tombstone.output_path}. Its final status is still on file: " <>
      "#{tombstone_status(tombstone)}. Start a new background job if you need the command's output again."
  end

  # The one-line final outcome a retention prose answer can still state: the public status vocabulary,
  # plus the exit code when the record carried one (omitted when it was never known).
  defp tombstone_status(tombstone) do
    status = status_string(Map.get(tombstone, :status)) || "unknown"

    case Map.get(tombstone, :exit_code) do
      code when is_integer(code) -> "status #{status}, exit code: #{code}"
      _other -> "status #{status}"
    end
  end

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

  # Armed while at least one live job needs the periodic reconcile — i.e. an OFF-PROCESS probed (`:unit`) job, whose
  # backend status costs a subprocess and therefore cannot be polled on demand.
  defp arm_tick(%{tick_timer: nil} = state) do
    if Enum.any?(state.jobs, fn {_id, job} ->
         Notice.live?(job) and StatusProbe.offprocess?(job.handle)
       end) do
      %{
        state
        | tick_timer: Process.send_after(self(), :reconcile_tick, resolved_tick_interval_ms())
      }
    else
      state
    end
  end

  defp arm_tick(state), do: state

  ## Records / helpers

  # The single state writer — and therefore the ONE terminal funnel for the
  # process registry: a job that becomes terminal here settles its
  # `:background_job` execution exactly once (a re-put of an already-terminal
  # record, e.g. marking it `announced`, is a no-op). `EvoGit.ProcessManager.finish/3`
  # is idempotent too, so a double settle could never hurt — this guard only
  # avoids pointless calls. A job killed only through the manager settles here
  # as well, because the manager routes a `:background_job` kill to `kill/3`.
  # It is ALSO the ONE notice-mirror writer: every transition passes through here,
  # so the ETS mirror can never drift from the authoritative map (a terminal,
  # unannounced job is inserted; anything else deletes its row).
  defp put_job(state, job) do
    previous = Map.get(state.jobs, job.id)

    if not Notice.live?(job) and (is_nil(previous) or Notice.live?(previous)) do
      release_permit(Map.get(job, :tool_permit))
    end

    settle_execution(state, previous, job)
    NoticeMirror.put(state.notice_table, job)
    %{state | jobs: Map.put(state.jobs, job.id, job)}
  end

  defp settle_execution(state, previous, job) do
    execution_id = Map.get(job, :execution_id)
    status = Map.get(job, :status)

    if is_binary(execution_id) and status in [:completed, :failed, :killed] and
         not match?(%{status: ^status}, previous) do
      reason = settle_reason(job)

      # The EXECUTION status is derived from the terminal cause, never copied from
      # the job status: an observed non-zero exit settles `:completed` (with the
      # real `:exit_code`) while the job record itself stays `:failed`.
      safe_finish(
        state.process_manager,
        execution_id,
        ProcessManager.Execution.status_for_reason(reason),
        exit_code: Map.get(job, :exit_code),
        reason: reason
      )
    end

    :ok
  end

  # The execution-level terminal cause recorded by the ONE transition that made
  # the job terminal. The fallback is unreachable in practice (every terminal
  # transition sets the field) but keeps this reader total.
  defp settle_reason(job) do
    case Map.get(job, :terminal_reason) do
      nil -> fallback_settle_reason(job)
      reason -> reason
    end
  end

  defp fallback_settle_reason(%{status: :completed}), do: :exited
  defp fallback_settle_reason(%{status: :killed}), do: {:killed_by, :operator}

  defp fallback_settle_reason(job), do: {:crashed, Map.get(job, :detail)}

  # OUTPUT routing: only a `:port` handle's chunks are the job's own output.
  defp find_live_job_by_port(jobs, port) do
    Enum.find_value(jobs, :error, fn {_id, job} ->
      if Notice.live?(job) and match?(%{kind: :port, port: ^port}, job.handle) do
        {:ok, job}
      end
    end)
  end

  # EXIT routing: BOTH handle shapes carry a port that reports the job's exit —
  # a `:port` handle's own child and a `:unit` handle's `systemd-run --wait`
  # observer client.
  defp find_live_job_by_observer_port(jobs, port) do
    Enum.find_value(jobs, :error, fn {_id, job} ->
      if Notice.live?(job) and match?(%{port: ^port}, job.handle) do
        {:ok, job}
      end
    end)
  end

  # Deterministic newest-first ordering for the state-only reads: two jobs started in the same microsecond would
  # otherwise come back in arbitrary map-iteration order. ONE implementation, shared with the mirror's claim, so a
  # claimed batch and a `snapshot/1` can never disagree.
  defp sort_newest_first_with_id(jobs), do: NoticeMirror.sort_newest_first_with_id(jobs)

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
