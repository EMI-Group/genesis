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

  @doc """
  Retrieves the full hierarchy of ContextNodes from the project root down to the given path.
  """
  @spec get_hierarchy(String.t(), String.t()) :: [t()]
  def get_hierarchy(path, root \\ ".") do
    abs_path = Path.expand(path)
    abs_root = Path.expand(root)

    relative_path = Path.relative_to(abs_path, abs_root)

    # Check if path is actually inside root
    # 1. Must be relative (not absolute path returned as-is)
    # 2. Must not start with ".."
    valid_hierarchy? =
      Path.type(relative_path) == :relative and
        not String.starts_with?(relative_path, "..")

    if not valid_hierarchy? do
      raise ArgumentError, "Path #{path} is not inside root #{root}"
    end

    case relative_path do
      "." ->
        [load(abs_root)]

      _ ->
        parts = Path.split(relative_path)

        paths =
          Enum.scan(parts, abs_root, fn part, acc ->
            Path.join(acc, part)
          end)

        [abs_root | paths]
        |> Enum.map(&load/1)
    end
  end
end
