defmodule EvoGit.ProcessManager.StatsTest do
  # Pure parsers: no OS call, no shared state — safe alongside every module.
  use ExUnit.Case, async: true

  alias EvoGit.ProcessManager.Stats

  @proc_stat "1234 (my proc) S 1 1234 1234 0 -1 4194560 100 0 0 0 50 25 0 0 20 0 1 0 999 12345 678 18446744073709551615\n"

  @proc_status """
  Name:\tsleep
  State:\tS (sleeping)
  Tgid:\t1234
  Pid:\t1234
  VmSize:\t    9124 kB
  VmRSS:\t    1712 kB
  """

  @ps_output """
    PID  PPID  PGID  %CPU    RSS     TIME STAT
   1234     1  1234   1.5   1712 00:00:05 S
   1235  1234  1234   0.0    512 00:00:00 S
   1236  1235  1234  12.5   2048 01:02:03 R
  """

  @systemctl_show """
  ActiveState=active
  CPUUsageNSec=2500000000
  MemoryCurrent=104857600
  """

  describe "empty/0" do
    test "is a stats map with exactly the frozen keys" do
      assert Stats.empty() == %{
               cpu_time_ms: nil,
               cpu_percent: nil,
               memory_bytes: nil,
               rss_bytes: nil,
               pids: [],
               sampled_at: nil
             }
    end
  end

  describe "parse_proc_stat/1" do
    test "reads pid/comm/state/ppid/pgid and converts ticks to ms" do
      assert {:ok, parsed} = Stats.parse_proc_stat(@proc_stat)
      assert parsed.pid == 1234
      assert parsed.comm == "my proc"
      assert parsed.state == "S"
      assert parsed.ppid == 1
      assert parsed.pgid == 1234
      assert parsed.utime_ticks == 50
      assert parsed.stime_ticks == 25
      assert parsed.cpu_time_ms == div(75 * 1000, Stats.clock_ticks())
    end

    test "is total: garbage is :malformed, never a raise" do
      assert {:error, :malformed} = Stats.parse_proc_stat("")
      assert {:error, :malformed} = Stats.parse_proc_stat("not a stat line")
      assert {:error, :malformed} = Stats.parse_proc_stat("1234 (x) S 1")
      assert {:error, :malformed} = Stats.parse_proc_stat(nil)
      assert {:error, :malformed} = Stats.parse_proc_stat(12_345)
    end
  end

  describe "parse_proc_status/1" do
    test "reads name/state and converts VmRSS/VmSize kB to bytes" do
      assert {:ok, parsed} = Stats.parse_proc_status(@proc_status)
      assert parsed.name == "sleep"
      assert parsed.state == "S (sleeping)"
      assert parsed.vm_rss_bytes == 1712 * 1024
      assert parsed.vm_size_bytes == 9124 * 1024
    end

    test "missing figures stay nil (never 0) and garbage is :malformed" do
      assert {:ok, parsed} = Stats.parse_proc_status("Name:\tsleep\n")
      assert parsed.vm_rss_bytes == nil
      assert parsed.vm_size_bytes == nil
      assert {:error, :malformed} = Stats.parse_proc_status("")
      assert {:error, :malformed} = Stats.parse_proc_status(:nope)
    end
  end

  describe "parse_ps_output/1" do
    test "parses every row and skips the header" do
      rows = Stats.parse_ps_output(@ps_output)
      assert length(rows) == 3
      assert Enum.map(rows, & &1.pid) == [1234, 1235, 1236]
      assert Enum.map(rows, & &1.ppid) == [1, 1234, 1235]
      assert Enum.map(rows, & &1.pgid) == [1234, 1234, 1234]

      first = hd(rows)
      assert first.cpu_percent == 1.5
      assert first.rss_bytes == 1712 * 1024
      assert first.cpu_time_ms == 5_000
      assert first.state == "S"

      assert Enum.at(rows, 2).cpu_time_ms == 3_723_000
    end

    test "is total: garbage rows are dropped, non-binary input is []" do
      assert Stats.parse_ps_output("") == []
      assert Stats.parse_ps_output("garbage\nmore garbage\n") == []
      assert Stats.parse_ps_output(nil) == []
      assert Stats.parse_ps_output(1) == []
    end
  end

  describe "parse_ps_time/1" do
    test "handles mm:ss, hh:mm:ss and dd-hh:mm:ss" do
      assert Stats.parse_ps_time("00:05") == 5_000
      assert Stats.parse_ps_time("01:02:03") == 3_723_000
      assert Stats.parse_ps_time("2-01:02:03") == 176_523_000
      assert Stats.parse_ps_time("00:01.50") == 1_500
    end

    test "passes non-negative integers through and nils the rest" do
      assert Stats.parse_ps_time(1_500) == 1_500
      assert Stats.parse_ps_time("nope") == nil
      assert Stats.parse_ps_time(nil) == nil
    end
  end

  describe "parse_systemctl_show/1" do
    test "converts CPUUsageNSec to ms and keeps MemoryCurrent bytes" do
      assert {:ok, parsed} = Stats.parse_systemctl_show(@systemctl_show)
      assert parsed.cpu_time_ms == 2_500
      assert parsed.memory_bytes == 104_857_600
      assert parsed.active_state == "active"
      assert parsed.alive
    end

    test "infinity / [not set] stay nil and an inactive unit is not alive" do
      output = """
      ActiveState=inactive
      CPUUsageNSec=[not set]
      MemoryCurrent=infinity
      """

      assert {:ok, parsed} = Stats.parse_systemctl_show(output)
      assert parsed.cpu_time_ms == nil
      assert parsed.memory_bytes == nil
      refute parsed.alive
      assert {:error, :malformed} = Stats.parse_systemctl_show("")
      assert {:error, :malformed} = Stats.parse_systemctl_show(nil)
    end
  end

  describe "cpu_percent/4 and changed?/2 and summarize/1" do
    test "cpu_percent is nil without two comparable samples" do
      now = DateTime.utc_now()
      assert Stats.cpu_percent(nil, nil, 10, now) == nil
      assert Stats.cpu_percent(10, nil, 10, now) == nil
      assert Stats.cpu_percent(10, now, 10, now) == nil
      assert is_float(Stats.cpu_percent(0, now, 100, DateTime.add(now, 1, :second)))
    end

    test "changed?/2 detects a meaningful movement only" do
      base = Stats.empty()
      refute Stats.changed?(base, base)
      # cpu_percent / sampled_at alone never make a map "changed"…
      refute Stats.changed?(base, %{base | cpu_percent: 3.5, sampled_at: DateTime.utc_now()})
      # …but a counter or the pid set does.
      assert Stats.changed?(base, %{base | rss_bytes: 4096})
      assert Stats.changed?(base, %{base | pids: [1]})
    end

    test "summarize/1 aggregates a process tree" do
      entries = [
        %{pid: 1, rss_bytes: 1024, cpu_time_ms: 10, cpu_percent: 1.0, state: "S"},
        %{pid: 2, rss_bytes: 2048, cpu_time_ms: 5, cpu_percent: 2.5, state: "R"}
      ]

      stats = Stats.summarize(entries)
      assert stats.rss_bytes == 3072
      assert stats.memory_bytes == 3072
      assert stats.cpu_time_ms == 15
      assert stats.cpu_percent == 3.5
      assert Enum.sort(stats.pids) == [1, 2]
      assert is_struct(stats.sampled_at, DateTime)
      # No entries: every figure stays nil and no pid is reported.
      assert %{rss_bytes: nil, memory_bytes: nil, cpu_time_ms: nil, pids: []} =
               Stats.summarize([])

      assert Stats.summarize(nil) == Stats.empty()
    end
  end
end
