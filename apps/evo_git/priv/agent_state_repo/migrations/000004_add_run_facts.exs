defmodule EvoGit.AgentStateRepo.Migrations.AddRunFacts do
  @moduledoc """
  Adds the v2 RUN-FACT columns to `agent_states`, normalizes the finished-run
  status and adds the roster index a whole-tree resume reads.

  ## Why a separate migration

  `000001_create_agent_state` stays the ONE schema-creating step: it never
  mentions these columns, so a database an EARLIER release left behind (already
  stamped at version 3) needs these guarded `ALTER TABLE`s, while a fresh
  database runs `000001`, `000002`, `000003`, then this file, which appends the
  columns after `pause_commit`. Column order is functionally irrelevant —
  every statement in `EvoGit.AgentState.Store` is name-based.

  ## Columns

  All seven are NULLABLE with no `DEFAULT` and no backfill, because `NULL` is
  exactly the truth for a row written before the fact existed:

    * `spawn_turn` / `spawn_index` — where in the parent's tool batch this
      child agent was started (the pair a parent's batch resolution matches
      done children against);
    * `branch` — the agent's own work branch;
    * `base_commit` — the commit its worktree was created from;
    * `anchor_ref` — the ref that keeps its `current_commit` reachable past
      worktree reclamation and branch cleanup;
    * `redispatch` — JSON: the fields needed to rebuild the agent's
      `%AgentSpec{}` after a restart (never pids, funs or credentials);
    * `result` — JSON: the finished run's stored result
      (`text`/`commit`/`repo id`), readable by a parent whose subagent call was
      interrupted.

  ## Normalization and the roster index

  `status = 'completed'` was the pre-v2 spelling of a finished run; the v2 row
  model has exactly `running` and `done`, so every legacy row is rewritten to
  `'done'`. This is a value normalization, not a schema change.

  `agent_states_task_parent_index` on `(task_id, parent_id)` serves the one
  read a whole-tree resume makes: every row of one task, and the done children
  of one parent's batch. The two pre-existing retention indexes
  (`agent_states_status_completed_at_index`, `agent_states_updated_at_index`)
  are deliberately left UNTOUCHED — retention pruning still uses them.

  ## Probe-guarded and idempotent

  A `PRAGMA table_info(agent_states)` probe decides each `ALTER`, and every
  statement runs via `repo().query/3` in body order — never
  `Ecto.Migration.execute/1`, whose string commands are queued until `flush/0`,
  so an in-body probe would observe the pre-migration schema. `up/0` issues an
  `ALTER` only when its column is ABSENT and `down/0` a `DROP COLUMN` only when
  it is PRESENT, so re-running either direction is a no-op instead of a
  "duplicate column name"/"no such column" error. The probe RAISES when it
  cannot run at all, so an unreadable schema can never masquerade as "the
  column is missing".

  `down/0` removes ONLY what this migration added: the seven columns and the
  roster index. It deliberately does NOT rewrite `'done'` back to
  `'completed'` — a status value is stored DATA, and turning every finished row
  back into the legacy spelling would relabel rows that were never legacy.
  """

  use Ecto.Migration

  @table "agent_states"
  @index "agent_states_task_parent_index"

  # The shapes this migration adds, in the order the columns are appended:
  # nullable, non-key. SQLite refuses a NOT NULL add without a default on a
  # populated table.
  @columns [
    {"spawn_turn", "INTEGER"},
    {"spawn_index", "INTEGER"},
    {"branch", "TEXT"},
    {"base_commit", "TEXT"},
    {"anchor_ref", "TEXT"},
    {"redispatch", "TEXT"},
    {"result", "TEXT"}
  ]

  @column_names Enum.map(@columns, fn {name, _type} -> name end)

  def up do
    existing = columns()

    Enum.each(@columns, fn {column, type} ->
      unless column?(existing, column) do
        sql("ALTER TABLE #{@table} ADD COLUMN #{column} #{type}")
      end
    end)

    # The pre-v2 spelling of a finished run. A row that is already `done` (or
    # still `running`) is untouched.
    sql("UPDATE #{@table} SET status = 'done' WHERE status = 'completed'")

    sql("CREATE INDEX IF NOT EXISTS #{@index} ON #{@table} (task_id, parent_id)")

    assert_columns!()
    assert_index!()
    :ok
  end

  def down do
    existing = columns()

    if index?(@index) do
      sql("DROP INDEX IF EXISTS #{@index}")
    end

    # Reverse append order, so a rollback walks the columns back out the way
    # they came in.
    Enum.each(Enum.reverse(@columns), fn {column, _type} ->
      if column?(existing, column) do
        sql("ALTER TABLE #{@table} DROP COLUMN #{column}")
      end
    end)

    assert_absent!()
    :ok
  end

  ## Helpers

  defp sql(statement), do: repo().query!(statement, [], log: false)

  # PRAGMA table_info(<table>) rows are [cid, name, type, notnull, dflt, pk] —
  # mapped to {name, type, notnull, pk} so a post-condition can pin the shape,
  # not merely the name. A probe that cannot run RAISES: reporting "no columns"
  # here would silently skip the ALTER and only ever be caught later.
  defp columns do
    case repo().query("PRAGMA table_info(#{@table})", [], log: false) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [_cid, name, type, notnull, _dflt, pk] ->
          {name, type, notnull, pk}
        end)

      {:error, reason} ->
        raise Ecto.MigrationError,
              "run-facts migration failed: could not read the #{@table} schema " <>
                "(PRAGMA table_info): #{inspect(reason)}"
    end
  end

  defp column?(columns, column),
    do: Enum.any?(columns, fn {name, _t, _n, _p} -> name == column end)

  # Same probe discipline as `columns/0`: an index list that cannot be read
  # must raise, never answer "no index".
  defp indexes do
    case repo().query(
           "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
           [@table],
           log: false
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name] -> name end)

      {:error, reason} ->
        raise Ecto.MigrationError,
              "run-facts migration failed: could not read the #{@table} indexes " <>
                "(sqlite_master): #{inspect(reason)}"
    end
  end

  defp index?(index), do: index in indexes()

  defp assert_columns! do
    current = columns()

    Enum.each(@columns, fn {column, type} ->
      case Enum.filter(current, fn {name, _t, _n, _p} -> name == column end) do
        [{^column, ^type, 0, 0}] ->
          :ok

        [] ->
          raise Ecto.MigrationError,
                "run-facts migration failed: the #{@table} table has no #{column} " <>
                  "column after the ALTER (PRAGMA table_info reported " <>
                  "#{inspect(Enum.map(current, &elem(&1, 0)))})"

        other ->
          raise Ecto.MigrationError,
                "run-facts migration failed: #{column} must be a nullable #{type} " <>
                  "non-key column, got #{inspect(other)}"
      end
    end)

    :ok
  end

  defp assert_index! do
    unless index?(@index) do
      raise Ecto.MigrationError,
            "run-facts migration failed: index #{@index} is missing on #{@table} " <>
              "after the migration"
    end

    :ok
  end

  defp assert_absent! do
    present = Enum.filter(@column_names, fn column -> column?(columns(), column) end)

    if present != [] do
      raise Ecto.MigrationError,
            "run-facts migration failed: columns #{inspect(present)} are still present " <>
              "on #{@table} after the rollback"
    end

    if index?(@index) do
      raise Ecto.MigrationError,
            "run-facts migration failed: index #{@index} is still present on #{@table} " <>
              "after the rollback"
    end

    :ok
  end
end
