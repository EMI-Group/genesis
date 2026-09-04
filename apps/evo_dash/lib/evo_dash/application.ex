defmodule EvoDash.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Create the ActiveTasks ETS table, owned by the long-lived application
    # process (NOT a supervised child) so it survives child restarts and lives
    # for the whole `mix test` run. Creation is idempotent — a no-op if the
    # table already exists (e.g. on application restart after a soft crash).
    # EvoDash.ActiveTasks is a pure ETS-helper module with no process (same
    # pattern as EvoGit.AgentScheduler.Store).
    ensure_ets_table(:evo_dash_active_tasks, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    children = [
      EvoDashWeb.Telemetry,
      {Phoenix.PubSub, name: EvoDash.PubSub},
      {Task.Supervisor, name: EvoDash.TaskSupervisor},
      # In-memory (ETS-backed) chat-history store for the Home chat page —
      # transcripts survive LiveView remounts, not BEAM restarts.
      EvoDash.ChatHistory,
      # Serializes native :wx directory-dialog usage (Browse buttons). Starts no
      # wx server at boot — wx is initialized lazily on the first pick.
      EvoDash.DirectoryPicker,
      # Auto-update state hub for the Tauri updater integration — holds the
      # update phase/versions/error state and broadcasts transitions on
      # EvoGit.PubSub's "updates" topic.
      EvoDash.UpdateStatus,
      EvoDashWeb.Endpoint
    ]

    # Desktop-only Tauri-shell lifetime watcher: the sidecar sets BOTH
    # EVOGIT_DESKTOP=1 and EVOGIT_LIFETIME_PORT, while manually-launched
    # releases and the remote daemon set neither. The module's own init/1
    # self-disable logic is belt-and-suspenders.
    children =
      if System.get_env("EVOGIT_DESKTOP") == "1" and
           System.get_env("EVOGIT_LIFETIME_PORT") not in [nil, ""] do
        children ++ [{EvoDash.DesktopLifetime, []}]
      else
        children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    # Use :one_for_one with a generous max_restarts to tolerate transient
    # crashes without shutting down the whole application.
    opts = [
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60,
      name: EvoDash.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end

  # Idempotent named-table creation (mirrors EvoGit.Application's
  # ensure_ets_table/2): no-op when the table already exists (e.g. on
  # application restart after a soft crash).
  defp ensure_ets_table(name, opts) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, opts)
      _tid -> :ok
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EvoDashWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
