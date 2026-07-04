defmodule EvoDash.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    data_dir = Application.get_env(:evo_dash, :data_dir, EvoGit.Platform.data_dir())

    children = [
      EvoDashWeb.Telemetry,
      {Phoenix.PubSub, name: EvoDash.PubSub},
      {Task.Supervisor, name: EvoDash.TaskSupervisor},
      {EvoDash.Store, data_dir: Path.join(data_dir, "tasks.sqlite")},
      EvoDash.TaskRegistry,
      EvoDashWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    # Use :one_for_one so Endpoint survives a TaskRegistry restart.
    # Tune max_restarts to tolerate repeated transient crashes without
    # shutting down the whole application.
    opts = [
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60,
      name: EvoDash.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EvoDashWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
