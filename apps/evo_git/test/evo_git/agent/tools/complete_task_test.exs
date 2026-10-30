defmodule EvoGit.Agent.Tools.CompleteTaskTest do
  @moduledoc """
  `async: true` — the `complete/5` + archive tests seed ONE row per agent in the
  shared, app-owned named ETS tables (`:evogit_sched_meta` /
  `:evogit_agent_state`) under a per-test UNIQUE agent id (deleted on exit, and
  nothing here asserts anything about the tables as a whole), so the writes are
  concurrent-safe.

  Every test additionally gets its OWN isolated `EvoGit.Store` +
  `EvoGit.TaskRegistry` pair (`EvoGit.TaskRegistryCase`), so the archive
  assertions read the REAL producer's writes out of a real dynamic store
  without touching the app-global one.

  Repository fixtures come from ONE per-module git TEMPLATE SET built in
  `setup_all` (a repo with no commits, one with a single commit and one with
  two) and copied per test with `File.cp_r!` — a copy costs ~2 ms, where the
  previous per-test `git init` + two `git config` + commit chain cost ~25-40 ms
  of `git` subprocesses. Every assertion is unchanged.
  """

  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Tools.CompleteTask

  setup_all do
    {:ok, repos: git_templates!()}
  end

  describe "schema/0" do
    test "returns a valid tool schema with correct name and description" do
      schema = CompleteTask.schema()

      assert schema.name == "complete_task"
      assert is_binary(schema.description)
      assert schema.description =~ "report your findings"
    end

    test "schema has result as required parameter" do
      schema = CompleteTask.schema()
      props = schema.parameter_schema["properties"]
      required = schema.parameter_schema["required"]

      assert "result" in Map.keys(props)
      assert "check_git_status" in Map.keys(props)
      assert "result" in required
      # check_git_status default is in the description, not necessarily in the JSON schema
      assert Map.has_key?(props, "check_git_status")
    end
  end

  describe "check_workspace_dirty/1" do
    # The template provides the repo shape each test previously built by hand:
    # by default a repository with one commit that already tracks `test.txt`
    # (tag `template: :empty` for the no-commit case).
    setup %{repos: repos} = context do
      {:ok, %{tmp_dir: copy_repo!(repos, Map.get(context, :template, :one))}}
    end

    test "returns clean when workspace has no changes", %{tmp_dir: tmp_dir} do
      # The template's one commit left the worktree clean.
      assert {:clean, nil} = CompleteTask.check_workspace_dirty(tmp_dir)
    end

    test "returns dirty when workspace has uncommitted modifications", %{tmp_dir: tmp_dir} do
      # Modify the already-committed file without committing.
      File.write!(Path.join(tmp_dir, "test.txt"), "modified content")

      assert {:dirty, warning_msg} = CompleteTask.check_workspace_dirty(tmp_dir)
      assert warning_msg =~ "uncommitted changes"
      assert warning_msg =~ "test.txt"
    end

    test "returns dirty when workspace has untracked files", %{tmp_dir: tmp_dir} do
      # Create an untracked file
      File.write!(Path.join(tmp_dir, "untracked.txt"), "new file")

      assert {:dirty, warning_msg} = CompleteTask.check_workspace_dirty(tmp_dir)
      assert warning_msg =~ "uncommitted changes"
      assert warning_msg =~ "untracked"
      assert warning_msg =~ "untracked.txt"
    end

    test "returns dirty when workspace has staged changes", %{tmp_dir: tmp_dir} do
      # Stage a new file
      File.write!(Path.join(tmp_dir, "staged.txt"), "staged content")
      {:ok, _} = Git.add(tmp_dir, "staged.txt")

      assert {:dirty, warning_msg} = CompleteTask.check_workspace_dirty(tmp_dir)
      assert warning_msg =~ "uncommitted changes"
      assert warning_msg =~ "staged.txt"
    end

    @tag template: :empty
    test "returns clean for an empty repo with no commits", %{tmp_dir: tmp_dir} do
      # A freshly initialized repo with nothing staged should be clean
      assert {:clean, nil} = CompleteTask.check_workspace_dirty(tmp_dir)
    end
  end

  describe "format_git_status_porcelain/1" do
    test "formats modified files" do
      output = CompleteTask.format_git_status_porcelain(" M lib/foo.ex")
      assert output =~ "modified  lib/foo.ex"
    end

    test "formats staged files" do
      output = CompleteTask.format_git_status_porcelain("M  lib/bar.ex")
      assert output =~ "staged  lib/bar.ex"
    end

    test "formats staged and modified files" do
      output = CompleteTask.format_git_status_porcelain("MM lib/baz.ex")
      assert output =~ "staged, modified  lib/baz.ex"
    end

    test "formats staged new files" do
      output = CompleteTask.format_git_status_porcelain("A  new_file.ex")
      assert output =~ "staged (new)  new_file.ex"
    end

    test "formats deleted files" do
      output = CompleteTask.format_git_status_porcelain(" D deleted_file.ex")
      assert output =~ "deleted  deleted_file.ex"
    end

    test "formats staged deleted files" do
      output = CompleteTask.format_git_status_porcelain("D  staged_del.ex")
      assert output =~ "staged (deleted)  staged_del.ex"
    end

    test "formats staged and deleted files" do
      output = CompleteTask.format_git_status_porcelain("DD both_del.ex")
      assert output =~ "staged, deleted  both_del.ex"
    end

    test "formats staged renamed files" do
      output = CompleteTask.format_git_status_porcelain("R  renamed.ex")
      assert output =~ "staged (renamed)  renamed.ex"
    end

    test "formats untracked files (single ?)" do
      output = CompleteTask.format_git_status_porcelain("?? untracked.ex")
      assert output =~ "untracked  untracked.ex"
    end

    test "formats multiple files on separate lines" do
      porcelain = " M modified.ex\nA  added.ex\n?? untracked.ex"
      output = CompleteTask.format_git_status_porcelain(porcelain)

      assert output =~ "modified  modified.ex"
      assert output =~ "staged (new)  added.ex"
      assert output =~ "untracked  untracked.ex"
    end

    test "passes through unknown status codes as-is" do
      output = CompleteTask.format_git_status_porcelain("XY weird.ex")
      assert output =~ "XY  weird.ex"
    end

    test "handles empty string" do
      assert CompleteTask.format_git_status_porcelain("") == ""
    end

    test "passes through short lines unchanged" do
      output = CompleteTask.format_git_status_porcelain("ab")
      assert output == "ab "
    end
  end

  describe "complete/5" do
    setup %{repos: repos} do
      tmp_dir = copy_repo!(repos, :one)
      base_commit = repos.base_commit

      # Ensure ETS tables exist for task-scoped naming lookups (create if not exist)
      ensure_task_tables!()

      {:ok, %{tmp_dir: tmp_dir, base_commit: base_commit}}
    end

    test "returns a branch name evogit-agent-T<task_id>-A<task_local_id> for the agent", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      # ETS entries for task-scoped naming, under a per-test unique agent id
      agent_id = unique_agent_id()
      register_agent!(agent_id, "1", 1, 1)

      result =
        CompleteTask.complete(agent_id, "Task done", base_commit, base_commit: base_commit)

      assert %{result: "Task done", commit_sha: ^base_commit, branch: "evogit-agent-T1-A1"} =
               result

      Process.delete(:repo_path)
    end

    test "writes a JSON metadata note with --ref=evogit when base_commit is provided", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      CompleteTask.complete("agent_meta", "Result text", base_commit,
        base_commit: base_commit,
        parent_id: "parent_1",
        depth: 2,
        objective: "Investigate the codebase"
      )

      # Verify the note is readable via Git.get_note
      assert {:ok, metadata} = Git.get_note(tmp_dir, base_commit, ["--ref=evogit"])

      assert metadata["agent_id"] == "agent_meta"
      assert metadata["base_commit"] == base_commit
      assert metadata["final_commit"] == base_commit
      assert metadata["parent_id"] == "parent_1"
      assert metadata["depth"] == 2
      assert metadata["objective"] == "Investigate the codebase"
      assert metadata["completed_at"] != nil

      # Verify completed_at is a valid ISO8601 timestamp
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(metadata["completed_at"])

      Process.delete(:repo_path)
    end

    test "skips metadata note when base_commit is nil", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      CompleteTask.complete("agent_no_base", "Result text", base_commit, base_commit: nil)

      # Verify no note was created
      assert {:error, {:no_note, _}} = Git.get_note(tmp_dir, base_commit, ["--ref=evogit"])

      Process.delete(:repo_path)
    end

    test "returns a map with :result, :commit_sha, and :branch", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      # ETS entries for task-scoped naming, under a per-test unique agent id
      agent_id = unique_agent_id()
      register_agent!(agent_id, "2", 2, 3)

      result =
        CompleteTask.complete(agent_id, "My findings", base_commit, base_commit: base_commit)

      assert is_map(result)
      assert Map.has_key?(result, :result)
      assert Map.has_key?(result, :commit_sha)
      assert Map.has_key?(result, :branch)
      assert result.result == "My findings"
      assert result.commit_sha == base_commit
      assert result.branch == "evogit-agent-T2-A3"

      Process.delete(:repo_path)
    end

    test "note is round-trippable via Git.get_note", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      CompleteTask.complete("agent_rt", "Round trip result", base_commit,
        base_commit: base_commit,
        parent_id: "root_agent",
        depth: 1,
        objective: "Check round-trip"
      )

      # Use the higher-level Git.get_note which parses JSON
      assert {:ok, metadata} = Git.get_note(tmp_dir, base_commit, ["--ref=evogit"])
      assert is_map(metadata)
      assert metadata["agent_id"] == "agent_rt"
      assert metadata["final_commit"] == base_commit

      Process.delete(:repo_path)
    end

    test "multi-line metadata note with quotes and '>' chars is force-overwritten via the -f fallback",
         %{
           tmp_dir: tmp_dir,
           base_commit: base_commit
         } do
      Process.put(:repo_path, tmp_dir)

      # ETS entries for task-scoped naming, under a per-test unique agent id
      agent_id = unique_agent_id()
      register_agent!(agent_id, "force", 6, 9)

      # Hostile content on BOTH completions: double quotes, newlines and '>'
      # chars flow into the pretty-printed JSON note (Jason.encode! pretty: true
      # is always multi-line). On Windows, `git notes add -m` with such content
      # broke with "unknown switch `>'" / "too many arguments" — this pins the
      # regression end-to-end (the -F <tempfile> adapter fix).
      first_result = "First result: \"quoted\"\nline2 > done"
      first_objective = "Objective > with > chars and \"quotes\""

      CompleteTask.complete(agent_id, first_result, base_commit,
        base_commit: base_commit,
        objective: first_objective
      )

      # Second completion on the SAME commit: `git notes add` now fails with
      # "a note already exists" (exit 1 → {:error, {:conflict, _msg}}), so
      # add_metadata_note delegates to handle_fallback, which retries with
      # force: true (git notes add -f). Asserting the SECOND result round-trips
      # byte-for-byte below IS the assertion that the -f fallback worked — the
      # first completion's note would otherwise still win.
      second_result = "Second result: overwritten > \"again\"\nline3"

      CompleteTask.complete(agent_id, second_result, base_commit,
        base_commit: base_commit,
        objective: first_objective
      )

      # Exact match — proves the force-overwrite path preserved the second
      # content byte-for-byte through pretty-JSON encode → git note → decode.
      assert {:ok, metadata} = CompleteTask.get_agent_metadata(tmp_dir, base_commit)
      assert metadata["result"] == second_result
      assert metadata["objective"] == first_objective

      Process.delete(:repo_path)
    end

    test "uses default opts when not provided", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      # ETS entries for task-scoped naming, under a per-test unique agent id
      agent_id = unique_agent_id()
      register_agent!(agent_id, "5", 5, 7)

      result = CompleteTask.complete(agent_id, "Simple result", base_commit)

      assert result.branch == "evogit-agent-T5-A7"
      assert result.result == "Simple result"

      # No base_commit in opts, so no metadata note
      assert {:error, {:no_note, _}} = Git.get_note(tmp_dir, base_commit, ["--ref=evogit"])

      Process.delete(:repo_path)
    end
  end

  describe "get_agent_metadata/2" do
    setup %{repos: repos} do
      {:ok, %{tmp_dir: copy_repo!(repos, :one), commit_sha: repos.base_commit}}
    end

    test "returns ok with metadata map when a note exists", %{
      tmp_dir: tmp_dir,
      commit_sha: commit_sha
    } do
      Process.put(:repo_path, tmp_dir)

      # First, create completion with metadata
      CompleteTask.complete("agent_gm", "Some result", commit_sha,
        base_commit: commit_sha,
        parent_id: "root",
        depth: 3,
        objective: "Test metadata retrieval"
      )

      # Now retrieve the metadata
      assert {:ok, metadata} = CompleteTask.get_agent_metadata(tmp_dir, commit_sha)
      assert metadata["agent_id"] == "agent_gm"
      assert metadata["base_commit"] == commit_sha
      assert metadata["final_commit"] == commit_sha
      assert metadata["parent_id"] == "root"
      assert metadata["depth"] == 3
      assert metadata["objective"] == "Test metadata retrieval"

      Process.delete(:repo_path)
    end

    test "returns error when no note exists", %{
      tmp_dir: tmp_dir,
      commit_sha: commit_sha
    } do
      # No note was added, so it should return an error
      assert {:error, {:no_note, _}} = CompleteTask.get_agent_metadata(tmp_dir, commit_sha)
    end

    test "returns error for a commit that doesn't exist" do
      assert {:error, {:enoent, _}} =
               CompleteTask.get_agent_metadata("/nonexistent/path", "abc123")
    end
  end

  describe "archive functionality" do
    setup %{repos: repos} do
      tmp_dir = copy_repo!(repos, :two)

      # Ensure ETS tables exist for task-scoped naming lookups
      ensure_task_tables!()

      {:ok,
       %{
         tmp_dir: tmp_dir,
         base_commit: repos.base_commit,
         final_commit: repos.final_commit
       }}
    end

    test "creates archive refs and persists exactly ONE archive row when archive is enabled", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit,
      final_commit: final_commit
    } do
      Process.put(:repo_path, tmp_dir)
      task_id = "ct#{System.unique_integer([:positive])}"
      agent_id = System.unique_integer([:positive])
      register_agent!(agent_id, task_id, 1, 1)

      CompleteTask.complete(agent_id, "Archive result", final_commit,
        base_commit: base_commit,
        archive: true,
        objective: "Test archive",
        parent_id: nil,
        depth: 0
      )

      ref_start = "refs/genesis/archive/T#{task_id}-A1-start"
      ref_final = "refs/genesis/archive/T#{task_id}-A1-final"

      assert {:ok, ^base_commit} = Git.rev_parse(tmp_dir, ref_start)
      assert {:ok, ^final_commit} = Git.rev_parse(tmp_dir, ref_final)

      # The STREAMING write: exactly ONE row in `task_agent_archives`, written
      # at agent completion (no buffering, no task-end collection).
      assert %{entries: [entry], total: 1} =
               TaskRegistry.list_task_archives(task_id, include_results: true)

      assert entry["task_id"] == task_id
      assert entry["agent_id"] == agent_id
      assert entry["objective"] == "Test archive"
      assert entry["result"] == "Archive result"
      assert entry["base_commit"] == base_commit
      assert entry["final_commit"] == final_commit
      assert entry["archive_ref_start"] == ref_start
      assert entry["archive_ref_final"] == ref_final
      assert entry["branch_name"] == "evogit-agent-T1-A1"
      assert entry["depth"] == 0

      # model_id defaults to nil when not provided
      assert entry["llm_settings"]["model_id"] == nil

      Process.delete(:repo_path)
    end

    test "does NOT create archive refs or an archive row when archive is disabled (default)", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit,
      final_commit: final_commit
    } do
      Process.put(:repo_path, tmp_dir)
      task_id = "ct#{System.unique_integer([:positive])}"
      agent_id = System.unique_integer([:positive])
      register_agent!(agent_id, task_id, 2, 2)

      # No archive: true
      CompleteTask.complete(agent_id, "No archive result", final_commit, base_commit: base_commit)

      # These refs should not exist
      assert {:error, {_, _}} =
               Git.rev_parse(tmp_dir, "refs/genesis/archive/T#{task_id}-A2-start")

      assert {:error, {_, _}} =
               Git.rev_parse(tmp_dir, "refs/genesis/archive/T#{task_id}-A2-final")

      # No archive row should be persisted either
      assert %{entries: [], total: 0} = TaskRegistry.list_task_archives(task_id)
      assert TaskRegistry.get_agent_archive(task_id, agent_id) == nil

      Process.delete(:repo_path)
    end

    test "includes usage in git note metadata", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit,
      final_commit: final_commit
    } do
      Process.put(:repo_path, tmp_dir)
      task_id = "ct#{System.unique_integer([:positive])}"
      agent_id = System.unique_integer([:positive])
      register_agent!(agent_id, task_id, 3, 3)

      usage = %EvoGit.Agent.Usage{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_cost: 0.005,
        output_cost: 0.010,
        total_cost: 0.015,
        cached_tokens: 40,
        cache_creation_tokens: 20
      }

      CompleteTask.complete(agent_id, "Usage result", final_commit,
        base_commit: base_commit,
        usage: usage,
        archive: true
      )

      # Read back the note
      assert {:ok, metadata} = Git.get_note(tmp_dir, final_commit, ["--ref=evogit"])

      assert metadata["usage"] != nil
      assert metadata["usage"]["input_tokens"] == 100
      assert metadata["usage"]["output_tokens"] == 50
      assert metadata["usage"]["total_tokens"] == 150
      assert metadata["usage"]["cost"] == 0.015

      # The note should use the concise format — new fields should NOT be present
      refute Map.has_key?(metadata["usage"], "cached_tokens")
      refute Map.has_key?(metadata["usage"], "input_cost")

      # The archive row carries the RICHER usage format (plain JSON, so the
      # keys arrive STRING-keyed after the round trip).
      assert %{entries: [entry], total: 1} =
               TaskRegistry.list_task_archives(task_id, include_results: true)

      arc_usage = entry["usage"]
      assert arc_usage["input_tokens"] == 100
      assert arc_usage["output_tokens"] == 50
      assert arc_usage["total_tokens"] == 150
      assert arc_usage["input_cost"] == 0.005
      assert arc_usage["output_cost"] == 0.010
      assert arc_usage["total_cost"] == 0.015
      assert arc_usage["cached_tokens"] == 40
      assert arc_usage["cache_creation_tokens"] == 20
      assert arc_usage["cache_hit_rate"] == 40.0

      # The archive usage map is the canonical per-agent cost contract: exactly
      # the keys of Usage.archive_usage_keys/0 — nothing more, and NEVER a
      # legacy note-style `cost` key.
      assert MapSet.new(Map.keys(arc_usage)) ==
               MapSet.new(Enum.map(EvoGit.Agent.Usage.archive_usage_keys(), &Atom.to_string/1))

      Process.delete(:repo_path)
    end

    test "the persisted archive row carries all 22 archive fields", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit,
      final_commit: final_commit
    } do
      Process.put(:repo_path, tmp_dir)
      Process.put(:evogit_started_at, DateTime.utc_now() |> DateTime.to_iso8601())
      task_id = "ct#{System.unique_integer([:positive])}"
      agent_id = System.unique_integer([:positive])
      register_agent!(agent_id, task_id, 4, 4)

      CompleteTask.complete(agent_id, "Full record test", final_commit,
        base_commit: base_commit,
        archive: true,
        objective: "Test record shape",
        parent_id: agent_id - 1,
        depth: 3,
        llm_model: "test:model",
        model_id: "fast",
        llm_generation_params: [temperature: 0.7],
        compression_threshold: 100_000,
        max_turns: 128,
        max_retries: 15,
        max_agent_depth: 8,
        foreign_repos: [EvoGit.Core.ForeignRepo.new("ext", "/path/to/ext")]
      )

      entry = TaskRegistry.get_agent_archive(task_id, agent_id)
      assert is_map(entry)

      # EXACTLY the table's columns: 22 producer fields + the task id.
      expected_keys = EvoGit.Store.Schemas.TaskAgentArchiveRow.columns()
      assert length(expected_keys) == 23
      assert Enum.sort(Map.keys(entry)) == Enum.sort(expected_keys)

      # Every producer field is populated (nothing silently dropped).
      for field <- expected_keys, field != "task_id" do
        assert Map.has_key?(entry, field)
      end

      assert entry["task_id"] == task_id
      assert entry["agent_id"] == agent_id
      assert entry["parent_id"] == agent_id - 1
      assert entry["depth"] == 3
      assert entry["objective"] == "Test record shape"
      assert entry["result"] == "Full record test"
      assert entry["base_commit"] == base_commit
      assert entry["final_commit"] == final_commit
      assert entry["archive_ref_start"] == "refs/genesis/archive/T#{task_id}-A4-start"
      assert entry["archive_ref_final"] == "refs/genesis/archive/T#{task_id}-A4-final"
      assert entry["branch_name"] == "evogit-agent-T4-A4"
      assert entry["repo_path"] == tmp_dir
      assert entry["compression_count"] == 0
      assert entry["completed_at"] != nil
      assert entry["started_at"] != nil

      # llm_settings carries the generation-time configuration
      llm_settings = entry["llm_settings"]
      assert llm_settings["model"] == "test:model"
      assert llm_settings["model_id"] == "fast"
      assert llm_settings["context_compression_threshold"] == 100_000
      assert llm_settings["temperature"] == 0.7

      # agent_settings carries the scheduler's caps
      agent_settings = entry["agent_settings"]
      assert agent_settings["max_turns"] == 128
      assert agent_settings["max_retries"] == 15
      assert agent_settings["max_agent_depth"] == 8

      # foreign_repos carries the delegation roster
      assert [repo_entry] = entry["foreign_repos"]
      assert repo_entry["id"] == "ext"
      assert repo_entry["root"] == "/path/to/ext"
      assert repo_entry["description"] == nil

      Process.delete(:repo_path)
      Process.delete(:evogit_started_at)
    end

    test "re-completing the same agent REPLACES its archive row (crash-retry idempotency)", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit,
      final_commit: final_commit
    } do
      Process.put(:repo_path, tmp_dir)
      task_id = "ct#{System.unique_integer([:positive])}"
      agent_id = System.unique_integer([:positive])
      register_agent!(agent_id, task_id, 5, 5)

      # Simulate a crash-retry double-completion: the same agent completes twice
      # with the same task_id. The composite primary key makes the second write
      # an idempotent upsert — at most ONE row.
      CompleteTask.complete(agent_id, "First", final_commit,
        base_commit: base_commit,
        archive: true
      )

      CompleteTask.complete(agent_id, "Second", final_commit,
        base_commit: base_commit,
        archive: true
      )

      assert %{entries: [entry], total: 1} =
               TaskRegistry.list_task_archives(task_id, include_results: true)

      assert entry["agent_id"] == agent_id
      assert entry["result"] == "Second"

      Process.delete(:repo_path)
    end

    test "two agents of one task persist one archive row each (no cross-agent leak)", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit,
      final_commit: final_commit
    } do
      Process.put(:repo_path, tmp_dir)
      task_id = "ct#{System.unique_integer([:positive])}"
      agent1 = System.unique_integer([:positive])
      agent2 = System.unique_integer([:positive])
      register_agent!(agent1, task_id, 6, 1)
      register_agent!(agent2, task_id, 6, 2)

      CompleteTask.complete(agent1, "Run1 A1", final_commit,
        base_commit: base_commit,
        archive: true
      )

      CompleteTask.complete(agent2, "Run1 A2", final_commit,
        base_commit: base_commit,
        archive: true
      )

      # Ordered `depth ASC, agent_id ASC` — both rows, each carrying only its
      # OWN result.
      assert %{entries: entries, total: 2} =
               TaskRegistry.list_task_archives(task_id, include_results: true)

      assert Enum.map(entries, & &1["agent_id"]) |> Enum.sort() ==
               Enum.sort([agent1, agent2])

      by_agent = Map.new(entries, &{&1["agent_id"], &1["result"]})
      assert by_agent[agent1] == "Run1 A1"
      assert by_agent[agent2] == "Run1 A2"

      # The roster read never selects the heavy `result` column.
      assert %{entries: roster, total: 2} = TaskRegistry.list_task_archives(task_id)
      refute Enum.any?(roster, &Map.has_key?(&1, "result"))

      Process.delete(:repo_path)
    end

    test "skips the archive row when the task id is unknown (scheduler lookup miss)", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit,
      final_commit: final_commit
    } do
      Process.put(:repo_path, tmp_dir)
      # No sched_meta/agent_state entry for this agent id: `lookup_task_info/1`
      # misses and yields task id 0, which cannot identify an archive row.
      agent_id = System.unique_integer([:positive])

      CompleteTask.complete(agent_id, "Unknown task", final_commit,
        base_commit: base_commit,
        archive: true
      )

      # The refs are still written (they only need the derived id pair)…
      assert {:ok, _} = Git.rev_parse(tmp_dir, "refs/genesis/archive/T0-A0-start")
      assert {:ok, _} = Git.rev_parse(tmp_dir, "refs/genesis/archive/T0-A0-final")

      # …but NO archive row is persisted and nothing raises.
      assert %{entries: [], total: 0} = TaskRegistry.list_task_archives("0")
      assert TaskRegistry.get_agent_archive("0", agent_id) == nil

      Process.delete(:repo_path)
    end

    # Registers one agent in the scheduler ETS tables so `complete/5` can derive
    # the task-scoped archive ref/branch names. Agent ids are INTEGERS (the
    # scheduler's `next_agent_id`) — the archive table's `agent_id` is an
    # integer primary-key part.
    defp register_agent!(agent_id, task_id, task_number, task_local_id) do
      :ets.insert(:evogit_sched_meta, {agent_id, %{task_id: task_id, task_number: task_number}})
      :ets.insert(:evogit_agent_state, {agent_id, %{task_local_id: task_local_id}})

      on_exit(fn ->
        :ets.delete(:evogit_sched_meta, agent_id)
        :ets.delete(:evogit_agent_state, agent_id)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # Builds the per-module repository TEMPLATE SET once (`setup_all`): every
  # `git` subprocess below is paid once per module instead of once per test.
  #
  #   * `:empty` — an initialized repo with NO commits;
  #   * `:one`   — one commit tracking `test.txt` ("initial content") — the sha
  #                is `base_commit`;
  #   * `:two`   — `:one` plus a second commit rewriting `test.txt` ("updated
  #                content") — its sha is `final_commit`.
  #
  # `git init` uses an EMPTY template dir (no hook samples / boilerplate), the
  # fixture identity + `commit.gpgsign=false` are repo-local, and
  # `core.abbrev=40` keeps any parsed commit sha complete. A per-test
  # `File.cp_r!` of a snapshot is a fully isolated repository (~2 ms) versus
  # ~25-40 ms of `git init` + `git config` + commit chain.
  defp git_templates! do
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit_complete_task_tpl_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    empty_template = Path.join(root, "empty_template")
    File.mkdir_p!(empty_template)

    repo = Path.join(root, "repo")

    {_, 0} =
      System.cmd("git", ["init", "-q", "--template=#{empty_template}", repo],
        stderr_to_stdout: true
      )

    for {key, value} <- [
          {"user.email", "test@example.com"},
          {"user.name", "Test User"},
          {"commit.gpgsign", "false"},
          {"core.abbrev", "40"}
        ] do
      {_, 0} = System.cmd("git", ["config", key, value], cd: repo, stderr_to_stdout: true)
    end

    empty = Path.join(root, "snapshot_empty")
    File.cp_r!(repo, empty)

    base_commit = commit_file!(repo, "test.txt", "initial content", "Initial commit")
    one = Path.join(root, "snapshot_one")
    File.cp_r!(repo, one)

    final_commit = commit_file!(repo, "test.txt", "updated content", "Updated commit")
    two = Path.join(root, "snapshot_two")
    File.cp_r!(repo, two)

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      empty: empty,
      one: one,
      two: two,
      base_commit: base_commit,
      final_commit: final_commit
    }
  end

  # Writes `relative_path`, stages EVERYTHING and commits; returns the new HEAD
  # sha (`core.abbrev=40` is not needed here — an explicit `rev-parse` is one
  # subprocess, paid once per template).
  defp commit_file!(repo, relative_path, content, message) do
    File.write!(Path.join(repo, relative_path), content)
    {_, 0} = System.cmd("git", ["add", "--", relative_path], cd: repo, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", message], cd: repo, stderr_to_stdout: true)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo, stderr_to_stdout: true)
    String.trim(sha)
  end

  # Copies a template snapshot into a fresh, uniquely-named directory: an
  # isolated repository whose commits, refs and worktree state are exactly the
  # snapshot's. Cleaned up on exit.
  defp copy_repo!(repos, kind) do
    dest =
      Path.join(
        System.tmp_dir!(),
        "complete_task_repo_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.cp_r!(Map.fetch!(repos, kind), dest)
    on_exit(fn -> File.rm_rf!(dest) end)
    dest
  end

  # A per-test agent id for rows seeded into the app-global scheduler ETS tables:
  # unique so a concurrently running module can neither observe nor clobber them.
  defp unique_agent_id, do: "ct_agent_#{System.unique_integer([:positive])}"

  # The task-scoped naming lookups read these NAMED tables; the app owns them,
  # so this is a no-op unless the app is not running.
  defp ensure_task_tables! do
    unless :ets.whereis(:evogit_sched_meta) != :undefined do
      :ets.new(:evogit_sched_meta, [:set, :public, :named_table])
    end

    unless :ets.whereis(:evogit_agent_state) != :undefined do
      :ets.new(:evogit_agent_state, [:set, :public, :named_table])
    end
  end
end
