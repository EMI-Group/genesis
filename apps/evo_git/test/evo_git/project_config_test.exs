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
end
