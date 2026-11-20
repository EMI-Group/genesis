defmodule EvoGit.AgentStateRepo.Migrations.AgentStateIndexes do
  @moduledoc """
  Adds the two read-path indexes `agent_states` was missing — and NOTHING else.

  ## Why these two

  `agent_states` is keyed `(task_id, agent_id)`, so the primary key serves one
  run's read but neither of the two aggregate scans the subsystem makes:

    * `SELECT MAX(agent_id) FROM agent_states` —
      `EvoGit.AgentState.Store.max_agent_id/1`, the boot seed for the
      scheduler's in-memory `next_agent_id` counter (agent ids must stay stable
      across a BEAM restart). Without an index on `agent_id` that aggregate is a
      FULL TABLE SCAN, made under a bounded budget
      (`EvoGit.TaskRegistry.AgentStateRead`, ~2 s) that DEGRADES to `0` — and a
      `0` seed is not benign: the scheduler then hands out ids from `1` again and
      can mint an id a durable row already holds. `agent_states_agent_id_index`
      makes the seed O(log n) instead.

    * `SELECT … WHERE task_id = ? ORDER BY depth, agent_id` — `roster/2`, the
      whole-tree skeleton a resume decides from, plus the same ordering in
      `roster_many/2`. The primary key's leading `task_id` narrows the rows but
      leaves the `ORDER BY` to be sorted, so SQLite builds a temp B-tree per
      call. `agent_states_task_depth_agent_index` on `(task_id, depth, agent_id)`
      IS that ordering, so the query is answered by an ordered index walk.

  ## The trade

  Two indexes on a table written once per agent turn (a coalesced checkpoint is
  ONE transaction touching one row) cost one index entry per insert/update and
  grow the file. That is bought against the two scans above: the id seed runs at
  EVERY scheduler boot and the roster runs at every pause/resume classification,
  and their failure modes are a duplicated agent id or a `:not_resumable`
  refusal — neither is worth an O(n) scan on a durable database measured in
  agent-turns.

  The two pre-existing retention indexes
  (`agent_states_status_completed_at_index`, `agent_states_updated_at_index`)
  and the v2 batch index `agent_states_task_parent_index` are deliberately left
  UNTOUCHED — `prune/1` and the batch lookups still use them.

  ## Index-only, idempotent, probe-guarded

  No column is added, dropped or retyped and no row is rewritten: this version
  is purely additive DDL. Every statement runs via `repo().query!/3` in body
  order — never `Ecto.Migration.execute/1`, whose string commands are queued
  until `flush/0`, so the post-conditions below must observe the post-migration
  schema. `CREATE INDEX IF NOT EXISTS` makes `up/0` a no-op on a re-run,
  `down/0` drops each index with `DROP INDEX IF EXISTS` and asserts both are
  gone, and a probe that cannot read the index list RAISES `Ecto.MigrationError`
  (boot-fatal) instead of reporting "no index".
  """

  use Ecto.Migration

  @table "agent_states"

  # {index name, ordered column list} — the two read paths above, in the order
  # `PRAGMA index_info/1` reports the columns back.
  @indexes [
    {"agent_states_agent_id_index", ["agent_id"]},
    {"agent_states_task_depth_agent_index", ["task_id", "depth", "agent_id"]}
  ]

  def up do
    Enum.each(@indexes, fn {index, columns} ->
      sql("CREATE INDEX IF NOT EXISTS #{index} ON #{@table} (#{Enum.join(columns, ", ")})")
    end)

    assert_indexes!()

    :ok
  end

  def down do
    Enum.each(@indexes, fn {index, _columns} ->
      sql("DROP INDEX IF EXISTS #{index}")
    end)

    assert_absent!()

    :ok
  end

  ## Helpers

  defp sql(statement), do: repo().query!(statement, [], log: false)

  # Every index name on `agent_states` (SQLite keeps those names unique, so
  # presence IS "exactly once"). A probe that cannot run RAISES: reporting "no
  # index" for an unreadable schema would silently skip the CREATE, and would
  # pass a rollback assertion for the wrong reason.
  defp index_names do
    case repo().query(
           "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
           [@table],
           log: false
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name] -> name end)

      {:error, reason} ->
        raise Ecto.MigrationError,
              "agent-state indexes migration failed: could not read the #{@table} " <>
                "index list (sqlite_master): #{inspect(reason)}"
    end
  end

  # The ordered column names of ONE index: `PRAGMA index_info(<index>)` rows are
  # [seqno, cid, name], and a nonexistent index answers NO rows. Same probe
  # discipline as `index_names/0`: an unreadable schema RAISES.
  defp index_columns(index) do
    case repo().query("PRAGMA index_info(#{index})", [], log: false) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [_seqno, _cid, name] -> name end)

      {:error, reason} ->
        raise Ecto.MigrationError,
              "agent-state indexes migration failed: could not read index #{index} " <>
                "(PRAGMA index_info): #{inspect(reason)}"
    end
  end

  defp assert_indexes! do
    current = index_names()

    Enum.each(@indexes, fn {index, columns} ->
      unless index in current do
        raise Ecto.MigrationError,
              "agent-state indexes migration failed: index #{index} is missing on " <>
                "#{@table} after the migration (sqlite_master reported " <>
                "#{inspect(current)})"
      end

      case index_columns(index) do
        ^columns ->
          :ok

        other ->
          raise Ecto.MigrationError,
                "agent-state indexes migration failed: index #{index} must be on " <>
                  "(#{Enum.join(columns, ", ")}), got #{inspect(other)}"
      end
    end)

    :ok
  end

  defp assert_absent! do
    present =
      @indexes
      |> Enum.filter(fn {index, _columns} -> index in index_names() end)
      |> Enum.map(&elem(&1, 0))

    if present != [] do
      raise Ecto.MigrationError,
            "agent-state indexes migration failed: indexes #{inspect(present)} are still " <>
              "present on #{@table} after the rollback"
    end

    :ok
  end
end
