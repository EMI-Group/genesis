defmodule EvoGit.Sandbox.Linux do
  @moduledoc """
  Linux sandbox backend using `systemd-run`.

  Provides full sandboxing: filesystem isolation, resource limits (CPU, memory),
  syscall filtering, and process isolation. Requires systemd.
  """

  alias EvoGit.{Nix, Platform}

  @doc "Returns true when sandbox mode allows systemd-run on Linux."
  @spec enabled?() :: boolean()
  def enabled? do
    case EvoGit.Defaults.sandbox() || :auto do
      :enabled -> true
      :disabled -> false
      :auto -> Platform.systemd_available?()
    end
  end

  @doc "Creates the evogit.slice if not already active."
  @spec ensure_initialized() :: :ok | {:error, term()}
  def ensure_initialized do
    if enabled?() do
      EvoGit.SandboxSlice.ensure_slice()
    else
      :ok
    end
  end

  @doc "Runs command via systemd-run."
  @spec run(String.t(), String.t(), [String.t()], String.t() | nil) ::
          {String.t(), non_neg_integer()}
  def run(cwd, executable, args \\ [], repo_root \\ nil) do
    if enabled?() do
      ensure_initialized()
      System.cmd("systemd-run", args(cwd, executable, args, repo_root), stderr_to_stdout: true)
    else
      System.cmd(executable, args, cd: cwd, stderr_to_stdout: true)
    end
  end

  @doc "Generates systemd-run argument list."
  @spec args(String.t(), String.t(), [String.t()], String.t() | nil) :: [String.t()]
  def args(cwd, executable, args \\ [], repo_root \\ nil) do
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

    # Add nix store and daemon socket dirs when nix wrapping is enabled
    nix_paths =
      if Nix.enabled?() do
        ["/nix/store", "/nix/var"]
      else
        []
      end

    # Add cwd, the system temp folders, and the language caches
    read_write_paths =
      [cwd | Platform.tmp_paths()] ++
        build_cache_dirs ++
        nix_paths ++
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
    # the user's interactive shell. TMPDIR is forwarded to a path the sandbox actually
    # grants write access to (resolved by EvoGit.Sandbox.resolve_tmpdir/0) so that
    # LLM-generated temp-file writes don't fail.
    env_args =
      [
        {"PATH", System.get_env("PATH")},
        {"HOME", System.get_env("HOME")},
        {"TMPDIR", EvoGit.Sandbox.resolve_tmpdir()}
      ]
      |> Enum.flat_map(fn
        {_key, nil} -> []
        {key, value} -> ["--setenv=#{key}=#{value}"]
      end)

    nix_env_args =
      if Nix.enabled?() do
        Nix.nix_env_vars()
        |> Enum.flat_map(fn {key, value} -> ["--setenv=#{key}=#{value}"] end)
      else
        []
      end

    [
      "--user",
      "--slice=evogit",
      "--wait",
      "--pipe",
      "--collect",
      "-q"
    ] ++
      env_args ++
      nix_env_args ++
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
      resource_args() ++
      read_write_args ++
      inaccessible_args ++
      if Nix.active?() do
        {nix_exe, nix_args} = Nix.wrap_command(executable, args)
        [nix_exe | nix_args]
      else
        [executable | args]
      end
  end

  defp resource_args do
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
    # AgentScheduler.get_config/0 is a GenServer.call that exits (noproc/
    # timeout) if the scheduler isn't running — e.g. during early init or
    # tests. We catch that exit specifically. Config.resolve never raises
    # and returns nil for missing keys, so it needs no protection.
    scheduler_config =
      try do
        EvoGit.AgentScheduler.get_config()
      catch
        :exit, _ -> %{}
      end

    case scheduler_config[:sandbox_process_resources] do
      nil -> EvoGit.Config.resolve([:sandbox, :process]) || %{}
      resources when map_size(resources) == 0 -> EvoGit.Config.resolve([:sandbox, :process]) || %{}
      resources -> resources
    end
  end
end
