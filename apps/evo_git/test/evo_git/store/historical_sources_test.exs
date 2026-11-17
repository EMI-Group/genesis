defmodule EvoGit.Store.HistoricalSourcesTest do
  @moduledoc """
  Interrupted development preservation state is refused before any migration.
  These synthetic files are not supported release-upgrade fixtures: boot must
  neither guess how to restore hidden sources nor repair colliding ledgers.
  Each test owns its unnamed repo and file, with no shared mutable globals.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store.{Boot, RepoScope}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "historical_sources_#{:os.getpid()}_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    path = Path.join(root, "tasks.sqlite")
    opts = Keyword.merge(Repo.start_opts(), database: path, name: nil, pool_size: 1)
    {:ok, pid} = Repo.start_link(opts)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Boot.stop(pid)
      File.rm_rf(root)
    end)

    RepoScope.with_repo(pid, fn ->
      Repo.query!("CREATE TABLE tasks (id TEXT PRIMARY KEY, archive_metadata TEXT, result TEXT)")
      Repo.query!("INSERT INTO tasks VALUES (?, ?, ?)", ["kept", "[broken source", "z1:opaque"])
      Repo.query!("CREATE TABLE projects (path TEXT PRIMARY KEY, name TEXT)")
      Repo.query!("INSERT INTO projects VALUES ('/legacy/demo', 'Demo')")
    end)

    {:ok, repo: pid}
  end

  for {label, statements} <- [
        {"empty marker", ["CREATE TABLE __genesis_historical_sources (stage TEXT)"]},
        {"operator-owned marker of unknown shape",
         [
           "CREATE TABLE __genesis_historical_sources (operator_data BLOB)",
           "INSERT INTO __genesis_historical_sources VALUES (X'00FF')"
         ]},
        {"hidden archive column without a marker",
         [
           "ALTER TABLE tasks RENAME COLUMN archive_metadata TO __genesis_preserved_archive_metadata"
         ]},
        {"hidden projects table without a marker",
         ["ALTER TABLE projects RENAME TO __genesis_preserved_projects"]},
        {"all remnants together",
         [
           "CREATE TABLE __genesis_historical_sources (stage TEXT)",
           "INSERT INTO __genesis_historical_sources VALUES ('interrupted')",
           "ALTER TABLE tasks RENAME COLUMN archive_metadata TO __genesis_preserved_archive_metadata",
           "ALTER TABLE projects RENAME TO __genesis_preserved_projects"
         ]}
      ] do
    test "#{label} refuses boot without changing schema, ledger or source bytes", %{repo: pid} do
      RepoScope.with_repo(pid, fn ->
        for statement <- unquote(statements), do: Repo.query!(statement)
      end)

      # Both a pre-migrator file and an already stamped ledger must be refused.
      # No schema_migrations bootstrap is permitted before the guard runs.
      for stamped <- [false, true] do
        if stamped do
          RepoScope.with_repo(pid, fn ->
            Repo.query!(
              "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, inserted_at TEXT)"
            )

            for version <- 20_260_815_000_001..20_260_815_000_009 do
              Repo.query!("INSERT INTO schema_migrations VALUES (?, ?)", [version, "2026-01-01"])
            end
          end)
        end

        before_boot = snapshot(pid)

        for _attempt <- 1..2 do
          assert_raise Ecto.MigrationError,
                       ~r/reserved preservation objects exist; inspect and recover the interrupted preservation state/,
                       fn -> Boot.run_migrations(pid) end

          assert snapshot(pid) == before_boot
          assert Process.alive?(pid)
        end
      end
    end
  end

  defp snapshot(pid) do
    RepoScope.with_repo(pid, fn ->
      schema =
        Repo.query!("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").rows

      tables =
        Repo.query!("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").rows

      data =
        for [table] <- tables do
          quoted = String.replace(table, "\"", "\"\"")
          {table, Repo.query!("SELECT * FROM \"#{quoted}\"").rows |> Enum.sort()}
        end

      {schema, data}
    end)
  end
end
