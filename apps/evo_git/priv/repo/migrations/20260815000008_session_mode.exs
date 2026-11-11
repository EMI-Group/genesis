defmodule EvoGit.Repo.Migrations.SessionMode do
  @moduledoc """
  Adds the `tasks.session_mode` column — the task's DRIVER mode
  (`"oneshot"` = today's one-shot agent, `"interactive"` = a session that
  yields to the non-terminal `:awaiting_input` status and waits for the next
  message).

  ## Why a separate migration

  `20260815000001_baseline_adoption` creates the FINAL shape, so a database
  booted by THIS release already has the column (this migration is then a pure
  probe-guarded no-op — it never alters, rewrites or re-reads a row). Every
  database an EARLIER release left behind is already stamped at version 1 and
  therefore never re-runs the baseline, so it needs this one guarded
  `ALTER TABLE tasks ADD COLUMN` — SQLite appends the column after
  `updated_at`, which is the accepted tail shape (column order is functionally
  irrelevant here: every query in this system is name-based).

  ## Values and normalization

  The column holds `"oneshot"` or `"interactive"` (plain TEXT, no CHECK — the
  store's `SessionMode` type / `Codec.decode_session_mode/1` own the value set).
  There is deliberately NO `DEFAULT` and no backfill: every pre-existing row
  reads back as `"oneshot"` through the codec, which is exactly what it is, and
  one NULL per existing row is cheaper than rewriting the whole table.
  A NULL, an absent value and an unknown spelling all normalize to `"oneshot"`
  in the read/write path, so neither a pre-migration row nor a hand-edited
  value can crash a read.

  ## Probe-guarded, idempotent

  The `PRAGMA table_info(tasks)` probe decides the branch, statements run via
  `repo().query!/3` in body order (never `Ecto.Migration.execute/1`, whose
  string commands are queued until `flush/0` — see the baseline migration's
  moduledoc), and the post-condition asserts the column's shape and that the
  ALTER wrote no data. Defined as `up/0` (no `down/0`), like the siblings:
  dropping the column would discard session state.

  ## No index

  `session_mode` is a two-value short TEXT column read as part of the existing
  row/page/summary projections — it is never a filter in any paginated query,
  so it gets no index (the same reasoning that keeps `type`/`review_status`
  unindexed).
  """

  use Ecto.Migration

  @column "session_mode"

  # The one shape this migration adds: nullable TEXT, not a key (SQLite refuses
  # NOT NULL adds without a default on a populated table, and the codec's
  # `"oneshot"` normalization makes a NULL unambiguous).
  @column_spec {@column, "TEXT", 0, 0}

  def up do
    if column?(tasks_columns()) do
      :ok
    else
      sql("ALTER TABLE tasks ADD COLUMN #{@column} TEXT")
    end

    assert_column!()
    assert_no_backfill!()
  end

  ## Helpers

  defp sql(statement), do: repo().query!(statement, [], log: false)

  # PRAGMA table_info(<table>) rows: [cid, name, type, notnull, dflt, pk] —
  # kept as {name, type, notnull, pk} tuples so the post-condition can check
  # the type and flags, not just the name.
  defp tasks_columns do
    case repo().query("PRAGMA table_info(tasks)", [], log: false) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [_cid, name, type, notnull, _dflt, pk] ->
          {name, type, notnull, pk}
        end)

      _other ->
        []
    end
  end

  defp column?(columns), do: Enum.any?(columns, fn {name, _t, _n, _p} -> name == @column end)

  defp assert_column! do
    case Enum.filter(tasks_columns(), fn {name, _t, _n, _p} -> name == @column end) do
      [@column_spec] ->
        :ok

      [] ->
        raise Ecto.MigrationError,
              "session_mode migration failed: the tasks table has no #{@column} column " <>
                "after the adoption (PRAGMA table_info reported " <>
                "#{inspect(Enum.map(tasks_columns(), &elem(&1, 0)))})"

      other ->
        raise Ecto.MigrationError,
              "session_mode migration failed: #{@column} must be a nullable TEXT non-key " <>
                "column, got #{inspect(other)}"
    end
  end

  # The adoption is a schema-header edit only: no row is rewritten and nothing
  # is backfilled, so every pre-existing row's session_mode is NULL (the codec
  # reads it as "oneshot"). A non-NULL value here means this migration wrote
  # data it does not own.
  defp assert_no_backfill! do
    case repo().query("SELECT count(*) FROM tasks WHERE #{@column} IS NOT NULL", [], log: false) do
      {:ok, %{rows: [[0]]}} ->
        :ok

      {:ok, %{rows: [[count]]}} ->
        raise Ecto.MigrationError,
              "session_mode migration failed: #{count} task row(s) hold a non-NULL " <>
                "#{@column} after the adoption — this migration must not write data"

      _other ->
        raise Ecto.MigrationError,
              "session_mode migration failed: could not verify that no task row was rewritten"
    end
  end
end
