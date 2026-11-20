defmodule EvoGit.ProcessManager.Control do
  @moduledoc """
  Behaviour + dispatcher for OS-level control of a tracked execution.

  `EvoGit.ProcessManager` never talks to the operating system itself: it holds
  the record, and this layer performs the probe/signal/kill against a
  `EvoGit.ProcessManager.Handle`, dispatched on the handle's `:kind`:

  | `kind`           | backend                        | mechanism |
  |------------------|--------------------------------|-----------|
  | `:systemd_unit`  | `Control.Systemd`              | `systemctl --user show/kill/stop` |
  | `:posix`         | `Control.Posix`                | `/proc` (Linux) or one `ps` table (macOS/BSD), `kill -SIG -- -pgid` |
  | `:windows`       | `Control.Windows`              | `tasklist` / `taskkill` |

  Every callback is **TOTAL**: a failed probe is `{:error, reason}`, an
  unobservable figure is a `nil` field, and nothing ever raises. That is what
  lets the registry and the caller-side sample path treat an OS hiccup as data
  instead of a crash. A backend that DOES raise is contained by `guarded/2`,
  which tags the crash by the operation that failed (`:probe_failed` for a
  stats probe, `:kill_failed` for a kill, `:signal_failed` for a signal) so a
  crashed kill is never reported as a probe failure.

  `alive?/1` answers a boolean (false for an unknown handle), because it is a
  predicate a caller branches on rather than an error it must format.

  ## Signals

  `normalize_signal/1` maps the small atom vocabulary the public API exposes
  (`:term | :kill | :int | :hup | :stop | :cont | :usr1 | :usr2`) onto the
  POSIX signal NAME, and passes a binary through (upcased), so a caller may send
  `:term`, `"TERM"` or `"SIGKILL"`. `Control.signal/2` normalizes ONCE and the
  backends receive that NAME as authoritative — they never re-normalize or
  re-validate it. `status_after_signal/1` says which status a successful signal
  implies (`SIGSTOP` → `:paused`, `SIGCONT` → `:running`, anything else → no
  status change), so pause/resume and the registry agree on ONE rule.

  ## Kill escalation

  Killing is TERM → short grace → KILL (the grace window is read at CALL time
  from the app env `:process_kill_grace_ms`, default
  `#{1500}`), then a final `alive?/1` verification: a well-behaved process gets
  the chance to flush and exit, and the caller learns whether the handle is
  really gone. The KILL attempt ALWAYS happens, even when the TERM itself
  failed (a dead group leader with live children is exactly what the
  escalation exists for), and `kill_outcome/3` turns the three observations
  into ONE verdict: a gone handle is `:ok`, otherwise the first REAL backend
  failure wins (KILL, then TERM), and `{:error, :still_alive}` means only that
  both signals were delivered and the handle is still there.
  """

  alias EvoGit.ProcessManager.{Handle, Stats}

  @typedoc """
  The signal vocabulary a CALLER may pass to `EvoGit.ProcessManager.signal/3`:
  the atom shorthand or a raw name binary. It is normalized ONCE by
  `normalize_signal/1` / `Control.signal/2`; a backend only ever sees the NAME.
  """
  @type signal :: :term | :kill | :int | :hup | :stop | :cont | :usr1 | :usr2 | String.t()

  # Grace between SIGTERM and SIGKILL — time for a well-behaved process to
  # flush and exit before the hard kill. Read at CALL time (app env
  # `:process_kill_grace_ms`), so a suite can shrink it.
  @kill_grace_ms 1_500

  @doc """
  Probes the handle's live resource usage.
  Returns `{:ok, stats}` with the frozen stats map (see
  `EvoGit.ProcessManager.Stats`), or `{:error, reason}` when the backend cannot
  answer at all (no executable, no pid, process already gone). The success
  payload is ALWAYS a map — an unparseable probe is an error, never a `nil`.
  """
  @callback stats(Handle.t()) :: {:ok, Stats.t()} | {:error, term()}

  @doc """
  Delivers one signal to the handle (the whole tree/unit, not just the leader).

  The signal NAME is authoritative: `Control.signal/2` normalizes it with
  `normalize_signal/1` exactly ONCE and a backend must not normalize or
  validate it again (`"TERM"`, `"SIGKILL"`, …). A backend's own escalation
  calls `signal/2` directly with those literal names.
  """
  @callback signal(Handle.t(), String.t()) :: :ok | {:error, term()}

  @doc """
  Terminates the handle: TERM, a short grace, then KILL; then verifies.

  A real backend failure is answered with its OWN reason (a failed/EPERM kill,
  an unavailable `kill`/`systemctl`); `{:error, :still_alive}` means only that
  both signals were delivered and the handle is still there.
  """
  @callback kill(Handle.t()) :: :ok | {:error, term()}

  @doc "Whether the handle still refers to a live OS execution."
  @callback alive?(Handle.t()) :: boolean()

  @backends %{
    systemd_unit: EvoGit.ProcessManager.Control.Systemd,
    posix: EvoGit.ProcessManager.Control.Posix,
    windows: EvoGit.ProcessManager.Control.Windows
  }

  @doc "The backend module implementing control for a handle (nil for an unknown handle)."
  @spec backend_for(Handle.t() | nil) :: module() | nil
  def backend_for(%Handle{kind: kind}), do: Map.get(@backends, kind)
  def backend_for(_handle), do: nil

  @doc "See `c:stats/1`. Total: a missing backend answers `{:error, :no_handle}`."
  @spec stats(Handle.t() | nil) :: {:ok, Stats.t()} | {:error, term()}
  def stats(handle), do: dispatch(:stats, handle)

  @doc "See `c:signal/2`. Total: a missing backend answers `{:error, :no_handle}`."
  @spec signal(Handle.t() | nil, signal()) :: :ok | {:error, term()}
  def signal(handle, signal), do: dispatch_signal(handle, signal)

  @doc "See `c:kill/1`. Total: a missing backend answers `{:error, :no_handle}`."
  @spec kill(Handle.t() | nil) :: :ok | {:error, term()}
  def kill(handle), do: dispatch(:kill, handle)

  @doc "See `c:alive?/1`. Total: a missing backend answers `false`."
  @spec alive?(Handle.t() | nil) :: boolean()
  def alive?(handle) do
    case backend_for(handle) do
      nil ->
        false

      module ->
        try do
          module.alive?(handle) == true
        rescue
          _ -> false
        catch
          _, _ -> false
        end
    end
  end

  @doc """
  Normalizes a signal to its NAME (`"TERM"`, `"KILL"`, `"USR1"`, …).
  A binary is upcased and passed through verbatim (`"SIGTERM"` and `"TERM"` are
  both accepted by `kill` and `systemctl kill`). Returns
  `{:error, :invalid_signal}` for anything else.
  """
  @spec normalize_signal(term()) :: {:ok, String.t()} | {:error, :invalid_signal}
  def normalize_signal(:term), do: {:ok, "TERM"}
  def normalize_signal(:kill), do: {:ok, "KILL"}
  def normalize_signal(:int), do: {:ok, "INT"}
  def normalize_signal(:hup), do: {:ok, "HUP"}
  def normalize_signal(:stop), do: {:ok, "STOP"}
  def normalize_signal(:cont), do: {:ok, "CONT"}
  def normalize_signal(:usr1), do: {:ok, "USR1"}
  def normalize_signal(:usr2), do: {:ok, "USR2"}

  def normalize_signal(signal) when is_binary(signal) do
    case String.trim(signal) do
      "" -> {:error, :invalid_signal}
      name -> {:ok, String.upcase(name)}
    end
  end

  def normalize_signal(_signal), do: {:error, :invalid_signal}

  @doc "The signal NAME a signal normalizes to, or nil when it is invalid."
  @spec signal_name(term()) :: String.t() | nil
  def signal_name(signal) do
    case normalize_signal(signal) do
      {:ok, name} -> name
      {:error, _reason} -> nil
    end
  end

  @doc """
  The status a successful signal implies: `:paused` for `SIGSTOP`, `:running`
  for `SIGCONT`, `nil` (no status change) for every other signal.
  """
  @spec status_after_signal(term()) :: :paused | :running | nil
  def status_after_signal(signal) do
    case normalize_signal(signal) do
      {:ok, "STOP"} -> :paused
      {:ok, "CONT"} -> :running
      _ -> nil
    end
  end

  @doc """
  The grace (ms) between SIGTERM and SIGKILL.
  Read at CALL time from the app env `:process_kill_grace_ms` (a non-negative
  integer), falling back to `#{@kill_grace_ms}`.
  """
  @spec kill_grace_ms() :: non_neg_integer()
  def kill_grace_ms do
    case Application.get_env(:evo_git, :process_kill_grace_ms, @kill_grace_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> @kill_grace_ms
    end
  end

  # The ONE kill verdict shared by every escalating backend (POSIX, systemd, …).
  #
  # `alive?` is the post-KILL verification and `hard` / `soft` are the KILL and
  # TERM results (`:ok | {:error, reason}`). A handle that is gone is `:ok` —
  # even when a signal reported a failure for a process that had already exited
  # — otherwise the FIRST real backend failure wins (hard kill, then soft kill).
  # `{:error, :still_alive}` therefore means only "both signals were delivered
  # and the handle is still there"; a real reason always outranks it.
  @doc false
  @spec kill_outcome(boolean(), :ok | {:error, term()}, :ok | {:error, term()}) ::
          :ok | {:error, term()}
  def kill_outcome(alive?, hard, soft) do
    cond do
      not alive? -> :ok
      match?({:error, _}, hard) -> hard
      match?({:error, _}, soft) -> soft
      true -> {:error, :still_alive}
    end
  end

  # Runs one backend call and contains ANY raise/exit/throw, tagging it by the
  # operation that failed (`:stats` → `:probe_failed`, `:kill` → `:kill_failed`,
  # `:signal` → `:signal_failed`).
  #
  # The repository forbids unjustified `try/rescue`; this IS the centralized
  # boundary that keeps the manager and the caller-side sample path alive when a
  # backend misbehaves. Public (`@doc false`) so a suite can pin both the tags
  # and the detail shapes without a fake backend.
  @doc false
  @spec guarded((-> term()), atom()) :: term()
  def guarded(fun, operation) do
    fun.()
  rescue
    e -> {:error, {crash_tag(operation), Exception.message(e)}}
  catch
    kind, reason -> {:error, {crash_tag(operation), {kind, reason}}}
  end

  ## Internal

  # A KILL that raises is a kill failure, a stats probe that raises is a probe
  # failure, a signal that raises is a signal failure — never one generic tag
  # for all three.
  @crash_tags %{stats: :probe_failed, kill: :kill_failed, signal: :signal_failed}

  defp crash_tag(operation), do: Map.get(@crash_tags, operation, :backend_failed)

  defp dispatch(_fun, handle) when not is_struct(handle, Handle), do: {:error, :no_handle}

  defp dispatch(fun, handle) do
    case backend_for(handle) do
      nil -> {:error, :no_handle}
      module -> guarded(fn -> apply(module, fun, [handle]) end, fun)
    end
  end

  defp dispatch_signal(handle, _signal) when not is_struct(handle, Handle),
    do: {:error, :no_handle}

  defp dispatch_signal(handle, signal) do
    with {:ok, name} <- normalize_signal(signal) do
      case backend_for(handle) do
        nil -> {:error, :no_handle}
        module -> guarded(fn -> module.signal(handle, name) end, :signal)
      end
    end
  end
end
