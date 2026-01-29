defmodule EvoGit.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: EvoGit.TaskSupervisor},
      # Starts a worker by calling: EvoGit.Worker.start_link(arg)
      # {EvoGit.Worker, arg}
      {EvoGit.WorkerPool,
       [
         max_concurrency: Application.get_env(:evo_git, :max_concurrency, 3),
         max_retries: Application.get_env(:evo_git, :max_retries, 3)
       ]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EvoGit.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
