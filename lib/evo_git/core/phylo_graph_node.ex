defmodule EvoGit.Core.PhyloGraphNode do
  @moduledoc """
  Manages the Temporal Dimension (Map the phylogenetic graph to git repo).
  """
  alias EvoGit.Adapters.Git

  defstruct [:path, :current_commit]

  @type t :: %__MODULE__{
          path: String.t(),
          current_commit: String.t()
        }

  @doc """
  Initializes the graph representation starting from a specific commit or branch.
  """
  def new(path, commit \\ "main") do
    %__MODULE__{path: path, current_commit: commit}
  end

  @doc """
  Finds the common ancestor (merge base) between two nodes.
  """
  def find_merge_base(%__MODULE__{} = node_a, %__MODULE__{} = node_b) do
    Git.merge_base(node_a.path, node_a.current_commit, node_b.current_commit)
  end

  @doc """
  Stages all changes and commits them to the node's worktree.
  Returns the updated node with the new commit SHA.
  """
  def add_and_commit(%__MODULE__{} = node, message) do
    with {:ok, _} <- Git.add(node.path),
         {:ok, _} <- Git.commit(node.path, message),
         {:ok, new_sha} <- Git.rev_parse(node.path) do
      {:ok, %{node | current_commit: new_sha}}
    end
  end

  @doc """
  Merges another node into the current node.
  If conflicts occur, returns {:conflict, node, conflict_files}.
  If successful, returns {:ok, updated_node}.
  """
  def crossover(%__MODULE__{} = node, %__MODULE__{} = other_node) do
    case Git.merge(node.path, other_node.current_commit) do
      {:ok, _output} ->
        {:ok, new_sha} = Git.rev_parse(node.path)
        {:ok, %{node | current_commit: new_sha}}

      {:conflict, _output} ->
        {:ok, conflicts} = Git.conflict_files(node.path)
        {:conflict, node, conflicts}

      error ->
        error
    end
  end

  @doc """
  Returns a list of conflicting files in the node's current state.
  """
  def get_conflict_files(%__MODULE__{} = node) do
    Git.conflict_files(node.path)
  end

  @doc """
  Returns the current HEAD SHA for a given path.
  """
  def current_head(path \\ File.cwd!()) do
    case Git.rev_parse(path) do
      {:ok, sha} -> {:ok, sha}
      error -> error
    end
  end

  @doc """
  Lists all directories in the given commit recursively.
  """
  def list_directories(commit_sha, root_path \\ File.cwd!()) do
    case Git.run(["ls-tree", "-r", "-d", "--name-only", commit_sha], root_path) do
      {:ok, output} ->
        dirs = String.split(output, "\n", trim: true)
        {:ok, dirs}

      error ->
        error
    end
  end

  @doc """
  Lists all files in the given commit recursively.
  """
  def list_files(commit_sha, root_path \\ File.cwd!()) do
    case Git.run(["ls-tree", "-r", "--name-only", commit_sha], root_path) do
      {:ok, output} ->
        files = String.split(output, "\n", trim: true)
        {:ok, files}

      error ->
        error
    end
  end

  @doc """
  Lists immediate children (files and directories) of a given path in a specific commit.
  """
  def list_immediate_children(commit_sha, path, root_path \\ File.cwd!()) do
    # git ls-tree --name-only <sha> <path>/
    # Note: if path is ".", use just the sha.
    args =
      cond do
        path == "." ->
          ["ls-tree", "--name-only", commit_sha]

        String.ends_with?(path, "/") ->
          ["ls-tree", "--name-only", commit_sha, path]

        true ->
          ["ls-tree", "--name-only", commit_sha, path <> "/"]
      end

    case Git.run(args, root_path) do
      {:ok, output} ->
        # Output contains paths relative to root.
        # If we asked for "lib", output is "lib/evo_git.ex", "lib/evo_git" etc.
        items = String.split(output, "\n", trim: true)
        {:ok, items}

      {:error, _code, msg} ->
        # If it fails because it's not a tree (e.g. it's a file), return empty list.
        if String.contains?(msg, "not a tree object") do
          {:ok, []}
        else
          {:error, msg}
        end
    end
  end
end
