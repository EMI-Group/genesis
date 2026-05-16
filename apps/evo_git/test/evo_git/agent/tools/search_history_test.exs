defmodule EvoGit.Agent.Tools.SearchHistoryTest do
  use ExUnit.Case
  alias EvoGit.Agent.Tools

  @moduletag :tmp_dir

  describe "schemas/0 - search_history" do
    test "search_history schema is included in tool schemas" do
      schemas = Tools.schemas()
      names = Enum.map(schemas, & &1.name)
      assert "search_history" in names
    end
  end

  describe "execute/4 - search_history" do
    setup %{tmp_dir: tmp_dir} do
      # Initialize a git repository
      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)

      # Create initial commit
      File.write!(Path.join(tmp_dir, "README.md"), "init")
      System.cmd("git", ["add", "README.md"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_dir)

      # Create a second commit with a distinctive message
      File.write!(Path.join(tmp_dir, "feature.txt"), "feature")
      System.cmd("git", ["add", "feature.txt"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "Add feature: user authentication"], cd: tmp_dir)

      # Create a third commit
      File.write!(Path.join(tmp_dir, "bugfix.txt"), "fix")
      System.cmd("git", ["add", "bugfix.txt"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "Fix: resolve crash on startup"], cd: tmp_dir)

      :ok
    end

    test "finds commits matching a pattern", %{tmp_dir: tmp_dir} do
      result = Tools.execute("search_history", %{"pattern" => "authentication"}, tmp_dir, tmp_dir)

      assert result =~ "Found 1 commit(s)"
      assert result =~ "Add feature: user authentication"
    end

    test "finds commits with regex pattern", %{tmp_dir: tmp_dir} do
      result = Tools.execute("search_history", %{"pattern" => "Add|Fix"}, tmp_dir, tmp_dir)

      assert result =~ "Found 2 commit(s)"
    end

    test "returns no matches for non-existent pattern", %{tmp_dir: tmp_dir} do
      result = Tools.execute("search_history", %{"pattern" => "nonexistent_pattern_xyz"}, tmp_dir, tmp_dir)

      assert result =~ "No commits found"
    end

    test "returns error for invalid regex", %{tmp_dir: tmp_dir} do
      result = Tools.execute("search_history", %{"pattern" => "[invalid"}, tmp_dir, tmp_dir)

      assert result =~ "Error compiling pattern"
    end

    test "returns error when pattern is missing" do
      result = Tools.execute("search_history", %{}, "/tmp")
      assert result =~ "Missing required argument"
    end

    test "respects max_count option", %{tmp_dir: tmp_dir} do
      # Search with max_count=1, should only search 1 commit (the most recent: "Fix: resolve crash on startup")
      # The pattern "Fix" matches the most recent commit
      result = Tools.execute("search_history", %{"pattern" => "Fix", "max_count" => 1}, tmp_dir, tmp_dir)

      assert result =~ "Found 1 commit(s)"
      assert result =~ "Fix: resolve crash on startup"

      # With max_count=1, the older "Add feature" commit should NOT be found
      refute result =~ "Add feature"
    end
  end
end
