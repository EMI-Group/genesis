defmodule EvoGit.DesktopParentMonitor do
  @moduledoc """
  Desktop-mode parent-death monitor.

  In the Tauri desktop app the backend runs as a sidecar child of the Rust
  shell. If the shell dies abnormally (Force Quit, crash, `kill -9`) there is
  no PDEATHSIG / process-group protection in the Rust shell, so the backend
  survives as an orphaned zombie — still holding its HTTP port, so the next
  app launch crashes with "port already in use".

  This GenServer closes that gap: the Rust shell passes its own OS pid via the
  `EVOGIT_PARENT_PID` env var (set in both `sidecar_env` and
  `headless_sidecar_env`), and this monitor polls that pid's liveness while
  enabled. When the parent is gone it logs a warning and stops the VM via
  `System.stop(0)`, freeing the port.

  ## Gating

  The monitor is appended to the supervision tree only when BOTH
  `EVOGIT_DESKTOP=1` and `EVOGIT_PARENT_PID` are set (see
  `EvoGit.Application.start/2`) — only the Tauri sidecar sets both, so
  manually-launched releases and the `genesis_remote` daemon are unaffected.
  As belt-and-suspenders, `init/1` also disables itself when
  `EVOGIT_PARENT_PID` is missing or empty, making a direct start a safe
  no-op.

  ## Test seams

  All three seams are `Application.get_env(:evo_git, ...)` reads so tests can
  swap them per-test (the established evo_git convention; the REAL
  `System.stop/0` must never run in the test VM):

  - `:parent_alive_check` — one-argument fun (`pid -> boolean`) replacing
    `default_alive?/1` (read at call time inside `handle_info`).
  - `:parent_stop_fun` — zero-arity fun replacing `default_stop/0`.
  - `:parent_monitor_interval_ms` — poll interval in ms (default 2000);
    tests use a large value and drive the logic by sending `:check_parent`
    directly (mirrors the `send(GenServer, :heartbeat)` pattern).
  """

  use GenServer

  require Logger

  @env_var "EVOGIT_PARENT_PID"

  @type state :: %{
          enabled: boolean(),
          parent_pid: String.t() | nil,
          interval_ms: pos_integer() | nil,
          stop_fun: (-> any()) | nil,
          stopped: boolean()
        }

  @doc """
  Starts the monitor.

  `opts` accepts `:interval_ms` (poll interval; falls back to the
  `:parent_monitor_interval_ms` application env, default 2000).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The default parent-alive check.

  - **Unix (macOS/Linux)**: `kill -0 <pid>` — exit 0 means the process
    exists, non-zero means it is gone.
  - **Windows**: `tasklist /FI "PID eq <pid>" /NH` — alive unless the output
    contains the "INFO: No tasks" line. (The `/FI` criteria text contains the
    pid itself, so a naive `String.contains?(output, pid)` would
    false-positive on every query.)

  Tooling failures (missing executable, exceptions) are logged and treated as
  **ALIVE**: a false-negative stop would silently close a healthy app, which
  is worse than a lingering zombie backend.
  """
  @spec default_alive?(String.t()) :: boolean()
  def default_alive?(pid) when is_binary(pid) do
    if EvoGit.Platform.windows?() do
      windows_alive?(pid)
    else
      unix_alive?(pid)
    end
  end

  @doc """
  The default stop action — gracefully stops the BEAM VM with exit code 0.

  Overridable via the `:parent_stop_fun` application env (tests inject a
  fake so the REAL `System.stop/0` never runs in the test VM).
  """
  @spec default_stop() :: no_return()
  def default_stop, do: System.stop(0)

  @impl true
  def init(opts) do
    case System.get_env(@env_var) do
      pid when pid in [nil, ""] ->
        # Disabled: no timer, safe no-op (a manually-launched release or a
        # direct start without the sidecar's env var must never misbehave).
        {:ok, %{enabled: false, parent_pid: nil, interval_ms: nil, stop_fun: nil, stopped: false}}

      parent_pid ->
        interval_ms =
          Keyword.get(opts, :interval_ms) ||
            Application.get_env(:evo_git, :parent_monitor_interval_ms, 2_000)

        stop_fun = Application.get_env(:evo_git, :parent_stop_fun, &__MODULE__.default_stop/0)

        # First check immediately, then every interval_ms.
        Process.send_after(self(), :check_parent, 0)

        {:ok,
         %{
           enabled: true,
           parent_pid: parent_pid,
           interval_ms: interval_ms,
           stop_fun: stop_fun,
           stopped: false
         }}
    end
  end

  @impl true
  def handle_info(:check_parent, %{enabled: false} = state) do
    # Disabled — nothing scheduled, nothing to do.
    {:noreply, state}
  end

  def handle_info(:check_parent, %{enabled: true, stopped: true} = state) do
    # Shutdown already initiated — never invoke the stop fun twice.
    {:noreply, state}
  end

  def handle_info(:check_parent, %{enabled: true} = state) do
    # Read the alive-check seam at call time so tests can swap it per-test.
    alive_check = Application.get_env(:evo_git, :parent_alive_check, &__MODULE__.default_alive?/1)

    if alive_check.(state.parent_pid) do
      Process.send_after(self(), :check_parent, state.interval_ms)
      {:noreply, state}
    else
      Logger.warning("[desktop] parent process #{state.parent_pid} is gone — shutting down")
      state.stop_fun.()
      # The stop fun stops the VM; no reschedule needed. Mark stopped so a
      # straggler :check_parent (e.g. the immediate first check racing a test
      # message) can never invoke it again.
      {:noreply, %{state | stopped: true}}
    end
  end

  defp unix_alive?(pid) do
    {_output, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    status == 0
  rescue
    error ->
      log_check_failure(error)
      true
  end

  defp windows_alive?(pid) do
    {output, _status} =
      System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH"], stderr_to_stdout: true)

    not String.contains?(output, "INFO: No tasks")
  rescue
    error ->
      log_check_failure(error)
      true
  end

  defp log_check_failure(error) do
    Logger.warning(
      "[desktop] parent alive check failed (#{Exception.message(error)}); assuming parent is alive"
    )
  end
end
