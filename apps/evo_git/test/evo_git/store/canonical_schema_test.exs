defmodule EvoGit.Store.CanonicalSchemaTest do
  @moduledoc """
  A FRESH database must end up with EXACTLY the final schema — nothing that was
  created and later dropped.

  The migration chain serves two audiences at once: a new install (where every
  adopt / fan-out / prune step must be a no-op) and any database an older
  release left behind. This suite pins the FIRST one, which is what makes the
  "one schema-creating migration" property observable instead of merely
  intended:

    * SCHEMA — `tasks` has exactly the 19 canonical columns in canonical order
      and NEVER `archive_metadata`; `task_agent_archives` has exactly its 23
      declared columns (`repo_id` TEXT) plus its roster index;
      `projects` has exactly its three columns; `tasks` carries exactly the SIX
      final `idx_tasks_*` indexes and NONE of the four redundant ones.
    * STATEMENTS — the SQL a fresh boot ACTUALLY executes (captured off the
      repo's `[:evo_git, :repo, :query]` telemetry) mentions `archive_metadata`
      nowhere: no `CREATE` carrying it, no fan-out `SELECT`/`INSERT`, no
      `ALTER TABLE tasks DROP COLUMN`. The whole legacy-archive path is skipped
      on a new install. The prune step's four `DROP INDEX IF EXISTS` statements
      DO run — that is the documented O(1) convergence no-op on a database
      where those indexes never existed.
    * IDEMPOTENCY — a second `Boot.run_migrations/1` reports nothing pending and
      leaves a byte-identical snapshot (schema + `schema_migrations` rows).

  Every test boots its own UNNAMED dynamic repo on a unique tmp database file
  (`async: true` is safe: each test owns its file, and `EvoGit.Store.Boot`
  serializes concurrent migration runs behind its `:global` lock).

  ## Telemetry attribution

  The `[:evo_git, :repo, :query]` handler is BEAM-wide while attached, and
  sibling `async: true` suites (`archive_migration_test.exs`, the boot-migration
  suites, `v0138_upgrade_path_test.exs`) boot LEGACY databases whose migration
  runs DO mention `archive_metadata`. Captured statements are therefore
  attributed before anything is asserted on them. `metadata.repo` cannot
  discriminate (`EvoGit.Repo` is the reported repo for EVERY dynamic instance —
  the instance identity is the dynamic-repo pid, which the telemetry does not
  carry), so the discriminator is the emitting PROCESS: the test process itself
  (it runs some statements, e.g. the `schema_migrations` reads) or one of its
  `$ancestors` descendants (`Ecto.Migrator` runs each migration body in its own
  spawned process). The handler runs INSIDE the emitting process, so both
  checks read that process's own state.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskAgentArchiveRow
  alias EvoGit.Store.Schemas.TaskRow

  # The six shipped migrations, contiguous versions 1..6.
  @migration_versions [
    20_260_815_000_001,
    20_260_815_000_002,
    20_260_815_000_003,
    20_260_815_000_004,
    20_260_815_000_005,
    20_260_815_000_006
  ]

  # `PRAGMA table_info(tasks)` — [cid, name, type, notnull, dflt_value, pk] —
  # EXACTLY as the baseline migration's CREATE TABLE declares it (cid is a
  # contiguous 0..18: no column is ever added or dropped on this path).
  @task_table_info_rows [
    [0, "id", "TEXT", 0, nil, 1],
    [1, "type", "TEXT", 0, nil, 0],
    [2, "status", "TEXT", 1, nil, 0],
    [3, "opts", "TEXT", 0, nil, 0],
    [4, "started_at", "TEXT", 0, nil, 0],
    [5, "finished_at", "TEXT", 0, nil, 0],
    [6, "logs", "TEXT", 0, nil, 0],
    [7, "result", "TEXT", 0, nil, 0],
    [8, "review_status", "TEXT", 0, nil, 0],
    [9, "usage", "TEXT", 0, nil, 0],
    [10, "agent_count", "INTEGER", 0, nil, 0],
    [11, "base_sha", "TEXT", 0, nil, 0],
    [12, "commit_sha", "TEXT", 0, nil, 0],
    [13, "lease_expires_at", "INTEGER", 0, nil, 0],
    [14, "model_id", "TEXT", 0, nil, 0],
    [15, "project_path", "TEXT", 0, nil, 0],
    [16, "branch_name", "TEXT", 0, nil, 0],
    [17, "error", "TEXT", 0, nil, 0],
    [18, "updated_at", "TEXT", 0, nil, 0]
  ]

  # `PRAGMA table_info(task_agent_archives)` — the 23 columns in DECLARED order.
  # `depth`/`compression_count` are the two `NOT NULL DEFAULT 0` counters (the
  # default is reported as the STRING "0"), and SQLite numbers the composite
  # primary key in declaration order (task_id 1, agent_id 2).
  @archive_table_info_rows [
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

  @archive_table "task_agent_archives"
  @archive_index_name "task_agent_archives_task_depth_idx"
  @archive_pk_autoindex "sqlite_autoindex_task_agent_archives_1"

  # The retired `tasks` column the whole archive path used to hang off. A fresh
  # database must never create it (and therefore never drop it either).
  @retired_task_column "archive_metadata"

  # The FINAL `tasks` index set — exactly six named indexes.
  @final_task_indexes ~w(idx_tasks_updated_at idx_tasks_started_at
                         idx_tasks_status_started_at idx_tasks_project_path_started_at
                         idx_tasks_status_updated_at_id idx_tasks_finished_at_id)

  # The four single-column indexes `20260815000006_prune_redundant_indexes`
  # drops. On a fresh database they never existed, so its statements are
  # `IF EXISTS` no-ops — and must never be preceded by a `CREATE` of them.
  @redundant_task_indexes ~w(idx_tasks_status idx_tasks_finished_at
                             idx_tasks_project_path idx_tasks_lease_expires_at)

  # SQLite's implicit UNIQUE backing index for the tasks TEXT PK.
  @tasks_pk_autoindex "sqlite_autoindex_tasks_1"

  # ── Fixtures / helpers ───────────────────────────────────────────────────

  # A fresh, UNNAMED dynamic repo on a unique tmp database file. It is
  # UNLINKED because `on_exit/1` callbacks run after the test process exits, so
  # the link's exit signal must not own the shutdown; `stop_quietly/1` keeps a
  # test that stopped its instance manually from hitting "no process".
  defp boot_fresh!(tag) do
    path = db_path(tag)
    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)

    on_exit(fn ->
      stop_quietly(pid)
      remove_db(path)
    end)

    pid
  end

  # The name embeds the OS pid + wall-clock ms on top of the per-BEAM unique
  # integer + test pid: `System.unique_integer/1` restarts in every BEAM and
  # test pids are deterministic across runs, so without those a PREVIOUS run's
  # stale tmp file would be silently adopted.
  defp db_path(tag) do
    unique = System.unique_integer([:positive, :monotonic])

    Path.join(
      System.tmp_dir!(),
      "evogit_canonical_#{tag}_#{:os.getpid()}_#{System.system_time(:millisecond)}_" <>
        "#{unique}_#{inspect(self())}.sqlite"
    )
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: :ok = Boot.stop(pid), else: :ok
  end

  # Removes the tmp database AND its WAL sidecars (`File.rm/1` is a no-op for a
  # path that is already gone).
  defp remove_db(path) do
    File.rm(path)
    File.rm(path <> "-wal")
    File.rm(path <> "-shm")
  end

  defp query!(pid, sql), do: RepoScope.with_repo(pid, fn -> Repo.query!(sql) end)

  defp query_rows(pid, sql), do: query!(pid, sql).rows

  defp column_names(pid, table) do
    pid
    |> query_rows("PRAGMA table_info(#{table})")
    |> Enum.map(fn [_cid, name | _] -> name end)
  end

  # Everything a migration run may legitimately change: the schema (tables,
  # indexes and their DDL) plus the migrator's own bookkeeping rows.
  defp db_snapshot(pid) do
    {
      query_rows(pid, "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"),
      query_rows(pid, "SELECT version, inserted_at FROM schema_migrations ORDER BY version")
    }
  end

  # ── The SQL a boot executes, attributed to THIS test ──────────────────────

  # Returns `{statements, emitters, fun_result}` — every statement `fun`
  # executes, in emission order, plus the processes that emitted them,
  # restricted to the processes attributable to this test (see the moduledoc's
  # "Telemetry attribution").
  defp capture_statements(fun) do
    test_pid = self()
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:evo_git, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if attributed_to?(test_pid), do: send(test_pid, {:captured_sql, metadata.query, self()})
      end,
      nil
    )

    try do
      result = fun.()
      {statements, emitters} = drain_statements([], [])
      {statements, emitters, result}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_statements(statements, emitters) do
    receive do
      {:captured_sql, sql, emitter} ->
        drain_statements([sql | statements], [emitter | emitters])
    after
      0 -> {Enum.reverse(statements), emitters |> Enum.reverse() |> Enum.uniq()}
    end
  end

  # Runs in the EMITTING process: the test process itself, or a descendant it
  # spawned (`$ancestors` names the whole spawn chain — `Ecto.Migrator` runs
  # each migration body in its own spawned process, so those count too).
  defp attributed_to?(test_pid) do
    self() == test_pid or test_pid in ancestors()
  end

  defp ancestors do
    case :erlang.process_info(self(), :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, :"$ancestors", [])
      _other -> []
    end
  end

  defp statements_matching(statements, regex) do
    Enum.filter(statements, &(&1 =~ regex))
  end

  # ── Migration bookkeeping ────────────────────────────────────────────────

  describe "migration set" do
    test "a fresh boot stamps exactly the six shipped, contiguous versions" do
      pid = boot_fresh!(:versions)

      assert pid
             |> query_rows("SELECT version FROM schema_migrations ORDER BY version")
             |> Enum.map(fn [version] -> version end) == @migration_versions

      assert RepoScope.with_repo(pid, fn -> Ecto.Migrator.migrated_versions(Repo) end) ==
               @migration_versions
    end

    test "a second boot migrates nothing and leaves a byte-identical snapshot" do
      pid = boot_fresh!(:idempotent)
      snapshot = db_snapshot(pid)

      assert Boot.run_migrations(pid) == []
      assert db_snapshot(pid) == snapshot
    end

    test "a second boot executes no DDL at all" do
      pid = boot_fresh!(:second_boot)

      {statements, _emitters, []} = capture_statements(fn -> Boot.run_migrations(pid) end)

      # The migrator still READS its bookkeeping (that is what tells it nothing
      # is pending) and re-asserts its OWN table on every run — that bootstrap
      # is the only DDL a no-op run may emit; no store object is touched.
      assert statements != []

      assert [bookkeeping] =
               statements_matching(statements, ~r/^\s*(CREATE|ALTER|DROP)\b/i)

      assert bookkeeping =~ ~r/CREATE TABLE IF NOT EXISTS "schema_migrations"/
    end
  end

  # ── tasks: the final 19-column shape ─────────────────────────────────────

  describe "tasks table" do
    test "PRAGMA table_info is exactly the 19 canonical columns, cids 0..18" do
      pid = boot_fresh!(:tasks_shape)

      rows = query_rows(pid, "PRAGMA table_info(tasks)")

      assert rows == @task_table_info_rows
      assert Enum.map(rows, fn [cid | _rest] -> cid end) == Enum.to_list(0..18)
      assert Enum.map(rows, fn [_cid, name | _rest] -> name end) == TaskRow.columns()
    end

    test "the retired archive_metadata column is never created" do
      pid = boot_fresh!(:no_archive_column)

      refute @retired_task_column in column_names(pid, "tasks")

      # Not merely absent from PRAGMA table_info: the stored CREATE TABLE text
      # never carried it either (a create-then-drop would still be visible in
      # the emitted statements, asserted separately below).
      [[ddl]] =
        query_rows(pid, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'tasks'")

      refute ddl =~ @retired_task_column
    end
  end

  # ── tasks: the final six indexes, and only those ──────────────────────────

  describe "tasks indexes" do
    test "PRAGMA index_list reports exactly the six final indexes plus the PK autoindex" do
      pid = boot_fresh!(:task_indexes)

      rows = query_rows(pid, "PRAGMA index_list(tasks)")
      names = Enum.map(rows, fn [_seq, name | _rest] -> name end)

      assert MapSet.new(names) == MapSet.new(@final_task_indexes ++ [@tasks_pk_autoindex])

      for [_seq, name, unique, origin, partial] <- rows, name in @final_task_indexes do
        assert unique == 0
        assert origin == "c"
        assert partial == 0
      end

      for redundant <- @redundant_task_indexes do
        refute redundant in names
      end
    end

    test "sqlite_master lists exactly the six idx_tasks_* indexes" do
      pid = boot_fresh!(:task_index_inventory)

      assert query_rows(
               pid,
               "SELECT name FROM sqlite_master WHERE type = 'index' " <>
                 "AND tbl_name = 'tasks' AND name LIKE 'idx_tasks_%' ORDER BY name"
             ) ==
               Enum.map(Enum.sort(@final_task_indexes), &[&1])
    end
  end

  # ── task_agent_archives: the 23-column relational archive ────────────────

  describe "task_agent_archives table" do
    test "PRAGMA table_info is exactly the 23 declared columns with repo_id TEXT" do
      pid = boot_fresh!(:archive_shape)

      rows = query_rows(pid, "PRAGMA table_info(#{@archive_table})")

      assert rows == @archive_table_info_rows

      assert Enum.map(rows, fn [_cid, name | _rest] -> name end) ==
               TaskAgentArchiveRow.columns()

      # A repo ID STRING ("primary" or a foreign repo id) — never an integer.
      assert for([_cid, "repo_id", type | _rest] <- rows, do: type) == ["TEXT"]
    end

    test "the roster index is a plain non-unique index on (task_id, depth, agent_id)" do
      pid = boot_fresh!(:archive_index)

      rows = query_rows(pid, "PRAGMA index_list(#{@archive_table})")
      names = Enum.map(rows, fn [_seq, name | _rest] -> name end)

      assert MapSet.new(names) == MapSet.new([@archive_index_name, @archive_pk_autoindex])

      for [_seq, name, unique, origin, partial] <- rows, name == @archive_index_name do
        assert unique == 0
        assert origin == "c"
        assert partial == 0
      end

      assert query_rows(pid, "PRAGMA index_info(#{@archive_index_name})")
             |> Enum.map(fn [_seqno, _cid, column] -> column end) == [
               "task_id",
               "depth",
               "agent_id"
             ]
    end
  end

  # ── projects: untouched by the archive work ──────────────────────────────

  describe "projects table" do
    test "exactly path, name and last_opened_at, with path the TEXT primary key" do
      pid = boot_fresh!(:projects)

      assert query_rows(pid, "PRAGMA table_info(projects)") == [
               [0, "path", "TEXT", 0, nil, 1],
               [1, "name", "TEXT", 0, nil, 0],
               [2, "last_opened_at", "TEXT", 0, nil, 0]
             ]
    end
  end

  # ── No create-then-drop: what a fresh boot actually EXECUTES ─────────────

  describe "fresh boot statements" do
    test "no executed statement mentions archive_metadata" do
      {statements, emitters, _pid} =
        capture_statements(fn -> boot_fresh!(:statements_no_archive) end)

      # Non-vacuity, both ways round: the stream must have been captured at all,
      # AND it must have been attributed across processes — the whole migration
      # DDL is emitted by `Ecto.Migrator`'s per-migration child processes, so a
      # capture limited to the test process alone would see no DDL and let this
      # negative assertion pass without ever looking at the schema work.
      assert length(statements) > 20
      assert self() in emitters
      assert length(emitters) > 1

      # The ONE schema-creating step: exactly one `tasks` CREATE, one archive
      # CREATE — and no statement anywhere that so much as names the retired
      # column (neither a CREATE carrying it nor an
      # `ALTER TABLE tasks DROP COLUMN archive_metadata`).
      assert length(statements_matching(statements, ~r/CREATE TABLE IF NOT EXISTS tasks/)) == 1

      assert length(
               statements_matching(statements, ~r/CREATE TABLE IF NOT EXISTS task_agent_archives/)
             ) == 1

      assert statements_matching(statements, ~r/#{@retired_task_column}/) == []
    end

    test "the legacy archive fan-out never runs (no fan-out SELECT/INSERT, no ALTER)" do
      {statements, _emitters, _pid} =
        capture_statements(fn -> boot_fresh!(:statements_no_fanout) end)

      # No column adoption and no column drop anywhere on a fresh database.
      assert statements_matching(statements, ~r/^\s*ALTER\s+TABLE/i) == []

      # The fan-out's own statements: reading tasks that still hold an archive,
      # inserting into the new table, nulling the old column.
      assert statements_matching(
               statements,
               ~r/#{@archive_table}[^;]*INSERT|INSERT[^;]*#{@archive_table}/i
             ) ==
               []

      assert statements_matching(statements, ~r/SELECT\s+id\s+FROM\s+tasks/i) == []
    end

    test "the prune step runs its four DROP INDEX IF EXISTS convergence no-ops" do
      {statements, _emitters, _pid} =
        capture_statements(fn -> boot_fresh!(:statements_prune) end)

      for name <- @redundant_task_indexes do
        assert "DROP INDEX IF EXISTS #{name}" in statements
      end

      # …and they are pure no-ops because no statement ever CREATEd them: the
      # baseline only creates the final six.
      for name <- @redundant_task_indexes do
        assert statements_matching(statements, ~r/CREATE\s+INDEX[^;]*\b#{name}\b/) == []
      end

      # Every statement the boot ran is a known shape — no table rebuild at all.
      assert statements_matching(statements, ~r/CREATE\s+TABLE(?!\s+IF\s+NOT\s+EXISTS)/) == []
    end
  end
end
