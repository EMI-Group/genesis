defmodule EvoGit.Store.Operations.Projects do
  @moduledoc """
  Project-CRUD store operations on Ecto — the port of the project handlers of
  the raw-SQL `EvoGit.Store` GenServer (`store.ex` lines 868-923).

  Pure operation module: every function takes the repo PID FIRST (an UNNAMED
  dynamic `EvoGit.Repo` instance started by `EvoGit.Store.Boot.start_dynamic/1`),
  scopes it through `EvoGit.Store.RepoScope.with_repo/2`, and addresses the
  database exclusively via `EvoGit.Repo.*` + the
  `EvoGit.Store.Schemas.ProjectRow` schema — no `?N` SQL strings, no GenServer.

  ## Return shapes (EXACTLY the old public-API shapes — zero consumer changes)

  | function                | old handler    | returns |
  |-------------------------|----------------|---------|
  | `put_project/2`         | store.ex:868   | `:ok` \| `{:error, :missing_project_path}` \| `{:error, :invalid_project_struct}` \| `{:error, :disk_full}` |
  | `get_project/2`         | store.ex:889   | `%RecentProject{}` \| `nil` |
  | `delete_project/2`      | store.ex:902   | `:ok` \| `{:error, :disk_full}` |
  | `select_all_projects/1` | store.ex:910   | `[RecentProject.t()]` — NO ordering (the old SQL had none; `TaskRegistry` sorts in Elixir) |
  | `count_projects/1`      | store.ex:920   | integer |

  ## REPLACE semantics

  `put_project/2` ports the old `INSERT OR REPLACE INTO projects ...`
  (a full-column replace keyed on the `path` TEXT primary key) as an explicit
  DELETE + INSERT inside ONE `EvoGit.Repo.transaction/3` with
  `mode: :immediate` — same rationale as the tasks table: the row is replaced
  wholesale, never updated in place. The insert goes through the TYPED
  `ProjectRow` schema so `last_opened_at` dumps via
  `EvoGit.Store.Types.TaskTimestamp` — byte-identical to
  `Codec.encode_project/1`.

  ## Disk-full handling

  Where the raw NIFs returned error tuples, the XqliteEcto3 adapter RAISES
  `%XqliteEcto3.Error{}`. The write boundary (`put_project/2`,
  `delete_project/2`) converts the disk-full class to `{:error, :disk_full}`
  via `EvoGit.Store.Errors.disk_full_exception?/1` (mirroring the old
  `execute_write/4`) and logs a warning; every other error re-raises — the
  old crash philosophy is preserved.

  ## NULL-path semantics

  A `nil` path never matches a row under the old raw SQL
  (`WHERE path = ?1` bound to NULL is never true): `get_project/2` returns
  `nil` and `delete_project/2` returns `:ok` WITHOUT touching the database
  (0 rows deleted), instead of letting Ecto compile `p.path == ^nil` into an
  `IS NULL` predicate.
  """

  import Ecto.Query

  alias EvoGit.RecentProject
  alias EvoGit.Repo
  alias EvoGit.Store.Codec
  alias EvoGit.Store.Errors
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.ProjectRow

  require Logger

  @doc """
  Inserts or replaces a project (full-column replace on the `path` PK).

  Mirrors the old `INSERT OR REPLACE` write: validates via
  `Codec.validate_project/1` first (`{:error, :missing_project_path}` for a
  nil path), then deletes + re-inserts the row in one immediate transaction.
  A non-`%RecentProject{}` argument returns `{:error, :invalid_project_struct}`
  (the old client-level shape).
  """
  @spec put_project(pid(), RecentProject.t()) ::
          :ok | {:error, :missing_project_path | :invalid_project_struct | :disk_full}
  def put_project(repo, %RecentProject{} = project) do
    case Codec.validate_project(project) do
      :ok -> RepoScope.with_repo(repo, fn -> replace_row(project) end)
      error -> error
    end
  end

  def put_project(_repo, _other), do: {:error, :invalid_project_struct}

  @doc """
  Reads a single project by path, returning the struct or `nil`.
  """
  @spec get_project(pid(), String.t() | nil) :: RecentProject.t() | nil
  # NULL never matches under the old SQL (`path = ?1` bound to NULL).
  def get_project(_repo, nil), do: nil

  def get_project(repo, path) do
    RepoScope.with_repo(repo, fn ->
      case Repo.get(ProjectRow, path) do
        nil -> nil
        row -> to_recent_project(row)
      end
    end)
  end

  @doc """
  Deletes a single project by path.

  Returns `:ok` whether or not the row existed (the old `DELETE` treated a
  zero-row write as success too).
  """
  @spec delete_project(pid(), String.t() | nil) :: :ok | {:error, :disk_full}
  # NULL never matches under the old SQL — 0 rows deleted, still :ok, and no
  # `IS NULL` predicate is ever compiled.
  def delete_project(_repo, nil), do: :ok

  def delete_project(repo, path) do
    RepoScope.with_repo(repo, fn ->
      write(fn ->
        Repo.delete_all(by_path(path))
        :ok
      end)
    end)
  end

  @doc """
  Returns all projects as a list of `%RecentProject{}` — unordered, exactly
  like the old bare `SELECT ... FROM projects` (no `ORDER BY`).
  """
  @spec select_all_projects(pid()) :: [RecentProject.t()]
  def select_all_projects(repo) do
    RepoScope.with_repo(repo, fn ->
      ProjectRow |> Repo.all() |> Enum.map(&to_recent_project/1)
    end)
  end

  @doc """
  Returns the number of project rows.
  """
  @spec count_projects(pid()) :: non_neg_integer()
  def count_projects(repo) do
    RepoScope.with_repo(repo, fn -> Repo.aggregate(ProjectRow, :count) end)
  end

  ## Private — writes

  # DELETE + INSERT in ONE immediate transaction — the Ecto rendering of the
  # old `INSERT OR REPLACE` (full-column replace on the path PK).
  defp replace_row(project) do
    row = [
      path: project.path,
      name: project.name,
      last_opened_at: project.last_opened_at
    ]

    write(fn ->
      Repo.delete_all(by_path(project.path))

      # TYPED schema insert: `last_opened_at` dumps through
      # `Types.TaskTimestamp` (== `Codec.encode_datetime/1`).
      Repo.insert_all(ProjectRow, [row])

      :ok
    end)
  end

  # Shared write boundary — the Ecto twin of the old `execute_write/4`:
  # the disk-full class becomes `{:error, :disk_full}` (+ warning), every
  # other adapter error re-raises (crash philosophy preserved). Must run
  # INSIDE a `RepoScope.with_repo/2` scope — the warning reads the bound
  # instance's database path.
  defp write(fun) do
    {:ok, :ok} = Repo.transaction(fun, mode: :immediate)
    :ok
  rescue
    exception ->
      if Errors.disk_full_exception?(exception) do
        log_disk_full(exception)
        {:error, :disk_full}
      else
        reraise exception, __STACKTRACE__
      end
  end

  defp by_path(path) do
    from(p in ProjectRow, where: p.path == ^path)
  end

  ## Private — decode

  # ProjectRow → domain struct. `last_opened_at` already loaded through
  # `Types.TaskTimestamp` (lenient, == `Codec.decode_datetime/1`), so this is
  # a plain field copy — the same values `Codec.decode_project/1` produced.
  defp to_recent_project(%ProjectRow{} = row) do
    %RecentProject{
      path: row.path,
      name: row.name,
      last_opened_at: row.last_opened_at
    }
  end

  defp log_disk_full(exception) do
    Logger.warning(
      "Store: DISK FULL — SQLite write failed for database at #{inspect(database_path())}. " <>
        "Free disk space on this volume and retry the write. " <>
        "(error: #{Exception.message(exception)})"
    )
  end

  defp database_path, do: Keyword.get(Repo.config(), :database)
end
