defmodule EvoGit do
  @moduledoc """
  Documentation for `EvoGit`.
  """

  @doc """
  Generates systemd-run arguments to execute a command inside a cheap sandbox.
  """
  def sandbox_args(cwd, executable, args \\ []) do
    [
      "--user",
      "--wait",
      "--pipe",
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
      "SystemCallArchitectures=native",
      "-p",
      "SystemCallErrorNumber=EPERM",
      "-p",
      "SystemCallFilter=~ @module @keyring @raw-io @reboot @mount @swap @clock @cpu-emulation @debug @obsolete @privileged",
      "-p",
      "CPUQuota=400%",
      "-p",
      "MemoryMax=16G",
      executable
    ] ++ args
  end
end
