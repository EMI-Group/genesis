defmodule EvoGit.Core.PhyloGraphNode do
  @moduledoc """
  Manages the Temporal Dimension (Map the phylogenetic graph to git repo).
  """
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

  # Additional methods to traverse the graph or compare versions would go here,
  # potentially delegating to EvoGit.Adapters.Git
end
