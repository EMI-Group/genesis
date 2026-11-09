defmodule EvoGit.ProcessManager.Control.Windows do
  @moduledoc """
  `EvoGit.ProcessManager.Control` backend for a raw Windows process
  (`%Handle{kind: :windows}`).

  ## What Windows supports

  | operation | mechanism | notes |
  |-----------|-----------|-------|
  | `stats/1` | `tasklist /FI "PID eq <pid>" /FO CSV /NH` for memory, `powershell -NoProfile -Command "(Get-Process -Id <pid>).CPU"` for CPU | memory is REQUIRED, CPU is BEST-EFFORT |
  | `alive?/1` | the same `tasklist` filter | a present row means the pid exists |
  | `kill/1` | `taskkill /PID <pid> /T /F` (whole tree, forced) | verified with `alive?/1` |
  | `signal/2` | `{:error, :unsupported}` | Windows has no POSIX signals |

  ## Documented limitation: no POSIX signals

  Windows has no `SIGSTOP`/`SIGCONT`/`SIGTERM`. `signal/2` — and therefore
  `EvoGit.ProcessManager.pause/2`, `resume/2` and a plain
  `signal(id, :term | :hup | …)` — answers `{:error, :unsupported}` on this
  backend. The supported lifecycle on Windows is: `attach/3`, stats sampling,
  `finish/3` and `kill/2`. A suspended process would require
  `NtSuspendProcess`/`DebugActiveProcess` through a native call, which is out of
  scope (no new dependencies, OS probes via `System.cmd` only).

  Every call is TOTAL: `tasklist`/PowerShell output is localized and fragile, so
  an unparseable answer yields `nil` fields or `{:error, reason}`, never a
  raise.
  """

  alias EvoGit.ProcessManager.{Handle, Stats}

  @behaviour EvoGit.ProcessManager.Control
  @cmd_timeout_ms 5_000

  @impl true
  def stats(%Handle{} = handle) do
    case Handle.target_pid(handle) do
      nil -> {:error, :no_pid}
      pid -> {:ok, collect(pid)}
    end
  end

  def stats(_handle), do: {:error, :no_pid}

  @impl true
  def alive?(%Handle{} = handle) do
    case Handle.target_pid(handle) do
      nil -> false
      pid -> tasklist_memory_bytes(pid) != :not_found
    end
  end

  def alive?(_handle), do: false

  @impl true
  def signal(_handle, _signal), do: {:error, :unsupported}

  @impl true
  def kill(%Handle{} = handle) do
    case Handle.target_pid(handle) do
      nil ->
        {:error, :no_pid}

      pid ->
        args = ["/PID", Integer.to_string(pid), "/T", "/F"]

        case run("taskkill", args) do
          {:ok, _output} -> if alive?(handle), do: {:error, :still_alive}, else: :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def kill(_handle), do: {:error, :no_pid}

  ## Internal

  defp collect(pid) do
    memory =
      case tasklist_memory_bytes(pid) do
        :not_found -> nil
        bytes -> bytes
      end

    %{
      Stats.empty()
      | cpu_time_ms: powershell_cpu_ms(pid),
        memory_bytes: memory,
        rss_bytes: memory,
        pids: if(is_integer(memory), do: [pid], else: []),
        sampled_at: DateTime.utc_now()
    }
  end

  # `tasklist /FO CSV /NH` prints one row per match:
  #   "notepad.exe","1234","Console","1","12,345 K"
  # The 5th CSV field is the working set in KB with thousand separators (and,
  # on some locales, a non-breaking space), so only digits are kept.
  defp tasklist_memory_bytes(pid) do
    filter = "PID eq #{pid}"

    case run("tasklist", ["/FI", filter, "/FO", "CSV", "/NH"]) do
      {:ok, output} -> parse_tasklist(output, pid)
      {:error, _reason} -> :not_found
    end
  end

  defp parse_tasklist(output, pid) do
    pid_text = Integer.to_string(pid)

    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(:not_found, fn line ->
      fields = parse_csv(line)

      if Enum.at(fields, 1) == pid_text do
        case Enum.at(fields, 4) do
          nil ->
            :not_found

          mem ->
            case Regex.replace(~r/\D/, mem, "") do
              "" -> :not_found
              digits -> to_int(digits)
            end
        end
      end
    end)
    |> case do
      :not_found -> :not_found
      nil -> :not_found
      kb -> kb * 1024
    end
  end

  # Minimal CSV splitter: `tasklist` quotes every field and never embeds a
  # quote, so a plain split on `","` after trimming the outer quotes is exact.
  defp parse_csv(line) do
    line
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.split("\",\"")
  end

  # Best-effort CPU time in ms: `(Get-Process -Id <pid>).CPU` is total
  # processor seconds as a decimal. Any failure (PowerShell absent, process
  # gone, unparseable output) yields nil.
  defp powershell_cpu_ms(pid) do
    script = "(Get-Process -Id #{pid}).CPU"

    with {:ok, output} <-
           run("powershell", ["-NoProfile", "-NonInteractive", "-Command", script]),
         {seconds, _} <- Float.parse(String.trim(output)) do
      round(seconds * 1000)
    else
      _ -> nil
    end
  end

  defp run(executable, args) do
    case System.find_executable(executable) do
      nil ->
        {:error, :not_available}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true, timeout: @cmd_timeout_ms) do
          {output, 0} -> {:ok, output}
          {output, code} -> {:error, {:command_failed, code, String.trim(output)}}
        end
    end
  rescue
    e -> {:error, {:command_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:command_failed, {kind, reason}}}
  end

  defp to_int(value) do
    case Integer.parse(value) do
      {int, _} -> int
      _ -> nil
    end
  end
end
