defmodule EvoGit.ProcessManager.Control.Posix do
  @moduledoc """
  `EvoGit.ProcessManager.Control` backend for a raw POSIX process
  (`%Handle{kind: :posix}`).

  ## Stats

    * **Linux** — read `/proc/<pid>/stat` (utime/stime → CPU ms, pgrp) and
      `/proc/<pid>/status` (`VmRSS`). The aggregate covers the process
      **subtree**: the handle pid plus its descendants, discovered by walking
      `/proc/<pid>/task/*/children` breadth-first. That walk is BOUNDED
      (`@max_tree_nodes` nodes, `@max_depth` levels) so a runaway fork tree
      cannot make one probe pathological, and it costs only file reads — no
      fork. This is the chosen aggregation strategy for Linux; process-GROUP
      scanning of all of `/proc` is deliberately NOT done (it would attribute
      this BEAM's own siblings to the execution).
    * **macOS / BSD (and any non-Linux POSIX host)** — ONE
      `ps -eo pid,ppid,pgid,pcpu,rss,time,stat` invocation, parsed ONCE by
      `EvoGit.ProcessManager.Stats.parse_ps_output/1`, then aggregated over the
      same `ppid` subtree. `cpu_percent` is the group sum of `%CPU`, `rss_bytes`
      the group sum of `RSS`, `cpu_time_ms` the group sum of `TIME`.

  `memory_bytes` mirrors `rss_bytes`: for a process tree, resident set IS the
  memory figure a human wants, and both keys are filled so a consumer may read
  either. A figure the backend cannot observe stays `nil` — never a fake 0.

  ## Signals

  `kill -<SIG> -- -<pgid>` (the whole group) is used ONLY when the handle
  carries a `pgid` that is KNOWN and is not this BEAM's own process group; the
  fallback is the bare pid. That guard is load-bearing: a raw port child
  normally inherits the BEAM's own process group, so an unguarded group signal
  would kill Genesis itself. When the group form fails the bare-pid form is
  retried once.

  `kill/1` is TERM → grace (`EvoGit.ProcessManager.Control.kill_grace_ms/0`) →
  KILL, then a final `alive?/1` verification: `:ok` only when the process is
  really gone.
  """

  alias EvoGit.ProcessManager.{Control, Handle, Stats}

  @behaviour EvoGit.ProcessManager.Control

  @proc "proc"
  @max_tree_nodes 256
  @max_depth 16

  ## Stats

  @impl true
  def stats(%Handle{} = handle) do
    cond do
      EvoGit.Platform.linux?() -> linux_stats(handle)
      true -> ps_stats(handle)
    end
  end

  def stats(_handle), do: {:error, :no_handle}

  ## Kill / signal / liveness

  @impl true
  def alive?(%Handle{} = handle) do
    case Handle.target_pid(handle) do
      nil -> false
      pid -> process_alive?(pid)
    end
  end

  def alive?(_handle), do: false

  @impl true
  def signal(%Handle{} = handle, signal) do
    with {:ok, name} <- control_signal(signal),
         {:ok, targets} <- signal_targets(handle) do
      send_signal(name, targets)
    end
  end

  def signal(_handle, _signal), do: {:error, :no_handle}

  @impl true
  def kill(%Handle{} = handle) do
    case signal_targets(handle) do
      {:error, reason} ->
        {:error, reason}

      {:ok, targets} ->
        result = send_signal("TERM", targets)
        # Best-effort escalation: a TERM that already failed (no such process)
        # still gets the KILL attempt, because a dead group leader with live
        # children is exactly the case the escalation exists for.
        _ = result
        Process.sleep(Control.kill_grace_ms())
        _ = send_signal("KILL", targets)

        if alive?(handle), do: {:error, :still_alive}, else: :ok
    end
  end

  def kill(_handle), do: {:error, :no_handle}

  ## Linux: /proc

  defp linux_stats(handle) do
    case Handle.target_pid(handle) do
      nil ->
        {:error, :no_pid}

      pid ->
        case File.read("/#{@proc}/#{pid}/stat") do
          {:ok, stat} ->
            # Reading the root's own stat proves the pid is LIVE (a dead pid has
            # no /proc entry) before the more expensive subtree walk.
            case Stats.parse_proc_stat(stat) do
              {:ok, _root} ->
                members = collect_linux_tree(pid)
                {:ok, Stats.summarize(Enum.map(members, &linux_member/1))}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, _reason} ->
            {:error, :not_running}
        end
    end
  end

  # One subtree member's observable figures. A member that died mid-walk is
  # skipped by the caller (nil entry), never reported as a zero-cost process.
  defp linux_member(pid) do
    %{
      pid: pid,
      cpu_time_ms: linux_cpu_ms(pid),
      rss_bytes: linux_rss(pid)
    }
  end

  defp linux_cpu_ms(pid) do
    with {:ok, stat} <- File.read("/#{@proc}/#{pid}/stat"),
         {:ok, parsed} <- Stats.parse_proc_stat(stat) do
      parsed.cpu_time_ms
    else
      _ -> nil
    end
  end

  defp linux_rss(pid) do
    with {:ok, status} <- File.read("/#{@proc}/#{pid}/status"),
         {:ok, parsed} <- Stats.parse_proc_status(status) do
      parsed.vm_rss_bytes
    else
      _ -> nil
    end
  end

  # The kernel's own parent→children list for a pid, unioned over every task
  # (thread) of that pid.
  defp linux_children(pid) do
    case File.ls("/#{@proc}/#{pid}/task") do
      {:ok, tids} ->
        Enum.flat_map(tids, fn tid ->
          case File.read("/#{@proc}/#{pid}/task/#{tid}/children") do
            {:ok, content} -> content |> String.split(~r/\s+/, trim: true) |> Enum.flat_map(&int/1)
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp collect_linux_tree(root) do
    walk_tree(root, [root], MapSet.new([root]), 0)
  end

  defp walk_tree(_root, acc, _seen, depth) when depth >= @max_depth, do: Enum.reverse(acc)
  defp walk_tree(_root, acc, _seen, _depth) when length(acc) >= @max_tree_nodes, do: Enum.reverse(acc)

  defp walk_tree(root, acc, seen, depth) do
    next =
      acc
      |> Enum.flat_map(&linux_children/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.take(@max_tree_nodes - length(acc))

    case next do
      [] -> Enum.reverse(acc)
      next -> walk_tree(root, acc ++ next, Enum.reduce(next, seen, &MapSet.put(&2, &1)), depth + 1)
    end
  end

  ## macOS / BSD: one `ps` table

  defp ps_stats(handle) do
    pid = Handle.target_pid(handle)

    if is_nil(pid) do
      {:error, :no_pid}
    else
      case ps_table() do
        {:ok, table} ->
          members = collect_ps_tree(table, pid)
          {:ok, Stats.summarize(members)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ps_table do
    case System.find_executable("ps") do
      nil ->
        {:error, :ps_unavailable}

      _ps ->
        case System.cmd("ps", ["-eo", "pid,ppid,pgid,pcpu,rss,time,stat"], stderr_to_stdout: true) do
          {output, 0} -> {:ok, Stats.parse_ps_output(output)}
          {_output, code} -> {:error, {:ps_failed, code}}
        end
    end
  rescue
    _ -> {:error, :ps_failed}
  catch
    _, _ -> {:error, :ps_failed}
  end

  # The handle pid plus every row whose ppid chain reaches it, bounded the same
  # way as the Linux walk.
  defp collect_ps_tree(table, root) do
    index = Enum.group_by(table, & &1.ppid)

    walk_ps(index, [root], MapSet.new([root]), 0)
    |> Enum.flat_map(fn pid -> Enum.filter(table, &(&1.pid == pid)) end)
    |> Enum.map(fn entry ->
      %{
        pid: entry.pid,
        cpu_time_ms: entry.cpu_time_ms,
        rss_bytes: entry.rss_bytes,
        cpu_percent: entry.cpu_percent
      }
    end)
  end

  defp walk_ps(_index, acc, _seen, depth) when depth >= @max_depth, do: acc

  defp walk_ps(index, acc, seen, depth) do
    next =
      acc
      |> Enum.flat_map(fn pid -> index |> Map.get(pid, []) |> Enum.map(& &1.pid) end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.take(max(@max_tree_nodes - length(acc), 0))

    case next do
      [] -> acc
      next -> walk_ps(index, acc ++ next, Enum.reduce(next, seen, &MapSet.put(&2, &1)), depth + 1)
    end
  end

  ## Signals

  # The targets a signal is delivered to, widest-safe first: the process GROUP
  # when the handle names one that is not this BEAM's own group, else the pid.
  defp signal_targets(%Handle{} = handle) do
    pid = Handle.target_pid(handle)
    group = group_target(handle)

    cond do
      is_binary(group) -> {:ok, {:group, group, pid}}
      is_integer(pid) -> {:ok, {:pid, Integer.to_string(pid)}}
      true -> {:error, :no_pid}
    end
  end

  defp group_target(%Handle{pgid: pgid}) when is_integer(pgid) and pgid > 1 do
    own = own_pgid()

    if is_integer(own) and pgid == own do
      # A raw port child inherits the BEAM's group — signalling the group would
      # take Genesis down with it.
      nil
    else
      "-#{pgid}"
    end
  end

  defp group_target(_handle), do: nil

  defp send_signal(name, {:group, group, pid}) do
    case run_kill(name, group) do
      :ok ->
        :ok

      {:error, _reason} when is_integer(pid) ->
        run_kill(name, Integer.to_string(pid))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_signal(name, {:pid, pid}) do
    run_kill(name, pid)
  end

  defp run_kill(name, target) do
    kill = System.find_executable("kill") || "kill"

    case System.cmd(kill, ["-#{name}", "--", target], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:kill_failed, code, String.trim(output)}}
    end
  rescue
    e -> {:error, {:kill_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:kill_failed, {kind, reason}}}
  end

  defp process_alive?(pid) when is_integer(pid) do
    if EvoGit.Platform.linux?() do
      File.exists?("/#{@proc}/#{pid}")
    else
      case run_kill("0", Integer.to_string(pid)) do
        :ok -> true
        {:error, _reason} -> false
      end
    end
  end

  ## This BEAM's own process group (the safety guard above).

  defp own_pgid do
    if EvoGit.Platform.linux?() do
      with {:ok, stat} <- File.read("/#{@proc}/self/stat"),
           {:ok, parsed} <- Stats.parse_proc_stat(stat) do
        parsed.pgid
      else
        _ -> nil
      end
    else
      case System.cmd("ps", ["-o", "pgid=", "-p", System.pid()], stderr_to_stdout: true) do
        {output, 0} ->
          case Integer.parse(String.trim(output)) do
            {pgid, _} -> pgid
            _ -> nil
          end

        _ ->
          nil
      end
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp control_signal(signal) do
    case Control.normalize_signal(signal) do
      {:ok, name} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp int(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> [int]
      _ -> []
    end
  end
end
