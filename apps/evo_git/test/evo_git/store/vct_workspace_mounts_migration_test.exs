defmodule EvoGit.Store.VctWorkspaceMountsMigrationTest do
  @moduledoc """
  `20260815000011_vct_workspace_mounts` — the ADDITIVE rebuild of `vct_mounts`
  that lets a WORKSPACE mount live beside the git project mounts: `path` becomes
  nullable and the two workspace columns `members`/`description` appear at the
  tail.

  Four audiences, one suite:

    * an APPLIED database (the four git-mount rows a real install already has
      in the old five-column table, `schema_migrations` stamped 1..9) → every
      row survives with a byte-identical
      `point`/`path`/`name`/`kind`/`last_opened_at`, the two new columns are
      NULL, and a workspace row (`path` NULL) is insertable afterwards
    * a RE-RUN → applying `up/0` again against the already-new table is a no-op
      (the migration's own guard, not the migrator's bookkeeping): no row is
      duplicated, none is lost
    * a PARTIALLY-new table (one of the two columns already added, `path` still
      NOT NULL) → the rebuild still runs and converges on the full shape
    * a MISSING table → `Ecto.MigrationError`, because
      `20260815000007_vct_mounts` creates it; silently creating an empty mount
      table here would hide a tampered chain

  Fixtures are crafted with RAW xqlite (never through the migration modules), so
  the old DDL below is the pre-workspace release's own shape.

  ## Pinned properties

    * IDENTITY — the five legacy columns are copied, never re-derived, and
      `path` keeps its UNIQUE guarantee
    * NULLs — `members`/`description` start NULL for every carried-over row, and
      any number of NULL `path` values coexist under the UNIQUE index (SQLite
      treats NULLs as distinct), which is what makes workspaces possible
    * ORDER — the physical column order is
      `point, path, name, kind, last_opened_at, members, description`
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.RepoScope

  # The OLD five-column mount table, exactly as `20260815000007_vct_mounts`
  # created it — the shape a released install has on disk.
  @old_mounts_ddl """
  CREATE TABLE vct_mounts (
    point TEXT PRIMARY KEY NOT NULL,
    path TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    last_opened_at TEXT
  )
  """

  @old_mount_columns ~w(point path name kind last_opened_at)

  # `PRAGMA table_info(vct_mounts)` — [cid, name, type, notnull, dflt, pk] — for
  # the NEW shape: `path` is the only column whose notnull flag flipped.
  @new_mount_table_info [
    [0, "point", "TEXT", 1, nil, 1],
    [1, "path", "TEXT", 0, nil, 0],
    [2, "name", "TEXT", 1, nil, 0],
    [3, "kind", "TEXT", 1, nil, 0],
    [4, "last_opened_at", "TEXT", 0, nil, 0],
    [5, "members", "TEXT", 0, nil, 0],
    [6, "description", "TEXT", 0, nil, 0]
  ]

  # Ecto's OWN `schema_migrations` DDL, byte-identical to what
  # `Ecto.Migration.SchemaMigration.ensure_schema_migrations_table!/3` emits
  # through `xqlite_ecto3`.
  @schema_migrations_ddl """
  CREATE TABLE "schema_migrations" ("version" INTEGER PRIMARY KEY, "inserted_at" TEXT)
  """

  # Every version BEFORE the workspace rebuild — stamped as applied, so the only
  # pending migration on such a database is `…00011` (version 10 is RETIRED and
  # must never be reused).
  @applied_versions [
    20_260_815_000_001,
    20_260_815_000_002,
    20_260_815_000_003,
    20_260_815_000_004,
    20_260_815_000_005,
    20_260_815_000_006,
    20_260_815_000_007,
    20_260_815_000_008,
    20_260_815_000_009
  ]

  @workspace_version 20_260_815_000_011
  @workspace_module EvoGit.Repo.Migrations.VctWorkspaceMounts

  @stamped_at "2026-08-15 00:00:00"

  # The rows a real install carries: several git mounts, one never opened (NULL
  # timestamp) and one RESERVED system mount (`vct:///genesis-source`), which the
  # rebuild must carry over like any other row.
  @mount_rows [
    {"vct:///projects/alpha", "/home/user/projects/alpha", "Alpha", "git",
     "2025-01-04T00:00:00.000Z"},
    {"vct:///projects/beta", "/home/user/projects/beta", "Beta", "git", nil},
    {"vct:///projects/gamma", "/home/user/other/gamma", "Gamma", "git",
     "2025-01-03T12:00:00.500Z"},
    {"vct:///genesis-source", "/home/user/.local/share/genesis/genesis-source", "genesis-source",
     "git", "2025-01-01T00:00:00.000Z"}
  ]

  setup do
    stamp =
      "#{System.system_time(:millisecond)}_#{:os.getpid()}_#{System.unique_integer([:positive])}"

    root = Path.join(System.tmp_dir!(), "evogit_vct_ws_mig_#{stamp}_#{inspect(self())}")

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, %{root: root}}
  end

  # ── (a) The upgrade ───────────────────────────────────────────────────────

  describe "an applied database with git mounts" do
    test "keeps every row byte-identically and adds the two nullable workspace columns",
         %{root: root} do
      path = Path.join(root, "upgrade.sqlite")
      build_old_db!(path, @mount_rows)

      # Ground truth BEFORE the boot: the OLD shape really is on disk.
      assert raw_column_names!(path, "vct_mounts") == @old_mount_columns
      assert raw_mount_rows!(path) == expected_rows()

      pid = start_repo!(path)

      assert Boot.run_migrations(pid) == [@workspace_version]

      assert migration_versions(pid) == @applied_versions ++ [@workspace_version]

      # The new physical shape, in order.
      assert query_rows(pid, "PRAGMA table_info(vct_mounts)") == @new_mount_table_info

      # EVERY row survived with the same five values, and the workspace columns
      # start NULL (an old row has no members and no description).
      assert query_rows(
               pid,
               "SELECT #{Enum.join(@old_mount_columns, ", ")}, members, description " <>
                 "FROM vct_mounts ORDER BY point"
             ) == Enum.map(expected_rows(), fn row -> row ++ [nil, nil] end)

      # `path` is still UNIQUE, located by its COLUMNS (a rebuilt table
      # re-derives the autoindex name): exactly one UNIQUE index covers `path`.
      assert unique_index_columns(pid) == [["path"], ["point"]]
    end

    test "accepts workspace rows with a NULL path afterwards, many of them", %{root: root} do
      path = Path.join(root, "workspaces.sqlite")
      build_old_db!(path, @mount_rows)

      pid = start_repo!(path)
      assert Boot.run_migrations(pid) == [@workspace_version]

      members = [
        %{"point" => "vct:///projects/alpha", "path" => nil},
        %{"point" => nil, "path" => "/home/user/projects/beta"}
      ]

      # TWO workspace rows, each with a NULL path: SQLite treats NULLs as
      # distinct under a UNIQUE index, so the old NOT NULL column is what used
      # to make this impossible.
      assert_query!(pid, insert_workspace_sql(), [
        "vct:///workspaces/first",
        "First",
        Jason.encode!(members),
        "everything I touch"
      ])

      assert_query!(pid, insert_workspace_sql(), ["vct:///workspaces/second", "Second", "[]", nil])

      assert query_rows(
               pid,
               "SELECT point, path, kind, members, description FROM vct_mounts " <>
                 "WHERE kind = 'workspace' ORDER BY point"
             ) == [
               [
                 "vct:///workspaces/first",
                 nil,
                 "workspace",
                 Jason.encode!(members),
                 "everything I touch"
               ],
               ["vct:///workspaces/second", nil, "workspace", "[]", nil]
             ]

      # The git rows are untouched by the workspace inserts.
      assert length(query_rows(pid, "SELECT point FROM vct_mounts WHERE kind = 'git'")) ==
               length(@mount_rows)

      # …and `path` is still UNIQUE for the rows that HAVE one.
      assert {:error, error} =
               RepoScope.with_repo(pid, fn ->
                 Repo.query(
                   "INSERT INTO vct_mounts (point, path, name, kind) VALUES (?, ?, ?, 'git')",
                   ["vct:///projects/duplicate", "/home/user/projects/alpha", "Duplicate"]
                 )
               end)

      assert Exception.message(error) =~ "UNIQUE constraint failed: vct_mounts.path"
    end
  end

  # ── (b) Re-run: the guard, not the bookkeeping ────────────────────────────

  describe "a re-run" do
    test "re-applying up/0 against the already-new table is a no-op", %{root: root} do
      path = Path.join(root, "rerun.sqlite")
      build_old_db!(path, @mount_rows)

      pid = start_repo!(path)
      assert Boot.run_migrations(pid) == [@workspace_version]

      snapshot = {mount_rows(pid), query_rows(pid, "PRAGMA table_info(vct_mounts)")}

      # Forget the version stamp so the migrator RUNS the body again: this is
      # `up/0` executed twice on the same database, and its own shape guard is
      # what must make the second run cheap instead of destructive.
      assert_query!(pid, "DELETE FROM schema_migrations WHERE version = ?", [@workspace_version])

      assert Ecto.Migrator.up(Repo, @workspace_version, @workspace_module, dynamic_repo: pid) ==
               :ok

      # Nothing duplicated, nothing lost, no shape drift.
      assert {mount_rows(pid), query_rows(pid, "PRAGMA table_info(vct_mounts)")} == snapshot

      assert mount_rows(pid) == Enum.map(expected_rows(), fn row -> row ++ [nil, nil] end)
    end

    test "a second boot migrates nothing and leaves the rows alone", %{root: root} do
      path = Path.join(root, "second_boot.sqlite")
      build_old_db!(path, @mount_rows)

      pid = start_repo!(path)
      assert Boot.run_migrations(pid) == [@workspace_version]

      before_ = mount_rows(pid)

      assert Boot.run_migrations(pid) == []
      assert mount_rows(pid) == before_
      assert migration_versions(pid) == @applied_versions ++ [@workspace_version]
    end
  end

  # ── (c) A partially-new table ─────────────────────────────────────────────

  describe "a partially-new table" do
    test "a table that already has ONE workspace column is still rebuilt", %{root: root} do
      path = Path.join(root, "partial.sqlite")
      build_old_db!(path, @mount_rows)

      # Half-upgraded: `members` exists, `description` does not and `path` is
      # still NOT NULL — the rebuild must run and converge on the full shape.
      exec_raw!(path, "ALTER TABLE vct_mounts ADD COLUMN members TEXT")

      assert raw_column_names!(path, "vct_mounts") == @old_mount_columns ++ ["members"]

      pid = start_repo!(path)

      assert Boot.run_migrations(pid) == [@workspace_version]
      assert query_rows(pid, "PRAGMA table_info(vct_mounts)") == @new_mount_table_info

      # The pre-existing `members` column is NOT carried over: the rebuild
      # copies only the five legacy columns and starts both workspace columns
      # NULL, so a half-written value can never masquerade as a real member list.
      assert mount_rows(pid) == Enum.map(expected_rows(), fn row -> row ++ [nil, nil] end)
    end
  end

  # ── (d) A missing table ───────────────────────────────────────────────────

  describe "a missing mount table" do
    test "refuses to run instead of creating an empty one", %{root: root} do
      path = Path.join(root, "missing.sqlite")
      build_old_db!(path, [])

      exec_raw!(path, "DROP TABLE vct_mounts")

      pid = start_repo!(path)

      # `20260815000007_vct_mounts` creates the table and is stamped as applied,
      # so its absence means the chain was tampered with: creating a fresh empty
      # mount table here would silently discard whatever the user had.
      assert_raise Ecto.MigrationError, ~r/vct_mounts does not exist/, fn ->
        Boot.run_migrations(pid)
      end

      refute "vct_mounts" in table_names(pid)
    end
  end

  # ── Fixtures / helpers ────────────────────────────────────────────────────

  defp insert_workspace_sql do
    """
    INSERT INTO vct_mounts (point, path, name, kind, last_opened_at, members, description)
    VALUES (?, NULL, ?, 'workspace', NULL, ?, ?)
    """
  end

  defp expected_rows, do: Enum.sort_by(@mount_rows, &elem(&1, 0)) |> Enum.map(&Tuple.to_list/1)

  # Raw xqlite: the OLD five-column `vct_mounts` with the given
  # `{point, path, name, kind, last_opened_at}` rows, plus a `schema_migrations`
  # stamped with every PRE-workspace version — so exactly one migration is
  # pending.
  defp build_old_db!(path, rows) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    for ddl <- [@old_mounts_ddl, @schema_migrations_ddl], do: exec!(conn, ddl)

    for version <- @applied_versions do
      exec!(conn, "INSERT INTO schema_migrations (version, inserted_at) VALUES (?1, ?2)", [
        version,
        @stamped_at
      ])
    end

    for {point, mount_path, name, kind, opened_at} <- rows do
      exec!(
        conn,
        "INSERT INTO vct_mounts (point, path, name, kind, last_opened_at) " <>
          "VALUES (?1, ?2, ?3, ?4, ?5)",
        [point, mount_path, name, kind, opened_at]
      )
    end

    :ok = XqliteNIF.close(conn)
    :ok
  end

  defp exec!(conn, sql, params \\ []), do: {:ok, _} = XqliteNIF.query(conn, sql, params)

  # Raw write on an existing file, outside any repo (fixture setup only).
  defp exec_raw!(path, sql, params \\ []) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)
    exec!(conn, sql, params)
    :ok = XqliteNIF.close(conn)
    :ok
  end

  defp raw_column_names!(path, table) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "PRAGMA table_info(#{table})", [])

    :ok = XqliteNIF.close(conn)
    Enum.map(rows, fn [_cid, name | _rest] -> name end)
  end

  # The five legacy columns of every row, `point` order — read straight off disk
  # (no repo, no app code), so the pre-migration values are ground truth.
  defp raw_mount_rows!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(
        conn,
        "SELECT #{Enum.join(@old_mount_columns, ", ")} FROM vct_mounts ORDER BY point",
        []
      )

    :ok = XqliteNIF.close(conn)
    rows
  end

  # The same projection through the LIVE repo.
  defp mount_rows(pid) do
    query_rows(
      pid,
      "SELECT point, path, name, kind, last_opened_at, members, description " <>
        "FROM vct_mounts ORDER BY point"
    )
  end

  # Every UNIQUE index's covered columns, sorted — the name-independent way to
  # assert `path` is UNIQUE (a rebuild re-derives the autoindex names).
  defp unique_index_columns(pid) do
    pid
    |> query_rows("PRAGMA index_list(vct_mounts)")
    |> Enum.flat_map(fn
      [_seq, name, 1, _origin, _partial] -> [name]
      _other -> []
    end)
    |> Enum.map(fn name ->
      pid
      |> query_rows("PRAGMA index_info('#{name}')")
      |> Enum.map(fn [_seqno, _cid, column] -> column end)
    end)
    |> Enum.sort()
  end

  defp table_names(pid) do
    pid
    |> query_rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    |> List.flatten()
  end

  defp migration_versions(pid) do
    pid
    |> query_rows("SELECT version FROM schema_migrations ORDER BY version")
    |> List.flatten()
  end

  defp query_rows(pid, sql, params \\ []) do
    RepoScope.with_repo(pid, fn -> Repo.query!(sql, params).rows end)
  end

  defp assert_query!(pid, sql, params) do
    RepoScope.with_repo(pid, fn -> {:ok, _result} = Repo.query(sql, params) end)
    :ok
  end

  # The unnamed dynamic repo `mix migrate.store` uses, so the applied-version
  # list `Boot.run_migrations/1` returns stays observable.
  defp start_repo!(path) do
    {:ok, pid} = Repo.start_link(database: Path.expand(path), name: nil, pool_size: 1)
    Process.unlink(pid)
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: :ok = Boot.stop(pid), else: :ok
  end
end
