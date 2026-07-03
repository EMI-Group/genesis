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
    ensure_ets_table(:evogit_archive_records, [:named_table, :public, :duplicate_bag, read_concurrency: true])

    children = [
      {Phoenix.PubSub, name: EvoGit.PubSub},
      {Task.Supervisor, name: EvoGit.TaskSupervisor},
      {EvoGit.AgentScheduler, []}
    ]

    # SandboxSlice is only needed on Linux (systemd-run backend)
    children =
      if EvoGit.Platform.linux?() do
        children ++ [{EvoGit.SandboxSlice, []}]
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
