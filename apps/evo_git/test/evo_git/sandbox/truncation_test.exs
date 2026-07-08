defmodule EvoGit.Sandbox.TruncationTest do
  use ExUnit.Case, async: true

  alias EvoGit.Sandbox.None

  @truncate_size 8192

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evo_git_truncation_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  describe "run_with_partial/6 — small file within max_bytes" do
    test "returns entire content with no truncation for a file well within max_bytes", %{tmp_dir: tmp_dir} do
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
      assert output =~ "[WARNING: Output exceeded #{max_bytes} bytes and was truncated to #{@truncate_size} bytes]"

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

      # Count files before
      before_count =
        case File.ls(partial_dir) do
          {:ok, files} -> length(files)
          {:error, :enoent} -> 0
        end

      file = Path.join(tmp_dir, "cleanup_test.txt")
      File.write!(file, "some content\n")

      {:ok, _output, 0} = None.run_with_partial(tmp_dir, "cat", [file], nil, 5000, 1000)

      # Count files after — should be the same (no leftovers)
      after_count =
        case File.ls(partial_dir) do
          {:ok, files} -> length(files)
          {:error, :enoent} -> 0
        end

      assert after_count == before_count,
             "Expected temp file count to remain #{before_count}, got #{after_count}"
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
    test "reads the entire file without crashing when file is under truncate_size", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "edge.txt")
      content = String.duplicate("E", 200)
      File.write!(file, content)

      # max_bytes=100, file=200 bytes — file exceeds max_bytes but is well
      # under truncate_size (8192), so it should be read entirely without crash
      {:ok, output, 0} = None.run_with_partial(tmp_dir, "cat", [file], nil, 5000, 100)

      assert output == content
    end
  end
end
