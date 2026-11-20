defmodule EvoGit.ProcessManager.Control.Systemd do
  @moduledoc """
  `EvoGit.ProcessManager.Control` backend for a transient systemd USER unit
  (`%Handle{kind: :systemd_unit}`).

  A `systemd-run` job (see `EvoGit.Sandbox.Linux` / `EvoGit.Sandbox.Background`)
  is NOT a child of this BEAM, so it is observed and controlled through
  `systemctl --user`:

    * **stats** — ONE `systemctl --user show <unit> -p CPUUsageNSec,MemoryCurrent,ActiveState`
      call, parsed by `EvoGit.ProcessManager.Stats.parse_systemctl_show/1`.
      `CPUUsageNSec` (nanoseconds) becomes `cpu_time_ms`, `MemoryCurrent`
      (bytes, `infinity` for a value systemd cannot measure) becomes
      `memory_bytes`/`rss_bytes`. Pids are NOT queried: the unit's cgroup
      content is not part of this probe.
    * **signal** — `systemctl --user kill --signal=<SIG> <unit>`, where `<SIG>`
      is the NAME `EvoGit.ProcessManager.Control.signal/2` already normalized
      (the backend never re-normalizes it).
    * **kill** — SIGTERM, a short grace
      (`EvoGit.ProcessManager.Control.kill_grace_ms/0`), then SIGKILL, then a
      final `alive?/1` verification decided by
      `EvoGit.ProcessManager.Control.kill_outcome/3`, so `:ok` means the unit
      really is gone; a real `systemctl` failure is reported as its OWN reason
      and `{:error, :still_alive}` only means both signals were delivered and
      the unit is still there.
    * **alive?** — `ActiveState` in `active`/`activating`/`reloading`.

  A transient unit that exited successfully is unloaded by systemd immediately
  (`CollectMode=inactive`), so "unit not found" is a NORMAL, non-error answer:
  `alive?/1` is false and no probe raises. Every call is TOTAL — a missing
  `systemctl`, a failed call or unparseable output degrades to `{:error, …}` /
  `nil` fields, never an exception (the registry must never die of a probe).
  """

  alias EvoGit.ProcessManager.{Control, Handle, Stats}

  @behaviour EvoGit.ProcessManager.Control
  # `systemctl --user show` is one fork; keep it comfortably under a sample tick.
  @cmd_timeout_ms 2_000

  @properties "CPUUsageNSec,MemoryCurrent,ActiveState"

  @impl true
  def stats(%Handle{unit: unit}) when is_binary(unit) and unit != "" do
    with {:ok, output} <- systemctl(["show", unit, "-p", @properties]),
         {:ok, parsed} <- Stats.parse_systemctl_show(output) do
      Stats.from_systemd(parsed)
    end
  end

  def stats(_handle), do: {:error, :no_unit}

  @impl true
  def alive?(%Handle{unit: unit}) when is_binary(unit) and unit != "" do
    case systemctl(["show", unit, "-p", "ActiveState"]) do
      {:ok, output} ->
        case Stats.parse_systemctl_show(output) do
          {:ok, parsed} -> parsed.alive == true
          {:error, _reason} -> false
        end

      {:error, _reason} ->
        false
    end
  end

  def alive?(_handle), do: false

  @impl true
  def signal(%Handle{unit: unit}, name)
      when is_binary(unit) and unit != "" and is_binary(name) do
    case systemctl(["kill", "--signal=#{name}", unit]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def signal(%Handle{unit: unit}, _name) when is_binary(unit) and unit != "",
    do: {:error, :invalid_signal}

  def signal(_handle, _signal), do: {:error, :no_unit}

  @impl true
  def kill(%Handle{unit: unit} = handle) when is_binary(unit) and unit != "" do
    soft = signal(handle, "TERM")
    # Best-effort escalation: a TERM that already failed still gets the KILL
    # attempt, because a leader that is already gone with live children is
    # exactly the case the escalation exists for.
    Process.sleep(Control.kill_grace_ms())
    hard = signal(handle, "KILL")

    # A gone unit is :ok; otherwise the REAL backend failure wins over the
    # generic `:still_alive`.
    Control.kill_outcome(alive?(handle), hard, soft)
  end

  def kill(_handle), do: {:error, :no_unit}

  ## Internal

  defp systemctl(args) do
    case System.find_executable("systemctl") do
      nil ->
        {:error, :systemctl_unavailable}

      systemctl ->
        case System.cmd(systemctl, ["--user" | args],
               stderr_to_stdout: true,
               timeout: @cmd_timeout_ms
             ) do
          {output, 0} -> {:ok, output}
          {output, code} -> {:error, {:systemctl_failed, code, String.trim(output)}}
        end
    end
  rescue
    e -> {:error, {:systemctl_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:systemctl_failed, {kind, reason}}}
  end
end
