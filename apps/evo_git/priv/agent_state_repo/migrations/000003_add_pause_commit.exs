defmodule EvoGit.AgentStateRepo.Migrations.AddPauseCommit do
  @moduledoc """
  Adds the `agent_states.pause_commit` column — the git commit sha of the
  worktree checkpoint an agent created when it paused at a turn boundary.

  ## Why a separate migration

  `000001_create_agent_state` stays the ONE schema-creating step: it never
  mentions this column, so a database an EARLIER release left behind (already
  stamped at version 2) needs this ONE guarded `ALTER TABLE`, while a fresh
  database runs `000001`, then `000002`, then this file, which appends the
  column after `completed_at`. Column order is functionally irrelevant here —
  every statement in `EvoGit.AgentState.Store` is name-based.

  ## Values and normalization

  The column holds a plain git commit sha as TEXT. `NULL` is the only other
  legal value and means "this run has no paused checkpoint". There is
  deliberately NO `DEFAULT` and no backfill: every pre-existing row holds
  `NULL`, which is exactly the truth for a row written before pausing existed,
  and `EvoGit.AgentState.Record`'s `:text` decoder surfaces it as `nil`.

  Only `EvoGit.AgentState.Store.put_pause_commit/5` writes this column, and it
  updates this column ALONE: the message chunks, `message_count` and
  `chunk_count` are untouched, so a pause can never be mistaken for a
  conversation write by the append/rewrite continuity rule.

  ## Probe-guarded and idempotent

  A `PRAGMA table_info(agent_states)` probe decides the branch, and every
  statement runs via `repo().query/3` in body order — never
  `Ecto.Migration.execute/1`, whose string commands are queued until `flush/0`,
  so an in-body probe would observe the pre-migration schema. `up/0` issues the
  `ALTER` only when the column is ABSENT and `down/0` the `DROP COLUMN` only
  when it is PRESENT, so re-running either direction is a no-op instead of a
  "duplicate column name"/"no such column" error. The probe RAISES when it
  cannot run at all, so an unreadable schema can never masquerade as "the
  column is missing".
  """

  use Ecto.Migration

  @table "agent_states"
  @column "pause_commit"

  # The one shape this migration adds: nullable TEXT, not a key. SQLite refuses
  # a NOT NULL add without a default on a populated table, and `NULL` is the
  # canonical "no paused checkpoint" value.
  @column_spec {@column, "TEXT", 0, 0}

  def up do
    unless column?(columns()) do
      sql("ALTER TABLE #{@table} ADD COLUMN #{@column} TEXT")
    end

    assert_column!()
    :ok
  end

  def down do
    if column?(columns()) do
      sql("ALTER TABLE #{@table} DROP COLUMN #{@column}")
    end

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
              "pause_commit migration failed: could not read the #{@table} schema " <>
                "(PRAGMA table_info): #{inspect(reason)}"
    end
  end

  defp column?(columns), do: Enum.any?(columns, fn {name, _t, _n, _p} -> name == @column end)

  defp assert_column! do
    case Enum.filter(columns(), fn {name, _t, _n, _p} -> name == @column end) do
      [@column_spec] ->
        :ok

      [] ->
        raise Ecto.MigrationError,
              "pause_commit migration failed: the #{@table} table has no #{@column} " <>
                "column after the ALTER (PRAGMA table_info reported " <>
                "#{inspect(Enum.map(columns(), &elem(&1, 0)))})"

      other ->
        raise Ecto.MigrationError,
              "pause_commit migration failed: #{@column} must be a nullable TEXT " <>
                "non-key column, got #{inspect(other)}"
    end
  end

  defp assert_absent! do
    if column?(columns()) do
      raise Ecto.MigrationError,
            "pause_commit migration failed: #{@column} is still present on #{@table} " <>
              "after the rollback"
    end

    :ok
  end
end
