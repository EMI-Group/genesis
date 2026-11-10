defmodule EvoGit.ProcessManager.Execution do
  @moduledoc """
  One tracked live OS execution — the record `EvoGit.ProcessManager` is the
  single source of truth for.

  An execution is either a **tool call** (`kind: :tool_call`: a call an agent is
  blocked on — a shell command, or a BEAM-local built-in such as `read`) or a
  **background job** (`kind: :background_job`: a detached job owned by
  `EvoGit.BackgroundJobs`).
  Both are "work an agent/task holds", which is why one struct models both: the
  dashboard, the agent tree and any operator action (pause, signal, kill) all
  read THIS shape and never the backend-specific maps.

  ## Origin (`:runtime`) vs backend (`:backend`)

  `:runtime` answers WHERE the call sits relative to the agent's turn, never
  what runs it: `:foreground` (the agent is blocked on it) or `:background`
  (the call outlives the turn, i.e. a `EvoGit.BackgroundJobs` job).

  `:backend` answers WHAT runs it: `:builtin` means the call ran INSIDE the BEAM
  (a built-in tool — `read`/`write`/`edit`/`rg`/`search_*`/`elixir_eval`/
  `job_output` — anything that is not the platform shell), so such an execution
  has NO OS process: no `:os_pid`, no `:unit`, no uptime and no CPU/memory
  stats (`:stats` stays `EvoGit.ProcessManager.Stats.empty/0`).
  `:systemd | :bwrap | :sandbox_exec | :none` mean an EXTERNAL OS process
  anchored by that sandbox backend (`:none` is external but unsandboxed).

  ## Terminal facts (`:exit_code` + `:reason`)

  `:exit_code` is an integer `0..255` when an external execution's OS process
  actually exited; it is `nil` for timeouts, kills, builtin calls and
  never-started calls.

  `:reason` is the ONE terminal cause and stays `nil` while the execution is
  live: `:exited` (the process ended on its own — consult `:exit_code`),
  `:timeout`, `:invalid_arguments` (never started: unparseable/malformed tool
  arguments), `:owner_died`, `{:killed_by, actor}`, `{:crashed, detail}`,
  `:no_os_process` (a builtin call finished; nothing ran) or the additive
  `{:tool_error, reason}` (a tool-returned `{:error, reason}`, not a
  raise/exit). `status_for_reason/1` is the uniform status mapping.

  ## Lifecycle

      :starting ──attach/3──▶ :running ──pause/2──▶ :paused
                                 ▲   │                 │
                                 └───┴── resume/2 ◀─────┘
                                 │
                                 ├── finish/3 ──▶ :completed | :failed | :killed
                                 └── signal/3 (:term/:kill) ──▶ the OS ends it;
                                     the caller records :failed/:completed

  `:unknown` exists for the degraded case where the registry can no longer
  observe the OS state (an unobservable handle on a backend that reports
  nothing); it is never produced by a successful probe.

  ## Fields (FROZEN — phase 2 and later rounds depend on these names)

    * `:id` — `"proc-<n>"`, monotonically increasing per registry instance.
    * `:kind` — `:tool_call | :background_job`.
    * `:tool` — the model-facing tool name (`"bash"`, `"job_output"`, …) or nil.
    * `:command` — the shell command line, or nil when unknown.
    * `:label` — a short human label for the dashboard.
    * `:agent_id` / `:task_id` — the owning agent and task identities (opaque:
      integers, strings or nil).
    * `:owner_pid` — the pid whose death kills this execution.
    * `:cwd` / `:repo_root` — where it runs (context for a human).
    * `:backend` — `:builtin | :systemd | :bwrap | :sandbox_exec | :none`:
      `:builtin` runs inside the BEAM (no OS process), the rest anchor an
      external OS process.
    * `:runtime` — `:foreground` (the agent is blocked on it) or `:background`
      (it outlives the turn).
    * `:status` — see the lifecycle above.
    * `:os_pid` / `:unit` — the OS identity, filled by `attach/3` (always nil
      for a builtin execution).
    * `:job_id` — the `EvoGit.BackgroundJobs` job id, for `:background_job`.
    * `:exit_code` / `:reason` — the terminal facts, filled by `finish/3` (see
      "Terminal facts" above).
    * `:inserted_at` / `:started_at` / `:ended_at` — the timeline.
    * `:stats` — the LAST stats map (ALWAYS a map, see
      `EvoGit.ProcessManager.Stats`), never nil.
    * `:control_log` — every accepted control action, oldest first.
  """

  alias EvoGit.ProcessManager.Stats

  @type kind :: :tool_call | :background_job
  @type status :: :starting | :running | :paused | :completed | :failed | :killed | :unknown
  @type runtime :: :foreground | :background
  @type backend :: :builtin | :systemd | :bwrap | :sandbox_exec | :none

  @type control_entry :: %{
          action: atom(),
          signal: String.t() | nil,
          reason: term(),
          actor: term(),
          at: DateTime.t()
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          kind: kind() | nil,
          tool: String.t() | nil,
          command: String.t() | nil,
          label: String.t() | nil,
          agent_id: term(),
          task_id: term(),
          owner_pid: pid() | nil,
          cwd: String.t() | nil,
          repo_root: String.t() | nil,
          backend: backend(),
          runtime: runtime(),
          status: status(),
          os_pid: integer() | nil,
          unit: String.t() | nil,
          job_id: String.t() | nil,
          exit_code: integer() | nil,
          reason: term(),
          inserted_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          stats: Stats.t(),
          control_log: [control_entry()]
        }

  defstruct id: nil,
            kind: nil,
            tool: nil,
            command: nil,
            label: nil,
            agent_id: nil,
            task_id: nil,
            owner_pid: nil,
            cwd: nil,
            repo_root: nil,
            backend: :none,
            runtime: :foreground,
            status: :starting,
            os_pid: nil,
            unit: nil,
            job_id: nil,
            exit_code: nil,
            reason: nil,
            inserted_at: nil,
            started_at: nil,
            ended_at: nil,
            stats: Stats.empty(),
            control_log: []

  @doc "The terminal statuses — a record in one of these never changes again."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: [:completed, :failed, :killed]

  @doc "Whether a status is terminal."
  @spec terminal?(status() | nil) :: boolean()
  def terminal?(status), do: status in terminal_statuses()

  @doc "The statuses the sampling timer probes (see `sampleable?/1`)."
  @spec live_statuses() :: [status()]
  def live_statuses, do: [:running, :paused]

  @doc "Whether a status is live (`:running` or `:paused`)."
  @spec live?(status() | nil) :: boolean()
  def live?(status), do: status in live_statuses()

  @doc """
  Whether this execution ran INSIDE the BEAM (`backend: :builtin`).

  Total: only a `%Execution{backend: :builtin}` answers `true`; any other term
  (including nil and a non-struct) answers `false`.
  """
  @spec builtin?(term()) :: boolean()
  def builtin?(%__MODULE__{backend: :builtin}), do: true
  def builtin?(_execution), do: false

  @doc """
  Whether this execution is an EXTERNAL OS process (`not builtin?/1`).

  Total: `true` for every term that is not a `%Execution{backend: :builtin}`.
  """
  @spec external?(term()) :: boolean()
  def external?(execution), do: not builtin?(execution)

  @doc """
  Whether the sampling timer probes this execution: live (`live?/1`) AND
  external (`external?/1`).

  A live builtin record is never probeable — it has no OS process — so it never
  arms the sampling timer and never contributes to `sample_all/1`. Total.
  """
  @spec sampleable?(term()) :: boolean()
  def sampleable?(execution), do: external?(execution) and live?(status_of(execution))

  @doc """
  The uniform terminal-status mapping for a terminal `:reason`.

  `:exited` and `:no_os_process` → `:completed` — and `:completed` ALSO covers a
  NON-ZERO `:exit_code`: the tool call itself succeeded and the model receives a
  normal result (the dashboard colors the code).
  `:timeout` and `{:killed_by, _}` → `:killed`; `:invalid_arguments`,
  `{:crashed, _}`, `:owner_died`, `{:tool_error, _}` and any other term →
  `:failed`. Total.
  """
  @spec status_for_reason(term()) :: status()
  def status_for_reason(:exited), do: :completed
  def status_for_reason(:no_os_process), do: :completed
  def status_for_reason(:timeout), do: :killed
  def status_for_reason({:killed_by, _actor}), do: :killed
  def status_for_reason(_reason), do: :failed

  @doc """
  The empty control-log entry shape (`EvoGit.ProcessManager.Control` fills it).
  """
  @spec control_entry(keyword() | map()) :: control_entry()
  def control_entry(attrs \\ []) do
    attrs = Map.new(attrs)

    %{
      action: Map.get(attrs, :action, :signal),
      signal: Map.get(attrs, :signal),
      reason: Map.get(attrs, :reason),
      actor: Map.get(attrs, :actor),
      at: Map.get(attrs, :at) || DateTime.utc_now()
    }
  end

  defp status_of(%__MODULE__{status: status}), do: status
  defp status_of(_execution), do: nil
end
