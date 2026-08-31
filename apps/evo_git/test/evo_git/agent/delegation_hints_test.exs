defmodule EvoGit.Agent.DelegationHintsTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.DelegationHints
  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.Config.Schema

  @repo_path "/home/user/project"

  # A minimal module that adopts the EvoGit.Agent behaviour so we can exercise
  # the private delegation-hinting path helpers directly. The behaviour injects
  # the private functions (path_to_child_dir/3, file_path_to_child_dir/3, etc.)
  # into this module; we re-export them through public test wrappers.
  defmodule HintAgent do
    use EvoGit.Agent

    def test_path_to_child_dir(dir_path, node_path, repo_path) do
      EvoGit.Agent.DelegationHints.path_to_child_dir(dir_path, node_path, repo_path)
    end

    def test_file_path_to_child_dir(file_path, node_path, repo_path) do
      EvoGit.Agent.DelegationHints.file_path_to_child_dir(file_path, node_path, repo_path)
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
        Enum.find(
          Schema.all_schemas(),
          &(&1.key_path == [:scheduler, :delegation_hint_threshold])
        )

      assert schema.type == :pos_integer
      assert schema.validation == [min: 1]
    end

    test "is in scheduler category" do
      schema =
        Enum.find(
          Schema.all_schemas(),
          &(&1.key_path == [:scheduler, :delegation_hint_threshold])
        )

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
               HintAgent.test_file_path_to_child_dir(
                 "./src/components/button.tsx",
                 "./",
                 @repo_path
               )
    end

    test "valid relative path under non-root node still produces a hint target" do
      assert ["./src/components"] =
               HintAgent.test_path_to_child_dir(
                 "./src/components/widget.tsx",
                 "./src",
                 @repo_path
               )
    end
  end

  # ── Own-node files must NOT produce delegation hints ──────────────────────
  #
  # path_to_child_dir/3 (and file_path_to_child_dir/3, which delegates to it)
  # must track only STRICT children of the agent's assigned node. Editing a
  # file that lives directly inside the agent's own node directory is normal
  # work, not delegation-worthy — and it must never render a malformed child
  # path like "./tests/backends/." (trailing "/.").

  describe "own-node files produce no delegation hint" do
    test "dir equal to own node returns [] (non-root)" do
      assert [] =
               HintAgent.test_path_to_child_dir(
                 "./tests/backends",
                 "./tests/backends",
                 @repo_path
               )
    end

    test "file directly inside own node returns [] (reported scenario)" do
      assert [] =
               HintAgent.test_file_path_to_child_dir(
                 "./tests/backends/test_iree_random_algorithms_parity.py",
                 "./tests/backends",
                 @repo_path
               )
    end

    test "extract_child_paths with write_file inside own node returns []" do
      args = %{"file_path" => "./tests/backends/foo.py"}

      assert [] =
               DelegationHints.extract_child_paths(
                 "write_file",
                 args,
                 "./tests/backends",
                 @repo_path
               )
    end

    test "extract_first_segment('./.') returns [] (no malformed root child)" do
      assert [] = DelegationHints.extract_first_segment("./.")
    end

    test "extract_first_segment_from_remainder('.', node) returns []" do
      assert [] = DelegationHints.extract_first_segment_from_remainder(".", "./tests/backends")
    end

    test "nested child under own node still produces a hint (regression)" do
      assert ["./tests/backends/sub"] =
               HintAgent.test_file_path_to_child_dir(
                 "./tests/backends/sub/foo.py",
                 "./tests/backends",
                 @repo_path
               )
    end
  end

  # ── extract_child_paths/4 — write-tool dispatcher ─────────────────────────
  #
  # extract_child_paths/4 is the public entry point: it dispatches to
  # do_extract_child_paths/4 only for write tools (write_file, edit_file) and
  # returns [] for everything else.

  describe "extract_child_paths/4 write-tool dispatcher" do
    test "non-write tool returns []" do
      assert [] = DelegationHints.extract_child_paths("run_bash", %{}, "./", @repo_path)
      assert [] = DelegationHints.extract_child_paths("read_file", %{}, "./", @repo_path)
      assert [] = DelegationHints.extract_child_paths("glob", %{}, "./", @repo_path)
    end

    test "write_file dispatches and extracts child dir" do
      args = %{"file_path" => "./src/utils/foo.ex"}

      assert ["./src"] = DelegationHints.extract_child_paths("write_file", args, "./", @repo_path)
    end

    test "edit_file dispatches and extracts child dir" do
      args = %{"file_path" => "./src/utils/foo.ex"}

      assert ["./src"] = DelegationHints.extract_child_paths("edit_file", args, "./", @repo_path)
    end

    test "write_file under non-root node extracts nested child" do
      args = %{"file_path" => "./src/components/button.tsx"}

      assert ["./src/components"] =
               DelegationHints.extract_child_paths("write_file", args, "./src", @repo_path)
    end
  end

  # ── do_extract_child_paths/4 — per-write-tool clause variants ─────────────

  describe "do_extract_child_paths/4 tool clauses" do
    test "create_files extracts only child paths under the node" do
      args = %{"paths" => ["./src/a.ex", "./lib/b.ex"]}

      # Only ./src/a.ex is under node ./src; ./lib/b.ex is a sibling and yields [].
      assert ["./src/a.ex"] =
               DelegationHints.do_extract_child_paths("create_files", args, "./src", @repo_path)
    end

    test "create_files at root node extracts first segment of each path" do
      args = %{"paths" => ["./src/a.ex", "./lib/b.ex"]}

      assert ["./src", "./lib"] =
               DelegationHints.do_extract_child_paths("create_files", args, "./", @repo_path)
    end

    test "make_dir extracts child dir" do
      args = %{"paths" => ["./src/components"]}

      assert ["./src"] =
               DelegationHints.do_extract_child_paths("make_dir", args, "./", @repo_path)
    end

    test "write_context extracts child dir" do
      args = %{"dir_path" => "./src/components"}

      assert ["./src"] =
               DelegationHints.do_extract_child_paths("write_context", args, "./", @repo_path)
    end

    test "edit_context extracts child dir" do
      args = %{"dir_path" => "./src/components"}

      assert ["./src"] =
               DelegationHints.do_extract_child_paths("edit_context", args, "./", @repo_path)
    end

    test "catch-all clause (write_file) extracts child dir from file_path" do
      args = %{"file_path" => "./src/utils/foo.ex"}

      assert ["./src"] =
               DelegationHints.do_extract_child_paths("write_file", args, "./", @repo_path)
    end

    test "missing args return []" do
      assert [] = DelegationHints.do_extract_child_paths("write_file", %{}, "./", @repo_path)
      assert [] = DelegationHints.do_extract_child_paths("create_files", %{}, "./", @repo_path)
      assert [] = DelegationHints.do_extract_child_paths("write_context", %{}, "./", @repo_path)
    end
  end

  # ── extract_first_segment/1 ───────────────────────────────────────────────

  describe "extract_first_segment/1" do
    test "single segment returns itself" do
      assert ["./src"] = DelegationHints.extract_first_segment("./src")
    end

    test "multi-segment path returns only first segment" do
      assert ["./src"] = DelegationHints.extract_first_segment("./src/utils")
    end

    test "root path returns []" do
      assert [] = DelegationHints.extract_first_segment("./")
    end

    test "empty string returns []" do
      assert [] = DelegationHints.extract_first_segment("")
    end

    test "different single segment" do
      assert ["./components"] = DelegationHints.extract_first_segment("./components/button")
    end
  end

  # ── extract_first_segment_from_remainder/2 ────────────────────────────────

  describe "extract_first_segment_from_remainder/2" do
    test "single segment appended to node path" do
      assert ["./src/utils"] =
               DelegationHints.extract_first_segment_from_remainder("utils", "./src")
    end

    test "multi-segment remainder returns only first segment" do
      assert ["./src/utils"] =
               DelegationHints.extract_first_segment_from_remainder("utils/helpers", "./src")
    end

    test "empty remainder returns []" do
      assert [] = DelegationHints.extract_first_segment_from_remainder("", "./src")
    end

    test "different node path" do
      assert ["./foo/bar"] =
               DelegationHints.extract_first_segment_from_remainder("bar", "./foo")
    end
  end

  # ── update_delegation_hints/2 ─────────────────────────────────────────────

  describe "update_delegation_hints/2" do
    test "empty hints + single path creates entry with count 1" do
      assert %{"./src" => %{count: 1, hint_shown: false}} =
               DelegationHints.update_delegation_hints(%{}, ["./src"])
    end

    test "existing entry increments count" do
      hints = %{"./src" => %{count: 1, hint_shown: false}}

      assert %{"./src" => %{count: 2, hint_shown: false}} =
               DelegationHints.update_delegation_hints(hints, ["./src"])
    end

    test "multiple paths each get an entry" do
      result = DelegationHints.update_delegation_hints(%{}, ["./src", "./lib"])

      assert %{"./src" => %{count: 1, hint_shown: false}} = result
      assert %{"./lib" => %{count: 1, hint_shown: false}} = result
    end

    test "empty child_paths list leaves hints unchanged" do
      hints = %{"./src" => %{count: 5, hint_shown: true}}

      assert ^hints = DelegationHints.update_delegation_hints(hints, [])
    end

    test "preserves hint_shown flag when incrementing" do
      hints = %{"./src" => %{count: 3, hint_shown: true}}

      assert %{"./src" => %{count: 4, hint_shown: true}} =
               DelegationHints.update_delegation_hints(hints, ["./src"])
    end
  end

  # ── filter_child_paths_if_conflicts/2 ─────────────────────────────────────

  describe "filter_child_paths_if_conflicts/2" do
    test "empty conflict list is a passthrough" do
      assert ["./src", "./lib"] =
               DelegationHints.filter_child_paths_if_conflicts(["./src", "./lib"], [])
    end

    test "non-empty conflict list suppresses all child paths" do
      assert [] =
               DelegationHints.filter_child_paths_if_conflicts(
                 ["./src", "./lib"],
                 ["conflict_file.txt"]
               )
    end

    test "empty child paths with conflicts still returns []" do
      assert [] = DelegationHints.filter_child_paths_if_conflicts([], ["conflict_file.txt"])
    end

    test "empty child paths with empty conflicts returns []" do
      assert [] = DelegationHints.filter_child_paths_if_conflicts([], [])
    end
  end

  # ── maybe_append_delegation_hint/4 — once-only threshold behavior ─────────

  describe "maybe_append_delegation_hint/4" do
    test "below threshold: count incremented, no hint appended" do
      # threshold 2: count becomes 1 (< 2), no hint
      {output, hints} = DelegationHints.maybe_append_delegation_hint("output", %{}, ["./src"], 2)

      assert output == "output"
      assert %{"./src" => %{count: 1, hint_shown: false}} = hints
    end

    test "at threshold first time: hint appended and marked shown" do
      # threshold 1: count becomes 1 (>= 1), hint appended
      {output, hints} = DelegationHints.maybe_append_delegation_hint("output", %{}, ["./src"], 1)

      assert String.contains?(output, "Delegation Hint")
      assert %{"./src" => %{count: 1, hint_shown: true}} = hints
    end

    test "already shown: count increments but no second hint" do
      hints0 = %{"./src" => %{count: 1, hint_shown: true}}

      {output, hints} =
        DelegationHints.maybe_append_delegation_hint("output", hints0, ["./src"], 1)

      # count incremented to 2, but no hint appended (once-only)
      assert output == "output"
      assert %{"./src" => %{count: 2, hint_shown: true}} = hints
    end

    test "hint message contains the child path and threshold number" do
      {output, _hints} = DelegationHints.maybe_append_delegation_hint("output", %{}, ["./src"], 1)

      assert String.contains?(output, "Delegation Hint")
      assert String.contains?(output, "./src")
      assert String.contains?(output, "1")
    end

    test "empty child_paths list: output unchanged, hints unchanged" do
      {output, hints} = DelegationHints.maybe_append_delegation_hint("output", %{}, [], 1)

      assert output == "output"
      assert hints == %{}
    end

    test "multiple paths at threshold each emit a hint" do
      {output, hints} =
        DelegationHints.maybe_append_delegation_hint("output", %{}, ["./src", "./lib"], 1)

      assert String.contains?(output, "./src")
      assert String.contains?(output, "./lib")
      assert %{"./src" => %{count: 1, hint_shown: true}} = hints
      assert %{"./lib" => %{count: 1, hint_shown: true}} = hints
    end
  end

  # ── entry_count/2 ─────────────────────────────────────────────────────────

  describe "entry_count/2" do
    test "returns count for existing path" do
      hints = %{"./src" => %{count: 3, hint_shown: false}}
      assert 3 = DelegationHints.entry_count(hints, "./src")
    end

    test "returns 0 for missing path" do
      assert 0 = DelegationHints.entry_count(%{}, "./src")
    end

    test "returns 0 when count is 0" do
      hints = %{"./src" => %{count: 0, hint_shown: false}}
      assert 0 = DelegationHints.entry_count(hints, "./src")
    end
  end

  # ── Read-tool extraction: extract_read_child_paths/4 ──────────────────────

  describe "extract_read_child_paths/4 read-tool dispatcher" do
    test "non-read tool returns []" do
      args = %{"file_path" => "./src/foo.ex"}

      assert [] = DelegationHints.extract_read_child_paths("write_file", args, "./", @repo_path)
      assert [] = DelegationHints.extract_read_child_paths("edit_file", args, "./", @repo_path)
      assert [] = DelegationHints.extract_read_child_paths("run_bash", %{}, "./", @repo_path)
    end

    test "read_file dispatches and extracts child dir" do
      args = %{"file_path" => "./src/utils/foo.ex"}

      assert ["./src"] =
               DelegationHints.extract_read_child_paths("read_file", args, "./", @repo_path)
    end

    test "list_dir dispatches and extracts child dir" do
      args = %{"dir_path" => "./src/components"}

      assert ["./src"] =
               DelegationHints.extract_read_child_paths("list_dir", args, "./", @repo_path)
    end

    test "rg dispatches and extracts child dir" do
      args = %{"path" => "./src/components"}

      assert ["./src"] =
               DelegationHints.extract_read_child_paths("rg", args, "./", @repo_path)
    end

    test "glob dispatches and extracts child dir" do
      args = %{"path" => "./src/components"}

      assert ["./src"] =
               DelegationHints.extract_read_child_paths("glob", args, "./", @repo_path)
    end
  end

  # ── do_extract_read_child_paths tool clauses ──────────────────────────────

  describe "do_extract_read_child_paths tool clauses" do
    test "read_file extracts child dir from file_path" do
      args = %{"file_path" => "./src/utils/foo.ex"}

      assert ["./src"] =
               DelegationHints.do_extract_read_child_paths("read_file", args, "./", @repo_path)
    end

    test "list_dir extracts child dir from dir_path" do
      args = %{"dir_path" => "./src/components"}

      assert ["./src"] =
               DelegationHints.do_extract_read_child_paths("list_dir", args, "./", @repo_path)
    end

    test "rg extracts child dir from path" do
      args = %{"path" => "./src/components"}

      assert ["./src"] =
               DelegationHints.do_extract_read_child_paths("rg", args, "./", @repo_path)
    end

    test "glob extracts child dir from path" do
      args = %{"path" => "./src/components"}

      assert ["./src"] =
               DelegationHints.do_extract_read_child_paths("glob", args, "./", @repo_path)
    end

    test "missing args return []" do
      assert [] = DelegationHints.do_extract_read_child_paths("read_file", %{}, "./", @repo_path)
      assert [] = DelegationHints.do_extract_read_child_paths("list_dir", %{}, "./", @repo_path)
      assert [] = DelegationHints.do_extract_read_child_paths("rg", %{}, "./", @repo_path)
      assert [] = DelegationHints.do_extract_read_child_paths("glob", %{}, "./", @repo_path)
    end

    test "read_file under non-root node extracts nested child" do
      args = %{"file_path" => "./src/components/button.tsx"}

      assert ["./src/components"] =
               DelegationHints.do_extract_read_child_paths("read_file", args, "./src", @repo_path)
    end
  end

  # ── update_read_delegation_hints/2 ────────────────────────────────────────

  describe "update_read_delegation_hints/2" do
    test "empty hints + single path creates entry with count 1" do
      assert %{"./src" => %{count: 1, hint_shown: false}} =
               DelegationHints.update_read_delegation_hints(%{}, ["./src"])
    end

    test "existing entry increments count" do
      hints = %{"./src" => %{count: 2, hint_shown: false}}

      assert %{"./src" => %{count: 3, hint_shown: false}} =
               DelegationHints.update_read_delegation_hints(hints, ["./src"])
    end

    test "multiple paths each get an entry" do
      result = DelegationHints.update_read_delegation_hints(%{}, ["./src", "./lib"])

      assert %{"./src" => %{count: 1, hint_shown: false}} = result
      assert %{"./lib" => %{count: 1, hint_shown: false}} = result
    end

    test "empty child_paths list leaves hints unchanged" do
      hints = %{"./src" => %{count: 4, hint_shown: true}}

      assert ^hints = DelegationHints.update_read_delegation_hints(hints, [])
    end
  end

  # ── maybe_append_read_delegation_hint/5 — delegation_level gate ───────────

  describe "maybe_append_read_delegation_hint/5" do
    test ":high level crosses threshold: appends read delegation hint" do
      {output, hints} =
        DelegationHints.maybe_append_read_delegation_hint("output", %{}, ["./src"], 1, :high)

      # Message references subagent_investigator / investigation.
      assert String.contains?(output, "investigat")
      assert String.contains?(output, "subagent_investigator")
      assert String.contains?(output, "./src")
      assert %{"./src" => %{count: 1, hint_shown: true}} = hints
    end

    test ":low level crosses threshold: does NOT append (gated)" do
      {output, hints} =
        DelegationHints.maybe_append_read_delegation_hint("output", %{}, ["./src"], 1, :low)

      assert output == "output"
      assert hints == %{}
    end

    test ":high level once-only: hint already shown yields no second hint" do
      hints0 = %{"./src" => %{count: 1, hint_shown: true}}

      {output, hints} =
        DelegationHints.maybe_append_read_delegation_hint("output", hints0, ["./src"], 1, :high)

      assert output == "output"
      assert %{"./src" => %{count: 2, hint_shown: true}} = hints
    end

    test ":high level below threshold: count incremented, no hint" do
      {output, hints} =
        DelegationHints.maybe_append_read_delegation_hint("output", %{}, ["./src"], 5, :high)

      assert output == "output"
      assert %{"./src" => %{count: 1, hint_shown: false}} = hints
    end

    test "hint message contains child path and count" do
      {output, _hints} =
        DelegationHints.maybe_append_read_delegation_hint("output", %{}, ["./src"], 1, :high)

      assert String.contains?(output, "Delegation Hint")
      assert String.contains?(output, "./src")
      # read hint message embeds the count (1)
      assert String.contains?(output, "1 turns")
    end
  end

  # ── Config accessors ──────────────────────────────────────────────────────
  #
  # These read from EvoGit.Config.resolve/1 and must return positive integers
  # (the schema declares them :pos_integer with validation [min: 1]).

  describe "config accessors" do
    test "delegation_hint_threshold/0 returns a positive integer" do
      value = DelegationHints.delegation_hint_threshold()
      assert is_integer(value)
      assert value > 0
    end

    test "read_delegation_hint_threshold/0 returns a positive integer" do
      value = DelegationHints.read_delegation_hint_threshold()
      assert is_integer(value)
      assert value > 0
    end

    test "max_tool_timeout/0 returns a positive integer" do
      value = DelegationHints.max_tool_timeout()
      assert is_integer(value)
      assert value > 0
    end

    test "default_tool_timeout/0 returns a positive integer" do
      value = DelegationHints.default_tool_timeout()
      assert is_integer(value)
      assert value > 0
    end

    test "max_tool_timeout is greater than default_tool_timeout" do
      assert DelegationHints.max_tool_timeout() > DelegationHints.default_tool_timeout()
    end
  end
end
