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

  @doc """
  Runs a command with timeout through the sandbox, recovering partial output on timeout.

  Unlike `run/4`, this function supports a timeout: if the command does not
  complete within the given timeout, any partial output written to stdout/stderr
  up to that point is recovered and returned.

  ## Parameters

  - `cwd` - The working directory for the command
  - `executable` - The executable to run
  - `args` - List of arguments to pass to the executable (default: [])
  - `repo_root` - Optional path to the git repository root
  - `timeout` - Timeout in milliseconds (positive integer)
  - `max_bytes` - Maximum output size in bytes before truncation (nil = no limit).
    When set and the output exceeds this size, only the first and last portions
    are read from disk to avoid loading large files into memory.

  ## Returns

  - `{:ok, output, exit_code}` — command completed within timeout
  - `{:timeout, partial_output}` — command timed out; partial_output is a string
    that may be empty if nothing was written before the timeout
  """
  @spec run_with_partial(
          String.t(),
          String.t(),
          [String.t()],
          String.t() | nil,
          pos_integer(),
          integer() | nil
        ) ::
          {:ok, String.t(), non_neg_integer()} | {:timeout, String.t()}
  def run_with_partial(cwd, executable, args \\ [], repo_root \\ nil, timeout, max_bytes \\ nil) do
    resolved = EvoGit.Executable.resolve(executable)
    backend().run_with_partial(cwd, resolved, args, repo_root, timeout, max_bytes)
  end

  @doc "Ensures the sandbox backend is initialized (e.g., creates systemd slice)."
  @spec ensure_initialized() :: :ok | {:error, term()}
  def ensure_initialized do
    backend().ensure_initialized()
  end

  @doc """
  Resolves a writable `TMPDIR` value for use inside the sandbox.

  The forwarded `TMPDIR` must point to a path the sandbox profile actually grants
  write access to. Returns a path based on `Platform.tmp_paths/0`:

    * If `$TMPDIR` is unset, falls back to the first entry of `Platform.tmp_paths/0`
      (e.g. `/tmp` on Linux/macOS).
    * If `$TMPDIR` is set, keeps it only when its expanded path exists AND is equal
      to, or a subdirectory of, one of the `Platform.tmp_paths/0` entries.
      Otherwise falls back to the first entry.

  This prevents forwarding a `TMPDIR` that the sandbox profile does not cover
  (e.g. macOS `/var/folders/...`) or that points to a non-existent directory.
  """
  @spec resolve_tmpdir() :: String.t()
  def resolve_tmpdir do
    tmp_paths = Platform.tmp_paths()
    default = List.first(tmp_paths)

    case System.get_env("TMPDIR") do
      nil ->
        default

      raw ->
        expanded = Path.expand(raw)

        if File.exists?(expanded) and under_any?(expanded, tmp_paths) do
          expanded
        else
          default
        end
    end
  end

  # Returns true when `path` is equal to, or a subdirectory of, one of `prefixes`.
  # Uses `prefix <> "/"` so that `/tmpfoo` does NOT match the `/tmp` prefix.
  defp under_any?(path, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      EvoGit.Platform.path_under?(path, prefix)
    end)
  end
end
