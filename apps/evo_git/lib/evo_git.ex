defmodule EvoGit do
  @moduledoc """
  Core EvoGit module providing sandboxed command execution.

  The sandbox uses `systemd-run` on Linux to isolate agent-executed commands
  inside a shared `evogit.slice` systemd user slice. Resource limits (CPU,
  memory, tasks) are applied to the slice as a whole, so they govern the
  aggregate of all sandboxed processes rather than each process individually.

  On other platforms (macOS, Windows) or when `systemd-run` is unavailable,
  commands run directly without sandboxing.

  ## Sandbox Configuration

  The sandbox behavior is controlled by the `:sandbox` application config:

    * `:auto` (default) — Enables sandbox on Linux when `systemd-run` is available,
      disables on all other platforms.
    * `:enabled` — Force-enable sandbox (will fail on non-Linux platforms).
    * `:disabled` — Disable sandbox entirely, run commands directly.

  Resource limits are configured via `[sandbox.resources]` and `[sandbox.process]` in TOML config:

      [sandbox]
      mode = "auto"

      [sandbox.resources]
      cpu_quota = "1000%"
      cpu_weight = 30
      memory_max = "16G"
      tasks_max = 8196

      [sandbox.process]
      cpu_quota = "800%"
      memory_max = "12G"
      limit_nofile = 65536
      oom_score_adjust = 1000

  ## Example Configuration

      config :evo_git, sandbox: :auto        # default
      config :evo_git, sandbox: :enabled     # force enable
      config :evo_git, sandbox: :disabled    # force disable
  """

  alias EvoGit.Platform

  @doc """
  Generates systemd-run arguments to execute a command inside a cheap sandbox.

  ## Parameters

  - `cwd` - The working directory for the command
  - `executable` - The executable to run
  - `args` - List of arguments to pass to the executable (default: [])
  - `repo_root` - Optional path to the git repository root. If provided,
    marks the repo_root/.git as writable, which is required for git worktrees
    to access the shared git database.

  """
  def sandbox_args(cwd, executable, args \\ [], repo_root \\ nil) do
    home = System.user_home!()

    # Keep sensitive credentials locked down
    inaccessible_args =
      [
        ".ssh",
        ".gnupg",
        ".aws",
        ".kube",
        ".config/sops",
        ".npmrc",
        ".git-credentials",
        ".netrc"
      ]
      |> Enum.flat_map(fn dir ->
        ["-p", "InaccessiblePaths=-#{Path.join(home, dir)}"]
      end)

    # Comprehensive build tool & language cache support
    build_cache_dirs =
      [
        # Universal cache (Python pip, Go build, C/C++ ccache)
        ".cache",
        # Universal local share (pnpm state, generic tools)
        ".local/share",
        # Universal local state
        ".local/state",
        # Rust packages
        ".cargo",
        # Rust toolchains
        ".rustup",
        # Elixir Mix
        ".mix",
        # Elixir Hex
        ".hex",
        # Node.js npm
        ".npm",
        # Node.js yarn
        ".yarn",
        # Bun JS
        ".bun",
        # Java Maven
        ".m2",
        # Java Gradle
        ".gradle",
        # Golang workspace (default GOPATH)
        "go"
      ]
      |> Enum.map(&Path.join(home, &1))

    # Add cwd, the system temp folders, and the language caches
    read_write_paths =
      [cwd | Platform.tmp_paths()] ++
        build_cache_dirs ++
        if repo_root do
          [Path.join(repo_root, ".git")]
        else
          []
        end

    read_write_args =
      Enum.flat_map(read_write_paths, fn path ->
        # The "-" prefix ensures systemd won't crash if the directory doesn't exist yet
        ["-p", "ReadWritePaths=-#{path}"]
      end)

    # Propagate PATH and HOME so tools installed in non-standard locations (e.g. /usr/local/bin,
    # nix store, user-local bin) are found inside the sandbox the same way they are in
    # the user's interactive shell.
    env_args =
      [{"PATH", System.get_env("PATH")}, {"HOME", System.get_env("HOME")}]
      |> Enum.flat_map(fn
        {_key, nil} -> []
        {key, value} -> ["--setenv=#{key}=#{value}"]
      end)

    [
      "--user",
      "--slice=evogit",
      "--wait",
      "--pipe",
      "--collect",
      "-q"
    ] ++
      env_args ++
      [
      "-p",
      "WorkingDirectory=#{cwd}",
      "-p",
      "StandardInput=null",
      # --- FILESYSTEM PROTECTION (The Anti-rm -rf) ---
      # /usr, /boot, /etc are read-only
      "-p",
      "ProtectSystem=strict",
      # /home is read-only (except ReadWritePaths)
      "-p",
      "ProtectHome=read-only",
      # Cannot tweak /sys
      "-p",
      "ProtectKernelTunables=yes",
      # Cannot escape cgroups
      "-p",
      "ProtectControlGroups=yes",
      # --- SYSCALL FILTERING (The Goldilocks Zone) ---
      "-p",
      "SystemCallArchitectures=native",
      "-p",
      "SystemCallErrorNumber=EPERM",
      "-p",
      "SystemCallFilter=~ @clock @module @mount @raw-io @reboot @swap",
      # --- PROCESS ISOLATION ---
      # Cannot use sudo or setuid binaries
      "-p",
      "NoNewPrivileges=yes",
      # Cannot see host processes via `ps`
      "-p",
      "PrivatePIDs=yes",
      # Hides other user processes in /proc
      "-p",
      "ProtectProc=invisible"
    ] ++
      sandbox_resource_args() ++
      read_write_args ++
      inaccessible_args ++ [executable | args]
  end

  @doc """
  Runs a command inside a cheap sandbox using systemd-run.

  ## Parameters

  - `cwd` - The working directory for the command
  - `executable` - The executable to run
  - `args` - List of arguments to pass to the executable (default: [])
  - `repo_root` - Optional path to the git repository root. If provided,
    marks the repo_root/.git as writable, which is required for git worktrees
    to access the shared git database.

  ## Returns

  `{{output :: String.t(), exit_code :: non_neg_integer()}}`

  ## Examples

      iex> EvoGit.sandbox_run("/path/to/repo", "ls", ["-la"])
      {"file1.txt\\nfile2.txt\\n", 0}

  """
  def sandbox_run(cwd, executable, args \\ [], repo_root \\ nil) do
    if sandbox_enabled?() do
      # Ensure the shared slice exists (idempotent — first call creates, subsequent are no-ops)
      EvoGit.SandboxSlice.ensure_slice()
      sandbox_args(cwd, executable, args, repo_root)
      |> then(&System.cmd("systemd-run", &1, stderr_to_stdout: true))
    else
      System.cmd(executable, args, cd: cwd, stderr_to_stdout: true)
    end
  end

  defp sandbox_enabled? do
    case EvoGit.Defaults.sandbox() || :auto do
      :enabled -> true
      :disabled -> false
      :auto -> Platform.systemd_available?()
    end
  end

  defp sandbox_resource_args do
    # Try runtime overrides first, fall back to TOML config
    process_resources = get_process_resources()

    cpu_quota_args =
      case Map.get(process_resources, :cpu_quota) do
        nil -> []
        v -> ["-p", "CPUQuota=#{v}"]
      end

    memory_args =
      case Map.get(process_resources, :memory_max) do
        nil -> []
        v -> ["-p", "MemoryMax=#{v}"]
      end

    nofile_args =
      case Map.get(process_resources, :limit_nofile) do
        nil -> []
        v -> ["-p", "LimitNOFILE=#{v}"]
      end

    oom_args =
      case Map.get(process_resources, :oom_score_adjust) do
        nil -> []
        v -> ["-p", "OOMScoreAdjust=#{v}"]
      end

    cpu_quota_args ++ memory_args ++ nofile_args ++ oom_args
  end

  defp get_process_resources do
    # Try runtime state first (from dashboard overrides)
    try do
      case EvoGit.AgentScheduler.get_config()[:sandbox_process_resources] do
        nil -> EvoGit.Config.resolve([:sandbox, :process]) || %{}
        resources when map_size(resources) == 0 -> EvoGit.Config.resolve([:sandbox, :process]) || %{}
        resources -> resources
      end
    rescue
      _ -> EvoGit.Config.resolve([:sandbox, :process]) || %{}
    catch
      _, _ -> EvoGit.Config.resolve([:sandbox, :process]) || %{}
    end
  end
end
