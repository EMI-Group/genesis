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
  @spec hierarchy_nodes(String.t(), String.t()) :: [t()]
  def hierarchy_nodes(relative_path, repo_path) do
    valid_hierarchy? =
      Path.type(relative_path) == :relative and
        not String.starts_with?(relative_path, "..")

    if not valid_hierarchy? do
      raise ArgumentError, "Path #{relative_path} must be relative to the repo root"
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

  @doc """
  Builds the string context representation for the AI by traversing the context tree.
  """
  @spec build_context(String.t(), String.t()) :: String.t()
  def build_context(relative_path, repo_path) do
    location_info =
      """
      Current Target Node: '#{relative_path}'.
      IMPORTANT: Your working directory is the repository root ('.'). All file paths provided to tools MUST be relative to the repository root. For example, if your target node is 'src/foo', you must write to 'src/foo/CONTEXT.md', NOT just 'CONTEXT.md'. If you need to run shell commands inside your target directory, you must `cd` into it first (e.g., `cd src/foo && npm init -y`).
      """
      |> String.trim_trailing()

    try do
      nodes = hierarchy_nodes(relative_path, repo_path)

      context_files =
        Enum.map(nodes, fn node ->
          if node.type == :directory do
            Path.join([repo_path, node.path, "CONTEXT.md"])
          else
            Path.join(repo_path, node.path)
          end
        end)
        |> Enum.filter(&File.exists?/1)

      context_contents =
        Enum.map_join(context_files, "\n\n", fn file ->
          case File.read(file) do
            {:ok, content} ->
              truncated_content =
                if String.length(content) > 10000 do
                  require Logger
                  Logger.warning("Content truncated for file: #{file}")
                  String.slice(content, 0, 10000) <> "\n... [Content Truncated] ..."
                else
                  content
                end

              "File: #{Path.relative_to(file, repo_path)}\n```\n#{truncated_content}\n```"

            _ ->
              ""
          end
        end)

      if context_contents == "" do
        location_info
      else
        location_info <> "\n\n# Context Tree\n" <> context_contents
      end
    rescue
      _e -> location_info
    end
  end
end
