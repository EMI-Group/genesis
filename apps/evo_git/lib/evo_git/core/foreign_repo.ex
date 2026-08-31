defmodule EvoGit.Core.ForeignRepo do
  @moduledoc """
  Represents a reference to a Git repository in the multi-repo system.

  Each repo has a unique `id` (string), an absolute `root` path, an optional
  `description`, a `writable` flag (default `false` — foreign repos are
  read-only unless explicitly marked writable), and an optional `base_sha`
  (per-repo starting commit, `nil` = HEAD).
  The primary repo always has id `"primary"`. Foreign repos have user-defined ids.

  ## Usage

  Foreign repos are configured in `genesis.toml` under the `[foreign_repos]` section:

      [foreign_repos.original]
      path = "/Source/original-proj"
      description = "The original monorepo"
      writable = true
      base_sha = "abc123"

      [foreign_repos.reference]
      path = "/Source/rust-rewrite-proj"
  """

  @enforce_keys [:id, :root]
  @derive {Jason.Encoder, only: [:id, :root, :description, :writable, :base_sha]}
  defstruct [:id, :root, :description, writable: false, base_sha: nil]

  alias EvoGit.Platform

  @type t :: %__MODULE__{
          id: String.t(),
          root: String.t(),
          description: String.t() | nil,
          writable: boolean(),
          base_sha: String.t() | nil
        }

  @doc """
  Creates a new ForeignRepo struct.

  ## Parameters
  - `id` - unique string identifier (e.g., `"primary"`, `"original"`)
  - `root` - absolute path to the repository root
  - `opts` - keyword options:
    - `:description` - human-readable description of the repo (optional, defaults to nil)
    - `:writable` - whether the repo is writable (optional, defaults to `false`;
      any non-`true` value is coerced to `false`)
    - `:base_sha` - per-repo starting commit (optional, defaults to `nil` = HEAD;
      blank/empty strings are treated as `nil`)

  ## Examples

      iex> ForeignRepo.new("primary", "/Source/my-project")
      %ForeignRepo{id: "primary", root: "/Source/my-project", description: nil, writable: false, base_sha: nil}

      iex> ForeignRepo.new("original", "/Source/legacy-proj", description: "The legacy codebase")
      %ForeignRepo{id: "original", root: "/Source/legacy-proj", description: "The legacy codebase"}

      iex> ForeignRepo.new("original", "/Source/legacy-proj", writable: true, base_sha: "abc123")
      %ForeignRepo{id: "original", root: "/Source/legacy-proj", description: nil, writable: true, base_sha: "abc123"}
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(id, root, opts \\ []) when is_binary(id) and is_binary(root) do
    root = Platform.safe_expand(root)

    %__MODULE__{
      id: id,
      root: root,
      description: Keyword.get(opts, :description),
      writable: writable?(Keyword.get(opts, :writable)),
      base_sha: coerce_base_sha(Keyword.get(opts, :base_sha))
    }
  end

  @doc """
  Normalizes any persisted/CLI foreign-repo shape into a `%ForeignRepo{}` struct.

  Returns the struct, or `nil` when the input is unparseable (non-map input,
  missing/empty `id`, or no root under any of `"root"`/`"path"`/`:root`/`:path`).
  Callers that map a list through this function drop the `nil` entries.

  ## Why this exists

  `TaskInfo.opts` are persisted to SQLite via `EvoGit.Store.Codec.encode_opts/1`.
  Because `%ForeignRepo{}` derives `Jason.Encoder`, the JSON round-trip returns
  `:foreign_repos` entries as STRING-keyed maps
  (`%{"id" => ..., "root" => ..., "description" => ..., "writable" => ...,
  "base_sha" => ...}`). Code that dot-accesses `.id`/`.root` on those raw maps
  (e.g. `EvoGit.Runtime.Helpers.merge_foreign_repos/2`)
  crashes with a `KeyError`. This function coerces every persisted/CLI shape back
  into a struct before use. `EvoGit.TaskRegistry.MergeContext` and
  `EvoGit.Runtime.Helpers` apply it centrally.

  Missing `"writable"`/`"base_sha"` keys (legacy persisted rows) default to
  `false`/`nil`.

  ## Examples

      iex> ForeignRepo.normalize(%ForeignRepo{id: "a", root: "/abs/a"})
      %ForeignRepo{id: "a", root: "/abs/a", description: nil, writable: false, base_sha: nil}

      iex> ForeignRepo.normalize(%{"id" => "a", "root" => "/abs/a", "description" => "desc"})
      %ForeignRepo{id: "a", root: "/abs/a", description: "desc", writable: false, base_sha: nil}

      iex> ForeignRepo.normalize(%{"id" => "a", "root" => "/abs/a", "writable" => true, "base_sha" => "abc123"})
      %ForeignRepo{id: "a", root: "/abs/a", description: nil, writable: true, base_sha: "abc123"}

      iex> ForeignRepo.normalize(%{id: "a", path: "/abs/a"})
      %ForeignRepo{id: "a", root: "/abs/a", description: nil, writable: false, base_sha: nil}

      iex> ForeignRepo.normalize(%{"id" => "a"})
      nil
  """
  @spec normalize(term()) :: t() | nil
  def normalize(%__MODULE__{} = repo), do: repo

  def normalize(repo) when is_map(repo) do
    id = Map.get(repo, "id") || Map.get(repo, :id)

    root =
      Map.get(repo, "root") || Map.get(repo, "path") || Map.get(repo, :root) ||
        Map.get(repo, :path)

    description = Map.get(repo, "description") || Map.get(repo, :description)

    with true <- is_binary(id) and id != "",
         true <- is_binary(root) and root != "" do
      opts =
        if is_binary(description) and description != "", do: [description: description], else: []

      writable = Map.get(repo, "writable", Map.get(repo, :writable, false))
      base_sha = Map.get(repo, "base_sha") || Map.get(repo, :base_sha)

      new(id, root, Keyword.merge(opts, writable: writable, base_sha: base_sha))
    else
      _ -> nil
    end
  end

  def normalize(_other), do: nil

  # Coerces a `writable` opt to a boolean: only the literal `true` is writable;
  # anything else (nil, non-boolean values) is coerced to `false` rather than
  # crashing on an invalid persisted/CLI value.
  defp writable?(value), do: value == true

  # Coerces a `base_sha` opt to a non-blank string or nil. Blank/whitespace-only
  # strings and non-string values are treated as nil (= HEAD).
  defp coerce_base_sha(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp coerce_base_sha(_other), do: nil

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
    # Normalize both paths for safe comparison (strip trailing separators)
    root = root |> Platform.trim_trailing_separators()
    abs_path = Platform.safe_expand(abs_path)

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
    abs_path = Platform.safe_expand(abs_path)

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
    |> Platform.trim_leading_separators()
    |> Platform.trim_trailing_separators()
    |> then(fn
      "" -> "./"
      "." -> "./"
      p -> if String.starts_with?(p, "./"), do: p, else: "./" <> p
    end)
  end
end
