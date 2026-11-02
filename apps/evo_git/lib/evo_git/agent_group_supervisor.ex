defmodule EvoGit.AgentGroupSupervisor do
  @moduledoc """
  Nested `one_for_all` supervisor linking `TaskSupervisor` and `AgentScheduler`.

  When AgentScheduler crashes, we need to kill and restart TaskSupervisor too,
  because the Task.Supervisor's running tasks are linked to the old scheduler's
  in-flight work and must be torn down. A `one_for_all` strategy ensures both
  children are taken down and restarted together, eliminating the need for
  `Process.flag(:trap_exit, true)` + manual `{:EXIT, ...}` handling.

  A third spec, `EvoGit.CatalogWarmup`, sits immediately before the scheduler:
  it does its work and returns `:ignore`, so it never becomes a running child —
  it only guarantees the LLM model catalog is already loaded (in its own, now
  dead, process) by the time `AgentScheduler.init/1` first reads it.
  """

  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    children = [
      {Task.Supervisor, name: EvoGit.TaskSupervisor},
      # Throwaway LLM-catalog warm-up. It pays the one-off `llm_db` snapshot
      # decode in a short-lived process and returns `:ignore` (so nothing stays
      # in this tree), which leaves `AgentScheduler.init/1` — the first catalog
      # consumer — with cheap `:persistent_term` reads instead of a ~50 MB
      # transient heap it would retain for a whole EMBEDDED release boot.
      # Must stay IMMEDIATELY BEFORE the scheduler.
      {EvoGit.CatalogWarmup, []},
      {EvoGit.AgentScheduler, []}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
