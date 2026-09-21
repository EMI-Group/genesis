defmodule Mix.Tasks.Migrate.Store do
  @moduledoc """
  Run pending Ecto migrations for the EvoGit task database (`tasks.sqlite`).

  The store auto-migrates at boot — `EvoGit.Store.Boot` runs the Ecto
  migrations in `priv/repo/migrations/` (baseline schema adoption + data
  normalization, including the legacy `branch_name` / `updated_at`
  backfills) before any read/write — so this task is NORMALLY A NO-OP. It
  exists for the manual cases: verifying a database after copying it between
  machines, or finishing an interrupted upgrade without booting the app.

  The task does NOT start the `:evo_git` application. It boots a private
  UNNAMED dynamic `EvoGit.Repo` instance on the target database and runs the
  migrations through `EvoGit.Store.Boot.run_migrations/1` — the exact call
  the store boot uses — then reports the applied versions (or "already
  current") and stops the instance.

  Safe to re-run: `Ecto.Migrator` with `all: true` is a no-op on a current
  database.

  ## Usage

      mix migrate.store [db_path]

  `db_path` is optional. Defaults to

      Path.join(Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir()), "tasks.sqlite")

  ## Output

  Lists each freshly applied migration (version + name) and finishes with
  "Database is now current", or reports "already current" when nothing was
  pending.
  """

  use Mix.Task

  @shortdoc "Migrate the EvoGit task database (run pending Ecto migrations)"

  @requirements ["app.config"]

  alias Ecto.Migrator
  alias EvoGit.Store.{Boot, RepoScope}

  @repo EvoGit.Repo

  @impl Mix.Task
  def run(args) do
    db_path = resolve_db_path(args)

    Mix.shell().info("==> Migrating task database: #{db_path}")

    # Mix-task context: the :evo_git app is NOT started (app.config only
    # loads + compiles), and the migrator needs the Ecto/DBConnection
    # runtime apps up — the same set `Ecto.Migrator.with_repo/3` starts.
    # Idempotent when they are already running (test context).
    Application.ensure_all_started(:ecto_sql)

    # `Boot.start_dynamic/1` would run the migrations too, but it discards
    # the applied-version list this task reports — so boot the unnamed
    # instance with the same shape and call `Boot.run_migrations/1` directly.
    case @repo.start_link(database: Path.expand(db_path), name: nil, pool_size: 1) do
      {:ok, pid} ->
        try do
          pid |> Boot.run_migrations() |> report(pid)
        after
          Boot.stop(pid)
        end

      {:error, reason} ->
        Mix.raise("Failed to open SQLite database #{db_path}: #{inspect(reason)}")
    end

    :ok
  end

  ## Setup helpers

  defp resolve_db_path([]) do
    data_dir = Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())
    Path.join(data_dir, "tasks.sqlite")
  end

  defp resolve_db_path([db_path | _rest]), do: db_path

  ## Reporting

  defp report([], pid) do
    count = migration_count(pid)

    Mix.shell().info("Database is already current — no pending migrations (#{count} applied).")
  end

  defp report(versions, pid) do
    statuses = migration_statuses(pid)
    names = Map.new(statuses, fn {_status, version, name} -> {version, name} end)

    Mix.shell().info("Applying #{length(versions)} migration(s):")

    for version <- versions do
      Mix.shell().info("  #{version}_#{names[version]}")
    end

    Mix.shell().info("Database is now current (#{length(statuses)} migration(s) applied).")
  end

  # `Ecto.Migrator.migrations/1` reads the repo's configured migrations
  # directory and compares it against `schema_migrations` — run scoped to
  # the task's private instance through `RepoScope`.
  defp migration_statuses(pid) do
    RepoScope.with_repo(pid, fn -> Migrator.migrations(@repo) end)
  end

  defp migration_count(pid), do: length(migration_statuses(pid))
end
