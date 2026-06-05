defmodule EvoGit.Sandbox do
  @moduledoc """
  Multi-platform sandbox dispatch module.

  Dispatches sandboxed command execution to the appropriate platform backend:

    * **Linux** — `systemd-run` with full sandboxing: filesystem isolation, resource
      limits (CPU, memory), syscall filtering, and process isolation.
    * **macOS** — `sandbox-exec` with filesystem isolation (read/write restrictions).
    * **Windows** — No sandbox; commands run directly.

  The active backend is determined automatically by `EvoGit.Platform.sandbox_backend/0`.
  """

  alias EvoGit.Platform

  @type capabilities :: %{
          filesystem_isolation: boolean(),
          resource_limits: boolean(),
          backend: :systemd_run | :sandbox_exec | :none
        }

  @doc "Returns the active sandbox backend module based on platform and availability."
  @spec backend() :: module()
  def backend do
    case Platform.sandbox_backend() do
      :systemd_run -> EvoGit.Sandbox.Linux
      :sandbox_exec -> EvoGit.Sandbox.MacOS
      :none -> EvoGit.Sandbox.None
    end
  end

  @doc "Returns the capabilities of the current platform's sandbox backend."
  @spec capabilities() :: capabilities()
  def capabilities do
    case Platform.sandbox_backend() do
      :systemd_run ->
        %{filesystem_isolation: true, resource_limits: true, backend: :systemd_run}

      :sandbox_exec ->
        %{filesystem_isolation: true, resource_limits: false, backend: :sandbox_exec}

      :none ->
        %{filesystem_isolation: false, resource_limits: false, backend: :none}
    end
  end

  @doc "Returns whether sandbox is currently enabled (considering mode + platform)."
  @spec enabled?() :: boolean()
  def enabled? do
    backend().enabled?()
  end

  @doc """
  Runs a command through the sandbox backend.

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
  @spec run(String.t(), String.t(), [String.t()], String.t() | nil) ::
          {String.t(), non_neg_integer()}
  def run(cwd, executable, args \\ [], repo_root \\ nil) do
    resolved = EvoGit.Executable.resolve(executable)
    backend().run(cwd, resolved, args, repo_root)
  end

  @doc "Ensures the sandbox backend is initialized (e.g., creates systemd slice)."
  @spec ensure_initialized() :: :ok | {:error, term()}
  def ensure_initialized do
    backend().ensure_initialized()
  end
end
