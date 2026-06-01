defmodule EvoGit.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: EvoGit.PubSub},
      {Task.Supervisor, name: EvoGit.TaskSupervisor},
      {EvoGit.AgentScheduler, []},
      {EvoGit.SandboxSlice, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EvoGit.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
