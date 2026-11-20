defmodule EvoDashWeb.ProjectsLive.ForeignRepos do
  @moduledoc """
  Node-aware foreign-repository helpers for the `EvoDashWeb.ProjectsLive`
  project settings panel.

  Path validation and `%EvoGit.Core.ForeignRepo{}` construction differ per node:
  a remote context must never `Path.expand/1` a path against the DASHBOARD's OS
  (a POSIX path on a remote Linux daemon would be wrongly rejected/managed by a
  Windows dashboard, and vice versa), while local contexts keep
  `ForeignRepo.new/3`'s exact expansion semantics — except Windows UNC / WSL
  roots on a non-Windows node, which are stored verbatim.

  Everything here is a pure helper over the page's assigns map (no socket
  mutation): the page keeps the foreign-repo events and their assigns.
  """
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDash.NodeContext
  alias EvoDash.SafeCall
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Platform
  alias EvoDashWeb.ProjectsLive.ProjectFlow

  @doc """
  Sorts repos primary-first, then by id (the page's one ordering rule for the
  list rendered in project settings).
  """
  @spec sort_by_primary([%ForeignRepo{}]) :: [%ForeignRepo{}]
  def sort_by_primary(repos) do
    Enum.sort_by(repos, fn repo ->
      {if(ForeignRepo.primary?(repo.id), do: 0, else: 1), repo.id}
    end)
  end

  @doc """
  True when the viewed node is a remote one (an explicit remote context or a
  resolved BEAM node other than this one).
  """
  @spec remote_context?(map()) :: boolean()
  def remote_context?(assigns) do
    Map.get(assigns, :remote?) == true or Map.get(assigns, :current_node) != node()
  end

  @doc """
  Node-aware absolute-path predicate.

  A POSIX path on a remote Linux daemon is wrongly rejected by the local-only
  `Platform.absolute_path?/1` on a Windows dashboard (`Path.type/1` →
  `:volumerelative`), and vice versa, so remote contexts use the shared
  node-aware predicate. Both branches ACCEPT Windows UNC / WSL roots —
  `//wsl.localhost/Ubuntu-22.04/...`, `\\\\server\\share\\...` and drive
  letters — via `EvoGit.Platform.absolute_path?/1`.
  """
  @spec path_absolute?(map(), String.t()) :: boolean()
  def path_absolute?(assigns, path) do
    if remote_context?(assigns) do
      ProjectFlow.absolute_path_for_node?(Map.get(assigns, :current_node), path)
    else
      Platform.absolute_path?(path)
    end
  end

  # ── UNC/WSL foreign-repo storage guard ─────────────────────────────────
  # `EvoGit.Core.ForeignRepo.new/3` `Path.expand`s its root internally. On a
  # WINDOWS node that is safe for UNC roots — Elixir's `Path.expand` preserves
  # a `//`-prefixed UNC root and normalizes the `\\server\share` form to
  # `//server/share`. On a NON-Windows node it corrupts them:
  # `Path.expand("//wsl.localhost/x")` collapses the prefix to
  # `/wsl.localhost/x`, and `Path.expand("\\server\share\x")` is cwd-joined
  # against the dashboard's working directory. UNC/WSL roots must therefore
  # NEVER pass through `ForeignRepo.new/3` on a non-Windows node — they are
  # stored verbatim (forward-slash-normalized, trailing separators trimmed)
  # with the same returned struct shape.
  @doc """
  True for a `//`- or `\\\\`-prefixed (UNC / WSL) path.
  """
  @spec unc_prefixed?(term()) :: boolean()
  def unc_prefixed?(path) when is_binary(path) do
    String.starts_with?(path, "//") or String.starts_with?(path, "\\\\")
  end

  def unc_prefixed?(_path), do: false

  @doc """
  Normalizes a verbatim UNC root (separators + trailing separators), keeping a
  bare `//` root intact.
  """
  @spec normalize_unc_root(String.t()) :: String.t()
  def normalize_unc_root(path) do
    normalized =
      path
      |> Platform.normalize_separators()
      |> Platform.trim_trailing_separators()

    if normalized == "", do: "//", else: normalized
  end

  @doc """
  `ForeignRepo.new/3` with the UNC-expansion guard: UNC/WSL roots on a
  non-Windows node bypass the internal `Path.expand/1` (which would mangle the
  `//`/`\\\\` prefix against the local OS) and build the same struct shape with
  the verbatim root; every other input keeps `ForeignRepo.new/3`'s exact
  expansion and `writable`/`base_sha` coercion semantics.
  """
  @spec new_guarded(String.t(), String.t(), keyword()) :: %ForeignRepo{}
  def new_guarded(id, root, opts) do
    if unc_prefixed?(root) and not Platform.windows?() do
      %ForeignRepo{
        id: id,
        root: normalize_unc_root(root),
        description: Keyword.get(opts, :description),
        writable: Keyword.get(opts, :writable, false),
        base_sha: Keyword.get(opts, :base_sha)
      }
    else
      ForeignRepo.new(id, root, opts)
    end
  end

  @doc """
  Node-aware `%ForeignRepo{}` construction with the UNC guard: local nodes go
  through `new_guarded/3` (== `ForeignRepo.new/3` except UNC roots are never
  `Path.expand`ed against the local OS); remote nodes keep
  `ProjectFlow.build_foreign_repo/4`'s verbatim raw-struct behavior.
  """
  @spec build_for_node(node() | nil, String.t(), String.t(), keyword()) :: %ForeignRepo{}
  def build_for_node(node, repo_id, path, opts) do
    if node == nil or node == node() do
      new_guarded(repo_id, path, opts)
    else
      ProjectFlow.build_foreign_repo(node, repo_id, path, opts)
    end
  end

  @doc """
  Validates a foreign-repo path + optional base_sha for the node being viewed.
  Returns `:ok` or `{:error, flash_message}`.

  Shared by the page's `add_foreign_repo` and `save_foreign_repo` handlers so
  both entry points enforce IDENTICAL rules (real checks, never crashes —
  cond/case only, no try/rescue):

    - path non-blank + absolute (the existing checks)
    - existence: local → `File.dir?/1`; remote → `NodeContext.dir?/2`
    - git-ness:  local → core `EvoGit.Adapters.Git.rev_parse/1` (NEVER shell
      out); remote → `NodeContext.list_branches/2`
    - base_sha resolvability (when non-nil): local → `rev_parse(path, sha)`;
      REMOTE base_sha check deliberately SKIPPED — NodeContext exposes no
      ref-resolution wrapper (verified), and the core's up-front task-start
      validation (`Runtime.Helpers.load_foreign_repos/2`) still raises
      ArgumentError for a bad remote base_sha, failing the task before any
      agent spawns (see projects_live/CONTEXT.md).
  """
  @spec validate_input(map(), String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def validate_input(assigns, path, base_sha) do
    remote_context? = remote_context?(assigns)
    node = if remote_context?, do: Map.get(assigns, :current_node), else: node()

    cond do
      path == "" ->
        {:error, gettext("Path cannot be empty.")}

      not path_absolute?(assigns, path) ->
        {:error, gettext("Path must be absolute.")}

      not path_exists?(node, remote_context?, path) ->
        {:error, gettext("Foreign repo path does not exist: %{path}", path: path)}

      not git_repo?(node, remote_context?, path) ->
        {:error, gettext("Path is not a git repository: %{path}", path: path)}

      is_binary(base_sha) and base_sha != "" and remote_context? ->
        # Remote base_sha check skipped by design (see function doc). The
        # core's task-start ArgumentError still catches bad values.
        :ok

      is_binary(base_sha) and base_sha != "" ->
        case EvoGit.Adapters.Git.rev_parse(path, base_sha) do
          {:ok, _} ->
            :ok

          _ ->
            {:error,
             gettext("Base commit %{base_sha} not found in repository: %{path}",
               base_sha: base_sha,
               path: path
             )}
        end

      true ->
        :ok
    end
  end

  @doc """
  Converts a previous task's `opts[:foreign_repos]` into `%ForeignRepo{}`
  structs, tolerating every persisted shape:

    - fresh `%ForeignRepo{}` structs (from an in-memory task)
    - maps with a `"root"` key (Jason-decoded from the DB)
    - maps with a `"path"` key (sessionStorage serialization format, fallback)
  """
  @spec from_task_opts(term()) :: [%ForeignRepo{}]
  def from_task_opts(nil), do: []
  def from_task_opts([]), do: []

  def from_task_opts(repos) when is_list(repos) do
    repos
    |> Enum.map(fn
      %ForeignRepo{} = repo ->
        repo

      repo when is_map(repo) ->
        id = Map.get(repo, "id") || Map.get(repo, :id) || "primary"
        root = Map.get(repo, "root") || Map.get(repo, "path") || Map.get(repo, :root)
        desc = Map.get(repo, "description") || Map.get(repo, :description)

        # Read-write foreign repos: thread `writable` and `base_sha`
        # through the guarded constructor (which for non-UNC inputs
        # is `ForeignRepo.new/3` — it coerces/validates them: only
        # literal true is writable, blank base_sha → nil). The UNC
        # guard keeps `//wsl.localhost/...` / `\\server\share\...`
        # roots verbatim on non-Windows nodes — `ForeignRepo.new/3`'s
        # `Path.expand` would collapse/cwd-join them (see
        # `new_guarded/3`).
        # Tolerant writable check for string-keyed persisted shapes.
        writable = Map.get(repo, "writable", Map.get(repo, :writable, false))

        base_sha = Map.get(repo, "base_sha") || Map.get(repo, :base_sha)

        opts =
          if(is_binary(desc) and desc != "",
            do: [description: desc],
            else: []
          )
          |> Keyword.put(:writable, writable == true or writable == "true")
          |> then(fn o ->
            if is_binary(base_sha) and base_sha != "",
              do: Keyword.put(o, :base_sha, base_sha),
              else: o
          end)

        new_guarded(id, root, opts)

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> sort_by_primary()
  end

  def from_task_opts(_other), do: []

  # Both remote probes run through `EvoDash.SafeCall`: they are cross-node
  # RPCs whose target can be dead/unreachable, and an exited call would
  # otherwise crash the LiveView. A failure reads as "not a directory" /
  # "not a git repository" so the caller renders its normal VALIDATION error
  # instead of the page dying.
  defp path_exists?(node, true, path) do
    SafeCall.run(fn -> NodeContext.dir?(node, path) end, false)
  end

  defp path_exists?(_node, false, path), do: File.dir?(path)

  defp git_repo?(node, true, path) do
    case SafeCall.run(fn -> NodeContext.list_branches(node, path) end, {:error, :unavailable}) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp git_repo?(_node, false, path) do
    match?({:ok, _}, EvoGit.Adapters.Git.rev_parse(path))
  end
end
