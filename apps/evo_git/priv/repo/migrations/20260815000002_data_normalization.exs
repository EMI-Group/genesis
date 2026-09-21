defmodule EvoGit.Repo.Migrations.DataNormalization do
  @moduledoc """
  Data normalization + denormalization backfills for adopted task databases.

  Ports the semantics of the raw-SQL boot pipeline + `mix migrate.store`:

    * timestamp normalization (`Schema.normalize_timestamps/1`) — rewrite
      legacy variable-precision ISO-8601 text to the fixed
      `%Y-%m-%dT%H:%M:%S.SSSZ` form via `strftime('%Y-%m-%dT%H:%M:%fZ', ...)`
    * canonical result rewrite (`Schema.canonicalize_results/1`) — JSON
      `null` text → SQL NULL; every other untagged value wrapped verbatim as
      `{"__result_tag__":"string","value":...}`
    * canonical opts rewrite (`Schema.canonicalize_opts/1`) — legacy
      positional `[key, value]` pair arrays → JSON objects. Always done in
      Elixir (never `json_group_object`, which collapses JSON booleans to
      SQLite integers)
    * `branch_name` backfill from `result.data.branch_name` (migrate.store
      step 6)
    * `updated_at` backfill from `finished_at` / `started_at` / now
      (migrate.store step 7)
    * drop the DETS-era quarantine tables (migrate.store step 8)

  Idempotent — every guard leaves already-normalized rows alone, so
  re-running (or a fresh DB) finds nothing to change.

  `execute/1` takes exactly ONE statement; the Elixir-side rewrites read
  rows via `repo().query/2` and update per-row.
  """

  use Ecto.Migration

  alias EvoGit.Store.Codec

  @impl Ecto.Migration
  def change do
    normalize_timestamps()
    canonicalize_results()
    canonicalize_opts()
    backfill_branch_name()
    backfill_updated_at()
    drop_quarantine_tables()
  end

  ## Timestamp normalization (Schema.normalize_timestamps/1)

  defp normalize_timestamps do
    normalize_timestamp("tasks", "started_at")
    normalize_timestamp("tasks", "finished_at")
    normalize_timestamp("projects", "last_opened_at")
  end

  defp normalize_timestamp(table, column) do
    # The GLOB pattern matches values already ending in exactly 3 fractional
    # digits + Z (the fixed format) → no-op after the first run;
    # julianday(...) IS NOT NULL skips unparseable rows.
    execute("""
      UPDATE #{table}
      SET #{column} = strftime('%Y-%m-%dT%H:%M:%fZ', #{column})
      WHERE #{column} IS NOT NULL
        AND #{column} NOT GLOB '*.[0-9][0-9][0-9]Z'
        AND julianday(#{column}) IS NOT NULL
    """)
  end

  ## Canonical result rewrite (Schema.canonicalize_results/1, JSON1 path)

  # JSON1 is compiled into every SQLite the NIF ships (xqlite prebuilt), so
  # this migration uses the SQL path only — probing with json_valid('{}')
  # and falling back to an Elixir loop would duplicate the Schema module for
  # no reachable benefit.
  defp canonicalize_results do
    # JSON literal null text → SQL NULL.
    execute("""
      UPDATE tasks
      SET result = NULL
      WHERE result IS NOT NULL
        AND json_valid(result) = 1
        AND json_type(result) = 'null'
    """)

    # Every other untagged value — raw non-JSON strings AND untagged JSON
    # objects/arrays/scalars — wrapped verbatim (json_object/3 turns its
    # TEXT argument into a JSON string, so the raw content round-trips).
    execute("""
      UPDATE tasks
      SET result = json_object('__result_tag__','string','value',result)
      WHERE result IS NOT NULL
        AND (json_valid(result) = 0
             OR json_extract(result, '$.__result_tag__') IS NULL)
    """)
  end

  ## Canonical opts rewrite (Schema.canonicalize_opts/1)

  defp canonicalize_opts do
    # SQL guard narrows the scan; rows that are already objects never match.
    {:ok, %{rows: rows}} =
      repo().query(
        """
        SELECT id, opts FROM tasks
        WHERE opts IS NOT NULL
          AND NOT (json_valid(opts) = 1 AND json_type(opts) = 'object')
        """,
        [],
        log: false
      )

    for [id, opts] <- rows,
        rewritten = rewrite_opts(opts),
        do: update_column(id, "opts", rewritten)

    :ok
  end

  # Legacy format: a JSON array of [key, value] pair arrays. Guard that every
  # element is a 2-element list; malformed rows and already-object rows are
  # left untouched (nil).
  defp rewrite_opts(opts) do
    case Jason.decode(opts) do
      {:ok, pairs} when is_list(pairs) ->
        if Enum.all?(pairs, &(is_list(&1) and length(&1) == 2)) do
          pairs |> Map.new(fn [k, v] -> {k, v} end) |> Jason.encode!()
        else
          nil
        end

      _other ->
        nil
    end
  end

  ## Denormalization backfills (migrate.store steps 6-7)

  defp backfill_branch_name do
    # From the canonical ok-result shape
    # {"__result_tag__":"ok","data":{"branch_name": "..."}}.
    execute("""
      UPDATE tasks
      SET branch_name = json_extract(result, '$.data.branch_name')
      WHERE branch_name IS NULL
        AND json_valid(result) = 1
        AND json_extract(result, '$.__result_tag__') = 'ok'
    """)
  end

  defp backfill_updated_at do
    now = Codec.encode_datetime(DateTime.utc_now())

    {:ok, _} =
      repo().query(
        "UPDATE tasks SET updated_at = COALESCE(finished_at, started_at, ?1) WHERE updated_at IS NULL",
        [now],
        log: false
      )

    :ok
  end

  ## Quarantine table drops (migrate.store step 8)

  defp drop_quarantine_tables do
    # DETS-era leftovers — no current code path creates these tables; they
    # only exist in very old databases.
    execute("DROP TABLE IF EXISTS tasks_quarantine")
    execute("DROP TABLE IF EXISTS projects_quarantine")
  end

  ## Shared

  defp update_column(id, column, value) do
    {:ok, _} =
      repo().query("UPDATE tasks SET #{column} = ?1 WHERE id = ?2", [value, id], log: false)

    :ok
  end
end
