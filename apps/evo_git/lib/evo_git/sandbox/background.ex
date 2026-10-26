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
      (`systemctl --user stop`). Completion is observed by the
      `systemd-run --wait` CLIENT: it stays alive for the unit's whole lifetime
      and exits with the unit's own status, and its port (kept open in the
      handle) is owned by the registry, which records the exit. A post-mortem
      `systemctl --user show <unit>` is NOT a reliable completion source —
      systemd unloads a successfully-exited transient unit immediately
      (`CollectMode=inactive`), so only FAILED units remain queryable. A job
      that outlives its BEAM loses its observer (the client dies with the BEAM)
      and is garbage-collected by the boot sweep instead.
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

  ## Output capture

  Port-based backends (bwrap, sandbox-exec, none, and every disabled path) spawn
  the command through the platform shell with `:stderr_to_stdout`, and the
  registry (`EvoGit.BackgroundJobs`) appends each port `{:data, chunk}` message
  to the job's output file. The command string therefore reaches the shell
  VERBATIM — it is never wrapped in an in-shell redirection, because grouping it
  (`( command ) >> file 2>&1`) breaks any command containing `#`, a heredoc or a
  trailing comment.

  The systemd backend has no port OUTPUT stream: systemd writes the file directly
  via `-p StandardOutput=append:<path>` / `-p StandardError=append:<path>`. Its
  port carries no job output at all — it is the `systemd-run --wait` client's
  port, used only as the exit OBSERVER, so any `{:data, _}` arriving on it is
  client diagnostics and is discarded by the registry.

  ## Boot sweep

  `sweep_stale_units/0` runs at registry boot and closes the systemd-run
  crash leak: it never touches a unit whose embedded `b<beam_os_pid>` is still
  a live process (a job belonging to another running instance must survive),
  and `reset-failed` only garbage-collects already-dead transient units.

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

  # Upper bound on the START GRACE window of a detached systemd job. The
  # `systemd-run --wait` client lives for the unit's WHOLE lifetime, so "the
  # client is still alive after this window" means the unit started and the
  # client's port is now the job's exit observer; a client that exits INSIDE
  # the window is either an immediately-finished job or a start failure (see
  # `spawn_unit/1`). Kept short: it is the one blocking spot of `spawn/1`.
  @start_grace_ms 1_000
  # Bounded settle-poll for a unit that is briefly `deactivating` before landing
  # in `failed` (an immediately-failing background command) — 5 × 50 ms of grace
  # plus the `systemctl show` round trips themselves.
  @unit_settle_attempts 5
  @unit_settle_interval_ms 50

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

    * `:unit` — a transient systemd user unit (systemd-run backend). `port` is
      the still-open `systemd-run --wait` CLIENT port — the completion
      OBSERVER, owned by the calling registry process: its
      `{port, {:exit_status, code}}` message carries the UNIT's exit status. It
      is `nil` only when the unit exited inside the start grace window, in
      which case `pending_exit_code` carries the already-observed status.
    * `:port` — a directly spawned child (bwrap / sandbox-exec / none), whose
      port belongs to the calling registry process.
  """
  @type handle ::
          %{
            kind: :unit,
            unit: String.t(),
            backend: module(),
            port: port() | nil,
            pending_exit_code: integer() | nil
          }
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
  `{port, {:exit_status, code}}` messages. That is true for BOTH handle shapes —
  a `:unit` handle keeps the `systemd-run --wait` client's port open as the
  job's exit observer (see `spawn_unit/1`), so a unit job's completion arrives
  as a port message exactly like a `:port` job's.

  Errors are `{:error, term()}` for EVERY backend, including
  `{:error, {:invalid_spec, spec}}` (an incomplete/blank spec) and
  `{:error, {:cwd_missing, String.t()}}` (the working directory does not exist —
  validated up front, so no backend can hand back a handle for a job that never
  ran).
  """
  @spec spawn(spec()) :: {:ok, handle()} | {:error, term()}
  def spawn(spec) do
    with :ok <- validate_spec(spec),
         :ok <- validate_cwd(spec) do
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
  never block on `systemctl`) and return `:ok` immediately; the unit's exit
  observer port then closes on its own. `:port` handles kill
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

  `:unit` handles are classified from `systemctl --user show` — which reports a
  unit only while it runs or after it FAILED (systemd unloads a successfully
  exited transient unit immediately), so it is a FALLBACK, not the completion
  source: the job's real exit status arrives as the observer port's own
  `{:exit_status, code}` message, which the registry owns. `:port` handles
  report `{:running, nil}` only while the port is open — their exit code
  arrives through that same port message.
  """
  @spec status(handle()) :: status()
  def status(%{kind: :unit} = handle), do: unit_status(handle)
  def status(%{kind: :port, port: port}), do: port_status(port)
  def status(_handle), do: {:unknown, nil}

  @doc """
  Garbage-collects detached units a CRASHED runtime left behind.

  The systemd-run backend's jobs are deliberately NOT children of the BEAM (they
  must outlive it), so a BEAM crash leaves its transient units behind with
  nobody left to stop them. The registry calls this once at boot to close that
  leak — WITHOUT ever harming a job belonging to another Genesis instance still
  running on the same host:

    * `inactive` / `failed` units hold no process any more, so they are only
      garbage-collected (`systemctl --user reset-failed`).
    * `active` / `activating` / `reloading` units are stopped ONLY when the
      `b<beam_os_pid>` embedded in the unit name (`genesis-job-b<pid>-<job_id>`)
      is NOT a live process. A live pid means the owning BEAM is still running,
      so the unit is left strictly alone — as is any unit whose pid cannot be
      extracted from its name: the sweep never stops something it cannot
      attribute.

  Acts only when the ACTIVE backend is `EvoGit.Sandbox.Linux` (the systemd-run
  backend) and `systemctl` exists; every other case is a no-op. Total: refuses
  to raise, always returns `:ok`.
  """
  @spec sweep_stale_units() :: :ok
  def sweep_stale_units do
    if EvoGit.Sandbox.backend() == EvoGit.Sandbox.Linux do
      list_job_units() |> Enum.each(&sweep_unit/1)
    end

    :ok
  rescue
    error ->
      Logger.warning("Sandbox.Background: unit sweep failed: #{inspect(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Sandbox.Background: unit sweep failed: #{inspect({kind, reason})}")
      :ok
  end

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

  # The unit runs detached (`--unit=<name>`), but the `systemd-run --wait`
  # CLIENT stays alive for the unit's whole lifetime and exits with the unit's
  # OWN exit status. That client — not a post-mortem `systemctl show` — is the
  # completion signal: its port is kept OPEN and stored in the handle, so the
  # registry (which calls this from its own process, and therefore owns the
  # port) receives `{port, {:exit_status, code}}` when the job ends.
  #
  # The client therefore does not return at unit START, so the start-failure
  # contract is recovered from a short START GRACE window on the port:
  #
  #   * still running after the grace  → the unit started; keep the port as the
  #     exit observer (the normal path);
  #   * exits 0 within the grace       → an immediately-finished job with exit
  #     code 0 (`pending_exit_code` on the handle, applied by the registry);
  #   * exits non-zero within the grace → EITHER the unit ran and failed
  #     immediately (e.g. command not found → 127; a FAILED unit IS retained, so
  #     its status is queryable) OR `systemd-run` itself could not start the
  #     unit (no unit exists → `systemctl show` fails). The retained-unit query
  #     decides, and the client's own stderr (unit output goes to the log file,
  #     so only systemd-run diagnostics land here) becomes the error detail.
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

    port =
      Port.open(
        {:spawn_executable, resolve!("systemd-run")},
        [:binary, :exit_status, :hide, :stderr_to_stdout, {:args, args}]
      )

    case await_start(port, [], @start_grace_ms) do
      {:running, _diagnostics} ->
        {:ok, %{kind: :unit, unit: unit, backend: EvoGit.Sandbox.Linux, port: port}}

      {:exited, code, diagnostics} ->
        immediate_unit_exit(unit, port, code, diagnostics)
    end
  end

  # The client exited inside the start grace window: settle whether the unit
  # really ran (→ an immediate job completion with its exit code) or whether
  # `systemd-run` itself failed (→ a spawn failure, never a job that can never
  # complete).
  defp immediate_unit_exit(unit, port, 0, _diagnostics) do
    close_observer(port)
    {:ok, %{kind: :unit, unit: unit, backend: EvoGit.Sandbox.Linux, pending_exit_code: 0}}
  end

  defp immediate_unit_exit(unit, port, code, diagnostics) do
    # A unit that FAILED stays retained by systemd, so it is queryable here;
    # give the state a moment to settle (`deactivating` → `failed`) before
    # concluding the unit never existed.
    unit_status = await_settled_unit_status(unit, @unit_settle_attempts)

    close_observer(port)

    case unit_status do
      {:exited, exit_code} ->
        {:ok,
         %{kind: :unit, unit: unit, backend: EvoGit.Sandbox.Linux, pending_exit_code: exit_code}}

      _ ->
        # No retained unit → `systemd-run` could not start it at all. Stop the
        # (possibly half-created) unit defensively and report the client's own
        # output, which carries systemd-run's diagnostic.
        Logger.warning(
          "Sandbox.Background: systemd-run could not start unit '#{unit}' (client exit #{code}): #{String.trim(diagnostics)}"
        )

        stop_unit_async(%{unit: unit})
        {:error, {:systemd_run_failed, diagnostics}}
    end
  end

  defp close_observer(port) do
    Helpers.close_port(port)
    Helpers.drain_port_messages(port)
  end

  # Polls `systemctl --user show` a bounded number of times: an immediate unit
  # failure is briefly `deactivating` before landing in `failed`, and anything
  # that never becomes readable stays `{:unknown, nil}`.
  defp await_settled_unit_status(unit, attempts) do
    case unit_status(%{unit: unit}) do
      {:unknown, _} when attempts > 0 ->
        Process.sleep(@unit_settle_interval_ms)
        await_settled_unit_status(unit, attempts - 1)

      status ->
        status
    end
  end

  defp await_start(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        await_start(port, [acc, data], timeout)

      {^port, {:exit_status, code}} ->
        {:exited, code, IO.iodata_to_binary(acc)}
    after
      timeout ->
        {:running, IO.iodata_to_binary(acc)}
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
    full_unit = service_name(unit)

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
        Platform.shell_args(spec.command),
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
        Platform.shell_args(spec.command)

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
            {:args, Platform.shell_args(spec.command)},
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

  @doc false
  # Parses `systemctl --user list-units --all --plain --no-legend 'genesis-job-*'`
  # output into `{unit, load, active, sub, description}` tuples, i.e. systemd's
  # column order (UNIT LOAD ACTIVE SUB DESCRIPTION). `String.split/1` collapses
  # both extra and running-together whitespace; the description is the only
  # free-form column, so the remaining columns are re-joined with one space.
  # Lines with fewer than four columns (garbled output, a stray legend/footer)
  # are skipped. A non-binary input yields `[]`.
  @spec parse_list_units(term()) ::
          [{String.t(), String.t(), String.t(), String.t(), String.t()}]
  def parse_list_units(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [unit, load, active, sub | description] ->
          [{unit, load, active, sub, Enum.join(description, " ")}]

        _ ->
          []
      end
    end)
  end

  def parse_list_units(_output), do: []

  @doc false
  # Extracts the OWNING BEAM's OS pid from a `genesis-job-b<pid>-<job_id>` unit
  # name (the ".service" suffix is optional). Any other name is `:error` — it is
  # NOT attributed to anyone, and the sweep never stops a unit it cannot
  # attribute.
  @spec beam_pid_from_unit(term()) :: {:ok, integer()} | :error
  def beam_pid_from_unit(unit) when is_binary(unit) do
    base = String.replace_suffix(unit, ".service", "")

    case Regex.run(~r/\Agenesis-job-b(\d+)-/, base) do
      [_match, digits] -> {:ok, String.to_integer(digits)}
      _ -> :error
    end
  end

  def beam_pid_from_unit(_unit), do: :error

  # ---------------------------------------------------------------------------
  # Boot sweep internals
  # ---------------------------------------------------------------------------

  defp list_job_units do
    if System.find_executable("systemctl") do
      args = ["--user", "list-units", "--all", "--plain", "--no-legend", "genesis-job-*"]

      # stderr is NOT merged: a host whose systemd user bus is unreachable
      # (containers, headless CI, a systemd-less distro) prints an error there
      # and exits non-zero — that must stay out of the parsed table.
      case System.cmd("systemctl", args, stderr_to_stdout: false) do
        {output, 0} -> parse_list_units(output)
        {_output, _code} -> []
      end
    else
      []
    end
  end

  # `inactive`/`failed` units own no process any more → just garbage-collected.
  # A still-active unit is stopped ONLY when its embedded owning-BEAM pid is
  # provably dead; anything unattributable (or any other ActiveState) is left
  # untouched.
  defp sweep_unit({unit, _load, active, _sub, _description}) do
    cond do
      active in ["inactive", "failed"] ->
        reset_failed_unit(unit)

      active in ["active", "activating", "reloading"] ->
        case beam_pid_from_unit(unit) do
          {:ok, pid} ->
            if process_alive?(pid) do
              Logger.debug(
                "Sandbox.Background: leaving unit '#{unit}' alone — owning runtime (pid #{pid}) is alive"
              )
            else
              stop_and_reset_unit(unit)
            end

          :error ->
            Logger.debug(
              "Sandbox.Background: leaving unit '#{unit}' alone — no owning pid in its name"
            )
        end

      true ->
        :ok
    end
  end

  defp sweep_unit(_row), do: :ok

  # POSIX liveness probe for the pid embedded in a unit name. A NON-ZERO exit
  # means the pid is unusable (ESRCH: gone; EPERM: recycled by another user's
  # process, so the BEAM that created the unit is gone either way) → not alive.
  # A probe that cannot even run errs on the SAFE side and reports `true`, so a
  # unit is never stopped on the strength of a failed probe.
  defp process_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _code} -> false
    end
  rescue
    _ -> true
  catch
    _, _ -> true
  end

  # Stops an ATTRIBUTED stale unit (its owning BEAM is provably gone), then
  # garbage-collects it — the same stop-then-reset-failed pair `kill/1` uses.
  defp stop_and_reset_unit(unit) do
    full_unit = service_name(unit)

    case Helpers.system_cmd("systemctl", ["--user", "stop", full_unit]) do
      {:ok, _output} ->
        Logger.info(
          "Sandbox.Background: stopped stale unit '#{full_unit}' — its owning runtime is gone"
        )

      {:error, output} ->
        Logger.warning(
          "Sandbox.Background: failed to stop stale unit '#{full_unit}': #{String.trim(output)}"
        )
    end

    reset_failed_unit(full_unit)
  end

  defp reset_failed_unit(unit) do
    Helpers.system_cmd("systemctl", ["--user", "reset-failed", service_name(unit)])
    :ok
  end

  defp service_name(unit) do
    if String.ends_with?(unit, ".service"), do: unit, else: unit <> ".service"
  end

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

  # The working directory is validated for EVERY backend, not just the ones that
  # notice: an unusable cwd fails the systemd-run client loudly, but
  # `Port.open/2` happily accepts a `{:cd, dir}` that does not exist and the
  # child then dies in the port-setup `chdir` (exit status 2, before `exec`), so
  # the port path would otherwise answer `{:ok, handle}` for a job that never
  # ran. This is the layer-below backstop for the registry's own
  # `normalize_start_spec/1` check, which already rejects a missing cwd with
  # prose before reaching here. Runs only after `validate_spec/1` succeeded, so
  # `cwd` is always a binary here.
  defp validate_cwd(%{cwd: cwd}) when is_binary(cwd) do
    if File.dir?(cwd), do: :ok, else: {:error, {:cwd_missing, cwd}}
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
