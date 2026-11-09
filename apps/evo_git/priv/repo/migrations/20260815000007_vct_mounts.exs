defmodule EvoGit.Repo.Migrations.VctMounts do
  @moduledoc """
  Creates `vct_mounts` — the Virtual Context Tree (VCT) mount table — and
  takes over whatever the legacy `projects` table still holds.

  ## 1. The table (the ONLY create site)

  | column           | type | notes |
  |------------------|------|-------|
  | `point`          | TEXT | PRIMARY KEY NOT NULL — the canonical `vct:///projects/<name>` point |
  | `path`           | TEXT | NOT NULL UNIQUE — the absolute OS path the point binds to |
  | `name`           | TEXT | NOT NULL — display name |
  | `kind`           | TEXT | NOT NULL — mount kind, `"git"` today |
  | `last_opened_at` | TEXT | ISO-8601 TEXT, or NULL for a mount never opened |

  `point` is the primary key because a VCT point is unique within a mount
  table (`EvoGit.VCT.Table.unique_point/2` guarantees it), and `path` is
  UNIQUE because one OS path is at most one mount. Timestamps stay ISO-8601
  **TEXT** — the wire format is owned by
  `EvoGit.Store.Types.TaskTimestamp`, not by this migration.

  ## 2. The legacy `projects` table (guarded)

  Only when a legacy `projects` table exists (a database written before the VCT
  owned the mount list) do its rows move here, after which the table is
  DROPPED. A fresh database never has `projects` at all — `20260815000001`
  deliberately does not create it — so this section is an O(1) no-op there.

  Rows are processed NEWEST FIRST (`last_opened_at` descending, NULLs last,
  `path` ascending as a deterministic tie-break), and each one derives its
  point exactly like `EvoGit.VCT.Table`:

    * the segment is the path basename, with every `/` and `\\` replaced by
      `-`, control characters stripped and the result trimmed;
    * `""`, `"."` and `".."` become `"project"`;
    * collisions take a `-N` suffix, N counting from 2.

  A non-blank stored display name is preserved; otherwise the basename is the
  name. Rows whose path is missing, blank or not absolute are skipped with a
  `Logger.warning` and never inserted. Inserts are `INSERT OR IGNORE`, so a
  re-run cannot duplicate a point or violate the UNIQUE path.

  Row-level leniency is the ONLY leniency: both legacy READS run through
  `repo().query!/3`, so a query that cannot even be parsed or executed (e.g. a
  `projects` table with an unexpected column shape) RAISES instead of
  reporting "no rows". The migration's own transaction then rolls back,
  `projects` survives untouched and boot fails loudly — a silent zero-row
  fan-out followed by `DROP TABLE projects` would destroy the user's mounts
  irreversibly.

  After the fan-out the table is capped to the 100 NEWEST mounts (the VCT's
  `max_projects/0` default), so a migration can never produce a table the VCT
  itself would refuse to grow.

  ## 3. Self-contained on purpose

  This file must keep working forever, even after `EvoGit.VCT.Table`,
  `EvoGit.VCT.Mount` or `EvoGit.Store` are refactored — an applied migration is
  frozen history — so the path/point rules are inlined here instead of being
  called from application code. The duplication of the point-segment and
  path-basename rules is therefore deliberate.

  ## 4. Statements and post-conditions

  Statements run via `repo().query!/3` in body order, never
  `Ecto.Migration.execute/1` (whose string commands are queued until
  `flush/0`, so an in-body probe would read pre-migration state). Every
  statement is a single SQL statement.

  Post-conditions raise `Ecto.MigrationError` with an actionable message:
  `PRAGMA table_info(vct_mounts)` must report EXACTLY the five canonical
  columns in order with the declared types/notnull/pk flags, and `projects`
  must be gone from `sqlite_master`.

  Defined as `up/0` (no `down/0`), like the siblings: dropping `vct_mounts`
  would delete the user's whole mount table, and re-creating `projects` would
  restore a table nothing reads.
  """

  use Ecto.Migration

  require Logger

  @table "vct_mounts"
  @legacy_table "projects"
  @projects_prefix "vct:///projects/"
  @max_projects 100
  @default_kind "git"
  @statement_timeout 120_000

  # {name, declared type, notnull, pk} — the shape `PRAGMA table_info` must
  # report, in physical order.
  @columns [
    {"point", "TEXT", 1, 1},
    {"path", "TEXT", 1, 0},
    {"name", "TEXT", 1, 0},
    {"kind", "TEXT", 1, 0},
    {"last_opened_at", "TEXT", 0, 0}
  ]

  @create_ddl """
  CREATE TABLE IF NOT EXISTS vct_mounts (
    point TEXT PRIMARY KEY NOT NULL,
    path TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    last_opened_at TEXT
  )
  """

  @spec up() :: :ok
  def up do
    sql(@create_ddl)

    if table_exists?(@legacy_table) do
      migrated = migrate_legacy_rows()
      cap_rows()
      sql("DROP TABLE IF EXISTS #{@legacy_table}")

      Logger.info(
        "vct_mounts: migrated #{migrated} legacy project row(s) and dropped #{@legacy_table}"
      )
    end

    assert_no_legacy_table!()
    assert_table_shape!()
    :ok
  end

  ## Legacy fan-out

  defp migrate_legacy_rows do
    used = points_in_use()

    {count, _used} =
      @legacy_table
      |> select_legacy_rows()
      |> Enum.reduce({0, used}, fn row, {count, used} ->
        case legacy_entry(row) do
          {:ok, entry} ->
            {point, used} = take_point(entry["path"], used)
            insert_mount(Map.put(entry, "point", point))
            {count + 1, used}

          :skip ->
            {count, used}
        end
      end)

    count
  end

  # Newest first, NULL timestamps last, `path` ASC as a deterministic
  # tie-break — the exact order the VCT would have produced had these rows
  # landed there one at a time, so `-N` suffixes are stable across runs.
  #
  # `query!/3` on purpose: a read that fails must ABORT the migration (the
  # transaction rolls back and `projects` survives) rather than look like an
  # empty table and let `up/0` drop the user's rows.
  defp select_legacy_rows(legacy_table) do
    statement = """
    SELECT path, name, last_opened_at
      FROM #{legacy_table}
     ORDER BY (last_opened_at IS NULL) ASC, last_opened_at DESC, path ASC
    """

    repo().query!(statement, [], timeout: @statement_timeout, log: false).rows
  end

  # Same rule as `select_legacy_rows/1`: a failed read raises, never `[]`.
  defp points_in_use do
    "SELECT point FROM #{@table}"
    |> repo().query!([], timeout: @statement_timeout, log: false)
    |> Map.fetch!(:rows)
    |> Enum.map(fn [point] -> point end)
    |> MapSet.new()
  end

  # Total: one unusable row is logged and skipped, never raised.
  defp legacy_entry([path, name, last_opened_at]) do
    case usable_path(path) do
      {:ok, os_path} ->
        {:ok,
         %{
           "path" => os_path,
           "name" => display_name(name, os_path),
           "kind" => @default_kind,
           "last_opened_at" => stored_timestamp(last_opened_at)
         }}

      :skip ->
        log_skip(path)
        :skip
    end
  end

  defp legacy_entry(row) do
    log_skip(row)
    :skip
  end

  defp usable_path(path) do
    trimmed = if is_binary(path), do: String.trim(path)

    cond do
      not is_binary(trimmed) -> :skip
      trimmed == "" -> :skip
      not absolute_path?(trimmed) -> :skip
      true -> {:ok, trimmed}
    end
  end

  # Inlined on purpose (see the moduledoc): a POSIX root, a Windows drive root
  # or a UNC root. `EvoGit.Platform.absolute_path?/1` is application code and
  # must not be called from a frozen migration.
  defp absolute_path?("/" <> _rest), do: true
  defp absolute_path?("\\\\" <> _rest), do: true

  defp absolute_path?(<<letter, ?:, sep, _rest::binary>>)
       when letter in ?a..?z and sep in [?/, ?\\],
       do: true

  defp absolute_path?(<<letter, ?:, sep, _rest::binary>>)
       when letter in ?A..?Z and sep in [?/, ?\\],
       do: true

  defp absolute_path?(_path), do: false

  defp take_point(os_path, used) do
    point = unique_point(@projects_prefix <> point_segment(basename(os_path)), used)
    {point, MapSet.put(used, point)}
  end

  defp unique_point(base, used, counter \\ 1) do
    candidate = if counter == 1, do: base, else: base <> "-" <> Integer.to_string(counter)

    if MapSet.member?(used, candidate) do
      unique_point(base, used, counter + 1)
    else
      candidate
    end
  end

  defp basename(path) do
    path
    |> String.replace("\\", "/")
    |> String.replace(~r{/+}, "/")
    |> String.trim_trailing("/")
    |> case do
      "" -> "/"
      form -> Path.basename(form)
    end
  end

  defp point_segment(raw) do
    segment =
      raw
      |> to_string()
      |> String.replace(~r{[/\\]}, "-")
      |> String.replace(~r/[\x00-\x1F\x7F]/, "")
      |> String.trim()

    if segment in ["", ".", ".."], do: "project", else: segment
  end

  defp display_name(stored, os_path) do
    normalized(stored) || normalized(basename(os_path)) || "project"
  end

  defp normalized(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      name -> name
    end
  end

  defp normalized(_value), do: nil

  # Stored verbatim: `EvoGit.Store.Types.TaskTimestamp` loads an ISO-8601 string
  # and decodes anything unparseable to `nil` (older = last), so no re-encoding
  # (and no byte drift) happens here.
  defp stored_timestamp(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      timestamp -> timestamp
    end
  end

  defp stored_timestamp(_value), do: nil

  defp log_skip(path) do
    Logger.warning(
      "vct_mounts: skipped legacy project row with an unusable path: #{inspect(path)}"
    )
  end

  defp insert_mount(entry) do
    sql(
      """
      INSERT OR IGNORE INTO #{@table} (point, path, name, kind, last_opened_at)
      VALUES (?, ?, ?, ?, ?)
      """,
      [entry["point"], entry["path"], entry["name"], entry["kind"], entry["last_opened_at"]]
    )
  end

  # Keep at most the 100 NEWEST mounts — the VCT's own default cap.
  defp cap_rows do
    sql("""
    DELETE FROM #{@table}
     WHERE point NOT IN (
       SELECT point FROM #{@table}
        ORDER BY (last_opened_at IS NULL) ASC, last_opened_at DESC, point ASC
        LIMIT #{@max_projects}
     )
    """)
  end

  ## Post-conditions

  defp assert_no_legacy_table! do
    if table_exists?(@legacy_table) do
      raise Ecto.MigrationError,
            "#{@legacy_table} still exists after the vct_mounts fan-out " <>
              "(sqlite_master still lists it); the drop did not take effect"
    end

    :ok
  end

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

  # PRAGMA table_info(<table>) rows: [cid, name, type, notnull, dflt_value, pk].
  defp column_specs(table) do
    case repo().query("PRAGMA table_info(#{table})", [], log: false) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [_cid, name, type, notnull, _default, pk] ->
          {name, type, notnull, pk}
        end)

      _other ->
        []
    end
  end

  defp table_exists?(table) do
    statement = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?"

    case repo().query(statement, [table], log: false) do
      {:ok, %{rows: [_ | _]}} -> true
      _other -> false
    end
  end

  defp sql(statement, params \\ []) do
    repo().query!(statement, params, timeout: @statement_timeout, log: false)
  end
end
