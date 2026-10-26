defmodule EvoGit.Repo.Migrations.CreateTaskAgentArchives do
  @moduledoc """
  Creates `task_agent_archives` — ONE relational ROW per (task, agent).

  The per-agent archive used to be a single JSON array inside
  `tasks.archive_metadata` (and, before the dedup, a duplicate
  `archive_records` key inside `tasks.result`). Reading ONE agent's archived
  conversation therefore meant decoding the WHOLE task's archive, and the
  dashboard's agent-detail panel paid for every agent of the task on every
  open. This migration gives each archived agent its own row, so the archive
  becomes a normal relational read: page the roster without the `result` blob,
  fetch one agent's `result` on demand, delete by task.

  ## Schema

  | column               | type    | notes |
  |----------------------|---------|-------|
  | `task_id`            | TEXT    | NOT NULL, PK part 1 |
  | `agent_id`           | INTEGER | NOT NULL, PK part 2 |
  | `parent_id`          | INTEGER | spawn tree parent (agent id), NULL for the root agent |
  | `depth`              | INTEGER | NOT NULL DEFAULT 0 — spawn depth (root = 0) |
  | `agent_type`         | TEXT    | agent type key (manager/executor/...) |
  | `context_node_path`  | TEXT    | node the agent was scoped to |
  | `objective`          | TEXT    | the agent's objective |
  | `result`             | TEXT    | the agent's final response — the HEAVY column, paged separately |
  | `base_commit`        | TEXT    | commit the agent started from |
  | `final_commit`       | TEXT    | commit the agent ended on |
  | `branch_name`        | TEXT    | branch the agent worked on |
  | `archive_ref_start`  | TEXT    | archive start ref |
  | `archive_ref_final`  | TEXT    | archive final ref |
  | `repo_id`            | INTEGER | repo index (0 = primary) |
  | `repo_root`          | TEXT    | absolute repo root |
  | `repo_path`          | TEXT    | repo-relative path |
  | `usage`              | TEXT    | plain JSON object (token/cost accounting) |
  | `llm_settings`       | TEXT    | plain JSON object |
  | `agent_settings`     | TEXT    | plain JSON object |
  | `foreign_repos`      | TEXT    | plain JSON array of objects |
  | `compression_count`  | INTEGER | NOT NULL DEFAULT 0 |
  | `started_at`         | TEXT    | ISO-8601 TEXT, stored as-is |
  | `completed_at`       | TEXT    | ISO-8601 TEXT, stored as-is |

  The composite `PRIMARY KEY (task_id, agent_id)` is what makes a write
  idempotent: a re-put of the same pair REPLACES the row
  (`INSERT … ON CONFLICT (task_id, agent_id) DO UPDATE` / the equivalent
  `INSERT OR REPLACE`), so a re-run or a crash-recovered write can never
  duplicate an agent.

  Timestamps stay ISO-8601 **TEXT** and the four JSON columns stay plain JSON
  **TEXT** — no Ecto field types, no compression, no `"z1:"` prefix, exactly
  like every other column in this store (the wire format is owned by
  `EvoGit.Store.Types.ArchiveColumns.*`, not by the migration).

  ## Index

  `task_agent_archives_task_depth_idx` on `(task_id, depth, agent_id)` serves
  the one read shape the dashboard uses — the per-task roster,
  `WHERE task_id = ? ORDER BY depth ASC, agent_id ASC LIMIT/OFFSET` — as an
  index-served seek + ordered scan, with `id`-only projections (`agent_id`,
  `depth`) answered from the index. The `task_id` prefix also serves the
  `DELETE … WHERE task_id = ?` cascade. No other index is added: `agent_id`
  lookups always carry the `task_id` (the pair IS the primary key, whose
  b-tree already covers the full-row fetch).

  ## Conventions

  Idempotent (`CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`) and
  applied to a FRESH database as well as to ANY already-migrated one — this is
  additive DDL, so there is no table rebuild and no data rewrite. Statements
  run via `repo().query!/3` (the sibling migrations' convention), NOT
  `Ecto.Migration.execute/1`, whose string commands are queued until
  `flush/0` — the post-condition below probes `PRAGMA table_info` /
  `PRAGMA index_info` in body order. Defined as `up/0` (no `down/0`), like the
  siblings: dropping the table would drop user archive data.
  """

  use Ecto.Migration

  # The physical column order — FIRST the two primary-key columns, then the
  # roster columns, then the heavy `result` blob, then the refs/repo/JSON
  # columns, and the timestamps LAST. Kept as data so the post-condition below
  # can assert the exact shape that was created.
  @table_ddl """
  CREATE TABLE IF NOT EXISTS task_agent_archives (
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
    repo_id INTEGER,
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

  @columns ~w(task_id agent_id parent_id depth agent_type context_node_path objective result
              base_commit final_commit branch_name archive_ref_start archive_ref_final repo_id
              repo_root repo_path usage llm_settings agent_settings foreign_repos
              compression_count started_at completed_at)

  @index_name "task_agent_archives_task_depth_idx"
  @index_columns ~w(task_id depth agent_id)

  def up do
    sql(@table_ddl)

    sql(
      "CREATE INDEX IF NOT EXISTS #{@index_name} ON task_agent_archives(task_id, depth, agent_id)"
    )

    assert_table_shape!()
    assert_index_shape!()
  end

  ## Helpers

  defp sql(statement), do: repo().query!(statement, [], log: false)

  # Post-condition: the table carries EXACTLY the declared columns in the
  # declared order. `IF NOT EXISTS` alone would silently keep a same-named
  # table of a different shape, and every read/write through the schema would
  # then fail at runtime instead of here.
  defp assert_table_shape! do
    actual = table_columns()

    if actual != @columns do
      raise Ecto.MigrationError,
            "task_agent_archives was not created with the expected columns: " <>
              "PRAGMA table_info returned #{inspect(actual)}"
    end

    :ok
  end

  # PRAGMA table_info(<table>) rows: [cid, name, type, notnull, dflt, pk]. A
  # missing table yields NO rows (never an error), so [] is the "absent" signal.
  defp table_columns do
    case repo().query("PRAGMA table_info(task_agent_archives)", [], log: false) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [_cid, name, _type, _notnull, _dflt, _pk] -> name end)

      _other ->
        []
    end
  end

  defp assert_index_shape! do
    actual = index_columns()

    if actual != @index_columns do
      raise Ecto.MigrationError,
            "index #{@index_name} on task_agent_archives(#{Enum.join(@index_columns, ", ")}) " <>
              "was not applied: PRAGMA index_info returned #{inspect(actual)}"
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
end
