defmodule EvoGit.Repo.Migrations.NormalizeTaskAgentArchives do
  @moduledoc """
  Enforces the CANONICAL `task_agent_archives` shape — in particular
  `repo_id` as **TEXT** — on databases created by a pre-release variant of
  `20260815000007_create_task_agent_archives`.

  ## Why

  `repo_id` carries a repo ID STRING (`"primary"` or a foreign repo id such as
  `"cowboy"`), so the canonical column is TEXT. A pre-release build of the
  archive-table migration declared it **INTEGER** instead. SQLite's INTEGER
  affinity then coerces a numeric-looking TEXT value to an INTEGER on insert,
  so a stored `"123"` comes back as the integer `123` and the Ecto `:string`
  field fails to load it — the fault-isolated store read degrades and the whole
  archive page answers its empty shape (`%{entries: [], total: 0}` / `nil`).
  Fresh installs already get the canonical TEXT column (migration
  `20260815000007` ships that way), so for them this migration is a NO-OP.

  ## What it does

    1. probe `PRAGMA table_info(task_agent_archives)`;
       * the table does not exist → NO-OP (a database that never ran the
         archive migration has nothing to canonicalize);
       * the declared type of `repo_id` is already `TEXT` (case-insensitive)
         → NO-OP;
       * the table exists but has no `repo_id` column → `Ecto.MigrationError`
         (neither shape this migration knows how to repair);
    2. otherwise rebuild the table — `CREATE TABLE
       task_agent_archives_canonical` with the EXACT canonical column
       list/order/types/PK of `20260815000007`, `INSERT … SELECT` every row
       (`CAST(repo_id AS TEXT)`, so a coerced integer comes back as its decimal
       TEXT form), `DROP TABLE task_agent_archives`,
       `ALTER TABLE … RENAME TO task_agent_archives`, then recreate the
       `task_agent_archives_task_depth_idx` index — a `Logger.warning` names the
       rebuild and its row count.

  ## Safety

  The rebuild runs inside the per-migration transaction the Ecto migrator
  already opens (this migration does not disable DDL transactions), so an
  interrupted rebuild rolls back to the ORIGINAL table — there is no window in
  which the archive rows live in neither table. On top of that:

    * a stale `task_agent_archives_canonical` table (e.g. from an earlier
      non-transactional attempt) is dropped BEFORE the copy, so the migration
      can be re-run;
    * the copied row count is COMPARED with the source's and a mismatch raises
      `Ecto.MigrationError` BEFORE the source table is dropped — rows can never
      be lost silently;
    * the post-condition re-probes `PRAGMA table_info` and `PRAGMA index_info`,
      raising if `repo_id` is still not TEXT or the index did not come back;
    * re-running is a NO-OP: after the rebuild `repo_id` is TEXT, so the first
      probe short-circuits.

  ## Conventions

  Statements run via `repo().query/3` + `repo().query!/3` (the sibling
  migrations' convention), NOT `Ecto.Migration.execute/1`, whose string
  commands are queued until `flush/0` — every probe and DDL statement here has
  to observe the previous one in body order. Defined as `up/0` (no `down/0`),
  like the siblings: there is nothing to roll back to, and the pre-release
  INTEGER shape must never be restored.
  """

  use Ecto.Migration

  require Logger

  @table "task_agent_archives"
  # Scratch name for the rebuild; renamed onto `@table` once the copy is done.
  @canonical_table "task_agent_archives_canonical"
  @index_name "task_agent_archives_task_depth_idx"
  @index_columns ~w(task_id depth agent_id)
  # The heavy `result` blob is copied row by row inside one statement; a user
  # database can hold thousands of multi-MiB rows.
  @statement_timeout 600_000

  # The canonical DDL — IDENTICAL to `20260815000007_create_task_agent_archives`
  # (same column order, types, NOT NULLs, DEFAULTs and composite PK).
  @canonical_ddl """
  CREATE TABLE #{@canonical_table} (
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

  # The canonical column list, in the canonical order: the copy names every
  # column on BOTH sides, so no column depends on positional matching.
  @columns ~w(task_id agent_id parent_id depth agent_type context_node_path objective result
              base_commit final_commit branch_name archive_ref_start archive_ref_final repo_id
              repo_root repo_path usage llm_settings agent_settings foreign_repos
              compression_count started_at completed_at)

  def up do
    case repo_id_affinity() do
      :missing_table ->
        :ok

      :no_repo_id_column ->
        raise Ecto.MigrationError,
              "#{@table} exists without a repo_id column: PRAGMA table_info " <>
                "returned #{inspect(table_columns())}"

      :text ->
        :ok

      affinity ->
        rebuild!(affinity)
    end

    :ok
  end

  ## Rebuild

  # Copy every row into the canonical table, then swap the two tables.
  defp rebuild!(affinity) do
    rows = row_count(@table)

    Logger.warning(
      "#{inspect(__MODULE__)}: rebuilding #{@table} with the canonical TEXT repo_id " <>
        "(found repo_id affinity #{inspect(affinity)}) — #{rows} row(s) to migrate"
    )

    # A leftover scratch table from an earlier attempt would make the CREATE
    # collide; nothing has ever read it, so it is safe to discard.
    sql("DROP TABLE IF EXISTS #{@canonical_table}")
    sql(@canonical_ddl)
    copy_rows!()
    assert_row_count!(rows)
    sql("DROP TABLE #{@table}")
    sql("ALTER TABLE #{@canonical_table} RENAME TO #{@table}")

    sql(
      "CREATE INDEX IF NOT EXISTS #{@index_name} ON #{@table}(#{Enum.join(@index_columns, ", ")})"
    )

    assert_canonical_shape!()

    Logger.warning(
      "#{inspect(__MODULE__)}: #{@table} rebuilt — #{rows} row(s) preserved, repo_id is TEXT"
    )
  end

  # Every canonical column is copied by NAME; `repo_id` is CAST to TEXT so an
  # INTEGER-affinity value (a coerced numeric-looking string) lands as its
  # decimal text form instead of coming back as a number.
  defp copy_rows! do
    source_columns =
      Enum.map_join(@columns, ", ", fn
        "repo_id" -> "CAST(repo_id AS TEXT)"
        column -> column
      end)

    sql(
      """
      INSERT INTO #{@canonical_table} (#{Enum.join(@columns, ", ")})
      SELECT #{source_columns} FROM #{@table}
      """,
      []
    )
  end

  # The point of the rebuild is preserving the archive: a differing count is a
  # hard stop, raised BEFORE the source table is dropped.
  defp assert_row_count!(expected) do
    actual = row_count(@canonical_table)

    if actual != expected do
      raise Ecto.MigrationError,
            "normalize-task-agent-archives copied #{actual} row(s) of #{expected}: " <>
              "the rebuild did not preserve #{@table} and the original table was kept"
    end

    :ok
  end

  ## Probes / post-conditions

  # The declared type of `repo_id`, or `:missing_table` / `:no_repo_id_column`.
  # PRAGMA table_info rows are [cid, name, type, notnull, dflt, pk]; a missing
  # table yields NO rows (never an error).
  defp repo_id_affinity do
    case table_info() do
      [] ->
        :missing_table

      rows ->
        case Enum.find(rows, fn [_cid, name | _rest] -> name == "repo_id" end) do
          nil -> :no_repo_id_column
          [_cid, _name, type | _rest] -> normalize_affinity(type)
        end
    end
  end

  # SQLite reports the DECLARED type verbatim ("TEXT", "text", "INTEGER", …),
  # so the TEXT check is case-insensitive and whitespace-tolerant.
  defp normalize_affinity(type) when is_binary(type) do
    case type |> String.trim() |> String.upcase() do
      "TEXT" -> :text
      other -> other
    end
  end

  defp normalize_affinity(_type), do: "NONE"

  defp table_info do
    case repo().query("PRAGMA table_info(#{@table})", [], log: false) do
      {:ok, %{rows: rows}} -> rows
      _other -> []
    end
  end

  defp table_columns do
    Enum.map(table_info(), fn [_cid, name | _rest] -> name end)
  end

  defp row_count(table) do
    %{rows: [[count]]} = sql("SELECT COUNT(*) FROM #{table}", [])
    count
  end

  # Post-condition: the swapped-in table carries the canonical columns and a
  # TEXT `repo_id`, and the roster index is back.
  defp assert_canonical_shape! do
    if repo_id_affinity() != :text do
      raise Ecto.MigrationError,
            "repo_id on #{@table} is still not TEXT after the rebuild: " <>
              "PRAGMA table_info returned #{inspect(table_columns())}"
    end

    actual = index_columns()

    if actual != @index_columns do
      raise Ecto.MigrationError,
            "index #{@index_name} on #{@table}(#{Enum.join(@index_columns, ", ")}) " <>
              "was not recreated: PRAGMA index_info returned #{inspect(actual)}"
    end

    :ok
  end

  # PRAGMA index_info(<name>) rows: [seqno, cid, name].
  defp index_columns do
    case repo().query("PRAGMA index_info(#{@index_name})", [], log: false) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [_seqno, _cid, column] -> column end)
      _other -> []
    end
  end

  ## Statements

  defp sql(statement, params \\ []) do
    repo().query!(statement, params, timeout: @statement_timeout, log: false)
  end
end
