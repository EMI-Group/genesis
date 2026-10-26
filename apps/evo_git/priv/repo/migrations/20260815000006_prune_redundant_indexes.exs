defmodule EvoGit.Repo.Migrations.PruneRedundantIndexes do
  @moduledoc """
  Final index normalization: drops the four `tasks` indexes no plan uses, and
  proves the final six exist.

  ## The four that go

    * `idx_tasks_status` on `(status)` — an exact prefix of
      `idx_tasks_status_started_at` `(status, started_at)`. Any seek on
      `status = ?` uses the composite: it is strictly more useful (it also
      delivers the paginated `ORDER BY started_at DESC`), so the single-column
      index can never win a plan.
    * `idx_tasks_finished_at` on `(finished_at)` — an exact prefix of
      `idx_tasks_finished_at_id` `(finished_at, id)`, which serves both cleanup
      legs as a COVERING index (`id` rides in the index entry), so the plain
      index only ever loses.
    * `idx_tasks_project_path` on `(project_path)` — an exact prefix of
      `idx_tasks_project_path_started_at` `(project_path, started_at)`, which
      also covers the `SELECT DISTINCT project_path` read
      (`SCAN … USING COVERING INDEX`) and the path-filtered page order.
    * `idx_tasks_lease_expires_at` on `(lease_expires_at)` — nothing ever
      filters or orders on that column: the lease reads constrain `status`
      (`select_running_lease_info/1`) or address the row by primary key
      (`update_lease_expires_at/3`), and expiry is compared in Elixir. Every
      write paid for maintaining an index no query could use.

  Each drop is a pure schema-header edit (no table rebuild, no data rewrite),
  and `DROP INDEX IF EXISTS` makes it a no-op on a database where the index
  never existed — which is every FRESH one: `20260815000001_baseline_adoption`
  creates only the final six, so this migration does nothing at all on a new
  install.

  ## Post-condition

  Both halves are asserted, so an already-migrated database provably converges
  instead of silently keeping a redundant index (or silently missing one):
  none of the four may still be listed by `PRAGMA index_list(tasks)`, and all
  six final `idx_tasks_*` indexes must be. The SHAPES of the six are pinned by
  the migrations that create them (`…000001`, `…000003`, `…000004`); this one
  only checks presence.

  Statements run via `repo().query!/3` in body order, not
  `Ecto.Migration.execute/1` (whose string commands are queued until
  `flush/0` — see the baseline migration's moduledoc), because the
  post-condition probes `PRAGMA index_list` after the drops. Defined as
  `up/0` (no `down/0`), like the siblings: re-creating the redundant indexes
  would only restore the write cost they imposed.
  """

  use Ecto.Migration

  @redundant_indexes ~w(idx_tasks_status idx_tasks_finished_at idx_tasks_project_path idx_tasks_lease_expires_at)

  # The FINAL `tasks` index set — the same six `20260815000001` creates.
  @final_indexes ~w(idx_tasks_updated_at idx_tasks_started_at idx_tasks_status_started_at
                    idx_tasks_project_path_started_at idx_tasks_status_updated_at_id
                    idx_tasks_finished_at_id)

  def up do
    for name <- @redundant_indexes do
      sql("DROP INDEX IF EXISTS #{name}")
    end

    assert_pruned!()
    assert_final_indexes!()
  end

  ## Helpers

  defp sql(statement), do: repo().query!(statement, [], log: false)

  defp assert_pruned! do
    present = index_names() |> MapSet.new()
    remaining = Enum.filter(@redundant_indexes, &MapSet.member?(present, &1))

    if remaining != [] do
      raise Ecto.MigrationError,
            "redundant tasks indexes were not dropped: #{inspect(remaining)} " <>
              "(PRAGMA index_list(tasks) still reports them)"
    end

    :ok
  end

  defp assert_final_indexes! do
    present = index_names() |> MapSet.new()
    missing = Enum.reject(@final_indexes, &MapSet.member?(present, &1))

    if missing != [] do
      raise Ecto.MigrationError,
            "the final tasks index set is incomplete: #{inspect(missing)} " <>
              "are missing (PRAGMA index_list(tasks) returned #{inspect(MapSet.to_list(present))})"
    end

    :ok
  end

  # PRAGMA index_list(<table>) rows: [seq, name, unique, origin, partial]. The
  # implicit `sqlite_autoindex_tasks_1` of the TEXT primary key is listed too —
  # it is not an `idx_tasks_*` name, so it never reaches the assertions above.
  defp index_names do
    case repo().query("PRAGMA index_list(tasks)", [], log: false) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [_seq, name | _rest] -> name end)
      _other -> []
    end
  end
end
