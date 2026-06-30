defmodule EvoGit.Agent.Result do
  @moduledoc """
  Structured result of a completed agent run.

  When an agent finishes its work (via the `complete_task` tool), it produces
  a `%Result{}` struct capturing the outcome — including the human-readable
  result string, the commit SHA of any changes made, and optional metadata
  such as tag, branch, base commit, `repo_id` (string identifying which
  repo this result belongs to, `nil` for backward compat), cumulative
  `usage` (token and cost tracking, `nil` for backward compat), and
  `agent_count` (total agents spawned including subagents, `nil` for
  backward compat), and `archive_records` (list of archive record maps for
  task archiving, `nil` for backward compat).
  """

  alias EvoGit.Agent.Usage

  @enforce_keys [:result, :commit_sha]
  defstruct [:result, :commit_sha, tag: nil, branch: nil, base_commit: nil, repo_id: nil, usage: nil, agent_count: nil, archive_records: nil]

  @type t :: %__MODULE__{
          result: String.t(),
          commit_sha: String.t(),
          tag: String.t() | nil,
          branch: String.t() | nil,
          base_commit: String.t() | nil,
          repo_id: String.t() | nil,
          usage: Usage.t() | nil,
          agent_count: pos_integer() | nil,
          archive_records: [map()] | nil
        }

  @doc """
  Creates a new `EvoGit.Agent.Result` struct.

  ## Parameters

    * `result`      — human-readable summary of what the agent accomplished
    * `commit_sha`  — SHA of the commit produced by the agent
    * `opts`        — optional keyword list (`:tag`, `:branch`, `:base_commit`, `:repo_id`, `:usage`, `:agent_count`, `:archive_records`)

  ## Examples

      iex> EvoGit.Agent.Result.new("Fixed the bug", "abc123", tag: "fix")
      %EvoGit.Agent.Result{result: "Fixed the bug", commit_sha: "abc123", tag: "fix"}
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(result, commit_sha, opts \\ []) do
    %__MODULE__{
      result: result,
      commit_sha: commit_sha,
      tag: Keyword.get(opts, :tag),
      branch: Keyword.get(opts, :branch),
      base_commit: Keyword.get(opts, :base_commit),
      repo_id: Keyword.get(opts, :repo_id),
      usage: Keyword.get(opts, :usage),
      agent_count: Keyword.get(opts, :agent_count),
      archive_records: Keyword.get(opts, :archive_records)
    }
  end
end
