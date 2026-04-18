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
      assert "write_file" in names
    end
  end

  describe "schema/1" do
    test "returns a specific schema by name" do
      schema = Tools.schema("read_file")
      assert schema.name == "read_file"
      assert is_map(schema.parameter_schema)
    end
  end

  describe "execute/4 - read_file" do
    test "reads an existing file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world")

      result = Tools.execute("read_file", %{"file_path" => "test.txt"}, tmp_dir)
      assert result == "hello world"
    end

    test "returns error for missing file", %{tmp_dir: tmp_dir} do
      result = Tools.execute("read_file", %{"file_path" => "missing.txt"}, tmp_dir)
      assert result =~ "Error reading file"
    end
  end

  describe "execute/4 - read_many_files" do
    test "reads multiple existing files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test1.txt"), "content 1")
      File.write!(Path.join(tmp_dir, "test2.txt"), "content 2")

      result =
        Tools.execute("read_many_files", %{"file_paths" => ["test1.txt", "test2.txt"]}, tmp_dir)

      assert result =~ "File: test1.txt\ncontent 1"
      assert result =~ "File: test2.txt\ncontent 2"
    end
  end

  describe "execute/4 - write_file" do
    test "writes to a new file and creates directory", %{tmp_dir: tmp_dir} do
      result =
        Tools.execute(
          "write_file",
          %{"file_path" => "new_dir/test.txt", "content" => "new content"},
          tmp_dir
        )

      assert result =~ "Successfully wrote to"

      assert File.read!(Path.join([tmp_dir, "new_dir", "test.txt"])) == "new content"
    end
  end

  describe "execute/4 - rewrite_file" do
    test "rewrites an existing file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "old content")

      result =
        Tools.execute(
          "rewrite_file",
          %{"file_path" => "test.txt", "content" => "new content"},
          tmp_dir
        )

      assert result =~ "Successfully rewrote"

      assert File.read!(file_path) == "new content"
    end

    test "returns error if file does not exist", %{tmp_dir: tmp_dir} do
      result =
        Tools.execute(
          "rewrite_file",
          %{"file_path" => "missing.txt", "content" => "content"},
          tmp_dir
        )

      assert result =~ "does not exist or is not a regular file"
    end
  end

  describe "execute/4 - create_files" do
    test "creates multiple empty files", %{tmp_dir: tmp_dir} do
      result = Tools.execute("create_files", %{"file_paths" => ["f1.txt", "dir/f2.txt"]}, tmp_dir)
      assert result =~ "Successfully created file f1.txt"
      assert result =~ "Successfully created file dir/f2.txt"

      assert File.read!(Path.join(tmp_dir, "f1.txt")) == ""
      assert File.read!(Path.join([tmp_dir, "dir", "f2.txt"])) == ""
    end
  end

  describe "execute/4 - create_directories" do
    test "creates directories with .gitkeep", %{tmp_dir: tmp_dir} do
      result = Tools.execute("create_directories", %{"dir_paths" => ["d1", "d2/sub"]}, tmp_dir)
      assert result =~ "Successfully created directory d1"
      assert result =~ "Successfully created directory d2/sub"

      assert File.exists?(Path.join([tmp_dir, "d1", ".gitkeep"]))
      assert File.exists?(Path.join([tmp_dir, "d2", "sub", ".gitkeep"]))
    end
  end

  describe "execute/4 - replace_in_file" do
    test "replaces exact text in file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world 123")

      result =
        Tools.execute(
          "replace_in_file",
          %{"file_path" => "test.txt", "old_text" => "world", "new_text" => "elixir"},
          tmp_dir
        )

      assert result =~ "Successfully replaced text"

      assert File.read!(file_path) == "hello elixir 123"
    end

    test "returns error if old text not found", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world")

      result =
        Tools.execute(
          "replace_in_file",
          %{"file_path" => "test.txt", "old_text" => "missing", "new_text" => "elixir"},
          tmp_dir
        )

      assert result =~ "not found in file"
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
