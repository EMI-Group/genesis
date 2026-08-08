defmodule EvoGit.Core.PhyloGraphNode do
  @moduledoc """
  Manages the Temporal Dimension (Map the phylogenetic graph to git repo).
  """
  alias EvoGit.Adapters.Git
  alias EvoGit.Platform

  defstruct [:repo, :base_commit, :current_commit]

  @type t :: %__MODULE__{
          repo: String.t(),
          base_commit: String.t(),
          current_commit: String.t()
        }

  @doc """
  Initializes the graph representation starting from a specific commit or branch.

  Both `base_commit` and `current_commit` are set to the given commit.
  As the agent works, `current_commit` advances while `base_commit` remains
  fixed, enabling diff-based evaluation of partial progress.
  """
  def new(repo, commit \\ "main") do
    %__MODULE__{repo: repo, base_commit: commit, current_commit: commit}
  end

  @doc """
  Finds the common ancestor (merge base) between two nodes.
  """
  def find_merge_base(%__MODULE__{} = node_a, %__MODULE__{} = node_b) do
    Git.merge_base(node_a.repo, node_a.current_commit, node_b.current_commit)
  end

  @doc """
  Stages all changes and commits them to the node's worktree.
  Returns the updated node with the new commit SHA.
  """
  def add_and_commit(%__MODULE__{} = node, message) do
    case Git.status(node.repo) do
      {:ok, ""} ->
        case Git.rev_parse(node.repo) do
          {:ok, new_sha} -> {:ok, %{node | current_commit: new_sha}}
          error -> error
        end

      {:ok, _changes} ->
        with {:ok, _} <- Git.add(node.repo),
             {:ok, _} <- Git.commit(node.repo, message),
             {:ok, new_sha} <- Git.rev_parse(node.repo) do
          {:ok, %{node | current_commit: new_sha}}
        end

      error ->
        error
    end
  end

  @doc """
  Merges another node into the current node.
  If conflicts occur, returns {:conflict, node, conflict_files}.
  If successful, returns {:ok, updated_node}.
  """
  def crossover(%__MODULE__{} = node, %__MODULE__{} = other_node) do
    case Git.merge(node.repo, other_node.current_commit) do
      {:ok, _output} ->
        {:ok, new_sha} = Git.rev_parse(node.repo)
        {:ok, %{node | current_commit: new_sha}}

      {:conflict, _output} ->
        {:ok, conflicts} = Git.conflict_files(node.repo)
        {:conflict, node, conflicts}

      error ->
        error
    end
  end

  @doc """
  Returns a list of conflicting files in the node's current state.
  """
  def get_conflict_files(%__MODULE__{} = node) do
    Git.conflict_files(node.repo)
  end

  @doc """
  Returns the current HEAD SHA for a given repo path.
  """
  def current_head(repo) do
    case Git.rev_parse(repo) do
      {:ok, sha} -> {:ok, sha}
      error -> error
    end
  end

  @doc """
  Lists all files in the given commit recursively.
  """
  def list_files(%__MODULE__{} = node) do
    case Git.run(["ls-tree", "-r", "--name-only", node.current_commit], node.repo) do
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
  def list_immediate_children(%__MODULE__{} = node, path) do
    # git ls-tree --name-only <sha> <path>/
    # Note: if path is ".", use just the sha.
    args =
      cond do
        path in [".", "./"] ->
          ["ls-tree", "--name-only", node.current_commit]

        Platform.trailing_separator?(path) ->
          ["ls-tree", "--name-only", node.current_commit, path]

        true ->
          ["ls-tree", "--name-only", node.current_commit, Platform.trim_trailing_separators(path) <> "/"]
      end

    case Git.run(args, node.repo) do
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
