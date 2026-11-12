defmodule EvoGit.Sandbox do
  @moduledoc """
  Multi-platform sandbox dispatch module.

  Dispatches sandboxed command execution to the appropriate platform backend:

    * **Linux (systemd)** — `systemd-run` with full sandboxing: filesystem isolation,
      resource limits (CPU, memory), syscall filtering, and process isolation.
    * **Linux (bwrap)** — bubblewrap sandboxing (filesystem isolation, no resource limits).
    * **macOS** — `sandbox-exec` with filesystem isolation (read/write restrictions).
    * **Windows** — No sandbox; commands run directly.

  The active backend is determined by `EvoGit.Platform.sandbox_backend/0` unless
  overridden via the `[sandbox] backend` config key (`:auto` (default) → platform
  detection, `:systemd` → systemd-run, `:bwrap` → bubblewrap; explicit choices are
  availability-gated with fallback to no sandbox).

  The NO-SANDBOX state is reported honestly instead of silently: `backend_reason/0`
  returns a human-readable explanation of the current isolation state (including
  `EvoGit.Sandbox.None`, where commands run with no OS-level isolation at all), and
  `warn_if_unisolated/0` — called from every dispatch entry point (`run/4`,
  `run_with_partial/5,6,7`, `spawn_detached/1`) — logs a ONE-TIME warning when the
  configuration DEMANDS isolation (`[sandbox] mode = "enabled"`, or an explicit
  `[sandbox] backend`) while no backend is usable.
  """

  require Logger

  alias EvoGit.Platform

  # One-time (per BEAM) latch for the "demands isolation, but runs unisolated"
  # warning. `:persistent_term` is the documented once-only home here (the app
  # has no boot hook that could evaluate the sandbox state up front).
  @unisolated_warning_key {__MODULE__, :unisolated_warning_emitted}

  @type capabilities :: %{
          filesystem_isolation: boolean(),
          resource_limits: boolean(),
          backend: :systemd_run | :bwrap | :sandbox_exec | :none
        }

  @doc """
  Returns the active sandbox backend module based on config and platform availability.

  A test may pin the module through the call-time seam
  `Application.get_env(:evo_git, :sandbox_backend_override)` (unset → the normal
  config/platform resolution, so production behavior is byte-identical).
  """
  @spec backend() :: module()
  def backend do
    case Application.get_env(:evo_git, :sandbox_backend_override) do
      module when is_atom(module) and module not in [nil, true, false] -> module
      _ -> configured_backend()
    end
  end

  defp configured_backend do
    case EvoGit.Config.resolve([:sandbox, :backend]) do
      :auto ->
        platform_backend()

      :systemd ->
        if Platform.systemd_available?(), do: EvoGit.Sandbox.Linux, else: EvoGit.Sandbox.None

      :bwrap ->
        if Platform.bwrap_available?(), do: EvoGit.Sandbox.Bwrap, else: EvoGit.Sandbox.None

      # nil (key not yet in the config schema) or any unknown value → platform detection
      _ ->
        platform_backend()
    end
  end

  @doc "Returns the capabilities of the active sandbox backend."
  @spec capabilities() :: capabilities()
  def capabilities do
    case backend() do
      EvoGit.Sandbox.Linux ->
        %{filesystem_isolation: true, resource_limits: true, backend: :systemd_run}

      EvoGit.Sandbox.Bwrap ->
        %{filesystem_isolation: true, resource_limits: false, backend: :bwrap}

      EvoGit.Sandbox.MacOS ->
        %{filesystem_isolation: true, resource_limits: false, backend: :sandbox_exec}

      EvoGit.Sandbox.None ->
        %{filesystem_isolation: false, resource_limits: false, backend: :none}
    end
  end

  @doc "Returns whether sandbox is currently enabled (considering mode + platform)."
  @spec enabled?() :: boolean()
  def enabled? do
    backend().enabled?()
  end

  @doc """
  Returns a short, human-readable description of the CURRENT isolation state.

  Unlike the bare boolean `enabled?/0`, this string is meant for operators, logs
  and the dashboard — it names the backend that actually isolates commands, and
  says plainly when nothing does:

    * `"systemd-run sandbox active (filesystem isolation + resource limits)"`
    * `"bwrap sandbox active (filesystem isolation, no resource limits)"`
    * `"sandbox-exec sandbox active (filesystem isolation)"`
    * for `EvoGit.Sandbox.None` (the honest Windows story) a `[sandbox] mode`-aware
      "no OS-level isolation" explanation naming the platform and the actionable
      `[sandbox] backend` / `[sandbox] mode` fix

  Derived from the resolved `[:sandbox, :mode]` / `[:sandbox, :backend]` and
  `backend().enabled?()` — never from `:os.type/0` alone.
  """
  @spec backend_reason() :: String.t()
  def backend_reason do
    backend = backend()

    if backend.enabled?() do
      active_reason(backend)
    else
      unisolated_reason(resolved_mode(), backend_setting())
    end
  end

  @doc """
  Logs a ONE-TIME warning when the configuration DEMANDS OS-level isolation but
  no backend is usable, so commands run unisolated.

  Called from every dispatch entry point (`run/4`, `run_with_partial/5,6,7`,
  `spawn_detached/1`). Exactly one warning is emitted per BEAM (latched in
  `:persistent_term`), it is actionable (`[sandbox] backend` / `[sandbox] mode`),
  and it is NEVER emitted when sandboxing is genuinely on or when it was
  deliberately turned off (`[sandbox] mode = "disabled"`).

  Total: a diagnostic must never break the command it describes — it always
  returns `:ok`.
  """
  @spec warn_if_unisolated() :: :ok
  def warn_if_unisolated do
    if :persistent_term.get(@unisolated_warning_key, false) do
      # Already warned in this BEAM — the fast path costs one read and never
      # re-resolves the backend.
      :ok
    else
      case warning_for(resolved_mode(), backend_setting(), backend().enabled?()) do
        nil ->
          :ok

        message ->
          :persistent_term.put(@unisolated_warning_key, true)
          Logger.warning(message)
          :ok
      end
    end
  end

  @doc false
  # The pure decision mapping behind `warn_if_unisolated/0`, exposed for tests.
  #
  # `nil` (no warning) when sandboxing is deliberately disabled, when a backend
  # genuinely isolates, or when `[sandbox] mode = "auto"` / `[sandbox] backend =
  # "auto"` simply fell back to no sandbox (the documented platform behavior).
  # A warning string when the configuration DEMANDS isolation — `mode =
  # "enabled"`, or an explicit `[sandbox] backend` — and none is in effect.
  @spec warning_for(atom(), atom(), boolean()) :: String.t() | nil
  def warning_for(:disabled, _backend_setting, _backend_enabled?), do: nil
  def warning_for(_mode, _backend_setting, true), do: nil
  def warning_for(:auto, :auto, false), do: nil

  def warning_for(mode, backend_setting, false) do
    "Sandbox: " <> unisolated_reason(mode, backend_setting)
  end

  @doc false
  # Clears the once-only warning latch; tests only (a latched warning must not
  # leak across test cases).
  @spec reset_unisolated_warning() :: :ok
  def reset_unisolated_warning do
    case :persistent_term.get(@unisolated_warning_key, nil) do
      nil -> :ok
      _ -> :persistent_term.erase(@unisolated_warning_key)
    end
  end

  defp active_reason(EvoGit.Sandbox.Linux),
    do: "systemd-run sandbox active (filesystem isolation + resource limits)"

  defp active_reason(EvoGit.Sandbox.Bwrap),
    do: "bwrap sandbox active (filesystem isolation, no resource limits)"

  defp active_reason(EvoGit.Sandbox.MacOS),
    do: "sandbox-exec sandbox active (filesystem isolation)"

  defp active_reason(module), do: "#{inspect(module)} sandbox active"

  # The resolved `[sandbox] mode`. The call-time seam
  # `Application.get_env(:evo_git, :sandbox_mode_override)` lets a test inject a
  # mode without mutating app-global config; unset → production resolution.
  defp resolved_mode do
    case Application.get_env(:evo_git, :sandbox_mode_override) do
      mode when mode in [:auto, :enabled, :disabled] -> mode
      _ -> EvoGit.Config.resolve([:sandbox, :mode]) || :auto
    end
  end

  defp backend_setting do
    EvoGit.Config.resolve([:sandbox, :backend]) || :auto
  end

  defp unisolated_reason(:disabled, _backend_setting) do
    "sandbox disabled by configuration ([sandbox] mode = \"disabled\"): " <>
      "agent commands run UNISOLATED"
  end

  defp unisolated_reason(:auto, :auto) do
    "no OS-level sandbox available on #{platform_name()} " <>
      "([sandbox] mode = \"auto\", [sandbox] backend = \"auto\"): " <>
      "agent commands run UNISOLATED (no filesystem isolation, no resource limits)"
  end

  defp unisolated_reason(mode, backend_setting) do
    "NO OS-LEVEL ISOLATION on #{platform_name()}: " <>
      "[sandbox] mode = \"#{mode}\" and [sandbox] backend = \"#{backend_setting}\" " <>
      "demand a sandbox, but no OS-level backend is usable here, so agent commands " <>
      "run UNISOLATED (no filesystem isolation, no resource limits). " <>
      "Fix: install/enable that backend, or set " <>
      "[sandbox] mode = \"disabled\" to accept direct execution."
  end

  defp platform_name, do: Platform.os() |> to_string()

  @doc """
  Runs a command through the sandbox backend.

  On Linux, uses `systemd-run` with full isolation. On macOS, uses `sandbox-exec`
  with filesystem isolation. On Windows, runs commands directly.

  Emits the once-per-BEAM unisolated warning through `warn_if_unisolated/0` when
  isolation was demanded but no backend provides any.

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
    warn_if_unisolated()
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
  - `opts` - Keyword list of observability options (default: `[]`). The only key
    this layer defines is `:execution_id` — the `"proc-<n>"` record created by
    `EvoGit.ProcessManager.track/3` that the backend attaches its real OS handle
    to as soon as that identity is known. Tracking is best-effort and
    observability-only: it never changes the command, its output or its exit
    status, and a backend that does not implement the 7-arity callback is simply
    called with the 6-arity form.

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
          integer() | nil,
          keyword()
        ) ::
          {:ok, String.t(), non_neg_integer()} | {:timeout, String.t()}
  def run_with_partial(
        cwd,
        executable,
        args \\ [],
        repo_root \\ nil,
        timeout,
        max_bytes \\ nil,
        opts \\ []
      ) do
    warn_if_unisolated()
    backend = backend()
    resolved = EvoGit.Executable.resolve(executable)

    if Code.ensure_loaded?(backend) and function_exported?(backend, :run_with_partial, 7) do
      backend.run_with_partial(cwd, resolved, args, repo_root, timeout, max_bytes, opts)
    else
      backend.run_with_partial(cwd, resolved, args, repo_root, timeout, max_bytes)
    end
  end

  @doc "Ensures the sandbox backend is initialized (e.g., creates systemd slice)."
  @spec ensure_initialized() :: :ok | {:error, term()}
  def ensure_initialized do
    backend().ensure_initialized()
  end

  @doc """
  Starts a command in a **detached** process that outlives the caller.

  This is the ONE detached entry point, answered for EVERY backend: callers never
  branch on `backend/0` themselves. `EvoGit.Sandbox.Background` picks how a
  detached process is represented on the running platform (a transient systemd
  unit where available, a raw port elsewhere).

  `EvoGit.Sandbox.Behaviour` is deliberately NOT extended with this capability:
  the behaviour is the FOREGROUND `run/4` / `run_with_partial/6` contract, and a
  mandatory detached callback would break every backend for a capability only
  some of them implement natively.

  ## Parameters

  `spec` is a map with:

    * `:command` — the shell command line to run
    * `:cwd` — the working directory for the command
    * `:output_path` — the file the backend directs stdout/stderr to
    * `:job_id` — stable identifier, used in any unit/process name

  ## Returns

    * `{:ok, handle}` — where `handle` is
      `%{kind: :unit, unit: String.t(), backend: module(), port: port() | nil, pending_exit_code: integer() | nil}`
      (the `systemd-run --wait` client port is the job's exit OBSERVER — see
      `EvoGit.Sandbox.Background`) or
      `%{kind: :port, port: port(), os_pid: integer() | nil, backend: module()}`
    * `{:error, reason}` — the detached process could not be started
  """
  @spec spawn_detached(%{
          command: String.t(),
          cwd: String.t(),
          output_path: String.t(),
          job_id: String.t()
        }) :: {:ok, map()} | {:error, term()}
  def spawn_detached(spec) do
    warn_if_unisolated()
    EvoGit.Sandbox.Background.spawn(spec)
  end

  @doc """
  Stops a detached process started by `spawn_detached/1`.

  Idempotent from the caller's point of view: killing an already-exited job is
  not an error condition the caller must handle specially (the backend reports
  `:ok` when there is nothing left to stop).
  """
  @spec kill_detached(map()) :: :ok | {:error, term()}
  def kill_detached(handle) do
    EvoGit.Sandbox.Background.kill(handle)
  end

  @doc """
  Reports whether a detached process started by `spawn_detached/1` is still alive.

  Returns `{:running, nil}`, `{:exited, exit_code | nil}` or `{:unknown, nil}`
  when the backend cannot tell. `:unknown` must NOT be read as "still running"
  forever: completion normally arrives as the handle's observer port
  `{:exit_status, code}` message, and `EvoGit.BackgroundJobs` settles a job that
  stays `:unknown` beyond a bounded grace as terminally failed instead of
  leaving it live.
  """
  @spec detached_status(map()) ::
          {:running, nil} | {:exited, integer() | nil} | {:unknown, nil}
  def detached_status(handle) do
    EvoGit.Sandbox.Background.status(handle)
  end

  @doc """
  Resolves the writable `TMPDIR` value for use inside the sandbox.

  When a managed **per-task** tmpdir is installed on the current process
  (`EvoGit.TaskTmpdir.current/0` — set by the agent runner and re-installed by
  the tool-dispatch layer in every spawned tool task), that path is returned
  DIRECTLY, bypassing the "must be under `Platform.tmp_paths/0`" check below —
  the per-task dir may live under a custom base or a repository (both are made
  writable by the backends, see `EvoGit.Sandbox.Helpers`).

  Otherwise the legacy constant-resolution applies. Returns a path based on
  `Platform.tmp_paths/0`:

    * If `$TMPDIR` is unset, falls back to the first entry of `Platform.tmp_paths/0`
      (e.g. `/tmp` on Linux/macOS).
    * If `$TMPDIR` is set, keeps it only when its expanded path exists AND is equal
      to, or a subdirectory of, one of the `Platform.tmp_paths/0` entries.
      Otherwise falls back to the first entry.

  This prevents forwarding a `TMPDIR` that the sandbox profile does not cover
  (e.g. macOS `/var/folders/...`) or that points to a non-existent directory.
  The original system tmp dirs (`/tmp`, `/var/tmp`, Windows temp) remain fully
  writable inside the sandbox regardless — the per-task dir is an ADDITIONAL
  writable path + a `TMPDIR` override, never a replacement.
  """
  @spec resolve_tmpdir() :: String.t()
  def resolve_tmpdir do
    case EvoGit.TaskTmpdir.current() do
      path when is_binary(path) -> path
      _ -> system_tmpdir()
    end
  end

  # The legacy per-BEAM constant resolution (used when no per-task tmpdir is
  # installed on the calling process).
  defp system_tmpdir do
    tmp_paths = Platform.tmp_paths()
    default = List.first(tmp_paths)

    case System.get_env("TMPDIR") do
      nil ->
        default

      raw ->
        expanded = Platform.safe_expand(raw)

        if File.exists?(expanded) and under_any?(expanded, tmp_paths) do
          expanded
        else
          default
        end
    end
  end

  # Returns the backend module selected by platform capability detection
  # (`EvoGit.Platform.sandbox_backend/0`): systemd-run first, then bwrap,
  # then sandbox-exec, then no sandbox.
  defp platform_backend do
    case Platform.sandbox_backend() do
      :systemd_run -> EvoGit.Sandbox.Linux
      :bwrap -> EvoGit.Sandbox.Bwrap
      :sandbox_exec -> EvoGit.Sandbox.MacOS
      :none -> EvoGit.Sandbox.None
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
