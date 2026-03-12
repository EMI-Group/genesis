defmodule EvoGit do
  @moduledoc """
  Documentation for `EvoGit`.
  """

  @doc """
  Generates systemd-run arguments to execute a command inside a cheap sandbox.
  """
  def sandbox_args(cwd, executable, args \\ []) do
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
      "ReadWritePaths=#{cwd}",
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
    ] ++ inaccessible_args ++ [executable | args]
  end
end
