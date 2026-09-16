defmodule EvoGit.TaskTmpdir do
  @moduledoc """
  Managed **per-task** temporary directory for agents.

  Single source of truth for the scratch directory shared by *all* agents of a
  single task. It replaces the former behaviour where every agent on a BEAM
  wrote scratch files into one host `/tmp` (no isolation, no sweep — tens of GB
  of accumulated trash). A per-task (not per-agent) scope is required because
  agents legitimately pass temp files to **sibling** agents through raw paths,
  so all agents of one task must share one directory.

  ## Modes (`[tmp] mode`)

    * `:system` (default) → `<system tmp>/genesis/task_<task_id>`, e.g.
      `/tmp/genesis/task_<task_id>` on Linux. Honors the user's own tmp
      configuration (tmpfs, auto-clean-on-reboot).
    * `:custom` → `<expanded([tmp] path)>/genesis/task_<task_id>`. The
      dedicated `genesis` subdir keeps the managed root separate so reclaim
      can never touch unrelated user files at the base. A missing/invalid
      `[tmp] path` logs a warning and falls back to `:system` behaviour.
    * `:per_repo` → `<task's PRIMARY repo>/.genesis/tmp/task_<task_id>`. A task
      with no primary repo (repo-less/reflect) falls back to `:system`
      behaviour.

  The managed root (`managed_root/1`) is the ONE directory at the top of each
  mode that this module owns; `reclaim/2` and `reclaim_stale/1` NEVER delete
  anything outside it and NEVER delete the root itself.

  ## Process-dictionary seam

  Tool commands do not run in the agent's own process (`tool_dispatch.ex` fans
  them out into `Task.async` closures that do NOT inherit the caller's process
  dictionary). The resolved path is therefore threaded explicitly: the runner
  resolves it once and calls `put_current/1`; the tool-dispatch layer reads
  `current/0` and re-installs it inside each spawned task. `EvoGit.Sandbox.resolve_tmpdir/0`
  prefers `current/0` when set, so every backend's `TMPDIR` injection (and the
  runtime's own temp files) automatically target the per-task directory.

  ## Constraints

  Modes `:system`/`:custom` share automatically across all agents of a task
  (the path depends only on `task_id`). `:per_repo` depends on the TASK's
  primary repository, not the individual agent's repo — subagents working in a
  foreign repository must still receive the SAME directory, which the caller
  achieves by threading the primary repo path (or the resolved dir) down.
  """

  require Logger

  @pd_key :evogit_task_tmpdir
  @dir_prefix "task_"
  @managed_subdir "genesis"
  @modes [:system, :custom, :per_repo]

  @type task_id :: integer() | String.t()
  @type mode :: :system | :custom | :per_repo

  @doc """
  Returns the resolved `[tmp] mode` config value (`:system` when unset or
  invalid).
  """
  @spec mode() :: mode()
  def mode do
    case EvoGit.Config.resolve([:tmp, :mode]) do
      m when m in @modes -> m
      _ -> :system
    end
  end

  @doc """
  Returns the per-task directory path for the configured mode.

  Pure path math — the directory is NOT created here (use `ensure/2`).
  `primary_repo_path` may be `nil` for repo-less/reflect tasks.
  """
  @spec path_for(task_id(), String.t() | nil) :: String.t()
  def path_for(task_id, primary_repo_path) do
    Path.join(managed_root(primary_repo_path), dir_name(task_id))
  end

  @doc """
  Returns the managed root directory for the current mode (the containment
  boundary owned by this module).

    * `:system` → `<system tmp>/genesis`
    * `:custom` → `<[tmp] path>/genesis` (falls back to the system root when
      the configured path is missing/invalid)
    * `:per_repo` → `<primary_repo_path>/.genesis/tmp` (falls back to the
      system root when no repo path is available)
  """
  @spec managed_root(String.t() | nil) :: String.t()
  def managed_root(primary_repo_path) do
    root_for(mode(), primary_repo_path)
  end

  @doc """
  Creates the per-task directory (idempotent) and returns its path.

  Never raises — a filesystem failure is logged and the path is still
  returned (callers may proceed; the sandbox will surface a real error if the
  directory truly cannot be used).
  """
  @spec ensure(task_id(), String.t() | nil) :: String.t()
  def ensure(task_id, primary_repo_path) do
    dir = path_for(task_id, primary_repo_path)

    case File.mkdir_p(dir) do
      :ok ->
        dir

      {:error, reason} ->
        Logger.warning("EvoGit.TaskTmpdir: failed to create #{dir}: #{inspect(reason)}")
        dir
    end
  end

  @doc """
  Installs `path` as the current process's per-task tmpdir (process-dictionary
  seam read by `current/0`).
  """
  @spec put_current(String.t() | nil) :: :ok
  def put_current(path) do
    Process.put(@pd_key, path)
    :ok
  end

  @doc "Returns the current process's per-task tmpdir, or `nil` when unset."
  @spec current() :: String.t() | nil
  def current do
    case Process.get(@pd_key) do
      path when is_binary(path) -> path
      _ -> nil
    end
  end

  @doc """
  Safely removes the per-task directory for `task_id`.

  Refuses to delete anything whose resolved path is not exactly
  `<managed_root>/task_<task_id>` (i.e. it must sit directly under a managed
  root and its basename must start with `task_`). The managed root itself is
  never removed. Idempotent, never raises.
  """
  @spec reclaim(task_id(), String.t() | nil) :: :ok
  def reclaim(task_id, primary_repo_path) do
    dir = path_for(task_id, primary_repo_path)
    root = managed_root(primary_repo_path)

    if safe_to_reclaim?(dir, root) do
      case File.rm_rf(dir) do
        {:ok, _} ->
          :ok

        {:error, reason, _path} ->
          Logger.warning("EvoGit.TaskTmpdir: failed to reclaim #{dir}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Sweeps stale per-task directories no longer belonging to a live task.

  For `:system`/`:custom` modes the managed root is enumerated and every
  `task_*` entry whose name is not in `live_task_ids` is removed. For
  `:per_repo` this is a no-op (the root is repo-specific and requires a repo
  path — per-repo stragglers are reclaimed per task via `reclaim/2`). The root
  itself is never removed; filesystem errors are swallowed (the sweep is
  best-effort). `live_task_ids` entries may be integers or strings.
  """
  @spec reclaim_stale([task_id()]) :: :ok
  def reclaim_stale(live_task_ids) do
    case mode() do
      :per_repo ->
        :ok

      _ ->
        root = managed_root(nil)
        live_names = MapSet.new(Enum.map(live_task_ids, &dir_name/1))
        sweep_root(root, live_names)
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp sweep_root(root, live_names) do
    case File.ls(root) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          if String.starts_with?(entry, @dir_prefix) and
               not MapSet.member?(live_names, entry) do
            _ = File.rm_rf(Path.join(root, entry))
          end
        end)

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp root_for(:system, _primary_repo_path) do
    Path.join(system_base(), @managed_subdir)
  end

  defp root_for(:custom, _primary_repo_path) do
    Path.join(custom_base(), @managed_subdir)
  end

  defp root_for(:per_repo, primary_repo_path)
       when is_binary(primary_repo_path) and primary_repo_path != "" do
    Path.join([primary_repo_path, ".genesis", "tmp"])
  end

  defp root_for(:per_repo, _primary_repo_path) do
    Path.join(system_base(), @managed_subdir)
  end

  # The system temp base: the first `Platform.tmp_paths/0` entry (the dir the
  # sandbox already grants write access to), falling back to `System.tmp_dir!()`.
  defp system_base do
    case EvoGit.Platform.tmp_paths() do
      [first | _] when is_binary(first) -> first
      _ -> System.tmp_dir!()
    end
  end

  # The `:custom` base path, validated + expanded. A missing/empty/non-absolute
  # (and non-`~`-relative) value logs a warning and falls back to the system
  # base — mirroring `EvoGit.Platform.data_dir/0`'s handling of `[data] dir`.
  defp custom_base do
    case EvoGit.Config.resolve([:tmp, :path]) do
      path when is_binary(path) and path != "" ->
        if custom_path_override?(path) do
          EvoGit.Platform.safe_expand(path)
        else
          Logger.warning(
            "Ignoring invalid [tmp] path config value #{inspect(path)}: expected an " <>
              "absolute path (or a ~/ home-relative path). Falling back to the system " <>
              "temporary directory for the per-task tmpdir."
          )

          system_base()
        end

      _ ->
        Logger.warning(
          "[tmp] mode is :custom but [tmp] path is not set (or not a string). " <>
            "Falling back to the system temporary directory for the per-task tmpdir."
        )

        system_base()
    end
  end

  # Accepts absolute paths or `~`-prefixed home-relative paths, exactly like
  # `[data] dir`. Relative paths are rejected (expanding them against the
  # process CWD would silently relocate the tmpdir).
  defp custom_path_override?(dir) when is_binary(dir) do
    Path.type(dir) == :absolute or dir == "~" or String.starts_with?(dir, "~/") or
      String.starts_with?(dir, "~\\")
  end

  defp dir_name(task_id), do: @dir_prefix <> to_string(task_id)

  defp safe_to_reclaim?(dir, root) do
    expanded_dir = Path.expand(dir)
    expanded_root = Path.expand(root)

    expanded_dir != expanded_root and
      Path.dirname(expanded_dir) == expanded_root and
      String.starts_with?(Path.basename(expanded_dir), @dir_prefix)
  end
end
