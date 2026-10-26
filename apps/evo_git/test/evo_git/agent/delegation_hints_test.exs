defmodule EvoGit.Agent.DelegationHintsTest do
  @moduledoc """
  `async: true` — pure `EvoGit.Agent.DelegationHints` path/hint helpers plus a
  read-only delegation-hint config accessor suite (no config mutation); no
  shared/global state is touched.
  """

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
    test "is registered in the scheduler category as a positive integer defaulting to 5" do
      schema =
        Enum.find(
          Schema.all_schemas(),
          &(&1.key_path == [:scheduler, :delegation_hint_threshold])
        )

      assert schema, "expected [:scheduler, :delegation_hint_threshold] in all_schemas/0"
      assert schema.type == :pos_integer
      assert schema.validation == [min: 1]
      assert schema.category == :scheduler
      assert Schema.defaults().scheduler.delegation_hint_threshold == 5
    end
  end

  # ── Child directory detection edge cases ─────────────────────────────────
  #
  # The delegation hinting feature counts write-tool calls per child directory
  # and emits a hint when the threshold is reached. The core path logic that
  # determines "is this path in a child node?" lives in
  # Shared.is_child_or_same_node?/2. The base cases are also pinned in
  # `tools/shared_test.exs`; the prefix look-alikes below are this suite's own.

  describe "child directory detection for delegation hinting" do
    test "classifies child / same / sibling / parent nodes, including prefix look-alikes" do
      cases = [
        # Agent at root, child directory ./src
        {"./", "./src", true},
        # Root node recognizes a nested child (deepest path wins)
        {"./", "./src/utils/helpers.ex", true},
        # Non-root node recognizes direct child + nested descendant
        {"./src", "./src/utils", true},
        {"./src", "./src/utils/helpers.ex", true},
        # Sibling directory is NOT a child
        {"./src", "./lib", false},
        # Parent directory is NOT a child
        {"./src/utils", "./src", false},
        # Same directory is recognized as same node
        {"./src", "./src", true},
        # Trailing slash is still a child
        {"./src", "./src/utils/", true},
        # Deeply nested node recognizes its children ...
        {"./apps/evo_git/lib", "./apps/evo_git/lib/evo_git", true},
        # ... and rejects siblings at the same depth
        {"./apps/evo_git/lib", "./apps/evo_git/test", false},
        # Partial prefix match does not false-positive: "./src" must NOT match
        # "./src_backup" — they share a prefix but are siblings.
        {"./src", "./src_backup", false},
        {"./lib", "./lib_test", false}
      ]

      for {node, path, expected} <- cases do
        assert Shared.is_child_or_same_node?(node, path) == expected,
               "expected is_child_or_same_node?(#{inspect(node)}, #{inspect(path)}) to be #{expected}"
      end
    end
  end

  # ── Absolute / out-of-repo paths must not crash hinting ───────────────────
  #
  # path_to_child_dir/3 (and file_path_to_child_dir/3, which delegates to it)
  # is the single chokepoint through which ALL write- and read-tool delegation
  # hinting flows. When an LLM passes an absolute path (e.g. "/tmp/foo"),
  # normalize_relpath/1 returns {:error, _} instead of a string. The hinting
  # code runs in the MAIN agent process (not the guarded tool-execution Task),
  # so a crash here would crash the entire agent. These cases verify the hinting
  # path returns [] (no hint) instead of raising.

  describe "absolute path resilience in path_to_child_dir/3" do
    @repo_path "/home/user/project"

    test "absolute / out-of-repo paths return [] while relative paths still hint" do
      for {path, node} <- [{"/tmp/foo", "./"}, {"/tmp/foo", "./src"}, {"/etc/passwd", "./"}] do
        assert [] = HintAgent.test_path_to_child_dir(path, node, @repo_path),
               "expected no hint for dir path #{inspect(path)} under node #{inspect(node)}"
      end

      for {path, node} <- [{"/tmp/foo/bar.ex", "./"}, {"/tmp/foo/bar.ex", "./src"}] do
        assert [] = HintAgent.test_file_path_to_child_dir(path, node, @repo_path),
               "expected no hint for file path #{inspect(path)} under node #{inspect(node)}"
      end

      # Regression: a valid relative dir/file path still produces a hint target.
      assert ["./src"] = HintAgent.test_path_to_child_dir("./src/components", "./", @repo_path)

      assert ["./src"] =
               HintAgent.test_file_path_to_child_dir(
                 "./src/components/button.tsx",
                 "./",
                 @repo_path
               )

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
    test "own-node dirs/files yield [] while a nested child still yields a hint" do
      # dir equal to own node
      assert [] =
               HintAgent.test_path_to_child_dir(
                 "./tests/backends",
                 "./tests/backends",
                 @repo_path
               )

      # file directly inside own node (reported scenario)
      assert [] =
               HintAgent.test_file_path_to_child_dir(
                 "./tests/backends/test_iree_random_algorithms_parity.py",
                 "./tests/backends",
                 @repo_path
               )

      # same thing through the write-tool entry point
      assert [] =
               DelegationHints.extract_child_paths(
                 "write_file",
                 %{"file_path" => "./tests/backends/foo.py"},
                 "./tests/backends",
                 @repo_path
               )

      # no malformed root child ("/.") is ever rendered
      assert [] = DelegationHints.extract_first_segment("./.")
      assert [] = DelegationHints.extract_first_segment_from_remainder(".", "./tests/backends")

      # Regression: a nested child under the own node still produces a hint.
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
  # do_extract_child_paths/4 only for write tools and returns [] for everything
  # else. The dispatcher passes the RAW tool-call name — the model-facing schema
  # name (`write`, `edit`, …), not the internal dispatch key — so the entry
  # points normalise through `EvoGit.Agent.ToolNames.normalize/1` before the
  # membership test. Without that, no delegation nudge ever fires.

  describe "extract_child_paths/4 write-tool dispatcher" do
    test "extracts a child dir for write/edit under every accepted spelling" do
      args = %{"file_path" => "./src/utils/foo.ex"}

      # model-facing names, case-insensitively
      assert ["./src"] = DelegationHints.extract_child_paths("write", args, "./", @repo_path)
      assert ["./src"] = DelegationHints.extract_child_paths("edit", args, "./", @repo_path)
      assert ["./src"] = DelegationHints.extract_child_paths("WRITE", args, "./", @repo_path)
      assert ["./src"] = DelegationHints.extract_child_paths("Edit", args, "./", @repo_path)

      # legacy internal-key spellings keep working (regression)
      assert ["./src"] = DelegationHints.extract_child_paths("write_file", args, "./", @repo_path)
      assert ["./src"] = DelegationHints.extract_child_paths("edit_file", args, "./", @repo_path)
    end

    test "extracts the nested child under a non-root node" do
      args = %{"file_path" => "./src/components/button.tsx"}

      assert ["./src/components"] =
               DelegationHints.extract_child_paths("write_file", args, "./src", @repo_path)

      assert ["./src/components"] =
               DelegationHints.extract_child_paths("write", args, "./src", @repo_path)
    end

    test "non-write tools return [] under every spelling" do
      args = %{"file_path" => "./src/foo.ex"}

      # internal dispatch keys
      assert [] = DelegationHints.extract_child_paths("run_bash", %{}, "./", @repo_path)
      assert [] = DelegationHints.extract_child_paths("read_file", %{}, "./", @repo_path)
      assert [] = DelegationHints.extract_child_paths("glob", %{}, "./", @repo_path)

      # model-facing names + a non-tool name
      assert [] = DelegationHints.extract_child_paths("read", args, "./", @repo_path)
      assert [] = DelegationHints.extract_child_paths("bash", args, "./", @repo_path)
      assert [] = DelegationHints.extract_child_paths(nil, args, "./", @repo_path)
    end
  end

  # ── do_extract_child_paths/4 — per-write-tool clause variants ─────────────

  describe "do_extract_child_paths/4 tool clauses" do
    test "each write-tool clause extracts its child target; missing args yield []" do
      # create_files only tracks paths under the node; ./lib/b.ex is a sibling.
      assert ["./src/a.ex"] =
               DelegationHints.do_extract_child_paths(
                 "create_files",
                 %{"paths" => ["./src/a.ex", "./lib/b.ex"]},
                 "./src",
                 @repo_path
               )

      # ... and at the root node it takes the first segment of each path.
      assert ["./src", "./lib"] =
               DelegationHints.do_extract_child_paths(
                 "create_files",
                 %{"paths" => ["./src/a.ex", "./lib/b.ex"]},
                 "./",
                 @repo_path
               )

      for {tool, args} <- [
            {"make_dir", %{"paths" => ["./src/components"]}},
            {"write_context", %{"dir_path" => "./src/components"}},
            {"edit_context", %{"dir_path" => "./src/components"}},
            # catch-all clause reads file_path
            {"write_file", %{"file_path" => "./src/utils/foo.ex"}}
          ] do
        assert ["./src"] =
                 DelegationHints.do_extract_child_paths(tool, args, "./", @repo_path),
               "expected #{inspect(tool)} to extract ./src"
      end

      for tool <- ["write_file", "create_files", "write_context"] do
        assert [] = DelegationHints.do_extract_child_paths(tool, %{}, "./", @repo_path),
               "expected missing args for #{inspect(tool)} to yield no child path"
      end
    end
  end

  # ── extract_first_segment/1 ───────────────────────────────────────────────

  describe "extract_first_segment/1" do
    test "returns the first segment, or [] for a root/empty path" do
      assert ["./src"] = DelegationHints.extract_first_segment("./src")
      assert ["./src"] = DelegationHints.extract_first_segment("./src/utils")
      assert ["./components"] = DelegationHints.extract_first_segment("./components/button")
      assert [] = DelegationHints.extract_first_segment("./")
      assert [] = DelegationHints.extract_first_segment("")
    end
  end

  # ── extract_first_segment_from_remainder/2 ────────────────────────────────

  describe "extract_first_segment_from_remainder/2" do
    test "appends only the first remainder segment to the node path" do
      assert ["./src/utils"] =
               DelegationHints.extract_first_segment_from_remainder("utils", "./src")

      assert ["./src/utils"] =
               DelegationHints.extract_first_segment_from_remainder("utils/helpers", "./src")

      assert ["./foo/bar"] =
               DelegationHints.extract_first_segment_from_remainder("bar", "./foo")

      assert [] = DelegationHints.extract_first_segment_from_remainder("", "./src")
    end
  end

  # ── update_delegation_hints/2 + update_read_delegation_hints/2 ───────────
  #
  # Both entry points are the SAME counter (`update_hints/3` with `:count`), so
  # one table drives both names.

  describe "update_delegation_hints/2 and update_read_delegation_hints/2" do
    test "create, increment, multi-path, and empty-path semantics are identical" do
      for update <- [
            &DelegationHints.update_delegation_hints/2,
            &DelegationHints.update_read_delegation_hints/2
          ] do
        # empty hints + single path creates an entry with count 1
        assert %{"./src" => %{count: 1, hint_shown: false}} = update.(%{}, ["./src"])

        # an existing entry increments its count
        hints = %{"./src" => %{count: 1, hint_shown: false}}
        assert %{"./src" => %{count: 2, hint_shown: false}} = update.(hints, ["./src"])

        # the hint_shown flag is preserved when incrementing
        shown = %{"./src" => %{count: 3, hint_shown: true}}
        assert %{"./src" => %{count: 4, hint_shown: true}} = update.(shown, ["./src"])

        # multiple paths each get an entry
        result = update.(%{}, ["./src", "./lib"])
        assert %{"./src" => %{count: 1, hint_shown: false}} = result
        assert %{"./lib" => %{count: 1, hint_shown: false}} = result

        # an empty child_paths list leaves the hints map untouched
        unchanged = %{"./src" => %{count: 5, hint_shown: true}}
        assert ^unchanged = update.(unchanged, [])
      end
    end
  end

  # ── filter_child_paths_if_conflicts/2 ─────────────────────────────────────

  describe "filter_child_paths_if_conflicts/2" do
    test "passes paths through only while no conflict files are present" do
      # Merge conflict in progress: the agent must edit directly, so every
      # nudge is suppressed.
      assert ["./src", "./lib"] =
               DelegationHints.filter_child_paths_if_conflicts(["./src", "./lib"], [])

      assert [] =
               DelegationHints.filter_child_paths_if_conflicts(
                 ["./src", "./lib"],
                 ["conflict_file.txt"]
               )

      assert [] = DelegationHints.filter_child_paths_if_conflicts([], ["conflict_file.txt"])
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
      assert String.contains?(output, "./src")
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
    test "returns the stored count, or 0 for a missing/zero entry" do
      assert 3 =
               DelegationHints.entry_count(%{"./src" => %{count: 3, hint_shown: false}}, "./src")

      assert 0 = DelegationHints.entry_count(%{}, "./src")

      assert 0 =
               DelegationHints.entry_count(%{"./src" => %{count: 0, hint_shown: false}}, "./src")
    end
  end

  # ── Read-tool extraction: extract_read_child_paths/4 ──────────────────────
  #
  # Same dispatcher contract as the write side: RAW tool-call name (model-facing
  # `read` or the internal `read_file`), normalised before the membership test.

  describe "extract_read_child_paths/4" do
    test "each read-tool clause extracts its child target from its own arg key" do
      for {tool, args} <- [
            {"read_file", %{"file_path" => "./src/utils/foo.ex"}},
            {"list_dir", %{"dir_path" => "./src/components"}},
            {"rg", %{"path" => "./src/components"}},
            {"glob", %{"path" => "./src/components"}}
          ] do
        # the public dispatcher ...
        assert ["./src"] = DelegationHints.extract_read_child_paths(tool, args, "./", @repo_path),
               "expected #{inspect(tool)} to extract ./src"

        # ... and the clause it dispatches to
        assert ["./src"] =
                 DelegationHints.do_extract_read_child_paths(tool, args, "./", @repo_path),
               "expected the #{inspect(tool)} clause to extract ./src"
      end

      assert ["./src/components"] =
               DelegationHints.do_extract_read_child_paths(
                 "read_file",
                 %{"file_path" => "./src/components/button.tsx"},
                 "./src",
                 @repo_path
               )
    end

    test "model-facing / case-variant / legacy spellings all reach the same clause" do
      args = %{"file_path" => "./src/utils/foo.ex"}

      assert ["./src"] = DelegationHints.extract_read_child_paths("read", args, "./", @repo_path)
      assert ["./src"] = DelegationHints.extract_read_child_paths("READ", args, "./", @repo_path)

      assert ["./src"] =
               DelegationHints.extract_read_child_paths("read_file", args, "./", @repo_path)

      assert ["./src/components"] =
               DelegationHints.extract_read_child_paths(
                 "read",
                 %{"file_path" => "./src/components/button.tsx"},
                 "./src",
                 @repo_path
               )
    end

    test "non-read tools return [] under every spelling" do
      args = %{"file_path" => "./src/foo.ex"}

      # internal dispatch keys
      assert [] = DelegationHints.extract_read_child_paths("write_file", args, "./", @repo_path)
      assert [] = DelegationHints.extract_read_child_paths("edit_file", args, "./", @repo_path)
      assert [] = DelegationHints.extract_read_child_paths("run_bash", %{}, "./", @repo_path)

      # model-facing names + a non-tool name
      assert [] = DelegationHints.extract_read_child_paths("write", args, "./", @repo_path)
      assert [] = DelegationHints.extract_read_child_paths("bash", args, "./", @repo_path)
      assert [] = DelegationHints.extract_read_child_paths(nil, args, "./", @repo_path)
    end

    test "missing args return [] for every read-tool clause" do
      for tool <- ["read_file", "list_dir", "rg", "glob"] do
        assert [] = DelegationHints.do_extract_read_child_paths(tool, %{}, "./", @repo_path),
               "expected missing args for #{inspect(tool)} to yield no child path"
      end
    end
  end

  # ── maybe_append_read_delegation_hint/5 — delegation_level gate ───────────

  describe "maybe_append_read_delegation_hint/5" do
    test ":high level crosses threshold: appends read delegation hint" do
      {output, hints} =
        DelegationHints.maybe_append_read_delegation_hint("output", %{}, ["./src"], 1, :high)

      # Message references subagent_investigator / investigation and embeds the
      # count that triggered it.
      assert String.contains?(output, "investigat")
      assert String.contains?(output, "subagent_investigator")
      assert String.contains?(output, "./src")
      assert String.contains?(output, "1 turns")
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
  end

  # ── maybe_append_read_delegation_hint/6 — role-aware subagent names ────────
  #
  # The nudge must name only the subagent tools the RECEIVING role can actually
  # spawn (resolved from its `subagent_modules/0`), never a tool it does not have.

  describe "maybe_append_read_delegation_hint/6 — role-aware subagent names" do
    test "GenesisPlanner (investigator-only subagents) never names subagent_manager" do
      # EvoGit.Agents.GenesisPlanner is `delegation_level :high` but its
      # `subagent_modules/0` lists the Investigator only — nudging it toward
      # `subagent_manager` pointed at a tool it cannot call.
      assert EvoGit.Agents.GenesisPlanner.subagent_modules() == [EvoGit.Agents.Investigator]

      {output, hints} =
        DelegationHints.maybe_append_read_delegation_hint(
          "output",
          %{},
          ["./src"],
          1,
          :high,
          EvoGit.Agents.GenesisPlanner
        )

      assert output =~ "Delegation Hint"
      assert output =~ "subagent_investigator"
      refute output =~ "subagent_manager"
      assert %{"./src" => %{count: 1, hint_shown: true}} = hints
    end

    test "a role that has the Manager still gets the subagent_manager mention" do
      assert EvoGit.Agents.Manager in EvoGit.Agents.Manager.subagent_modules()

      {output, _hints} =
        DelegationHints.maybe_append_read_delegation_hint(
          "output",
          %{},
          ["./src"],
          1,
          :high,
          EvoGit.Agents.Manager
        )

      # Historical wording preserved when both tools are available.
      assert output =~ "subagent_investigator"
      assert output =~ "(or `subagent_manager`)"
      assert output =~ "./src"
    end

    test "an unknown or subagent-less role produces no hint (total, no raise)" do
      # `nil` = role unknown (direct/unit-test callers): keep the historical
      # both-names wording.
      {nil_output, _hints} =
        DelegationHints.maybe_append_read_delegation_hint("output", %{}, ["./src"], 1, :high, nil)

      assert nil_output =~ "subagent_investigator"
      assert nil_output =~ "subagent_manager"

      # Every role that resolves to NO suggestable tool yields the output
      # unchanged and the counters untouched — whatever its `subagent_modules/0`
      # looks like (empty, entries without `subagent_tool_name/0`, or no callback
      # at all).
      assert EvoGit.Agents.SelfReflective.subagent_modules() == []
      assert HintAgent.subagent_modules() == []

      for role <- [EvoGit.Agents.SelfReflective, RoleWithUntitledSubagents, String, HintAgent] do
        assert {"output", %{}} =
                 DelegationHints.maybe_append_read_delegation_hint(
                   "output",
                   %{},
                   ["./src"],
                   1,
                   :high,
                   role
                 ),
               "expected no hint for role #{inspect(role)}"
      end
    end
  end

  # ── Config accessors ──────────────────────────────────────────────────────
  #
  # These read from EvoGit.Config.resolve/1 and must return positive integers
  # (the schema declares them :pos_integer with validation [min: 1]).

  describe "config accessors" do
    test "every accessor returns a positive integer" do
      accessors = [
        {:delegation_hint_threshold, &DelegationHints.delegation_hint_threshold/0},
        {:read_delegation_hint_threshold, &DelegationHints.read_delegation_hint_threshold/0},
        {:max_tool_timeout, &DelegationHints.max_tool_timeout/0},
        {:default_tool_timeout, &DelegationHints.default_tool_timeout/0}
      ]

      for {name, fun} <- accessors do
        value = fun.()
        assert is_integer(value), "expected #{name} to be an integer, got: #{inspect(value)}"
        assert value > 0, "expected #{name} to be positive, got: #{inspect(value)}"
      end
    end

    test "max_tool_timeout is greater than default_tool_timeout" do
      assert DelegationHints.max_tool_timeout() > DelegationHints.default_tool_timeout()
    end
  end
end

# A role whose `subagent_modules/0` lists entries that do NOT export
# `subagent_tool_name/0` (plus a nil and a non-module atom) — pins the hint's
# TOTAL role-name resolution: every entry contributes nothing instead of raising.
defmodule EvoGit.Agent.DelegationHintsTest.RoleWithUntitledSubagents do
  def subagent_modules, do: [String, nil, :not_a_module]
end
