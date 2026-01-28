defmodule EvoGit.Core.PhylogeneticGraph do
  @moduledoc """
  Manages the Temporal Dimension (Git history and the "better than" logic).
  """
  defstruct [:current_sha]

  @type t :: %__MODULE__{ 
          current_sha: String.t()
        }

  @doc """
  Initializes the graph representation starting from a specific commit (or HEAD).
  """
  def new(sha \\ "HEAD") do
    %__MODULE__{current_sha: sha}
  end

  # Additional methods to traverse the graph or compare versions would go here,
  # potentially delegating to EvoGit.Adapters.Git
end
