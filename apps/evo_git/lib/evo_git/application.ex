defmodule EvoGit.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # Compile-time Mix env — safe in releases (Mix.env/0 is evaluated at compile
  # time; in prod releases it resolves to :prod). Used to skip boot-time
  # distribution enabling in the test environment, where a developer's real
  # [node] enabled = true config would otherwise attempt to start
  # :net_kernel/EPMD on a non-distributed BEAM.
  @mix_env Mix.env()

  @impl true
  def start(_type, _args) do
    # Create ETS tables owned by the application process so they survive
    # AgentScheduler crashes/restarts. If a table already exists (e.g., on
    # application restart after a soft crash), creation is a no-op.
    ensure_ets_table(:evogit_agent_state, [:named_table, :public, :set, read_concurrency: true])
    ensure_ets_table(:evogit_sched_meta, [:named_table, :public, :set, read_concurrency: true])

    # Graceful-cancel marker: task_ids currently in a graceful cancel. The
    # scheduler registers task_ids here via begin_graceful_cancel/1; run_agent
    # refuses new root agents for members and Dispatch.register_agent puts
    # newly registered agents into cancel-grace. TaskRegistry clears entries
    # when the task reaches a terminal state. Read via :ets.member by the
    # scheduler handlers (same process) and by Dispatch/TaskRegistry.
    ensure_ets_table(:evogit_cancelling_tasks, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    # Archive records keyed by {task_id, agent_id} — at most one record per
    # agent per task, so re-writes (e.g. crash-retry double completion) are
    # idempotent overwrites.
    ensure_ets_table(:evogit_archive_records, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    # Persistent per-repo worktree-init marker: repo_root => init timestamp.
    # Written once the destructive per-repo init (rm_rf workers dir + orphaned
    # evogit-agent-* branch cleanup + git worktree prune) has run. App-owned so
    # it SURVIVES WorktreeManager restarts — a manager-only restart must NOT
    # re-wipe the worktrees of still-running agents (that was a production
    # crash cascade). It dies with the app, so a genuine BEAM restart (no live
    # agents) re-runs the full wipe, which is correct. Read/written
    # defensively via :ets.whereis by the WorktreeManager (same pattern as
    # :evogit_cancelling_tasks).
    ensure_ets_table(:evogit_worktree_repos, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    # Enable distributed Erlang at startup if configured.
    # This must happen before starting RemoteConnection-related children,
    # since RemoteConnection needs the local node in distributed mode to
    # connect to remote nodes via SSH tunnels.
    #
    # Skipped in the test env: a developer's real [node] enabled = true config
    # would make this attempt to start :net_kernel/EPMD, which fails with
    # :nodistribution on a non-distributed BEAM and logs a spurious warning at
    # app boot (before ExUnit starts, so it cannot be captured test-side).
    # Tests that need distribution start it on demand via enable_for_remote/1.
    if @mix_env != :test do
      EvoGit.Distribution.maybe_enable()
    end

    # Use the IANA tz database (bundled with the tz dep) as Elixir's global
    # time zone database so per-profile peak-hour `timezone` fields (IANA
    # names) resolve correctly. tz pre-compiles the IANA time zone data into
    # the dependency at build time and enables no auto-update/updater
    # process, so configuring the database causes no network I/O at boot.
    # It ships with every release automatically as a dep of :evo_git.
    Calendar.put_time_zone_database(Tz.TimeZoneDatabase)

    children = [
      {Phoenix.PubSub, name: EvoGit.PubSub},
      # PubSub broadcast throttle (coalesces rapid agent-update signals)
      {EvoGit.AgentScheduler.PubSub.Throttle, []},
      # Human-in-the-loop approval gate for the self-reflective agent's command
      # shell (level-2/3 commands). Starts AFTER EvoGit.PubSub — it subscribes
      # to the "tasks" topic in init to auto-deny pending approvals when the
      # owning task is cancelled/reaches a terminal state.
      {EvoGit.CommandApproval, []},
      {Registry, keys: :unique, name: EvoGit.RemoteConnection.Registry},
      {DynamicSupervisor, name: EvoGit.RemoteConnection.Supervisor, strategy: :one_for_one},
      {EvoGit.Store,
       data_dir:
         Path.join(
           Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir()),
           "tasks.sqlite"
         )},
      {Registry,
       keys: :unique,
       name: EvoGit.TaskRegistry.ProcessRegistry,
       id: :task_registry_process_registry},
      {EvoGit.TaskRegistry, []},
      {EvoGit.AgentScheduler.WorktreeManager, []},
      {EvoGit.AgentGroupSupervisor, []},
      # Peak-hour LLM concurrency engine — watches the local wall clock and
      # dynamically pushes per-model peak/off-peak concurrency via
      # update_config(model_concurrency:). Starts AFTER AgentGroupSupervisor
      # (it calls the scheduler on its initial check); its own
      # {:scheduler_config_updated, node} subscription re-applies on config
      # edits/reloads.
      {EvoGit.PeakHourEngine, []},
      # System sampling — broadcasts {:system_sample, node, seq, sample} on
      # PubSub topic "system" every 3s. Runs on every node (incl. the headless
      # genesis_remote daemon) so remote dashboards get chart pushes.
      {EvoGit.SystemSampler, []}
    ]

    # SandboxSlice is only needed on Linux (systemd-run backend)
    children =
      if EvoGit.Platform.linux?() do
        children ++ [{EvoGit.SandboxProcessRegistry, []}, {EvoGit.SandboxSlice, []}]
      else
        children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EvoGit.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp ensure_ets_table(name, opts) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, opts)
      _tid -> :ok
    end
  end
end
