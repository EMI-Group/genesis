defmodule EvoGit.AgentGroupSupervisor do
  @moduledoc """
  Nested `one_for_all` supervisor linking `TaskSupervisor` and `AgentScheduler`.

  When AgentScheduler crashes, we need to kill and restart TaskSupervisor too,
  because the Task.Supervisor's running tasks are linked to the old scheduler's
  in-flight work and must be torn down. A `one_for_all` strategy ensures both
  children are taken down and restarted together, eliminating the need for
  `Process.flag(:trap_exit, true)` + manual `{:EXIT, ...}` handling.
  """

  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    children = [
      {Task.Supervisor, name: EvoGit.TaskSupervisor},
      {EvoGit.AgentScheduler, []}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
