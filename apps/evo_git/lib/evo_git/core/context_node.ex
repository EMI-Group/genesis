defmodule EvoGit.Core.ContextNode do
  @moduledoc """
  Represents a node in the Spatial Dimension (the Context Tree).

  The type (:directory or :file) is determined at runtime, not at creation time,
  because the node may be created before the path exists in the filesystem.

  ## Multi-repo support

  The `repo_id` field identifies which repository this node belongs to in a
  multi-repo setup.  It defaults to `"primary"` for single-repo usage and is
  threaded through `load/3` and `hierarchy_nodes/3` when working with foreign
  repositories.
  """
  @enforce_keys [:path, :repo]
  defstruct [:path, :repo, repo_id: "primary"]

  alias EvoGit.Adapters.Git
  alias EvoGit.Platform

  @type t :: %__MODULE__{
          path: String.t(),
          repo: String.t(),
          repo_id: String.t()
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
  defp check_path_ignored(path, repo_path) when is_binary(path) and path not in [".", "./"] do
    abs_path = Path.expand(path, repo_path)

    # First, check the current path
    case Git.check_ignore(repo_path, [abs_path]) do
      {:ok, [_ | _]} ->
        true

      {:ok, []} ->
        # If current path is not ignored, check parent directory recursively
        check_path_ignored(Path.dirname(path), repo_path)

      _ ->
        false
    end
  end

  defp check_path_ignored(_, _) when true, do: false

  @doc """
  Normalizes a relative path to canonical "./foo/bar" format.

  Rules:
  - Raises if the path is absolute (Unix: /foo, Windows: C:\\foo)
  - Strips leading/trailing slashes
  - `""` → `"./"`, `"."` → `"./"`
  - If already starts with `"./"`, keeps as-is
  - Otherwise prepends `"./"`
  """
  @spec normalize_relpath(String.t()) :: String.t()
  def normalize_relpath(path) when is_binary(path) do
    if EvoGit.Platform.absolute_path?(path) do
      raise "normalize_relpath expects a relative path, got absolute: #{inspect(path)}"
    end

    normalized = path |> Platform.normalize_separators() |> Platform.trim_separators()

    cond do
      normalized in ["", "."] -> "./"
      String.starts_with?(normalized, "./") -> normalized
      true -> "./" <> normalized
    end
  end

  @doc """
  Loads a ContextNode from a given relative path within a repository.
  `relative_path` must be relative to `repo_path` (or "./" for root).
  `repo_path` must be the absolute path to the repository root.

  Note: This does not check if the path exists or determine its type,
  because the node may represent a path that doesn't exist yet at creation time.
  Type is determined at runtime when reading the context.
  """
  @spec load(String.t(), String.t()) :: t()
  def load(relative_path, repo_path) do
    load(relative_path, repo_path, "primary")
  end

  @doc """
  Loads a ContextNode with an explicit `repo_id` for multi-repo support.
  """
  @spec load(String.t(), String.t(), String.t()) :: t()
  def load(relative_path, repo_path, repo_id) do
    %__MODULE__{
      path: normalize_relpath(relative_path),
      repo: repo_path,
      repo_id: repo_id
    }
  end

  @doc """
  Retrieves the full hierarchy of ContextNodes from the project root down to the given relative path.
  `relative_path` must be relative to the root of the repository.
  `repo_path` must be the absolute path to the repository root.
  Nodes that do not exist in the filesystem are excluded from the result list.
  """
  @spec hierarchy_nodes(String.t(), String.t()) :: {:ok, [t()]} | {:error, term()}
  def hierarchy_nodes(relative_path, repo_path) do
    hierarchy_nodes(relative_path, repo_path, "primary")
  end

  @doc """
  Retrieves the full hierarchy of ContextNodes from the project root down to the given relative path,
  with an explicit `repo_id` for multi-repo support.
  """
  @spec hierarchy_nodes(String.t(), String.t(), String.t()) :: {:ok, [t()]} | {:error, term()}
  def hierarchy_nodes(relative_path, repo_path, repo_id)
      when is_binary(relative_path) and is_binary(repo_path) and is_binary(repo_id) do
    if Path.type(relative_path) == :relative and not String.starts_with?(relative_path, "..") do
      paths =
        if relative_path in [".", "./"] do
          ["./"]
        else
          normalized = normalize_relpath(relative_path)

          # Path.split("./foo/bar") = [".", "foo", "bar"]
          [_dot | parts] = Path.split(normalized)
          # Build ["./", "./foo", "./foo/bar"]
          ["./" | Enum.scan(parts, "./", fn part, acc -> Path.join(acc, part) end)]
        end

      nodes = Enum.map(paths, &load(&1, repo_path, repo_id))

      {:ok, nodes}
    else
      {:error, :invalid_path}
    end
  end

  def hierarchy_nodes(_relative_path, _repo_path, _repo_id) do
    {:error, :invalid_path}
  end

  @doc """
  Builds the string context representation for the AI by traversing the context tree.
  Per the design spec, only directories are included in the explicit context hierarchy.
  File-level context is handled implicitly by LLMs.

  YAML front matter (delimited by `---`) in CONTEXT.md files is stripped before
  inclusion. The front matter is used for metadata like skill configuration and
  is not part of the visible context tree.
  """
  @spec build_context(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def build_context(relative_path, repo_path) do
    case hierarchy_nodes(relative_path, repo_path) do
      {:ok, nodes} ->
        context_max = context_max_bytes()

        context_contents =
          nodes
          # Only include directories in the explicit context hierarchy.
          # Compute abs_path once per node and thread it through.
          |> Enum.flat_map(fn %__MODULE__{} = node ->
            abs_path = Path.expand(node.path, node.repo)

            if File.dir?(abs_path) do
              content =
                case File.read(Path.join(abs_path, "CONTEXT.md")) do
                  {:ok, c} -> c
                  _ -> ""
                end

              file =
                if node.path == "./" do
                  "./CONTEXT.md"
                else
                  Path.join(node.path, "CONTEXT.md")
                end

              # Strip YAML front matter before presenting to agents
              display_content = EvoGit.Skills.strip_front_matter(content)

              # UTF-8-safe truncation: backs up from the cut point to a
              # valid character boundary so we never split a multi-byte
              # codepoint (which would produce invalid UTF-8 that crashes
              # Jason.encode! in the LLM request pipeline).
              truncated_content =
                if byte_size(display_content) > context_max do
                  require Logger
                  Logger.warning("Content truncated for file: #{file}")
                  EvoGit.UTF8.safe_binary_part(display_content, 0, context_max) <>
                    "\n... [Content Truncated] ..."
                else
                  display_content
                end

              ["File: #{file}\n```\n#{truncated_content}\n```"]
            else
              []
            end
          end)
          |> Enum.join("\n\n")

        location_info =
          """
          Current Repository (worktree): '#{repo_path}'. The current working directory (cwd) is also set to the repository path.
          Current Assigned Node: '#{relative_path}'. You should be focusing on the context and files under this node.
          IMPORTANT: The worktree path is fixed for this agent's lifetime and the cwd is set to it. Always use relative paths when referring to files in this repository.
          IMPORTANT: Subagents you spawn each get their OWN isolated worktree with cwd automatically set correctly. Never include worktree paths or `cd` commands in subagent objectives — just tell them what to do (e.g., "run `mix test`").
          """
          |> String.trim_trailing()

        if context_contents == "" do
          {:ok, location_info}
        else
          {:ok, "# Context Tree\n" <> context_contents <> "\n\n" <> location_info}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds the context tree AND extracts hierarchical skill names in a single pass.

  Returns `{:ok, context_string, skill_names}` or `{:error, reason}`.
  `skill_names` is a deduplicated list of skill name strings inherited from
  root to the given node.
  """
  @spec build_context_with_skills(String.t(), String.t()) ::
          {:ok, String.t(), [String.t()]} | {:error, term()}
  def build_context_with_skills(relative_path, repo_path) do
    with {:ok, context} <- build_context(relative_path, repo_path) do
      skill_names = EvoGit.Skills.hierarchical_skill_names(relative_path, repo_path)
      {:ok, context, skill_names}
    end
  end

  defp context_max_bytes do
    EvoGit.Config.resolve([:truncation, :context_max_bytes])
  end
end
