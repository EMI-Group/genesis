defmodule EvoGit.Agent.ToolsTest do
  use ExUnit.Case
  alias EvoGit.Agent.Tools

  @moduletag :tmp_dir

  describe "schemas/0" do
    test "returns a list of tool schemas" do
      schemas = Tools.schemas()
      assert is_list(schemas)
      assert length(schemas) > 0

      names = Enum.map(schemas, & &1.name)
      assert "read_file" in names
      assert "file_write" in names
      assert "file_edit" in names
    end
  end

  describe "schema/1" do
    test "returns a specific schema by name" do
      schema = Tools.schema(:read_file)
      assert schema.name == "read_file"
      assert is_map(schema.parameter_schema)
    end
  end

  describe "execute/4 - read_file" do
    test "reads an existing file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world")

      result = Tools.execute("read_file", %{"file_path" => "test.txt"}, tmp_dir)
      assert result =~ "1\thello world"
    end

    test "reads an existing file without line numbers", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world")

      result = Tools.execute("read_file", %{"file_path" => "test.txt", "line_numbers" => false}, tmp_dir)
      refute result =~ "1\thello world"
      assert result =~ "hello world"
    end

    test "returns error for missing file", %{tmp_dir: tmp_dir} do
      result = Tools.execute("read_file", %{"file_path" => "missing.txt"}, tmp_dir)
      assert result =~ "Error reading file"
    end
  end

  describe "execute/4 - file_write" do
    test "writes to a new file and creates directory", %{tmp_dir: tmp_dir} do
      result =
        Tools.execute(
          "file_write",
          %{"file_path" => "new_dir/test.txt", "content" => "new content"},
          tmp_dir
        )

      assert result =~ "Successfully wrote to"

      assert File.read!(Path.join([tmp_dir, "new_dir", "test.txt"])) == "new content"
    end
  end

  describe "execute/4 - file_edit" do
    test "replaces exact text in file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world 123")

      result =
        Tools.execute(
          "file_edit",
          %{"file_path" => "test.txt", "old_string" => "world", "new_string" => "elixir"},
          tmp_dir
        )

      assert result =~ "has been updated successfully"
      assert File.read!(file_path) == "hello elixir 123"
    end

    test "replaces all occurrences when replace_all is true", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world hello world")

      result =
        Tools.execute(
          "file_edit",
          %{
            "file_path" => "test.txt",
            "old_string" => "hello",
            "new_string" => "hi",
            "replace_all" => true
          },
          tmp_dir
        )

      assert result =~ "All occurrences were successfully replaced"
      assert File.read!(file_path) == "hi world hi world"
    end

    test "returns error if multiple matches found without replace_all", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world hello world")

      result =
        Tools.execute(
          "file_edit",
          %{"file_path" => "test.txt", "old_string" => "hello", "new_string" => "hi"},
          tmp_dir
        )

      assert result =~ "Found 2 matches"
      assert result =~ "Set replace_all=true"
      assert File.read!(file_path) == "hello world hello world"
    end

    test "strips trailing whitespace from new_string", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world")

      result =
        Tools.execute(
          "file_edit",
          %{"file_path" => "test.txt", "old_string" => "world", "new_string" => "elixir   \n\n"},
          tmp_dir
        )

      assert result =~ "has been updated successfully"
      assert File.read!(file_path) == "hello elixir"
    end

    test "returns error if old_string not found", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world")

      result =
        Tools.execute(
          "file_edit",
          %{"file_path" => "test.txt", "old_string" => "missing", "new_string" => "elixir"},
          tmp_dir
        )

      assert result =~ "old_string not found in file"
    end
  end

  describe "execute/4 - read_dir_context" do
    test "reads existing CONTEXT.md", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)
      File.write!(Path.join(dir_path, "CONTEXT.md"), "dir context")

      result = Tools.execute("read_dir_context", %{"dir_path" => "lib"}, tmp_dir)
      assert result == "dir context"
    end

    test "returns error if CONTEXT.md missing", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)

      result = Tools.execute("read_dir_context", %{"dir_path" => "lib"}, tmp_dir)
      assert result =~ "No CONTEXT.md found"
    end

    test "returns error if directory is missing", %{tmp_dir: tmp_dir} do
      result = Tools.execute("read_dir_context", %{"dir_path" => "missing"}, tmp_dir)
      assert result =~ "does not exist"
    end

    test "returns error if path is a file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "")

      result = Tools.execute("read_dir_context", %{"dir_path" => "test.txt"}, tmp_dir)
      assert result =~ "is a file, not a directory"
    end
  end

  describe "execute/4 - glob" do
    test "returns matching paths", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join(tmp_dir, "lib/a.ex"), "")
      File.write!(Path.join(tmp_dir, "lib/b.ex"), "")

      result = Tools.execute("glob", %{"pattern" => "lib/*.ex"}, tmp_dir)

      assert result =~ "lib/a.ex"
      assert result =~ "lib/b.ex"
    end

    test "returns message if no matches", %{tmp_dir: tmp_dir} do
      result = Tools.execute("glob", %{"pattern" => "missing/*.ex"}, tmp_dir)
      assert result =~ "No files found matching pattern"
    end
  end

  describe "execute/4 - list_directory" do
    test "lists contents of a directory", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)
      File.write!(Path.join(dir_path, "a.ex"), "")
      File.mkdir_p!(Path.join(dir_path, "sub"))

      result = Tools.execute("list_directory", %{"dir_path" => "lib"}, tmp_dir)

      files = String.split(result, "\n")
      assert "a.ex" in files
      assert "sub" in files
    end

    test "returns error for missing directory", %{tmp_dir: tmp_dir} do
      result = Tools.execute("list_directory", %{"dir_path" => "missing"}, tmp_dir)
      assert result =~ "Error listing directory"
    end
  end

  describe "execute/4 - rewrite_dir_context" do
    test "writes CONTEXT.md and commits in systemd-run sandbox", %{tmp_dir: tmp_dir} do
      # Initialize a git repository
      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)

      # Create an initial commit so we have a HEAD
      File.write!(Path.join(tmp_dir, "README.md"), "init")
      System.cmd("git", ["add", "README.md"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "init commit"], cd: tmp_dir)

      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)

      # Pass repo_root as tmp_dir as well so that systemd-run has access to .git
      result = Tools.execute("rewrite_dir_context", %{"dir_path" => "lib", "content" => "new context", "commit" => true}, tmp_dir, tmp_dir)
      assert result =~ "Successfully updated CONTEXT.md for directory 'lib'"
      assert result =~ "Committed:"

      assert File.read!(Path.join(dir_path, "CONTEXT.md")) == "new context"

      # Check git log
      {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: tmp_dir)
      assert log =~ "Update CONTEXT.md for lib"
    end

    test "writes CONTEXT.md without committing", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)

      result =
        Tools.execute(
          "rewrite_dir_context",
          %{"dir_path" => "lib", "content" => "new context", "commit" => false},
          tmp_dir
        )

      assert result == "Successfully updated CONTEXT.md for directory 'lib'"

      assert File.read!(Path.join(dir_path, "CONTEXT.md")) == "new context"
    end

    test "returns error if directory does not exist", %{tmp_dir: tmp_dir} do
      result =
        Tools.execute(
          "rewrite_dir_context",
          %{"dir_path" => "missing", "content" => "context"},
          tmp_dir
        )

      assert result =~ "does not exist"
    end

    test "returns error if path is a file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "")

      result =
        Tools.execute(
          "rewrite_dir_context",
          %{"dir_path" => "test.txt", "content" => "context"},
          tmp_dir
        )

      assert result =~ "is a file, not a directory"
    end
  end

  describe "execute/4 - unknown tool" do
    test "returns error for unknown tool", %{tmp_dir: tmp_dir} do
      result = Tools.execute("unknown_tool", %{}, tmp_dir)
      assert result =~ "Unknown tool"
    end
  end
end
