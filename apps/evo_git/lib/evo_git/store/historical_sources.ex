defmodule EvoGit.Store.HistoricalSources do
  @moduledoc false

  # Prior development builds could leave these objects after an interrupted
  # preservation attempt. Never migrate a partially hidden schema or guess how
  # to restore it: stop before any migration mutates the database.
  @repo EvoGit.Repo
  @marker "__genesis_historical_sources"
  @hidden_archive "__genesis_preserved_archive_metadata"
  @hidden_projects "__genesis_preserved_projects"

  def run(source) do
    assert_no_preservation!()
    Ecto.Migrator.run(@repo, source, :up, all: true)
  end

  defp assert_no_preservation! do
    if table?(@marker) or column?(@hidden_archive) or table?(@hidden_projects) do
      raise Ecto.MigrationError,
            "historical source preservation: reserved preservation objects exist; " <>
              "inspect and recover the interrupted preservation state before retrying"
    end
  end

  defp column?(name),
    do: Enum.any?(sql("PRAGMA table_info(tasks)").rows, &(Enum.at(&1, 1) == name))

  defp table?(name),
    do: sql("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [name]).rows != []

  defp sql(statement, params \\ []),
    do: @repo.query!(statement, params, timeout: 600_000, log: false)
end
