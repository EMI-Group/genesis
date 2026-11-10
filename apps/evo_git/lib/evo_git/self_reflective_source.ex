defmodule EvoGit.SelfReflectiveSource do
  @moduledoc """
  Manages the local clone of the Genesis repository used by the self-reflective
  (repo-less) agent, and its reserved Virtual Context Tree (VCT) mount.

  The self-reflective agent reads the Genesis source/docs **read-only**. This
  module owns a shallow managed clone at `<data_dir>/genesis-source`
  (`source_dir/0`), declares it as the RESERVED VCT mount
  `vct:///genesis-source` (`point/0`, `system_mounts/0`, `ensure_mount/0`), and
  is the **single source of truth** for the source-root resolution chain
  (`reference_path/0`) consumed by both
  `EvoGit.Runtime.SelfReflective.source_root/0` and
  `EvoGit.AgentScheduler.Dispatch.resolve_repo_less_root/0`.

  The VCT mount is pure NAMESPACE metadata (`EvoGit.VCT`): it binds the reserved
  point to the managed dir's OS path but never creates a directory, never
  requires the path to exist, and is never listed as a user project (reserved
  mounts are invisible to `EvoGit.VCT.projects/1`/`search/2`, never evicted and
  never forgotten). Re-pointing that mount at another checkout is the supported
  way to override the source the agent reads.

  Public API (all pure local reads except `clone/0`/`update/0`, which touch
  the network via git):

    * `source_dir/0` — the managed clone location (overridable via the
      `:self_reflective_source_dir` app env, default
      `<data_dir>/genesis-source`).
    * `clone_url/0` — the upstream clone URL (overridable via the
      `:self_reflective_source_url` app env, default the GitHub repo).
    * `point/0` — the reserved VCT point (`"vct:///genesis-source"`).
    * `system_mounts/0` — the VCT `:system_mounts` entry declared at boot
      (pure, no I/O).
    * `ensure_mount/0` — registers/refreshes that mount (total, never raises).
    * `status/0` — a read-only snapshot of the managed dir and its mount state
      (never raises, never touches the network).
    * `clone/0` — shallow-clones the upstream into `source_dir/0`
      (`{:error, :already_cloned}` when the dir already exists) and then
      ensures the VCT mount best effort.
    * `update/0` — fetches + fast-forwards the managed clone
      (`{:error, :not_cloned}` / `{:error, :not_a_git_repo}` guards) and then
      ensures the VCT mount best effort.
    * `reference_path/0` — the resolution chain (see below).
    * `available?/0` — whether a usable Genesis source is available RIGHT NOW
      (pure local reads, no git subprocess — safe to call on every page load).
  """

  require Logger

  alias EvoGit.Adapters.Git
  alias EvoGit.VCT.Table

  @default_clone_url "https://github.com/EMI-Group/genesis.git"
  @genesis_source_point "vct:///genesis-source"
  @genesis_source_name "genesis-source"

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
  The RESERVED VCT point bound to the managed Genesis source checkout:
  `"vct:///genesis-source"`.

  Canonical (accepted by `EvoGit.VCT.Path.parse/1`) and constant — there is no
  app-env override, so the point is stable across boots and machines. Being
  outside `vct:///projects/<name>`, it is a reserved (system) mount: resolvable,
  but never listed as a project nor evicted.
  """
  @spec point() :: String.t()
  def point, do: @genesis_source_point

  @doc """
  The host-declared VCT `:system_mounts` entry for the managed source checkout:
  `[%{point: point(), path: source_dir(), name: "genesis-source"}]`.

  Pure (no I/O, no VCT call) — `EvoGit.Application` passes it to the
  `EvoGit.VCT` child spec so the reserved mount is ensured idempotently at boot.
  The recorded OS path need not exist yet (a checkout is provisioned later).
  """
  @spec system_mounts() :: [map()]
  def system_mounts do
    [%{point: point(), path: source_dir(), name: @genesis_source_name}]
  end

  @doc """
  Ensures the reserved VCT mount `point/0` binds `source_dir/0`
  (`name: "genesis-source"`).

  Idempotent: the same point holding the same normalized OS path is a no-op;
  a different path re-points the mount (same point). TOTAL and never raising —
  every failure (including an unreachable VCT server) is returned as
  `{:error, reason}`.

  Called best effort by `clone/0`/`update/0` after a successful clone/update, so
  a VCT problem can never turn a successful sync into an error.
  """
  @spec ensure_mount() :: {:ok, EvoGit.VCT.Mount.t()} | {:error, term()}
  def ensure_mount do
    EvoGit.VCT.ensure_mount(point(), source_dir(), name: @genesis_source_name)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
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
    * `point` — `point/0` (the reserved VCT point, always present)
    * `mounted` — `true` ONLY when the VCT currently binds `point/0` to
      `source_dir/0`; `false` whenever the VCT is unavailable or binds
      something else
  """
  @spec status() :: map()
  def status do
    dir = source_dir()
    exists = File.dir?(dir)
    is_git_repo = exists and git_repo?(dir)
    valid = is_git_repo and File.regular?(Path.join(dir, "CONTEXT.md"))
    reference = reference_path()

    %{
      dir: dir,
      exists: exists,
      is_git_repo: is_git_repo,
      valid: valid,
      commit: commit(dir, is_git_repo),
      branch: branch(dir, is_git_repo),
      version: version(dir),
      remote_url: remote_url(dir, is_git_repo),
      reference: reference,
      is_reference: dir == reference,
      point: point(),
      mounted: mounted?()
    }
  end

  @doc """
  Shallow-clones `clone_url/0` into `source_dir/0`.

  Returns `{:error, :already_cloned}` when the dir already exists (checked
  BEFORE cloning — the managed dir is never overwritten), or
  `{:ok, status/0}` on success. Shallow (`--depth 1`) is fine: the
  self-reflective agent only READS the tree, and `update/0` refreshes it.

  After a SUCCESSFUL clone the reserved VCT mount is ensured best effort
  (`ensure_mount/0`): a VCT failure is logged and never turns the clone into an
  error.
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
            {:ok, _} ->
              ensure_mount_after_sync()
              {:ok, status()}

            {:error, reason} ->
              {:error, reason}
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

  After a SUCCESSFUL update the reserved VCT mount is ensured best effort
  (`ensure_mount/0`): a VCT failure is logged and never turns the update into an
  error.
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
        case do_update(dir) do
          {:ok, _status} = ok ->
            ensure_mount_after_sync()
            ok

          other ->
            other
        end
    end
  end

  @doc """
  The SINGLE SOURCE OF TRUTH for the self-reflective source-root resolution
  chain, in order:

    1. `:self_reflective_source_root` app env (if non-empty binary)
    2. `GENESIS_SOURCE_ROOT` env var (if non-empty binary)
    3. the VCT mount at `point/0` (`vct:///genesis-source`) WHEN its path is a
       valid Genesis checkout (git repo + `CONTEXT.md` at root). Re-pointing
       that reserved mount is the supported "override". This step is SKIPPED
       entirely whenever the `:self_reflective_source_dir` app env seam is set,
       so hermetic tests stay deterministic.
    4. `source_dir/0` IF the dir exists AND is a valid Genesis checkout
       (git repo + `CONTEXT.md` at root) — auto-reference: cloning makes it
       the reference, no separate set-reference action
    5. `nil` (callers supply their own terminal fallback — see
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
            vct_reference() || managed_reference()
        end
    end
  end

  @doc """
  Whether a usable Genesis source is available to the self-reflective agent
  RIGHT NOW.

  Resolves the SAME source root the agent will actually use —
  `reference_path() || File.cwd!()` (the terminal fallback mirrors
  `EvoGit.Runtime.SelfReflective.source_root/0`) — and validates it is a Genesis
  checkout: the dir exists AND carries a `CONTEXT.md` at its root (the same
  validity rule as `status/0`'s `valid` field and `managed_reference/0`).

  Pure local reads ONLY: no git subprocesses (unlike `status/0`), no network,
  never raises — cheap enough to call on every page load.

  **LOCAL-NODE-ONLY**: resolves against the local BEAM's data dir
  (`source_dir/0`) + this process's environment; it is meaningless as a
  cross-node RPC answer (a remote daemon resolves its own source).
  """
  @spec available?() :: boolean()
  def available? do
    dir = reference_path() || File.cwd!()
    genesis_checkout?(dir)
  end

  # --- Private helpers ------------------------------------------------------
  # A managed clone is always a plain checkout, so `.git` is a directory. The
  # dir-based check is preferred over `git rev-parse --git-dir` because the
  # latter walks UP the tree and would report a non-repo dir nested inside
  # another git repo (e.g. the real Genesis checkout) as a git repo.
  defp git_repo?(dir), do: File.dir?(Path.join(dir, ".git"))

  # Step 3 of the reference chain: the reserved VCT mount qualifies only when
  # its path is a valid Genesis checkout (git repo + CONTEXT.md at root).
  # Skipped entirely while the `:self_reflective_source_dir` app env seam is set
  # so hermetic tests stay deterministic.
  defp vct_reference do
    if is_nil(Application.get_env(:evo_git, :self_reflective_source_dir)) do
      case EvoGit.VCT.resolve(point()) do
        {:ok, %EvoGit.VCT.Mount{path: path}} when is_binary(path) ->
          if git_repo?(path) and genesis_checkout?(path), do: path, else: nil

        _other ->
          nil
      end
    else
      nil
    end
  end

  # `mounted` in status/0: the VCT currently binds the reserved point to the
  # managed dir. False whenever the VCT is unavailable or binds another path.
  defp mounted? do
    case EvoGit.VCT.resolve(point()) do
      {:ok, %EvoGit.VCT.Mount{path: path}} when is_binary(path) ->
        Table.comparison_form(path) == Table.comparison_form(source_dir())

      _other ->
        false
    end
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  # Best effort after a successful clone/update: a VCT failure must NEVER turn
  # the sync into an error, so it is only logged.
  defp ensure_mount_after_sync do
    case ensure_mount() do
      {:ok, _mount} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "SelfReflectiveSource: could not ensure VCT mount #{point()}: #{inspect(reason)}"
        )
    end
  end

  # Step 4 of the reference chain: the managed dir qualifies only when it is
  # a valid Genesis checkout (git repo + CONTEXT.md at root). This mirrors the
  # `valid` field of status/0 without recursing through it.
  defp managed_reference do
    dir = source_dir()

    if git_repo?(dir) and genesis_checkout?(dir) do
      dir
    else
      nil
    end
  end

  # A usable Genesis source: the dir exists AND carries a CONTEXT.md at its
  # root. Shared by `vct_reference/0`, `managed_reference/0` and `available?/0`.
  defp genesis_checkout?(dir) do
    File.dir?(dir) and File.regular?(Path.join(dir, "CONTEXT.md"))
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
