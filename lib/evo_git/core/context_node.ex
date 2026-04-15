defmodule EvoGit.Core.ContextNode do
  @moduledoc """
  Represents a node in the Spatial Dimension (the Context Tree).
  """
  @enforce_keys [:path, :type, :repo]
  defstruct [:path, :type, :repo]

  alias EvoGit.Adapters.Git

  @type t :: %__MODULE__{
          path: String.t(),
          type: :directory | :file,
          repo: String.t()
        }

  @doc """
  Checks if the given node's path is ignored by git (according to .gitignore).
  Returns true if the path or any parent directory is ignored.
  """
  @spec is_ignored?(t()) :: boolean()
  def is_ignored?(%__MODULE__{path: path, repo: repo_path}) do
    check_path_ignored(path, repo_path)
  end

  # Check if a path (and all its parent components) is ignored by git
  defp check_path_ignored(path, repo_path) when is_binary(path) and path != "." do
    abs_path = Path.expand(path, repo_path)

    # First, check the current path
    case Git.check_ignore(repo_path, [abs_path]) do
      {:ok, [_ | _]} ->
        true

      {:ok, []} ->
        # If current path is not ignored, check parent directory recursively
        parent = Path.dirname(path)

        if parent == "." do
          false
        else
          check_path_ignored(parent, repo_path)
        end

      _ ->
        false
    end
  end

  defp check_path_ignored(_, _), do: false

  @doc """
  Loads a ContextNode from a given relative path within a repository.
  `relative_path` must be relative to `repo_path` (or "." for root).
  `repo_path` must be the absolute path to the repository root.
  """
  @spec load(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def load(relative_path, repo_path) do
    abs_path = Path.expand(relative_path, repo_path)

    if File.exists?(abs_path) do
      type =
        if File.dir?(abs_path) do
          :directory
        else
          :file
        end

      {:ok,
       %__MODULE__{
         path: relative_path,
         type: type,
         repo: repo_path
       }}
    else
      {:error, :enoent}
    end
  end

  @doc """
  Retrieves the full hierarchy of ContextNodes from the project root down to the given relative path.
  `relative_path` must be relative to the root of the repository.
  `repo_path` must be the absolute path to the repository root.
  Nodes that do not exist in the filesystem are excluded from the result list.
  """
  @spec hierarchy_nodes(String.t(), String.t()) :: {:ok, [t()]} | {:error, term()}
  def hierarchy_nodes(relative_path, repo_path)
      when is_binary(relative_path) and is_binary(repo_path) do
    if Path.type(relative_path) == :relative and not String.starts_with?(relative_path, "..") do
      paths =
        if relative_path == "." do
          ["."]
        else
          ["." | Enum.scan(Path.split(relative_path), &Path.join(&2, &1))]
        end

      nodes =
        paths
        |> Enum.reduce([], fn p, acc ->
          case load(p, repo_path) do
            {:ok, node} -> [node | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      {:ok, nodes}
    else
      {:error, :invalid_path}
    end
  end

  def hierarchy_nodes(_relative_path, _repo_path) do
    {:error, :invalid_path}
  end

  @doc """
  Reads the context contract for a given directory node, or the file content for a file node.
  """
  @spec read_context(t()) :: {:ok, String.t()} | {:error, term()}
  def read_context(%__MODULE__{type: :directory} = node) do
    abs_path = Path.expand(node.path, node.repo)
    contract_path = Path.join(abs_path, "CONTEXT.md")

    File.read(contract_path)
  end

  def read_context(%__MODULE__{type: :file} = node) do
    abs_path = Path.expand(node.path, node.repo)
    File.read(abs_path)
  end

  @doc """
  Reads the context contract for a given directory or file node, raising on error.
  """
  @spec read_context!(t()) :: String.t()
  def read_context!(%__MODULE__{} = node) do
    case read_context(node) do
      {:ok, content} -> content
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: node.path
    end
  end

  @doc """
  Returns the relative path to the file that provides the context for a node.
  """
  @spec context_file_path(t()) :: String.t()
  def context_file_path(%__MODULE__{type: :directory} = node) do
    Path.join(node.path, "CONTEXT.md")
  end

  def context_file_path(%__MODULE__{type: :file} = node) do
    node.path
  end

  @doc """
  Builds the string context representation for the AI by traversing the context tree.
  """
  @spec build_context(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def build_context(relative_path, repo_path) do
    location_info =
      """
      Current Path: '#{relative_path}'.
      IMPORTANT: Your working directory is the repository root ('.').
      All file paths provided to tools MUST be relative to the repository root.
      """
      |> String.trim_trailing()

    case hierarchy_nodes(relative_path, repo_path) do
      {:ok, nodes} ->
        context_contents =
          nodes
          |> Enum.map(fn node ->
            content =
              case read_context(node) do
                {:ok, c} -> c
                _ -> ""
              end

            file = context_file_path(node)

            truncated_content =
              if String.length(content) > 10000 do
                require Logger
                Logger.warning("Content truncated for file: #{file}")
                String.slice(content, 0, 10000) <> "\n... [Content Truncated] ..."
              else
                content
              end

            "File: #{file}\n```\n#{truncated_content}\n```"
          end)
          |> Enum.join("\n\n")

        if context_contents == "" do
          {:ok, location_info}
        else
          {:ok, location_info <> "\n\n# Context Tree\n" <> context_contents}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds the string context representation for the AI by traversing the context tree, raising on error.
  """
  @spec build_context!(String.t(), String.t()) :: String.t()
  def build_context!(relative_path, repo_path) do
    case build_context(relative_path, repo_path) do
      {:ok, result} -> result
      {:error, reason} -> raise "Failed to build context: #{inspect(reason)}"
    end
  end
end
