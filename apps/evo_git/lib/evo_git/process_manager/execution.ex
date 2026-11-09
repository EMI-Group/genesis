defmodule EvoGit.ProcessManager.Execution do
  @moduledoc """
  One tracked live OS execution — the record `EvoGit.ProcessManager` is the
  single source of truth for.

  An execution is either a **tool call** (`kind: :tool_call`: a foreground shell
  command an agent is blocked on) or a **background job**
  (`kind: :background_job`: a detached job owned by `EvoGit.BackgroundJobs`).
  Both are "live OS work an agent/task holds", which is why one struct models
  both: phase 2's dashboard, the agent tree and any operator action (pause,
  signal, kill) all read THIS shape and never the backend-specific maps.

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
    * `:backend` — `:systemd | :bwrap | :sandbox_exec | :none`: which sandbox
      backend anchors it.
    * `:runtime` — `:foreground` (the agent is blocked on it) or `:detached`
      (it outlives the turn).
    * `:status` — see the lifecycle above.
    * `:os_pid` / `:unit` — the OS identity, filled by `attach/3`.
    * `:job_id` — the `EvoGit.BackgroundJobs` job id, for `:background_job`.
    * `:exit_code` / `:reason` — the terminal facts, filled by `finish/3`.
    * `:inserted_at` / `:started_at` / `:ended_at` — the timeline.
    * `:stats` — the LAST stats map (ALWAYS a map, see
      `EvoGit.ProcessManager.Stats`), never nil.
    * `:control_log` — every accepted control action, oldest first.
  """

  alias EvoGit.ProcessManager.Stats

  @type kind :: :tool_call | :background_job
  @type status :: :starting | :running | :paused | :completed | :failed | :killed | :unknown
  @type runtime :: :foreground | :detached
  @type backend :: :systemd | :bwrap | :sandbox_exec | :none

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

  @doc "The statuses the sampling timer probes."
  @spec live_statuses() :: [status()]
  def live_statuses, do: [:running, :paused]

  @doc "Whether a status is live (probed by the sampling timer)."
  @spec live?(status() | nil) :: boolean()
  def live?(status), do: status in live_statuses()

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
end
