defmodule EvoGit.TaskInfo do
  @moduledoc """
  Struct representing a task in the registry.
  """
  defstruct [
    :id,
    :type,
    :opts,
    :ref,
    :started_at,
    :finished_at,
    status: :pending,
    logs: [],
    result: nil,
    review_status: nil,
    usage: nil,
    agent_count: nil,
    base_sha: nil,
    commit_sha: nil,
    archive_metadata: nil,
    lease_expires_at: nil,
    model_id: nil,
    project_path: nil,
    branch_name: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          type: atom() | nil,
          status: :pending | :running | :finalizing | :completed | :failed | :cancelled,
          opts: keyword() | nil,
          ref: Task.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          logs: [String.t()],
          result: term(),
          review_status: atom() | nil,
          usage: EvoGit.Agent.Usage.t() | nil,
          agent_count: pos_integer() | nil,
          base_sha: String.t() | nil,
          commit_sha: String.t() | nil,
          archive_metadata: [map()] | nil,
          lease_expires_at: integer() | nil,
          model_id: String.t() | nil,
          project_path: String.t() | nil,
          branch_name: String.t() | nil
        }
end
