defmodule EvoGit.Agent.DelegationHintsTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.Config.Schema

  # A minimal module that adopts the EvoGit.Agent behaviour so we can exercise
  # the private delegation-hinting path helpers directly. The behaviour injects
  # the private functions (path_to_child_dir/3, file_path_to_child_dir/3, etc.)
  # into this module; we re-export them through public test wrappers.
  defmodule HintAgent do
    use EvoGit.Agent

    def test_path_to_child_dir(dir_path, node_path, repo_path) do
      path_to_child_dir(dir_path, node_path, repo_path)
    end

    def test_file_path_to_child_dir(file_path, node_path, repo_path) do
      file_path_to_child_dir(file_path, node_path, repo_path)
    end
  end

  # ── Config schema tests ──────────────────────────────────────────────────

  describe "delegation_hint_threshold config schema" do
    test "is present in all_schemas" do
      schemas = Schema.all_schemas()
      keys = Enum.map(schemas, & &1.key_path)
      assert [:scheduler, :delegation_hint_threshold] in keys
    end

    test "defaults to 5" do
      defaults = Schema.defaults()
      assert defaults.scheduler.delegation_hint_threshold == 5
    end

    test "has correct type and validation" do
      schema =
        Enum.find(Schema.all_schemas(), &(&1.key_path == [:scheduler, :delegation_hint_threshold]))

      assert schema.type == :pos_integer
      assert schema.validation == [min: 1]
    end

    test "is in scheduler category" do
      schema =
        Enum.find(Schema.all_schemas(), &(&1.key_path == [:scheduler, :delegation_hint_threshold]))

      assert schema.category == :scheduler
    end
  end

  # ── Child directory detection edge cases ─────────────────────────────────
  #
  # The delegation hinting feature counts write-tool calls per child directory
  # and emits a hint when the threshold is reached. The core path logic that
  # determines "is this path in a child node?" lives in
  # Shared.is_child_or_same_node?/2.

  describe "child directory detection for delegation hinting" do
    test "root node recognizes first-level child" do
      # Agent at root, child directory ./src
      assert Shared.is_child_or_same_node?("./", "./src") == true
    end

    test "root node recognizes nested child" do
      assert Shared.is_child_or_same_node?("./", "./src/utils/helpers.ex") == true
    end

    test "non-root node recognizes direct child" do
      assert Shared.is_child_or_same_node?("./src", "./src/utils") == true
    end

    test "non-root node recognizes nested descendant" do
      assert Shared.is_child_or_same_node?("./src", "./src/utils/helpers.ex") == true
    end

    test "sibling directory is NOT a child" do
      assert Shared.is_child_or_same_node?("./src", "./lib") == false
    end

    test "parent directory is NOT a child" do
      assert Shared.is_child_or_same_node?("./src/utils", "./src") == false
    end

    test "same directory is recognized as same node" do
      assert Shared.is_child_or_same_node?("./src", "./src") == true
    end

    test "child path with trailing slash is still a child" do
      assert Shared.is_child_or_same_node?("./src", "./src/utils/") == true
    end

    test "deeply nested non-root node recognizes its children" do
      assert Shared.is_child_or_same_node?("./apps/evo_git/lib", "./apps/evo_git/lib/evo_git") ==
               true
    end

    test "deeply nested non-root node rejects siblings at same depth" do
      assert Shared.is_child_or_same_node?("./apps/evo_git/lib", "./apps/evo_git/test") == false
    end

    test "partial prefix match does not false-positive" do
      # "./src" should NOT match "./src_backup" — they share a prefix but are siblings
      assert Shared.is_child_or_same_node?("./src", "./src_backup") == false
    end

    test "partial prefix match does not false-positive with similar names" do
      assert Shared.is_child_or_same_node?("./lib", "./lib_test") == false
    end
  end

  # ── Path normalization for delegation detection ──────────────────────────
  #
  # The hint logic normalizes extracted file paths before grouping them by
  # child directory. normalize_relpath/1 must produce consistent results so
  # that "./src", "src", and "src/" all map to the same key.

  describe "path normalization consistency for delegation detection" do
    test "various formats of the same path normalize identically" do
      paths = ["src", "./src", "src/", "./src/"]
      normalized = Enum.map(paths, &Shared.normalize_relpath/1)
      assert Enum.uniq(normalized) == ["./src"]
    end

    test "root path normalizes consistently" do
      assert Shared.normalize_relpath("./") == "./"
      assert Shared.normalize_relpath("") == "./"
      assert Shared.normalize_relpath(".") == "./"
    end

    test "multi-segment path normalizes consistently" do
      paths = ["apps/evo_git/lib", "./apps/evo_git/lib", "apps/evo_git/lib/"]
      normalized = Enum.map(paths, &Shared.normalize_relpath/1)
      assert Enum.uniq(normalized) == ["./apps/evo_git/lib"]
    end
  end

  # ── Absolute / out-of-repo paths must not crash hinting ───────────────────
  #
  # path_to_child_dir/3 (and file_path_to_child_dir/3, which delegates to it)
  # is the single chokepoint through which ALL write- and read-tool delegation
  # hinting flows. When an LLM passes an absolute path (e.g. "/tmp/foo"),
  # normalize_relpath/1 returns {:error, _} instead of a string. The hinting
  # code runs in the MAIN agent process (not the guarded tool-execution Task),
  # so a crash here would crash the entire agent. These tests verify the hinting
  # path returns [] (no hint) instead of raising.

  describe "absolute path resilience in path_to_child_dir/3" do
    @repo_path "/home/user/project"

    test "absolute dir path returns [] instead of raising (root node)" do
      assert [] = HintAgent.test_path_to_child_dir("/tmp/foo", "./", @repo_path)
    end

    test "absolute dir path returns [] instead of raising (non-root node)" do
      assert [] = HintAgent.test_path_to_child_dir("/tmp/foo", "./src", @repo_path)
    end

    test "absolute file path returns [] instead of raising (root node)" do
      assert [] = HintAgent.test_file_path_to_child_dir("/tmp/foo/bar.ex", "./", @repo_path)
    end

    test "absolute file path returns [] instead of raising (non-root node)" do
      assert [] = HintAgent.test_file_path_to_child_dir("/tmp/foo/bar.ex", "./src", @repo_path)
    end

    test "path outside repo returns [] instead of raising" do
      assert [] = HintAgent.test_path_to_child_dir("/etc/passwd", "./", @repo_path)
    end

    test "valid relative dir path still produces a hint target (regression)" do
      assert ["./src"] = HintAgent.test_path_to_child_dir("./src/components", "./", @repo_path)
    end

    test "valid relative file path still produces a hint target (regression)" do
      assert ["./src"] =
               HintAgent.test_file_path_to_child_dir("./src/components/button.tsx", "./", @repo_path)
    end

    test "valid relative path under non-root node still produces a hint target" do
      assert ["./src/components"] =
               HintAgent.test_path_to_child_dir("./src/components/widget.tsx", "./src", @repo_path)
    end
  end
end
