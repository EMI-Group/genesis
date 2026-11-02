defmodule EvoGit.Bench.ReportTest do
  @moduledoc """
  Tests for `EvoGit.Bench.Report` — the pure text/JSON presentation of a
  benchmark result.

  Both renderers are driven by a SYNTHETIC result map (no git, no filesystem,
  no timers) built to the `EvoGit.Bench.run/1` contract, so these tests pin the
  rendering contract without paying for a real benchmark. `async: true`: no
  global state and no I/O.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Bench.Report

  # The eight measured phases, in contract/render order.
  @phase_keys [
    :worktree_add,
    :file_read,
    :file_write,
    :git_status,
    :git_add,
    :git_commit,
    :worktree_remove,
    :worktree_prune
  ]

  @top_level_keys [
    "label",
    "dir",
    "kept",
    "settings",
    "system",
    "setup",
    "phases",
    "cycle",
    "overall",
    "throughput"
  ]

  # ── Synthetic result ──────────────────────────────────────────────────────

  defp phase(total_us, samples, share) do
    n = length(samples)

    %{
      n: n,
      total_us: total_us,
      mean_us: Float.round(total_us / n, 1),
      median_us: Enum.at(samples, div(n, 2)),
      p95_us: Enum.max(samples),
      min_us: Enum.min(samples),
      max_us: Enum.max(samples),
      samples_us: samples,
      share: share
    }
  end

  defp result do
    %{
      label: "bench-host",
      dir: "/tmp/genesis-bench-1234-1",
      kept: false,
      settings: %{
        iterations: 2,
        warmup: 0,
        files: 64,
        writes: 4,
        reads: 5,
        file_size: 1024,
        seed: 42,
        fsync: false
      },
      system: %{
        os: "Linux",
        arch: "x86_64-pc-linux-gnu",
        cpus: 8,
        elixir: "1.20.4",
        otp: "29",
        hostname: "bench-host",
        git_version: "git version 2.45.2",
        fs_type: "ext4",
        fs_device: "/dev/sda1",
        mountpoint: "/"
      },
      setup: %{us: 152_000, files: 64, bytes: 65_536},
      phases: %{
        # [10, 11] keeps the mean at exactly 10.5 for the JSON round-trip test.
        worktree_add: phase(21, [10, 11], 0.01),
        file_read: phase(1_000, [400, 600], 0.2),
        file_write: phase(2_000, [900, 1_100], 0.4),
        git_status: phase(600, [250, 350], 0.12),
        git_add: phase(400, [150, 250], 0.08),
        git_commit: phase(500, [200, 300], 0.1),
        worktree_remove: phase(300, [100, 200], 0.06),
        worktree_prune: phase(150, [50, 100], 0.03)
      },
      cycle: %{
        n: 2,
        total_us: 4_971,
        mean_us: 2_485.5,
        median_us: 2_485.5,
        p95_us: 5_000,
        min_us: 4_942,
        max_us: 5_000,
        samples_us: [4_942, 5_000]
      },
      overall: %{cycles: 2, wall_us: 4_971, cycles_per_sec: 402.3},
      throughput: %{
        files_written: 8,
        bytes_written: 8_192,
        write_mib_per_sec: 3.9,
        files_read: 10,
        bytes_read: 10_240,
        read_mib_per_sec: 4.9
      }
    }
  end

  defp with_fs(result, fs_type, mountpoint) do
    %{result | system: %{result.system | fs_type: fs_type, mountpoint: mountpoint}}
  end

  # ── render_text/1 ─────────────────────────────────────────────────────────

  describe "render_text/1" do
    test "renders the header, every phase label, the totals and the note" do
      text = Report.render_text(result())

      assert text =~ "bench-host"
      assert text =~ "/tmp/genesis-bench-1234-1"
      assert text =~ "(ext4)"
      assert text =~ "Linux"
      assert text =~ "git version 2.45.2"

      # All eight human phase labels, in the contract's phrasing.
      assert text =~ "worktree add"
      assert text =~ "file read"
      assert text =~ "file write"
      assert text =~ "git status"
      assert text =~ "git add"
      assert text =~ "git commit"
      assert text =~ "worktree remove"
      assert text =~ "worktree prune"

      assert text =~ "Overall"
      assert text =~ "Write throughput"
      assert text =~ "Read throughput"
    end

    test "renders the settings line" do
      text = Report.render_text(result())

      assert text =~ "Settings"
      assert text =~ "2 cycles (+0 warmup)"
      assert text =~ "64 seed files"
      assert text =~ "5 reads + 4 writes/cycle"
      # KiB drops a trailing `.0` (`trim_zero/1`), so 1024 bytes renders as 1 KiB.
      assert text =~ "1 KiB"
      assert text =~ "fsync off"
      assert text =~ "seed 42"
    end

    test "renders the repo setup line" do
      text = Report.render_text(result())

      assert text =~ "Repo setup: 64 files"
      assert text =~ "152.0 ms"
    end

    test "renders the notes line" do
      assert Report.render_text(result()) =~
               "Note: absolute numbers vary with page cache and machine load"
    end

    test "warns when the bench directory sits on a RAM filesystem" do
      text =
        result()
        |> with_fs("tmpfs", "/tmp")
        |> Report.render_text()

      assert text =~ "Warning"
      assert text =~ "/tmp is on tmpfs"
      assert text =~ "results measure RAM"
    end

    test "does not warn for a real filesystem" do
      text = Report.render_text(with_fs(result(), "ext4", "/"))

      refute text =~ "Warning"
      refute text =~ "results measure RAM"
    end

    test "renders an empty result map without raising" do
      text = Report.render_text(%{})

      assert is_binary(text)
      assert text =~ "unknown"
      assert text =~ "Overall"
      assert text =~ "Phase"
    end

    test "renders a degenerate map (unknown values and an empty phase table)" do
      text =
        Report.render_text(%{
          label: "",
          phases: %{},
          cycle: nil,
          overall: %{cycles: "two"},
          settings: %{iterations: nil},
          system: %{fs_type: :odd}
        })

      assert is_binary(text)
      assert text =~ "Overall"
      assert text =~ "worktree add"
      refute text =~ "Warning"
    end
  end

  # ── render_json/1 ─────────────────────────────────────────────────────────

  describe "render_json/1" do
    test "projects exactly the ten top-level keys" do
      decoded = result() |> Report.render_json() |> Jason.decode!()

      assert decoded |> Map.keys() |> Enum.sort() == Enum.sort(@top_level_keys)
    end

    test "drops keys outside the contract" do
      decoded =
        result()
        |> Map.put(:extra, "ignored")
        |> Report.render_json()
        |> Jason.decode!()

      refute Map.has_key?(decoded, "extra")
      assert Map.has_key?(decoded, "label")
    end

    test "encodes every phase under its string name" do
      decoded = result() |> Report.render_json() |> Jason.decode!()

      assert decoded["phases"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(Enum.map(@phase_keys, &Atom.to_string/1))

      Enum.each(@phase_keys, fn key ->
        stats = Map.fetch!(decoded["phases"], Atom.to_string(key))

        assert is_number(stats["mean_us"])
        assert is_integer(stats["n"])
        assert is_list(stats["samples_us"])
        assert is_number(stats["share"])
      end)
    end

    test "round-trips the numbers unchanged" do
      decoded = result() |> Report.render_json() |> Jason.decode!()

      assert decoded["phases"]["worktree_add"]["mean_us"] == 10.5
      assert decoded["phases"]["worktree_add"]["total_us"] == 21
      assert decoded["phases"]["worktree_add"]["samples_us"] == [10, 11]
      assert decoded["phases"]["file_write"]["share"] == 0.4
      assert decoded["overall"]["cycles"] == 2
      assert decoded["overall"]["wall_us"] == 4_971
      assert decoded["overall"]["cycles_per_sec"] == 402.3
      assert decoded["cycle"]["n"] == 2
      assert decoded["settings"]["iterations"] == 2
      assert decoded["settings"]["fsync"] == false
      assert decoded["kept"] == false
      assert decoded["label"] == "bench-host"
      assert decoded["setup"]["files"] == 64
      assert decoded["throughput"]["bytes_written"] == 8_192
    end

    test "makes non-JSON values safe instead of raising" do
      # `kept` as an atom and a struct in `system` must not break encoding.
      decoded =
        result()
        |> Map.put(:kept, :kept_atom)
        |> Map.put(:system, %{fs_type: :odd, mountpoint: {1, 2}})
        |> Report.render_json()
        |> Jason.decode!()

      assert decoded["kept"] == "kept_atom"
      assert decoded["system"]["fs_type"] == "odd"
      assert decoded["system"]["mountpoint"] == [1, 2]
    end

    test "encodes an empty result map as the ten null keys" do
      decoded = %{} |> Report.render_json() |> Jason.decode!()

      assert decoded == Map.new(@top_level_keys, fn key -> {key, nil} end)
    end
  end
end
