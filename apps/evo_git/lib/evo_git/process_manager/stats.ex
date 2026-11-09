defmodule EvoGit.ProcessManager.Stats do
  @moduledoc """
  Pure parsing and aggregation helpers for live OS-execution stats.

  `EvoGit.ProcessManager` records ONE `stats` map per execution (see
  `EvoGit.ProcessManager.Execution`), and that map is produced by the control
  backends (`control/posix.ex`, `control/systemd.ex`, `control/windows.ex`)
  from real OS output. Every OS source is a distinct, brittle text format —
  `man 5 proc`, `ps -eo pid,ppid,pgid,pcpu,rss,time,stat`, the `systemctl show`
  `key=value` stream and Windows `tasklist` CSV — so ALL parsing lives here, in
  pure functions that take the literal text and return plain data. A suite can
  therefore pin the exact formats with fixture strings and never spawn a
  process, while the backends stay thin (invoke the OS, hand the text over).

  ## The stats map (FROZEN)

      %{
        cpu_time_ms: non_neg_integer() | nil,
        cpu_percent: float() | nil,
        memory_bytes: non_neg_integer() | nil,
        rss_bytes: non_neg_integer() | nil,
        pids: [integer()],
        sampled_at: DateTime.t() | nil
      }

  It is ALWAYS a map with exactly those keys (`empty/0` is the default), never
  `nil`: a consumer — today the registry, phase 2 the dashboard — can render
  unconditionally and treat `nil` as "not observable on this backend".

  ## Parsers (all TOTAL — garbage in, `{:error, :malformed}` / `[]` / nil out)

    * `parse_proc_stat/1` — one `/proc/<pid>/stat` line (fields 1-15: pid, comm,
      state, ppid, pgrp, …, utime (14), stime (15)).
    * `parse_proc_status/1` — one `/proc/<pid>/status` file (`VmRSS`/`VmSize`).
    * `parse_ps_output/1` — `ps -eo pid,ppid,pgid,pcpu,rss,time,stat` output
      (header tolerated, malformed lines skipped).
    * `parse_ps_time/1` — the `ps` `time` field, `[[dd-]hh:]mm:ss[.ss]`.
    * `parse_systemctl_show/1` — `systemctl --user show <unit>` `key=value`
      output (`CPUUsageNSec`, `MemoryCurrent` including `infinity`/`[not set]`,
      `ActiveState`).

  ## Clock ticks

  `/proc/<pid>/stat` reports CPU time in `USER_HZ` clock ticks. Linux's
  `USER_HZ` is 100 on every architecture Elixir ships for, so the conversion is
  the module attribute `@clock_ticks`. It is deliberately NOT resolved with
  `getconf CLK_TCK`: that would fork a process on every single probe.
  """

  @type t :: %{
          cpu_time_ms: non_neg_integer() | nil,
          cpu_percent: float() | nil,
          memory_bytes: non_neg_integer() | nil,
          rss_bytes: non_neg_integer() | nil,
          pids: [integer()],
          sampled_at: DateTime.t() | nil
        }

  # Linux `USER_HZ` — the unit of `utime`/`stime` in `/proc/<pid>/stat`.
  @clock_ticks 100
  # Default per-execution probe budget for `EvoGit.ProcessManager.sample_all/1`.
  @default_probe_timeout_ms 2_000
  # systemd reports "infinity" (and older builds "[not set]") for a value it
  # cannot measure; both mean "unknown", never a number.
  @systemd_unknown_values ["", "infinity", "[not set]", "n/a", "not set"]
  @systemd_active_states ["active", "activating", "reloading"]

  ## The frozen stats map

  @doc """
  The empty stats map — EXACTLY the six frozen keys, every value unknown.
  """
  @spec empty() :: t()
  def empty do
    %{
      cpu_time_ms: nil,
      cpu_percent: nil,
      memory_bytes: nil,
      rss_bytes: nil,
      pids: [],
      sampled_at: nil
    }
  end

  @doc """
  Clock ticks per second assumed for `/proc` CPU time (`USER_HZ`).
  """
  @spec clock_ticks() :: pos_integer()
  def clock_ticks, do: @clock_ticks

  @doc """
  Per-execution probe budget (ms) used as the `Task.async_stream` timeout of
  `EvoGit.ProcessManager.sample_all/1`.
  Read at CALL time from the app env `:process_stats_probe_timeout_ms` (a
  positive integer), falling back to `#{@default_probe_timeout_ms}`.
  """
  @spec sample_timeout_ms() :: pos_integer()
  def sample_timeout_ms do
    case Application.get_env(:evo_git, :process_stats_probe_timeout_ms, @default_probe_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _other -> @default_probe_timeout_ms
    end
  end

  @doc """
  CPU time (ms) expressed as a percentage of one core over the interval between
  two cumulative samples of the SAME process tree.
  Returns `nil` when either cumulative value or either timestamp is missing, or
  when the timestamps do not advance. A shrinking cumulative value (the tree
  lost a member) is clamped to 0 rather than reported as negative.
  """
  @spec cpu_percent(nil | integer(), nil | DateTime.t(), nil | integer(), nil | DateTime.t()) ::
          float() | nil
  def cpu_percent(prev_ms, prev_at, cur_ms, cur_at) do
    with true <- is_integer(prev_ms) and is_integer(cur_ms),
         true <- prev_ms >= 0 and cur_ms >= 0,
         %DateTime{} <- prev_at,
         %DateTime{} <- cur_at,
         elapsed when elapsed > 0 <- DateTime.diff(cur_at, prev_at, :millisecond) do
      delta = max(cur_ms - prev_ms, 0)
      Float.round(delta / elapsed * 100, 2)
    else
      _ -> nil
    end
  end

  @doc """
  Whether two stats maps differ MEANINGFULLY — the three counters or the pid
  set changed. `cpu_percent` and `sampled_at` move on every tick by
  construction, so they never make a stats map "changed" (otherwise every tick
  would broadcast an update).
  """
  @spec changed?(t(), t()) :: boolean()
  def changed?(%{} = prev, %{} = cur) do
    prev[:cpu_time_ms] != cur[:cpu_time_ms] or
      prev[:memory_bytes] != cur[:memory_bytes] or
      prev[:rss_bytes] != cur[:rss_bytes] or
      List.wrap(prev[:pids]) != List.wrap(cur[:pids])
  end

  def changed?(_prev, _cur), do: true

  @doc """
  Aggregates per-process entries into ONE stats map: sums `cpu_time_ms`,
  `rss_bytes` and `cpu_percent`, fills `pids`, and mirrors the RSS sum into
  `memory_bytes` (RSS IS the memory figure for a process tree).
  Each entry is a map with optional `:pid`, `:cpu_time_ms`, `:rss_bytes` and
  `:cpu_percent` keys. A field stays `nil` when NO entry reports it — an
  unobservable value is never reported as a fake zero.
  """
  @spec summarize([map()]) :: t()
  def summarize(entries) when is_list(entries) do
    pids =
      entries
      |> Enum.map(&Map.get(&1, :pid))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()
      |> Enum.sort()

    rss = sum_field(entries, :rss_bytes)

    %{
      empty()
      | cpu_time_ms: sum_field(entries, :cpu_time_ms),
        cpu_percent: sum_float(entries, :cpu_percent),
        rss_bytes: rss,
        memory_bytes: rss,
        pids: pids,
        sampled_at: DateTime.utc_now()
    }
  end

  def summarize(_entries), do: empty()

  @doc """
  Builds the stats map for a `:systemd_unit` from `parse_systemctl_show/1`
  output. systemd reports the unit's cgroup totals, so `memory_bytes` is the
  memory figure and `rss_bytes` mirrors it; pids are not queried.
  """
  @spec from_systemd(map()) :: t() | nil
  def from_systemd(%{} = parsed) do
    %{
      empty()
      | cpu_time_ms: parsed[:cpu_time_ms],
        memory_bytes: parsed[:memory_bytes],
        rss_bytes: parsed[:memory_bytes],
        sampled_at: DateTime.utc_now()
    }
  end

  def from_systemd(_parsed), do: nil

  ## /proc/<pid>/stat

  @doc """
  Parses one `/proc/<pid>/stat` line.

  The `comm` field (2) may contain spaces AND parentheses, so the record is
  split at the LAST `)` — everything before it is `pid (comm` and the fields
  after it start at `state` (3). Returns
  `%{pid, comm, state, ppid, pgid, utime_ticks, stime_ticks, cpu_time_ms}`
  or `{:error, :malformed}` when the line cannot be a proc stat record (fewer
  than 15 fields, a non-numeric pid, …).
  """
  @spec parse_proc_stat(term()) :: {:ok, map()} | {:error, :malformed}
  def parse_proc_stat(stat) when is_binary(stat) do
    with {close_index, _len} <- last_paren(stat),
         head = binary_part(stat, 0, close_index),
         rest = binary_part(stat, close_index + 1, byte_size(stat) - close_index - 1),
         {pid, comm} when is_integer(pid) <- split_proc_head(head),
         [state, ppid, pgrp | tail] when length(tail) >= 10 <- String.split(rest) do
      utime = to_int(Enum.at(tail, 8))
      stime = to_int(Enum.at(tail, 9))

      {:ok,
       %{
         pid: pid,
         comm: comm,
         state: state,
         ppid: to_int(ppid),
         pgid: to_int(pgrp),
         utime_ticks: utime,
         stime_ticks: stime,
         cpu_time_ms: cpu_ms(utime, stime)
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  def parse_proc_stat(_stat), do: {:error, :malformed}

  ## /proc/<pid>/status

  @doc """
  Parses a `/proc/<pid>/status` file: `%{name, state, vm_rss_bytes, vm_size_bytes}`.
  The `VmRSS`/`VmSize` figures are converted from kB to bytes; a missing line
  yields `nil` (an unreadable figure is never reported as 0).
  """
  @spec parse_proc_status(term()) ::
          {:ok, %{name: String.t() | nil, state: String.t() | nil, vm_rss_bytes: integer() | nil, vm_size_bytes: integer() | nil}}
          | {:error, :malformed}
  def parse_proc_status(status) when is_binary(status) do
    fields =
      status
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
          _ -> acc
        end
      end)

    if map_size(fields) == 0 do
      {:error, :malformed}
    else
      {:ok,
       %{
         name: fields["Name"],
         state: fields["State"],
         vm_rss_bytes: kb_field(fields["VmRSS"]),
         vm_size_bytes: kb_field(fields["VmSize"])
       }}
    end
  end

  def parse_proc_status(_status), do: {:error, :malformed}

  ## `ps -eo pid,ppid,pgid,pcpu,rss,time,stat`

  @doc """
  Parses `ps -eo pid,ppid,pgid,pcpu,rss,time,stat` output into a list of
  `%{pid, ppid, pgid, cpu_percent, rss_bytes, cpu_time_ms, state}` maps.

  Header lines and malformed rows are skipped (never raised), so a truncated or
  localized `ps` table degrades to fewer entries. This ONE invocation is the
  non-Linux (`macOS`/BSD) stats source: the whole table is parsed in one pass and
  the caller aggregates the process tree out of the `ppid` relations.
  """
  @spec parse_ps_output(term()) :: [map()]
  def parse_ps_output(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_ps_line/1)
  end

  def parse_ps_output(_output), do: []

  defp parse_ps_line(line) do
    case String.split(String.trim(line)) do
      [pid, ppid, pgid, cpu, rss, time, state] ->
        with {:ok, pid} <- int(pid),
             {:ok, ppid} <- int(ppid),
             {:ok, pgid} <- int(pgid),
             {:ok, rss} <- int(rss) do
          [
            %{
              pid: pid,
              ppid: ppid,
              pgid: pgid,
              cpu_percent: to_float(cpu),
              rss_bytes: kb_to_bytes(rss),
              cpu_time_ms: parse_ps_time(time),
              state: state
            }
          ]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc """
  Parses the `ps` `time` field (`[[dd-]hh:]mm:ss`, with optional fractional
  seconds as printed by BSD/macOS `ps`) into milliseconds. Returns `nil` for an
  unparseable value.
  """
  @spec parse_ps_time(term()) :: non_neg_integer() | nil
  def parse_ps_time(value) when is_binary(value) do
    {days, clock} =
      case String.split(value, "-", parts: 2) do
        [day_part, clock] -> {to_int(day_part) || 0, clock}
        [clock] -> {0, clock}
      end

    parts = String.split(String.trim(clock), ":")

    seconds =
      case parts do
        [minutes, secs] -> {0, to_int(minutes), to_float(secs)}
        [hours, minutes, secs] -> {to_int(hours), to_int(minutes), to_float(secs)}
        _ -> nil
      end

    case seconds do
      {hours, minutes, secs} when is_integer(hours) and is_integer(minutes) and is_float(secs) ->
        days * 86_400_000 + hours * 3_600_000 + minutes * 60_000 + round(secs * 1000)

      _ ->
        nil
    end
  end

  def parse_ps_time(value) when is_integer(value) and value >= 0, do: value
  def parse_ps_time(_value), do: nil

  ## `systemctl --user show <unit> -p ...`

  @doc """
  Parses `systemctl show` `key=value` output into
  `%{cpu_time_ms, memory_bytes, active_state, alive}`.

  `CPUUsageNSec` is nanoseconds → ms, `MemoryCurrent` is bytes (both `nil` for
  `infinity`/`[not set]`), and `alive` is true only for a unit that is
  `active`, `activating` or `reloading`.
  """
  @spec parse_systemctl_show(term()) ::
          {:ok, %{cpu_time_ms: integer() | nil, memory_bytes: integer() | nil, active_state: String.t() | nil, alive: boolean()}}
          | {:error, :malformed}
  def parse_systemctl_show(output) when is_binary(output) do
    fields =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
          _ -> acc
        end
      end)

    if map_size(fields) == 0 do
      {:error, :malformed}
    else
      active_state = fields["ActiveState"]

      {:ok,
       %{
         cpu_time_ms: ns_to_ms(maybe_int(fields["CPUUsageNSec"])),
         memory_bytes: maybe_int(fields["MemoryCurrent"]),
         active_state: active_state,
         alive: active_state in @systemd_active_states
       }}
    end
  end

  def parse_systemctl_show(_output), do: {:error, :malformed}

  ## Internal helpers

  defp last_paren(binary) do
    case :binary.matches(binary, ")") do
      [] -> :error
      matches -> List.last(matches)
    end
  end

  defp split_proc_head(head) do
    case :binary.split(head, "(") do
      [pid_part, comm] -> {to_int(pid_part), comm}
      _ -> :error
    end
  end

  defp cpu_ms(utime, stime) when is_integer(utime) and is_integer(stime) do
    div((utime + stime) * 1000, @clock_ticks)
  end

  defp cpu_ms(_utime, _stime), do: nil

  defp sum_field(entries, key) do
    values = entries |> Enum.map(&Map.get(&1, key)) |> Enum.filter(&is_number/1)

    case values do
      [] -> nil
      values -> Enum.reduce(values, 0, &(&1 + &2))
    end
  end

  defp sum_float(entries, key) do
    case sum_field(entries, key) do
      nil -> nil
      value -> Float.round(value * 1.0, 2)
    end
  end

  defp kb_field(nil), do: nil

  defp kb_field(value) do
    value
    |> String.split()
    |> List.first()
    |> to_int()
    |> kb_to_bytes()
  end

  defp kb_to_bytes(nil), do: nil
  defp kb_to_bytes(kb) when is_integer(kb), do: kb * 1024

  defp int(value) do
    case to_int(value) do
      nil -> :error
      int -> {:ok, int}
    end
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_int(_value), do: nil

  defp to_float(value) when is_number(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      _ -> nil
    end
  end

  defp to_float(_value), do: nil

  defp maybe_int(nil), do: nil

  defp maybe_int(value) do
    if String.downcase(String.trim(value)) in @systemd_unknown_values do
      nil
    else
      to_int(value)
    end
  end

  defp ns_to_ms(nil), do: nil
  defp ns_to_ms(ns) when is_integer(ns) and ns >= 0, do: div(ns, 1_000_000)
  defp ns_to_ms(_ns), do: nil
end
