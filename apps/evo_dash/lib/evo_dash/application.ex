defmodule EvoDash.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EvoDashWeb.Telemetry,
      {Phoenix.PubSub, name: EvoDash.PubSub},
      {Task.Supervisor, name: EvoDash.TaskSupervisor},
      {EvoDash.TaskStore, data_dir: Path.join(EvoGit.Platform.data_dir(), "tasks.cubdb")},
      EvoDash.TaskRegistry,
      EvoDashWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EvoDash.Supervisor]
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
