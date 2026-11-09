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
  instead of a crash.

  `alive?/1` answers a boolean (false for an unknown handle), because it is a
  predicate a caller branches on rather than an error it must format.

  ## Signals

  `normalize_signal/1` maps the small atom vocabulary the public API exposes
  (`:term | :kill | :int | :hup | :stop | :cont | :usr1 | :usr2`) onto the
  POSIX signal NAME, and passes a binary through (upcased), so a caller may send
  `:term`, `"TERM"` or `"SIGKILL"`. `status_after_signal/1` says which status a
  successful signal implies (`SIGSTOP` → `:paused`, `SIGCONT` → `:running`,
  anything else → no status change), so pause/resume and the registry agree on
  ONE rule.

  ## Kill escalation

  Killing is TERM → short grace → KILL (the grace window is read at CALL time
  from the app env `:process_kill_grace_ms`, default
  `#{1500}`), then a final `alive?/1` verification:
  a well-behaved process gets the chance to flush and exit, and the caller
  learns whether the handle is really gone.
  """

  alias EvoGit.ProcessManager.{Handle, Stats}

  @type signal :: :term | :kill | :int | :hup | :stop | :cont | :usr1 | :usr2 | String.t()

  # Grace between SIGTERM and SIGKILL — time for a well-behaved process to
  # flush and exit before the hard kill. Read at CALL time (app env
  # `:process_kill_grace_ms`), so a suite can shrink it.
  @kill_grace_ms 1_500

  @doc """
  Probes the handle's live resource usage.
  Returns `{:ok, stats}` with the frozen stats map (see
  `EvoGit.ProcessManager.Stats`), or `{:error, reason}` when the backend cannot
  answer at all (no executable, no pid, process already gone).
  """
  @callback stats(Handle.t()) :: {:ok, Stats.t()} | {:error, term()}

  @doc "Delivers one signal to the handle (the whole tree/unit, not just the leader)."
  @callback signal(Handle.t(), signal()) :: :ok | {:error, term()}

  @doc "Terminates the handle: TERM, a short grace, then KILL; then verifies."
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
  def stats(handle), do: dispatch(:stats, handle, {:error, :no_handle})

  @doc "See `c:signal/2`. Total: a missing backend answers `{:error, :no_handle}`."
  @spec signal(Handle.t() | nil, signal()) :: :ok | {:error, term()}
  def signal(handle, signal), do: dispatch_signal(handle, signal)

  @doc "See `c:kill/1`. Total: a missing backend answers `{:error, :no_handle}`."
  @spec kill(Handle.t() | nil) :: :ok | {:error, term()}
  def kill(handle), do: dispatch(:kill, handle, {:error, :no_handle})

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

  ## Internal

  defp dispatch(_fun, handle, fallback) when not is_struct(handle, Handle), do: fallback

  defp dispatch(fun, handle, fallback) do
    case backend_for(handle) do
      nil -> fallback
      module -> guarded(fn -> apply(module, fun, [handle]) end, fallback)
    end
  end

  defp dispatch_signal(handle, _signal) when not is_struct(handle, Handle),
    do: {:error, :no_handle}

  defp dispatch_signal(handle, signal) do
    with {:ok, _name} <- normalize_signal(signal) do
      case backend_for(handle) do
        nil -> {:error, :no_handle}
        module -> guarded(fn -> module.signal(handle, signal) end, {:error, :no_handle})
      end
    end
  end

  defp guarded(fun, _fallback) do
    fun.()
  rescue
    e -> {:error, {:probe_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:probe_failed, {kind, reason}}}
  end
end
