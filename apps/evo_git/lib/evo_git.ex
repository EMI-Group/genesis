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

    # Build ReadWritePaths - always include cwd, and repo_root/.git if provided
    read_write_paths =
      if repo_root do
        [cwd, Path.join(repo_root, ".git")]
      else
        [cwd]
      end

    read_write_args =
      Enum.flat_map(read_write_paths, fn path ->
        ["-p", "ReadWritePaths=#{path}"]
      end)

    [
      "--user",
      "--wait",
      "--pipe",
      "-q",
      "-p",
      "WorkingDirectory=#{cwd}",
      "-p",
      "ProtectSystem=strict",
      "-p",
      "ProtectHome=read-only",
      "-p",
      "PrivateTmp=yes",
      "-p",
      "NoNewPrivileges=yes",
      "-p",
      "PrivatePIDs=yes",
      "-p",
      "ProtectProc=invisible",
      "-p",
      "SystemCallArchitectures=native",
      "-p",
      "SystemCallErrorNumber=EPERM",
      "-p",
      "SystemCallFilter=~ @module @keyring @raw-io @reboot @mount @swap @clock @cpu-emulation @debug @obsolete @privileged",
      "-p",
      "CPUQuota=400%",
      "-p",
      "MemoryMax=16G"
    ] ++
      read_write_args ++
      inaccessible_args ++ [executable | args]
  end
end
