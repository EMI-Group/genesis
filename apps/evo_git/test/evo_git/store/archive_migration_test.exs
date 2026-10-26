defmodule EvoGit.Store.ArchiveMigrationTest do
  @moduledoc """
  Coverage for the DATA migrations of the relational-archive round:

    * `20260815000006_unpack_abandoned_compressed_rows` — the one-shot repair
      that expands values still stored in the rejected `"z1:"`-prefixed
      compression format (written by the migration that no longer ships) back
      into plain JSON text, for `result`/`logs`/`archive_metadata`;
    * `20260815000008_move_archives_to_table` — the fan-out of the legacy
      `tasks.archive_metadata` JSON array into ONE `task_agent_archives` row per
      archived agent, followed by the physical `DROP COLUMN`;
    * `20260815000009_normalize_task_agent_archives` — the canonical-shape
      repair of `task_agent_archives`: a table whose `repo_id` was declared
      INTEGER (a pre-release variant of `…007`) is rebuilt with the canonical
      TEXT column, every row preserved.

  ## Fixture shape

  Each test crafts a REAL pre-migration database with RAW xqlite (never the
  repo): the canonical 20-column `tasks` table (the pre-drop shape, i.e. WITH
  `archive_metadata`), the `projects` table and a `schema_migrations` table.
  The fixture stamps every shipped version EXCEPT the one under test, so
  exactly that migration is pending and its effects are observable in
  isolation — most importantly 006 must be asserted BEFORE 008 nulls the
  archive column and drops it.

  ## Pinned contracts

    * 006: `"z1:"`-prefixed `result`/`logs`/`archive_metadata` values are
      inflated back to the ORIGINAL plain JSON bytes; values that never had the
      prefix are byte-identical afterwards; a corrupt payload is left exactly
      as it was and logged as a WARNING naming the task id and the column;
      `updated_at` never moves;
    * 008: one `task_agent_archives` row per record with EVERY column mapped
      (JSON columns re-encoded as plain JSON, `depth`/`compression_count`
      defaulting to 0, `repo_id` copied VERBATIM as the repo ID STRING it
      carried — `"primary"`/`"cowboy"`, never an index), the duplicated
      `data.archive_records` stripped from `result` ONLY when present (a result
      without it stays byte-identical), `archive_metadata` NULLed, the column
      physically dropped, `updated_at` untouched, and a re-run (partial-failure
      recovery) converging. The migrated rows MUST also be readable through the
      `EvoGit.Store` facade (`list_task_archives/3`, `get_agent_archive/3`) —
      with `repo_id` typed INTEGER every real-data load degraded to
      `%{entries: [], total: 0}` / `nil`.
    * 009: an INTEGER-affinity `repo_id` table is rebuilt into the EXACT
      canonical shape of `…007` (columns/order/types/NOT NULLs/DEFAULTs/PK),
      all rows and values preserved, a coerced numeric-looking value coming
      back as its TEXT form (`"123"`, loadable by the Ecto `:string` field) and
      the `task_agent_archives_task_depth_idx` index recreated; a canonical
      TEXT table, a database WITHOUT the table, and a forced re-run are all
      NO-OPs (no rebuild, no warning).

  Never writes to the user's real data dir: every database lives under the
  per-test `System.tmp_dir!()` root.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.Boot
  alias EvoGit.Store.RepoScope

  @baseline_version 20_260_815_000_001
  @normalization_version 20_260_815_000_002
  @composite_index_version 20_260_815_000_003
  @covering_index_version 20_260_815_000_005
  @unpack_version 20_260_815_000_006
  @archive_table_version 20_260_815_000_007
  @move_archives_version 20_260_815_000_008
  @normalize_archives_version 20_260_815_000_009

  # Ascending, exactly as `schema_migrations` reports it (the rejected
  # compression migration 004 no longer ships).
  @migration_versions [
    @baseline_version,
    @normalization_version,
    @composite_index_version,
    @covering_index_version,
    @unpack_version,
    @archive_table_version,
    @move_archives_version,
    @normalize_archives_version
  ]

  # The canonical PRE-DROP 20-column DDL — the state a database upgraded from
  # a released build is in (the baseline created it, no archive migration has
  # run yet).
  @tasks_ddl """
  CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    type TEXT,
    status TEXT NOT NULL,
    opts TEXT,
    started_at TEXT,
    finished_at TEXT,
    logs TEXT,
    result TEXT,
    review_status TEXT,
    usage TEXT,
    agent_count INTEGER,
    base_sha TEXT,
    commit_sha TEXT,
    archive_metadata TEXT,
    lease_expires_at INTEGER,
    model_id TEXT,
    project_path TEXT,
    branch_name TEXT,
    error TEXT,
    updated_at TEXT
  )
  """

  @projects_ddl """
  CREATE TABLE projects (
    path TEXT PRIMARY KEY,
    name TEXT,
    last_opened_at TEXT
  )
  """

  @updated_at "2024-05-05T10:00:01.000Z"

  @archive_table "task_agent_archives"

  # The destination columns in table order — the exact projection the
  # assertions read back.
  @archive_projection ~w(task_id agent_id parent_id depth agent_type context_node_path objective
                         result base_commit final_commit branch_name archive_ref_start
                         archive_ref_final repo_id repo_root repo_path usage llm_settings
                         agent_settings foreign_repos compression_count started_at completed_at)

  # The archive-table columns stored as plain JSON TEXT.
  @json_columns ~w(usage llm_settings agent_settings foreign_repos)

  @archive_index "task_agent_archives_task_depth_idx"

  # `PRAGMA table_info(task_agent_archives)` rows — [cid, name, type, notnull,
  # dflt, pk] — of the CANONICAL table (the exact shape `…007` creates and
  # `…009` must converge on): TEXT `repo_id`, `task_id`/`agent_id` the composite
  # primary key, DEFAULT 0 on `depth`/`compression_count`.
  @canonical_archive_table_info [
    [0, "task_id", "TEXT", 1, nil, 1],
    [1, "agent_id", "INTEGER", 1, nil, 2],
    [2, "parent_id", "INTEGER", 0, nil, 0],
    [3, "depth", "INTEGER", 1, "0", 0],
    [4, "agent_type", "TEXT", 0, nil, 0],
    [5, "context_node_path", "TEXT", 0, nil, 0],
    [6, "objective", "TEXT", 0, nil, 0],
    [7, "result", "TEXT", 0, nil, 0],
    [8, "base_commit", "TEXT", 0, nil, 0],
    [9, "final_commit", "TEXT", 0, nil, 0],
    [10, "branch_name", "TEXT", 0, nil, 0],
    [11, "archive_ref_start", "TEXT", 0, nil, 0],
    [12, "archive_ref_final", "TEXT", 0, nil, 0],
    [13, "repo_id", "TEXT", 0, nil, 0],
    [14, "repo_root", "TEXT", 0, nil, 0],
    [15, "repo_path", "TEXT", 0, nil, 0],
    [16, "usage", "TEXT", 0, nil, 0],
    [17, "llm_settings", "TEXT", 0, nil, 0],
    [18, "agent_settings", "TEXT", 0, nil, 0],
    [19, "foreign_repos", "TEXT", 0, nil, 0],
    [20, "compression_count", "INTEGER", 1, "0", 0],
    [21, "started_at", "TEXT", 0, nil, 0],
    [22, "completed_at", "TEXT", 0, nil, 0]
  ]

  # The PRE-RELEASE variant of the archive table: byte-for-byte the canonical
  # DDL except `repo_id INTEGER` — the shape a dev database created by the
  # abandoned `…007` variant carries.
  @pre_release_archive_ddl """
  CREATE TABLE task_agent_archives (
    task_id TEXT NOT NULL,
    agent_id INTEGER NOT NULL,
    parent_id INTEGER,
    depth INTEGER NOT NULL DEFAULT 0,
    agent_type TEXT,
    context_node_path TEXT,
    objective TEXT,
    result TEXT,
    base_commit TEXT,
    final_commit TEXT,
    branch_name TEXT,
    archive_ref_start TEXT,
    archive_ref_final TEXT,
    repo_id INTEGER,
    repo_root TEXT,
    repo_path TEXT,
    usage TEXT,
    llm_settings TEXT,
    agent_settings TEXT,
    foreign_repos TEXT,
    compression_count INTEGER NOT NULL DEFAULT 0,
    started_at TEXT,
    completed_at TEXT,
    PRIMARY KEY (task_id, agent_id)
  )
  """

  # The canonical `…007` DDL, used by the "already correct, never rebuilt" test.
  @canonical_archive_ddl """
  CREATE TABLE task_agent_archives (
    task_id TEXT NOT NULL,
    agent_id INTEGER NOT NULL,
    parent_id INTEGER,
    depth INTEGER NOT NULL DEFAULT 0,
    agent_type TEXT,
    context_node_path TEXT,
    objective TEXT,
    result TEXT,
    base_commit TEXT,
    final_commit TEXT,
    branch_name TEXT,
    archive_ref_start TEXT,
    archive_ref_final TEXT,
    repo_id TEXT,
    repo_root TEXT,
    repo_path TEXT,
    usage TEXT,
    llm_settings TEXT,
    agent_settings TEXT,
    foreign_repos TEXT,
    compression_count INTEGER NOT NULL DEFAULT 0,
    started_at TEXT,
    completed_at TEXT,
    PRIMARY KEY (task_id, agent_id)
  )
  """

  # The 19 LIVE `tasks` columns AFTER the archive migration drops
  # `archive_metadata`.
  @live_task_columns ~w(id type status opts started_at finished_at logs result review_status
                        usage agent_count base_sha commit_sha lease_expires_at model_id
                        project_path branch_name error updated_at)

  setup do
    # pid + wall-clock ms on top of the per-BEAM unique integer: a counter
    # alone collides with a PREVIOUS run's leftover directory.
    stamp =
      "#{System.system_time(:millisecond)}_#{:os.getpid()}_#{System.unique_integer([:positive])}"

    root = Path.join(System.tmp_dir!(), "evogit_archive_migration_#{stamp}_#{inspect(self())}")

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, %{root: root}}
  end

  # ── 20260815000006_unpack_abandoned_compressed_rows ───────────────────────

  describe "20260815000006_unpack_abandoned_compressed_rows" do
    test "inflates z1-packed result/logs/archive_metadata back to plain JSON", %{root: root} do
      path = Path.join(root, "unpack.sqlite")

      %{result: plain_result, logs: plain_logs, archive: plain_archive} = seed_packed!(path)

      pid = start_repo!(path)

      # The inflated value is the ORIGINAL plain JSON, byte for byte.
      assert raw!(path, "packed", "result") == plain_result
      assert raw!(path, "packed", "logs") == plain_logs
      assert raw!(path, "packed", "archive_metadata") == plain_archive

      # Every shipped version is stamped, including the repair.
      assert migration_versions(pid) == @migration_versions
    end

    test "leaves unprefixed values byte-identical and never bumps updated_at", %{root: root} do
      path = Path.join(root, "unpack_untouched.sqlite")
      seed_packed!(path)

      before = snapshot!(path)
      before_updated_at = updated_at_map!(path)

      start_repo!(path)

      after_ = snapshot!(path)

      # The plain row is untouched (and still not prefixed).
      assert after_[{"plain", "result"}] == before[{"plain", "result"}]
      assert after_[{"plain", "logs"}] == before[{"plain", "logs"}]
      assert after_[{"plain", "archive_metadata"}] == before[{"plain", "archive_metadata"}]
      refute packed?(after_[{"plain", "result"}])

      # NULL columns stay NULL.
      assert after_[{"nil-columns", "result"}] == nil
      assert after_[{"nil-columns", "logs"}] == nil
      assert after_[{"nil-columns", "archive_metadata"}] == nil

      # The repair never touches updated_at — for ANY row.
      assert updated_at_map!(path) == before_updated_at
    end

    test "a corrupt z1 payload is logged and left exactly as it was", %{root: root} do
      path = Path.join(root, "unpack_corrupt.sqlite")
      seed_packed!(path)

      before = snapshot!(path)

      {_pid, log} = with_log(fn -> start_repo!(path) end)

      assert log =~ "skipping task corrupt-base64 column result"
      assert log =~ "skipping task corrupt-zlib column logs"

      after_ = snapshot!(path)

      # Neither corrupt value changed by a single byte...
      assert after_[{"corrupt-base64", "result"}] == before[{"corrupt-base64", "result"}]
      assert after_[{"corrupt-zlib", "logs"}] == before[{"corrupt-zlib", "logs"}]

      # ...while the healthy rows were still repaired.
      assert after_[{"packed", "result"}] != before[{"packed", "result"}]
      refute packed?(after_[{"packed", "result"}])
    end

    test "is idempotent: a forced re-run rewrites nothing", %{root: root} do
      path = Path.join(root, "unpack_idempotent.sqlite")
      seed_packed!(path)

      pid = start_repo!(path)
      first = snapshot!(path)

      # Drop the version row so the migration body runs AGAIN over the already
      # repaired file — it must converge without writing anything.
      :ok = clear_version!(pid, @unpack_version)
      :ok = Boot.stop(pid)

      pid = start_repo!(path)

      assert snapshot!(path) == first
      assert migration_versions(pid) == @migration_versions
    end
  end

  # ── 20260815000008_move_archives_to_table ─────────────────────────────────

  describe "20260815000008_move_archives_to_table" do
    test "fans the legacy archive out into one row per agent with every field mapped", %{
      root: root
    } do
      path = Path.join(root, "fan_out.sqlite")
      fixture = seed_archives!(path)

      pid = start_repo!(path)

      rows = archive_rows(pid, "task-a")

      assert Enum.map(rows, fn [_task_id, agent_id | _rest] -> agent_id end) == [1, 2, 3]

      # The JSON columns are PLAIN JSON text — no compression, no "z1:" prefix.
      for row <- rows,
          {column, value} <- Enum.zip(@archive_projection, row),
          column in @json_columns,
          value != nil do
        assert is_binary(value)
        refute String.starts_with?(value, "z1:")
      end

      assert archive_entry(rows, 1) == %{
               "task_id" => "task-a",
               "agent_id" => 1,
               "parent_id" => nil,
               "depth" => 0,
               "agent_type" => "manager",
               "context_node_path" => ".",
               "objective" => "Build the thing",
               "result" => "final answer text",
               "base_commit" => "base1",
               "final_commit" => "final1",
               "branch_name" => "evogit-agent-T1-A1",
               "archive_ref_start" => "refs/genesis/archive/T1-A1-start",
               "archive_ref_final" => "refs/genesis/archive/T1-A1-final",
               "repo_id" => "primary",
               "repo_root" => "/tmp/repo",
               "repo_path" => "/tmp/repo",
               "usage" => fixture.usage,
               "llm_settings" => fixture.llm_settings,
               "agent_settings" => fixture.agent_settings,
               "foreign_repos" => fixture.foreign_repos,
               "compression_count" => 2,
               "started_at" => "2024-05-05T09:00:00.000Z",
               "completed_at" => "2024-05-05T10:00:00.000Z"
             }

      # A sparse record: only what it carried, everything else NULL, and the
      # `depth`/`compression_count` NOT NULL defaults.
      assert archive_entry(rows, 2) == %{
               "task_id" => "task-a",
               "agent_id" => 2,
               "parent_id" => 1,
               "depth" => 1,
               "agent_type" => nil,
               "context_node_path" => nil,
               "objective" => "Subtask",
               "result" => "sub answer",
               "base_commit" => nil,
               "final_commit" => "final2",
               "branch_name" => nil,
               "archive_ref_start" => nil,
               "archive_ref_final" => nil,
               "repo_id" => "cowboy",
               "repo_root" => nil,
               "repo_path" => nil,
               "usage" => nil,
               "llm_settings" => nil,
               "agent_settings" => nil,
               "foreign_repos" => nil,
               "compression_count" => 0,
               "started_at" => nil,
               "completed_at" => nil
             }

      # No `depth` / `compression_count` in the record at all → the columns'
      # DEFAULT 0.
      no_counters = archive_entry(rows, 3)

      assert {no_counters["depth"], no_counters["compression_count"]} == {0, 0}
      assert no_counters["parent_id"] == 1
      assert no_counters["objective"] == "Another"
      assert no_counters["result"] == nil
      # A record that carried no `repo_id` keeps SQL NULL — the column is never
      # defaulted to an index.
      assert no_counters["repo_id"] == nil

      # The second task's archive moved too (its own (task_id, agent_id) key
      # space).
      assert %{
               "task_id" => "task-b",
               "agent_id" => 7,
               "objective" => "Solo",
               "result" => "only",
               "depth" => 0
             } = archive_entry(archive_rows(pid, "task-b"), 7)

      # THE REAL-DATA FAILURE MODE this pins: the migrated rows must be LOADABLE
      # through the `EvoGit.Store` facade. With `repo_id` typed INTEGER a
      # `"primary"` value raised `cannot load "primary" as type :integer`, the
      # read offload degraded and every archive read answered its empty shape
      # (`%{entries: [], total: 0}` / `nil`) for ALL real data.
      store = start_store!(path)

      assert %{entries: roster, total: 3} = Store.list_task_archives(store, "task-a")
      # depth ASC then agent_id ASC: 1 and 3 are depth 0, 2 is depth 1.
      assert Enum.map(roster, & &1["agent_id"]) == [1, 3, 2]
      assert Enum.map(roster, & &1["repo_id"]) == ["primary", nil, "cowboy"]

      assert %{"agent_id" => 2, "repo_id" => "cowboy", "result" => "sub answer"} =
               Store.get_agent_archive(store, "task-a", 2)

      assert %{total: 1} = Store.list_task_archives(store, "task-b")

      assert migration_versions(pid) == @migration_versions
    end

    test "strips the duplicated data.archive_records from result only when present", %{
      root: root
    } do
      path = Path.join(root, "strip_result.sqlite")
      fixture = seed_archives!(path)

      before = snapshot!(path)
      before_updated_at = updated_at_map!(path)

      start_repo!(path)

      # `task-a` carried the duplicate: the key is gone, the rest of the result
      # data is preserved.
      stripped = Jason.decode!(raw!(path, "task-a", "result"))
      refute Map.has_key?(stripped["data"], "archive_records")
      assert stripped["data"]["commit_sha"] == "abc123"
      assert stripped["data"]["result"] == "short report"
      assert Map.get(stripped, "__result_tag__") == "ok"

      # `task-b` never had the key: its result is byte-identical.
      assert raw!(path, "task-b", "result") == fixture.plain_result

      # No row's updated_at moved — moving the archive is not a task mutation.
      assert updated_at_map!(path) == before_updated_at

      # Sanity: the fan-out had a source (the column really carried the array).
      refute before[{"task-a", "archive_metadata"}] == nil
    end

    test "nulls archive_metadata and physically drops the column", %{root: root} do
      path = Path.join(root, "drop_column.sqlite")
      seed_archives!(path)

      assert "archive_metadata" in column_names!(path)

      pid = start_repo!(path)

      assert column_names(pid) == @live_task_columns
      refute "archive_metadata" in column_names(pid)
    end

    test "a corrupt archive is logged and skipped without wedging the migration", %{root: root} do
      path = Path.join(root, "corrupt_archive.sqlite")
      seed_archives!(path)

      {pid, log} = with_log(fn -> start_repo!(path) end)

      assert log =~ "skipping task task-corrupt"
      assert log =~ "not a JSON array"
      assert log =~ "skipping task task-bad-json"
      assert log =~ "not valid JSON"

      assert migration_versions(pid) == @migration_versions
      refute "archive_metadata" in column_names(pid)
      assert archive_rows(pid, "task-corrupt") == []
      assert archive_rows(pid, "task-bad-json") == []

      # The healthy tasks still migrated alongside.
      assert length(archive_rows(pid, "task-a")) == 3
    end

    test "is idempotent: re-running after the column is gone is a no-op", %{root: root} do
      path = Path.join(root, "drop_idempotent.sqlite")
      seed_archives!(path)

      pid = start_repo!(path)
      before = data_snapshot!(path)
      before_archives = archive_rows(pid, "task-a")

      # A re-run of the migration body with the column already dropped must
      # converge silently (the column-existence guard).
      :ok = clear_version!(pid, @move_archives_version)
      :ok = Boot.stop(pid)

      pid = start_repo!(path)

      assert data_snapshot!(path) == before
      assert archive_rows(pid, "task-a") == before_archives
      assert migration_versions(pid) == @migration_versions
    end

    test "resumes a partially-applied fan-out without duplicating an agent", %{root: root} do
      path = Path.join(root, "resume.sqlite")
      fixture = seed_archives!(path)

      pid = start_repo!(path)
      assert length(archive_rows(pid, "task-a")) == 3

      # Simulate a crash AFTER some rows were written but BEFORE the archive
      # was cleared/dropped: restore the column with the original array for
      # `task-a` and delete one of its three rows.
      :ok = sql!(pid, "ALTER TABLE tasks ADD COLUMN archive_metadata TEXT", [])

      :ok =
        sql!(pid, "UPDATE tasks SET archive_metadata = ? WHERE id = ?", [
          fixture.archive_a,
          "task-a"
        ])

      :ok =
        sql!(pid, "DELETE FROM #{@archive_table} WHERE task_id = ? AND agent_id = ?", [
          "task-a",
          2
        ])

      :ok = clear_version!(pid, @move_archives_version)
      :ok = Boot.stop(pid)

      pid = start_repo!(path)

      # The missing record is back, and the untouched ones were REPLACED (never
      # duplicated) — three rows, not five.
      assert Enum.map(archive_rows(pid, "task-a"), fn [_task_id, agent_id | _rest] -> agent_id end) ==
               [1, 2, 3]

      refute "archive_metadata" in column_names(pid)
      assert migration_versions(pid) == @migration_versions
    end
  end

  # ── 20260815000009_normalize_task_agent_archives ──────────────────────────

  describe "20260815000009_normalize_task_agent_archives" do
    test "rebuilds an INTEGER repo_id table to TEXT, preserving every row and the index", %{
      root: root
    } do
      path = Path.join(root, "normalize_integer.sqlite")
      seed_pre_release_archives!(path)

      # The pre-release shape really is INTEGER on disk, and the
      # numeric-looking TEXT `"123"` was COERCED to the integer 123 by that
      # affinity — the exact failure mode this migration repairs.
      assert archive_table_type!(path, "repo_id") == "INTEGER"
      assert raw_archive_value!(path, "task-legacy", 4, "repo_id") == 123

      {pid, log} = with_log(fn -> start_repo!(path) end)

      assert log =~ "rebuilding task_agent_archives"

      # The rebuilt table carries the EXACT canonical shape of `…007`.
      assert archive_table_info(pid) == @canonical_archive_table_info

      # The roster index was dropped with the old table and recreated.
      assert archive_index_columns(pid) == ~w(task_id depth agent_id)

      rows = archive_rows(pid, "task-legacy")

      assert Enum.map(rows, fn [_task_id, agent_id | _rest] -> agent_id end) == [1, 2, 3, 4]

      # Every value survived — the heavy result blob, the JSON columns, the
      # timestamps, and `repo_id` as the repo ID STRING it always was.
      assert archive_entry(rows, 1) == %{
               "task_id" => "task-legacy",
               "agent_id" => 1,
               "parent_id" => nil,
               "depth" => 0,
               "agent_type" => "manager",
               "context_node_path" => ".",
               "objective" => "Build the thing",
               "result" => "final answer text",
               "base_commit" => "base1",
               "final_commit" => "final1",
               "branch_name" => "evogit-agent-T1-A1",
               "archive_ref_start" => "refs/genesis/archive/T1-A1-start",
               "archive_ref_final" => "refs/genesis/archive/T1-A1-final",
               "repo_id" => "primary",
               "repo_root" => "/tmp/repo",
               "repo_path" => "/tmp/repo",
               "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15},
               "llm_settings" => %{"model" => "test-model"},
               "agent_settings" => %{"max_turns" => 40},
               "foreign_repos" => [],
               "compression_count" => 2,
               "started_at" => "2024-05-05T09:00:00.000Z",
               "completed_at" => "2024-05-05T10:00:00.000Z"
             }

      assert archive_entry(rows, 2)["repo_id"] == "cowboy"
      assert archive_entry(rows, 2)["depth"] == 1
      # SQL NULL stays NULL (never defaulted to an index).
      assert archive_entry(rows, 3)["repo_id"] == nil
      # The coerced integer is back to its TEXT form.
      assert archive_entry(rows, 4)["repo_id"] == "123"

      # The archive is readable through the store facade again (an
      # INTEGER-typed `repo_id` degraded EVERY real-data read).
      store = start_store!(path)

      assert %{entries: roster, total: 4} = Store.list_task_archives(store, "task-legacy")
      assert Enum.map(roster, & &1["repo_id"]) == ["primary", "cowboy", nil, "123"]

      assert migration_versions(pid) == @migration_versions
    end

    test "a numeric-looking repo_id stays TEXT through the rebuild and later inserts", %{
      root: root
    } do
      path = Path.join(root, "normalize_numeric.sqlite")
      seed_pre_release_archives!(path)

      pid = start_repo!(path)

      # The value coerced by the OLD INTEGER affinity is TEXT after the rebuild.
      assert raw_archive_value!(path, "task-legacy", 4, "repo_id") == "123"

      # A SUBSEQUENT insert of the same numeric-looking string is stored as
      # TEXT (the canonical affinity), not coerced to an integer.
      :ok =
        sql!(pid, "INSERT INTO #{@archive_table} (task_id, agent_id, repo_id) VALUES (?, ?, ?)", [
          "task-new",
          1,
          "123"
        ])

      assert raw_archive_value!(path, "task-new", 1, "repo_id") == "123"

      store = start_store!(path)

      assert %{entries: [%{"repo_id" => "123"}], total: 1} =
               Store.list_task_archives(store, "task-new")

      assert %{"agent_id" => 1, "repo_id" => "123"} =
               Store.get_agent_archive(store, "task-new", 1)
    end

    test "a canonical TEXT table is left untouched (no rebuild)", %{root: root} do
      path = Path.join(root, "normalize_canonical.sqlite")
      seed_canonical_archives!(path)

      before_info = archive_table_info_raw!(path)
      before_rows = raw_archive_rows!(path)

      {pid, log} = with_log(fn -> start_repo!(path) end)

      refute log =~ "rebuilding task_agent_archives"

      assert archive_table_info(pid) == before_info
      assert archive_table_info(pid) == @canonical_archive_table_info
      assert raw_archive_rows!(path) == before_rows
      assert migration_versions(pid) == @migration_versions
    end

    test "a database without the archive table is a no-op", %{root: root} do
      path = Path.join(root, "normalize_absent.sqlite")
      # Everything except 009 is stamped and NO archive table exists (a database
      # that never ran the archive migration).
      create_db!(path, [@normalize_archives_version])

      {pid, log} = with_log(fn -> start_repo!(path) end)

      refute log =~ "rebuilding task_agent_archives"
      assert archive_table_info(pid) == []
      assert migration_versions(pid) == @migration_versions
    end

    test "is idempotent: a forced re-run rebuilds nothing", %{root: root} do
      path = Path.join(root, "normalize_idempotent.sqlite")
      seed_pre_release_archives!(path)

      pid = start_repo!(path)
      rebuilt_info = archive_table_info(pid)
      rebuilt_rows = raw_archive_rows!(path)

      # Re-run the migration body over the ALREADY canonical table (the version
      # row deleted): the `repo_id` probe must short-circuit it.
      :ok = clear_version!(pid, @normalize_archives_version)
      :ok = Boot.stop(pid)

      {pid, log} = with_log(fn -> start_repo!(path) end)

      refute log =~ "rebuilding task_agent_archives"
      assert archive_table_info(pid) == rebuilt_info
      assert raw_archive_rows!(path) == rebuilt_rows
      assert migration_versions(pid) == @migration_versions
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  # Rows for the unpack migration: one fully packed, one plain, one NULL, and
  # two corrupt payloads (bad base64 / not a zlib stream).
  defp seed_packed!(path) do
    create_db!(path, [@unpack_version])

    result = ~S({"__result_tag__":"ok","data":{"commit_sha":"abc123","result":"done"}})
    logs = ~S(["2024-05-05 log line"])
    archive = Jason.encode!([%{"agent_id" => 1, "objective" => "step one"}])

    insert_rows!(path, [
      [
        id: "packed",
        result: packed(result),
        logs: packed(logs),
        archive_metadata: packed(archive)
      ],
      [id: "plain", result: result, logs: logs, archive_metadata: archive],
      [id: "nil-columns", result: nil, logs: nil, archive_metadata: nil],
      [id: "corrupt-base64", result: "z1:not base64 at all!!"],
      [id: "corrupt-zlib", logs: "z1:" <> Base.encode64("not a zlib stream")]
    ])

    %{result: result, logs: logs, archive: archive}
  end

  # Rows for the archive fan-out: two migratable tasks (one WITH the duplicated
  # `data.archive_records`, one without) and two undecodable archives.
  defp seed_archives!(path) do
    create_db!(path, [@archive_table_version, @move_archives_version])

    usage = %{
      "input_tokens" => 10,
      "output_tokens" => 5,
      "total_tokens" => 15,
      "total_cost" => 0.5
    }

    llm_settings = %{"model" => "test-model", "generation_params" => %{"temperature" => 0.2}}
    agent_settings = %{"max_turns" => 40, "max_retries" => 2}
    foreign_repos = [%{"id" => "foreign", "path" => "/tmp/foreign", "writable" => false}]

    full = %{
      "agent_id" => 1,
      "parent_id" => nil,
      "depth" => 0,
      "agent_type" => "manager",
      "context_node_path" => ".",
      "objective" => "Build the thing",
      "result" => "final answer text",
      "base_commit" => "base1",
      "final_commit" => "final1",
      "branch_name" => "evogit-agent-T1-A1",
      "archive_ref_start" => "refs/genesis/archive/T1-A1-start",
      "archive_ref_final" => "refs/genesis/archive/T1-A1-final",
      "repo_id" => "primary",
      "repo_root" => "/tmp/repo",
      "repo_path" => "/tmp/repo",
      "usage" => usage,
      "llm_settings" => llm_settings,
      "agent_settings" => agent_settings,
      "foreign_repos" => foreign_repos,
      "compression_count" => 2,
      "started_at" => "2024-05-05T09:00:00.000Z",
      "completed_at" => "2024-05-05T10:00:00.000Z"
    }

    minimal = %{
      "agent_id" => 2,
      "parent_id" => 1,
      "depth" => 1,
      "objective" => "Subtask",
      "result" => "sub answer",
      "final_commit" => "final2",
      "repo_id" => "cowboy"
    }

    # No `depth` / `compression_count` at all — the columns' DEFAULT 0 applies.
    no_counters = %{"agent_id" => 3, "parent_id" => 1, "objective" => "Another"}

    archive_a = Jason.encode!([full, minimal, no_counters])
    archive_b = Jason.encode!([%{"agent_id" => 7, "objective" => "Solo", "result" => "only"}])

    # The result data exactly as the runtime built it: the per-agent archive
    # embedded under `data.archive_records` (the duplicate of the column).
    result_a =
      Jason.encode!(%{
        "__result_tag__" => "ok",
        "data" => %{
          "commit_sha" => "abc123",
          "result" => "short report",
          "branch_name" => "genesis/agent_abc123",
          "archive_records" => [full, minimal, no_counters]
        }
      })

    # Same shape, NO `archive_records` key: must stay byte-identical.
    result_b =
      Jason.encode!(%{
        "__result_tag__" => "ok",
        "data" => %{"commit_sha" => "def456", "result" => "other report"}
      })

    insert_rows!(path, [
      [id: "task-a", result: result_a, archive_metadata: archive_a],
      [id: "task-b", result: result_b, archive_metadata: archive_b],
      [id: "task-corrupt", result: nil, archive_metadata: ~S({"not":"a list"})],
      [id: "task-bad-json", result: nil, archive_metadata: "not json at all"]
    ])

    %{
      archive_a: archive_a,
      archive_b: archive_b,
      plain_result: result_b,
      usage: usage,
      llm_settings: llm_settings,
      agent_settings: agent_settings,
      foreign_repos: foreign_repos
    }
  end

  # The PRE-RELEASE variant of the archive table (`repo_id INTEGER`) with the
  # roster index and four rows: full, sparse, NULL `repo_id`, and a
  # numeric-looking `repo_id` (`"123"`, which the INTEGER affinity coerces to the
  # integer 123 on insert).
  defp seed_pre_release_archives!(path) do
    create_db!(path, [@normalize_archives_version])

    exec_raw!(path, @pre_release_archive_ddl)

    exec_raw!(
      path,
      "CREATE INDEX #{@archive_index} ON #{@archive_table}(task_id, depth, agent_id)"
    )

    insert_archive_rows!(path, [
      [
        "task-legacy",
        1,
        nil,
        0,
        "manager",
        ".",
        "Build the thing",
        "final answer text",
        "base1",
        "final1",
        "evogit-agent-T1-A1",
        "refs/genesis/archive/T1-A1-start",
        "refs/genesis/archive/T1-A1-final",
        "primary",
        "/tmp/repo",
        "/tmp/repo",
        ~S({"input_tokens":10,"output_tokens":5,"total_tokens":15}),
        ~S({"model":"test-model"}),
        ~S({"max_turns":40}),
        "[]",
        2,
        "2024-05-05T09:00:00.000Z",
        "2024-05-05T10:00:00.000Z"
      ],
      [
        "task-legacy",
        2,
        1,
        1,
        "executor",
        "lib",
        "Subtask",
        "sub answer",
        nil,
        "final2",
        nil,
        nil,
        nil,
        "cowboy",
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        0,
        nil,
        nil
      ],
      [
        "task-legacy",
        3,
        1,
        1,
        "executor",
        "lib",
        "Another",
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        0,
        nil,
        nil
      ],
      [
        "task-legacy",
        4,
        1,
        1,
        "executor",
        "lib",
        "Numeric",
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        "123",
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        0,
        nil,
        nil
      ]
    ])

    :ok
  end

  # The CANONICAL (`repo_id TEXT`) table, already correct: the migration must
  # leave it completely alone.
  defp seed_canonical_archives!(path) do
    create_db!(path, [@normalize_archives_version])

    exec_raw!(path, @canonical_archive_ddl)

    exec_raw!(
      path,
      "CREATE INDEX #{@archive_index} ON #{@archive_table}(task_id, depth, agent_id)"
    )

    insert_archive_rows!(path, [
      [
        "task-canonical",
        1,
        nil,
        0,
        "manager",
        ".",
        "Already canonical",
        "done",
        nil,
        "final1",
        nil,
        nil,
        nil,
        "123",
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        0,
        nil,
        nil
      ]
    ])

    :ok
  end

  # Inserts rows in `@archive_projection` order.
  defp insert_archive_rows!(path, rows) do
    placeholders =
      @archive_projection
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_column, index} -> "?#{index}" end)

    statement =
      "INSERT INTO #{@archive_table} (#{Enum.join(@archive_projection, ", ")}) " <>
        "VALUES (#{placeholders})"

    for row <- rows, do: exec_raw!(path, statement, row)
    :ok
  end

  # The canonical 20-column table + `projects` + a `schema_migrations` stamped
  # with everything EXCEPT `pending` — so exactly the migration(s) under test
  # are pending.
  defp create_db!(path, pending) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    for ddl <- [@tasks_ddl, @projects_ddl] do
      {:ok, _} = XqliteNIF.query(conn, ddl, [])
    end

    {:ok, _} =
      XqliteNIF.query(
        conn,
        "CREATE TABLE schema_migrations (version BIGINT PRIMARY KEY, inserted_at TEXT)",
        []
      )

    for version <- @migration_versions -- pending do
      {:ok, _} =
        XqliteNIF.query(
          conn,
          "INSERT INTO schema_migrations (version, inserted_at) VALUES (?1, ?2)",
          [version, "2024-05-05 00:00:00"]
        )
    end

    :ok = XqliteNIF.close(conn)
    :ok
  end

  # Inserts task rows into an EXISTING fixture database.
  defp insert_rows!(path, rows) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    defaults = [
      type: "genesis",
      status: "completed",
      opts: ~S({"mode":"new","path":"/tmp/archive-migration"}),
      started_at: "2024-05-05T09:00:00.000Z",
      finished_at: "2024-05-05T10:00:00.000Z",
      logs: "[]",
      result: nil,
      review_status: "open",
      usage: nil,
      agent_count: 1,
      base_sha: nil,
      commit_sha: nil,
      archive_metadata: nil,
      lease_expires_at: nil,
      model_id: nil,
      project_path: "/tmp/archive-migration",
      branch_name: nil,
      error: nil,
      updated_at: @updated_at
    ]

    columns = [:id | Keyword.keys(defaults)]
    placeholders = columns |> Enum.with_index(1) |> Enum.map_join(", ", fn {_c, i} -> "?#{i}" end)

    insert_sql =
      "INSERT INTO tasks (#{Enum.map_join(columns, ", ", &Atom.to_string/1)}) " <>
        "VALUES (#{placeholders})"

    for row <- rows do
      merged = Keyword.merge(defaults, row)
      values = Enum.map(columns, &Keyword.fetch!(merged, &1))
      {:ok, _} = XqliteNIF.query(conn, insert_sql, values)
    end

    :ok = XqliteNIF.close(conn)
    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Boots a dynamic repo (running the pending migration(s)) and unlinks it:
  # the `on_exit` guard runs after the test process is gone.
  defp start_repo!(path) do
    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)
    pid
  end

  # A uniquely-named `EvoGit.Store` over an ALREADY-MIGRATED database file — the
  # facade the dashboard/RPC layers actually call. It boots its OWN dynamic repo
  # on the same file (every migration is recorded, so nothing runs).
  defp start_store!(path) do
    unique =
      "#{System.pid()}_#{System.system_time(:millisecond)}_" <>
        "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}"

    name = :"archive_migration_store_#{unique}"
    {:ok, pid} = Store.start_link(data_dir: path, name: name, pool_size: 1)
    Process.unlink(pid)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000), else: :ok end)

    name
  end

  defp migration_versions(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows
      |> Enum.map(&hd/1)
    end)
  end

  defp clear_version!(pid, version) do
    sql!(pid, "DELETE FROM schema_migrations WHERE version = ?", [version])
  end

  defp sql!(pid, statement, params) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!(statement, params, log: false)
      :ok
    end)
  end

  defp archive_rows(pid, task_id) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!(
        "SELECT #{Enum.join(@archive_projection, ", ")} FROM #{@archive_table} " <>
          "WHERE task_id = ? ORDER BY agent_id",
        [task_id],
        log: false
      ).rows
    end)
  end

  # ONE archive row as a STRING-KEYED map, with the JSON columns DECODED (map
  # key order can never make an assertion flaky).
  defp archive_entry(rows, agent_id) do
    row = Enum.find(rows, fn [_task_id, id | _rest] -> id == agent_id end)

    @archive_projection
    |> Enum.zip(row)
    |> Map.new()
    |> Map.new(fn {column, value} ->
      if column in @json_columns and is_binary(value) do
        {column, Jason.decode!(value)}
      else
        {column, value}
      end
    end)
  end

  defp column_names(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!("PRAGMA table_info(tasks)").rows
      |> Enum.map(fn [_cid, name | _rest] -> name end)
    end)
  end

  # Column names read with RAW xqlite — usable BEFORE any repo is booted.
  defp column_names!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "PRAGMA table_info(tasks)", [])
    :ok = XqliteNIF.close(conn)
    Enum.map(rows, fn [_cid, name | _rest] -> name end)
  end

  # Raw xqlite read of ONE column of ONE row — the ground truth on disk,
  # independent of the repo/codec.
  defp raw!(path, id, column) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: [[value]]}} =
      XqliteNIF.query(conn, "SELECT #{column} FROM tasks WHERE id = ?1", [id])

    :ok = XqliteNIF.close(conn)
    value
  end

  # Every (id, result, logs, archive_metadata) value on disk, keyed by
  # `{id, column}` — used to prove byte-identity across a boot. Requires the
  # PRE-DROP table shape.
  defp snapshot!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT id, result, logs, archive_metadata FROM tasks", [])

    :ok = XqliteNIF.close(conn)

    for [id, result, logs, archive] <- rows,
        {column, value} <- [{"result", result}, {"logs", logs}, {"archive_metadata", archive}],
        into: %{},
        do: {{id, column}, value}
  end

  # ── archive-table raw helpers (`…009`) ────────────────────────────────────

  # A statement against the file through RAW xqlite (usable before/independently
  # of any repo), returning the result rows.
  defp query_raw!(path, statement, params \\ []) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, statement, params)
    :ok = XqliteNIF.close(conn)
    rows
  end

  defp exec_raw!(path, statement, params \\ []) do
    _rows = query_raw!(path, statement, params)
    :ok
  end

  # `PRAGMA table_info(task_agent_archives)` read with RAW xqlite.
  defp archive_table_info_raw!(path) do
    query_raw!(path, "PRAGMA table_info(#{@archive_table})")
  end

  defp archive_table_type!(path, column) do
    Enum.find_value(archive_table_info_raw!(path), fn [_cid, name, type | _rest] ->
      if name == column, do: type
    end)
  end

  # ONE column of ONE archive row, read with RAW xqlite — the ground truth on
  # disk (the affinity coercion is only observable there).
  defp raw_archive_value!(path, task_id, agent_id, column) do
    [[value]] =
      query_raw!(
        path,
        "SELECT #{column} FROM #{@archive_table} WHERE task_id = ?1 AND agent_id = ?2",
        [task_id, agent_id]
      )

    value
  end

  # Every archive row on disk, in `@archive_projection` order — the shape a
  # "nothing was rebuilt" assertion compares.
  defp raw_archive_rows!(path) do
    query_raw!(
      path,
      "SELECT #{Enum.join(@archive_projection, ", ")} FROM #{@archive_table} " <>
        "ORDER BY task_id, agent_id"
    )
  end

  # `PRAGMA table_info(task_agent_archives)` through the booted repo.
  defp archive_table_info(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!("PRAGMA table_info(#{@archive_table})").rows
    end)
  end

  # The columns the roster index covers, via the booted repo.
  defp archive_index_columns(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!("PRAGMA index_info(#{@archive_index})").rows
      |> Enum.map(fn [_seqno, _cid, column] -> column end)
    end)
  end

  # The same, for a database whose `archive_metadata` column is already gone.
  defp data_snapshot!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT id, result, logs, opts, branch_name FROM tasks", [])

    :ok = XqliteNIF.close(conn)
    Enum.sort(rows)
  end

  defp updated_at_map!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "SELECT id, updated_at FROM tasks", [])
    :ok = XqliteNIF.close(conn)
    Map.new(rows, fn [id, updated_at] -> {id, updated_at} end)
  end

  # The rejected on-disk format: `"z1:" <> Base64(zlib(json))`.
  defp packed(plain), do: "z1:" <> Base.encode64(:zlib.compress(plain))

  defp packed?(value), do: is_binary(value) and String.starts_with?(value, "z1:")
end
