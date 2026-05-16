defmodule EvoGit.Agent.Tools.SearchContextTest do
  use ExUnit.Case
  alias EvoGit.Agent.Tools

  @moduletag :tmp_dir

  describe "schemas/0 - search_context" do
    test "search_context schema is included in tool schemas" do
      schemas = Tools.schemas()
      names = Enum.map(schemas, & &1.name)
      assert "search_context" in names
    end
  end

  describe "execute/4 - search_context" do
    test "finds pattern in CONTEXT.md files", %{tmp_dir: tmp_dir} do
      # Create directories with CONTEXT.md files
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.mkdir_p!(Path.join(tmp_dir, "src"))
      File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "This is the library module.\nIt handles data processing.")
      File.write!(Path.join(tmp_dir, "src/CONTEXT.md"), "This is the source module.\nIt handles UI rendering.")

      result = Tools.execute("search_context", %{"pattern" => "data processing"}, tmp_dir)

      assert result =~ "Command executed successfully"
      assert result =~ "data processing"
    end

    test "searches only CONTEXT.md files, not other files", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "Module documentation")
      File.write!(Path.join(tmp_dir, "lib/code.ex"), "unique_pattern_xyz in code")

      result = Tools.execute("search_context", %{"pattern" => "unique_pattern_xyz"}, tmp_dir)

      assert result =~ "No matches found"
    end

    test "searches within specified path", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.mkdir_p!(Path.join(tmp_dir, "src"))
      File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "library context with special_keyword")
      File.write!(Path.join(tmp_dir, "src/CONTEXT.md"), "source context without the keyword")

      result = Tools.execute("search_context", %{"pattern" => "special_keyword", "path" => "lib"}, tmp_dir)

      assert result =~ "Command executed successfully"
      assert result =~ "special_keyword"
    end

    test "returns no matches when pattern not found", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "some content")

      result = Tools.execute("search_context", %{"pattern" => "nonexistent_pattern_xyz"}, tmp_dir)

      assert result =~ "No matches found"
    end

    test "returns error when pattern is missing" do
      result = Tools.execute("search_context", %{}, "/tmp")
      assert result =~ "Missing required argument"
    end
  end
end
