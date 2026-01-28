defmodule EvoGit.Adapters.Git do
  @moduledoc """
  Wrapper for Git CLI operations, focusing on Worktree isolation.
  """

  def add_worktree(_path, _base_sha, _branch_name) do
    # git worktree add -b branch_name path base_sha
    :ok
  end

  def commit(_path, _message) do
    # git commit -am message
    :ok
  end
end
