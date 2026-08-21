defmodule EvoGit.SelfReflectiveSource do
  @moduledoc """
  Manages the local clone of the Genesis repository used by the self-reflective
  (repo-less) agent.

  The self-reflective agent reads the Genesis source/docs **read-only**. This
  module owns a shallow managed clone at `<data_dir>/genesis-source`
  (`source_dir/0`) and is the **single source of truth** for the source-root
  resolution chain (`reference_path/0`) consumed by both
  `EvoGit.Runtime.SelfReflective.source_root/0` and
  `EvoGit.AgentScheduler.Dispatch.resolve_repo_less_root/0`.

  Public API (all pure local reads except `clone/0`/`update/0`, which touch
  the network via git):

    * `source_dir/0` — the managed clone location (overridable via the
      `:self_reflective_source_dir` app env, default
      `<data_dir>/genesis-source`).
    * `clone_url/0` — the upstream clone URL (overridable via the
      `:self_reflective_source_url` app env, default the GitHub repo).
    * `status/0` — a read-only snapshot of the managed dir (never raises,
      never touches the network).
    * `clone/0` — shallow-clones the upstream into `source_dir/0`
      (`{:error, :already_cloned}` when the dir already exists).
    * `update/0` — fetches + fast-forwards the managed clone
      (`{:error, :not_cloned}` / `{:error, :not_a_git_repo}` guards).
    * `reference_path/0` — the resolution chain (see below).
  """

  alias EvoGit.Adapters.Git

  @default_clone_url "https://github.com/EMI-Group/genesis.git"

  @doc """
  The managed clone directory: `Path.join(EvoGit.Platform.data_dir(), "genesis-source")`.
  Overridable via the `:self_reflective_source_dir` app env (used by tests and
  hermetic deployments).
  """
  @spec source_dir() :: String.t()
  def source_dir do
    Application.get_env(:evo_git, :self_reflective_source_dir) ||
      Path.join(EvoGit.Platform.data_dir(), "genesis-source")
  end

  @doc """
  The upstream clone URL (default `https://github.com/EMI-Group/genesis.git`).
  Overridable via the `:self_reflective_source_url` app env.
  """
  @spec clone_url() :: String.t()
  def clone_url do
    Application.get_env(:evo_git, :self_reflective_source_url) || @default_clone_url
  end

  @doc """
  Read-only snapshot of the managed source dir. NEVER raises and NEVER touches
  the network — every field is a pure local read guarded by `case` on adapter
  tuples.

  Returns a map with:

    * `dir` — `source_dir/0`
    * `exists` — the dir exists (any kind)
    * `is_git_repo` — the dir has a `.git` directory
    * `valid` — `is_git_repo` AND a `CONTEXT.md` exists at the dir root
      (a Genesis checkout)
    * `commit` — short HEAD sha (`rev-parse --short HEAD`), nil on failure
    * `branch` — current branch, nil on failure
    * `version` — trimmed `VERSION` file content, nil when missing/unreadable
    * `remote_url` — `remote get-url origin`, nil on failure
    * `reference` — `reference_path/0` result
    * `is_reference` — `source_dir() == reference_path()`
  """
  @spec status() :: map()
  def status do
    dir = source_dir()
    exists = File.dir?(dir)
    is_git_repo = exists and git_repo?(dir)
    valid = is_git_repo and File.regular?(Path.join(dir, "CONTEXT.md"))

    %{
      dir: dir,
      exists: exists,
      is_git_repo: is_git_repo,
      valid: valid,
      commit: commit(dir, is_git_repo),
      branch: branch(dir, is_git_repo),
      version: version(dir),
      remote_url: remote_url(dir, is_git_repo),
      reference: reference_path(),
      is_reference: source_dir() == reference_path()
    }
  end

  @doc """
  Shallow-clones `clone_url/0` into `source_dir/0`.

  Returns `{:error, :already_cloned}` when the dir already exists (checked
  BEFORE cloning — the managed dir is never overwritten), or
  `{:ok, status/0}` on success. Shallow (`--depth 1`) is fine: the
  self-reflective agent only READS the tree, and `update/0` refreshes it.
  """
  @spec clone() :: {:ok, map()} | {:error, term()}
  def clone do
    dir = source_dir()

    if File.dir?(dir) do
      {:error, :already_cloned}
    else
      case File.mkdir_p(Path.dirname(dir)) do
        :ok ->
          case Git.clone(clone_url(), dir, ["--depth", "1"]) do
            {:ok, _} -> {:ok, status()}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, {:mkdir_failed, reason}}
      end
    end
  end

  @doc """
  Fetches + fast-forwards the managed clone to the upstream default branch.

  Guards: `{:error, :not_cloned}` when `source_dir/0` does not exist;
  `{:error, :not_a_git_repo}` when it exists but is not a git checkout.
  Otherwise returns `{:ok, status/0}`.

  The managed clone is created SHALLOW (`clone --depth 1`) and is a managed
  artifact (no local work — regenerated on demand), so the update strategy
  for a shallow checkout is `fetch --depth 1` + `reset --hard
  origin/<default-branch>`: a plain `fetch` + `merge --ff-only` cannot
  fast-forward across a shallow depth boundary, and resetting is safe because
  the dir carries no local work. A non-shallow checkout (e.g. a
  manually-created managed dir) uses the non-destructive `fetch` +
  `merge --ff-only origin/<branch>` path instead.
  """
  @spec update() :: {:ok, map()} | {:error, term()}
  def update do
    dir = source_dir()

    cond do
      not File.dir?(dir) ->
        {:error, :not_cloned}

      not git_repo?(dir) ->
        {:error, :not_a_git_repo}

      true ->
        do_update(dir)
    end
  end

  @doc """
  The SINGLE SOURCE OF TRUTH for the self-reflective source-root resolution
  chain, in order:

    1. `:self_reflective_source_root` app env (if non-empty binary)
    2. `GENESIS_SOURCE_ROOT` env var (if non-empty binary)
    3. `source_dir/0` IF the dir exists AND is a valid Genesis checkout
       (git repo + `CONTEXT.md` at root) — auto-reference: cloning makes it
       the reference, no separate set-reference action
    4. `nil` (callers supply their own terminal fallback — see
       `EvoGit.Runtime.SelfReflective.source_root/0` for `File.cwd!()` and
       `EvoGit.AgentScheduler.Dispatch` for `"[system]"`)

  Never raises.
  """
  @spec reference_path() :: String.t() | nil
  def reference_path do
    case Application.get_env(:evo_git, :self_reflective_source_root) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        case System.get_env("GENESIS_SOURCE_ROOT") do
          path when is_binary(path) and path != "" ->
            path

          _ ->
            managed_reference()
        end
    end
  end

  # --- Private helpers ------------------------------------------------------

  # A managed clone is always a plain checkout, so `.git` is a directory. The
  # dir-based check is preferred over `git rev-parse --git-dir` because the
  # latter walks UP the tree and would report a non-repo dir nested inside
  # another git repo (e.g. the real Genesis checkout) as a git repo.
  defp git_repo?(dir), do: File.dir?(Path.join(dir, ".git"))

  # Step 3 of the reference chain: the managed dir qualifies only when it is
  # a valid Genesis checkout (git repo + CONTEXT.md at root). This mirrors the
  # `valid` field of status/0 without recursing through it.
  defp managed_reference do
    dir = source_dir()

    if File.dir?(dir) and git_repo?(dir) and File.regular?(Path.join(dir, "CONTEXT.md")) do
      dir
    else
      nil
    end
  end

  defp commit(_dir, false), do: nil

  defp commit(dir, true) do
    case Git.rev_parse_short(dir) do
      {:ok, sha} -> sha
      _ -> nil
    end
  end

  defp branch(_dir, false), do: nil

  defp branch(dir, true) do
    case Git.current_branch(dir) do
      {:ok, name} -> name
      _ -> nil
    end
  end

  defp version(dir) do
    case File.read(Path.join(dir, "VERSION")) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp remote_url(_dir, false), do: nil

  defp remote_url(dir, true) do
    case Git.remote_url(dir) do
      {:ok, url} -> url
      _ -> nil
    end
  end

  defp do_update(dir) do
    if shallow?(dir) do
      update_shallow(dir)
    else
      update_full(dir)
    end
  end

  defp update_shallow(dir) do
    with {:ok, branch} <- Git.origin_default_branch(dir),
         {:ok, _} <- Git.fetch(dir, ["--depth", "1"]),
         {:ok, _} <- Git.reset_hard(dir, "origin/#{branch}") do
      {:ok, status()}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_full(dir) do
    with {:ok, _} <- Git.fetch(dir),
         {:ok, branch} <- tracked_branch(dir),
         {:ok, _} <- Git.merge_ff_only(dir, "origin/#{branch}") do
      {:ok, status()}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # The branch to fast-forward: the current branch when on a real branch, else
  # the origin default branch (detached HEAD).
  defp tracked_branch(dir) do
    case Git.current_branch(dir) do
      {:ok, "HEAD"} -> Git.origin_default_branch(dir)
      {:ok, branch} -> {:ok, branch}
      {:error, _} -> Git.origin_default_branch(dir)
    end
  end

  defp shallow?(dir) do
    case Git.run(["rev-parse", "--is-shallow-repository"], dir) do
      {:ok, "true"} -> true
      _ -> false
    end
  end
end
