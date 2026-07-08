defmodule EvoGit do
  @moduledoc """
  Core EvoGit module providing sandboxed command execution.

  The sandbox system supports multiple platform backends:

    * **Linux** — `systemd-run` with full sandboxing: filesystem isolation, resource
      limits (CPU, memory), syscall filtering, and process isolation.
    * **macOS** — `sandbox-exec` with filesystem isolation (read/write restrictions).
    * **Windows** — No sandbox; commands run directly.

  The active backend is determined automatically by `EvoGit.Platform.sandbox_backend/0`.

  ## Sandbox Configuration

  The sandbox behavior is controlled by the `:sandbox` application config:

    * `:auto` (default) — Enables sandbox on Linux (systemd-run) and macOS (sandbox-exec),
      disables on Windows.
    * `:enabled` — Force-enable sandbox (uses the platform's available backend).
    * `:disabled` — Disable sandbox entirely, run commands directly.

  Resource limits are Linux-only and configured via `[sandbox.resources]` and `[sandbox.process]`
  in TOML config:

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

  ## Nix Develop Integration

  When `[nix] enabled = true` in config and a `flake.nix` exists in the config
  directory (e.g. `~/.config/genesis/flake.nix`), all tool calls are wrapped in
  `nix develop` so that tools defined in the flake are available to the agent.
  This is handled transparently by each sandbox backend via the `EvoGit.Nix`
  helper module.
  """

  @doc """
  Generates sandbox arguments for the Linux/systemd-run backend.

  This function is retained for backward compatibility and testing.
  On non-Linux platforms, returns an empty list.
  """
  def sandbox_args(cwd, executable, args \\ [], repo_root \\ nil) do
    EvoGit.Sandbox.Linux.args(cwd, executable, args, repo_root)
  end

  @doc """
  Runs a command inside the platform-appropriate sandbox.

  On Linux, uses `systemd-run` with full isolation. On macOS, uses `sandbox-exec`
  with filesystem isolation. On Windows, runs commands directly.

  ## Parameters

  - `cwd` - The working directory for the command
  - `executable` - The executable to run
  - `args` - List of arguments to pass to the executable (default: [])
  - `repo_root` - Optional path to the git repository root

  ## Returns

  `{output :: String.t(), exit_code :: non_neg_integer()}`
  """
  def sandbox_run(cwd, executable, args \\ [], repo_root \\ nil) do
    EvoGit.Sandbox.run(cwd, executable, args, repo_root)
  end

  @doc """
  Runs a command inside the platform-appropriate sandbox with partial output recovery on timeout.

  Unlike `sandbox_run/4`, which loses all output when a command times out, this function
  redirects command output to a temp file so that partial output can be recovered on timeout.

  ## Parameters

  - `cwd` - The working directory for the command
  - `executable` - The executable to run
  - `args` - List of arguments to pass to the executable (default: [])
  - `repo_root` - Optional path to the git repository root
  - `timeout` - Timeout in milliseconds
  - `max_bytes` - Maximum output size in bytes before truncation (nil = no limit)

  ## Returns

  - `{:ok, output, exit_code}` — command completed within timeout
  - `{:timeout, partial_output}` — command timed out, partial output recovered
  """
  def sandbox_run_with_partial(cwd, executable, args \\ [], repo_root \\ nil, timeout, max_bytes \\ nil) do
    EvoGit.Sandbox.run_with_partial(cwd, executable, args, repo_root, timeout, max_bytes)
  end

  @doc """
  Returns whether the sandbox is currently enabled for the active backend.
  """
  def sandbox_enabled? do
    EvoGit.Sandbox.enabled?()
  end
end
