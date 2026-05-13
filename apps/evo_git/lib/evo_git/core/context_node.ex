defmodule EvoGit.Core.ContextNode do
  @moduledoc """
  Represents a node in the Spatial Dimension (the Context Tree).

  The type (:directory or :file) is determined at runtime, not at creation time,
  because the node may be created before the path exists in the filesystem.
  """
  @enforce_keys [:path, :repo]
  defstruct [:path, :repo]

  alias EvoGit.Adapters.Git

  @context_max_bytes 64 * 1024

  @type t :: %__MODULE__{
          path: String.t(),
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

  Note: This does not check if the path exists or determine its type,
  because the node may represent a path that doesn't exist yet at creation time.
  Type is determined at runtime when reading the context.
  """
  @spec load(String.t(), String.t()) :: t()
  def load(relative_path, repo_path) do
    %__MODULE__{
      path: relative_path,
      repo: repo_path
    }
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

      nodes = Enum.map(paths, &load(&1, repo_path))

      {:ok, nodes}
    else
      {:error, :invalid_path}
    end
  end

  def hierarchy_nodes(_relative_path, _repo_path) do
    {:error, :invalid_path}
  end

  # Reads the CONTEXT.md contract for a directory node.
  # Per the design spec, only directories have explicit CONTEXT.md files.
  # File-level context is handled implicitly by LLMs, not explicitly modeled.
  @spec read_context(t()) :: {:ok, String.t()} | {:error, term()}
  defp read_context(%__MODULE__{} = node) do
    abs_path = Path.expand(node.path, node.repo)

    if File.dir?(abs_path) do
      contract_path = Path.join(abs_path, "CONTEXT.md")
      File.read(contract_path)
    else
      # Files don't have explicit CONTEXT.md - LLMs handle file-level context naturally
      {:ok, ""}
    end
  end

  # Returns the relative path to the CONTEXT.md file for a directory node.
  # Per the design spec, only directories have explicit CONTEXT.md files.
  @spec context_file_path(t()) :: String.t()
  defp context_file_path(%__MODULE__{} = node) do
    abs_path = Path.expand(node.path, node.repo)

    if File.dir?(abs_path) do
      Path.join(node.path, "CONTEXT.md")
    else
      # Files don't have explicit context files
      nil
    end
  end

  @doc """
  Builds the string context representation for the AI by traversing the context tree.
  Per the design spec, only directories are included in the explicit context hierarchy.
  File-level context is handled implicitly by LLMs.
  """
  @spec build_context(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def build_context(relative_path, repo_path) do
    location_info =
      """
      Current Repository (worktree): '#{repo_path}'. The current working directory (cwd) is also set to the repository path.
      Current Assigned Node: '#{relative_path}'. You should be focusing on the context and files under this node.
      IMPORTANT: The worktree path might change as you get scheduled to run in different worktrees, but the cwd will always be set to the correct path.
        Therefore you should always use relative paths when referring to files in this repository.
      """
      |> String.trim_trailing()

    case hierarchy_nodes(relative_path, repo_path) do
      {:ok, nodes} ->
        context_contents =
          nodes
          # Only include directories in the explicit context hierarchy
          |> Enum.filter(fn node ->
            abs_path = Path.expand(node.path, node.repo)
            File.dir?(abs_path)
          end)
          |> Enum.map(fn node ->
            content =
              case read_context(node) do
                {:ok, c} -> c
                _ -> ""
              end

            file = context_file_path(node)

            truncated_content =
              if byte_size(content) > @context_max_bytes do
                require Logger
                Logger.warning("Content truncated for file: #{file}")
                binary_part(content, 0, @context_max_bytes) <> "\n... [Content Truncated] ..."
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
end
