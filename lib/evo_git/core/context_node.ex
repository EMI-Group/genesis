defmodule EvoGit.Core.ContextNode do
  @moduledoc """
  Represents a node in the Spatial Dimension (the Context Tree).
  """
  @enforce_keys [:path, :type]
  defstruct [:path, :type, :context_contract]

  @type t :: %__MODULE__{
          path: String.t(),
          type: :directory | :file,
          context_contract: String.t() | nil
        }

  @doc """
  Loads a ContextNode from a given path on the disk.
  """
  @spec load(String.t()) :: t()
  def load(path) do
    if File.dir?(path) do
      contract_path = Path.join(path, "CONTEXT.md")
      contract =
        if File.exists?(contract_path) do
          File.read!(contract_path)
        else
          nil
        end

      %__MODULE__{
        path: path,
        type: :directory,
        context_contract: contract
      }
    else
      %__MODULE__{
        path: path,
        type: :file,
        context_contract: nil
      }
    end
  end
end
