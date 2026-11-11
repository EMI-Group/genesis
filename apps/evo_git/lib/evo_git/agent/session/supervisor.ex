defmodule EvoGit.Agent.Session.Supervisor do
  @moduledoc """
  The `DynamicSupervisor` every `EvoGit.Agent.Session` process runs under.

  `strategy: :one_for_one`: sessions are independent, so one agent's crash never
  restarts another. Sessions themselves are `restart: :temporary` (see
  `EvoGit.Agent.Session.child_spec/1`) — a crashed session is NEVER restarted by
  this supervisor; the scheduler's own crash/retry path owns that decision, and
  it is the only thing that knows whether the run may be retried.

  The supervisor is started by name only; every agent session is started here by
  `EvoGit.AgentScheduler.Dispatch.do_try_dispatch/4` and owned by that dispatch.
  """

  @doc """
  Starts the dynamic supervisor under `EvoGit.Agent.Session.Supervisor`.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(supervisor_opts(opts))
  end

  @doc false
  def child_spec(opts) do
    DynamicSupervisor.child_spec(supervisor_opts(opts))
  end

  defp supervisor_opts(opts) do
    Keyword.merge([strategy: :one_for_one, name: __MODULE__], opts)
  end
end
