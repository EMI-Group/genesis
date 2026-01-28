defmodule EvoGit.Adapters.Git do
  @moduledoc """
  Wrapper for Git CLI operations, focusing on Worktree isolation.
  """
  
def add_worktree(path, base_sha, branch_name) do
    # git worktree add -b branch_name path base_sha
  end

def commit(path, message) do
    # git commit -am message
  end
end

defmodule EvoGit.Adapters.Gemini do
  @moduledoc """
  Wrapper for Gemini CLI integration.
  """

def call(prompt, input \ nil) do
    # echo input | gemini --prompt prompt
  end
end
