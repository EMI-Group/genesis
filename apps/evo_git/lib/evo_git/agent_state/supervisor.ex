defmodule EvoGit.AgentState.Supervisor do
  @moduledoc """
  The container of the durable agent-state subsystem.

  `EvoGit.AgentState` is a child of `EvoGit.Supervisor` as THIS supervisor, not
  as the writer GenServer, so a failing disk (or a crashing writer) is contained
  here: the restart intensity is deliberately generous (10 restarts / 60 s)
  while `EvoGit.Supervisor`'s own default is 3 / 5 s.
  A repeated boot failure therefore degrades the store (see
  `EvoGit.AgentState.Server.init/1`) or restarts the writer — it can never shut
  the application or the BEAM down.

  The supervisor passes its OWN pid to the child as the `:supervisor` start
  option, so the server can publish
  `{EvoGit.AgentState, :server_for, supervisor_pid} => server_pid` in
  `:persistent_term`. `EvoGit.AgentState`'s public functions accept either pid
  (a supervisor pid is resolved to its writer) — a `GenServer.call` to a
  supervisor would otherwise crash it.
  """

  use Supervisor

  @max_restarts 10
  @max_seconds 60

  @doc "Starts the agent-state supervisor (unnamed; the writer keeps its own name)."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    # `self()` here IS the supervisor process, so the child learns the pid the
    # facade must resolve through.
    server_opts = Keyword.put(opts, :supervisor, self())

    Supervisor.init([{EvoGit.AgentState.Server, server_opts}],
      strategy: :one_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end
end
