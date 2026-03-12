defmodule EvoGit.Core.ContextNode do
  @moduledoc """
  Represents a node in the Spatial Dimension (the Context Tree).
  """
  @enforce_keys [:path, :type, :repo]
  defstruct [:path, :type, :context_contract, :repo]

  @type t :: %__MODULE__{
          path: String.t(),
          type: :directory | :file,
          context_contract: String.t() | nil,
          repo: String.t()
        }

  @doc """
  Loads a ContextNode from a given relative path within a repository.
  `relative_path` must be relative to `repo_path` (or "." for root).
  `repo_path` must be the absolute path to the repository root.
  """
  @spec load(String.t(), String.t()) :: t()
  def load(relative_path, repo_path) do
    abs_path = Path.expand(relative_path, repo_path)

    if File.dir?(abs_path) do
      contract_path = Path.join(abs_path, "CONTEXT.md")

      contract =
        if File.exists?(contract_path) do
          File.read!(contract_path)
        else
          nil
        end

      %__MODULE__{
        path: relative_path,
        type: :directory,
        context_contract: contract,
        repo: repo_path
      }
    else
      %__MODULE__{
        path: relative_path,
        type: :file,
        context_contract: nil,
        repo: repo_path
      }
    end
  end

  @doc """
  Retrieves the full hierarchy of ContextNodes from the project root down to the given relative path.
  `relative_path` must be relative to the root of the repository.
  `repo_path` must be the absolute path to the repository root.
  """
  @spec hier_context(String.t(), String.t()) :: [t()]
  def hier_context(relative_path, repo_path) do
    valid_hierarchy? =
      Path.type(relative_path) == :relative and
        not String.starts_with?(relative_path, "..")

    if not valid_hierarchy? do
      raise ArgumentError, "Path \#{relative_path} must be relative to the repo root"
    end

    case relative_path do
      "." ->
        [load(".", repo_path)]

      _ ->
        parts = Path.split(relative_path)

        paths = Enum.scan(parts, &Path.join(&2, &1))

        ["." | paths]
        |> Enum.map(fn p -> load(p, repo_path) end)
    end
  end
end
