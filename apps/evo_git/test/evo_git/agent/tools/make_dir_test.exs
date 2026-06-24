defmodule EvoGit.Agent.Tools.MakeDirTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.MakeDir

  describe "schema/0" do
    test "returns a valid tool schema" do
      schema = MakeDir.schema()

      assert schema.name == "make_dir"
      assert is_binary(schema.description)
      assert schema.description =~ "Git does NOT track empty directories"
      assert schema.description =~ "CONTEXT.md"
    end

    test "schema has correct parameters" do
      schema = MakeDir.schema()
      props = schema.parameter_schema["properties"]

      assert "paths" in Map.keys(props)
      assert "keep_file" in Map.keys(props)
      assert "commit" in Map.keys(props)
      assert "parents" in Map.keys(props)

      assert props["paths"]["type"] == "array"
      assert props["keep_file"]["enum"] == ~w(CONTEXT.md .gitkeep none)
      assert props["keep_file"]["default"] == "CONTEXT.md"
      assert props["commit"]["default"] == true
      assert props["parents"]["default"] == true
    end
  end

  describe "execute/3 - basic directory creation" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "make_dir_test_" <> to_string(System.unique_integer()))

      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "creates a single directory with CONTEXT.md by default", %{tmp_dir: tmp_dir} do
      # Set commit to false since we don't have a git repo
      result = MakeDir.execute(%{"paths" => ["lib"], "commit" => false}, tmp_dir, nil)

      assert result =~ "Successfully created 1 directory"
      assert result =~ "lib"

      assert File.dir?(Path.join(tmp_dir, "lib"))
      assert File.exists?(Path.join(tmp_dir, "lib/CONTEXT.md"))
      assert File.read!(Path.join(tmp_dir, "lib/CONTEXT.md")) == ""
    end

    test "creates multiple directories", %{tmp_dir: tmp_dir} do
      result = MakeDir.execute(%{"paths" => ["lib", "test", "config"], "commit" => false}, tmp_dir, nil)

      assert result =~ "Successfully created 3 directories"

      assert File.dir?(Path.join(tmp_dir, "lib"))
      assert File.dir?(Path.join(tmp_dir, "test"))
      assert File.dir?(Path.join(tmp_dir, "config"))

      assert File.exists?(Path.join(tmp_dir, "lib/CONTEXT.md"))
      assert File.exists?(Path.join(tmp_dir, "test/CONTEXT.md"))
      assert File.exists?(Path.join(tmp_dir, "config/CONTEXT.md"))
    end

    test "creates nested directories when parents is true (default)", %{tmp_dir: tmp_dir} do
      result = MakeDir.execute(%{"paths" => ["lib/core/utils"], "commit" => false}, tmp_dir, nil)

      assert result =~ "Successfully created 1 directory"

      assert File.dir?(Path.join(tmp_dir, "lib/core/utils"))
      assert File.exists?(Path.join(tmp_dir, "lib/core/utils/CONTEXT.md"))
    end

    test "creates nested directories with parents: true explicitly", %{tmp_dir: tmp_dir} do
      result =
        MakeDir.execute(%{"paths" => ["deep/nested/path"], "parents" => true, "commit" => false}, tmp_dir, nil)

      assert result =~ "Successfully created 1 directory"

      assert File.dir?(Path.join(tmp_dir, "deep/nested/path"))
    end
  end

  describe "execute/3 - keep_file options" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "make_dir_keep_test_" <> to_string(System.unique_integer()))

      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "creates .gitkeep file when keep_file is .gitkeep", %{tmp_dir: tmp_dir} do
      result = MakeDir.execute(%{"paths" => ["lib"], "keep_file" => ".gitkeep", "commit" => false}, tmp_dir, nil)

      assert result =~ "Successfully created 1 directory"

      refute File.exists?(Path.join(tmp_dir, "lib/CONTEXT.md"))
      assert File.exists?(Path.join(tmp_dir, "lib/.gitkeep"))
    end

    test "creates no placeholder file when keep_file is none", %{tmp_dir: tmp_dir} do
      result = MakeDir.execute(%{"paths" => ["lib"], "keep_file" => "none", "commit" => false}, tmp_dir, nil)

      assert result =~ "Successfully created 1 directory"

      refute File.exists?(Path.join(tmp_dir, "lib/CONTEXT.md"))
      refute File.exists?(Path.join(tmp_dir, "lib/.gitkeep"))
      assert File.dir?(Path.join(tmp_dir, "lib"))
    end

    test "creates CONTEXT.md when keep_file is CONTEXT.md explicitly", %{tmp_dir: tmp_dir} do
      result =
        MakeDir.execute(%{"paths" => ["lib"], "keep_file" => "CONTEXT.md", "commit" => false}, tmp_dir, nil)

      assert result =~ "Successfully created 1 directory"
      assert File.exists?(Path.join(tmp_dir, "lib/CONTEXT.md"))
    end

    test "returns error tuple for invalid keep_file value", %{tmp_dir: tmp_dir} do
      result = MakeDir.execute(%{"paths" => ["lib"], "keep_file" => "invalid.txt"}, tmp_dir, nil)

      assert {:error, message} = result
      assert message =~ "Invalid keep_file value"
    end
  end

  describe "execute/3 - parents option" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "make_dir_parents_test_" <> to_string(System.unique_integer()))

      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "errors when parents is false and parent directory doesn't exist", %{tmp_dir: tmp_dir} do
      result =
        MakeDir.execute(%{"paths" => ["missing/nested/path"], "parents" => false, "commit" => false}, tmp_dir, nil)

      assert result =~ "Errors:"
      assert result =~ "missing/nested/path"
    end

    test "succeeds when parents is false and parent directory exists", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "existing"))

      result =
        MakeDir.execute(%{"paths" => ["existing/child"], "parents" => false, "commit" => false}, tmp_dir, nil)

      assert result =~ "Successfully created 1 directory"
      assert File.dir?(Path.join(tmp_dir, "existing/child"))
    end

    test "returns error tuple for invalid parents value", %{tmp_dir: tmp_dir} do
      result = MakeDir.execute(%{"paths" => ["lib"], "parents" => "yes"}, tmp_dir, nil)

      assert {:error, message} = result
      assert message =~ "parents must be a boolean"
    end
  end

  describe "execute/3 - commit option" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "make_dir_commit_test_" <> to_string(System.unique_integer()))

      File.mkdir_p!(tmp_dir)

      # Initialize a git repository
      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)

      # Create an initial commit
      File.write!(Path.join(tmp_dir, "README.md"), "init")
      System.cmd("git", ["add", "README.md"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "init commit"], cd: tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "commits keep files when commit is true", %{tmp_dir: tmp_dir} do
      result = MakeDir.execute(%{"paths" => ["lib"], "commit" => true}, tmp_dir, tmp_dir)

      assert result =~ "Successfully created 1 directory"
      assert result =~ "Changes committed"

      # Check git status - should be clean (no uncommitted changes)
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: tmp_dir)
      assert status == ""

      # Check commit message
      {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: tmp_dir)
      assert log =~ "Create directory"
      assert log =~ "lib"
    end

    test "does not commit when commit is false", %{tmp_dir: tmp_dir} do
      result = MakeDir.execute(%{"paths" => ["lib"], "commit" => false}, tmp_dir, tmp_dir)

      assert result =~ "Successfully created 1 directory"
      refute result =~ "Changes committed"

      # Check git status - should show uncommitted changes
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: tmp_dir)
      # Git shows untracked files, either as lib/CONTEXT.md or just lib/
      assert status != ""
    end

    test "only stages keep files, not other dirty files", %{tmp_dir: tmp_dir} do
      # Create a dirty file that should NOT be committed
      File.write!(Path.join(tmp_dir, "dirty.txt"), "dirty content")

      # Create directory with commit
      result = MakeDir.execute(%{"paths" => ["lib"], "commit" => true}, tmp_dir, tmp_dir)

      assert result =~ "Successfully created 1 directory"

      # Check that dirty.txt is still uncommitted
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: tmp_dir)
      assert status =~ "dirty.txt"

      # But CONTEXT.md should be committed
      assert File.exists?(Path.join(tmp_dir, "lib/CONTEXT.md"))
      {diff, 0} = System.cmd("git", ["diff", "HEAD", "--", "lib/CONTEXT.md"], cd: tmp_dir)
      # If it's committed, diff should be empty
      assert diff == ""
    end

    test "skips commit when keep_file is none", %{tmp_dir: tmp_dir} do
      result = MakeDir.execute(%{"paths" => ["lib"], "keep_file" => "none", "commit" => true}, tmp_dir, tmp_dir)

      assert result =~ "Successfully created 1 directory"
      # When keep_file is none, there's nothing to commit
      # The result message should indicate directories were created
      assert File.dir?(Path.join(tmp_dir, "lib"))
    end
  end

  describe "execute/3 - error handling" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "make_dir_error_test_" <> to_string(System.unique_integer()))

      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "handles mixed success and failure", %{tmp_dir: tmp_dir} do
      # Create one existing directory
      File.mkdir_p!(Path.join(tmp_dir, "existing"))

      # Try to create multiple directories, one will fail due to parents: false
      result =
        MakeDir.execute(
          %{"paths" => ["existing/child", "missing/nested", "another"], "parents" => false, "commit" => false},
          tmp_dir,
          nil
        )

      assert result =~ "Created"
      assert result =~ "Errors:"
    end

    test "returns error tuple for invalid paths format", %{tmp_dir: tmp_dir} do
      result = MakeDir.execute(%{"paths" => "not-an-array"}, tmp_dir, nil)

      # Should return an error tuple
      assert {:error, message} = result
      assert message =~ "must be an array"
    end

    test "returns error string (not a crash) for absolute path with node_path set", %{tmp_dir: tmp_dir} do
      result =
        MakeDir.execute(
          %{"paths" => ["/tmp/test_outside_dir"], "commit" => false},
          tmp_dir,
          nil,
          "./lib"
        )

      assert is_binary(result)
      assert result =~ "outside the repository root"
      assert result =~ "/tmp/test_outside_dir"
      assert result =~ "relative to the repository root"
    end
  end
end
