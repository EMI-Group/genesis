defmodule EvoGit.Agent.Result do
  @moduledoc """
  Structured result of a completed agent run.

  When an agent finishes its work (via the `complete_task` tool), it produces
  a `%Result{}` struct capturing the outcome — including the human-readable
  result string, the commit SHA of any changes made, and optional metadata
  such as tag, branch, and base commit.
  """

  @enforce_keys [:result, :commit_sha]
  defstruct [:result, :commit_sha, tag: nil, branch: nil, base_commit: nil]

  @type t :: %__MODULE__{
          result: String.t(),
          commit_sha: String.t(),
          tag: String.t() | nil,
          branch: String.t() | nil,
          base_commit: String.t() | nil
        }

  @doc """
  Creates a new `EvoGit.Agent.Result` struct.

  ## Parameters

    * `result`      — human-readable summary of what the agent accomplished
    * `commit_sha`  — SHA of the commit produced by the agent
    * `opts`        — optional keyword list (`:tag`, `:branch`, `:base_commit`)

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
      base_commit: Keyword.get(opts, :base_commit)
    }
  end
end
