defmodule EvoGit.Repo.Migrations.UnpackAbandonedCompressedRows do
  @moduledoc """
  One-shot REPAIR: expand every task row still stored in the abandoned
  `"z1:"`-prefixed compression format back into plain JSON text.

  ## Why this exists

  An earlier iteration of this store compressed the three large task text
  columns — `result`, `logs` and `archive_metadata` — as
  `"z1:" <> Base64(zlib(json))` whenever their JSON exceeded 4096 bytes, and
  shipped a migration that rewrote pre-existing rows into that format. The
  approach was REJECTED: every trace of it is gone from the encoder/decoder,
  so nothing in the runtime writes — or can read — that prefix any more. A
  database that already ran the rejected rewrite, however, still carries the
  compressed values ON DISK: unreadable to the current codec and permanently
  larger than they need to be in the WAL.

  This migration is that repair, and it is deliberately the LAST word on the
  format: it inflates each remaining `"z1:"` value back to the plain JSON text
  it was made from and stores that text. `archive_metadata` is then emptied
  and dropped by the sibling archive migration (`20260815000008`), which runs
  later; unpacking it first keeps that migration's JSON decode working.

  ## Per row

  For each column (`result`, `logs`, `archive_metadata`) independently:

    1. sweep the ids whose value is a TEXT that STARTS WITH `"z1:"`
       (`substr(col, 1, 3) = 'z1:'` — a case-SENSITIVE prefix test, unlike
       SQLite's case-insensitive `LIKE`);
    2. read ONE value at a time (a row's `result` can be tens of MiB), strip
       the prefix, `Base.decode64/1` it and `:zlib.uncompress/1` it;
    3. `UPDATE` exactly that one column of that one row with the inflated
       plain text — nothing else on the row, and in particular NEVER
       `updated_at` (the repair must not look like a task mutation).

  The compression/decompression helpers live HERE, locally, on purpose: no
  `EvoGit.Store.Codec` function is involved (the codec no longer has any), so
  this script can never be resurrected as a live writer of the format.

  ## Idempotent

  The candidate sweep only selects `"z1:"`-prefixed values AND the `UPDATE`
  repeats the same predicate in its own `WHERE`, so a value that does not
  start with the prefix is never touched: a second run (or a concurrent boot
  that already repaired the row) matches nothing and writes nothing.

  ## Lenient

  A payload that fails to base64-decode or zlib-inflate is LEFT EXACTLY AS IT
  WAS and logged with `Logger.warning` naming the task id and the column
  (never the payload contents — it can be tens of MiB). A corrupt value must
  not wedge a user's upgrade; it is excluded from the post-condition below and
  reported in the run summary.

  ## Conventions

  Statements run via `repo().query/3` + `repo().query!/3` (the sibling
  migrations' convention), NOT `Ecto.Migration.execute/1`, whose string
  commands are queued until `flush/0` — the post-condition probes the table in
  body order. `timeout: 600_000` per statement: a 100 MB payload legitimately
  runs past the 60 s connection budget. Defined as `up/0` (no `down/0`): the
  packed format is gone and cannot be re-created.
  """

  use Ecto.Migration

  require Logger

  # The three columns the abandoned compression ever touched.
  @columns ~w(result logs archive_metadata)

  @prefix "z1:"

  # One statement may decode/inflate a ~100 MB payload; the connection's
  # default 60 s budget is not enough for that on a cold page cache.
  @statement_timeout 600_000

  def up do
    for column <- @columns, column_exists?(column) do
      unpack_column(column)
    end

    :ok
  end

  ## Per-column pass

  defp unpack_column(column) do
    {rewritten, skipped} =
      column
      |> compressed_ids()
      |> Enum.reduce({0, []}, fn id, {rewritten, skipped} ->
        case repair_fetched(column, id) do
          :rewritten -> {rewritten + 1, skipped}
          :untouched -> {rewritten, skipped}
          :error -> {rewritten, [id | skipped]}
        end
      end)

    Logger.info(
      "#{inspect(__MODULE__)}: #{column}: #{rewritten} row(s) unpacked to plain JSON, " <>
        "#{length(skipped)} left untouched"
    )

    assert_converged!(column, skipped)
  end

  # Fetch → repair → write, ONE row at a time. The fetched value is re-checked
  # before it is unpacked, so a row another boot already repaired (or a value
  # that stopped being compressed) is left alone.
  defp repair_fetched(column, id) do
    case fetch_value(column, id) do
      {:ok, value} ->
        case unpack(value) do
          {:ok, plain} ->
            write_value(column, id, plain)
            :rewritten

          :untouched ->
            :untouched

          :error ->
            warn(id, column, "the z1: payload could not be base64-decoded and zlib-inflated")
            :error
        end

      :error ->
        warn(id, column, "the row could not be read back")
        :error
    end
  end

  ## Unpacking (local, deliberately NOT the codec)

  defp unpack(@prefix <> encoded), do: inflate(encoded)
  defp unpack(_value), do: :untouched

  defp inflate(encoded) do
    case Base.decode64(encoded) do
      {:ok, compressed} -> inflate_binary(compressed)
      :error -> :error
    end
  end

  defp inflate_binary(compressed) do
    case :zlib.uncompress(compressed) do
      plain when is_binary(plain) -> {:ok, plain}
      _other -> :error
    end
  rescue
    # `:zlib.uncompress/1` raises `:data_error` on a truncated/corrupt stream.
    _error -> :error
  end

  ## Statements

  defp compressed_ids(column) do
    """
    SELECT id FROM tasks
     WHERE #{column} IS NOT NULL
       AND substr(#{column}, 1, 3) = '#{@prefix}'
    """
    |> select_ids([])
  end

  defp fetch_value(column, id) do
    case repo().query(
           "SELECT #{column} FROM tasks WHERE id = ?",
           [id],
           timeout: @statement_timeout,
           log: false
         ) do
      {:ok, %{rows: [[value]]}} -> {:ok, value}
      _other -> :error
    end
  end

  # The prefix predicate is REPEATED in the UPDATE's WHERE clause: if the row
  # changed between the sweep and this write (or a concurrent boot already
  # unpacked it), the update matches nothing instead of clobbering it.
  defp write_value(column, id, plain) do
    sql(
      """
      UPDATE tasks
         SET #{column} = ?
       WHERE id = ?
         AND #{column} IS NOT NULL
         AND substr(#{column}, 1, 3) = '#{@prefix}'
      """,
      # 100 MB payloads: params, never string interpolation.
      [plain, id]
    )
  end

  defp select_ids(statement, params) do
    case repo().query(statement, params, timeout: @statement_timeout, log: false) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [id] -> id end)
      _other -> []
    end
  end

  defp sql(statement, params) do
    repo().query!(statement, params, timeout: @statement_timeout, log: false)
  end

  ## Guards / post-condition

  # `archive_metadata` is dropped by `20260815000008`, which runs after this
  # migration — but a partially-applied boot (or a hand-edited database) can
  # reach this body without the column, so the sweep skips it instead of
  # raising on a missing column.
  defp column_exists?(column) do
    case repo().query("PRAGMA table_info(tasks)", [], log: false) do
      {:ok, %{rows: rows}} -> Enum.any?(rows, fn [_cid, name | _rest] -> name == column end)
      _other -> false
    end
  end

  # Post-condition: no `"z1:"` value is left in this column, apart from the
  # ids this run logged as undecodable (a corrupt payload must not wedge the
  # upgrade; the summary above names them).
  defp assert_converged!(column, skipped) do
    {exclusion, params} = exclusion_clause(skipped)

    remaining =
      """
      SELECT id FROM tasks
       WHERE #{column} IS NOT NULL
         AND substr(#{column}, 1, 3) = '#{@prefix}'
       #{exclusion}
      """
      |> select_ids(params)

    if remaining != [] do
      raise Ecto.MigrationError,
            "unpack-abandoned-compressed-rows did not converge: #{length(remaining)} row(s) " <>
              "still hold a \"#{@prefix}\"-prefixed #{column} (e.g. " <>
              "#{remaining |> Enum.take(5) |> Enum.join(", ")}); the migration's UPDATE did not " <>
              "take effect"
    end

    :ok
  end

  defp exclusion_clause([]), do: {"", []}

  defp exclusion_clause(skipped) do
    placeholders = Enum.map_join(skipped, ", ", fn _id -> "?" end)
    {"AND id NOT IN (#{placeholders})", skipped}
  end

  defp warn(id, column, reason) do
    Logger.warning(
      "#{inspect(__MODULE__)}: skipping task #{id} column #{column} — #{reason} " <>
        "(the value is left exactly as it was)"
    )
  end
end
