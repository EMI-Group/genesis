defmodule EvoGit.SelfReflectiveSource do
  @moduledoc """
  Manages the Genesis source checkout read by the self-reflective (repo-less)
  agent, and its reserved Virtual Context Tree (VCT) mount.

  ## Source mode: release clone vs running checkout

  In **release** mode the source root is the shallow managed clone at
  `<data_dir>/genesis-source` (`managed_dir/0`), provisioned by `clone/0` and
  refreshed by `update/0`.
  In **source** mode — a dev checkout run through `mix run`, `iex -S mix` or
  `mix phx.server` — the source root is the checkout the running instance was
  BUILT FROM (`running_source_dir/0`), discovered by walking up from
  `Application.app_dir(:evo_git)` to the umbrella root
  (`source_root_from_app_dir/1`).
  `source_mode/0` decides which mode applies and `source_dir/0` is the ONE
  accessor both paths go through.
  In release mode a boot-time version check (`maybe_sync_on_boot/0` →
  `sync_needed?/0` → `sync_now/0`) auto-pulls the managed clone when its
  `VERSION` differs from the running release version.

  The self-reflective agent reads the Genesis source/docs **read-only**.
  This module declares the source root as the RESERVED VCT mount
  `vct:///genesis-source` (`point/0`, `system_mounts/0`, `ensure_mount/0`), and
  is the **single source of truth** for the source-root resolution chain
  (`reference_path/0`) consumed by both
  `EvoGit.Runtime.SelfReflective.source_root/0` and
  `EvoGit.AgentScheduler.Dispatch.resolve_repo_less_root/0`.

  The VCT mount is pure NAMESPACE metadata (`EvoGit.VCT`): it binds the reserved
  point to the source root's OS path but never creates a directory, never
  requires the path to exist, and is never listed as a user project (reserved
  mounts are invisible to `EvoGit.VCT.projects/1`/`search/2`, never evicted and
  never forgotten). Re-pointing that mount at another checkout is the supported
  way to override the source the agent reads.

  Public API (all pure local reads except `clone/0`/`update/0`/`sync_now/0`,
  which touch the network via git):

    * `source_mode/0` — `:source` for a dev checkout, `:release` otherwise.
    * `running_from_source?/0` — `source_mode() == :source`.
    * `running_source_dir/0` — the checkout the running instance was built from.
    * `source_root_from_app_dir/1` — the pure ancestor walk behind it.
    * `source_dir/0` — the Genesis source root this instance reads (the
      `:self_reflective_source_dir` app env wins, then the running checkout in
      `:source` mode, else `managed_dir/0`).
    * `managed_dir/0` — the managed clone location,
      `Path.join(EvoGit.Platform.data_dir(), "genesis-source")`.
    * `clone_url/0` — the upstream clone URL (overridable via the
      `:self_reflective_source_url` app env, default the GitHub repo).
    * `point/0` — the reserved VCT point (`"vct:///genesis-source"`).
    * `system_mounts/0` — the VCT `:system_mounts` entry declared at boot
      (pure, no I/O).
    * `ensure_mount/0` — registers/refreshes that mount (total, never raises).
    * `status/0` — a read-only snapshot of the source dir and its mount state
      (never raises, never touches the network).
    * `clone/0` — shallow-clones the upstream into `source_dir/0`
      (`{:error, :already_cloned}` when the dir already exists) and then
      ensures the VCT mount best effort; refuses in `:source` mode.
    * `update/0` — fetches + fast-forwards the managed clone
      (`{:error, :not_cloned}` / `{:error, :not_a_git_repo}` guards) and then
      ensures the VCT mount best effort; refuses in `:source` mode.
    * `running_version/0` — the running `:evo_git` application version.
    * `sync_needed?/0` — whether the managed clone's `VERSION` differs from it.
    * `sync_now/0` — one synchronous shallow auto-pull (`:in_sync` when none is
      needed).
    * `maybe_sync_on_boot/0` — the total, non-blocking boot hook for it.
    * `reference_path/0` — the resolution chain (see below).
    * `available?/0` — whether a usable Genesis source is available RIGHT NOW
      (pure local reads, no git subprocess — safe to call on every page load).
  """

  require Logger

  alias EvoGit.Adapters.Git
  alias EvoGit.VCT.Table

  # Compile-time Mix env, the established pattern in `EvoGit.Application`: the
  # whole ExUnit suite runs FROM the checkout, so without this pin every test
  # would resolve `:source` mode and read (or attempt to sync) the developer's
  # real tree instead of the per-test fixtures — the suite must stay hermetic.
  @mix_env Mix.env()

  @default_clone_url "https://github.com/EMI-Group/genesis.git"
  @genesis_source_point "vct:///genesis-source"
  @genesis_source_name "genesis-source"
  # Ancestor levels walked up from a release/dev app dir: `<repo>/_build/dev/lib/
  # evo_git` needs four, so six is the documented floor and eight the walk.
  @source_walk_up_levels 8

  @doc """
  The source mode of THIS instance: `:source` for a dev checkout, `:release`
  otherwise.

  Resolution order:

    1. the `:self_reflective_source_mode` app env when it is `:source` or
       `:release` (test/ops seam)
    2. `:release` when this module was compiled in `:test` — the ExUnit suite
       runs from the checkout and must stay hermetic
    3. `:source` when `running_source_dir/0` finds a Genesis umbrella checkout
       above the running app dir
    4. `:release`

  Never raises.
  """
  @spec source_mode() :: :source | :release
  def source_mode do
    case Application.get_env(:evo_git, :self_reflective_source_mode) do
      mode when mode in [:source, :release] ->
        mode

      _other ->
        cond do
          @mix_env == :test -> :release
          running_source_dir() != nil -> :source
          true -> :release
        end
    end
  end

  @doc "Whether this instance runs FROM a source checkout (`source_mode/0`)."
  @spec running_from_source?() :: boolean()
  def running_from_source?, do: source_mode() == :source

  @doc """
  The Genesis checkout the running instance was built from, or `nil`.

  The `:self_reflective_running_source_dir` app env wins when it is a non-empty
  binary (test seam); otherwise `source_root_from_app_dir/1` walks up from
  `Application.app_dir(:evo_git)`.

  Total and never raising: an unresolvable app dir or an unexpected app-env
  value answers `nil`.
  """
  @spec running_source_dir() :: String.t() | nil
  def running_source_dir do
    case Application.get_env(:evo_git, :self_reflective_running_source_dir) do
      dir when is_binary(dir) and dir != "" ->
        dir

      _other ->
        source_root_from_app_dir(Application.app_dir(:evo_git))
    end
  rescue
    # Justified rescue: `Application.app_dir/1` raises for an unresolvable app,
    # and this accessor is documented TOTAL (it runs on every page load path).
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  @doc """
  The Genesis UMBRELLA root at or above `app_dir`, or `nil` (pure, total).

  Walks up at least six levels (eight in practice) and answers the first
  ancestor holding `mix.exs` AND `VERSION` AND `apps/evo_git/mix.exs` — a
  Genesis checkout, either a dev `_build` app dir or a source-mode install.
  A release app dir (`<release>/lib/evo_git-<vsn>`) has no such ancestor and
  therefore answers `nil`, which is what keeps a release on its managed clone.
  """
  @spec source_root_from_app_dir(term()) :: String.t() | nil
  def source_root_from_app_dir(app_dir) when is_binary(app_dir) and app_dir != "" do
    app_dir
    |> ancestor_dirs(@source_walk_up_levels)
    |> Enum.find(&genesis_umbrella_root?/1)
  end

  def source_root_from_app_dir(_other), do: nil

  @doc """
  The managed clone directory:
  `Path.join(EvoGit.Platform.data_dir(), "genesis-source")`.

  This is the RELEASE-mode source root; `source_dir/0` is what callers read.
  """
  @spec managed_dir() :: String.t()
  def managed_dir, do: Path.join(EvoGit.Platform.data_dir(), "genesis-source")

  @doc """
  The Genesis source root this instance reads.

  The `:self_reflective_source_dir` app env wins outright (a full override seam
  used by tests and hermetic deployments).
  Otherwise `:source` mode answers `running_source_dir/0` (falling back to
  `managed_dir/0` when the checkout cannot be located) and `:release` mode
  answers `managed_dir/0`.

  Never raises.
  """
  @spec source_dir() :: String.t()
  def source_dir do
    case Application.get_env(:evo_git, :self_reflective_source_dir) do
      dir when is_binary(dir) and dir != "" ->
        dir

      _other ->
        case source_mode() do
          :source -> running_source_dir() || managed_dir()
          :release -> managed_dir()
        end
    end
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
  The host-declared VCT `:system_mounts` entry for the source checkout this
  instance reads: `[%{point: point(), path: source_dir(), name:
  "genesis-source"}]`.

  Pure (no I/O, no VCT call) — `EvoGit.Application` passes it to the
  `EvoGit.VCT` child spec so the reserved mount is ensured idempotently at boot.
  The recorded OS path need not exist yet (a checkout is provisioned later):
  in `:source` mode it is the running checkout, in `:release` mode the managed
  clone.
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
    * `is_git_repo` — the dir has a `.git` directory or gitfile
    * `valid` — `is_git_repo` AND a `CONTEXT.md` exists at the dir root
      (a Genesis checkout)
    * `commit` — short HEAD sha (`rev-parse --short HEAD`), nil on failure
    * `branch` — current branch, nil on failure
    * `version` — trimmed `VERSION` file content of `dir`, nil when
      missing/unreadable
    * `remote_url` — `remote get-url origin`, nil on failure
    * `reference` — `reference_path/0` result
    * `is_reference` — `source_dir() == reference_path()`
    * `point` — `point/0` (the reserved VCT point, always present)
    * `mounted` — `true` ONLY when the VCT currently binds `point/0` to
      `source_dir/0`; `false` whenever the VCT is unavailable or binds
      something else
    * `source_mode` — `source_mode/0` (`:source` or `:release`)
    * `running_version` — `running_version/0` (the `:evo_git` app version)
    * `managed_dir` — `managed_dir/0` (the release-mode clone location)
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
      mounted: mounted?(),
      source_mode: source_mode(),
      running_version: running_version(),
      managed_dir: managed_dir()
    }
  end

  @doc """
  The running `:evo_git` application version (`Application.spec(:evo_git,
  :vsn)`), or `nil` when the application spec is unavailable.

  This is the version the managed clone is compared against on boot — the same
  comparison the `genesis_source` agent tool reports.
  """
  @spec running_version() :: String.t() | nil
  def running_version do
    case Application.spec(:evo_git, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  @doc """
  Shallow-clones `clone_url/0` into `source_dir/0`.

  Returns `{:error, :already_cloned}` when the dir already exists (checked
  BEFORE cloning — the managed dir is never overwritten), or
  `{:ok, status/0}` on success. Shallow (`--depth 1`) is fine: the
  self-reflective agent only READS the tree, and `update/0` refreshes it.

  In `:source` mode this answers `{:error, :running_from_source}`: a dev
  instance reads the checkout it was built from, so the state-dir clone is
  neither what it reads nor something it should create.

  After a SUCCESSFUL clone the reserved VCT mount is ensured best effort
  (`ensure_mount/0`): a VCT failure is logged and never turns the clone into an
  error.
  """
  @spec clone() :: {:ok, map()} | {:error, term()}
  def clone do
    if running_from_source?() do
      {:error, :running_from_source}
    else
      clone_at(source_dir(), clone_url())
    end
  end

  @doc "Prepares the exact approved source destination and upstream without rereading config."
  @spec clone_at(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def clone_at(dir, url) when is_binary(dir) and is_binary(url) do
    if File.dir?(dir) do
      {:error, :already_cloned}
    else
      case File.mkdir_p(Path.dirname(dir)) do
        :ok ->
          case Git.clone(url, dir, ["--depth", "1"]) do
            {:ok, _} ->
              ensure_mount_after_sync(dir)
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

  Guards: `{:error, :running_from_source}` in `:source` mode (a dev instance
  reads the checkout it was built from, not the state-dir clone),
  `{:error, :not_cloned}` when `source_dir/0` does not exist;
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
      running_from_source?() ->
        {:error, :running_from_source}

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
  Whether the managed clone needs a boot-time auto-pull.

  True only when ALL of these hold:

    * `source_mode/0` is `:release` (a dev instance reads its own checkout)
    * auto-sync is enabled — the `:self_reflective_source_auto_sync` app env,
      default `true`
    * `source_dir/0` exists and is a git repo
    * its `VERSION` differs from `running_version/0` (an unreadable clone
      `VERSION` counts as a mismatch)
    * the last-successful-auto-sync stamp does not already equal
      `running_version/0`

  The stamp (`<source_dir()>.auto-sync-version`, a SIBLING of the clone) is
  written ONLY after a successful sync, so a failed/offline attempt is retried
  on the next boot.
  Without it a release whose upstream default branch carries a newer `VERSION`
  would re-fetch the clone on every single restart.

  Never raises.
  """
  @spec sync_needed?() :: boolean()
  def sync_needed? do
    running = running_version()

    source_mode() == :release and auto_sync_enabled?() and
      case File.dir?(source_dir()) and git_repo?(source_dir()) do
        false -> false
        true -> version(source_dir()) != running and sync_stamp() != running
      end
  rescue
    # Justified rescue: a boot-time predicate must answer, never crash boot.
    _exception -> false
  catch
    _kind, _reason -> false
  end

  @doc """
  One synchronous auto-pull of the managed clone (tests and the spawned boot
  path).

  Answers `:in_sync` when `sync_needed?/0` is false, `{:ok, status/0}` after a
  successful `update/0` — writing the `<source_dir()>.auto-sync-version` stamp
  and logging the version transition — or `{:error, reason}` when the pull
  fails (a warning is logged and the stamp is NOT written, so the next boot
  retries).

  Total: a raise or throw inside the git path degrades to `{:error, reason}`.
  """
  @spec sync_now() :: :in_sync | {:ok, map()} | {:error, term()}
  def sync_now do
    if sync_needed?() do
      do_sync()
    else
      :in_sync
    end
  rescue
    exception -> {:error, {:sync_failed, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Boot hook: pull the managed clone in the background when
  `sync_needed?/0` holds, and return `:ok` immediately.

  The sync runs in a plain UNLINKED `spawn/1` wrapped in rescue/catch: it is a
  one-shot boot task whose failure must never reach the supervision tree, so a
  supervisor is not a fit (a crash-restart of a merely nice-to-have pull would
  burn the application's restart budget and could take the app down).
  Any raise or throw in the check itself is swallowed into `:ok`.
  """
  @spec maybe_sync_on_boot() :: :ok
  def maybe_sync_on_boot do
    if sync_needed?() do
      spawn(fn ->
        # Justified rescue/catch: this process is unlinked and unmonitored, so
        # an escaping error would only produce a bare crash report at boot.
        try do
          sync_now()
        rescue
          exception ->
            Logger.warning("Genesis source auto-sync crashed: #{inspect(exception)}")
        catch
          kind, reason ->
            Logger.warning("Genesis source auto-sync crashed: #{inspect({kind, reason})}")
        end
      end)
    end

    :ok
  rescue
    # Justified rescue: the boot path must never fail because of a version check.
    exception ->
      Logger.warning("Genesis source auto-sync check failed: #{inspect(exception)}")
      :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  The SINGLE SOURCE OF TRUTH for the self-reflective source-root resolution
  chain, in order:

    1. `:self_reflective_source_root` app env (if non-empty binary)
    2. `GENESIS_SOURCE_ROOT` env var (if non-empty binary)
    3. in `:source` mode (`source_mode/0`) AND only while the
       `:self_reflective_source_dir` app env seam is NOT set:
       `running_source_dir/0` when it is a valid Genesis checkout (git repo +
       `CONTEXT.md` at root). This step precedes the VCT step so a stale
       reserved mount left behind by an earlier release run cannot win over the
       checkout this instance was built from.
    4. the VCT mount at `point/0` (`vct:///genesis-source`) WHEN its path is a
       valid Genesis checkout (git repo + `CONTEXT.md` at root). Re-pointing
       that reserved mount is the supported "override". This step is SKIPPED
       entirely whenever the `:self_reflective_source_dir` app env seam is set,
       so hermetic tests stay deterministic.
    5. `source_dir/0` IF the dir exists AND is a valid Genesis checkout
       (git repo + `CONTEXT.md` at root) — auto-reference: cloning makes it
       the reference, no separate set-reference action
    6. `nil` (the assistant remains repo-less with its isolated `[system]`
       runtime root; optional source reads must explicitly request preparation)

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
            running_reference() || vct_reference() || managed_reference()
        end
    end
  end

  @doc """
  Whether a usable Genesis source is available to the self-reflective agent
  RIGHT NOW.

  Resolves the SAME source root the agent will actually use —
  `reference_path()` (no launch-directory fallback) — and validates it is a Genesis
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
    dir = reference_path()
    is_binary(dir) and genesis_checkout?(dir)
  end

  # --- Private helpers ------------------------------------------------------
  # A checkout qualifies when `.git` is a DIRECTORY (a plain clone) or a REGULAR
  # FILE (a git WORKTREE or submodule carries a `.git` gitfile) — a dev instance
  # running from a worktree must be recognized.
  # The path-based check is preferred over `git rev-parse --git-dir` because the
  # latter walks UP the tree and would report a non-repo dir nested inside
  # another git repo (e.g. the real Genesis checkout) as a git repo.
  defp git_repo?(dir) do
    dot_git = Path.join(dir, ".git")
    File.dir?(dot_git) or File.regular?(dot_git)
  end

  # Step 3 of the reference chain: in `:source` mode the checkout this instance
  # was built from qualifies only when it is a valid Genesis checkout, and only
  # while the `:self_reflective_source_dir` app env seam is unset (hermetic
  # tests stay deterministic and the seam keeps absolute priority).
  defp running_reference do
    if source_mode() == :source and
         is_nil(Application.get_env(:evo_git, :self_reflective_source_dir)) do
      dir = running_source_dir()

      if is_binary(dir) and git_repo?(dir) and genesis_checkout?(dir), do: dir, else: nil
    else
      nil
    end
  end

  # Step 4 of the reference chain: the reserved VCT mount qualifies only when
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
  defp ensure_mount_after_sync(dir \\ source_dir()) do
    mount_result =
      try do
        EvoGit.VCT.ensure_mount(point(), dir, name: @genesis_source_name)
      rescue
        exception -> {:error, exception}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case mount_result do
      {:ok, _mount} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "SelfReflectiveSource: could not ensure VCT mount #{point()}: #{inspect(reason)}"
        )
    end
  end

  # Step 5 of the reference chain: `source_dir/0` qualifies only when it is
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

  # --- Auto-sync helpers ----------------------------------------------------

  defp auto_sync_enabled? do
    Application.get_env(:evo_git, :self_reflective_source_auto_sync, true) not in [false, nil]
  end

  # The success stamp lives BESIDE the clone, never inside it: a shallow
  # `reset --hard` would otherwise wipe the marker on exactly the sync it
  # records.
  defp sync_stamp_path, do: source_dir() <> ".auto-sync-version"

  defp sync_stamp do
    case File.read(sync_stamp_path()) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp write_sync_stamp do
    case File.write(sync_stamp_path(), "#{running_version()}\n") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Genesis source auto-sync: could not write #{sync_stamp_path()}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp do_sync do
    dir = source_dir()
    before_version = version(dir)

    case update() do
      {:ok, status} ->
        write_sync_stamp()

        Logger.info(
          "Genesis source auto-sync: #{before_version || "unknown"} -> " <>
            "#{status.version || "unknown"}"
        )

        {:ok, status}

      {:error, reason} ->
        Logger.warning("Genesis source auto-sync failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Ancestor walk --------------------------------------------------------

  # `app_dir` and its ancestors, deepest-first, capped at `levels` parents.
  defp ancestor_dirs(app_dir, levels) when levels >= 0 do
    [app_dir | parent_dirs(Path.dirname(app_dir), levels)]
  end

  defp parent_dirs(_dir, 0), do: []

  defp parent_dirs(dir, levels) do
    [dir | parent_dirs(Path.dirname(dir), levels - 1)]
  end

  # A Genesis UMBRELLA checkout: root `mix.exs` + `VERSION` + the `:evo_git`
  # app's own `mix.exs`.
  defp genesis_umbrella_root?(dir) do
    File.regular?(Path.join(dir, "mix.exs")) and
      File.regular?(Path.join(dir, "VERSION")) and
      File.regular?(Path.join(dir, "apps/evo_git/mix.exs"))
  end
end
