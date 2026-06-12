defmodule EvoGit.Agent.DelegationHintsTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.Config.Schema

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
end
