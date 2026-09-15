defmodule EvoGit.Sandbox.TruncationTest do
  use ExUnit.Case, async: true

  alias EvoGit.Sandbox.None

  @truncate_size 8192

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "evo_git_truncation_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  describe "run_with_partial/6 — small file within max_bytes" do
    test "returns entire content with no truncation for a file well within max_bytes", %{
      tmp_dir: tmp_dir
    } do
      file = Path.join(tmp_dir, "small.txt")
      content = "Line 1\nLine 2\nLine 3\n"
      File.write!(file, content)

      {:ok, output, 0} = None.run_with_partial(tmp_dir, "cat", [file], nil, 5000, 5000)

      assert output == content
    end
  end

  describe "run_with_partial/6 — large file exceeding max_bytes" do
    test "returns first and last portions with omission marker for a file exceeding max_bytes", %{
      tmp_dir: tmp_dir
    } do
      file = Path.join(tmp_dir, "large.txt")

      # Create a 20000-byte file: distinct first 100 bytes ('X'), distinct
      # last 100 bytes ('Z'), middle filled with 'M'.
      prefix = String.duplicate("X", 100)
      suffix = String.duplicate("Z", 100)
      middle = String.duplicate("M", 20_000 - 200)
      full_content = prefix <> middle <> suffix
      File.write!(file, full_content)

      max_bytes = 5000

      {:ok, output, 0} = None.run_with_partial(tmp_dir, "cat", [file], nil, 5000, max_bytes)

      # Verify the warning header is present
      assert output =~
               "[WARNING: Output exceeded #{max_bytes} bytes and was truncated to #{@truncate_size} bytes]"

      # Verify omission marker with byte count
      omitted = 20_000 - @truncate_size
      assert output =~ "... [#{omitted} bytes omitted] ..."

      # Verify first portion: should contain the 'X' prefix from the start of the file
      assert output =~ String.duplicate("X", 100)

      # Verify last portion: should contain the 'Z' suffix from the end of the file
      assert output =~ String.duplicate("Z", 100)
    end

    test "truncation warning follows the expected message format", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "format_test.txt")

      # Create a file large enough to trigger truncation (> 8192 bytes)
      content = String.duplicate("D", 10_000)
      File.write!(file, content)

      max_bytes = 5000

      {:ok, output, 0} = None.run_with_partial(tmp_dir, "cat", [file], nil, 5000, max_bytes)

      # Verify the exact format: [WARNING: Output exceeded N bytes and was truncated to 8192 bytes]
      assert output =~ ~r/\[WARNING: Output exceeded \d+ bytes and was truncated to \d+ bytes\]/
      assert output =~ "was truncated to #{@truncate_size} bytes"
    end
  end

  describe "run_with_partial/6 — temp file cleanup" do
    test "does not leave temp files behind after completion", %{tmp_dir: tmp_dir} do
      partial_dir = Path.join(EvoGit.Sandbox.resolve_tmpdir(), "genesis_partial_outputs")

      # Snapshot the CURRENT file SET rather than its size. This directory is
      # SHARED with the concurrently-running `async: true` module none_test.exs
      # (and any other backend test that calls run_with_partial/6), which
      # creates and deletes its own temp file here at arbitrary instants — a
      # single before/after count comparison races with that interleaving.
      # Comparing the SET DIFFERENCE against the pre-run baseline, with a
      # bounded wait for our own temp file to disappear, is immune to the
      # interleaving while still failing on a genuine leftover.
      before = current_files(partial_dir)

      # 20_000 bytes with max_bytes=5000 genuinely exceeds the bound, so the
      # command's output is redirected to the shared temp file and read back
      # truncated — the partial-output/temp-file path is really exercised.
      file = Path.join(tmp_dir, "cleanup_test.txt")
      File.write!(file, String.duplicate("C", 20_000))
      max_bytes = 5000

      {:ok, output, 0} = None.run_with_partial(tmp_dir, "cat", [file], nil, 5000, max_bytes)

      # Proves the temp-file path actually ran before we assert cleanup.
      assert output =~
               "[WARNING: Output exceeded #{max_bytes} bytes and was truncated to #{@truncate_size} bytes]"

      leftover = wait_for_no_leftover(partial_dir, before)

      assert leftover == MapSet.new(),
             "Expected no new temp files beyond the baseline in #{partial_dir}, " <>
               "but found leftovers: #{inspect(MapSet.to_list(leftover))}"
    end
  end

  describe "run_with_partial/6 — max_bytes is nil (backward compatibility)" do
    test "reads the entire file when max_bytes is nil", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "nil_max.txt")
      content = String.duplicate("N", 10_000)
      File.write!(file, content)

      {:ok, output, 0} = None.run_with_partial(tmp_dir, "cat", [file], nil, 5000, nil)

      # Should return full content without truncation
      assert output == content
    end
  end

  describe "run_with_partial/6 — small max_bytes, file just over max_bytes but under truncate_size" do
    test "reads the entire file without crashing when file is under truncate_size", %{
      tmp_dir: tmp_dir
    } do
      file = Path.join(tmp_dir, "edge.txt")
      content = String.duplicate("E", 200)
      File.write!(file, content)

      # max_bytes=100, file=200 bytes — file exceeds max_bytes but is well
      # under truncate_size (8192), so it should be read entirely without crash
      {:ok, output, 0} = None.run_with_partial(tmp_dir, "cat", [file], nil, 5000, 100)

      assert output == content
    end
  end

  # The current file set of `dir` (empty when the dir does not exist yet).
  defp current_files(dir) do
    case File.ls(dir) do
      {:ok, files} -> MapSet.new(files)
      {:error, :enoent} -> MapSet.new()
    end
  end

  # Polls the shared partial-output dir until no entry beyond `baseline`
  # remains (the real "no leftover" condition), ~5 ms steps up to ~1 s total.
  # The bounded wait exists because the directory is shared with the
  # concurrently-running `async: true` module none_test.exs, whose transient
  # temp file can briefly appear here. Returns the leftover set — empty on
  # success, still non-empty if a genuine leftover never disappears.
  defp wait_for_no_leftover(dir, baseline, attempts \\ 200) do
    leftover = MapSet.difference(current_files(dir), baseline)

    if MapSet.size(leftover) == 0 or attempts == 0 do
      leftover
    else
      Process.sleep(5)
      wait_for_no_leftover(dir, baseline, attempts - 1)
    end
  end
end
