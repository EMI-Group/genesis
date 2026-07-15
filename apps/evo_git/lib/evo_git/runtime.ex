defmodule EvoGit.Runtime do
  @moduledoc """
  Coordinates the Genesis and Evolution stages.
  """

  alias EvoGit.Adapters.Git
  require Logger

  @doc """
  Ensures a Git repository exists at the given path.
  If not, initializes one, stages all existing files, and creates an initial commit.
  A `.gitignore` is written to exclude `/.genesis` worktrees.
  """
  def ensure_repo(repo_path) do
    if File.dir?(Path.join(repo_path, ".git")) do
      :ok
    else
      Logger.info("Initializing Git repository at #{repo_path}...")
      File.mkdir_p!(repo_path)
      Git.init(repo_path)

      # Create .gitignore to ignore .genesis worktrees
      gitignore_path = Path.join(repo_path, ".gitignore")
      File.write!(gitignore_path, "/.genesis\n")
      Git.add(repo_path)

      case Git.commit(repo_path, "Initial commit") do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end
end
