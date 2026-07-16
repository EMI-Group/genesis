defmodule EvoGit.Sandbox.HelpersTest do
  use ExUnit.Case, async: true

  alias EvoGit.Sandbox.Helpers

  describe "shell_escape/1" do
    test "wraps a simple argument in single quotes" do
      assert Helpers.shell_escape("hello") == "'hello'"
    end

    test "wraps an empty string in single quotes" do
      assert Helpers.shell_escape("") == "''"
    end

    test "escapes single quotes using the '\\'' sequence" do
      # it's → 'it'\''s'
      assert Helpers.shell_escape("it's") == "'it'\\''s'"
    end

    test "escapes multiple single quotes" do
      # a'b'c → 'a'\''b'\''c
      assert Helpers.shell_escape("a'b'c") == "'a'\\''b'\\''c'"
    end

    test "escapes an argument that is a single quote" do
      assert Helpers.shell_escape("'") == "''\\'''"
    end

    test "handles arguments with shell metacharacters safely" do
      # Dangerous shell metacharacters must be inside the single-quoted wrapper
      # so they are treated literally.
      escaped = Helpers.shell_escape("; rm -rf /")

      assert String.starts_with?(escaped, "'")
      assert String.ends_with?(escaped, "'")
      assert escaped == "'; rm -rf /'"
    end

    test "handles backticks and dollar signs (no interpolation inside single quotes)" do
      assert Helpers.shell_escape("$(whoami)") == "'$(whoami)'"
      assert Helpers.shell_escape("`whoami`") == "'`whoami`'"
    end
  end

  describe "read_tempfile/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "helpers_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, %{dir: dir}}
    end

    test "reads and deletes a small file", %{dir: dir} do
      file = Path.join(dir, "small.txt")
      File.write!(file, "hello world")

      assert Helpers.read_tempfile(file, nil) == "hello world"
      refute File.exists?(file), "temp file should be deleted after reading"
    end

    test "returns empty string for a non-existent file" do
      refute File.exists?(Path.join(System.tmp_dir!(), "definitely_nonexistent_file"))

      assert Helpers.read_tempfile(
               Path.join(System.tmp_dir!(), "definitely_nonexistent_file"),
               nil
             ) == ""
    end

    test "reads the entire file when max_bytes is nil", %{dir: dir} do
      file = Path.join(dir, "full.txt")
      content = String.duplicate("A", 1000)
      File.write!(file, content)

      assert Helpers.read_tempfile(file, nil) == content
    end

    test "reads the entire file when size is under max_bytes", %{dir: dir} do
      file = Path.join(dir, "under.txt")
      content = String.duplicate("B", 100)
      File.write!(file, content)

      assert Helpers.read_tempfile(file, 500) == content
    end

    test "truncates with warning when file exceeds max_bytes and truncate_size", %{dir: dir} do
      file = Path.join(dir, "large.txt")
      prefix = String.duplicate("X", 100)
      suffix = String.duplicate("Z", 100)
      middle = String.duplicate("M", 20_000 - 200)
      File.write!(file, prefix <> middle <> suffix)

      output = Helpers.read_tempfile(file, 5000)

      assert output =~ "[WARNING: Output exceeded 5000 bytes and was truncated to 8192 bytes]"
      assert output =~ String.duplicate("X", 100)
      assert output =~ String.duplicate("Z", 100)
      omitted = 20_000 - 8192
      assert output =~ "... [#{omitted} bytes omitted] ..."
    end

    test "reads entire file when size exceeds max_bytes but is under truncate_size", %{dir: dir} do
      file = Path.join(dir, "edge.txt")
      content = String.duplicate("E", 200)
      File.write!(file, content)

      # max_bytes=100, file=200 bytes — file exceeds max_bytes but is well
      # under truncate_size (8192), so it should be read entirely.
      assert Helpers.read_tempfile(file, 100) == content
    end
  end

  describe "system_cmd/2" do
    test "runs a command successfully and returns {:ok, output}" do
      assert {:ok, output} = Helpers.system_cmd("echo", ["hello"])
      assert String.contains?(output, "hello")
    end

    test "returns {:error, output} for a failing command" do
      # `false` always exits with code 1
      assert {:error, _output} = Helpers.system_cmd("false", [])
    end

    test "returns {:error, _} when the command is not found" do
      assert {:error, msg} = Helpers.system_cmd("this_command_definitely_does_not_exist_xyz", [])
      assert String.contains?(msg, "command not found")
    end
  end
end
