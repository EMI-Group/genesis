defmodule EvoGit.Core.ContextNode do
  @moduledoc """
  Represents a node in the Spatial Dimension (the Context Tree).
  """
  defstruct [:path, :type, :context_contract]

  @type t :: %__MODULE__{
          path: String.t(),
          type: :directory | :file,
          context_contract: String.t() | nil
        }
end

defmodule EvoGit.Core.PhylogeneticGraph do
  @moduledoc """
  Manages the Temporal Dimension (Git history and the "better than" logic).
  """
  defstruct [:current_sha, :history]
end
