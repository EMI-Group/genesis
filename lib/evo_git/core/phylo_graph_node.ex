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
  def merge(%__MODULE__{} = node, %__MODULE__{} = other_node) do
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
end
