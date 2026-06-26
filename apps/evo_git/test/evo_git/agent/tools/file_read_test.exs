defmodule EvoGit.Agent.Tools.FileReadTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.FileRead

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "file_read_test_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  describe "execute/3 - normal reads" do
    test "reads a multi-line file with default offset/limit and includes line numbers", %{
      tmp_dir: tmp_dir
    } do
      file_path = "example.ex"

      File.write!(
        Path.join(tmp_dir, file_path),
        "line one\nline two\nline three\n"
      )

      result = FileRead.execute(%{"file_path" => file_path}, tmp_dir, nil)

      assert is_binary(result)

      # Line numbers should be present (cat -n style)
      assert result =~ "1\tline one"
      assert result =~ "2\tline two"
      assert result =~ "3\tline three"

      # Header should be present
      assert result =~ "File: #{file_path}"
    end
  end

  describe "execute/3 - offset beyond EOF (crash regression)" do
    # The original bug: read_file_fast_path/3 raised a FunctionClauseError when
    # offset exceeded the file's line count, producing a negative Enum.slice/3
    # amount. These tests verify the clamp fix prevents the crash.

    test "1-line file with offset well beyond EOF does not crash", %{tmp_dir: tmp_dir} do
      file_path = "single.ex"

      # No trailing newline => total_lines = 1
      File.write!(Path.join(tmp_dir, file_path), "single line")

      result = FileRead.execute(%{"file_path" => file_path, "offset" => 300}, tmp_dir, nil)

      assert is_binary(result)
      # The selection is empty, so the actual line content must be absent
      refute result =~ "single line"
    end

    test "multi-line file with offset beyond EOF does not crash", %{tmp_dir: tmp_dir} do
      file_path = "multi.ex"

      # No trailing newline => total_lines = 3
      File.write!(Path.join(tmp_dir, file_path), "line one\nline two\nline three")

      result = FileRead.execute(%{"file_path" => file_path, "offset" => 10}, tmp_dir, nil)

      assert is_binary(result)
      # No lines selected, so actual content must be absent
      refute result =~ "line one"
      refute result =~ "line two"
      refute result =~ "line three"
    end

    test "offset exactly equal to total_lines + 1 returns empty without crashing", %{
      tmp_dir: tmp_dir
    } do
      file_path = "three_lines.ex"

      # No trailing newline => total_lines = 3
      File.write!(Path.join(tmp_dir, file_path), "alpha\nbeta\ngamma")

      result = FileRead.execute(%{"file_path" => file_path, "offset" => 4}, tmp_dir, nil)

      assert is_binary(result)
      refute result =~ "alpha"
      refute result =~ "beta"
      refute result =~ "gamma"
    end
  end

  describe "execute/3 - limit extends past EOF" do
    test "returns only remaining lines from offset to EOF", %{tmp_dir: tmp_dir} do
      file_path = "partial.ex"

      # No trailing newline => total_lines = 3
      File.write!(Path.join(tmp_dir, file_path), "line one\nline two\nline three")

      result =
        FileRead.execute(
          %{"file_path" => file_path, "offset" => 2, "limit" => 100},
          tmp_dir,
          nil
        )

      assert is_binary(result)

      # Lines 2 and 3 should be present
      assert result =~ "2\tline two"
      assert result =~ "3\tline three"

      # Line 1 should NOT be present (we started at offset 2)
      refute result =~ "1\tline one"
      refute result =~ "line one"
    end
  end
end
