defmodule EvoGit.Store.HistoricalSources do
  @moduledoc false

  # A boot-only raw SQL boundary: frozen migrations 5/7 must not consume the
  # sources migration 10 repairs. Rename, never copy/decode/drop, those sources
  # around the frozen migrations. The durable marker and each rename commit in
  # ONE transaction; a killed boot resumes from the marker, not guessed schema.
  # These reserved names must remain stable until every interrupted boot can
  # restore them. No runtime Store operation may use this module.
  @repo EvoGit.Repo
  @repair 20_260_815_000_010
  @archives 20_260_815_000_005
  @mounts 20_260_815_000_007
  @marker "__genesis_historical_sources"
  @hidden_archive "__genesis_preserved_archive_metadata"
  @hidden_projects "__genesis_preserved_projects"

  def run(source) do
    versions = Ecto.Migrator.migrated_versions(@repo)

    unless Enum.any?(source, fn {version, _} -> version == @repair end),
      do: fail!("repair migration 10 is unavailable")

    if @repair in versions do
      assert_no_preservation!()
      Ecto.Migrator.run(@repo, source, :up, all: true)
    else
      # Baseline adoption must see the original schema. Once versions 1..4
      # finish, no earlier migration can encounter our temporary column name.
      early = Ecto.Migrator.run(@repo, source, :up, to: 20_260_815_000_004)
      preserve!(Ecto.Migrator.migrated_versions(@repo))
      frozen = Ecto.Migrator.run(@repo, source, :up, to: 20_260_815_000_009)
      restore!()
      repaired = Ecto.Migrator.run(@repo, source, :up, all: true)
      early ++ frozen ++ repaired
    end
  end

  defp preserve!(versions) do
    transaction!(fn ->
      if table?(@marker) do
        preserved_sources!()
      else
        assert_no_preservation!()

        sources =
          []
          |> maybe_add(
            "archive_metadata",
            @archives not in versions and column?("archive_metadata")
          )
          |> maybe_add("projects", @mounts not in versions and table?("projects"))

        if sources != [] do
          sql("CREATE TABLE #{@marker} (source TEXT PRIMARY KEY NOT NULL)")

          for source <- sources do
            sql("INSERT INTO #{@marker} (source) VALUES (?)", [source])
            hide!(source)
          end
        end
      end
    end)
  end

  defp maybe_add(sources, source, true), do: [source | sources]
  defp maybe_add(sources, _source, false), do: sources

  defp restore! do
    transaction!(fn ->
      if table?(@marker) do
        for source <- preserved_sources!(), do: reveal!(source)
        sql("DROP TABLE #{@marker}")
      else
        assert_no_preservation!()
      end
    end)
  end

  defp preserved_sources! do
    unless sql("PRAGMA table_info(#{@marker})").rows == [[0, "source", "TEXT", 1, nil, 1]],
      do: fail!("unsupported preservation marker shape")

    sources = sql("SELECT source FROM #{@marker}").rows

    unless sources != [] and Enum.all?(sources, &(&1 in [["archive_metadata"], ["projects"]])),
      do: fail!("unsupported preservation marker contents")

    for [source] <- sources do
      case source do
        "archive_metadata" ->
          unless column?(@hidden_archive) and not column?("archive_metadata"),
            do: fail!("archive preservation marker does not match tasks columns")

        "projects" ->
          unless table?(@hidden_projects) and not table?("projects"),
            do: fail!("project preservation marker does not match tables")
      end
    end

    names = Enum.map(sources, &hd/1)

    if column?(@hidden_archive) and "archive_metadata" not in names,
      do: fail!("unmarked preserved archive column")

    if table?(@hidden_projects) and "projects" not in names,
      do: fail!("unmarked preserved projects table")

    names
  end

  defp assert_no_preservation! do
    if table?(@marker) or column?(@hidden_archive) or table?(@hidden_projects),
      do:
        fail!(
          "reserved preservation objects exist without a pending repair; inspect before retrying"
        )
  end

  defp hide!("archive_metadata"),
    do: sql("ALTER TABLE tasks RENAME COLUMN archive_metadata TO #{@hidden_archive}")

  defp hide!("projects"), do: sql("ALTER TABLE projects RENAME TO #{@hidden_projects}")

  defp reveal!("archive_metadata"),
    do: sql("ALTER TABLE tasks RENAME COLUMN #{@hidden_archive} TO archive_metadata")

  defp reveal!("projects"), do: sql("ALTER TABLE #{@hidden_projects} RENAME TO projects")

  defp column?(name),
    do: Enum.any?(sql("PRAGMA table_info(tasks)").rows, &(Enum.at(&1, 1) == name))

  defp table?(name),
    do: sql("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [name]).rows != []

  defp transaction!(fun) do
    # Exceptions deliberately escape: SQLite rolls back all marker/rename DDL,
    # and boot must stop rather than run a destructive migration unprotected.
    {:ok, result} = @repo.transaction(fun, mode: :immediate, timeout: 600_000)
    result
  end

  defp sql(statement, params \\ []),
    do: @repo.query!(statement, params, timeout: 600_000, log: false)

  defp fail!(message),
    do: raise(Ecto.MigrationError, "historical source preservation: " <> message)
end
