defmodule EvoGit.Core.ForeignRepo do
  @moduledoc """
  Represents a reference to a Git repository in the multi-repo system.

  Each repo has a unique `id` (string), an absolute `root` path, and an optional `description`.
  The primary repo always has id `"primary"`. Foreign repos have user-defined ids.

  ## Usage

  Foreign repos are configured in `genesis.toml` under the `[foreign_repos]` section:

      [foreign_repos.original]
      path = "/Source/original-proj"
      description = "The original monorepo"

      [foreign_repos.reference]
      path = "/Source/rust-rewrite-proj"
  """

  @enforce_keys [:id, :root]
  defstruct [:id, :root, :description]

  @type t :: %__MODULE__{
          id: String.t(),
          root: String.t(),
          description: String.t() | nil
        }

  @doc """
  Creates a new ForeignRepo struct.

  ## Parameters
  - `id` - unique string identifier (e.g., `"primary"`, `"original"`)
  - `root` - absolute path to the repository root
  - `opts` - keyword options:
    - `:description` - human-readable description of the repo (optional, defaults to nil)

  ## Examples

      iex> ForeignRepo.new("primary", "/Source/my-project")
      %ForeignRepo{id: "primary", root: "/Source/my-project", description: nil}

      iex> ForeignRepo.new("original", "/Source/legacy-proj", description: "The legacy codebase")
      %ForeignRepo{id: "original", root: "/Source/legacy-proj", description: "The legacy codebase"}
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(id, root, opts \\ []) when is_binary(id) and is_binary(root) do
    root = Path.expand(root)

    %__MODULE__{
      id: id,
      root: root,
      description: Keyword.get(opts, :description)
    }
  end

  @doc """
  Returns the primary repo identifier.
  """
  @spec primary_id() :: String.t()
  def primary_id, do: "primary"

  @doc """
  Checks if the given repo id is the primary repo.
  """
  @spec primary?(String.t()) :: boolean()
  def primary?(id), do: id == "primary"

  @doc """
  Normalizes an absolute path to a relative path within this repo.

  Returns `{:ok, relative_path}` if the path is within this repo, or
  `{:error, :not_in_repo}` if it's outside.

  ## Examples

      iex> repo = ForeignRepo.new("primary", "/Source/proj")
      iex> ForeignRepo.normalize_path(repo, "/Source/proj/src/lib.rs")
      {:ok, "./src/lib.rs"}

      iex> repo = ForeignRepo.new("primary", "/Source/proj")
      iex> ForeignRepo.normalize_path(repo, "/other/path")
      {:error, :not_in_repo}
  """
  @spec normalize_path(t(), String.t()) :: {:ok, String.t()} | {:error, :not_in_repo}
  def normalize_path(%__MODULE__{root: root}, abs_path) when is_binary(abs_path) do
    # Normalize both paths for safe comparison (strip trailing slashes)
    root = root |> String.trim_trailing("/") |> String.trim_trailing("\\")
    abs_path = Path.expand(abs_path)

    if String.starts_with?(abs_path, root) and
         (abs_path == root or EvoGit.Platform.path_next_is_separator?(abs_path, byte_size(root))) do
      relative = Path.relative_to(abs_path, root)
      {:ok, normalize_relative(relative)}
    else
      {:error, :not_in_repo}
    end
  end

  @doc """
  Given a list of ForeignRepo structs and an absolute path, determines which repo
  the path belongs to and returns the repo id along with the relative path.

  Returns `{:ok, repo_id, relative_path}` or `{:error, :not_in_any_repo}`.

  The primary repo is checked last, so foreign repos take precedence if paths
  overlap (unlikely but possible).
  """
  @spec resolve_path([t()], String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :not_in_any_repo}
  def resolve_path(repos, abs_path) when is_list(repos) and is_binary(abs_path) do
    abs_path = Path.expand(abs_path)

    # Check foreign repos first, then primary (split_with avoids O(n log n) sort)
    {foreign, primary} = Enum.split_with(repos, fn %__MODULE__{id: id} -> not primary?(id) end)
    sorted = foreign ++ primary

    Enum.find_value(sorted, {:error, :not_in_any_repo}, fn %__MODULE__{} = repo ->
      case normalize_path(repo, abs_path) do
        {:ok, rel_path} -> {:ok, repo.id, rel_path}
        {:error, :not_in_repo} -> nil
      end
    end)
  end

  @doc """
  Checks if a path string is absolute.
  Handles both Unix (/foo) and Windows (C:\\foo, D:/bar) paths.
  Returns false for nil or non-binary values.
  """
  @spec absolute_path?(String.t() | nil) :: boolean()
  def absolute_path?(path) when is_binary(path) do
    EvoGit.Platform.absolute_path?(path)
  end

  def absolute_path?(_other), do: false

  # Normalizes a relative path to "./foo/bar" format
  defp normalize_relative(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> then(fn
      "" -> "./"
      "." -> "./"
      p -> if String.starts_with?(p, "./"), do: p, else: "./" <> p
    end)
  end
end
