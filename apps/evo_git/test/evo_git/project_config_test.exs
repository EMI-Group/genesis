defmodule EvoGit.ProjectConfigTest do
  use ExUnit.Case, async: true

  alias EvoGit.ProjectConfig

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "evo_git_project_config_" <> to_string(System.unique_integer())
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  describe "read/1" do
    test "returns nil when no config file exists", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.read(tmp_dir) == nil
    end

    test "returns parsed map for valid genesis.toml", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup_worktree.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert %{"worktree" => %{"script" => "scripts/setup_worktree.sh"}} =
               ProjectConfig.read(tmp_dir)
    end

    test "returns empty map for empty genesis.toml", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "genesis.toml"), "")

      assert ProjectConfig.read(tmp_dir) == %{}
    end

    test "returns nil and logs warning for invalid TOML", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "genesis.toml"), "[invalid = missing_value")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ProjectConfig.read(tmp_dir) == nil
        end)

      assert log =~ "Failed to parse"
    end

    test "falls back to legacy evogit.toml when genesis.toml is absent", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup_worktree.sh"
      """

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

      assert %{"worktree" => %{"script" => "scripts/setup_worktree.sh"}} =
               ProjectConfig.read(tmp_dir)
    end

    test "prefers genesis.toml over legacy evogit.toml when both exist", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "genesis.toml"), "[commands]\ndev = \"mix test\"\n")
      File.write!(Path.join(tmp_dir, "evogit.toml"), "[commands]\ndev = \"npm run dev\"\n")

      config = ProjectConfig.read(tmp_dir)
      assert config["commands"]["dev"] == "mix test"
    end
  end

  describe "worktree_script/1" do
    test "returns nil when no config file exists", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.worktree_script(tmp_dir) == nil
    end

    test "returns script path when worktree.script is configured", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup_worktree.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir) == "scripts/setup_worktree.sh"
    end

    test "returns nil when worktree section exists but no script key", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      timeout = 30
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir) == nil
    end

    test "returns nil when config has no worktree section", %{tmp_dir: tmp_dir} do
      toml_content = """
      [other]
      key = "value"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir) == nil
    end
  end

  describe "foreign_repos/1" do
    test "returns empty list when no config file exists", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.foreign_repos(tmp_dir) == []
    end

    test "returns empty list when no foreign_repos section exists", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup_worktree.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.foreign_repos(tmp_dir) == []
    end

    test "parses multiple foreign repo entries", %{tmp_dir: tmp_dir} do
      toml_content = """
      [foreign_repos.original]
      path = "/Source/original-proj"

      [foreign_repos.reference]
      path = "/Source/rust-rewrite-proj"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      repos = ProjectConfig.foreign_repos(tmp_dir)

      assert length(repos) == 2

      ids = Enum.map(repos, & &1.id) |> Enum.sort()
      assert ids == ["original", "reference"]

      roots = Enum.map(repos, & &1.root) |> Enum.sort()
      assert roots == ["/Source/original-proj", "/Source/rust-rewrite-proj"]
    end

    test "handles optional description field", %{tmp_dir: tmp_dir} do
      toml_content = """
      [foreign_repos.original]
      path = "/Source/original-proj"
      description = "Legacy Project"

      [foreign_repos.reference]
      path = "/Source/rust-rewrite-proj"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      repos = ProjectConfig.foreign_repos(tmp_dir)

      original = Enum.find(repos, &(&1.id == "original"))
      reference = Enum.find(repos, &(&1.id == "reference"))

      # Explicit description is used when provided
      assert original.description == "Legacy Project"
      # Defaults to nil when description is omitted
      assert reference.description == nil
    end

    test "returns empty list and logs warning for invalid foreign_repos config", %{
      tmp_dir: tmp_dir
    } do
      toml_content = """
      [foreign_repos.broken]
      missing_path = "oops"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ProjectConfig.foreign_repos(tmp_dir) == []
        end)

      assert log =~ "Failed to parse foreign_repos"
    end
  end

  describe "worktree_script/2 (OS variants)" do
    test "returns OS-specific script when matching variant exists", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script.linux = "scripts/setup_linux.sh"
      script.macos = "scripts/setup_macos.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir, :linux) == "scripts/setup_linux.sh"
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == "scripts/setup_macos.sh"
    end

    test "returns nil when OS-specific variant does not exist", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script.linux = "scripts/setup_linux.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir, :macos) == nil
      assert ProjectConfig.worktree_script(tmp_dir, :windows) == nil
    end

    test "returns fallback string script when no OS-specific variants", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      # String script is returned regardless of OS queried
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == "scripts/setup.sh"
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == "scripts/setup.sh"
      assert ProjectConfig.worktree_script(tmp_dir, :windows) == "scripts/setup.sh"
    end

    test "returns nil when no config file exists", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == nil
    end

    test "returns nil when worktree section exists but no script", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      timeout = 30
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir, :linux) == nil
    end

    test "OS-specific map does not fall back to string (TOML parses as map or string, not both)" do
      # This test documents the behavior: when script is a map (OS variants),
      # a non-matching OS returns nil — it does NOT fall back to a separate
      # string script because TOML doesn't allow both forms simultaneously.
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "evo_git_project_config_" <> to_string(System.unique_integer())
        )

      File.mkdir_p!(tmp_dir)

      toml_content = """
      [worktree]
      script.linux = "scripts/setup_linux.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      # No macos variant in the map → nil
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == nil

      File.rm_rf!(tmp_dir)
    end
  end

  describe "commands/1" do
    test "parses commands correctly", %{tmp_dir: tmp_dir} do
      toml_content = """
      [commands]
      dev = "npm run dev"
      test = "mix test"
      build = "mix compile"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      commands = ProjectConfig.commands(tmp_dir)

      assert commands == %{
               "dev" => "npm run dev",
               "test" => "mix test",
               "build" => "mix compile"
             }
    end

    test "returns empty map when no commands section", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.commands(tmp_dir) == %{}
    end

    test "returns empty map when no config file exists", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.commands(tmp_dir) == %{}
    end
  end

  describe "write_worktree_script/2" do
    @scripts %{unix: "#!/bin/bash\ncp -R \"$SOURCE_REPO_PATH/deps\" \"$TARGET_WORKTREE_PATH/\"\n", windows: "# Copy deps\nCopy-Item -Recurse \"$env:SOURCE_REPO_PATH/deps\" \"$env:TARGET_WORKTREE_PATH/\"\n"}

    test "creates genesis.toml when it does not exist", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.read(tmp_dir) == nil

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      assert File.exists?(Path.join(tmp_dir, "genesis.toml"))
    end

    test "writes top-level comment when creating new genesis.toml", %{tmp_dir: tmp_dir} do
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      contents = File.read!(Path.join(tmp_dir, "genesis.toml"))

      assert contents =~ "genesis.toml — EvoGit project configuration file."
      assert contents =~ "EvoGit agents read this file automatically"
    end

    test "writes worktree section comment block", %{tmp_dir: tmp_dir} do
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      contents = File.read!(Path.join(tmp_dir, "genesis.toml"))

      assert contents =~ "Worktree Init Script"
      assert contents =~ "SOURCE_REPO_PATH"
      assert contents =~ "TARGET_WORKTREE_PATH"
      assert contents =~ "WARNING"
    end

    test "round-trips: written scripts are readable via worktree_script/2", %{tmp_dir: tmp_dir} do
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      assert ProjectConfig.worktree_script(tmp_dir, :linux) == @scripts.unix
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == @scripts.unix
      assert ProjectConfig.worktree_script(tmp_dir, :windows) == @scripts.windows
    end

    test "merges into existing genesis.toml preserving other sections", %{tmp_dir: tmp_dir} do
      toml_content = """
      [commands]
      dev = "mix test"

      [foreign_repos.original]
      path = "/Source/original-proj"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      # The script is readable
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == @scripts.unix

      # Other sections preserved
      config = ProjectConfig.read(tmp_dir)
      assert config["commands"]["dev"] == "mix test"
      assert config["foreign_repos"]["original"]["path"] == "/Source/original-proj"
    end

    test "preserves existing non-script keys in [worktree] section", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      timeout = 30
      verbose = true
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      config = ProjectConfig.read(tmp_dir)
      assert config["worktree"]["timeout"] == 30
      assert config["worktree"]["verbose"] == true
      assert config["worktree"]["script"]["linux"] == @scripts.unix
    end

    test "updates existing script values", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "genesis.toml"), "[worktree]\nscript = \"old.sh\"\n")

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      assert ProjectConfig.worktree_script(tmp_dir, :linux) == @scripts.unix
    end

    test "replaces existing single-string script with OS-variant form", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script.linux = "scripts/setup_linux.sh"
      script.macos = "scripts/setup_macos.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      # The OS-variant form now takes precedence
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == @scripts.unix
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == @scripts.unix
    end

    test "handles script content containing triple single quotes", %{tmp_dir: tmp_dir} do
      # Content with ''' — the encoder must fall back to escaped form
      tricky_scripts = %{
        unix: "echo hi\n'''\necho there\n",
        windows: "echo hi\n'''\necho there\n"
      }

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, tricky_scripts)

      assert ProjectConfig.worktree_script(tmp_dir, :linux) == tricky_scripts.unix
    end

    test "does not duplicate top-level comment when updating existing file", %{tmp_dir: tmp_dir} do
      # First write creates the file with top-level comment
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      # Second write should not duplicate the top-level comment
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      contents = File.read!(Path.join(tmp_dir, "genesis.toml"))

      # Count occurrences of the top-level comment first line
      first_line = "# genesis.toml — EvoGit project configuration file."
      count = contents |> String.split("\n") |> Enum.count(&(&1 == first_line))

      assert count == 1
    end

    test "does not duplicate worktree comment block when updating existing file", %{
      tmp_dir: tmp_dir
    } do
      # First write creates the file with worktree comment block
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      # Second write should not duplicate the worktree comment block
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      contents = File.read!(Path.join(tmp_dir, "genesis.toml"))

      # Count occurrences of the comment block header
      count = contents |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "# ───"))

      assert count == 1
    end
  end
end
