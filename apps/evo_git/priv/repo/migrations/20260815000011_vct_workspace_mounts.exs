defmodule EvoGit.Repo.Migrations.VctWorkspaceMounts do
  @moduledoc """
  Rebuilds `vct_mounts` so the Virtual Context Tree (VCT) mount table can hold
  WORKSPACE mounts beside the git project mounts `20260815000007_vct_mounts`
  created.

  ## 1. The new shape

  | column           | type | notes |
  |------------------|------|-------|
  | `point`          | TEXT | PRIMARY KEY NOT NULL — the canonical `vct:///…` point |
  | `path`           | TEXT | UNIQUE, **NULLABLE** — the absolute OS path a git mount binds to |
  | `name`           | TEXT | NOT NULL — display name |
  | `kind`           | TEXT | NOT NULL — mount kind, `"git"` or `"workspace"` |
  | `last_opened_at` | TEXT | ISO-8601 TEXT, or NULL for a mount never opened |
  | `members`        | TEXT | NULLABLE — a JSON ARRAY of member maps, in order |
  | `description`    | TEXT | NULLABLE — an optional free-text description |

  Two things changed, both ADDITIVE:

    * `path` LOST its `NOT NULL`. A workspace mount has no OS path of its own —
      it groups other mounts — so it stores NULL. SQLite allows any number of
      NULLs under a UNIQUE index (NULLs are distinct), so many workspaces
      coexist with the UNIQUE git paths in one table; `path` stays UNIQUE, so
      two points still can never claim one directory.
    * `members` and `description` are new NULLABLE columns. `members` is the
      workspace's ORDERED member list, JSON-encoded as TEXT (order is
      significant), where each member is a STRING-KEYED map
      `%{"point" => "vct:///…" | nil, "path" => "/abs/path" | nil}` with at
      least one of the two set. A git mount carries `NULL` here (an empty
      list), and `description` is optional for every kind.

  ## 2. The rebuild

  SQLite cannot drop `NOT NULL` in place, so the table is REBUILT in body
  order, one single SQL statement each:

      CREATE TABLE vct_mounts_new (… the seven columns above …)
      INSERT INTO vct_mounts_new (…7…)
        SELECT point, path, name, kind, last_opened_at, NULL, NULL FROM vct_mounts
      DROP TABLE vct_mounts
      ALTER TABLE vct_mounts_new RENAME TO vct_mounts

  EVERY existing row survives with a byte-identical `point`/`path`/`name`/
  `kind`/`last_opened_at`; the five legacy columns are never rewritten,
  re-derived or dropped, and the new columns start as NULL (an old row picks up
  `[]` for `members` when it is READ, which is the store operation's job, not
  this migration's). No legacy table is fanned out and no cap is applied here —
  both belong to `20260815000007_vct_mounts`.

  ## 3. The guard

  The rebuild runs ONLY when the table still has the old shape, so a re-run (or
  any partially-upgraded file) is a no-op:

    * the table already has `members` AND `description` and `path` is nullable
      → nothing to do, only the shape is asserted;
    * the table does not exist at all → `Ecto.MigrationError`, because
      `20260815000007_vct_mounts` creates it and a missing table means the chain
      was tampered with (silently creating an empty mount table here would hide
      that).

  ## 4. Self-contained on purpose

  An applied migration is frozen history and must keep working forever, even
  after the store layer or `EvoGit.VCT` are refactored, so this file calls no
  application code at all: the column list and DDL are inlined, and the
  member-map encoding is NOT validated here (the migration copies NULLs only).

  ## 5. Statements and post-conditions

  Statements run via `repo().query!/3` in body order, never
  `Ecto.Migration.execute/1` (whose string commands are queued until `flush/0`,
  so an in-body probe would read pre-migration state). Every statement is a
  single SQL statement.

  Post-conditions raise `Ecto.MigrationError` with an actionable message:
  `PRAGMA table_info(vct_mounts)` must report EXACTLY the seven canonical
  columns in order with the declared types/notnull/pk flags, and one UNIQUE
  index must cover exactly `["path"]`. That index is located by INSPECTING
  `PRAGMA index_list` + `PRAGMA index_info` rather than by its name: SQLite
  names a table-level autoindex `sqlite_autoindex_<table>_<n>`, which a rebuild
  re-derives from the new table name.

  Defined as `up/0` (no `down/0`), like the siblings: going back would DROP the
  workspace columns and therefore lose the user's workspace mounts, and a
  rebuilt table cannot restore the dropped rows.
  """

  use Ecto.Migration

  @table "vct_mounts"
  @rebuild_table "vct_mounts_new"
  @statement_timeout 120_000

  # {name, declared type, notnull, pk} — the shape `PRAGMA table_info` must
  # report, in physical order. `path` is the ONE column whose notnull flag
  # flipped (1 → 0) when it became nullable for workspace mounts.
  @columns [
    {"point", "TEXT", 1, 1},
    {"path", "TEXT", 0, 0},
    {"name", "TEXT", 1, 0},
    {"kind", "TEXT", 1, 0},
    {"last_opened_at", "TEXT", 0, 0},
    {"members", "TEXT", 0, 0},
    {"description", "TEXT", 0, 0}
  ]

  @create_ddl """
  CREATE TABLE vct_mounts_new (
    point TEXT PRIMARY KEY NOT NULL,
    path TEXT UNIQUE,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    last_opened_at TEXT,
    members TEXT,
    description TEXT
  )
  """

  @copy_sql """
  INSERT INTO vct_mounts_new (point, path, name, kind, last_opened_at, members, description)
  SELECT point, path, name, kind, last_opened_at, NULL, NULL FROM vct_mounts
  """

  @spec up() :: :ok
  def up do
    cond do
      not table_exists?(@table) ->
        raise Ecto.MigrationError,
              "#{@table} does not exist, so the workspace-mount rebuild cannot run: " <>
                "20260815000007_vct_mounts creates it and must have been applied first " <>
                "(the migration chain is out of order or was tampered with)"

      current_shape?() ->
        :ok

      true ->
        rebuild_table()
    end

    assert_table_shape!()
    assert_unique_path!()
    :ok
  end

  ## The rebuild

  # The new table is built beside the old one and swapped in with a RENAME, so
  # the whole rebuild is four single statements inside the migration's own
  # transaction: a failure anywhere rolls back and leaves the old table (and its
  # rows) untouched.
  defp rebuild_table do
    sql(@create_ddl)
    sql(@copy_sql)
    sql("DROP TABLE #{@table}")
    sql("ALTER TABLE #{@rebuild_table} RENAME TO #{@table}")
  end

  # TRUE only for the NEW shape: both added columns are present and `path` is
  # nullable. Every other state (the old five-column table, a table missing one
  # of the two columns) needs the rebuild.
  defp current_shape? do
    columns = column_specs(@table)
    names = Enum.map(columns, fn {name, _type, _notnull, _pk} -> name end)

    has_workspace_columns = "members" in names and "description" in names

    path_nullable =
      Enum.any?(columns, fn {name, _type, notnull, _pk} -> name == "path" and notnull == 0 end)

    has_workspace_columns and path_nullable
  end

  ## Post-conditions

  defp assert_table_shape! do
    observed = column_specs(@table)

    if observed != @columns do
      raise Ecto.MigrationError,
            "#{@table} does not have the expected shape: " <>
              "expected #{inspect(@columns)}, got #{inspect(observed)} " <>
              "(from PRAGMA table_info(#{@table}))"
    end

    :ok
  end

  # One UNIQUE index must cover exactly `path`. Located by its COLUMNS, never by
  # its name: a rebuilt table's autoindex name is re-derived from the table name
  # (`sqlite_autoindex_vct_mounts_1`/`_2` here), and the numbers depend on the
  # declaration order of the primary key and the UNIQUE column.
  defp assert_unique_path! do
    covered =
      @table
      |> unique_index_names()
      |> Enum.map(&index_columns/1)

    unless ["path"] in covered do
      raise Ecto.MigrationError,
            "#{@table}.path is not UNIQUE after the workspace-mount rebuild: " <>
              "the UNIQUE indexes cover #{inspect(covered)} " <>
              "(from PRAGMA index_list(#{@table}))"
    end

    :ok
  end

  # The names of every UNIQUE index on the table.
  defp unique_index_names(table) do
    "PRAGMA index_list(#{table})"
    |> query_rows()
    |> Enum.flat_map(fn
      [_seq, name, 1, _origin, _partial] -> [name]
      _other -> []
    end)
  end

  # PRAGMA index_info(<index>) rows: [seqno, cid, name] — the covered columns in
  # index order (`cid` and `name` are NULL for an expression index).
  defp index_columns(index_name) do
    "PRAGMA index_info(#{quote_name(index_name)})"
    |> query_rows()
    |> Enum.map(fn
      [_seqno, _cid, column] -> column
      [_seqno, _cid] -> nil
    end)
  end

  ## Introspection helpers

  # PRAGMA table_info(<table>) rows: [cid, name, type, notnull, dflt_value, pk].
  defp column_specs(table) do
    table
    |> column_info_rows()
    |> Enum.map(fn [_cid, name, type, notnull, _default, pk] ->
      {name, type, notnull, pk}
    end)
  end

  defp column_info_rows(table) do
    case repo().query("PRAGMA table_info(#{table})", [], log: false) do
      {:ok, %{rows: rows}} -> rows
      _other -> []
    end
  end

  defp query_rows(statement) do
    statement
    |> repo().query!([], timeout: @statement_timeout, log: false)
    |> Map.fetch!(:rows)
  end

  defp table_exists?(table) do
    statement = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?"

    case repo().query(statement, [table], log: false) do
      {:ok, %{rows: [_ | _]}} -> true
      _other -> false
    end
  end

  # A PRAGMA takes a bare identifier, so a quoted name is spelled with SQL
  # string-literal quoting (single quotes escaped by doubling).
  defp quote_name(name) when is_binary(name) do
    "'" <> String.replace(name, "'", "''") <> "'"
  end

  defp sql(statement, params \\ []) do
    repo().query!(statement, params, timeout: @statement_timeout, log: false)
  end
end
