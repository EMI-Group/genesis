defmodule EvoGit.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

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

    # Enable distributed Erlang at startup if configured.
    # This must happen before starting RemoteConnection-related children,
    # since RemoteConnection needs the local node in distributed mode to
    # connect to remote nodes via SSH tunnels.
    EvoGit.Distribution.maybe_enable()

    children = [
      {Phoenix.PubSub, name: EvoGit.PubSub},
      # PubSub broadcast throttle (coalesces rapid agent-update signals)
      {EvoGit.AgentScheduler.PubSub.Throttle, []},
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
      {EvoGit.AgentGroupSupervisor, []}
    ]

    # SandboxSlice is only needed on Linux (systemd-run backend)
    children =
      if EvoGit.Platform.linux?() do
        children ++ [{EvoGit.SandboxProcessRegistry, []}, {EvoGit.SandboxSlice, []}]
      else
        children
      end

    # Desktop mode: monitor the Tauri shell's OS pid (EVOGIT_PARENT_PID) and
    # exit the VM when the shell dies, so an orphaned backend never holds the
    # port. Gated on the env vars ONLY — the sidecar sets both, while
    # manually-launched releases and the genesis_remote daemon set neither
    # (the module's own init-disabled logic is belt-and-suspenders for direct
    # starts).
    children =
      if System.get_env("EVOGIT_DESKTOP") == "1" and
           System.get_env("EVOGIT_PARENT_PID") not in [nil, ""] do
        children ++ [{EvoGit.DesktopParentMonitor, []}]
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
