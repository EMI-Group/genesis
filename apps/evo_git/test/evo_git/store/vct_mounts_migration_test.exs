defmodule EvoGit.Store.VctMountsMigrationTest do
  @moduledoc """
  `20260815000007_vct_mounts` — the migration that puts the Virtual Context Tree
  (VCT) mount table into SQLite and retires the legacy `projects` table.

  Three audiences, one suite:

    * a LEGACY database (a release that still shipped `projects` rows) → every
      usable row is carried into `vct_mounts`, the table is DROPPED, and the
      result is capped to the 100 newest mounts; unusable rows are skipped
    * a RELEASED v0.14.1 database (`schema_migrations` stamped with versions
      1..6, which Ecto therefore never re-runs) → version 7 is the ONLY pending
      migration, carries the rows over the same way, and drops `projects`; an
      unreadable `projects` table instead ABORTS the migration, leaving both
      the table and its rows (and version 7 pending) intact
    * a FRESH database → `vct_mounts` exists with its five columns and
      `projects` NEVER appears in `sqlite_master` (the baseline migration no
      longer creates it)

  The fixtures are crafted with RAW xqlite, so they stay independent of the
  migration modules (`v0138_upgrade_path_test.exs` / `boot_migration_test.exs`
  style): the `projects` DDL below is the pre-VCT release's own shape.

  ## Pinned fan-out rules

    * ORDER — newest first (`last_opened_at` DESC, NULLs last, `path` ASC as the
      deterministic tie-break), so a `-N` suffix is assigned to the OLDER
      collision
    * POINT — `vct:///projects/<basename>`, every `/` and `\\` in the segment
      replaced by `-`, collisions suffixed `-2`, `-3`, …
    * NAME — a non-blank stored display name is preserved, otherwise the
      basename
    * SKIP — a missing, blank or non-absolute `path` is logged and never
      inserted
    * CAP — at most 100 rows survive (the VCT's own default `max_projects/0`)
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.RepoScope

  # The pre-VCT `projects` table, exactly as a released database carries it.
  @projects_ddl """
  CREATE TABLE projects (
    path TEXT PRIMARY KEY,
    name TEXT,
    last_opened_at TEXT
  )
  """

  # A legacy `tasks` shape `20260815000001_baseline_adoption` adopts (the
  # v0.5.0-v0.5.1 prefix): present so the boot exercises the REAL chain instead
  # of a projects-only file.
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
    lease_expires_at INTEGER
  )
  """

  @mount_columns ~w(point path name kind last_opened_at)

  # ── The released v0.14.1 upgrade fixture ─────────────────────────────────
  #
  # v0.14.1 shipped exactly the six migrations BELOW version 7, so a real
  # v0.14.1 `schema_migrations` carries these rows and Ecto never re-runs them:
  # the ONLY pending work on such a database is `…00007_vct_mounts`.
  @released_versions [
    20_260_815_000_001,
    20_260_815_000_002,
    20_260_815_000_003,
    20_260_815_000_004,
    20_260_815_000_005,
    20_260_815_000_006
  ]

  @vct_version 20_260_815_000_007

  # The `tasks` table v0.14.1 shipped: the FINAL 19 columns in canonical order
  # (`…00001` created it that way and `…00005` had already dropped
  # `archive_metadata`).
  @released_tasks_ddl """
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
    lease_expires_at INTEGER,
    model_id TEXT,
    project_path TEXT,
    branch_name TEXT,
    error TEXT,
    updated_at TEXT
  )
  """

  @released_task_columns ~w(id type status opts started_at finished_at logs result review_status
                            usage agent_count base_sha commit_sha lease_expires_at model_id
                            project_path branch_name error updated_at)

  # The six final `tasks` indexes a v0.14.1 database already carries
  # (`…00006` had pruned the four redundant ones).
  @released_task_indexes [
    {"idx_tasks_updated_at", "updated_at"},
    {"idx_tasks_started_at", "started_at"},
    {"idx_tasks_status_started_at", "status, started_at"},
    {"idx_tasks_project_path_started_at", "project_path, started_at"},
    {"idx_tasks_status_updated_at_id", "status, updated_at, id"},
    {"idx_tasks_finished_at_id", "finished_at, id"}
  ]

  # The `task_agent_archives` shape v0.14.1 shipped (`…00005`'s CREATE).
  @release_archive_ddl """
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

  @released_archive_index "task_agent_archives_task_depth_idx"

  # Ecto's OWN `schema_migrations` DDL, byte-identical to what
  # `Ecto.Migration.SchemaMigration.ensure_schema_migrations_table!/3` emits
  # through `xqlite_ecto3` (read back from `sqlite_master` on a fresh boot):
  # a `bigint` version primary key plus the `inserted_at` timestamp.
  @schema_migrations_ddl """
  CREATE TABLE "schema_migrations" ("version" INTEGER PRIMARY KEY, "inserted_at" TEXT)
  """

  # A `projects` table whose columns are NOT the released shape: selecting
  # `last_opened_at` from it fails, which must ABORT the migration.
  @broken_projects_ddl """
  CREATE TABLE projects (
    path TEXT PRIMARY KEY,
    name TEXT
  )
  """

  # The fan-out fixture, shared by the pre-Ecto and the released-v0.14.1
  # cases: the SAME rows must derive the SAME mounts on either upgrade path.
  @legacy_rows [
    # Two different paths with the same basename: the point collides and
    # the NEWER row keeps the unsuffixed point.
    {"/home/user/projects/demo", "demo", "2025-01-04T00:00:00.000Z"},
    {"/home/user/other/demo", "  ", "2025-01-03T00:00:00.000Z"},
    # A non-blank stored display name wins over the basename.
    {"/home/user/projects/legacy", "Legacy Display", "2025-01-02T00:00:00.000Z"},
    # A NULL timestamp sorts last, exactly like a never-opened mount.
    {"/home/user/projects/last", nil, nil},
    # Unusable: relative, blank, missing and whitespace-only paths never
    # become a mount.
    {"relative/path", "rel", "2025-01-09T00:00:00.000Z"},
    {"", "blank", "2025-01-08T00:00:00.000Z"},
    {"   ", "spaces", "2025-01-07T00:00:00.000Z"}
  ]

  @expected_mounts [
    [
      "vct:///projects/demo",
      "/home/user/projects/demo",
      "demo",
      "git",
      "2025-01-04T00:00:00.000Z"
    ],
    [
      "vct:///projects/demo-2",
      "/home/user/other/demo",
      "demo",
      "git",
      "2025-01-03T00:00:00.000Z"
    ],
    ["vct:///projects/last", "/home/user/projects/last", "last", "git", nil],
    [
      "vct:///projects/legacy",
      "/home/user/projects/legacy",
      "Legacy Display",
      "git",
      "2025-01-02T00:00:00.000Z"
    ]
  ]

  # A released `schema_migrations` timestamp (`:naive_datetime` TEXT).
  @stamped_at "2026-08-15 00:00:00"

  setup do
    stamp =
      "#{System.system_time(:millisecond)}_#{:os.getpid()}_#{System.unique_integer([:positive])}"

    root = Path.join(System.tmp_dir!(), "evogit_vct_mig_#{stamp}_#{inspect(self())}")

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, %{root: root}}
  end

  # ── (a) legacy projects rows ───────────────────────────────────────────────

  describe "a legacy database with projects rows" do
    test "derives the mount rows, preserves names, skips unusable rows and drops projects",
         %{root: root} do
      path = Path.join(root, "legacy.sqlite")

      build_legacy_db!(path, @legacy_rows)

      # Ground truth BEFORE boot: the fixture really carries the legacy table.
      assert File.exists?(path)
      assert "projects" in raw_table_names!(path)

      pid = start_booted_repo!(path)

      # Every usable row, in point order, with its derived point/name.
      assert mount_rows(pid) == @expected_mounts

      # The legacy table is GONE (post-condition of the migration), and the
      # fresh mount table carries exactly its five canonical columns.
      refute "projects" in table_names(pid)
      assert column_names(pid, "vct_mounts") == @mount_columns
    end

    test "caps the fan-out at the 100 NEWEST mounts", %{root: root} do
      path = Path.join(root, "cap.sqlite")

      # 120 legacy rows, oldest first: `project-001` is the oldest and
      # `project-120` the newest, with distinct basenames so no `-N` suffix is
      # involved and the cap is the only thing that removes rows.
      rows =
        for index <- 1..120 do
          stamp = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
          opened_at = DateTime.add(stamp, index * 60, :second) |> DateTime.to_iso8601()

          {"/legacy/project-#{pad(index)}", "project-#{pad(index)}", opened_at}
        end

      build_legacy_db!(path, rows)

      pid = start_booted_repo!(path)

      points = mount_rows(pid) |> Enum.map(&hd/1)

      assert length(points) == 100
      # The 100 NEWEST survive: 021..120.
      assert "vct:///projects/project-120" in points
      assert "vct:///projects/project-021" in points
      refute "vct:///projects/project-020" in points
      refute "vct:///projects/project-001" in points
      refute "projects" in table_names(pid)
    end
  end

  # ── (b) released v0.14.1 database ─────────────────────────────────────────
  #
  # v0.14.1 stamped versions 1..6 and shipped the `projects` table, so the
  # ONLY migration such a database still runs is `…00007_vct_mounts`. Ecto
  # tracks version numbers only (no checksums), so the five already-applied
  # versions can never re-run and must not be "repaired" by this fixture.

  describe "a released v0.14.1 database" do
    test "applies only version 7 and derives the mounts from its projects rows", %{root: root} do
      path = Path.join(root, "released.sqlite")
      build_released_db!(path, @legacy_rows)

      # Ground truth BEFORE boot: a genuine v0.14.1 file — the six shipped
      # versions, the legacy `projects` table with rows, no `vct_mounts`.
      assert Enum.sort(raw_table_names!(path)) ==
               ["projects", "schema_migrations", "task_agent_archives", "tasks"]

      assert raw_migration_versions!(path) == @released_versions

      pid = start_repo!(path)

      # EXACTLY one migration is pending, and it is the VCT one.
      assert Boot.run_migrations(pid) == [@vct_version]

      assert migration_versions(pid) == @released_versions ++ [@vct_version]

      # The SAME fan-out rules the pre-Ecto fixture pins: newest first, `-N`
      # suffixes on collisions, stored display names preserved, NULL
      # timestamps last, unusable paths skipped.
      assert mount_rows(pid) == @expected_mounts

      # The legacy table is dropped and the mount table carries its five
      # canonical columns.
      refute "projects" in table_names(pid)
      assert column_names(pid, "vct_mounts") == @mount_columns

      # Nothing else moved: the released `tasks`/archive shapes and the final
      # six-index set are exactly what v0.14.1 already had.
      assert column_names(pid, "tasks") == @released_task_columns

      assert index_names(pid, "tasks") ==
               Enum.sort(Enum.map(@released_task_indexes, &elem(&1, 0)))

      assert index_names(pid, "task_agent_archives") == [@released_archive_index]

      assert column_names(pid, "task_agent_archives") ==
               ~w(task_id agent_id parent_id depth agent_type context_node_path objective
                  result base_commit final_commit branch_name archive_ref_start
                  archive_ref_final repo_id repo_root repo_path usage llm_settings
                  agent_settings foreign_repos compression_count started_at completed_at)
    end

    test "an EMPTY legacy projects table upgrades to an empty mount table", %{root: root} do
      path = Path.join(root, "released_empty.sqlite")
      build_released_db!(path, [])

      assert raw_migration_versions!(path) == @released_versions
      assert "projects" in raw_table_names!(path)

      pid = start_repo!(path)

      # The majority of real users: nothing to carry over, so version 7 still
      # creates the table, drops the empty legacy one and stamps itself.
      assert Boot.run_migrations(pid) == [@vct_version]

      assert mount_rows(pid) == []
      refute "projects" in table_names(pid)
      assert column_names(pid, "vct_mounts") == @mount_columns
      assert migration_versions(pid) == @released_versions ++ [@vct_version]
    end

    test "an unreadable legacy projects table ABORTS the migration and survives", %{root: root} do
      path = Path.join(root, "released_broken.sqlite")

      # A `projects` table without `last_opened_at`: the fan-out's read cannot
      # be executed. Reporting "no rows" here would DROP the user's table, so
      # the read must raise and roll the whole migration back.
      build_released_db!(path, [], @broken_projects_ddl)

      raw_exec!(path, "INSERT INTO projects (path, name) VALUES (?1, ?2)", [
        "/home/user/projects/demo",
        "demo"
      ])

      pid = start_repo!(path)

      assert_raise XqliteEcto3.Error, ~r/no such column: last_opened_at/, fn ->
        Boot.run_migrations(pid)
      end

      # The transaction rolled back: the legacy table AND its row survive, the
      # half-built mount table is gone and version 7 stays PENDING (so the
      # next boot retries it once the shape is fixed).
      assert "projects" in table_names(pid)
      refute "vct_mounts" in table_names(pid)

      assert query_rows(pid, "SELECT path, name FROM projects") == [
               ["/home/user/projects/demo", "demo"]
             ]

      assert migration_versions(pid) == @released_versions
    end
  end

  # ── (c) fresh database ────────────────────────────────────────────────────

  describe "a fresh database" do
    test "creates vct_mounts and never creates projects", %{root: root} do
      path = Path.join(root, "fresh.sqlite")
      refute File.exists?(path)

      pid = start_booted_repo!(path)

      refute "projects" in table_names(pid)
      assert column_names(pid, "vct_mounts") == @mount_columns
      assert mount_rows(pid) == []
    end
  end

  # ── Fixtures / helpers ────────────────────────────────────────────────────

  defp pad(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")

  # Raw xqlite: a legacy `tasks` table, the pre-VCT `projects` table with the
  # given `{path, name, last_opened_at}` rows, and NO `schema_migrations` (so
  # the whole chain runs, exactly like a pre-Ecto release left it on disk).
  defp build_legacy_db!(path, project_rows) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)
    exec!(conn, @tasks_ddl)
    exec!(conn, @projects_ddl)
    insert_projects!(conn, project_rows)
    :ok = XqliteNIF.close(conn)
    :ok
  end

  # Raw xqlite: a RELEASED v0.14.1 file — the final `tasks` table with its six
  # indexes, the shipped `task_agent_archives` table, the legacy `projects`
  # table and Ecto's `schema_migrations` stamped with versions 1..6. Written
  # by hand (never through the migration modules) so it stays a faithful
  # reproduction of what the release left on disk.
  defp build_released_db!(path, project_rows, projects_ddl \\ @projects_ddl) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    for ddl <-
          [@released_tasks_ddl, @release_archive_ddl, projects_ddl, @schema_migrations_ddl] ++
            released_task_index_ddl() do
      exec!(conn, ddl)
    end

    exec!(
      conn,
      "CREATE INDEX IF NOT EXISTS #{@released_archive_index} " <>
        "ON task_agent_archives(task_id, depth, agent_id)"
    )

    for version <- @released_versions do
      exec!(conn, "INSERT INTO schema_migrations (version, inserted_at) VALUES (?1, ?2)", [
        version,
        @stamped_at
      ])
    end

    insert_projects!(conn, project_rows)

    :ok = XqliteNIF.close(conn)
    :ok
  end

  defp released_task_index_ddl do
    for {name, columns} <- @released_task_indexes do
      "CREATE INDEX IF NOT EXISTS #{name} ON tasks(#{columns})"
    end
  end

  defp insert_projects!(conn, project_rows) do
    for {project_path, name, last_opened_at} <- project_rows do
      exec!(conn, "INSERT INTO projects (path, name, last_opened_at) VALUES (?1, ?2, ?3)", [
        project_path,
        name,
        last_opened_at
      ])
    end
  end

  defp exec!(conn, sql, params \\ []), do: {:ok, _} = XqliteNIF.query(conn, sql, params)

  # Raw write on an existing file, outside any repo (fixture setup only).
  defp raw_exec!(path, sql, params) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)
    exec!(conn, sql, params)
    :ok = XqliteNIF.close(conn)
    :ok
  end

  defp raw_table_names!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT name FROM sqlite_master WHERE type = 'table'", [])

    :ok = XqliteNIF.close(conn)
    Enum.map(rows, &hd/1)
  end

  # The applied-version list straight off disk (no repo, no app code).
  defp raw_migration_versions!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT version FROM schema_migrations ORDER BY version", [])

    :ok = XqliteNIF.close(conn)
    List.flatten(rows)
  end

  defp start_booted_repo!(path) do
    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  # The shape `mix migrate.store` uses: an UNNAMED dynamic repo, so the
  # applied-version list `Boot.run_migrations/1` returns stays observable
  # (`Boot.start_dynamic/1` runs the same migrations but discards it).
  defp start_repo!(path) do
    {:ok, pid} = Repo.start_link(database: Path.expand(path), name: nil, pool_size: 1)
    Process.unlink(pid)
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: :ok = Boot.stop(pid), else: :ok
  end

  # Every mount row in `point` order, as a plain list of the five columns —
  # the projection `EvoGit.Store.list_vct_mounts/1` reads.
  defp mount_rows(pid) do
    query_rows(
      pid,
      "SELECT #{Enum.join(@mount_columns, ", ")} FROM vct_mounts ORDER BY point"
    )
  end

  defp table_names(pid) do
    pid
    |> query_rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    |> List.flatten()
  end

  defp column_names(pid, table) do
    pid
    |> query_rows("PRAGMA table_info(#{table})")
    |> Enum.map(fn [_cid, name | _rest] -> name end)
  end

  defp index_names(pid, table) do
    pid
    |> query_rows(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = '#{table}' " <>
        "AND sql IS NOT NULL ORDER BY name"
    )
    |> List.flatten()
  end

  defp migration_versions(pid) do
    pid
    |> query_rows("SELECT version FROM schema_migrations ORDER BY version")
    |> List.flatten()
  end

  defp query_rows(pid, sql) do
    RepoScope.with_repo(pid, fn -> Repo.query!(sql).rows end)
  end
end
