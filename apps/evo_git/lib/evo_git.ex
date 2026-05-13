defmodule EvoGit do
  @moduledoc """
  Documentation for `EvoGit`.
  """

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
        ".cache",       # Universal cache (Python pip, Go build, C/C++ ccache)
        ".local/share", # Universal local share (pnpm state, generic tools)
        ".local/state", # Universal local state
        ".cargo",       # Rust packages
        ".rustup",      # Rust toolchains
        ".mix",         # Elixir Mix
        ".hex",         # Elixir Hex
        ".npm",         # Node.js npm
        ".yarn",        # Node.js yarn
        ".bun",         # Bun JS
        ".m2",          # Java Maven
        ".gradle",      # Java Gradle
        "go"            # Golang workspace (default GOPATH)
      ]
      |> Enum.map(&Path.join(home, &1))

    # Add cwd, the system temp folders, and the language caches
    read_write_paths =
      [cwd, "/tmp", "/var/tmp"] ++
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

    [
      "--user",
      "--wait",
      "--pipe",
      "-q",
      "-p", "WorkingDirectory=#{cwd}",
      "-p", "ProtectSystem=strict",
      "-p", "ProtectHome=read-only",
      # Note: PrivateTmp=yes has been removed so the host's /tmp is shared
      "-p", "NoNewPrivileges=yes",
      "-p", "PrivatePIDs=yes",
      "-p", "ProtectProc=invisible",
      "-p", "SystemCallArchitectures=native",
      "-p", "SystemCallErrorNumber=EPERM",
      "-p", "SystemCallFilter=~ @module @keyring @raw-io @reboot @mount @swap @debug @obsolete @privileged",
      "-p", "CPUWeight=30",
      "-p", "MemoryMax=16G"
    ] ++
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
    sandbox_args(cwd, executable, args, repo_root)
    |> then(&System.cmd("systemd-run", &1, stderr_to_stdout: true))
  end
end
