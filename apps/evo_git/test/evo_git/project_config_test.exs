defmodule EvoGit.ProjectConfigTest do
  use ExUnit.Case, async: true

  alias EvoGit.ProjectConfig

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evo_git_project_config_" <> to_string(System.unique_integer()))

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

    test "returns parsed map for valid evogit.toml", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup_worktree.sh"
      """

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

      assert %{"worktree" => %{"script" => "scripts/setup_worktree.sh"}} =
               ProjectConfig.read(tmp_dir)
    end

    test "returns empty map for empty evogit.toml", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "evogit.toml"), "")

      assert ProjectConfig.read(tmp_dir) == %{}
    end

    test "returns nil and logs warning for invalid TOML", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "evogit.toml"), "[invalid = missing_value")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ProjectConfig.read(tmp_dir) == nil
        end)

      assert log =~ "Failed to parse"
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

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir) == "scripts/setup_worktree.sh"
    end

    test "returns nil when worktree section exists but no script key", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      timeout = 30
      """

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir) == nil
    end

    test "returns nil when config has no worktree section", %{tmp_dir: tmp_dir} do
      toml_content = """
      [other]
      key = "value"
      """

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

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

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

      assert ProjectConfig.foreign_repos(tmp_dir) == []
    end

    test "parses multiple foreign repo entries", %{tmp_dir: tmp_dir} do
      toml_content = """
      [foreign_repos.original]
      path = "/Source/original-proj"

      [foreign_repos.reference]
      path = "/Source/rust-rewrite-proj"
      """

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

      repos = ProjectConfig.foreign_repos(tmp_dir)

      assert length(repos) == 2

      ids = Enum.map(repos, & &1.id) |> Enum.sort()
      assert ids == [:original, :reference]

      roots = Enum.map(repos, & &1.root) |> Enum.sort()
      assert roots == ["/Source/original-proj", "/Source/rust-rewrite-proj"]
    end

    test "handles optional name field", %{tmp_dir: tmp_dir} do
      toml_content = """
      [foreign_repos.original]
      path = "/Source/original-proj"
      name = "Legacy Project"

      [foreign_repos.reference]
      path = "/Source/rust-rewrite-proj"
      """

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

      repos = ProjectConfig.foreign_repos(tmp_dir)

      original = Enum.find(repos, &(&1.id == :original))
      reference = Enum.find(repos, &(&1.id == :reference))

      # Explicit name is used when provided
      assert original.name == "Legacy Project"
      # Falls back to nil when name is omitted (default name is set by ForeignRepo.new/3 only when name key is absent)
      assert reference.name == nil
    end

    test "returns empty list and logs warning for invalid foreign_repos config", %{
      tmp_dir: tmp_dir
    } do
      toml_content = """
      [foreign_repos.broken]
      missing_path = "oops"
      """

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

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

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir, :linux) == "scripts/setup_linux.sh"
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == "scripts/setup_macos.sh"
    end

    test "returns nil when OS-specific variant does not exist", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script.linux = "scripts/setup_linux.sh"
      """

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir, :macos) == nil
      assert ProjectConfig.worktree_script(tmp_dir, :windows) == nil
    end

    test "returns fallback string script when no OS-specific variants", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup.sh"
      """

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

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

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir, :linux) == nil
    end

    test "OS-specific map does not fall back to string (TOML parses as map or string, not both)" do
      # This test documents the behavior: when script is a map (OS variants),
      # a non-matching OS returns nil — it does NOT fall back to a separate
      # string script because TOML doesn't allow both forms simultaneously.
      tmp_dir =
        Path.join(System.tmp_dir!(), "evo_git_project_config_" <> to_string(System.unique_integer()))

      File.mkdir_p!(tmp_dir)

      toml_content = """
      [worktree]
      script.linux = "scripts/setup_linux.sh"
      """

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

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

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

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

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

      assert ProjectConfig.commands(tmp_dir) == %{}
    end

    test "returns empty map when no config file exists", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.commands(tmp_dir) == %{}
    end
  end
end
