defmodule EvoGit.BenchTest do
  @moduledoc """
  Integration tests for `EvoGit.Bench.run/1` against REAL git.

  Every test builds its own unique scratch directory under `System.tmp_dir!()`
  (no `@moduletag :tmp_dir`, so concurrent modules never share a bench root)
  and removes it in `on_exit`. The settings are deliberately tiny — 8 seed
  files, 2 reads/writes and 2 cycles — so the suite pays for the production
  fork path (worktree add/remove, file I/O, `git status`/`add`/`commit`) and
  nothing else.

  Only STRUCTURAL invariants are asserted: sample counts, echoed settings,
  byte/file totals and the cleanup/keep contracts. Absolute timings are never
  asserted (they vary with page cache and machine load).

  `async: true`: no BEAM-global state. `EvoGit.Bench` seeds the process-local
  `:rand` stream of the calling process, which no other test observes.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.Bench

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

  @iterations 2
  @files 8
  @writes 2
  @reads 2
  @file_size 64

  setup do
    dir = Path.join(System.tmp_dir!(), "bench-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  # Tiny measured settings; `iterations`/`warmup`/`files`/`writes`/`reads`/
  # `file_size` are the option keys `EvoGit.Bench.validate/1` accepts, the rest
  # of the defaults (seed, label, fsync, keep) come from `defaults/0`.
  defp opts(dir, overrides \\ []) do
    Keyword.merge(
      [
        dir: dir,
        iterations: @iterations,
        warmup: 0,
        files: @files,
        writes: @writes,
        reads: @reads,
        file_size: @file_size
      ],
      overrides
    )
  end

  describe "run/1 over a real repository" do
    test "reports every measured phase, the setup and the throughput totals", %{dir: dir} do
      assert {:ok, result} = Bench.run(opts(dir))

      # ── Settings echo ──────────────────────────────────────────────────
      assert is_binary(result.label)
      assert result.label == Bench.defaults()[:label]
      assert String.starts_with?(result.dir, dir)

      assert %{
               iterations: @iterations,
               warmup: 0,
               files: @files,
               writes: @writes,
               reads: @reads,
               file_size: @file_size,
               seed: 42,
               fsync: false
             } = result.settings

      # ── Phases ─────────────────────────────────────────────────────────
      assert result.phases |> Map.keys() |> Enum.sort() == Enum.sort(@phase_keys)

      Enum.each(@phase_keys, fn key ->
        stats = Map.fetch!(result.phases, key)

        assert stats.n == @iterations, "#{key}: unexpected sample count"
        assert length(stats.samples_us) == @iterations
        assert Enum.all?(stats.samples_us, &(is_integer(&1) and &1 >= 0))
        assert is_float(stats.share)
        assert stats.share >= 0.0 and stats.share <= 1.0
      end)

      # ── Per-cycle totals ───────────────────────────────────────────────
      assert result.cycle.n == @iterations
      assert length(result.cycle.samples_us) == @iterations
      assert result.cycle.total_us == Enum.sum(result.cycle.samples_us)

      # ── Setup ──────────────────────────────────────────────────────────
      assert result.setup.files == @files
      assert result.setup.bytes == @files * @file_size
      assert is_integer(result.setup.us) and result.setup.us >= 0

      # ── Throughput ─────────────────────────────────────────────────────
      assert result.throughput.files_written == @iterations * @writes
      assert result.throughput.bytes_written == @iterations * @writes * @file_size
      assert result.throughput.files_read == @iterations * @reads
      assert result.throughput.bytes_read == @iterations * @reads * @file_size

      assert is_float(result.throughput.write_mib_per_sec)
      assert result.throughput.write_mib_per_sec >= 0.0
      assert is_float(result.throughput.read_mib_per_sec)
      assert result.throughput.read_mib_per_sec >= 0.0

      # ── Overall ────────────────────────────────────────────────────────
      assert result.overall.cycles == @iterations
      assert result.overall.wall_us == result.cycle.total_us
      assert result.overall.cycles_per_sec > 0.0

      # ── Cleanup contract ───────────────────────────────────────────────
      assert result.kept == false
      refute File.exists?(result.dir)
    end

    test "keep: true leaves the bench root behind, without bench worktrees or branches", %{
      dir: dir
    } do
      assert {:ok, result} = Bench.run(opts(dir, keep: true))

      assert result.kept == true
      assert File.dir?(result.dir)

      repo = Path.join(result.dir, "repo")
      assert File.dir?(repo)

      # The counted cycles removed their worktrees and pruned the registry.
      assert {:ok, worktrees} = Git.run(["worktree", "list"], repo)
      refute worktrees =~ ".genesis/workers"
      assert length(String.split(worktrees, "\n", trim: true)) == 1

      # And deleted the per-cycle bench branches.
      assert {:ok, ""} = Git.run(["branch", "--list", "evogit-bench-*"], repo)

      for index <- 0..(@iterations - 1) do
        refute File.exists?(Path.join([repo, ".genesis", "workers", "bench-#{index}"]))
      end
    end
  end

  describe "run/1 error handling" do
    test "reports invalid options as a :validation error before any I/O", %{dir: dir} do
      assert {:error, {:validation, message}} = Bench.run(opts(dir, iterations: 0))

      assert is_binary(message)
      assert message =~ "iterations"
      assert File.ls!(dir) == []
    end
  end

  describe "picker/1" do
    test "cycles over the list instead of running out" do
      pick = Bench.picker(["a", "b", "c"])

      assert Enum.map(0..6, pick) == ["a", "b", "c", "a", "b", "c", "a"]
    end

    test "returns the only file for a single-element list" do
      pick = Bench.picker(["only"])

      assert Enum.map(0..3, pick) == ["only", "only", "only", "only"]
    end
  end
end
