defmodule EvoGit.Store.VctMountsMigrationTest do
  @moduledoc """
  `20260815000007_vct_mounts` — the migration that puts the Virtual Context Tree
  (VCT) mount table into SQLite and retires the legacy `projects` table.

  Two audiences, one suite:

    * a LEGACY database (a release that still shipped `projects` rows) → every
      usable row is carried into `vct_mounts`, the table is DROPPED, and the
      result is capped to the 100 newest mounts; unusable rows are skipped
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

      build_legacy_db!(path, [
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
      ])

      # Ground truth BEFORE boot: the fixture really carries the legacy table.
      assert File.exists?(path)
      assert "projects" in raw_table_names!(path)

      pid = start_booted_repo!(path)

      # Every usable row, in point order, with its derived point/name.
      assert mount_rows(pid) == [
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

  # ── (b) fresh database ────────────────────────────────────────────────────

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
    {:ok, _} = XqliteNIF.query(conn, @tasks_ddl, [])
    {:ok, _} = XqliteNIF.query(conn, @projects_ddl, [])

    for {project_path, name, last_opened_at} <- project_rows do
      {:ok, _} =
        XqliteNIF.query(
          conn,
          "INSERT INTO projects (path, name, last_opened_at) VALUES (?1, ?2, ?3)",
          [project_path, name, last_opened_at]
        )
    end

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

  defp start_booted_repo!(path) do
    {:ok, pid} = Boot.start_dynamic(path)
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

  defp query_rows(pid, sql) do
    RepoScope.with_repo(pid, fn -> Repo.query!(sql).rows end)
  end
end
