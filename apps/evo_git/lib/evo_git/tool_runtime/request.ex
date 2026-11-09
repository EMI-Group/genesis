defmodule EvoGit.ToolRuntime.Request do
  @moduledoc """
  Everything the managed tool-call runtime needs to execute ONE batch.

  The AGENT process resolves this struct ONCE per batch (from its process
  dictionary and the scheduler) and hands it to
  `EvoGit.ToolRuntime.execute_batch/2`. The runtime then owns concurrency,
  per-call timeouts, tool slots, `EvoGit.ProcessManager` tracking and the
  installation of the per-call context inside the spawned tool tasks — so no
  agent-side state has to be threaded through the execution engine.

  ## Fields

    * `:agent_id` — the scheduler agent id the tool slot is acquired under.
    * `:task_id` — the owning task id (task-control/background-job tools report
      who acted).
    * `:agent_pid` — the AGENT's pid, never a tool task's pid (a background job
      monitored on a tool task would die the instant the task is shut down).
    * `:repo_path` — the agent's worktree (the tool `cwd`).
    * `:repo_root` — the repository's MAIN working copy.
    * `:node_path` — the agent's context-tree node path.
    * `:taskdir` — the per-task tmpdir (`EvoGit.TaskTmpdir`), re-installed in
      every tool task.
    * `:max_timeout` — the configured per-call ceiling (ms).
    * `:delegation_level` — the receiving role's delegation level.
    * `:agent_module` — the receiving role module.
    * `:role` — the ROLE-GUARD inputs `EvoGit.Agent.Tools.execute/5` consults
      (`:repo_less`, `:foreign_repos`, `:repo_id`).
  """

  alias EvoGit.Agent.DelegationHints

  @fields [
    :agent_id,
    :task_id,
    :agent_pid,
    :repo_path,
    :repo_root,
    :node_path,
    :taskdir,
    :max_timeout,
    :delegation_level,
    :agent_module,
    :role
  ]

  @type role :: %{
          repo_less: boolean(),
          foreign_repos: list(),
          repo_id: String.t() | nil
        }

  @type t :: %__MODULE__{
          agent_id: integer() | nil,
          task_id: String.t() | nil,
          agent_pid: pid() | nil,
          repo_path: String.t() | nil,
          repo_root: String.t() | nil,
          node_path: String.t() | nil,
          taskdir: String.t() | nil,
          max_timeout: integer(),
          delegation_level: atom(),
          agent_module: module() | nil,
          role: role()
        }

  defstruct @fields

  @doc """
  Builds a request from a map (atom keys) or a keyword list.

  Absent keys fall back to their defaults: `:max_timeout` to
  `EvoGit.Agent.DelegationHints.max_tool_timeout/0`, `:delegation_level` to
  `:high` (the `EvoGit.Agent` behaviour default) and `:role` to
  `%{repo_less: false, foreign_repos: [], repo_id: nil}`. Every other field
  defaults to `nil`.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    attrs = attrs |> Enum.into(%{}) |> Map.take(@fields)

    %__MODULE__{
      agent_id: Map.get(attrs, :agent_id),
      task_id: Map.get(attrs, :task_id),
      agent_pid: Map.get(attrs, :agent_pid),
      repo_path: Map.get(attrs, :repo_path),
      repo_root: Map.get(attrs, :repo_root),
      node_path: Map.get(attrs, :node_path),
      taskdir: Map.get(attrs, :taskdir),
      max_timeout: Map.get(attrs, :max_timeout) || DelegationHints.max_tool_timeout(),
      delegation_level: Map.get(attrs, :delegation_level) || :high,
      agent_module: Map.get(attrs, :agent_module),
      role: normalize_role(Map.get(attrs, :role))
    }
  end

  defp normalize_role(%{} = role) do
    %{
      repo_less: Map.get(role, :repo_less) == true,
      foreign_repos: Map.get(role, :foreign_repos) || [],
      repo_id: Map.get(role, :repo_id)
    }
  end

  defp normalize_role(_role), do: %{repo_less: false, foreign_repos: [], repo_id: nil}
end
