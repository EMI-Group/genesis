defmodule EvoGit.Sandbox.Background do
  @moduledoc """
  Detached (background) command execution for the sandbox subsystem.

  Long-running jobs — dev servers, watchers, builds — must outlive the agent
  turn that started them and must be startable, killable and observable without
  a blocking foreground call. `EvoGit.BackgroundJobs` owns the registry (output
  files, port messages, persistence, owner-process monitoring); this module owns
  ONLY the OS-level layer: start a command detached, kill it, and report whether
  it still runs.

  Jobs talk to the OS through **pipes and files only — no PTY is used**, which
  mirrors the reference DeepSeek Harness (its background jobs have no PTY
  either). The consequence is a buffering caveat: a non-TTY stdout is
  block-buffered by libc, so a program that relies on default buffering (most C
  programs, many language runtimes) shows its output in chunks rather than line
  by line; only programs that flush explicitly stream smoothly.

  ## Lifetime guarantee per backend

  `spawn/1` never blocks for the lifetime of the job. It returns a handle that
  records how the job is anchored to the OS, and that anchor is what `kill/1`
  targets:

    * **systemd-run (`EvoGit.Sandbox.Linux`)** — PRIMARY MECHANISM: a transient
      systemd *user* unit named `genesis-job-b<beam_os_pid>-<job_id>`. The job
      is NOT a child of the BEAM, so it SURVIVES a BEAM crash or restart, and
      ownership stays provable from the name (the embedded pid is the BEAM that
      created it). Termination is therefore always explicit
      (`systemctl --user stop`), and the unit is started WITHOUT `--collect` so
      its exit status stays queryable after it finishes.
    * **bwrap (`EvoGit.Sandbox.Bwrap`)** — the bwrap process is a session leader
      (`--new-session`) and, in full capability, the pid-namespace root, so
      killing its process group (`kill -TERM -- -<pgid>` → `-KILL`) takes the
      WHOLE sandbox tree down; `--die-with-parent` additionally kills it if the
      BEAM dies. PRIMARY guarantee = the bwrap process itself.
    * **sandbox-exec (`EvoGit.Sandbox.MacOS`)** — PRIMARY guarantee = the
      registry's owner-process monitor plus a process-group TERM→KILL of the
      `sandbox-exec` child. There is no pid namespace and no die-with-parent
      here, so a BEAM crash can LEAK the process.
    * **none (`EvoGit.Sandbox.None`, Windows / unsupported)** — PRIMARY
      guarantee = the registry's owner-process monitor plus a
      `taskkill /PID <pid> /T /F` tree kill on Windows. As on macOS, a BEAM
      crash can leak the process.

  `EvoGit.Sandbox.Behaviour` is deliberately NOT extended with these callbacks:
  background execution is an entry point layered ON TOP of the backends (it
  reuses their public argv builders, so env vars, isolation and writable-path
  grants match foreground execution exactly), not a fifth execution mode every
  backend must implement.

  Every function is total: OS failures come back as `{:error, term()}` and never
  raise.
  """

  require Logger

  alias EvoGit.{Platform, Sandbox.Helpers}

  # Upper bound on the ONE blocking spot of `spawn/1` — waiting for the
  # `systemd-run` client to hand the unit over to systemd. In practice this
  # returns in milliseconds (the client exits as soon as the unit starts).
  @systemd_run_timeout 5_000

  @typedoc """
  A background job request. `output_path`'s parent directory and the file
  itself are prepared by the caller (the registry) — the job only appends.
  """
  @type spec :: %{
          command: String.t(),
          cwd: String.t(),
          output_path: String.t(),
          job_id: String.t()
        }

  @typedoc """
  How a running job is anchored to the OS.

    * `:unit` — a transient systemd user unit (systemd-run backend);
    * `:port` — a directly spawned child (bwrap / sandbox-exec / none), whose
      port belongs to the calling registry process.
  """
  @type handle ::
          %{kind: :unit, unit: String.t(), backend: module()}
          | %{kind: :port, port: port(), os_pid: integer() | nil, backend: module()}

  @type status :: {:running, nil} | {:exited, integer() | nil} | {:unknown, nil}

  @doc """
  Starts `spec.command` detached in `spec.cwd`, appending stdout+stderr to
  `spec.output_path`.

  Dispatches on the ACTIVE sandbox backend (`EvoGit.Sandbox.backend/0`) and
  falls back to a plain shell child when that backend is not enabled (sandbox
  mode `:disabled`, or the test env) — mirroring every backend's
  `enabled?/false` path.

  Called from the registry GenServer process, so any Port opened here is OWNED
  by the registry: it receives `{port, {:data, chunk}}` and
  `{port, {:exit_status, code}}` messages.
  """
  @spec spawn(spec()) :: {:ok, handle()} | {:error, term()}
  def spawn(spec) do
    with :ok <- validate_spec(spec) do
      do_spawn(EvoGit.Sandbox.backend(), spec)
    end
  rescue
    error -> {:error, {:spawn_failed, error}}
  catch
    kind, reason -> {:error, {:spawn_failed, {kind, reason}}}
  end

  @doc """
  Terminates a background job.

  `:unit` handles stop the systemd unit in a spawned `Task` (the registry must
  never block on `systemctl`) and return `:ok` immediately. `:port` handles kill
  the process TREE via `EvoGit.Sandbox.Helpers.kill_process_tree/1`, leaving the
  port alone so the container's natural `{:exit_status, code}` message still
  reaches the registry.
  """
  @spec kill(handle()) :: :ok | {:error, term()}
  def kill(%{kind: :unit} = handle), do: stop_unit_async(handle)
  def kill(%{kind: :port} = handle), do: kill_port(handle)
  def kill(handle), do: {:error, {:invalid_handle, handle}}

  @doc """
  Reports whether a background job still runs.

  `:unit` handles are classified from `systemctl --user show` (the unit is
  retained after exit, so its exit status is still queryable); `:port` handles
  report `{:running, nil}` only while the port is open — the job's real exit
  code arrives as the port's own `{:exit_status, code}` message, which the
  registry owns.
  """
  @spec status(handle()) :: status()
  def status(%{kind: :unit} = handle), do: unit_status(handle)
  def status(%{kind: :port, port: port}), do: port_status(port)
  def status(_handle), do: {:unknown, nil}

  # ---------------------------------------------------------------------------
  # Spawn dispatch
  # ---------------------------------------------------------------------------

  defp do_spawn(EvoGit.Sandbox.Linux, spec) do
    if EvoGit.Sandbox.Linux.enabled?() do
      spawn_unit(spec)
    else
      # Sandbox mode disabled (or test env): systemd-run is not in play, so the
      # job runs as a plain shell child — the same fallback as `run/4`'s
      # disabled path.
      spawn_port(spec, EvoGit.Sandbox.Linux)
    end
  end

  defp do_spawn(EvoGit.Sandbox.Bwrap, spec) do
    if EvoGit.Sandbox.Bwrap.enabled?() do
      spawn_bwrap(spec)
    else
      spawn_port(spec, EvoGit.Sandbox.Bwrap)
    end
  end

  defp do_spawn(EvoGit.Sandbox.MacOS, spec) do
    if EvoGit.Sandbox.MacOS.enabled?() do
      spawn_macos(spec)
    else
      spawn_port(spec, EvoGit.Sandbox.MacOS)
    end
  end

  defp do_spawn(_backend, spec), do: spawn_port(spec, EvoGit.Sandbox.None)

  # -- systemd-run (transient user unit) --------------------------------------

  defp spawn_unit(spec) do
    unit = unit_name(spec.job_id)

    args =
      EvoGit.Sandbox.Linux.detached_args(
        spec.cwd,
        Platform.shell(),
        Platform.shell_args(spec.command),
        spec.output_path,
        unit
      )

    case systemd_run(args) do
      {:ok, _output} ->
        {:ok, %{kind: :unit, unit: unit, backend: EvoGit.Sandbox.Linux}}

      {:error, output} ->
        # A timed-out client may still have started the unit — never leak it.
        stop_unit_async(%{unit: unit})
        {:error, {:systemd_run_failed, output}}
    end
  end

  # Runs the systemd-run CLIENT and waits (bounded) for it to hand the unit
  # over to systemd. This is the single blocking spot of the whole module and
  # lasts milliseconds in practice: without `--wait` the client exits as soon
  # as the unit has started.
  defp systemd_run(args) do
    exec = resolve!("systemd-run")

    port =
      Port.open(
        {:spawn_executable, exec},
        [:binary, :exit_status, :hide, :stderr_to_stdout, {:args, args}]
      )

    result = await_start(port, [], @systemd_run_timeout)
    Helpers.close_port(port)
    Helpers.drain_port_messages(port)
    result
  end

  defp await_start(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        await_start(port, [acc, data], timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, code}} ->
        {:error, "systemd-run exited with status #{code}: #{IO.iodata_to_binary(acc)}"}
    after
      timeout ->
        {:error, "systemd-run did not return within #{timeout}ms: #{IO.iodata_to_binary(acc)}"}
    end
  end

  defp stop_unit_async(%{unit: unit}) do
    # Spawned so the registry is never blocked by systemctl — the same rule the
    # `:DOWN` path of `EvoGit.SandboxProcessRegistry` follows.
    Task.start(fn -> stop_unit(unit) end)
    :ok
  rescue
    _ -> :ok
  end

  defp stop_unit(unit) do
    full_unit = if String.ends_with?(unit, ".service"), do: unit, else: unit <> ".service"

    case Helpers.system_cmd("systemctl", ["--user", "stop", full_unit]) do
      {:ok, _output} ->
        Logger.debug("Sandbox.Background: stopped unit '#{full_unit}'")

      {:error, output} ->
        Logger.warning(
          "Sandbox.Background: failed to stop unit '#{full_unit}': #{String.trim(output)}"
        )
    end

    # Clear the failed/inactive residue so the unit's exit status does not
    # linger in systemd's failure list. Best-effort, never raises.
    Helpers.system_cmd("systemctl", ["--user", "reset-failed", full_unit])
    :ok
  end

  # -- bwrap ------------------------------------------------------------------

  defp spawn_bwrap(spec) do
    shell = Platform.shell()

    argv =
      EvoGit.Sandbox.Bwrap.args(
        spec.cwd,
        shell,
        Platform.shell_args(redirect_command(spec.command, spec.output_path)),
        nil
      )

    # No {:env} option, mirroring bwrap.ex's own port: the sandbox inherits the
    # caller env and gets TMPDIR/git identity via `--setenv` args instead.
    port =
      Port.open(
        {:spawn_executable, resolve!("bwrap")},
        [:binary, :exit_status, :hide, :stderr_to_stdout, {:args, argv}]
      )

    {:ok, port_handle(port, EvoGit.Sandbox.Bwrap)}
  end

  # -- sandbox-exec (macOS) ---------------------------------------------------

  defp spawn_macos(spec) do
    shell = Platform.shell()

    argv =
      ["-p", EvoGit.Sandbox.MacOS.effective_profile(spec.cwd, nil), "--", shell] ++
        Platform.shell_args(redirect_command(spec.command, spec.output_path))

    # Same TMPDIR injection shape as `MacOS.run/4`; `Helpers.port_env/1` converts
    # the pairs to the charlists `Port.open/2` demands.
    env = Helpers.port_env([{"TMPDIR", EvoGit.Sandbox.resolve_tmpdir()}])

    port =
      Port.open(
        {:spawn_executable, resolve!("sandbox-exec")},
        [
          :binary,
          :exit_status,
          :hide,
          :stderr_to_stdout,
          {:args, argv},
          {:cd, spec.cwd},
          {:env, env}
        ]
      )

    {:ok, port_handle(port, EvoGit.Sandbox.MacOS)}
  end

  # -- none (Windows / unsupported, and every disabled path) ------------------

  defp spawn_port(spec, backend) do
    shell = Platform.shell()

    port =
      Port.open(
        {:spawn_executable, resolve!(shell)},
        [:binary, :exit_status, :hide, :stderr_to_stdout] ++
          [
            {:args, Platform.shell_args(redirect_command(spec.command, spec.output_path))},
            {:cd, spec.cwd}
          ] ++
          env_option()
      )

    {:ok, port_handle(port, backend)}
  end

  # The managed per-task tmpdir (when one is installed on this process) is
  # exported to the child exactly like the non-sandboxed foreground paths do.
  # `{:env, []}` is omitted entirely rather than passed empty.
  defp env_option do
    case Helpers.temp_env_vars() do
      [] -> []
      vars -> [{:env, Helpers.port_env(vars)}]
    end
  end

  defp port_handle(port, backend) do
    os_pid =
      case Helpers.wait_for_os_pid(port) do
        pid when is_integer(pid) -> pid
        _ -> nil
      end

    %{kind: :port, port: port, os_pid: os_pid, backend: backend}
  end

  # ---------------------------------------------------------------------------
  # Kill / status
  # ---------------------------------------------------------------------------

  defp kill_port(%{port: port, os_pid: os_pid}) do
    if is_integer(os_pid) do
      # Leave the port open: the child's death produces the natural
      # `{:exit_status, code}` message the registry records.
      Helpers.kill_process_tree(os_pid)
    else
      # No pid was ever observed (pathological) — closing the port kills the
      # child and releases the resource.
      Helpers.close_port(port)
    end
  rescue
    _ -> {:error, :kill_failed}
  catch
    _, _ -> {:error, :kill_failed}
  end

  defp unit_status(%{unit: unit}) do
    if System.find_executable("systemctl") do
      args = [
        "--user",
        "show",
        unit,
        "-p",
        "ActiveState",
        "-p",
        "ExecMainStatus",
        "-p",
        "ExecMainCode"
      ]

      case System.cmd("systemctl", args, stderr_to_stdout: false) do
        {output, 0} -> output |> parse_systemctl_show() |> classify_unit_state()
        {_output, _code} -> {:unknown, nil}
      end
    else
      {:unknown, nil}
    end
  rescue
    _ -> {:unknown, nil}
  catch
    _, _ -> {:unknown, nil}
  end

  defp port_status(port) do
    case Port.info(port) do
      # `nil` (closed) and `:undefined` (not alive) both mean the child is gone;
      # its real exit code travelled in the port's `{:exit_status, code}`
      # message, which the registry owns.
      info when is_list(info) -> {:running, nil}
      _ -> {:unknown, nil}
    end
  rescue
    _ -> {:unknown, nil}
  catch
    _, _ -> {:unknown, nil}
  end

  # ---------------------------------------------------------------------------
  # Pure helpers (public for testing)
  # ---------------------------------------------------------------------------

  @doc false
  # A transient systemd unit name embedding the OWNING BEAM's OS pid, so a
  # later boot can prove ownership of a unit a crashed runtime left behind.
  # Characters systemd rejects in unit names are folded to "_" (job ids are
  # `"bash-<16 hex>"` in practice, so this is purely defensive).
  @spec unit_name(String.t()) :: String.t()
  def unit_name(job_id) when is_binary(job_id) do
    "genesis-job-b#{System.pid()}-#{String.replace(job_id, ~r/[^A-Za-z0-9_.:-]/, "_")}"
  end

  @doc false
  # Parses `systemctl show`'s `Key=Value` lines into a map. Garbled/empty
  # lines are skipped — an unparsable output yields `%{}`, which classifies as
  # `{:unknown, nil}`.
  @spec parse_systemctl_show(String.t()) :: %{optional(String.t()) => String.t()}
  def parse_systemctl_show(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  def parse_systemctl_show(_output), do: %{}

  @doc false
  # Classifies a `systemctl show` map into the handle status contract:
  #
  #   | ActiveState                        | ExecMain*                    | status |
  #   |------------------------------------|------------------------------|--------|
  #   | active / activating / reloading    | any                          | {:running, nil} |
  #   | inactive                           | ExecMainCode=1               | {:exited, ExecMainStatus} |
  #   | inactive                           | ExecMainCode=2 (signal)      | {:exited, nil} |
  #   | failed                             | ExecMainCode=2 (signal)      | {:exited, nil} |
  #   | failed                             | any other code               | {:exited, ExecMainStatus or nil} |
  #   | inactive w/ other code, unknown,   | any                          | {:unknown, nil} |
  #   | missing or garbled ActiveState     |                              |        |
  #
  # A `failed` unit therefore surfaces as a non-zero/failed EXIT, never as a
  # crash of the caller.
  @spec classify_unit_state(map()) :: status()
  def classify_unit_state(%{"ActiveState" => state} = info) do
    case state do
      active when active in ["active", "activating", "reloading"] ->
        {:running, nil}

      "inactive" ->
        case info["ExecMainCode"] do
          "1" -> {:exited, int_or_nil(info["ExecMainStatus"])}
          "2" -> {:exited, nil}
          _ -> {:unknown, nil}
        end

      "failed" ->
        case info["ExecMainCode"] do
          "2" -> {:exited, nil}
          _ -> {:exited, int_or_nil(info["ExecMainStatus"])}
        end

      _other ->
        {:unknown, nil}
    end
  end

  def classify_unit_state(_info), do: {:unknown, nil}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp validate_spec(
         %{command: command, cwd: cwd, output_path: output_path, job_id: job_id} = spec
       )
       when is_binary(command) and is_binary(cwd) and is_binary(output_path) and is_binary(job_id) do
    if command == "" or cwd == "" or output_path == "" or job_id == "" do
      {:error, {:invalid_spec, spec}}
    else
      :ok
    end
  end

  defp validate_spec(spec), do: {:error, {:invalid_spec, spec}}

  # Appends stdout+stderr to `output_path` inside the command STRING (used by
  # the shell-spawned backends; systemd-run uses its own StandardOutput/
  # StandardError properties instead).
  #
  # The command string is GROUPED before redirecting: `a && b >> f` would only
  # redirect `b`, losing everything the earlier commands printed.
  defp redirect_command(command, output_path) do
    if EvoGit.Powershell.powershell_executable?(Platform.shell()) do
      # PowerShell is NOT POSIX — a single-quoted string is a literal and
      # `'\''` escaping does not apply — so the redirection target is
      # double-quoted with the backtick escape, and `& { ... }` is the
      # equivalent of the POSIX subshell grouping. The whole script is handed to
      # `-EncodedCommand` afterwards, so these quotes never travel through argv.
      "& { " <> command <> " } >> \"" <> String.replace(output_path, "\"", "`\"") <> "\" 2>&1"
    else
      "(" <> command <> ") >> " <> Helpers.shell_escape(output_path) <> " 2>&1"
    end
  end

  # Resolves an executable to an absolute path — `Port.open/2`'s
  # `:spawn_executable` does no PATH search. Raises `:enoent` (caught by the
  # caller's rescue) so a missing binary surfaces as `{:error, ...}`.
  defp resolve!(name) do
    case EvoGit.Sandbox.None.resolve_executable(name) do
      resolved when is_binary(resolved) -> resolved
      _ -> :erlang.error(:enoent, [name])
    end
  end

  defp int_or_nil(nil), do: nil

  defp int_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp int_or_nil(_value), do: nil
end
